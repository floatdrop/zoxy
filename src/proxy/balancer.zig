//! Load balancing across a cluster's endpoints: power-of-two-choices (P2C)
//! least-request (docs/DESIGN.md §7 Phase 2). Two uniform draws, keep the one
//! with fewer in-flight attempts — O(1), no scan, and provably close to
//! least-loaded ("The Power of Two Choices in Randomized Load Balancing",
//! Mitzenmacher). In-flight counts live in the per-worker `ClusterState`
//! (share-nothing, no synchronization); each worker balances its own traffic,
//! which is the Envoy/Linkerd worker-local model.
//!
//! Availability = healthy (active health checks) and not ejected (passive
//! outlier detection). When *no* endpoint is available the balancer fails
//! open and routes anyway (simplified Envoy panic mode): an all-ejected
//! cluster must not become a self-sustaining 503 storm — health signals can
//! be stale, and the outage may be on our side of the network.
//!
//! Weighted picks are deferred: least-request already self-adapts to unequal
//! endpoint capacity (a slow endpoint accumulates in-flight and repels
//! traffic). If config weights land later, compare cross-multiplied loads
//! (`in_flight_a * weight_b` vs `in_flight_b * weight_a`) — no division.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");
const config = @import("../config.zig");
const Cluster = config.Cluster;
const ClusterState = @import("resilience.zig").ClusterState;

/// Pick an endpoint index, favoring the less-loaded of two random draws.
/// Null only for an empty cluster. `exclude_index` (a retry's failed
/// endpoint) is avoided when the cluster offers any alternative, but soft:
/// the only endpoint, or the only *available* one, is still returned.
pub fn pick_least_request(
    cluster: *const Cluster,
    state: *const ClusterState,
    random: std.Random,
    now_ns: u64,
    exclude_index: ?u32,
) ?u32 {
    const count: u32 = @intCast(cluster.endpoints.len);
    if (count == 0) return null;
    assert(count <= constants.endpoints_per_cluster_max); // enforced by config.parse
    if (exclude_index) |exclude| assert(exclude < count);
    if (count == 1) return 0; // no choice to make

    const first = draw_excluding(random, count, exclude_index);
    const second = draw_excluding(random, count, exclude_index);
    assert(first < count);
    assert(second < count);
    const first_available = is_available(state, first, now_ns);
    const second_available = is_available(state, second, now_ns);
    if (first_available and second_available) return least_loaded(state, first, second);
    if (first_available) return first;
    if (second_available) return second;

    // Both draws unavailable: bounded scan from a random offset for any
    // available endpoint, still avoiding the excluded one.
    const offset = random.uintLessThan(u32, count);
    var step: u32 = 0;
    while (step < count) : (step += 1) {
        const index = (offset + step) % count;
        if (exclude_index != null and index == exclude_index.?) continue;
        if (is_available(state, index, now_ns)) return index;
    }
    // The excluded endpoint beats an unavailable one.
    if (exclude_index) |exclude| {
        if (is_available(state, exclude, now_ns)) return exclude;
    }
    // Panic mode: zero available endpoints — fail open and route anyway to
    // the less-loaded draw (see the module comment).
    return least_loaded(state, first, second);
}

/// Consistent-hash pick (docs/DESIGN.md §7 Phase 4): the Maglev table maps
/// the hash to its home endpoint; if that one is unavailable (or excluded —
/// a retry's failed endpoint), walk forward through the table so the
/// fallback is *deterministic* for the hash, not random. Each endpoint is
/// considered once (a tried-bitmask bounds the walk). Same fail-open rule
/// as P2C: zero available endpoints still routes — to the home endpoint.
pub fn pick_hashed(
    cluster: *const Cluster,
    state: *const ClusterState,
    hash: u64,
    now_ns: u64,
    exclude_index: ?u32,
) ?u32 {
    const count: u32 = @intCast(cluster.endpoints.len);
    if (count == 0) return null;
    assert(count <= constants.endpoints_per_cluster_max);
    const table = cluster.maglev_table;
    assert(table.len == constants.maglev_table_entries); // hashed clusters only
    if (exclude_index) |exclude| assert(exclude < count);

    const home: u32 = table[hash % table.len];
    assert(home < count); // the build wrote only real endpoint indices
    var tried: u32 = 0;
    var tried_count: u32 = 0;
    var step: u64 = 0;
    while (tried_count < count and step < table.len) : (step += 1) {
        const index: u32 = table[(hash + step) % table.len];
        assert(index < count);
        const bit = @as(u32, 1) << @intCast(index);
        if (tried & bit != 0) continue;
        tried |= bit;
        tried_count += 1;
        if (exclude_index != null and index == exclude_index.?) continue;
        if (is_available(state, index, now_ns)) return index;
    }
    // The excluded endpoint beats an unavailable one.
    if (exclude_index) |exclude| {
        if (is_available(state, exclude, now_ns)) return exclude;
    }
    // Panic mode: fail open to the hash's home endpoint (affinity intact).
    return home;
}

/// One uniform draw over [0, count), skipping `exclude` by drawing over
/// count-1 and shifting past it. A single-endpoint cluster ignores the
/// exclusion — the only option is better than none.
fn draw_excluding(random: std.Random, count: u32, exclude: ?u32) u32 {
    assert(count > 0);
    if (exclude) |ex| {
        assert(ex < count);
        if (count > 1) {
            var index = random.uintLessThan(u32, count - 1);
            if (index >= ex) index += 1;
            assert(index != ex);
            return index;
        }
    }
    return random.uintLessThan(u32, count);
}

fn is_available(state: *const ClusterState, index: u32, now_ns: u64) bool {
    assert(index < constants.endpoints_per_cluster_max);
    const endpoint = &state.endpoints[index];
    if (!endpoint.healthy) return false;
    // An expired ejection deadline counts as available; clearing the state
    // (lazy un-ejection) is the outlier module's job, not the balancer's.
    return now_ns >= endpoint.ejected_until_ns;
}

fn least_loaded(state: *const ClusterState, first: u32, second: u32) u32 {
    assert(first < constants.endpoints_per_cluster_max);
    assert(second < constants.endpoints_per_cluster_max);
    const first_load = state.endpoints[first].in_flight;
    const second_load = state.endpoints[second].in_flight;
    return if (second_load < first_load) second else first;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

fn test_cluster(gpa: std.mem.Allocator, endpoint_count: u32) !config.Config {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print(
        \\{{ "listen": "0.0.0.0:80", "routes": [{{ "cluster": "c" }}],
        \\   "clusters": [{{ "name": "c", "endpoints": [
    , .{});
    var i: u32 = 0;
    while (i < endpoint_count) : (i += 1) {
        if (i > 0) try w.print(",", .{});
        try w.print("\"127.0.0.1:{d}\"", .{9000 + i});
    }
    try w.print("] }}] }}", .{});
    return config.parse(gpa, w.buffered());
}

test "balancer: empty cluster yields null, single endpoint short-circuits" {
    var empty = try config.parse(testing.allocator,
        \\{ "listen": "0.0.0.0:80", "routes": [{ "cluster": "c" }],
        \\  "clusters": [{ "name": "c", "endpoints": [] }] }
    );
    defer empty.deinit();
    var single = try test_cluster(testing.allocator, 1);
    defer single.deinit();

    var state = ClusterState{};
    var prng = std.Random.DefaultPrng.init(42);
    try testing.expect(pick_least_request(
        empty.find_cluster("c").?,
        &state,
        prng.random(),
        0,
        null,
    ) == null);
    // Even an unhealthy single endpoint is returned (fail open).
    state.endpoints[0].healthy = false;
    try testing.expectEqual(
        @as(?u32, 0),
        pick_least_request(single.find_cluster("c").?, &state, prng.random(), 0, null),
    );
}

test "balancer: picks favor the endpoint with fewer requests in flight" {
    var cfg = try test_cluster(testing.allocator, 2);
    defer cfg.deinit();
    const cluster = cfg.find_cluster("c").?;

    var state = ClusterState{};
    state.endpoints[0].in_flight = 10;
    state.endpoints[1].in_flight = 0;
    var prng = std.Random.DefaultPrng.init(42);
    var picks = [2]u32{ 0, 0 };
    for (0..100) |_| {
        const index = pick_least_request(cluster, &state, prng.random(), 0, null).?;
        picks[index] += 1;
    }
    // P2C over two endpoints picks the loaded one only when both draws land
    // on it (probability 1/4): expect ~75 picks of the idle endpoint.
    try testing.expect(picks[1] > picks[0]);
    try testing.expect(picks[1] >= 60);
    try testing.expect(picks[0] <= 40);
}

test "balancer: excluded endpoint is avoided when alternatives exist" {
    var cfg = try test_cluster(testing.allocator, 3);
    defer cfg.deinit();
    const cluster = cfg.find_cluster("c").?;

    var state = ClusterState{};
    var prng = std.Random.DefaultPrng.init(7);
    for (0..100) |_| {
        const index = pick_least_request(cluster, &state, prng.random(), 0, 1).?;
        try testing.expect(index != 1);
    }
}

test "balancer: unavailable endpoints are skipped via the fallback scan" {
    var cfg = try test_cluster(testing.allocator, 4);
    defer cfg.deinit();
    const cluster = cfg.find_cluster("c").?;

    // Only endpoint 2 is available; both random draws will often miss it.
    var state = ClusterState{};
    state.endpoints[0].healthy = false;
    state.endpoints[1].ejected_until_ns = 1000; // ejected until t=1000
    state.endpoints[3].healthy = false;
    var prng = std.Random.DefaultPrng.init(7);
    for (0..100) |_| {
        const index = pick_least_request(cluster, &state, prng.random(), 500, null).?;
        try testing.expectEqual(@as(u32, 2), index);
    }
    // Once the ejection deadline passes, endpoint 1 is available again.
    var seen_one = false;
    for (0..100) |_| {
        const index = pick_least_request(cluster, &state, prng.random(), 1000, null).?;
        try testing.expect(index == 1 or index == 2);
        if (index == 1) seen_one = true;
    }
    try testing.expect(seen_one);
}

fn test_hashed_cluster(gpa: std.mem.Allocator, endpoint_count: u32) !config.Config {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print(
        \\{{ "listen": "0.0.0.0:80", "routes": [{{ "cluster": "c" }}],
        \\   "clusters": [{{ "name": "c",
        \\     "lb": {{ "policy": "maglev" }}, "endpoints": [
    , .{});
    var i: u32 = 0;
    while (i < endpoint_count) : (i += 1) {
        if (i > 0) try w.print(",", .{});
        try w.print("\"127.0.0.1:{d}\"", .{9000 + i});
    }
    try w.print("] }}] }}", .{});
    return config.parse(gpa, w.buffered());
}

test "balancer: hashed picks are consistent and walk deterministically" {
    var cfg = try test_hashed_cluster(testing.allocator, 4);
    defer cfg.deinit();
    const cluster = cfg.find_cluster("c").?;

    var state = ClusterState{};
    const hash = std.hash.Wyhash.hash(0, "/users/42");
    const home = pick_hashed(cluster, &state, hash, 0, null).?;
    for (0..10) |_| { // affinity: the same key lands on the same endpoint
        try testing.expectEqual(home, pick_hashed(cluster, &state, hash, 0, null).?);
    }

    // Home goes unhealthy: the fallback is deterministic too — and it is
    // not a re-randomization (repeatable across calls).
    state.endpoints[home].healthy = false;
    const fallback = pick_hashed(cluster, &state, hash, 0, null).?;
    try testing.expect(fallback != home);
    for (0..10) |_| {
        try testing.expectEqual(fallback, pick_hashed(cluster, &state, hash, 0, null).?);
    }
    // Home recovers: the key goes home again (consistency restored).
    state.endpoints[home].healthy = true;
    try testing.expectEqual(home, pick_hashed(cluster, &state, hash, 0, null).?);
}

test "balancer: hashed retry excludes the failed endpoint but not the last one" {
    var cfg = try test_hashed_cluster(testing.allocator, 3);
    defer cfg.deinit();
    const cluster = cfg.find_cluster("c").?;

    var state = ClusterState{};
    const hash = std.hash.Wyhash.hash(0, "/session/abc");
    const home = pick_hashed(cluster, &state, hash, 0, null).?;
    const retry = pick_hashed(cluster, &state, hash, 0, home).?;
    try testing.expect(retry != home);

    // Everyone but the failed endpoint is unavailable: the exclusion is
    // soft — the failed endpoint still beats an unavailable one.
    for (0..3) |index| {
        if (index != home) state.endpoints[index].healthy = false;
    }
    try testing.expectEqual(home, pick_hashed(cluster, &state, hash, 0, home).?);
}

test "balancer: hashed pick fails open to the home endpoint" {
    var cfg = try test_hashed_cluster(testing.allocator, 3);
    defer cfg.deinit();
    const cluster = cfg.find_cluster("c").?;

    var state = ClusterState{};
    const hash = std.hash.Wyhash.hash(0, "/anything");
    const home = pick_hashed(cluster, &state, hash, 0, null).?;
    for (&state.endpoints) |*endpoint| endpoint.healthy = false;
    // Panic mode keeps affinity: the dead home endpoint, not a random one.
    try testing.expectEqual(home, pick_hashed(cluster, &state, hash, 0, null).?);
}

test "balancer: hashed picks spread distinct keys across endpoints" {
    var cfg = try test_hashed_cluster(testing.allocator, 4);
    defer cfg.deinit();
    const cluster = cfg.find_cluster("c").?;

    var state = ClusterState{};
    var counts = [_]u32{0} ** 4;
    var key_buf: [32]u8 = undefined;
    for (0..400) |sequence| {
        const key = std.fmt.bufPrint(&key_buf, "/item/{d}", .{sequence}) catch unreachable;
        const hash = std.hash.Wyhash.hash(0, key);
        counts[pick_hashed(cluster, &state, hash, 0, null).?] += 1;
    }
    for (counts) |count| { // 400 keys over 4 endpoints: each gets a real share
        try testing.expect(count > 50);
        try testing.expect(count < 150);
    }
}

test "balancer: zero available endpoints fails open and still routes" {
    var cfg = try test_cluster(testing.allocator, 3);
    defer cfg.deinit();
    const cluster = cfg.find_cluster("c").?;

    var state = ClusterState{};
    for (&state.endpoints) |*endpoint| endpoint.healthy = false;
    var prng = std.Random.DefaultPrng.init(1);
    for (0..20) |_| {
        // Panic mode: a pick is always produced, never null.
        const index = pick_least_request(cluster, &state, prng.random(), 0, null).?;
        try testing.expect(index < 3);
    }
}
