//! Config reload via supervised self-relaunch (docs/DESIGN.md §7 Phase 6,
//! slice 2). A reload is deliberately *not* an in-process swap: per-worker state
//! is reserved at startup and keyed by cluster/endpoint index, and routed
//! requests borrow `*const Cluster` for their whole lifetime — mutating a live
//! `Config` is unsafe. Instead, on SIGHUP the running instance fork+execs a
//! fresh `zoxy` on the same config path; the successor adopts the listener fds
//! through the Phase-4 handoff socket and serves while this instance drains —
//! the exact cutover a binary hot restart uses, just self-triggered.
//!
//! The decision (`evaluate`) is pure and unit-tested; the effect
//! (`spawn_successor`) is a thin fork+exec syscall seam, like the raw-syscall
//! code in `main.zig`/`net/handoff.zig`.

const std = @import("std");
const linux = std.os.linux;
const assert = std.debug.assert;
const Ip4Address = std.Io.net.Ip4Address;

/// Whether an already-parsed new config can be reloaded by relaunch. A failed
/// parse is handled by the caller (which owns the diagnostic path), so it is
/// not a variant here.
pub const Outcome = enum {
    /// Compatible — fork+exec a successor.
    launch,
    /// No handoff socket configured on the running instance: there is no channel
    /// for a successor to adopt the listeners through, so no graceful cutover.
    no_handoff,
    /// The new config drops or moves the handoff socket. The successor adopts
    /// through *its own* (new) handoff path, so it would never connect to ours,
    /// bind fresh beside us, and never let us drain — a permanent double-serve.
    handoff_changed,
    /// The listen address changed: the successor cannot adopt the running
    /// listeners (handoff validates the address), so both would end up serving.
    listen_changed,
};

/// Decide whether a parsed new config can be reloaded by relaunch. The successor
/// re-parses the file and adopts through the handoff path *it* reads, so the new
/// config must keep the same handoff socket and listen address or it binds fresh
/// beside us instead of adopting. Pure — effects stay in the caller.
pub fn evaluate(
    current_handoff: ?[]const u8,
    next_handoff: ?[]const u8,
    current_listen: Ip4Address,
    next_listen: Ip4Address,
) Outcome {
    const current = current_handoff orelse return .no_handoff;
    const next = next_handoff orelse return .handoff_changed;
    if (!std.mem.eql(u8, current, next)) return .handoff_changed;
    if (!address_equal(current_listen, next_listen)) return .listen_changed;
    return .launch;
}

fn address_equal(a: Ip4Address, b: Ip4Address) bool {
    return std.mem.eql(u8, &a.bytes, &b.bytes) and a.port == b.port;
}

pub const SpawnError = error{ ExePathFailed, ForkFailed };

/// fork+exec a fresh `zoxy <config_path>` — the successor. Everything that
/// allocates (the exe path, argv) is built before the fork; between fork and
/// execve the child does nothing but the exec itself, so no allocator or lock
/// is touched in the forked child (async-signal-safety). Returns the child pid;
/// the caller keeps serving until the successor adopts the listeners and the
/// handoff triggers this process's drain.
pub fn spawn_successor(
    io: std.Io,
    gpa: std.mem.Allocator,
    config_path: [:0]const u8,
) SpawnError!linux.pid_t {
    assert(config_path.len > 0);
    const exe_path = std.process.executablePathAlloc(io, gpa) catch return error.ExePathFailed;
    assert(exe_path.len > 0);
    // The child's COW copy keeps argv alive across execve; build it up front.
    var argv = [_:null]?[*:0]const u8{ exe_path.ptr, config_path.ptr };
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.ForkFailed;
    const pid: linux.pid_t = @intCast(rc);
    if (pid == 0) {
        _ = linux.execve(exe_path.ptr, &argv, std.c.environ);
        linux.exit_group(127); // only reached if execve failed
    }
    assert(pid > 0);
    return pid;
}

// ---- tests ----------------------------------------------------------------

test "reload: evaluate requires an unchanged handoff socket and listen address" {
    const sock: []const u8 = "/run/zoxy.sock";
    const moved: []const u8 = "/run/other.sock";
    const listen = try Ip4Address.parse("127.0.0.1", 8080);
    const same = try Ip4Address.parse("127.0.0.1", 8080);
    const other_port = try Ip4Address.parse("127.0.0.1", 9090);
    const other_host = try Ip4Address.parse("0.0.0.0", 8080);

    // No handoff socket on the running instance → nothing to adopt through.
    try std.testing.expectEqual(Outcome.no_handoff, evaluate(null, sock, listen, same));
    // Compatible: same handoff socket and address.
    try std.testing.expectEqual(Outcome.launch, evaluate(sock, sock, listen, same));
    // The new config drops or moves the handoff socket → successor can't adopt.
    try std.testing.expectEqual(Outcome.handoff_changed, evaluate(sock, null, listen, same));
    try std.testing.expectEqual(Outcome.handoff_changed, evaluate(sock, moved, listen, same));
    // A changed port or host means the successor can't adopt the listeners.
    try std.testing.expectEqual(Outcome.listen_changed, evaluate(sock, sock, listen, other_port));
    try std.testing.expectEqual(Outcome.listen_changed, evaluate(sock, sock, listen, other_host));
}
