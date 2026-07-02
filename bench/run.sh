#!/usr/bin/env bash
# End-to-end benchmark: load generator -> zoxy -> nginx origin, on loopback.
#
#   bench/run.sh [-R rate] [-d duration] [-c connections] [-t threads]
#
# Two runs at the same target rate, so the proxy hop cost is directly visible:
#   baseline:  generator -> nginx, with "Connection: close" (zoxy's Phase-0
#              one-request-per-connection model — a keep-alive baseline would
#              measure the handshake tax, not the proxy)
#   proxied:   generator -> zoxy -> nginx
#
# The generator is zrk (github.com/floatdrop/zrk): constant throughput with
# coordinated-omission-corrected latency. A closed-loop generator (wrk) stops
# sending when the server stalls, so the stall never shows up in its numbers;
# zrk charges backlogged requests from their *intended* send time. Set $ZRK to
# the binary or have `zrk` on PATH; otherwise this falls back to wrk via nix
# with a warning (its latencies are NOT corrected, treat them as optimistic).
#
# nginx is used from PATH when installed, otherwise fetched with `nix shell`.
# Ports are offset from the dev defaults so a running dev instance survives.
set -euo pipefail

RATE=30000
DURATION=10s
CONNECTIONS=64
THREADS=4
while getopts "R:d:c:t:h" opt; do
    case $opt in
        R) RATE=$OPTARG ;;
        d) DURATION=$OPTARG ;;
        c) CONNECTIONS=$OPTARG ;;
        t) THREADS=$OPTARG ;;
        *) sed -n '2,20p' "$0"; exit 2 ;;
    esac
done

ORIGIN_PORT=19000
PROXY_PORT=18080
ADMIN_PORT=19901

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
ZOXY_PID=""
cleanup() {
    [ -n "$ZOXY_PID" ] && kill "$ZOXY_PID" 2>/dev/null || true
    [ -f "$WORK/nginx.pid" ] && kill "$(cat "$WORK/nginx.pid")" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Bounded wait for an HTTP endpoint to come up (5s).
wait_for() {
    for _ in $(seq 1 50); do
        curl -sf -o /dev/null "$1" && return 0
        sleep 0.1
    done
    echo "bench: timeout waiting for $1" >&2
    exit 1
}

echo "== build (ReleaseFast) =="
(cd "$ROOT" && zig build -Doptimize=ReleaseFast)

mkdir -p "$WORK/nginx-tmp"
cat > "$WORK/nginx.conf" <<EOF
worker_processes 4;
error_log $WORK/nginx-error.log;
pid $WORK/nginx.pid;
events { worker_connections 4096; }
http {
    access_log off;
    default_type text/plain;
    client_body_temp_path $WORK/nginx-tmp;
    proxy_temp_path $WORK/nginx-tmp;
    fastcgi_temp_path $WORK/nginx-tmp;
    uwsgi_temp_path $WORK/nginx-tmp;
    scgi_temp_path $WORK/nginx-tmp;
    server {
        listen 127.0.0.1:$ORIGIN_PORT;
        return 200 "hello from origin - 64 bytes of payload for the benchmark!\n";
    }
}
EOF
cat > "$WORK/zoxy.json" <<EOF
{
  "listen": "127.0.0.1:$PROXY_PORT",
  "admin": "127.0.0.1:$ADMIN_PORT",
  "routes": [{ "cluster": "origin" }],
  "clusters": [{ "name": "origin", "endpoints": ["127.0.0.1:$ORIGIN_PORT"] }]
}
EOF

echo "== start origin (nginx :$ORIGIN_PORT) and proxy (zoxy :$PROXY_PORT) =="
if command -v nginx >/dev/null; then
    nginx -c "$WORK/nginx.conf"
else
    nix shell nixpkgs#nginx --command nginx -c "$WORK/nginx.conf"
fi
"$ROOT/zig-out/bin/zoxy" "$WORK/zoxy.json" > "$WORK/zoxy.log" 2>&1 &
ZOXY_PID=$!
wait_for "http://127.0.0.1:$ORIGIN_PORT/"
wait_for "http://127.0.0.1:$PROXY_PORT/"

ZRK=${ZRK:-$(command -v zrk || true)}
if [ -n "$ZRK" ]; then
    generate() { "$ZRK" -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" -R"$RATE" \
        --plain --latency "$@"; }
else
    echo "bench: zrk not found (set \$ZRK or install github.com/floatdrop/zrk)" >&2
    echo "bench: falling back to closed-loop wrk — latencies are NOT" >&2
    echo "bench: coordinated-omission-corrected; treat them as optimistic" >&2
    generate() { nix shell nixpkgs#wrk --command wrk -t"$THREADS" -c"$CONNECTIONS" \
        -d"$DURATION" --latency "$@"; }
fi

echo
echo "== baseline: generator -> nginx, Connection: close, target ${RATE}/s =="
generate -H 'Connection: close' "http://127.0.0.1:$ORIGIN_PORT/"

echo
echo "== proxied: generator -> zoxy -> nginx, target ${RATE}/s =="
generate "http://127.0.0.1:$PROXY_PORT/"

echo
echo "== zoxy counters =="
curl -s "http://127.0.0.1:$ADMIN_PORT/metrics"
