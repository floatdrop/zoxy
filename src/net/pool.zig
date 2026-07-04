//! Fixed-capacity object pool backed by one startup allocation and an intrusive
//! free list. Acquire/release never allocate; exhaustion returns null so callers
//! apply backpressure (docs/DESIGN.md §4). `T` must have a `free_next: ?*T` field
//! and an `in_use: bool` field — the latter makes every slot in `items`
//! classifiable (fields of a never-acquired slot are otherwise undefined), so
//! callers can sweep live objects (graceful drain) and diagnostics can dump them.

const std = @import("std");
const assert = std.debug.assert;

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        free_head: ?*T,
        free_count: u32,
        capacity: u32,

        pub fn init(gpa: std.mem.Allocator, capacity: u32) !Self {
            assert(capacity > 0);
            const items = try gpa.alloc(T, capacity);
            // Fresh items are uninitialized; null the links so release() can
            // assert an item is not already on the free list. `in_use` starts
            // true only so the release() below models a real handback.
            for (items) |*item| {
                item.free_next = null;
                item.in_use = true;
            }
            var self: Self = .{
                .items = items,
                .free_head = null,
                .free_count = 0,
                .capacity = capacity,
            };
            // Build the free list so acquire() hands out item 0 first.
            var i: u32 = capacity;
            while (i > 0) {
                i -= 1;
                self.release(&items[i]);
            }
            assert(self.free_count == capacity);
            return self;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.items);
            self.* = undefined;
        }

        pub fn acquire(self: *Self) ?*T {
            const item = self.free_head orelse return null;
            assert(!item.in_use); // everything on the free list is free
            self.free_head = item.free_next;
            item.free_next = null;
            item.in_use = true;
            assert(self.free_count > 0);
            self.free_count -= 1;
            return item;
        }

        pub fn release(self: *Self, item: *T) void {
            assert(self.free_count < self.capacity);
            assert(item.in_use); // only a live object can be handed back
            // Negative space: a double release would link the item into the
            // free list twice and hand the same slot to two connections.
            assert(item.free_next == null);
            assert(item != self.free_head);
            item.in_use = false;
            item.free_next = self.free_head;
            self.free_head = item;
            self.free_count += 1;
        }
    };
}

test "pool: acquire/release round-trips" {
    const Node = struct { value: u32 = 0, free_next: ?*@This() = null, in_use: bool = false };
    var pool = try Pool(Node).init(std.testing.allocator, 3);
    defer pool.deinit(std.testing.allocator);

    const a = pool.acquire().?;
    const b = pool.acquire().?;
    const c = pool.acquire().?;
    try std.testing.expect(pool.acquire() == null); // exhausted
    try std.testing.expectEqual(@as(u32, 0), pool.free_count);

    pool.release(b);
    try std.testing.expectEqual(b, pool.acquire().?); // most-recently-freed reused (LIFO)
    pool.release(a);
    pool.release(b);
    pool.release(c);
    try std.testing.expectEqual(@as(u32, 3), pool.free_count);
}
