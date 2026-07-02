//! Zero-copy HTTP/1.1 request-head parser. Every field is a slice into the
//! caller's input buffer — nothing is copied or allocated (docs/DESIGN.md §5).
//! The parser re-runs from the start on each call (picohttpparser style): feed
//! it the bytes received so far; `.incomplete` means "call again with more".
//! Header lines land in a caller-provided fixed array, so a request that exceeds
//! it is rejected (431) rather than growing.

const std = @import("std");
const assert = std.debug.assert;

pub const Method = enum { get, head, post, put, delete, patch, options, connect, trace, other };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
    /// The raw header line including its terminating CRLF, as a slice of the
    /// input — lets a forwarder skip or splice whole lines without copying.
    line: []const u8 = "",
};

/// A parsed request head. All slices point into the input buffer and are valid
/// only while that buffer is unmodified.
pub const Request = struct {
    method: Method,
    method_text: []const u8,
    target: []const u8,
    /// Minor version: 0 for HTTP/1.0, 1 for HTTP/1.1.
    version_minor: u8,
    headers: []const Header,
    /// Bytes consumed by the head, including the terminating CRLF CRLF. The
    /// body (if any) begins at `input[head_len..]`.
    head_len: usize,

    /// Case-insensitive header lookup; returns the first match.
    pub fn header(request: *const Request, name: []const u8) ?[]const u8 {
        return findHeader(request.headers, name);
    }

    pub fn host(request: *const Request) ?[]const u8 {
        return request.header("host");
    }
};

/// A parsed response head. All slices point into the input buffer and are
/// valid only while that buffer is unmodified. The reason phrase is ignored.
pub const Response = struct {
    status: u16,
    /// Minor version: 0 for HTTP/1.0, 1 for HTTP/1.1.
    version_minor: u8,
    headers: []const Header,
    /// Bytes consumed by the head, including the terminating CRLF CRLF. The
    /// body (if any) begins at `input[head_len..]`.
    head_len: usize,

    /// Case-insensitive header lookup; returns the first match.
    pub fn header(response: *const Response, name: []const u8) ?[]const u8 {
        return findHeader(response.headers, name);
    }
};

pub const ParseError = error{
    /// Syntactically invalid — respond 400.
    Malformed,
    /// More header lines than the caller's array holds — respond 431.
    TooManyHeaders,
    /// Not HTTP/1.0 or HTTP/1.1 — respond 505.
    UnsupportedVersion,
};

pub const Parsed = union(enum) {
    complete: Request,
    /// The head is not yet fully present; read more and parse again.
    incomplete,
};

pub const ParsedResponse = union(enum) {
    complete: Response,
    /// The head is not yet fully present; read more and parse again.
    incomplete,
};

/// Parse a request head out of `input`, filling `headers` with header lines.
pub fn parse(input: []const u8, headers: []Header) ParseError!Parsed {
    assert(headers.len > 0);
    var pos: usize = 0;

    const request_line = readLine(input, &pos) orelse return .incomplete;
    const line = try parseRequestLine(request_line);

    const count = (try readHeaders(input, &pos, headers)) orelse return .incomplete;
    assert(count <= headers.len);
    assert(pos <= input.len);
    return .{ .complete = .{
        .method = line.method,
        .method_text = line.method_text,
        .target = line.target,
        .version_minor = line.version_minor,
        .headers = headers[0..count],
        .head_len = pos,
    } };
}

/// Parse a response head out of `input`, filling `headers` with header lines.
pub fn parseResponse(input: []const u8, headers: []Header) ParseError!ParsedResponse {
    assert(headers.len > 0);
    var pos: usize = 0;

    const status_line = readLine(input, &pos) orelse return .incomplete;
    const line = try parseStatusLine(status_line);

    const count = (try readHeaders(input, &pos, headers)) orelse return .incomplete;
    assert(count <= headers.len);
    assert(pos <= input.len);
    return .{ .complete = .{
        .status = line.status,
        .version_minor = line.version_minor,
        .headers = headers[0..count],
        .head_len = pos,
    } };
}

/// Read header lines up to and including the blank line, returning how many
/// were stored. Null means the head is not yet complete.
fn readHeaders(input: []const u8, pos: *usize, headers: []Header) ParseError!?usize {
    var count: usize = 0;
    while (true) {
        const line_start = pos.*;
        const header_line = readLine(input, pos) orelse return null;
        if (header_line.len == 0) return count; // blank line terminates the head
        if (count == headers.len) return error.TooManyHeaders;
        headers[count] = try parseHeader(header_line);
        headers[count].line = input[line_start..pos.*];
        count += 1;
    }
}

/// Case-insensitive lookup over parsed headers; returns the first match.
fn findHeader(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

const RequestLine = struct {
    method: Method,
    method_text: []const u8,
    target: []const u8,
    version_minor: u8,
};

fn parseRequestLine(line: []const u8) ParseError!RequestLine {
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return error.Malformed;
    const method_text = line[0..sp1];
    if (method_text.len == 0 or !isToken(method_text)) return error.Malformed;
    assert(method_text.len > 0); // negative space: rejected above

    const after_method = line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, after_method, ' ') orelse return error.Malformed;
    const target = after_method[0..sp2];
    if (target.len == 0 or !isTargetText(target)) return error.Malformed;
    assert(target.len > 0);

    return .{
        .method = methodFromText(method_text),
        .method_text = method_text,
        .target = target,
        .version_minor = try parseVersion(after_method[sp2 + 1 ..]),
    };
}

const StatusLine = struct {
    status: u16,
    version_minor: u8,
};

/// Parse "HTTP/1.x NNN[ reason]". The reason phrase may be absent (some
/// servers send none) and is ignored either way.
fn parseStatusLine(line: []const u8) ParseError!StatusLine {
    const version_len = "HTTP/1.1".len;
    if (line.len < version_len + 4) return error.Malformed; // SP + three digits
    const version_minor = try parseVersion(line[0..version_len]);
    if (line[version_len] != ' ') return error.Malformed;
    var status: u16 = 0;
    for (line[version_len + 1 ..][0..3]) |c| {
        if (c < '0' or c > '9') return error.Malformed;
        status = status * 10 + (c - '0');
    }
    if (status < 100) return error.Malformed;
    assert(status <= 999); // three digits
    // Anything after the code must be a space-separated reason phrase.
    if (line.len > version_len + 4 and line[version_len + 4] != ' ') return error.Malformed;
    return .{ .status = status, .version_minor = version_minor };
}

fn parseVersion(version: []const u8) ParseError!u8 {
    const prefix = "HTTP/";
    if (!std.mem.startsWith(u8, version, prefix)) return error.Malformed;
    const v = version[prefix.len..];
    if (v.len != 3 or v[1] != '.') return error.Malformed;
    assert(v.len == 3);
    if (v[0] != '1') return error.UnsupportedVersion;
    return switch (v[2]) {
        '0' => 0,
        '1' => 1,
        else => error.UnsupportedVersion,
    };
}

fn parseHeader(line: []const u8) ParseError!Header {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Malformed;
    const name = line[0..colon];
    // A token name with no whitespace blocks header-smuggling tricks.
    if (name.len == 0 or !isToken(name)) return error.Malformed;
    assert(name.len > 0);
    return .{ .name = name, .value = trimOws(line[colon + 1 ..]) };
}

fn methodFromText(text: []const u8) Method {
    const map = std.StaticStringMap(Method).initComptime(.{
        .{ "GET", .get },
        .{ "HEAD", .head },
        .{ "POST", .post },
        .{ "PUT", .put },
        .{ "DELETE", .delete },
        .{ "PATCH", .patch },
        .{ "OPTIONS", .options },
        .{ "CONNECT", .connect },
        .{ "TRACE", .trace },
    });
    return map.get(text) orelse .other;
}

/// Read one CRLF-terminated line, advancing `pos` past the CRLF. Returns null
/// (incomplete) if no CRLF is present yet. The returned slice excludes the CRLF.
fn readLine(input: []const u8, pos: *usize) ?[]const u8 {
    assert(pos.* <= input.len);
    const start = pos.*;
    var i = start;
    while (i + 1 < input.len) : (i += 1) {
        if (input[i] == '\r' and input[i + 1] == '\n') {
            pos.* = i + 2;
            return input[start..i];
        }
    }
    return null;
}

/// RFC 9110 token characters: DIGIT / ALPHA / "!#$%&'*+-.^_`|~". Everything
/// else — separators, whitespace, control bytes, high-bit bytes — is out.
const token_chars: [256]bool = blk: {
    var table = [_]bool{false} ** 256;
    for ("!#$%&'*+-.^_`|~") |c| table[c] = true;
    for ('0'..'9' + 1) |c| table[c] = true;
    for ('a'..'z' + 1) |c| table[c] = true;
    for ('A'..'Z' + 1) |c| table[c] = true;
    break :blk table;
};

/// True if every byte is an RFC 9110 token character. A strict charset for
/// methods and header names keeps smuggling tricks (and bytes an upstream
/// might interpret differently than we do) out of the forwarded head.
fn isToken(s: []const u8) bool {
    for (s) |c| {
        if (!token_chars[c]) return false;
    }
    return true;
}

/// True if every byte may appear in a request target: visible ASCII plus
/// high-bit bytes (lenient toward raw i18n URLs); controls are rejected.
fn isTargetText(s: []const u8) bool {
    for (s) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// Trim optional leading/trailing whitespace (spaces and tabs) per RFC 9110 OWS.
fn trimOws(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) start += 1;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    assert(start <= end);
    assert(end <= s.len);
    return s[start..end];
}

// ---- tests ----------------------------------------------------------------

test "h1: parses a complete request with headers" {
    var headers: [8]Header = undefined;
    const raw = "GET /path?q=1 HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\nBODYBYTES";
    const parsed = try parse(raw, &headers);

    const req = parsed.complete;
    try std.testing.expectEqual(Method.get, req.method);
    try std.testing.expectEqualStrings("GET", req.method_text);
    try std.testing.expectEqualStrings("/path?q=1", req.target);
    try std.testing.expectEqual(@as(u8, 1), req.version_minor);
    try std.testing.expectEqual(@as(usize, 2), req.headers.len);
    try std.testing.expectEqualStrings("example.com", req.host().?);
    try std.testing.expectEqualStrings("*/*", req.header("accept").?);
    // Case-insensitive lookup, and body is left unconsumed.
    try std.testing.expectEqualStrings("example.com", req.header("HOST").?);
    try std.testing.expectEqualStrings("BODYBYTES", raw[req.head_len..]);
}

test "h1: header lines expose their raw span including the CRLF" {
    var headers: [4]Header = undefined;
    const raw = "GET / HTTP/1.1\r\nHost: x\r\nAccept: */*\r\n\r\n";
    const req = (try parse(raw, &headers)).complete;
    try std.testing.expectEqualStrings("Host: x\r\n", req.headers[0].line);
    try std.testing.expectEqualStrings("Accept: */*\r\n", req.headers[1].line);
}

test "h1: trims OWS around header values" {
    var headers: [4]Header = undefined;
    const parsed = try parse("GET / HTTP/1.1\r\nHost: \t example.com \t \r\n\r\n", &headers);
    try std.testing.expectEqualStrings("example.com", parsed.complete.host().?);
}

test "h1: incomplete input asks for more" {
    var headers: [4]Header = undefined;
    try std.testing.expectEqual(
        Parsed.incomplete,
        try parse("GET / HTTP/1.1\r\nHost: x\r\n", &headers),
    );
    try std.testing.expectEqual(Parsed.incomplete, try parse("GET / HTT", &headers));
    try std.testing.expectEqual(Parsed.incomplete, try parse("", &headers));
}

test "h1: rejects malformed requests" {
    var headers: [8]Header = undefined;
    try std.testing.expectError(error.Malformed, parse("GET\r\n\r\n", &headers));
    try std.testing.expectError(error.Malformed, parse("GET /\r\n\r\n", &headers));
    try std.testing.expectError(
        error.Malformed,
        parse("GET / HTTP/1.1\r\nBadHeader\r\n\r\n", &headers),
    );
    try std.testing.expectError(
        error.Malformed,
        parse("GET / HTTP/1.1\r\nBad Name: v\r\n\r\n", &headers),
    );
    try std.testing.expectError(error.Malformed, parse("GET / WHAT/1.1\r\n\r\n", &headers));
}

test "h1: rejects non-token bytes in method and header names" {
    var headers: [4]Header = undefined;
    // Separators and high-bit bytes are not RFC 9110 token characters.
    try std.testing.expectError(error.Malformed, parse("GE\"T / HTTP/1.1\r\n\r\n", &headers));
    try std.testing.expectError(
        error.Malformed,
        parse("GET / HTTP/1.1\r\nX(y: v\r\n\r\n", &headers),
    );
    try std.testing.expectError(
        error.Malformed,
        parse("GET / HTTP/1.1\r\nX\xffy: v\r\n\r\n", &headers),
    );
    // Control bytes in the target are rejected; high-bit bytes are tolerated.
    try std.testing.expectError(error.Malformed, parse("GET /\x01 HTTP/1.1\r\n\r\n", &headers));
    _ = try parse("GET /\xc3\xa9 HTTP/1.1\r\n\r\n", &headers);
}

test "h1: rejects unsupported versions" {
    var headers: [4]Header = undefined;
    try std.testing.expectError(
        error.UnsupportedVersion,
        parse("GET / HTTP/2.0\r\n\r\n", &headers),
    );
    try std.testing.expectError(
        error.UnsupportedVersion,
        parse("GET / HTTP/1.9\r\n\r\n", &headers),
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        (try parse("GET / HTTP/1.0\r\n\r\n", &headers)).complete.version_minor,
    );
}

test "h1: parses a complete response head" {
    var headers: [8]Header = undefined;
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nHELLO";
    const response = (try parseResponse(raw, &headers)).complete;
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqual(@as(u8, 1), response.version_minor);
    try std.testing.expectEqualStrings("5", response.header("content-length").?);
    try std.testing.expectEqualStrings("HELLO", raw[response.head_len..]);
}

test "h1: response reason phrase is optional and may contain spaces" {
    var headers: [4]Header = undefined;
    const no_reason = (try parseResponse("HTTP/1.1 204\r\n\r\n", &headers)).complete;
    try std.testing.expectEqual(@as(u16, 204), no_reason.status);
    const spaced = (try parseResponse("HTTP/1.0 404 Not Found\r\n\r\n", &headers)).complete;
    try std.testing.expectEqual(@as(u16, 404), spaced.status);
    try std.testing.expectEqual(@as(u8, 0), spaced.version_minor);
}

test "h1: incomplete response asks for more" {
    var headers: [4]Header = undefined;
    try std.testing.expectEqual(
        ParsedResponse.incomplete,
        try parseResponse("HTTP/1.1 200 OK\r\nA: b\r\n", &headers),
    );
    try std.testing.expectEqual(ParsedResponse.incomplete, try parseResponse("HTTP/1.", &headers));
}

test "h1: rejects malformed and unsupported responses" {
    var headers: [4]Header = undefined;
    try std.testing.expectError(error.Malformed, parseResponse("HTTP/1.1 20\r\n\r\n", &headers));
    try std.testing.expectError(error.Malformed, parseResponse("HTTP/1.1 2x0\r\n\r\n", &headers));
    try std.testing.expectError(error.Malformed, parseResponse("HTTP/1.1 099\r\n\r\n", &headers));
    try std.testing.expectError(error.Malformed, parseResponse("HTTP/1.1 200OK\r\n\r\n", &headers));
    try std.testing.expectError(error.Malformed, parseResponse("ICY 200 OK\r\n\r\n", &headers));
    try std.testing.expectError(
        error.UnsupportedVersion,
        parseResponse("HTTP/2.0 200 OK\r\n\r\n", &headers),
    );
}

test "h1: rejects too many headers" {
    var one: [1]Header = undefined;
    try std.testing.expectError(
        error.TooManyHeaders,
        parse("GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n", &one),
    );
}
