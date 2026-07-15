# Dev environment (https://devenv.sh): the pinned toolchain — zig 0.16 +
# zls, kcov (Linux, coverage), nginx (the Tier-1 bench origin, §9),
# haproxy (the Tier-1 state-of-the-art reference proxy, §9), poop
# (Tier-0 hardware-counter A/B) and perf + flamegraph for the pinned
# `zig build profile` (all Linux only). Activated automatically by
# `.envrc` via direnv, or manually with `devenv shell`.
{ pkgs, lib, ... }:
let
  # `zig build profile` (Tier-0, §9) needs perf + flamegraph, so developers get
  # them — but that pair drags in pkgs.linuxPackages_latest.perf, whose closure
  # is often uncached, and building it falls back to the stdenv source-bootstrap
  # which fails intermittently (the `ldexpl.c is not valid` coverage flake). CI
  # never runs `zig build profile`, so skip them there and keep its closure
  # cache-only. GitHub Actions sets CI=true; a CI checkout is always fresh, so
  # this re-evaluates every run and never serves a stale (perf-included) shell.
  in_ci = (builtins.getEnv "CI") == "true";
in
{
  packages =
    [
      pkgs.zig_0_16
      pkgs.zls
      pkgs.nginx
      pkgs.haproxy
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (
      [
        pkgs.kcov
        pkgs.poop
      ]
      ++ lib.optionals (!in_ci) [
        pkgs.linuxPackages_latest.perf
        pkgs.flamegraph
      ]
    );
}
