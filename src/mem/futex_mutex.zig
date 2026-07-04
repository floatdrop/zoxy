//! A blocking mutex over the raw Linux futex (Drepper's three-state design,
//! "Futexes Are Tricky" §6, the exchange variant). Zig 0.16 removed
//! `std.Thread.Mutex`; its replacement `std.Io.Mutex` needs an `Io` instance
//! that zoxy's workers deliberately do not carry (docs/DESIGN.md §3), so this
//! goes direct to the syscall like the rest of the I/O layer.
//!
//! Off the data path only: today's sole user is the TLS hook heap, taken
//! during handshake-time allocation. The relay path never locks.

const std = @import("std");
const linux = std.os.linux;
const assert = std.debug.assert;

pub const FutexMutex = struct {
    state: u32 = state_unlocked,

    const state_unlocked: u32 = 0;
    const state_locked: u32 = 1;
    /// Locked with (possible) sleepers: unlock must issue a wake.
    const state_contended: u32 = 2;

    pub fn lock(mutex: *FutexMutex) void {
        const raced = @cmpxchgWeak(
            u32,
            &mutex.state,
            state_unlocked,
            state_locked,
            .acquire,
            .monotonic,
        );
        if (raced == null) return; // uncontended fast path
        mutex.lock_contended();
    }

    /// Waits are bounded by the holder's critical section — microseconds
    /// here: the heap's O(1) pop/push under the lock, never I/O.
    fn lock_contended(mutex: *FutexMutex) void {
        while (true) {
            // Pessimistically mark contended: cheaper than tracking the
            // exact waiter count, at worst one spurious wake.
            const previous = @atomicRmw(u32, &mutex.state, .Xchg, state_contended, .acquire);
            assert(previous <= state_contended);
            if (previous == state_unlocked) return; // acquired
            _ = linux.futex_4arg(
                &mutex.state,
                .{ .cmd = .WAIT, .private = true },
                state_contended,
                null,
            );
        }
    }

    pub fn unlock(mutex: *FutexMutex) void {
        const previous = @atomicRmw(u32, &mutex.state, .Xchg, state_unlocked, .release);
        assert(previous != state_unlocked); // unlock without lock
        assert(previous <= state_contended);
        if (previous == state_contended) {
            _ = linux.futex_3arg(&mutex.state, .{ .cmd = .WAKE, .private = true }, 1);
        }
    }
};

test "futex_mutex: uncontended lock/unlock round-trips" {
    var mutex = FutexMutex{};
    try std.testing.expectEqual(FutexMutex.state_unlocked, mutex.state);
    mutex.lock();
    try std.testing.expectEqual(FutexMutex.state_locked, mutex.state);
    mutex.unlock();
    try std.testing.expectEqual(FutexMutex.state_unlocked, mutex.state);
}

test "futex_mutex: serializes increments across threads" {
    const iterations_per_thread = 10_000;
    const thread_count = 4;

    const Shared = struct {
        mutex: FutexMutex = .{},
        counter: u64 = 0,

        fn work(shared: *@This()) void {
            for (0..iterations_per_thread) |_| {
                shared.mutex.lock();
                shared.counter += 1; // non-atomic on purpose: the lock is the test
                shared.mutex.unlock();
            }
        }
    };

    var shared = Shared{};
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Shared.work, .{&shared});
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(
        @as(u64, iterations_per_thread * thread_count),
        shared.counter,
    );
    try std.testing.expectEqual(FutexMutex.state_unlocked, shared.mutex.state);
}
