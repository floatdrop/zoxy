//! Load balancing across a cluster's endpoints. Phase-0 ships round-robin;
//! P2C/EWMA is Phase-1 (docs/DESIGN.md §7). State is per-worker (single-threaded,
//! share-nothing), so a plain counter needs no synchronization.

const std = @import("std");
const config = @import("../config.zig");
const Cluster = config.Cluster;
const Endpoint = config.Endpoint;

pub const RoundRobin = struct {
    next: usize = 0,

    /// Pick the next endpoint, cycling through the cluster. Null if the cluster
    /// has no endpoints.
    pub fn pick(rr: *RoundRobin, cluster: *const Cluster) ?*const Endpoint {
        if (cluster.endpoints.len == 0) return null;
        const index = rr.next % cluster.endpoints.len;
        rr.next +%= 1;
        return &cluster.endpoints[index];
    }
};

// ---- tests ----------------------------------------------------------------

test "balancer: round-robin cycles endpoints" {
    var cfg = try config.parse(std.testing.allocator,
        \\{
        \\  "listen": "0.0.0.0:80",
        \\  "routes": [{ "cluster": "c" }],
        \\  "clusters": [{ "name": "c", "endpoints": ["127.0.0.1:1", "127.0.0.1:2", "127.0.0.1:3"] }]
        \\}
    );
    defer cfg.deinit();
    const cluster = cfg.findCluster("c").?;

    var rr: RoundRobin = .{};
    const ports = [_]u16{ 1, 2, 3, 1, 2 };
    for (ports) |expected| {
        try std.testing.expectEqual(expected, rr.pick(cluster).?.address.port);
    }
}

test "balancer: empty cluster yields null" {
    var cfg = try config.parse(std.testing.allocator,
        \\{ "listen": "0.0.0.0:80", "routes": [{ "cluster": "c" }], "clusters": [{ "name": "c", "endpoints": [] }] }
    );
    defer cfg.deinit();
    var rr: RoundRobin = .{};
    try std.testing.expect(rr.pick(cfg.findCluster("c").?) == null);
}
