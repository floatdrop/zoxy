//! Sans-io HTTP/2 frame codec (RFC 9113 §4, §6): the 24-byte client preface,
//! the 9-byte frame header, the per-type structural rules (fixed payload
//! sizes, stream-id zero/nonzero, our advertised frame-size bound), and the
//! fixed-shape payloads (SETTINGS, PING, RST_STREAM, GOAWAY, WINDOW_UPDATE).
//! Pure functions over caller-owned slices — nothing is copied, allocated,
//! or transformed. What a frame *means* in the current connection/stream
//! state is the state machine's business (a later slice), not this file's
//! (docs/DESIGN.md §7 Phase 5).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");

/// Every HTTP/2 connection opens with these 24 client bytes, before the
/// first frame (RFC 9113 §3.4).
pub const client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

pub const frame_header_bytes: usize = 9;
pub const setting_entry_bytes: usize = 6;

/// SETTINGS_MAX_FRAME_SIZE must stay within this range (RFC 9113 §6.5.2);
/// values outside it are a connection error.
pub const frame_size_floor: u24 = 16384;
pub const frame_size_ceiling: u24 = std.math.maxInt(u24);

/// Frame types (RFC 9113 §6). Non-exhaustive: an unknown type is not an
/// error — its frame must be skipped (§4.1, §5.5).
pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
    _,
};

/// Frame flags (RFC 9113 §6). `end_stream` and `ack` share a bit value —
/// they apply to disjoint frame types.
pub const Flags = struct {
    pub const end_stream: u8 = 0x01; // DATA, HEADERS
    pub const ack: u8 = 0x01; // SETTINGS, PING
    pub const end_headers: u8 = 0x04; // HEADERS, PUSH_PROMISE, CONTINUATION
    pub const padded: u8 = 0x08; // DATA, HEADERS, PUSH_PROMISE
    pub const priority: u8 = 0x20; // HEADERS
};

/// Error codes for RST_STREAM and GOAWAY (RFC 9113 §7). Non-exhaustive:
/// unknown codes arrive from peers and must be tolerated (§7: "treat as
/// INTERNAL_ERROR"), never crash the connection handler.
pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
    _,
};

pub const FrameHeader = struct {
    /// Payload length; the frame occupies `frame_header_bytes + length` wire bytes.
    length: u24,
    type: FrameType,
    flags: u8,
    /// The reserved high bit is masked off on parse (RFC 9113 §4.1).
    stream_id: u31,
};

/// One parsed frame. The payload is a slice of the input, valid only while
/// that buffer is unmodified.
pub const Frame = struct {
    header: FrameHeader,
    payload: []const u8,

    /// Wire bytes this frame occupies (header + payload); the next frame
    /// begins at `input[wire_bytes()..]`.
    pub fn wire_bytes(frame: *const Frame) usize {
        assert(frame.payload.len == frame.header.length);
        return frame_header_bytes + frame.payload.len;
    }
};

pub const FrameError = error{
    /// Payload longer than the frame size we advertised — FRAME_SIZE_ERROR,
    /// always a connection error.
    FrameTooLarge,
    /// Payload length invalid for the frame type — FRAME_SIZE_ERROR. Whether
    /// it is a connection or a stream error depends on the type and state
    /// (RFC 9113 §4.2); that mapping is the caller's.
    InvalidLength,
    /// A structural rule violated (stream id, field value) — PROTOCOL_ERROR.
    Protocol,
    /// A window value exceeding 2^31-1 — FLOW_CONTROL_ERROR.
    FlowControl,
};

/// The GOAWAY/RST_STREAM error code a codec error maps to.
pub fn error_code(err: FrameError) ErrorCode {
    return switch (err) {
        error.FrameTooLarge, error.InvalidLength => .frame_size_error,
        error.Protocol => .protocol_error,
        error.FlowControl => .flow_control_error,
    };
}

/// Match the client preface at the start of `input`: returns the preface
/// length once it is fully present, null while a matching prefix is still
/// arriving. A mismatch fails on the first wrong byte — no need to wait
/// for all 24.
pub fn check_preface(input: []const u8) error{Malformed}!?usize {
    const n = @min(input.len, client_preface.len);
    if (!std.mem.eql(u8, input[0..n], client_preface[0..n])) return error.Malformed;
    if (input.len < client_preface.len) return null;
    assert(n == client_preface.len);
    assert(std.mem.startsWith(u8, input, client_preface));
    return client_preface.len;
}

pub fn parse_frame_header(bytes: *const [frame_header_bytes]u8) FrameHeader {
    return .{
        .length = std.mem.readInt(u24, bytes[0..3], .big),
        .type = @enumFromInt(bytes[3]),
        .flags = bytes[4],
        // @truncate keeps the low 31 bits — the reserved bit is masked (§4.1).
        .stream_id = @truncate(std.mem.readInt(u32, bytes[5..9], .big)),
    };
}

pub fn write_frame_header(header: FrameHeader, out: *[frame_header_bytes]u8) void {
    // We never send a frame larger than the size we ourselves advertise.
    assert(header.length <= constants.h2_frame_payload_bytes_max);
    std.mem.writeInt(u24, out[0..3], header.length, .big);
    out[3] = @intFromEnum(header.type);
    out[4] = header.flags;
    std.mem.writeInt(u32, out[5..9], header.stream_id, .big);
    assert(out[5] & 0x80 == 0); // the reserved bit is never set on the wire
}

/// Parse one frame from the start of `input`. Null means incomplete — read
/// more and call again. The header is validated as soon as its 9 bytes are
/// present, so an oversize or malformed frame fails before its payload
/// arrives. Bytes past the returned frame belong to the next frame.
pub fn parse_frame(input: []const u8) FrameError!?Frame {
    if (input.len < frame_header_bytes) return null;
    const header = parse_frame_header(input[0..frame_header_bytes]);
    if (header.length > constants.h2_frame_payload_bytes_max) return error.FrameTooLarge;
    try validate_header(header);
    const total: usize = frame_header_bytes + header.length;
    if (input.len < total) return null;
    assert(total >= frame_header_bytes);
    const frame = Frame{ .header = header, .payload = input[frame_header_bytes..total] };
    assert(frame.payload.len == header.length);
    return frame;
}

/// The context-free structural rules of RFC 9113 §6: which stream ids a type
/// permits and which payload lengths. Rules that need connection or stream
/// state (SETTINGS timing, CONTINUATION adjacency, …) are not checked here.
fn validate_header(header: FrameHeader) FrameError!void {
    assert(header.length <= constants.h2_frame_payload_bytes_max);
    switch (header.type) {
        .data, .headers, .continuation => {
            if (header.stream_id == 0) return error.Protocol;
        },
        .priority => {
            if (header.stream_id == 0) return error.Protocol;
            if (header.length != 5) return error.InvalidLength;
        },
        .rst_stream => {
            if (header.stream_id == 0) return error.Protocol;
            if (header.length != 4) return error.InvalidLength;
        },
        .settings => {
            if (header.stream_id != 0) return error.Protocol;
            if (header.flags & Flags.ack != 0) {
                if (header.length != 0) return error.InvalidLength;
            } else if (header.length % setting_entry_bytes != 0) {
                return error.InvalidLength;
            }
        },
        .push_promise => {
            if (header.stream_id == 0) return error.Protocol;
        },
        .ping => {
            if (header.stream_id != 0) return error.Protocol;
            if (header.length != 8) return error.InvalidLength;
        },
        .goaway => {
            if (header.stream_id != 0) return error.Protocol;
            if (header.length < 8) return error.InvalidLength;
        },
        .window_update => {
            if (header.length != 4) return error.InvalidLength;
        },
        _ => {}, // unknown types carry no rules; the caller skips the payload
    }
}

// ---- SETTINGS (RFC 9113 §6.5) ----------------------------------------------

/// Setting identifiers. Non-exhaustive: unknown identifiers must be ignored
/// (RFC 9113 §6.5.2).
pub const SettingId = enum(u16) {
    header_table_size = 0x1,
    enable_push = 0x2,
    max_concurrent_streams = 0x3,
    initial_window_size = 0x4,
    max_frame_size = 0x5,
    max_header_list_size = 0x6,
    _,
};

pub const Setting = struct {
    id: SettingId,
    value: u32,
};

/// The peer's settings, mutated by each non-ACK SETTINGS frame. Defaults per
/// RFC 9113 §6.5.2. These are the peer's *declared* values; what we reserve
/// and enforce for ourselves comes from `constants.zig`, never from here.
pub const Settings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = true,
    /// Null means unlimited (the peer never declared a limit).
    max_concurrent_streams: ?u32 = null,
    initial_window_size: u31 = 65535,
    max_frame_size: u24 = frame_size_floor,
    /// Null means unlimited (advisory; RFC 9113 §6.5.2).
    max_header_list_size: ?u32 = null,

    /// Apply a SETTINGS payload. The caller has already validated the frame
    /// through `parse_frame` (stream 0, non-ACK, length a multiple of 6).
    /// Unknown identifiers are ignored; invalid values are connection errors.
    pub fn apply(settings: *Settings, payload: []const u8) FrameError!void {
        assert(payload.len % setting_entry_bytes == 0);
        assert(payload.len <= constants.h2_frame_payload_bytes_max);
        var offset: usize = 0;
        // Bounded by the frame-size cap: at most max/6 entries.
        while (offset < payload.len) : (offset += setting_entry_bytes) {
            const id = std.mem.readInt(u16, payload[offset..][0..2], .big);
            const value = std.mem.readInt(u32, payload[offset + 2 ..][0..4], .big);
            try settings.set(@enumFromInt(id), value);
        }
    }

    fn set(settings: *Settings, id: SettingId, value: u32) FrameError!void {
        switch (id) {
            .header_table_size => settings.header_table_size = value,
            .enable_push => switch (value) {
                0 => settings.enable_push = false,
                1 => settings.enable_push = true,
                else => return error.Protocol,
            },
            .max_concurrent_streams => settings.max_concurrent_streams = value,
            .initial_window_size => {
                if (value > std.math.maxInt(u31)) return error.FlowControl;
                settings.initial_window_size = @intCast(value);
            },
            .max_frame_size => {
                if (value < frame_size_floor or value > frame_size_ceiling) {
                    return error.Protocol;
                }
                settings.max_frame_size = @intCast(value);
            },
            .max_header_list_size => settings.max_header_list_size = value,
            _ => {}, // unknown identifiers are ignored (§6.5.2)
        }
    }
};

/// Encode a SETTINGS frame carrying `entries`; returns the wire length.
pub fn write_settings(entries: []const Setting, out: []u8) usize {
    const payload_len = entries.len * setting_entry_bytes;
    assert(payload_len <= constants.h2_frame_payload_bytes_max);
    const total = frame_header_bytes + payload_len;
    assert(out.len >= total);
    write_frame_header(.{
        .length = @intCast(payload_len),
        .type = .settings,
        .flags = 0,
        .stream_id = 0,
    }, out[0..frame_header_bytes]);
    for (entries, 0..) |entry, i| {
        const offset = frame_header_bytes + i * setting_entry_bytes;
        std.mem.writeInt(u16, out[offset..][0..2], @intFromEnum(entry.id), .big);
        std.mem.writeInt(u32, out[offset + 2 ..][0..4], entry.value, .big);
    }
    return total;
}

pub fn write_settings_ack(out: *[frame_header_bytes]u8) void {
    write_frame_header(
        .{ .length = 0, .type = .settings, .flags = Flags.ack, .stream_id = 0 },
        out,
    );
}

// ---- fixed-shape payloads (PING, RST_STREAM, GOAWAY, WINDOW_UPDATE) --------

pub const ping_frame_bytes = frame_header_bytes + 8;

/// Encode a PING (or its ACK — same 8 opaque bytes echoed back, §6.7).
pub fn write_ping(data: *const [8]u8, ack: bool, out: *[ping_frame_bytes]u8) void {
    write_frame_header(.{
        .length = 8,
        .type = .ping,
        .flags = if (ack) Flags.ack else 0,
        .stream_id = 0,
    }, out[0..frame_header_bytes]);
    @memcpy(out[frame_header_bytes..], data);
}

pub const rst_stream_frame_bytes = frame_header_bytes + 4;

pub fn write_rst_stream(stream_id: u31, code: ErrorCode, out: *[rst_stream_frame_bytes]u8) void {
    assert(stream_id != 0); // RST_STREAM is always stream-scoped (§6.4)
    write_frame_header(
        .{ .length = 4, .type = .rst_stream, .flags = 0, .stream_id = stream_id },
        out[0..frame_header_bytes],
    );
    std.mem.writeInt(u32, out[frame_header_bytes..], @intFromEnum(code), .big);
}

/// The RST_STREAM payload: the error code (§6.4).
pub fn parse_rst_stream(payload: *const [4]u8) ErrorCode {
    return @enumFromInt(std.mem.readInt(u32, payload, .big));
}

pub const goaway_frame_bytes = frame_header_bytes + 8;

/// Encode a GOAWAY without debug data (we never send any).
pub fn write_goaway(last_stream_id: u31, code: ErrorCode, out: *[goaway_frame_bytes]u8) void {
    write_frame_header(
        .{ .length = 8, .type = .goaway, .flags = 0, .stream_id = 0 },
        out[0..frame_header_bytes],
    );
    std.mem.writeInt(u32, out[frame_header_bytes..][0..4], last_stream_id, .big);
    std.mem.writeInt(u32, out[frame_header_bytes + 4 ..][0..4], @intFromEnum(code), .big);
}

pub const GoAway = struct {
    last_stream_id: u31,
    code: ErrorCode,
    debug_data: []const u8,
};

/// The GOAWAY payload (§6.8); `parse_frame` already guaranteed length >= 8.
pub fn parse_goaway(payload: []const u8) GoAway {
    assert(payload.len >= 8);
    return .{
        .last_stream_id = @truncate(std.mem.readInt(u32, payload[0..4], .big)),
        .code = @enumFromInt(std.mem.readInt(u32, payload[4..8], .big)),
        .debug_data = payload[8..],
    };
}

pub const window_update_frame_bytes = frame_header_bytes + 4;

pub fn write_window_update(
    stream_id: u31,
    increment: u31,
    out: *[window_update_frame_bytes]u8,
) void {
    assert(increment > 0); // a zero increment is a protocol error to send (§6.9)
    write_frame_header(
        .{ .length = 4, .type = .window_update, .flags = 0, .stream_id = stream_id },
        out[0..frame_header_bytes],
    );
    std.mem.writeInt(u32, out[frame_header_bytes..], increment, .big);
}

/// The WINDOW_UPDATE increment, reserved bit masked. Zero is a protocol
/// error (§6.9) — whether it kills the stream or the connection depends on
/// the frame's stream id; that mapping is the caller's.
pub fn parse_window_update(payload: *const [4]u8) FrameError!u31 {
    const increment: u31 = @truncate(std.mem.readInt(u32, payload, .big));
    if (increment == 0) return error.Protocol;
    assert(increment <= std.math.maxInt(u31));
    return increment;
}

// ---- tests ----------------------------------------------------------------

/// Build a raw frame header, including shapes `write_frame_header` refuses
/// to produce (oversize lengths, reserved bit set).
fn raw_header(length: u24, frame_type: u8, flags: u8, stream_id: u32) [frame_header_bytes]u8 {
    var bytes: [frame_header_bytes]u8 = undefined;
    std.mem.writeInt(u24, bytes[0..3], length, .big);
    bytes[3] = frame_type;
    bytes[4] = flags;
    std.mem.writeInt(u32, bytes[5..9], stream_id, .big);
    return bytes;
}

test "h2 frame: preface matches incrementally and fails fast" {
    try std.testing.expectEqual(@as(?usize, 24), try check_preface(client_preface));
    try std.testing.expectEqual(@as(?usize, null), try check_preface(client_preface[0..10]));
    try std.testing.expectEqual(@as(?usize, null), try check_preface(""));
    // Bytes after the preface do not disturb the match.
    try std.testing.expectEqual(@as(?usize, 24), try check_preface(client_preface ++ "\x00\x00"));
    // A wrong byte fails immediately — an HTTP/1.1 client is detected at byte one.
    try std.testing.expectError(error.Malformed, check_preface("GET / HTTP/1.1\r\n"));
    try std.testing.expectError(error.Malformed, check_preface("PRI * HTTP/2.1"));
}

test "h2 frame: header round-trips through write and parse" {
    var bytes: [frame_header_bytes]u8 = undefined;
    const header = FrameHeader{
        .length = constants.h2_frame_payload_bytes_max,
        .type = .headers,
        .flags = Flags.end_headers | Flags.end_stream,
        .stream_id = std.math.maxInt(u31),
    };
    write_frame_header(header, &bytes);
    try std.testing.expectEqual(header, parse_frame_header(&bytes));
}

test "h2 frame: the reserved stream-id bit is masked on parse" {
    const bytes = raw_header(0, 0x6, 0, 0x8000_0001); // R bit + stream 1
    const header = parse_frame_header(&bytes);
    try std.testing.expectEqual(@as(u31, 1), header.stream_id);
}

test "h2 frame: incomplete input asks for more, byte by byte" {
    var wire: [ping_frame_bytes]u8 = undefined;
    write_ping(&.{ 1, 2, 3, 4, 5, 6, 7, 8 }, false, &wire);
    for (0..wire.len) |n| {
        try std.testing.expect((try parse_frame(wire[0..n])) == null);
    }
    const frame = (try parse_frame(&wire)).?;
    try std.testing.expectEqual(FrameType.ping, frame.header.type);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, frame.payload);
}

test "h2 frame: consecutive frames are delimited by wire_bytes" {
    var wire: [frame_header_bytes + ping_frame_bytes]u8 = undefined;
    write_settings_ack(wire[0..frame_header_bytes]);
    write_ping(&([_]u8{0} ** 8), true, wire[frame_header_bytes..]);

    const first = (try parse_frame(&wire)).?;
    try std.testing.expectEqual(FrameType.settings, first.header.type);
    try std.testing.expect(first.header.flags & Flags.ack != 0);

    const second = (try parse_frame(wire[first.wire_bytes()..])).?;
    try std.testing.expectEqual(FrameType.ping, second.header.type);
    try std.testing.expect(second.header.flags & Flags.ack != 0);
    try std.testing.expectEqual(wire.len, first.wire_bytes() + second.wire_bytes());
}

test "h2 frame: oversize frames fail on the header alone" {
    const bytes = raw_header(constants.h2_frame_payload_bytes_max + 1, 0x0, 0, 1);
    // No payload present — the length field is enough to reject.
    try std.testing.expectError(error.FrameTooLarge, parse_frame(&bytes));
}

test "h2 frame: stream-id rules per type" {
    // DATA, HEADERS, CONTINUATION, RST_STREAM, PRIORITY, PUSH_PROMISE: never stream 0.
    try std.testing.expectError(error.Protocol, parse_frame(&raw_header(0, 0x0, 0, 0)));
    try std.testing.expectError(error.Protocol, parse_frame(&raw_header(0, 0x1, 0, 0)));
    try std.testing.expectError(error.Protocol, parse_frame(&raw_header(0, 0x9, 0, 0)));
    try std.testing.expectError(error.Protocol, parse_frame(&raw_header(4, 0x3, 0, 0)));
    try std.testing.expectError(error.Protocol, parse_frame(&raw_header(5, 0x2, 0, 0)));
    try std.testing.expectError(error.Protocol, parse_frame(&raw_header(4, 0x5, 0, 0)));
    // SETTINGS, PING, GOAWAY: only stream 0.
    try std.testing.expectError(error.Protocol, parse_frame(&raw_header(0, 0x4, 0, 1)));
    try std.testing.expectError(error.Protocol, parse_frame(&raw_header(8, 0x6, 0, 1)));
    try std.testing.expectError(error.Protocol, parse_frame(&raw_header(8, 0x7, 0, 1)));
}

test "h2 frame: fixed payload lengths per type" {
    try std.testing.expectError(error.InvalidLength, parse_frame(&raw_header(7, 0x6, 0, 0)));
    try std.testing.expectError(error.InvalidLength, parse_frame(&raw_header(3, 0x3, 0, 1)));
    try std.testing.expectError(error.InvalidLength, parse_frame(&raw_header(4, 0x2, 0, 1)));
    try std.testing.expectError(error.InvalidLength, parse_frame(&raw_header(5, 0x8, 0, 0)));
    try std.testing.expectError(error.InvalidLength, parse_frame(&raw_header(4, 0x7, 0, 0)));
    // SETTINGS: a multiple of 6, and an ACK carries no payload.
    try std.testing.expectError(error.InvalidLength, parse_frame(&raw_header(5, 0x4, 0, 0)));
    try std.testing.expectError(
        error.InvalidLength,
        parse_frame(&raw_header(6, 0x4, Flags.ack, 0)),
    );
}

test "h2 frame: unknown frame types parse and are skippable" {
    var wire: [frame_header_bytes + 3]u8 = undefined;
    wire[0..frame_header_bytes].* = raw_header(3, 0xff, 0xaa, 7);
    @memcpy(wire[frame_header_bytes..], "xyz");
    const frame = (try parse_frame(&wire)).?;
    try std.testing.expectEqual(@as(u8, 0xff), @intFromEnum(frame.header.type));
    try std.testing.expectEqualStrings("xyz", frame.payload);
    try std.testing.expectEqual(wire.len, frame.wire_bytes());
}

test "h2 frame: settings defaults match RFC 9113 section 6.5.2" {
    const settings = Settings{};
    try std.testing.expectEqual(@as(u32, 4096), settings.header_table_size);
    try std.testing.expect(settings.enable_push);
    try std.testing.expectEqual(@as(?u32, null), settings.max_concurrent_streams);
    try std.testing.expectEqual(@as(u31, 65535), settings.initial_window_size);
    try std.testing.expectEqual(frame_size_floor, settings.max_frame_size);
    try std.testing.expectEqual(@as(?u32, null), settings.max_header_list_size);
}

test "h2 frame: settings round-trip through write, parse, and apply" {
    var wire: [128]u8 = undefined;
    const len = write_settings(&.{
        .{ .id = .header_table_size, .value = 0 },
        .{ .id = .max_concurrent_streams, .value = 128 },
        .{ .id = .initial_window_size, .value = 16384 },
        .{ .id = .max_frame_size, .value = 65536 },
        .{ .id = @enumFromInt(0x99), .value = 1 }, // unknown: must be ignored
    }, &wire);
    try std.testing.expectEqual(frame_header_bytes + 5 * setting_entry_bytes, len);

    const frame = (try parse_frame(wire[0..len])).?;
    try std.testing.expectEqual(FrameType.settings, frame.header.type);
    try std.testing.expect(frame.header.flags & Flags.ack == 0);

    var settings = Settings{};
    try settings.apply(frame.payload);
    try std.testing.expectEqual(@as(u32, 0), settings.header_table_size);
    try std.testing.expectEqual(@as(?u32, 128), settings.max_concurrent_streams);
    try std.testing.expectEqual(@as(u31, 16384), settings.initial_window_size);
    try std.testing.expectEqual(@as(u24, 65536), settings.max_frame_size);
}

test "h2 frame: settings rejects invalid values" {
    var settings = Settings{};
    var wire: [64]u8 = undefined;

    var len = write_settings(&.{.{ .id = .enable_push, .value = 2 }}, &wire);
    var frame = (try parse_frame(wire[0..len])).?;
    try std.testing.expectError(error.Protocol, settings.apply(frame.payload));

    len = write_settings(&.{.{ .id = .initial_window_size, .value = 1 << 31 }}, &wire);
    frame = (try parse_frame(wire[0..len])).?;
    try std.testing.expectError(error.FlowControl, settings.apply(frame.payload));

    len = write_settings(&.{.{ .id = .max_frame_size, .value = frame_size_floor - 1 }}, &wire);
    frame = (try parse_frame(wire[0..len])).?;
    try std.testing.expectError(error.Protocol, settings.apply(frame.payload));

    len = write_settings(&.{.{ .id = .max_frame_size, .value = 1 << 24 }}, &wire);
    frame = (try parse_frame(wire[0..len])).?;
    try std.testing.expectError(error.Protocol, settings.apply(frame.payload));
}

test "h2 frame: rst_stream, goaway, and window_update round-trip" {
    var rst: [rst_stream_frame_bytes]u8 = undefined;
    write_rst_stream(9, .refused_stream, &rst);
    const rst_frame = (try parse_frame(&rst)).?;
    try std.testing.expectEqual(@as(u31, 9), rst_frame.header.stream_id);
    try std.testing.expectEqual(
        ErrorCode.refused_stream,
        parse_rst_stream(rst_frame.payload[0..4]),
    );

    var goaway: [goaway_frame_bytes]u8 = undefined;
    write_goaway(41, .no_error, &goaway);
    const goaway_frame = (try parse_frame(&goaway)).?;
    const parsed = parse_goaway(goaway_frame.payload);
    try std.testing.expectEqual(@as(u31, 41), parsed.last_stream_id);
    try std.testing.expectEqual(ErrorCode.no_error, parsed.code);
    try std.testing.expectEqual(@as(usize, 0), parsed.debug_data.len);

    var update: [window_update_frame_bytes]u8 = undefined;
    write_window_update(0, 65535, &update);
    const update_frame = (try parse_frame(&update)).?;
    try std.testing.expectEqual(
        @as(u31, 65535),
        try parse_window_update(update_frame.payload[0..4]),
    );
}

test "h2 frame: goaway with debug data and unknown error codes" {
    var wire: [frame_header_bytes + 8 + 5]u8 = undefined;
    wire[0..frame_header_bytes].* = raw_header(13, 0x7, 0, 0);
    std.mem.writeInt(u32, wire[frame_header_bytes..][0..4], 0x8000_0007, .big); // R bit set
    std.mem.writeInt(u32, wire[frame_header_bytes + 4 ..][0..4], 0xdead_beef, .big);
    @memcpy(wire[frame_header_bytes + 8 ..], "debug");
    const frame = (try parse_frame(&wire)).?;
    const parsed = parse_goaway(frame.payload);
    try std.testing.expectEqual(@as(u31, 7), parsed.last_stream_id); // R bit masked
    try std.testing.expectEqual(@as(u32, 0xdead_beef), @intFromEnum(parsed.code));
    try std.testing.expectEqualStrings("debug", parsed.debug_data);
}

test "h2 frame: a zero window increment is a protocol error" {
    const payload = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.Protocol, parse_window_update(&payload));
    // The reserved bit alone does not make the increment nonzero.
    const reserved_only = [_]u8{ 0x80, 0, 0, 0 };
    try std.testing.expectError(error.Protocol, parse_window_update(&reserved_only));
}

test "h2 frame: codec errors map to their RFC 9113 error codes" {
    try std.testing.expectEqual(ErrorCode.frame_size_error, error_code(error.FrameTooLarge));
    try std.testing.expectEqual(ErrorCode.frame_size_error, error_code(error.InvalidLength));
    try std.testing.expectEqual(ErrorCode.protocol_error, error_code(error.Protocol));
    try std.testing.expectEqual(ErrorCode.flow_control_error, error_code(error.FlowControl));
}
