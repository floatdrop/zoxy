//! Allocation guard for the zero-alloc acceptance gate (docs/DESIGN.md §4).
//!
//! zoxy's serving path holds no allocator by construction, so the guarantee is
//! structural. `CountingAllocator` wraps a backing allocator and counts every
//! heap-touching call; the acceptance test snapshots the count after startup,
//! drives a full request through the proxy, and asserts the count did not move —
//! a tripwire that fails loudly if a future change allocates on the hot path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const CountingAllocator = struct {
    backing: Allocator,
    allocations: usize = 0,
    resizes: usize = 0,
    remaps: usize = 0,
    frees: usize = 0,

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Calls that create or move a heap allocation (i.e. must not happen on the
    /// serving path). Frees are excluded — releasing startup memory is fine.
    pub fn allocation_count(self: *const CountingAllocator) usize {
        return self.allocations + self.resizes + self.remaps;
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocations += 1;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }
    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.remaps += 1;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "guard: counts heap-touching calls, ignores frees" {
    var counting = CountingAllocator{ .backing = std.testing.allocator };
    const a = counting.allocator();

    const buf = try a.alloc(u8, 32);
    try std.testing.expectEqual(@as(usize, 1), counting.allocation_count());
    a.free(buf);
    try std.testing.expectEqual(@as(usize, 1), counting.allocation_count()); // frees don't count
    try std.testing.expectEqual(@as(usize, 1), counting.frees);
}
