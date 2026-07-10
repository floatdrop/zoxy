//! Build-time lint for the fd boundary of DESIGN.md §4/§9: raw syscall
//! surfaces (`std.posix`, `std.os`, `os.linux`) and the `xev` import may be
//! named only under `src/io/`, with an explicit allowlist for `main.zig`
//! startup work (rlimits, sigaction). `@cImport` is forbidden everywhere —
//! the codebase has no C-FFI dependency (§4). Runs as `zig build lint`
//! with the source root as its single argument.

const std = @import("std");

const assert = std.debug.assert;

/// Bounded walk: a source tree past this size is itself a lint failure —
/// raise deliberately if the project legitimately grows.
const files_max: u32 = 512;
const file_bytes_max: u32 = 1024 * 1024;

const syscall_needles = [_][]const u8{ "std.posix", "std.os", "os.linux" };

/// Lines in `main.zig` naming `std.posix` must contain one of these
/// identifiers; everything else (sockets, files, pipes) stays behind the
/// Io seam even in main.
const main_allowlist = [_][]const u8{
    "getrlimit",
    "setrlimit",
    "rlimit",
    "sigaction",
    "Sigaction",
    "sigemptyset",
    "sigset_t",
    "SIG",
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    assert(args.len >= 1);
    if (args.len != 2) {
        std.debug.print("usage: lint <source-root>\n", .{});
        return 2;
    }

    var root = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer root.close(io);

    var violation_count: u32 = 0;
    var file_count: u32 = 0;
    var walker = try root.walk(arena);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        if (!std.mem.endsWith(u8, entry.path, ".zig")) {
            continue;
        }
        file_count += 1;
        assert(file_count <= files_max);
        violation_count += try lintFile(arena, io, root, entry.path);
    }
    assert(file_count >= 1);

    if (violation_count > 0) {
        std.debug.print("lint: {d} violation(s)\n", .{violation_count});
        return 1;
    }
    return 0;
}

fn lintFile(
    arena: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    path: []const u8,
) !u32 {
    assert(path.len > 0);
    const in_io_directory = std.mem.startsWith(u8, path, "io/") or
        std.mem.startsWith(u8, path, "io" ++ std.fs.path.sep_str);
    const is_main = std.mem.eql(u8, path, "main.zig");

    const contents = try root.readFileAlloc(io, path, arena, .limited(file_bytes_max));
    assert(contents.len < file_bytes_max);

    var violation_count: u32 = 0;
    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_number += 1;
        if (lintLine(line, in_io_directory, is_main)) |message| {
            std.debug.print("{s}:{d}: {s}\n", .{ path, line_number, message });
            violation_count += 1;
        }
    }
    assert(line_number >= 1);
    return violation_count;
}

/// Returns a violation message for the line, or null if the line is clean.
fn lintLine(line: []const u8, in_io_directory: bool, is_main: bool) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "@cImport") != null) {
        return "@cImport is forbidden: no C-FFI dependency (DESIGN.md §4)";
    }
    if (in_io_directory) {
        return null;
    }
    if (std.mem.indexOf(u8, line, "@import(\"xev\")") != null) {
        return "xev may only be imported under src/io/ (DESIGN.md §4)";
    }
    for (syscall_needles) |needle| {
        if (std.mem.indexOf(u8, line, needle) == null) {
            continue;
        }
        if (is_main) {
            if (lineIsAllowlisted(line)) {
                return null;
            }
            return "main.zig may only use std.posix for rlimits and sigaction";
        }
        return "raw syscall surfaces live under src/io/ only (DESIGN.md §4)";
    }
    return null;
}

fn lineIsAllowlisted(line: []const u8) bool {
    assert(line.len > 0);
    for (main_allowlist) |identifier| {
        if (std.mem.indexOf(u8, line, identifier) != null) {
            return true;
        }
    }
    return false;
}

test "lintLine: raw syscalls flagged outside io, allowed inside" {
    try std.testing.expect(lintLine("const x = std.posix.socket();", false, false) != null);
    try std.testing.expect(lintLine("const x = std.os.linux.close(fd);", false, false) != null);
    try std.testing.expect(lintLine("const x = std.posix.socket();", true, false) == null);
    try std.testing.expect(lintLine("const clean = a + b;", false, false) == null);
}

test "lintLine: main.zig allowlist admits rlimit and sigaction only" {
    try std.testing.expect(lintLine("try std.posix.setrlimit(.NOFILE, limits);", false, true) == null);
    try std.testing.expect(lintLine("std.posix.sigaction(.TERM, &action, null);", false, true) == null);
    try std.testing.expect(lintLine("_ = std.posix.setsockopt(fd, 0, 0, &opt);", false, true) != null);
}

test "lintLine: xev import and cImport boundaries" {
    try std.testing.expect(lintLine("const xev = @import(\"xev\");", false, false) != null);
    try std.testing.expect(lintLine("const xev = @import(\"xev\");", true, false) == null);
    try std.testing.expect(lintLine("const c = @cImport({});", true, false) != null);
}
