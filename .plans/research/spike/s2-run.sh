#!/bin/sh
# Spike S2's driver: s2-coroutine-cost.sps on the project's library path,
# from the worktree's root, under a timeout. Run it inside the Guix
# container:
#
#   scripts/guix-env sh .plans/research/spike/s2-run.sh bytes [ROUNDS [LARGE]]
#   scripts/guix-env sh .plans/research/spike/s2-run.sh rps [SECONDS [ROUNDS [GROUP ...]]]
#   scripts/guix-env sh .plans/research/spike/s2-run.sh show
#
# oha is build/oha, the server's pinned release; curl is the container's.
set -eu
s=vendor/chez-http-server
libdirs=$s/src:$s/vendor/chez-libuv/src:$s/vendor/chez-httparse/src:$s/vendor/chez-httparse/vendor/byte-machine/src:$s/vendor/uriparse/src:build/scheme-libs:$s/vendor/chez-libuv/tests
program=.plans/research/spike/s2-coroutine-cost.sps
mode=${1:-}
[ $# -gt 0 ] && shift
case $mode in
  bytes) exec timeout 1800 scheme --libdirs "$libdirs" --program "$program" bytes ./build/oha "$@" ;;
  rps)   exec timeout 7200 scheme --libdirs "$libdirs" --program "$program" rps ./build/oha "$@" ;;
  show)  exec timeout 300 scheme --libdirs "$libdirs" --program "$program" show "$@" ;;
  *) echo "usage: s2-run.sh bytes|rps|show [ARGS...]" >&2; exit 2 ;;
esac
