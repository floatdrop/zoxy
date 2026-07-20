//! §7 "filters are data, not code": per-listener request-processing rules,
//! compiled at config load (`config.zig`) into immutable arena tables and
//! interpreted per request — never scripted, never allocating. A rule is a
//! match (a conjunction of predicates over the parsed head, in the §7
//! canonical forms so a filter and the router never disagree) and an
//! ordered action list drawn from a closed enum. Cluster selection is NOT
//! an action: the route table owns the backend decision (§7), so filters
//! never compete with routing. This module holds the compiled shapes; the
//! interpreter and the config-load compiler live in slices to come.

const std = @import("std");

const parser = @import("parser.zig");
const router = @import("router.zig");

const assert = std.debug.assert;

/// A single header predicate: the named header must be present, or equal,
/// or contain the given value (case-insensitive name, per RFC 9110).
pub const HeaderMatch = struct {
    name: []const u8,
    kind: Kind,
    /// Unused for `.present`; the compared value otherwise.
    value: []const u8,

    pub const Kind = enum(u8) { present, equals, contains };
};

/// A rule's match: every present predicate must hold (a conjunction). A
/// null/empty field is "any", so an all-null match is an unconditional
/// rule. Host and path prefix are already canonical (§7), compared
/// byte-for-byte against the request's canonical host/path.
pub const Match = struct {
    /// Registered methods the rule applies to; null = any method.
    methods: ?std.EnumSet(parser.Method) = null,
    host: ?[]const u8 = null,
    path_prefix: ?[]const u8 = null,
    headers: []const HeaderMatch = &.{},
};

/// One header edit's name and value (value unused for a remove).
pub const HeaderEdit = struct {
    name: []const u8,
    value: []const u8,
};

/// A canonical path-prefix rewrite of the *forwarded* request only
/// (routing already chose the cluster, §7): the matched `from` prefix is
/// replaced by `to`, and the result re-canonicalized before it goes
/// upstream. Both are validated canonical at config load.
pub const Rewrite = struct {
    from: []const u8,
    to: []const u8,
};

/// The closed action enum (§7): no `pick cluster` (routing owns the
/// backend), no scripting. Anything past this is a Zig function in the
/// owning phase module, added at compile time.
pub const Action = union(enum) {
    /// Answer a static status and stop (§8 static-response machinery).
    reject: u16,
    /// Set (replacing any existing), add (append), or remove a header on
    /// the forwarded request, applied during the head render.
    header_set: HeaderEdit,
    header_add: HeaderEdit,
    header_remove: []const u8,
    /// Rewrite the forwarded canonical path's prefix.
    rewrite_prefix: Rewrite,
};

/// One compiled rule: match, then its ordered actions.
pub const Rule = struct {
    match: Match,
    actions: []const Action,
};

/// The statuses a `reject` action may name — a subset of the §8 static
/// responses that make sense as a policy verdict. Config rejects any
/// other value at load, and `shed.staticResponse` must support each.
pub fn isRejectStatus(status: u16) bool {
    return switch (status) {
        400, 403, 404, 429 => true,
        else => false,
    };
}

/// The parsed head a rule matches against, in the §7 canonical forms:
/// `host` is the canonical routing host (null when absent/unmatchable),
/// `path` the canonical request path (or "/" for asterisk-form), and
/// `headers` the parsed head's headers (zero-copy slices).
pub const RequestView = struct {
    method: parser.Method,
    host: ?[]const u8,
    path: []const u8,
    headers: []const parser.Header,
};

/// The reject status of the first matching rule that carries a `reject`
/// action, or null to proceed (§7). Rules are evaluated top-down and
/// actions in order, so the first reject reached wins — and because a
/// matched rule's reject stops the request, any header/rewrite edits are
/// then moot (they apply only to a request that forwards, handled at the
/// render). Bounded loops over immutable arena data; no allocation.
pub fn firstReject(rules: []const Rule, view: RequestView) ?u16 {
    assert(view.path.len >= 1);
    assert(view.path[0] == '/');
    for (rules) |rule| {
        if (!matches(rule.match, view)) {
            continue;
        }
        for (rule.actions) |action| {
            switch (action) {
                .reject => |status| {
                    assert(isRejectStatus(status));
                    return status;
                },
                // Edits apply at the render, only when the request
                // forwards; a reject anywhere in a matched rule stops it.
                .header_set, .header_add, .header_remove, .rewrite_prefix => {},
            }
        }
    }
    return null;
}

/// Whether a rule's match — a conjunction — holds for the request. A
/// null/empty field is "any"; host and path prefix compare in the §7
/// canonical forms (the path via the router's segment-boundary match, so
/// filters and routing agree byte-for-byte).
fn matches(match: Match, view: RequestView) bool {
    if (match.methods) |set| {
        if (!set.contains(view.method)) {
            return false;
        }
    }
    if (match.host) |host| {
        const request_host = view.host orelse return false;
        if (!std.mem.eql(u8, host, request_host)) {
            return false;
        }
    }
    if (match.path_prefix) |prefix| {
        if (!router.prefixMatches(prefix, view.path)) {
            return false;
        }
    }
    for (match.headers) |header_match| {
        if (!headerMatches(header_match, view.headers)) {
            return false;
        }
    }
    return true;
}

/// Whether some header satisfies the predicate. Name comparison is
/// case-insensitive (RFC 9110); `equals`/`contains` compare the value
/// byte-exact / by substring. Multiple headers of the same name each get
/// a chance — the predicate holds if any does.
fn headerMatches(header_match: HeaderMatch, headers: []const parser.Header) bool {
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, header_match.name)) {
            continue;
        }
        switch (header_match.kind) {
            .present => return true,
            .equals => if (std.mem.eql(u8, header.value, header_match.value)) return true,
            .contains => if (std.mem.indexOf(u8, header.value, header_match.value) != null) return true,
        }
    }
    return false;
}

test "filter: isRejectStatus admits the policy set only" {
    try std.testing.expect(isRejectStatus(403));
    try std.testing.expect(isRejectStatus(429));
    try std.testing.expect(!isRejectStatus(200));
    try std.testing.expect(!isRejectStatus(503));
}

test "filter: firstReject matches on method, host, path, header" {
    const H = parser.Header;
    const rules = [_]Rule{
        // Reject a POST to /admin from a specific host with a header set.
        .{
            .match = .{
                .methods = blk: {
                    var set = std.EnumSet(parser.Method){};
                    set.insert(.post);
                    break :blk set;
                },
                .host = "api.example",
                .path_prefix = "/admin",
                .headers = &.{.{ .name = "X-Env", .kind = .equals, .value = "prod" }},
            },
            .actions = &.{.{ .reject = 403 }},
        },
    };
    const prod = [_]H{.{ .name = "x-env", .value = "prod" }};
    const dev = [_]H{.{ .name = "X-Env", .value = "dev" }};

    // Full match → 403.
    try std.testing.expectEqual(@as(?u16, 403), firstReject(&rules, .{
        .method = .post,
        .host = "api.example",
        .path = "/admin/users",
        .headers = &prod,
    }));
    // Wrong method, host, path, or header value → no reject.
    try std.testing.expectEqual(@as(?u16, null), firstReject(&rules, .{
        .method = .get, // not POST
        .host = "api.example",
        .path = "/admin",
        .headers = &prod,
    }));
    try std.testing.expectEqual(@as(?u16, null), firstReject(&rules, .{
        .method = .post,
        .host = "other.example", // wrong host
        .path = "/admin",
        .headers = &prod,
    }));
    try std.testing.expectEqual(@as(?u16, null), firstReject(&rules, .{
        .method = .post,
        .host = "api.example",
        .path = "/public", // not under /admin
        .headers = &prod,
    }));
    try std.testing.expectEqual(@as(?u16, null), firstReject(&rules, .{
        .method = .post,
        .host = "api.example",
        .path = "/admin",
        .headers = &dev, // header value mismatch
    }));
    // A segment-splitting path must not match the /admin prefix.
    try std.testing.expectEqual(@as(?u16, null), firstReject(&rules, .{
        .method = .post,
        .host = "api.example",
        .path = "/administrator",
        .headers = &prod,
    }));
}

test "filter: an all-any match is unconditional; edit-only rules never reject" {
    const rules = [_]Rule{
        .{ .match = .{}, .actions = &.{
            .{ .header_set = .{ .name = "X-Via", .value = "zoxy" } },
        } },
        .{ .match = .{ .path_prefix = "/blocked" }, .actions = &.{.{ .reject = 404 }} },
    };
    const empty: []const parser.Header = &.{};
    // The edit-only rule matches everything but does not reject.
    try std.testing.expectEqual(@as(?u16, null), firstReject(&rules, .{
        .method = .get,
        .host = null,
        .path = "/anything",
        .headers = empty,
    }));
    // The second rule rejects its prefix.
    try std.testing.expectEqual(@as(?u16, 404), firstReject(&rules, .{
        .method = .get,
        .host = null,
        .path = "/blocked/x",
        .headers = empty,
    }));
}
