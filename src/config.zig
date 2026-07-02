//! Static proxy configuration. Parsed once at startup (allocation is allowed
//! here — the *serving* path is what must not allocate; docs/DESIGN.md §1). The
//! resulting `Config` is immutable and owns all its strings/slices in an arena.
//! Format is JSON (std-only, zero external deps).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const Ip4Address = std.Io.net.Ip4Address;

pub const Endpoint = struct {
    address: Ip4Address,
};

pub const Cluster = struct {
    name: []const u8,
    endpoints: []const Endpoint,
    /// Position within `Config.clusters`; always < `clusters_max`. Keys the
    /// per-cluster balancer state, which is reserved statically per worker.
    index: usize,
};

pub const Route = struct {
    /// "*" matches any Host.
    host: []const u8,
    /// Matched as a prefix of the request target; "/" matches everything.
    path_prefix: []const u8,
    cluster: []const u8,
};

pub const Config = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    listen: Ip4Address,
    routes: []const Route,
    clusters: []const Cluster,

    pub fn deinit(config: Config) void {
        config.arena.deinit();
        config.gpa.destroy(config.arena);
    }

    pub fn findCluster(config: Config, name: []const u8) ?*const Cluster {
        for (config.clusters) |*cluster| {
            if (std.mem.eql(u8, cluster.name, name)) return cluster;
        }
        return null;
    }
};

pub const ParseError = error{
    InvalidAddress,
    UnknownCluster,
    NoClusters,
    TooManyClusters,
} || std.json.ParseError(std.json.Scanner) || std.mem.Allocator.Error;

/// JSON shape mirrored 1:1 for decoding, then lowered into `Config`.
const Dto = struct {
    listen: []const u8,
    routes: []const RouteDto,
    clusters: []const ClusterDto,

    const RouteDto = struct {
        host: []const u8 = "*",
        path_prefix: []const u8 = "/",
        cluster: []const u8,
    };
    const ClusterDto = struct {
        name: []const u8,
        endpoints: []const []const u8,
    };
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError!Config {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Decode into the DTO with a throwaway arena, then dupe what we keep.
    const parsed = try std.json.parseFromSlice(Dto, gpa, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const dto = parsed.value;

    // Balancer state is reserved statically, one counter per cluster index.
    if (dto.clusters.len > constants.clusters_max) return error.TooManyClusters;
    const clusters = try a.alloc(Cluster, dto.clusters.len);
    assert(clusters.len == dto.clusters.len);
    assert(clusters.len <= constants.clusters_max);
    for (dto.clusters, clusters, 0..) |dc, *cluster, index| {
        const endpoints = try a.alloc(Endpoint, dc.endpoints.len);
        for (dc.endpoints, endpoints) |text_addr, *endpoint| {
            endpoint.* = .{ .address = try parseAddress(text_addr) };
        }
        cluster.* = .{
            .name = try a.dupe(u8, dc.name),
            .endpoints = endpoints,
            .index = index,
        };
    }

    const routes = try a.alloc(Route, dto.routes.len);
    assert(routes.len == dto.routes.len);
    for (dto.routes, routes) |dr, *route| {
        route.* = .{
            .host = try a.dupe(u8, dr.host),
            .path_prefix = try a.dupe(u8, dr.path_prefix),
            .cluster = try a.dupe(u8, dr.cluster),
        };
    }

    // Validate every route references a real cluster before we commit.
    for (routes) |route| {
        if (findClusterIn(clusters, route.cluster) == null) return error.UnknownCluster;
    }

    return .{
        .gpa = gpa,
        .arena = arena,
        .listen = try parseAddress(dto.listen),
        .routes = routes,
        .clusters = clusters,
    };
}

fn findClusterIn(clusters: []const Cluster, name: []const u8) ?*const Cluster {
    for (clusters) |*cluster| {
        if (std.mem.eql(u8, cluster.name, name)) return cluster;
    }
    return null;
}

/// Parse "host:port" (IPv4) into an address.
fn parseAddress(text: []const u8) error{InvalidAddress}!Ip4Address {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidAddress;
    assert(colon < text.len); // lastIndexOfScalar returns an in-bounds index
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return error.InvalidAddress;
    return Ip4Address.parse(text[0..colon], port) catch return error.InvalidAddress;
}

// ---- tests ----------------------------------------------------------------

const test_config =
    \\{
    \\  "listen": "0.0.0.0:8080",
    \\  "routes": [
    \\    { "host": "api.example.com", "path_prefix": "/v1", "cluster": "api" },
    \\    { "cluster": "default" }
    \\  ],
    \\  "clusters": [
    \\    { "name": "api", "endpoints": ["127.0.0.1:9001", "127.0.0.1:9002"] },
    \\    { "name": "default", "endpoints": ["127.0.0.1:9000"] }
    \\  ]
    \\}
;

test "config: parses listen, routes, clusters" {
    var config = try parse(std.testing.allocator, test_config);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 8080), config.listen.port);
    try std.testing.expectEqual(@as(usize, 2), config.routes.len);
    try std.testing.expectEqual(@as(usize, 2), config.clusters.len);

    // Defaults are applied for the second route.
    try std.testing.expectEqualStrings("*", config.routes[1].host);
    try std.testing.expectEqualStrings("/", config.routes[1].path_prefix);

    const api = config.findCluster("api").?;
    try std.testing.expectEqual(@as(usize, 2), api.endpoints.len);
    try std.testing.expectEqual(@as(u16, 9002), api.endpoints[1].address.port);
    try std.testing.expect(config.findCluster("nope") == null);
}

test "config: rejects a route to an unknown cluster" {
    const bad =
        \\{ "listen": "0.0.0.0:80", "routes": [{ "cluster": "ghost" }], "clusters": [] }
    ;
    try std.testing.expectError(error.UnknownCluster, parse(std.testing.allocator, bad));
}

test "config: rejects more clusters than clusters_max" {
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{{ \"listen\": \"0.0.0.0:80\", \"routes\": [], \"clusters\": [", .{});
    var i: usize = 0;
    while (i < constants.clusters_max + 1) : (i += 1) {
        if (i > 0) try w.print(",", .{});
        try w.print("{{ \"name\": \"c{d}\", \"endpoints\": [] }}", .{i});
    }
    try w.print("] }}", .{});
    try std.testing.expectError(
        error.TooManyClusters,
        parse(std.testing.allocator, w.buffered()),
    );
}

test "config: rejects an invalid address" {
    const bad =
        \\{ "listen": "not-an-address", "routes": [], "clusters": [] }
    ;
    try std.testing.expectError(error.InvalidAddress, parse(std.testing.allocator, bad));
}
