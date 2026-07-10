//! zoxy entrypoint. Real startup (config, budgets printout, signal handlers,
//! the event loop) lands in slice 9 of Phase 0; until then this stub only
//! proves that the binary links against the zoxy module.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("zoxy: Phase 0 in progress; serving lands in slice 9.\n", .{});
}
