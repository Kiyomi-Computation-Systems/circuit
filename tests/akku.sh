#!/bin/sh
# tests/akku.sh: what scripts/akku promises, checked on a fake Akku 1.2.0
# tree and a fake Chez, so it needs no Akku and no network. The script
# runs from a copy of it, in a scratch tree of its own, whose
# build/akku-tool/ is the fake's. `make check-site-deps` runs it.
set -u
cd "$(dirname "$0")/.."

scratch=$(mktemp -d "${TMPDIR:-/tmp}/akku-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

root=$scratch/root
mkdir -p "$root/scripts" "$scratch/bin"
cp scripts/akku "$root/scripts/akku"
tool=$root/build/akku-tool/akku/akku-1.2.0.src

# The fake Chez: it writes its arguments and the environment Akku reads, a
# line each, then exits with FAKE_STATUS.
cat > "$scratch/bin/chez" <<'EOF'
#!/bin/sh
{ for a in "$@"; do echo "arg $a"; done
  echo "XDG_DATA_HOME=${XDG_DATA_HOME-<unset>}"
  echo "XDG_CACHE_HOME=${XDG_CACHE_HOME-<unset>}"
  echo "CHEZSCHEMELIBDIRS=${CHEZSCHEMELIBDIRS-<unset>}"
  echo "CHEZSCHEMELIBEXTS=${CHEZSCHEMELIBEXTS-<unset>}"
  echo "AKKU_SETTINGS=${AKKU_SETTINGS-<unset>}"; } > "$FAKE_RAN"
exit "${FAKE_STATUS:-0}"
EOF
chmod +x "$scratch/bin/chez"

# run [VAR=VALUE]...: scripts/akku update, on the fake Chez, with the VARs
# in its environment. Its output is in $scratch/out, its status returned.
run() {
  rm -f "$scratch/ran"
  env CHEZ="$scratch/bin/chez" FAKE_RAN="$scratch/ran" "$@" sh "$root/scripts/akku" update \
    > "$scratch/out" 2>&1
}

# 1. No Akku 1.2.0 under build/akku-tool: exits 2, naming make akku-deps,
#    and runs no Chez.
run; got=$?
if [ "$got" -eq 2 ] \
   && grep -qF "akku: no Akku 1.2.0 at $tool. Run 'make akku-deps' on the host, where the network is." "$scratch/out" \
   && [ ! -e "$scratch/ran" ]; then
  pass "with no Akku 1.2.0 it exits 2, naming make akku-deps, and runs nothing"
else
  fail "with no Akku 1.2.0 it exits 2, naming make akku-deps, and runs nothing (exit $got)"; cat "$scratch/out" >&2
fi

mkdir -p "$tool/lib/akku/bin" "$tool/lib/akku/lib" "$tool/share/akku/keys.d"
: > "$tool/lib/akku/bin/akku.sps"
echo key > "$tool/share/akku/keys.d/akku-archive-1.gpg"

# 2. It runs Akku's program on CHEZ with the arguments it was given, its
#    data and cache under build/akku-tool, the release's keys copied there,
#    and Akku's own libraries alone on Chez's path: CHEZSCHEMELIBEXTS is
#    unset. Chez's status is its own.
want=$(printf '%s\n' "arg --program" "arg $tool/lib/akku/bin/akku.sps" "arg update" \
  "XDG_DATA_HOME=$root/build/akku-tool/data" "XDG_CACHE_HOME=$root/build/akku-tool/cache" \
  "CHEZSCHEMELIBDIRS=$tool/lib/akku/lib" "CHEZSCHEMELIBEXTS=<unset>" "AKKU_SETTINGS=<unset>")
run CHEZSCHEMELIBEXTS=.x.sls FAKE_STATUS=255; got=$?
if [ "$got" -eq 255 ] && [ "$(cat "$scratch/ran" 2>/dev/null)" = "$want" ] \
   && [ "$(cat "$root/build/akku-tool/data/akku/keys.d/akku-archive-1.gpg" 2>/dev/null)" = key ]; then
  pass "it runs Akku 1.2.0 on CHEZ, its data, cache and keys under build/akku-tool, Chez's status its own"
else
  fail "it runs Akku 1.2.0 on CHEZ, its data, cache and keys under build/akku-tool, Chez's status its own (exit $got)"
  cat "$scratch/out" "$scratch/ran" >&2
fi

# 3. AKKU_SETTINGS is unset: under no-network, Akku's update would only
#    warn, and Akku would go on with the index it has.
run AKKU_SETTINGS=no-network; got=$?
if [ "$got" -eq 0 ] && [ "$(cat "$scratch/ran" 2>/dev/null)" = "$want" ]; then
  pass "it unsets AKKU_SETTINGS, so no-network can't leave Akku on an old index"
else
  fail "it unsets AKKU_SETTINGS, so no-network can't leave Akku on an old index (exit $got)"
  cat "$scratch/out" "$scratch/ran" >&2
fi

if [ "$fails" -eq 0 ]; then
  echo "akku: all checks passed"
else
  echo "akku: $fails check(s) failed" >&2
  exit 1
fi
