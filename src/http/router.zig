//! §7 routing: map a request's canonical host and path to a cluster
//! through a per-listener table. Host is the outer dimension — a
//! host-specific route beats an any-host one — and path is longest-prefix
//! within that. Pure: the table is built, validated, and sorted at config
//! load (`config.zig`) so a host-specific match precedes any any-host
//! match and each group is longest-prefix-first, making a request-time
//! match a bounded linear scan over immutable arena data, never an
//! allocation on the loop. No match is a real outcome: the caller
//! answers 404 (§8).

const std = @import("std");

const assert = std.debug.assert;

/// One routing rule: a canonical path prefix and the cluster it selects,
/// optionally scoped to a canonical host (`null` = any host). Both keys
/// are validated canonical at config load (§7), so they compare directly
/// against the request's canonical host/path with no per-request work.
pub const Route = struct {
    host: ?[]const u8 = null,
    prefix: []const u8,
    cluster_index: u16,
};

/// The cluster for a request's canonical `host` (null when the request
/// carried no usable Host) and canonical `path`, or null when nothing
/// matches (the caller's 404, §8). `routes` is sorted host-specific-first
/// then longest-prefix-first, so the first matching route is the most
/// specific: any route scoped to the request's host beats every any-host
/// route, and within a group the longest prefix wins.
pub fn route(routes: []const Route, host: ?[]const u8, path: []const u8) ?u16 {
    assert(routes.len >= 1);
    assert(path.len >= 1);
    assert(path[0] == '/');
    for (routes) |candidate| {
        if (hostMatches(candidate.host, host) and prefixMatches(candidate.prefix, path)) {
            return candidate.cluster_index;
        }
    }
    return null;
}

/// An any-host route (`route_host == null`) matches every request. A
/// host-scoped route matches only when the request carried a host and it
/// equals the route's — so a request with no usable Host (`req_host ==
/// null`) meets only the any-host routes (§7).
fn hostMatches(route_host: ?[]const u8, req_host: ?[]const u8) bool {
    const scoped = route_host orelse return true;
    const requested = req_host orelse return false;
    return std.mem.eql(u8, scoped, requested);
}

/// A prefix matches only when it covers whole path segments: the path
/// equals the prefix, the prefix is slash-terminated, or the byte right
/// after the prefix is `/`. So `/api` matches `/api` and `/api/v1` but
/// never `/apihost` — a string prefix that splits a segment is not a
/// route. `/` is slash-terminated, so the root prefix is the catch-all.
/// Public so filters (§7) share exactly one canonical-path prefix
/// semantics with routing.
pub fn prefixMatches(prefix: []const u8, path: []const u8) bool {
    assert(prefix.len >= 1);
    assert(prefix[0] == '/');
    assert(path.len >= 1);
    assert(path[0] == '/');
    if (!std.mem.startsWith(u8, path, prefix)) {
        return false;
    }
    if (path.len == prefix.len) {
        return true;
    }
    assert(path.len > prefix.len);
    if (prefix[prefix.len - 1] == '/') {
        return true;
    }
    return path[prefix.len] == '/';
}

test "router: longest-prefix wins at segment boundaries" {
    // As config.zig will store them: sorted longest-prefix-first.
    const routes = [_]Route{
        .{ .prefix = "/api/v2", .cluster_index = 3 },
        .{ .prefix = "/api", .cluster_index = 2 },
        .{ .prefix = "/", .cluster_index = 0 },
    };
    try std.testing.expectEqual(@as(?u16, 3), route(&routes, null, "/api/v2"));
    try std.testing.expectEqual(@as(?u16, 3), route(&routes, null, "/api/v2/x"));
    try std.testing.expectEqual(@as(?u16, 2), route(&routes, null, "/api"));
    try std.testing.expectEqual(@as(?u16, 2), route(&routes, null, "/api/v1"));
    // A segment-splitting string prefix is not a match: "/api" must not
    // capture "/apihost", so it falls through to the catch-all.
    try std.testing.expectEqual(@as(?u16, 0), route(&routes, null, "/apihost"));
    try std.testing.expectEqual(@as(?u16, 0), route(&routes, null, "/other"));
    try std.testing.expectEqual(@as(?u16, 0), route(&routes, null, "/"));
}

test "router: no catch-all means no match is null (404)" {
    const routes = [_]Route{
        .{ .prefix = "/api", .cluster_index = 1 },
    };
    try std.testing.expectEqual(@as(?u16, 1), route(&routes, null, "/api"));
    try std.testing.expectEqual(@as(?u16, 1), route(&routes, null, "/api/deep/path"));
    try std.testing.expectEqual(@as(?u16, null), route(&routes, null, "/"));
    try std.testing.expectEqual(@as(?u16, null), route(&routes, null, "/apix"));
    try std.testing.expectEqual(@as(?u16, null), route(&routes, null, "/elsewhere"));
}

test "router: a slash-terminated prefix matches its whole subtree" {
    const routes = [_]Route{
        .{ .prefix = "/assets/", .cluster_index = 5 },
        .{ .prefix = "/", .cluster_index = 0 },
    };
    try std.testing.expectEqual(@as(?u16, 5), route(&routes, null, "/assets/img.png"));
    // "/assets" (no trailing slash) is not under "/assets/"; catch-all.
    try std.testing.expectEqual(@as(?u16, 0), route(&routes, null, "/assets"));
}

test "router: a host-specific route beats an any-host one, whatever the prefix" {
    // As config.zig sorts them: host-specific first, then longest-prefix.
    const routes = [_]Route{
        .{ .host = "a.example", .prefix = "/api", .cluster_index = 1 },
        .{ .host = "a.example", .prefix = "/", .cluster_index = 2 },
        .{ .prefix = "/deep", .cluster_index = 3 },
        .{ .prefix = "/", .cluster_index = 0 },
    };
    // Host a.example: its own routes win, longest-prefix among them.
    try std.testing.expectEqual(@as(?u16, 1), route(&routes, "a.example", "/api/x"));
    // Host a.example, /deep/x: no host route matches except its own
    // catch-all "/", which STILL beats the longer any-host "/deep" —
    // host-specificity dominates prefix length.
    try std.testing.expectEqual(@as(?u16, 2), route(&routes, "a.example", "/deep/x"));
    try std.testing.expectEqual(@as(?u16, 2), route(&routes, "a.example", "/other"));
    // A different host falls entirely to the any-host routes.
    try std.testing.expectEqual(@as(?u16, 3), route(&routes, "b.example", "/deep/x"));
    try std.testing.expectEqual(@as(?u16, 0), route(&routes, "b.example", "/api"));
    // No usable Host matches only any-host routes.
    try std.testing.expectEqual(@as(?u16, 3), route(&routes, null, "/deep"));
    try std.testing.expectEqual(@as(?u16, 0), route(&routes, null, "/whatever"));
}

test "router: a host-scoped table 404s a request whose host is absent" {
    const routes = [_]Route{
        .{ .host = "only.example", .prefix = "/", .cluster_index = 1 },
    };
    try std.testing.expectEqual(@as(?u16, 1), route(&routes, "only.example", "/x"));
    // Wrong host, or no host at all: nothing any-host to fall back to.
    try std.testing.expectEqual(@as(?u16, null), route(&routes, "other.example", "/x"));
    try std.testing.expectEqual(@as(?u16, null), route(&routes, null, "/x"));
}
