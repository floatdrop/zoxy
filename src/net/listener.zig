//! A TCP listening socket with `SO_REUSEPORT`, so every worker can bind the same
//! address and let the kernel load-balance accepts across cores (docs/DESIGN.md
//! §2). Socket creation moved into `std.Io` in 0.16, so we go straight to the
//! raw `std.os.linux` syscalls, which keeps us off any allocating/blocking path.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const assert = std.debug.assert;

const Ip4Address = std.Io.net.Ip4Address;

pub const Listener = struct {
    fd: posix.socket_t,

    pub const OpenError = error{
        SocketCreateFailed,
        SetSockOptFailed,
        BindFailed,
        ListenFailed,
    };

    /// Create a non-blocking, reuseport TCP listener bound to `address`.
    /// A `port` of 0 lets the kernel choose one; read it back with `boundAddress`.
    pub fn open(address: Ip4Address, backlog: u32) OpenError!Listener {
        const fd = createSocket() orelse return error.SocketCreateFailed;
        errdefer _ = linux.close(fd);

        setReuse(fd) catch return error.SetSockOptFailed;

        var sa = sockaddrIn(address);
        if (posix.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            return error.BindFailed;
        }
        if (posix.errno(linux.listen(fd, backlog)) != .SUCCESS) {
            return error.ListenFailed;
        }
        return .{ .fd = fd };
    }

    pub fn close(listener: *Listener) void {
        _ = linux.close(listener.fd);
        listener.* = undefined;
    }

    /// The bound address, resolving an ephemeral port assigned by the kernel.
    pub fn boundAddress(listener: Listener) Ip4Address {
        var sa: linux.sockaddr.in = undefined;
        var len: posix.socklen_t = @sizeOf(linux.sockaddr.in);
        const rc = linux.getsockname(listener.fd, @ptrCast(&sa), &len);
        assert(posix.errno(rc) == .SUCCESS);
        assert(sa.family == linux.AF.INET);
        return .{ .bytes = @bitCast(sa.addr), .port = std.mem.bigToNative(u16, sa.port) };
    }
};

fn createSocket() ?posix.socket_t {
    const flags = linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK;
    const rc = linux.socket(linux.AF.INET, flags, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn setReuse(fd: posix.socket_t) posix.SetSockOptError!void {
    const on: c_int = 1;
    const bytes = std.mem.asBytes(&on);
    try posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, bytes);
    try posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, bytes);
}

fn sockaddrIn(address: Ip4Address) linux.sockaddr.in {
    return .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, address.port),
        .addr = @bitCast(address.bytes),
    };
}

// ---- tests ----------------------------------------------------------------

test "listener: accepts a loopback connection" {
    const io_mod = @import("../io/io.zig");
    const IO = io_mod.IO;
    const Completion = io_mod.Completion;

    var listener = try Listener.open(Ip4Address.loopback(0), 8);
    defer listener.close();
    const port = listener.boundAddress().port;

    // Blocking loopback connect completes the handshake into the accept queue.
    const client: posix.socket_t = blk: {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        try std.testing.expect(posix.errno(rc) == .SUCCESS);
        break :blk @intCast(rc);
    };
    defer _ = linux.close(client);
    {
        var sa = sockaddrIn(Ip4Address.loopback(port));
        const rc = linux.connect(client, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
        try std.testing.expect(posix.errno(rc) == .SUCCESS);
    }

    var io = try IO.init(8, 0);
    defer io.deinit();

    const Harness = struct {
        accepted_fd: posix.socket_t = -1,
        done: bool = false,
        fn onAccept(h: *@This(), _: *Completion, result: io_mod.AcceptError!posix.socket_t) void {
            h.accepted_fd = result catch -1;
            h.done = true;
        }
    };
    var h = Harness{};
    var completion: Completion = undefined;
    io.accept(*Harness, &h, Harness.onAccept, &completion, listener.fd);
    try io.run_until_done(&h.done);

    try std.testing.expect(h.accepted_fd >= 0);
    _ = linux.close(h.accepted_fd);
}
