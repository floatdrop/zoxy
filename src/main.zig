//! zoxy entrypoint. Phase-0: a thread-per-core echo server — one worker per CPU,
//! each with its own io_uring loop, its own SO_REUSEPORT listener, and its own
//! connection pool (share-nothing; docs/DESIGN.md §2). The kernel load-balances
//! accepts across the per-worker listeners.

const std = @import("std");
const linux = std.os.linux;

const zoxy = @import("zoxy");
const constants = zoxy.constants;
const IO = zoxy.io.IO;
const Listener = zoxy.Listener;
const Pool = zoxy.connection.Pool;
const EchoServer = zoxy.connection.EchoServer;
const Ip4Address = std.Io.net.Ip4Address;

const listen_port = 8080;

pub fn main() !void {
    // Startup allocations (pools) only — nothing here runs on the serving path.
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const worker_count = std.Thread.getCpuCount() catch 1;
    const address = Ip4Address.unspecified(listen_port);

    // Allocate every pool up front, on this thread, so worker startup touches no
    // shared allocator (the serving loop then allocates nothing).
    const pools = try gpa.alloc(Pool, worker_count);
    defer gpa.free(pools);
    for (pools) |*pool| pool.* = try Pool.init(gpa, constants.connections_max);
    defer for (pools) |*pool| pool.deinit(gpa);

    const threads = try gpa.alloc(std.Thread, worker_count);
    defer gpa.free(threads);
    for (threads, pools, 0..) |*thread, *pool, cpu| {
        thread.* = try std.Thread.spawn(.{}, runWorker, .{ address, pool, cpu });
    }

    std.log.info("zoxy echo listening on 0.0.0.0:{d} across {d} worker(s)", .{
        listen_port,
        worker_count,
    });
    for (threads) |thread| thread.join();
}

/// One share-nothing worker: its own IO ring, listener, and pool, pinned to a
/// core. Runs the accept/echo loop forever.
fn runWorker(address: Ip4Address, pool: *Pool, cpu: usize) void {
    pinToCpu(cpu);

    var io = IO.init(constants.io_ring_entries, 0) catch |err| return logWorkerError("io init", err);
    defer io.deinit();

    var listener = Listener.open(address, constants.accept_backlog) catch |err| return logWorkerError("listen", err);
    defer listener.close();

    var server = EchoServer.init(&io, pool, listener);
    server.start();
    while (true) io.run_once() catch |err| return logWorkerError("io run", err);
}

/// Best-effort CPU pinning (Linux only). Failure is non-fatal.
fn pinToCpu(cpu: usize) void {
    var set = std.mem.zeroes(linux.cpu_set_t);
    const bits = @bitSizeOf(usize);
    if (cpu / bits >= set.len) return; // more CPUs than the affinity mask covers
    set[cpu / bits] |= @as(usize, 1) << @intCast(cpu % bits);
    linux.sched_setaffinity(0, &set) catch {};
}

fn logWorkerError(what: []const u8, err: anyerror) void {
    std.log.err("zoxy worker {s}: {s}", .{ what, @errorName(err) });
}
