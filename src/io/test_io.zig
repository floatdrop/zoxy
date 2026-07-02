//! Deterministic simulation IO backend (docs/DESIGN.md: "swappable IO ->
//! deterministic testing"; TigerBeetle's VOPR idea). Same API surface as the
//! io_uring backend, but nothing touches the kernel: sockets are in-memory
//! byte pipes, the clock is virtual, and every completion is chosen by a
//! seeded PRNG — one pending operation at a time, with adversarial partial
//! reads and writes. A given seed replays the exact same schedule.
//!
//! Faithfulness notes (these catch real bug classes):
//! - Completing an op advances the virtual clock a little; when nothing is
//!   ready the clock jumps to the earliest timer. No timers and nothing
//!   ready means the system is stuck: `error.WouldBlockForever`.
//! - `close`/`close_now` do NOT complete ops already pending on the fd —
//!   exactly like io_uring — so a missing `shutdown_socket` before close
//!   surfaces as a detected deadlock instead of passing silently.
//! - A send blocks (stays pending) while the peer's buffer is full: bounded
//!   buffers push backpressure exactly like TCP flow control.
//! - Socket slots are never reused within one IO instance, so a stale fd is
//!   a hang or an assert, never a silent redirect.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const assert = std.debug.assert;

/// Virtual fds start here — accidentally passing one to a real syscall (or a
/// real fd to us) trips range asserts instead of corrupting something.
const fd_base: posix.socket_t = 1000;
const socket_max = 4096;
const socket_buffer_bytes = 4096;
const accept_queue_max = 16;
const candidates_max = 1024;

pub const AcceptError = error{
    ConnectionAborted,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    Canceled,
    Unexpected,
};

pub const RecvError = error{
    ConnectionResetByPeer,
    ConnectionRefused,
    SystemResources,
    Canceled,
    Unexpected,
};

pub const SendError = error{
    BrokenPipe,
    ConnectionResetByPeer,
    SystemResources,
    Canceled,
    Unexpected,
};

pub const ConnectError = error{
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NetworkUnreachable,
    Canceled,
    Unexpected,
};

pub const CloseError = error{Unexpected};

pub const TimeoutError = error{ Canceled, Unexpected };

pub const CancelError = error{Unexpected};

const Operation = union(enum) {
    accept: struct { socket: posix.socket_t },
    recv: struct { socket: posix.socket_t, buffer: []u8 },
    send: struct { socket: posix.socket_t, buffer: []const u8 },
    connect: struct { socket: posix.socket_t, addr: linux.sockaddr.in },
    close: struct { fd: posix.fd_t },
    timeout: struct { expires_at_ns: u64 },
    cancel: struct { target: u64 },
};

const ErasedCallback = *const fn (
    context: *anyopaque,
    completion: *Completion,
    result: *const anyopaque,
) void;

pub const Completion = struct {
    operation: Operation,
    context: *anyopaque = undefined,
    callback: ErasedCallback = undefined,
    /// Result in cqe.res convention: >= 0 success, negative is `-errno`.
    result: i32 = 0,
    retries: u32 = 0,
    next: ?*Completion = null,
};

const CompletionQueue = struct {
    head: ?*Completion = null,
    tail: ?*Completion = null,
    count: u32 = 0,

    fn push(queue: *CompletionQueue, completion: *Completion) void {
        assert(completion.next == null);
        if (queue.tail) |tail| tail.next = completion else queue.head = completion;
        queue.tail = completion;
        queue.count += 1;
    }

    fn pop(queue: *CompletionQueue) ?*Completion {
        const completion = queue.head orelse return null;
        queue.head = completion.next;
        if (queue.head == null) queue.tail = null;
        completion.next = null;
        assert(queue.count > 0);
        queue.count -= 1;
        return completion;
    }

    fn remove(queue: *CompletionQueue, completion: *Completion) bool {
        var previous: ?*Completion = null;
        var current = queue.head;
        while (current) |node| : ({
            previous = current;
            current = node.next;
        }) {
            if (node != completion) continue;
            if (previous) |p| p.next = node.next else queue.head = node.next;
            if (queue.tail == node) queue.tail = previous;
            node.next = null;
            assert(queue.count > 0);
            queue.count -= 1;
            return true;
        }
        return false;
    }
};

const Socket = struct {
    state: State = .free,
    /// Listener: the bound port; streams: 0.
    port: u16 = 0,
    accept_queue: [accept_queue_max]posix.socket_t = undefined,
    accept_queue_len: u32 = 0,
    /// Stream peer fd; -1 when unconnected or the peer is fully gone.
    peer_fd: posix.socket_t = -1,
    /// Bytes readable on this fd (written by the peer). Linear, compacted.
    buffer: [socket_buffer_bytes]u8 = undefined,
    buffer_len: usize = 0,
    /// The peer sent FIN (or vanished): reads drain the buffer, then 0.
    remote_closed: bool = false,
    read_shutdown: bool = false,
    write_shutdown: bool = false,

    const State = enum { free, listener, stream };
};

pub const IO = struct {
    prng: std.Random.DefaultPrng,
    now: u64 = 0,
    sockets: []Socket,
    /// Next never-used slot (slots are not reused; see the module comment).
    socket_count: u32 = 0,
    pending: CompletionQueue = .{},
    completed: CompletionQueue = .{},

    /// The socket table is too large for the stack; the caller provides the
    /// allocator (simulation is not the zero-alloc serving path).
    pub fn init_simulation(gpa: std.mem.Allocator, seed: u64) !IO {
        const sockets = try gpa.alloc(Socket, socket_max);
        for (sockets) |*socket| socket.* = .{};
        return .{ .prng = std.Random.DefaultPrng.init(seed), .sockets = sockets };
    }

    pub fn deinit_simulation(io: *IO, gpa: std.mem.Allocator) void {
        gpa.free(io.sockets);
        io.* = undefined;
    }

    // ---- virtual sockets ---------------------------------------------------

    fn allocate(io: *IO, state: Socket.State) posix.socket_t {
        assert(state != .free);
        assert(io.socket_count < socket_max); // simulation ran out of fd slots
        const index = io.socket_count;
        io.socket_count += 1;
        io.sockets[index].state = state;
        return fd_base + @as(posix.socket_t, @intCast(index));
    }

    fn socket_at(io: *IO, fd: posix.socket_t) *Socket {
        assert(fd >= fd_base);
        assert(fd < fd_base + @as(posix.socket_t, @intCast(io.socket_count)));
        return &io.sockets[@intCast(fd - fd_base)];
    }

    pub fn open_listener(io: *IO, port: u16) posix.socket_t {
        assert(port != 0);
        const fd = io.allocate(.listener);
        io.socket_at(fd).port = port;
        return fd;
    }

    pub fn open_tcp_socket(io: *IO) ?posix.socket_t {
        return io.allocate(.stream);
    }

    pub fn set_tcp_no_delay(io: *IO, fd: posix.socket_t) void {
        _ = io.socket_at(fd); // range check only; the virtual wire has no Nagle
    }

    pub fn now_ns(io: *IO) u64 {
        return io.now;
    }

    /// Wakes everything pending on the fd (reads see EOF, writes see EPIPE)
    /// and FINs the peer — mirrors shutdown(SHUT_RDWR).
    pub fn shutdown_socket(io: *IO, fd: posix.socket_t) void {
        const socket = io.socket_at(fd);
        assert(socket.state == .stream);
        socket.read_shutdown = true;
        socket.write_shutdown = true;
        if (socket.peer_fd >= 0) io.socket_at(socket.peer_fd).remote_closed = true;
    }

    /// Frees the fd and FINs the peer. Ops already pending on the fd are NOT
    /// completed — exactly like an io_uring close — so a missing shutdown
    /// becomes a detectable hang.
    pub fn close_now(io: *IO, fd: posix.socket_t) void {
        const socket = io.socket_at(fd);
        assert(socket.state != .free); // double close
        if (socket.state == .stream and socket.peer_fd >= 0) {
            const peer = io.socket_at(socket.peer_fd);
            peer.remote_closed = true;
            peer.peer_fd = -1; // writes there now fail
        }
        socket.* = .{ .state = .free };
    }

    // ---- submission (same shape as the io_uring backend) -------------------

    pub fn accept(
        io: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, AcceptError!posix.socket_t) void,
        completion: *Completion,
        socket: posix.socket_t,
    ) void {
        io.submit(Context, context, AcceptError!posix.socket_t, callback, completion, .{
            .accept = .{ .socket = socket },
        });
    }

    pub fn recv(
        io: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, RecvError!usize) void,
        completion: *Completion,
        socket: posix.socket_t,
        buffer: []u8,
    ) void {
        assert(buffer.len > 0);
        io.submit(Context, context, RecvError!usize, callback, completion, .{
            .recv = .{ .socket = socket, .buffer = buffer },
        });
    }

    pub fn send(
        io: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, SendError!usize) void,
        completion: *Completion,
        socket: posix.socket_t,
        buffer: []const u8,
    ) void {
        assert(buffer.len > 0);
        io.submit(Context, context, SendError!usize, callback, completion, .{
            .send = .{ .socket = socket, .buffer = buffer },
        });
    }

    pub fn connect(
        io: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, ConnectError!void) void,
        completion: *Completion,
        socket: posix.socket_t,
        addr: linux.sockaddr.in,
    ) void {
        io.submit(Context, context, ConnectError!void, callback, completion, .{
            .connect = .{ .socket = socket, .addr = addr },
        });
    }

    pub fn close(
        io: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, CloseError!void) void,
        completion: *Completion,
        fd: posix.fd_t,
    ) void {
        io.submit(Context, context, CloseError!void, callback, completion, .{
            .close = .{ .fd = fd },
        });
    }

    pub fn timeout(
        io: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, TimeoutError!void) void,
        completion: *Completion,
        nanoseconds: u63,
    ) void {
        io.submit(Context, context, TimeoutError!void, callback, completion, .{
            .timeout = .{ .expires_at_ns = io.now + nanoseconds },
        });
    }

    pub fn cancel(
        io: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, CancelError!void) void,
        completion: *Completion,
        target: *const Completion,
    ) void {
        io.submit(Context, context, CancelError!void, callback, completion, .{
            .cancel = .{ .target = @intFromPtr(target) },
        });
    }

    fn submit(
        io: *IO,
        comptime Context: type,
        context: Context,
        comptime Result: type,
        comptime callback: fn (Context, *Completion, Result) void,
        completion: *Completion,
        operation: Operation,
    ) void {
        comptime assert(@typeInfo(Context) == .pointer);
        completion.* = .{
            .operation = operation,
            .context = @ptrCast(context),
            .callback = erase(Context, Result, callback),
        };
        io.pending.push(completion);
    }

    // ---- the deterministic scheduler ---------------------------------------

    /// Complete exactly one pending operation, chosen at random among those
    /// that are ready; jump the clock to the next timer when nothing is.
    pub fn run_once(io: *IO) !void {
        var candidates: [candidates_max]*Completion = undefined;
        var count = io.gather_ready(&candidates);
        if (count == 0) {
            const earliest = io.earliest_timer() orelse return error.WouldBlockForever;
            assert(earliest >= io.now);
            io.now = earliest;
            count = io.gather_ready(&candidates);
            assert(count > 0); // the due timer at least
        }
        const pick = candidates[io.prng.random().intRangeLessThan(usize, 0, count)];
        const removed = io.pending.remove(pick);
        assert(removed);
        // Every completion costs a little virtual time.
        io.now += 1 + io.prng.random().intRangeLessThan(u64, 0, 10 * std.time.ns_per_us);
        pick.result = io.perform(pick);
        io.completed.push(pick);
        io.run_completed();
    }

    pub fn run_until_done(io: *IO, done: *const bool) !void {
        while (!done.*) try io.run_once();
    }

    fn gather_ready(io: *IO, candidates: *[candidates_max]*Completion) usize {
        var count: usize = 0;
        var current = io.pending.head;
        while (current) |completion| : (current = completion.next) {
            if (!io.ready(completion)) continue;
            assert(count < candidates_max); // more ready ops than the table holds
            candidates[count] = completion;
            count += 1;
        }
        return count;
    }

    fn earliest_timer(io: *const IO) ?u64 {
        var earliest: ?u64 = null;
        var current = io.pending.head;
        while (current) |completion| : (current = completion.next) {
            switch (completion.operation) {
                .timeout => |op| {
                    if (earliest == null or op.expires_at_ns < earliest.?) {
                        earliest = op.expires_at_ns;
                    }
                },
                else => {},
            }
        }
        return earliest;
    }

    fn ready(io: *IO, completion: *Completion) bool {
        switch (completion.operation) {
            .accept => |op| {
                const listener = io.socket_at(op.socket);
                return listener.state == .listener and listener.accept_queue_len > 0;
            },
            .recv => |op| {
                const socket = io.socket_at(op.socket);
                if (socket.state != .stream) return false; // closed under the op: hangs
                return socket.buffer_len > 0 or socket.remote_closed or socket.read_shutdown;
            },
            .send => |op| {
                const socket = io.socket_at(op.socket);
                if (socket.state != .stream) return false; // closed under the op: hangs
                if (socket.write_shutdown or socket.peer_fd < 0) return true; // fails now
                const peer = io.socket_at(socket.peer_fd);
                return peer.buffer_len < peer.buffer.len; // room to make progress
            },
            .connect => return true,
            .close => return true,
            .timeout => |op| return io.now >= op.expires_at_ns,
            .cancel => return true,
        }
    }

    fn perform(io: *IO, completion: *Completion) i32 {
        switch (completion.operation) {
            .accept => |op| return io.perform_accept(op.socket),
            .recv => |op| return io.perform_recv(op.socket, op.buffer),
            .send => |op| return io.perform_send(op.socket, op.buffer),
            .connect => |op| return io.perform_connect(op.socket, op.addr),
            .close => |op| {
                io.close_now(op.fd);
                return 0;
            },
            .timeout => return -@as(i32, @intFromEnum(linux.E.TIME)), // normal expiry
            .cancel => |op| return io.perform_cancel(op.target),
        }
    }

    fn perform_accept(io: *IO, listener_fd: posix.socket_t) i32 {
        const listener = io.socket_at(listener_fd);
        assert(listener.state == .listener);
        assert(listener.accept_queue_len > 0);
        const fd = listener.accept_queue[0];
        listener.accept_queue_len -= 1;
        std.mem.copyForwards(
            posix.socket_t,
            listener.accept_queue[0..listener.accept_queue_len],
            listener.accept_queue[1 .. listener.accept_queue_len + 1],
        );
        assert(fd >= fd_base);
        return fd;
    }

    fn perform_recv(io: *IO, fd: posix.socket_t, buffer: []u8) i32 {
        const socket = io.socket_at(fd);
        assert(socket.state == .stream);
        if (socket.buffer_len == 0) {
            assert(socket.remote_closed or socket.read_shutdown);
            return 0; // EOF
        }
        // Adversarial partial read: 1..=available bytes, capped by the buffer.
        const available = @min(socket.buffer_len, buffer.len);
        const n = io.prng.random().intRangeAtMost(usize, 1, available);
        @memcpy(buffer[0..n], socket.buffer[0..n]);
        std.mem.copyForwards(
            u8,
            socket.buffer[0 .. socket.buffer_len - n],
            socket.buffer[n..socket.buffer_len],
        );
        socket.buffer_len -= n;
        return @intCast(n);
    }

    fn perform_send(io: *IO, fd: posix.socket_t, buffer: []const u8) i32 {
        const socket = io.socket_at(fd);
        assert(socket.state == .stream);
        if (socket.write_shutdown) return -@as(i32, @intFromEnum(linux.E.PIPE));
        if (socket.peer_fd < 0) return -@as(i32, @intFromEnum(linux.E.PIPE));
        const peer = io.socket_at(socket.peer_fd);
        assert(peer.state == .stream);
        const space = peer.buffer.len - peer.buffer_len;
        assert(space > 0); // ready() gates on room
        // Adversarial partial write: 1..=what fits.
        const n = io.prng.random().intRangeAtMost(usize, 1, @min(buffer.len, space));
        @memcpy(peer.buffer[peer.buffer_len..][0..n], buffer[0..n]);
        peer.buffer_len += n;
        return @intCast(n);
    }

    fn perform_connect(io: *IO, fd: posix.socket_t, addr: linux.sockaddr.in) i32 {
        const socket = io.socket_at(fd);
        assert(socket.state == .stream);
        assert(socket.peer_fd < 0); // never connected twice
        const port = std.mem.bigToNative(u16, addr.port);
        const listener_fd = io.find_listener(port) orelse
            return -@as(i32, @intFromEnum(linux.E.CONNREFUSED));
        const listener = io.socket_at(listener_fd);
        if (listener.accept_queue_len == accept_queue_max) {
            return -@as(i32, @intFromEnum(linux.E.CONNREFUSED)); // backlog full
        }
        const server_fd = io.allocate(.stream);
        const server = io.socket_at(server_fd);
        server.peer_fd = fd;
        socket.peer_fd = server_fd;
        listener.accept_queue[listener.accept_queue_len] = server_fd;
        listener.accept_queue_len += 1;
        return 0;
    }

    fn find_listener(io: *IO, port: u16) ?posix.socket_t {
        for (io.sockets[0..io.socket_count], 0..) |*socket, index| {
            if (socket.state != .listener) continue;
            if (socket.port != port) continue;
            return fd_base + @as(posix.socket_t, @intCast(index));
        }
        return null;
    }

    fn perform_cancel(io: *IO, target: u64) i32 {
        var current = io.pending.head;
        while (current) |completion| : (current = completion.next) {
            if (@intFromPtr(completion) != target) continue;
            const removed = io.pending.remove(completion);
            assert(removed);
            completion.result = -@as(i32, @intFromEnum(linux.E.CANCELED));
            io.completed.push(completion);
            return 0;
        }
        return -@as(i32, @intFromEnum(linux.E.NOENT)); // nothing to cancel
    }

    // ---- result delivery (mirrors the io_uring backend) ---------------------

    fn run_completed(io: *IO) void {
        var maybe = io.completed.pop();
        while (maybe) |completion| : (maybe = io.completed.pop()) {
            io.complete(completion);
        }
    }

    fn complete(io: *IO, completion: *Completion) void {
        _ = io;
        switch (completion.operation) {
            .accept => {
                const result = decode_accept(completion.result);
                completion.callback(completion.context, completion, &result);
            },
            .recv => {
                const result = decode_recv(completion.result);
                completion.callback(completion.context, completion, &result);
            },
            .send => {
                const result = decode_send(completion.result);
                completion.callback(completion.context, completion, &result);
            },
            .connect => {
                const result = decode_connect(completion.result);
                completion.callback(completion.context, completion, &result);
            },
            .close => {
                const result: CloseError!void = {};
                completion.callback(completion.context, completion, &result);
            },
            .timeout => {
                const result = decode_timeout(completion.result);
                completion.callback(completion.context, completion, &result);
            },
            .cancel => {
                const result = decode_cancel(completion.result);
                completion.callback(completion.context, completion, &result);
            },
        }
    }
};

fn to_errno(result: i32) posix.E {
    assert(result < 0);
    return @enumFromInt(@as(u16, @intCast(-result)));
}

fn decode_accept(result: i32) AcceptError!posix.socket_t {
    if (result >= 0) return @intCast(result);
    return switch (to_errno(result)) {
        .CANCELED => error.Canceled,
        else => error.Unexpected,
    };
}

fn decode_recv(result: i32) RecvError!usize {
    if (result >= 0) return @intCast(result);
    return switch (to_errno(result)) {
        .CONNRESET => error.ConnectionResetByPeer,
        .CANCELED => error.Canceled,
        else => error.Unexpected,
    };
}

fn decode_send(result: i32) SendError!usize {
    if (result >= 0) return @intCast(result);
    return switch (to_errno(result)) {
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionResetByPeer,
        .CANCELED => error.Canceled,
        else => error.Unexpected,
    };
}

fn decode_connect(result: i32) ConnectError!void {
    if (result >= 0) return;
    return switch (to_errno(result)) {
        .CONNREFUSED => error.ConnectionRefused,
        .CANCELED => error.Canceled,
        else => error.Unexpected,
    };
}

fn decode_timeout(result: i32) TimeoutError!void {
    if (result >= 0) return;
    return switch (to_errno(result)) {
        .TIME => {}, // normal expiry
        .CANCELED => error.Canceled,
        else => error.Unexpected,
    };
}

fn decode_cancel(result: i32) CancelError!void {
    if (result >= 0) return;
    return switch (to_errno(result)) {
        .NOENT, .ALREADY => {},
        else => error.Unexpected,
    };
}

fn erase(
    comptime Context: type,
    comptime Result: type,
    comptime callback: fn (Context, *Completion, Result) void,
) ErasedCallback {
    return &struct {
        fn erased(context: *anyopaque, completion: *Completion, result: *const anyopaque) void {
            const typed_context: Context = @ptrCast(@alignCast(context));
            const typed_result: *const Result = @ptrCast(@alignCast(result));
            callback(typed_context, completion, typed_result.*);
        }
    }.erased;
}

// ---- tests ------------------------------------------------------------------

const TestPeer = struct {
    io: *IO,
    fd: posix.socket_t = -1,
    recv_buf: [64]u8 = undefined,
    received: usize = 0,
    sent: usize = 0,
    message: []const u8 = "",
    eof: bool = false,
    accept_c: Completion = undefined,
    recv_c: Completion = undefined,
    send_c: Completion = undefined,
    connect_c: Completion = undefined,

    fn on_accept(peer: *TestPeer, _: *Completion, result: AcceptError!posix.socket_t) void {
        peer.fd = result catch unreachable;
        peer.arm_recv();
    }
    fn arm_recv(peer: *TestPeer) void {
        const tail = peer.recv_buf[peer.received..];
        peer.io.recv(*TestPeer, peer, on_recv, &peer.recv_c, peer.fd, tail);
    }
    fn on_recv(peer: *TestPeer, _: *Completion, result: RecvError!usize) void {
        const n = result catch unreachable;
        if (n == 0) {
            peer.eof = true;
            return;
        }
        peer.received += n;
        peer.arm_recv();
    }
    fn on_connect(peer: *TestPeer, _: *Completion, result: ConnectError!void) void {
        result catch unreachable;
        peer.arm_send();
    }
    fn arm_send(peer: *TestPeer) void {
        peer.io.send(*TestPeer, peer, on_send, &peer.send_c, peer.fd, peer.message[peer.sent..]);
    }
    fn on_send(peer: *TestPeer, _: *Completion, result: SendError!usize) void {
        peer.sent += result catch unreachable;
        if (peer.sent < peer.message.len) return peer.arm_send();
        peer.io.shutdown_socket(peer.fd); // FIN: the receiver sees EOF
    }
};

test "test_io: listen/connect/accept/send/recv round-trip, deterministically" {
    const gpa = std.testing.allocator;
    // The same seed must produce the identical byte-delivery schedule.
    var transcripts: [2]usize = undefined;
    for (&transcripts) |*transcript| {
        var io = try IO.init_simulation(gpa, 42);
        defer io.deinit_simulation(gpa);

        const listener = io.open_listener(8080);
        var server = TestPeer{ .io = &io };
        io.accept(*TestPeer, &server, TestPeer.on_accept, &server.accept_c, listener);

        var client = TestPeer{ .io = &io, .message = "hello, deterministic world!" };
        client.fd = io.open_tcp_socket().?;
        io.connect(*TestPeer, &client, TestPeer.on_connect, &client.connect_c, client.fd, .{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, 8080),
            .addr = 0,
        });

        var steps: usize = 0;
        while (!server.eof) : (steps += 1) {
            try std.testing.expect(steps < 10_000); // progress, not a hang
            try io.run_once();
        }
        try std.testing.expectEqualStrings(client.message, server.recv_buf[0..server.received]);
        transcript.* = steps;
    }
    try std.testing.expectEqual(transcripts[0], transcripts[1]);
}

test "test_io: close without shutdown leaves a pending recv hanging" {
    const gpa = std.testing.allocator;
    var io = try IO.init_simulation(gpa, 7);
    defer io.deinit_simulation(gpa);

    const listener = io.open_listener(9090);
    var server = TestPeer{ .io = &io };
    io.accept(*TestPeer, &server, TestPeer.on_accept, &server.accept_c, listener);

    var client = TestPeer{ .io = &io, .message = "x" };
    client.fd = io.open_tcp_socket().?;
    io.connect(*TestPeer, &client, TestPeer.on_connect, &client.connect_c, client.fd, .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, 9090),
        .addr = 0,
    });
    while (server.received < 1) try io.run_once();

    // The server arms another recv, then closes its own fd without shutdown:
    // that recv can never complete — io_uring semantics — and with no timers
    // the loop reports the deadlock instead of spinning.
    io.close_now(server.fd);
    try std.testing.expectError(error.WouldBlockForever, io.run_once());
}

test "test_io: timers fire in virtual time order" {
    const gpa = std.testing.allocator;
    var io = try IO.init_simulation(gpa, 3);
    defer io.deinit_simulation(gpa);

    const Harness = struct {
        fired: [2]bool = .{ false, false },
        order_first: ?usize = null,
        fn on_late(h: *@This(), _: *Completion, _: TimeoutError!void) void {
            h.fired[1] = true;
            if (h.order_first == null) h.order_first = 1;
        }
        fn on_early(h: *@This(), _: *Completion, _: TimeoutError!void) void {
            h.fired[0] = true;
            if (h.order_first == null) h.order_first = 0;
        }
    };
    var h = Harness{};
    var late_c: Completion = undefined;
    var early_c: Completion = undefined;
    io.timeout(*Harness, &h, Harness.on_late, &late_c, 50 * std.time.ns_per_ms);
    io.timeout(*Harness, &h, Harness.on_early, &early_c, 10 * std.time.ns_per_ms);

    while (!h.fired[0] or !h.fired[1]) try io.run_once();
    try std.testing.expectEqual(@as(?usize, 0), h.order_first); // the earlier deadline first
    try std.testing.expect(io.now >= 50 * std.time.ns_per_ms);
}
