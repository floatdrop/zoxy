//! `zig build schema` entry point: render the config JSON Schema to stdout
//! so the build step can capture it into zig-out/config.schema.json for the
//! release workflow to ship. All content is derived from the config
//! definitions — see src/config_schema.zig.

const std = @import("std");

const zoxy = @import("zoxy");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &file_writer.interface;
    try zoxy.config_schema.writeSchema(writer);
    try writer.flush();
}
