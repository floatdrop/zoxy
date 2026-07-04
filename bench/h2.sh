#!/usr/bin/env bash
# HTTP/2 benchmark: load generator -> zoxy -> nginx origin, on loopback.
#
#   bench/h2.sh [-d duration] [-c connections] [-t threads]
#
# zoxy speaks HTTP/2 to the client ONLY over TLS+ALPN (there is no plaintext
# h2c on the listener), and translates it to HTTP/1.1 upstream. So the whole
# client side is h2-over-TLS; the origin stays H1 behind the proxy. For each
# multiplexing level (-m = concurrent streams per connection) the script runs:
#   direct:  generator -> nginx  (nginx's own TLS + http2 listener)
#   proxied: generator -> zoxy   (zoxy terminates TLS+h2, translates to H1 nginx)
# so the direct-vs-proxied gap is zoxy's h2 hop cost: TLS termination + HPACK +
# frame handling + h2->h1 translation + the pooled H1 upstream.
#
# READ THE NUMBERS RIGHT — h2 is few-connections-many-streams, so req/s here is
# NOT `conns/latency` like the H1 `-m1` bench. At -m1 it is a latency test (one
# stream/conn); at higher -m the streams multiplex over each connection and
# req/s reflects multiplexed throughput. zoxy advertises
# SETTINGS_MAX_CONCURRENT_STREAMS=64, so -m100 is server-capped at 64 in flight
# (h2load opens more as others finish). Connections stay low (-c8 default)
# because each worker caps at h2_connections_max=16 live h2 connections; raise
# -m, not -c, to add load. Each role is pinned to disjoint cores so the
# proxied run never steals cores from the generator/origin.
#
# h2load (nghttp2) and nginx come from PATH when present, else `nix shell`.
# NOTE: this h2load build has no `-k`; it does not verify certs anyway, so the
# self-signed fixture under src/tls/testdata is used as-is over plain https://.
# Ports are offset from the dev defaults so a running dev instance survives.
set -euo pipefail

DURATION=10s
CONNECTIONS=8
THREADS=""
MPLEX="1 32 100"       # multiplexing sweep (h2load -m); override with -m "1 16"
ACCEPT_MODE=reuseport  # zoxy default; -a shared spreads h2 conns off the hot worker
while getopts "d:c:t:m:a:h" opt; do
    case $opt in
        d) DURATION=$OPTARG ;;
        c) CONNECTIONS=$OPTARG ;;
        t) THREADS=$OPTARG ;;
        m) MPLEX=$OPTARG ;;
        a) ACCEPT_MODE=$OPTARG ;;
        *) sed -n '2,20p' "$0"; exit 2 ;;
    esac
done
DURATION_S=${DURATION//[^0-9]/}

ORIGIN_PORT=19000        # nginx H1 plaintext — zoxy's upstream
ORIGIN_TLS_PORT=19443    # nginx TLS + http2 — the direct baseline
PROXY_PORT=18080
ADMIN_PORT=19901

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CERT=$ROOT/src/tls/testdata/certificate.pem
KEY=$ROOT/src/tls/testdata/private_key.pem
WORK=$(mktemp -d)
ZOXY_PID=""
cleanup() {
    [ -n "$ZOXY_PID" ] && kill "$ZOXY_PID" 2>/dev/null || true
    [ -f "$WORK/nginx.pid" ] && kill "$(cat "$WORK/nginx.pid")" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Bounded wait for an endpoint (5s); -k so the self-signed TLS ports pass too.
wait_for() {
    for _ in $(seq 1 50); do
        curl -skf -o /dev/null "$1" && return 0
        sleep 0.1
    done
    echo "bench: timeout waiting for $1" >&2
    exit 1
}

# --- core pinning (see bench/run.sh for the rationale): origin smallest (canned
# 200), proxy + generator split the rest. zoxy is sized by its visible CPUs, so
# taskset both pins and sizes it. Same origin/gen cores in every run.
NCPU=$(nproc)
PIN_ORIGIN=""; PIN_PROXY=""; PIN_GEN=""
ORIGIN_CPUS=""; PROXY_CPUS=""; GEN_CPUS=""
NGINX_WORKERS=4
PROXY_COUNT=0
seq_csv() { seq "$1" "$2" | paste -sd, -; }
if command -v taskset >/dev/null && [ "$NCPU" -ge 3 ]; then
    origin_count=$(( NCPU / 4 )); [ "$origin_count" -lt 1 ] && origin_count=1
    rest=$(( NCPU - origin_count ))
    PROXY_COUNT=$(( rest / 2 )); [ "$PROXY_COUNT" -lt 1 ] && PROXY_COUNT=1
    gen_count=$(( rest - PROXY_COUNT ))
    ORIGIN_CPUS=$(seq_csv 0 $((origin_count - 1)))
    PROXY_CPUS=$(seq_csv "$origin_count" $((origin_count + PROXY_COUNT - 1)))
    GEN_CPUS=$(seq_csv $((origin_count + PROXY_COUNT)) $((NCPU - 1)))
    PIN_ORIGIN="taskset -c $ORIGIN_CPUS"
    PIN_PROXY="taskset -c $PROXY_CPUS"
    PIN_GEN="taskset -c $GEN_CPUS"
    NGINX_WORKERS=$origin_count
    [ -z "$THREADS" ] && THREADS=$gen_count
fi
[ -z "$THREADS" ] && THREADS=4
# h2load needs connections >= threads.
[ "$THREADS" -gt "$CONNECTIONS" ] && THREADS=$CONNECTIONS

echo "== build (ReleaseFast) =="
(cd "$ROOT" && zig build -Doptimize=ReleaseFast)

mkdir -p "$WORK/nginx-tmp"
cat > "$WORK/nginx.conf" <<EOF
worker_processes $NGINX_WORKERS;
error_log $WORK/nginx-error.log;
pid $WORK/nginx.pid;
events { worker_connections 4096; }
http {
    access_log off;
    default_type text/plain;
    # Default keepalive_requests (1000) closes each h2 connection after 1000
    # requests (GOAWAY); in duration mode h2load does not fully re-establish, so
    # the direct baseline would flatline at conns*1000. Lift it out of the way.
    keepalive_requests 100000000;
    keepalive_timeout 3600s;
    client_body_temp_path $WORK/nginx-tmp;
    proxy_temp_path $WORK/nginx-tmp;
    fastcgi_temp_path $WORK/nginx-tmp;
    uwsgi_temp_path $WORK/nginx-tmp;
    scgi_temp_path $WORK/nginx-tmp;
    server {
        listen 127.0.0.1:$ORIGIN_PORT;
        return 200 "hello from origin - 64 bytes of payload for the benchmark!\n";
    }
    server {
        listen 127.0.0.1:$ORIGIN_TLS_PORT ssl;
        http2 on;
        ssl_certificate $CERT;
        ssl_certificate_key $KEY;
        return 200 "hello from origin - 64 bytes of payload for the benchmark!\n";
    }
}
EOF
cat > "$WORK/zoxy.json" <<EOF
{
  "listen": "127.0.0.1:$PROXY_PORT",
  "admin": "127.0.0.1:$ADMIN_PORT",
  "accept_mode": "$ACCEPT_MODE",
  "tls": { "certificate_file": "$CERT", "private_key_file": "$KEY", "http2": true },
  "routes": [{ "cluster": "origin" }],
  "clusters": [{ "name": "origin", "endpoints": ["127.0.0.1:$ORIGIN_PORT"] }]
}
EOF

if [ -n "$PIN_PROXY" ]; then
    echo "== core pinning ($NCPU cpus): nginx=[$ORIGIN_CPUS] zoxy=[$PROXY_CPUS] h2load=[$GEN_CPUS] =="
else
    echo "== core pinning: disabled (<3 cpus or no taskset) =="
fi

echo "== start origin (nginx h1 :$ORIGIN_PORT / h2 :$ORIGIN_TLS_PORT) and proxy (zoxy h2 :$PROXY_PORT, accept_mode=$ACCEPT_MODE) =="
if command -v nginx >/dev/null; then
    $PIN_ORIGIN nginx -c "$WORK/nginx.conf"
else
    $PIN_ORIGIN nix shell nixpkgs#nginx --command nginx -c "$WORK/nginx.conf"
fi
$PIN_PROXY "$ROOT/zig-out/bin/zoxy" "$WORK/zoxy.json" > "$WORK/zoxy.log" 2>&1 &
ZOXY_PID=$!
wait_for "https://127.0.0.1:$ORIGIN_TLS_PORT/"
wait_for "https://127.0.0.1:$PROXY_PORT/"

# Keep the h2 negotiation line, throughput, the request tally (failed/errored
# tripwire), and the latency table.
summarize() {
    grep -E 'Application protocol|finished in|^requests:|^status codes:|min.*max.*median|^request |^connect |^TTFB |^req/s ' || true
}
# generate <mplex> <url>  — no --h1 (we want h2), no -k (unsupported, unneeded).
if command -v h2load >/dev/null; then
    generate() { $PIN_GEN h2load -t"$THREADS" -c"$CONNECTIONS" -D"$DURATION" -m"$1" "$2" 2>/dev/null | summarize; }
else
    generate() { $PIN_GEN nix shell nixpkgs#nghttp2 --command \
        h2load -t"$THREADS" -c"$CONNECTIONS" -D"$DURATION" -m"$1" "$2" 2>/dev/null | summarize; }
fi

proc_cpu_ticks() {
    local stat
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || { echo 0; return; }
    stat=${stat#*) }
    # shellcheck disable=SC2086
    set -- $stat
    echo $(( ${12} + ${13} ))
}

for m in $MPLEX; do
    echo
    echo "############ multiplexing -m$m  (${DURATION} x ${CONNECTIONS} conns x ${THREADS} threads) ############"
    echo "== direct: generator -> nginx h2, -m$m =="
    generate "$m" "https://127.0.0.1:$ORIGIN_TLS_PORT/"
    echo
    echo "== proxied: generator -> zoxy h2 -> nginx h1, -m$m =="
    cpu_before=$(proc_cpu_ticks "$ZOXY_PID")
    generate "$m" "https://127.0.0.1:$PROXY_PORT/"
    cpu_after=$(proc_cpu_ticks "$ZOXY_PID")
    if [ "$PROXY_COUNT" -gt 0 ] && [ -n "$DURATION_S" ] && [ "$DURATION_S" -gt 0 ]; then
        clk=$(getconf CLK_TCK)
        zoxy_pct=$(( (cpu_after - cpu_before) * 100 / (clk * DURATION_S) ))
        echo "   zoxy CPU during run: ${zoxy_pct}% of $((PROXY_COUNT * 100))% available (${PROXY_COUNT} cores)"
    fi
done

echo
echo "== reading the result =="
echo "   -m1 is a latency test (one stream/conn): compare the 'request' rows,"
echo "   direct vs proxied, for the h2 hop cost (TLS term + HPACK + framing +"
echo "   h2->h1 translation). Higher -m multiplexes streams per connection, so"
echo "   req/s is multiplexed throughput. zoxy advertises MAX_CONCURRENT_STREAMS"
echo "   =64, so -m100 is capped at 64 streams/conn in flight."
echo
echo "   5xx/'failed' at high -m is BOUNDED LOAD-SHEDDING, not a crash: each"
echo "   worker reserves h2_legs_max=128 upstream legs; a stream that finds none"
echo "   free gets 503 (served requests stay 200). Watch two things: (1) 'zoxy"
echo "   CPU' well under its ceiling while shedding = idle workers, i.e. each h2"
echo "   connection is pinned to ONE worker and few connections hash unevenly"
echo "   (worker_accepted below shows the spread); (2) raising -c adds streams,"
echo "   not balance, so it sheds harder. This is H2's few-conns model meeting"
echo "   the reserved per-worker pools — a sizing knob (constants.zig), not a bug."
echo "   FIX for the imbalance: -a shared (measured: -m32 -c8 sheds 78k under"
echo "   reuseport at spread 8/6/3, 0 under shared at 9/8/8). Or raise h2_legs_max."

echo
echo "== zoxy counters (worker_accepted spread shows reuseport imbalance) =="
curl -s "http://127.0.0.1:$ADMIN_PORT/metrics" | grep -E '^zoxy_(requests|client_errors|upstream_errors|upstream_reused|tls_handshakes|tls_h2_handoffs|rejected)|^zoxy_worker_accepted'
