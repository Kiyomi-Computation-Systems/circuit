#!/bin/sh
# tests/fetch-akku-lock.sh: what scripts/fetch-akku-lock promises, checked
# offline. It builds an archive and a lock of its own (a file:// URL) in a
# scratch directory, so it needs curl or wget, tar, xz and diff, but no
# network.
# `make check-site-deps` runs it.
set -u
cd "$(dirname "$0")/.."
script=$PWD/scripts/fetch-akku-lock

scratch=$(mktemp -d "${TMPDIR:-/tmp}/fetch-akku-lock.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

mkdir -p "$scratch/src/pkg/src" "$scratch/srv"
echo '(library (pkg) (export) (import (rnrs)))' > "$scratch/src/pkg/src/pkg.sls"
tar -cf - -C "$scratch/src/pkg" . | xz -c > "$scratch/srv/pkg.tar.xz"
good=$(sha256 "$scratch/srv/pkg.tar.xz")
# A sha256 that differs from good's in its first digit only.
case $good in
  0*) bad=1${good#?} ;;
  *) bad=0${good#?} ;;
esac

# A lock in `akku lock`'s own layout, plus a second project written the
# older way, with every string after its key on one line.
write_lock() {
  cat > "$scratch/Akku.lock" <<EOF
#!r6rs ; -*- mode: scheme; coding: utf-8 -*-
(import (akku format lockfile))
(projects
  ((name "other")
   (location (url "file://$scratch/srv/missing.tar.xz"))
   (content (sha256 "$good")))
  ((name "pkg")
   (location
     (url "file://$scratch/srv/pkg.tar.xz"))
   (content
     (sha256
       "$1"))))
EOF
}

run() {
  AKKU_LOCK=$scratch/Akku.lock AKKU_DEST=$scratch/dest "$script" "$@" \
    > "$scratch/out" 2>&1
}

# 1. The pinned archive is fetched, checked and unpacked.
write_lock "$good"
if run pkg && [ -f "$scratch/dest/pkg/src/pkg.sls" ] \
   && [ "$(cat "$scratch/dest/pkg.sha256")" = "$good" ]; then
  pass "the pinned archive is unpacked and its sha256 recorded"
else
  fail "the pinned archive is unpacked and its sha256 recorded"; cat "$scratch/out" >&2
fi

# 2. A second run needs no network: the server's archive is gone.
mv "$scratch/srv/pkg.tar.xz" "$scratch/srv/pkg.tar.xz.away"
rm -f "$scratch/dest/dl/pkg.tar.xz"
if run pkg && grep -q 'pkg is up to date' "$scratch/out"; then
  pass "an unpacked tree that records the lock's sha256 is left alone, offline"
else
  fail "an unpacked tree that records the lock's sha256 is left alone, offline"; cat "$scratch/out" >&2
fi
mv "$scratch/srv/pkg.tar.xz.away" "$scratch/srv/pkg.tar.xz"

# 3. An archive whose sha256 is not the lock's is refused, deleted, and
#    nothing is unpacked; the tree from before is not trusted either.
write_lock "$bad"
if ! run pkg && grep -q "pins $bad" "$scratch/out" \
   && [ ! -f "$scratch/dest/dl/pkg.tar.xz" ] \
   && [ "$(cat "$scratch/dest/pkg.sha256")" = "$good" ]; then
  pass "an archive whose sha256 differs from the lock is refused, and nothing is unpacked"
else
  fail "an archive whose sha256 differs from the lock is refused, and nothing is unpacked"; cat "$scratch/out" >&2
fi

# 4. A package the lock does not name fails by name.
write_lock "$good"
if ! run absent && grep -q 'absent is not in' "$scratch/out"; then
  pass "a package missing from the lock fails by name"
else
  fail "a package missing from the lock fails by name"; cat "$scratch/out" >&2
fi

# 5. A download that fails says so, and suggests where to run it.
if ! run other && grep -q 'could not download' "$scratch/out" \
   && [ ! -d "$scratch/dest/other" ]; then
  pass "a failed download fails by name and unpacks nothing"
else
  fail "a failed download fails by name and unpacks nothing"; cat "$scratch/out" >&2
fi

# 6. A lock re-pinned to a new archive replaces the old tree whole: a file
#    only the old archive had is gone.
write_lock "$good"
run pkg
mkdir -p "$scratch/src/pkg2/src"
echo '(library (pkg two) (export) (import (rnrs)))' > "$scratch/src/pkg2/src/two.sls"
tar -cf - -C "$scratch/src/pkg2" . | xz -c > "$scratch/srv/pkg.tar.xz"
write_lock "$(sha256 "$scratch/srv/pkg.tar.xz")"
if run pkg && [ -f "$scratch/dest/pkg/src/two.sls" ] \
   && [ ! -e "$scratch/dest/pkg/src/pkg.sls" ]; then
  pass "a re-pinned archive replaces the old tree whole"
else
  fail "a re-pinned archive replaces the old tree whole"; cat "$scratch/out" >&2
  find "$scratch/dest/pkg" >&2
fi

# 7. An archive tar cannot read is refused: the run fails, and the tree
#    from before stays, still recording its own sha256. The lock pins the
#    unreadable bytes, so the sha256 check passes and tar is what refuses.
printf 'not an archive\n' > "$scratch/srv/pkg.tar.xz"
before=$(cat "$scratch/dest/pkg.sha256")
write_lock "$(sha256 "$scratch/srv/pkg.tar.xz")"
if ! run pkg && grep -q 'could not unpack' "$scratch/out" \
   && [ -f "$scratch/dest/pkg/src/two.sls" ] \
   && [ "$(cat "$scratch/dest/pkg.sha256")" = "$before" ]; then
  pass "an archive tar cannot read is refused, and the tree from before stays"
else
  fail "an archive tar cannot read is refused, and the tree from before stays"; cat "$scratch/out" >&2
fi

# 8. Without xz, the run does what this host's tar can do. GNU tar needs
#    xz to read the archive, so the run fails, and the tree from before
#    stays, still recording its own sha256. bsdtar built with liblzma
#    (macOS's) reads xz itself, so the run unpacks the archive whole. The
#    PATH holds every tool the script uses except xz, and holds it only
#    inside a subshell: bash 3.2, macOS's /bin/sh, keeps an assignment made
#    before a function call once the call returns.
mkdir -p "$scratch/srv3/src" "$scratch/noxz"
echo three > "$scratch/srv3/src/three.sls"
tar -cf - -C "$scratch/srv3" . | xz -c > "$scratch/srv/pkg.tar.xz"
new=$(sha256 "$scratch/srv/pkg.tar.xz")
before=$(cat "$scratch/dest/pkg.sha256")
write_lock "$new"
for t in sh awk cut cat mkdir rm mv ls tar curl wget sha256sum shasum; do
  p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$scratch/noxz/$t"
done
path=$PATH
if PATH=$scratch/noxz "$scratch/noxz/tar" -tf "$scratch/srv/pkg.tar.xz" \
     > /dev/null 2>&1; then
  if (PATH=$scratch/noxz; run pkg) \
     && [ -f "$scratch/dest/pkg/src/three.sls" ] \
     && [ ! -e "$scratch/dest/pkg/src/two.sls" ] \
     && [ "$(cat "$scratch/dest/pkg.sha256")" = "$new" ]; then
    pass "without xz, a tar that reads xz itself unpacks the archive whole"
  else
    fail "without xz, a tar that reads xz itself unpacks the archive whole"; cat "$scratch/out" >&2
  fi
elif ! (PATH=$scratch/noxz; run pkg) && grep -q 'could not unpack' "$scratch/out" \
   && [ -f "$scratch/dest/pkg/src/two.sls" ] \
   && [ "$(cat "$scratch/dest/pkg.sha256")" = "$before" ]; then
  pass "without xz the run fails, and the tree from before stays"
else
  fail "without xz the run fails, and the tree from before stays"; cat "$scratch/out" >&2
fi
[ "$PATH" = "$path" ] || fail "the PATH without xz ends with its row, but is still $PATH"

# 9. An archive that unpacks to nothing is refused, and nothing is recorded.
mkdir -p "$scratch/empty"
tar -cf - -C "$scratch/empty" --files-from /dev/null | xz -c > "$scratch/srv/pkg.tar.xz"
before=$(cat "$scratch/dest/pkg.sha256")
write_lock "$(sha256 "$scratch/srv/pkg.tar.xz")"
if ! run pkg && grep -q 'unpacked to nothing' "$scratch/out" \
   && [ "$(cat "$scratch/dest/pkg.sha256")" = "$before" ]; then
  pass "an archive that unpacks to nothing is refused"
else
  fail "an archive that unpacks to nothing is refused"; cat "$scratch/out" >&2
fi

# 10. A tree that records the lock's sha256 is held to its archive under
#     dl/, with no network: the server's archive is gone. A whole tree is
#     left alone; one with a file deleted, changed or added is unpacked
#     again, whole, from that archive.
mkdir -p "$scratch/srv4/src"
echo '(library (pkg four) (export) (import (rnrs)))' > "$scratch/srv4/src/four.sls"
echo 'four' > "$scratch/srv4/src/notes.txt"
tar -cf - -C "$scratch/srv4" . | xz -c > "$scratch/srv/pkg.tar.xz"
write_lock "$(sha256 "$scratch/srv/pkg.tar.xz")"
run pkg
mv "$scratch/srv/pkg.tar.xz" "$scratch/srv/pkg.tar.xz.away"
whole() {
  [ "$(cat "$scratch/dest/pkg/src/four.sls")" = '(library (pkg four) (export) (import (rnrs)))' ] \
    && [ "$(cat "$scratch/dest/pkg/src/notes.txt")" = four ] \
    && [ "$(ls "$scratch/dest/pkg/src" | tr '\n' ' ')" = 'four.sls notes.txt ' ] \
    && [ ! -e "$scratch/dest/pkg.check" ]
}
if run pkg && grep -q 'pkg is up to date' "$scratch/out" && whole; then
  pass "a tree its archive under dl/ holds is left alone, offline"
else
  fail "a tree its archive under dl/ holds is left alone, offline"; cat "$scratch/out" >&2
fi
rm "$scratch/dest/pkg/src/four.sls"
if run pkg && grep -q 'differs from its archive' "$scratch/out" && whole; then
  pass "a file deleted from the tree is put back from its archive, offline"
else
  fail "a file deleted from the tree is put back from its archive, offline"; cat "$scratch/out" >&2
fi
echo 'edited' > "$scratch/dest/pkg/src/notes.txt"
if run pkg && grep -q 'differs from its archive' "$scratch/out" && whole; then
  pass "a file changed in the tree is put back from its archive, offline"
else
  fail "a file changed in the tree is put back from its archive, offline"; cat "$scratch/out" >&2
fi
echo 'stray' > "$scratch/dest/pkg/src/stray.sls"
if run pkg && grep -q 'differs from its archive' "$scratch/out" && whole; then
  pass "a file added to the tree is removed, the tree unpacked again from its archive, offline"
else
  fail "a file added to the tree is removed, the tree unpacked again from its archive, offline"; cat "$scratch/out" >&2
fi
mv "$scratch/srv/pkg.tar.xz.away" "$scratch/srv/pkg.tar.xz"

if [ "$fails" -eq 0 ]; then
  echo "fetch-akku-lock: all checks passed"
else
  echo "fetch-akku-lock: $fails check(s) failed" >&2
  exit 1
fi
