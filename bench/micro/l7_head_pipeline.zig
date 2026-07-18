//! Tier-0 micro bench (§9): the per-request L7 head CPU — parse the
//! request head, render it upstream, parse the origin response head,
//! render it downstream — the work an L7 exchange does that an L4 relay
//! does not. Realistic small-GET heads (what the Tier-1 loopback bench
//! drives). poop A/B on hardware counters; decision tool, not a CI gate.
//!
//! Run: `zig build bench-micro` then
//! `poop ./zig-out/bin/zoxy-bench-l7_head_pipeline` for the absolute
//! per-iteration cost, or poop two builds to A/B a candidate change.

const std = @import("std");

const zoxy = @import("zoxy");

const parser = zoxy.http.parser;
const render = zoxy.http.render;

const iterations: u64 = 1_000_000;

const request_head =
    "GET / HTTP/1.1\r\n" ++
    "Host: 127.0.0.1:18181\r\n" ++
    "User-Agent: zrk/0.1\r\n" ++
    "Accept: */*\r\n\r\n";

const response_head =
    "HTTP/1.1 200 OK\r\n" ++
    "Server: nginx\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "Content-Length: 18\r\n\r\n";

pub fn main() void {
    var request_storage: parser.HeaderStorage = undefined;
    var response_storage: parser.HeaderStorage = undefined;
    var upstream_head: [zoxy.constants.head_bytes_max]u8 = undefined;
    var downstream_head: [zoxy.constants.head_bytes_max]u8 = undefined;

    var checksum: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        const request = parser.parseRequestHead(request_head, false, &request_storage) catch unreachable;
        const upstream = render.renderRequestHead(&request, false, &upstream_head) catch unreachable;
        const response = parser.parseResponseHead(response_head, false, &response_storage, request.method) catch unreachable;
        const downstream = render.renderResponseHead(&response, true, &downstream_head) catch unreachable;

        // Consume the outputs so nothing is dead-code-eliminated.
        checksum +%= upstream[upstream.len - 1];
        checksum +%= downstream[downstream.len - 1];
        checksum +%= @intFromEnum(request.method);
        checksum +%= response.status;
    }
    std.debug.print("checksum {d}\n", .{checksum});
}
