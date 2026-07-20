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

test "filter: isRejectStatus admits the policy set only" {
    try std.testing.expect(isRejectStatus(403));
    try std.testing.expect(isRejectStatus(429));
    try std.testing.expect(!isRejectStatus(200));
    try std.testing.expect(!isRejectStatus(503));
}
