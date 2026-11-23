#!/bin/sh
# tests/check-pins.sh: what `make check-pins` and `make deps` promise of
# the fetched trees, of chez-libuv's copy and of the server's submodule,
# checked on small fake trees, a fake lock of their own (file:// URLs), a
# fake server submodule in a fake repository, and the Makefile itself, its
# directories, lock and pin given on make's command line. A tree for each
# name AKKU_TREES gives, as the Makefile reads it, holds the file
# AKKU_TREES names; chez-libuv's has a Makefile whose build makes the two
# products the real one makes. So it needs curl, tar, xz, sha256sum or
# shasum, diff, make and git, but no network, no Chez and no compiler.
# `make check-site-deps` runs it, on the host: the container has no git.
set -u
cd "$(dirname "$0")/.."

scratch=$(mktemp -d "${TMPDIR:-/tmp}/check-pins-test.XXXXXX")
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

command -v git >/dev/null 2>&1 \
  || { echo "check-pins: needs git, for its fake server submodule: run it on the host" >&2; exit 1; }

src=$scratch/src srv=$scratch/srv trees=$scratch/trees akku=$scratch/akku
copy=$scratch/build/chez-libuv lock=$scratch/Akku.lock
mkdir -p "$src" "$srv" "$scratch/bin"

# The server's submodule: a repository of two releases, v1.0.0 at c1 and
# v1.1.0 at c2, each naming itself in its Akku.manifest, with a library,
# an ignored build/ and a nested submodule, inner, as the real server has
# its own. It is added to a fake repository, super, as
# vendor/chez-http-server at c1, its pin. No configuration of the user's or
# the system's reaches git here: no identity, signing or hooks.
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
g() { git -c user.name=check-pins -c user.email=check-pins@example.invalid \
        -c init.defaultBranch=main -c protocol.file.allow=always "$@"; }
manifest() { printf '(import (akku format manifest))\n(akku-package ("chez-http-server" "%s"))\n' "$1"; }
up=$scratch/up super=$scratch/super inner=$scratch/inner
mkdir -p "$up/src" "$super" "$inner"
g -C "$inner" init -q
echo i1 > "$inner/README" && g -C "$inner" add -A && g -C "$inner" commit -qm i1
i2=$(echo i2 > "$inner/README" && g -C "$inner" commit -qam i2 && git -C "$inner" rev-parse HEAD)
g -C "$inner" checkout -q HEAD~1
g -C "$up" init -q
printf 'build/\n' > "$up/.gitignore"
echo '(library (http-server) (export) (import (rnrs)))' > "$up/src/http-server.sls"
manifest 1.0.0 > "$up/Akku.manifest"
g -C "$up" submodule add -q "$inner" inner 2>/dev/null
g -C "$up" add -A && g -C "$up" commit -qm c1 && g -C "$up" tag v1.0.0
c1=$(git -C "$up" rev-parse HEAD)
manifest 1.1.0 > "$up/Akku.manifest"
echo '; c2' >> "$up/src/http-server.sls"
g -C "$up" commit -qam c2 && g -C "$up" tag v1.1.0
c2=$(git -C "$up" rev-parse HEAD)
g -C "$super" init -q
g -C "$super" submodule add -q "$up" vendor/chez-http-server 2>/dev/null
sdir=$super/vendor/chez-http-server
g -C "$sdir" checkout -q --detach "$c1" 2>/dev/null
g -C "$super" add vendor/chez-http-server

# A pkg-config for deps' require-tools: deps runs no real build here.
printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/pkg-config"
chmod +x "$scratch/bin/pkg-config"

# mk ARG...: this checkout's make, with the row's directories and lock, no
# Chez and no compiler, and none of an outer make's flags. The ARGs come
# last, so one that sets a variable wins: make takes a command line's last.
# Its output is in $scratch/out, its status returned.
mk() {
  env -u MAKEFLAGS -u MAKELEVEL -u MFLAGS PATH="$scratch/bin:$PATH" \
    make --no-print-directory CHEZ=true CC=true \
    AKKU_DIR="$akku" AKKU_TREES_DIR="$trees" AKKU_LOCK_FILE="$lock" \
    LIBUV_DIR="$copy" BUILD_DIR="$scratch/build" SERVER_DIR="$sdir" SERVER_PIN="$c1" SERVER_VERSION=1.0.0 \
    FETCH_SERVER=true \
    "$@" > "$scratch/out" 2>&1
}

# holds TEXT...: each is in the output.
holds() {
  for want in "$@"; do grep -qF -- "$want" "$scratch/out" || return 1; done
}

# The Makefile's AKKU_TREES, as it reads them.
printf 'print-trees: ; @echo $(AKKU_TREES)\n' > "$scratch/print.mk"
all=$(env -u MAKEFLAGS -u MAKELEVEL -u MFLAGS make --no-print-directory -s -f Makefile -f "$scratch/print.mk" print-trees CHEZ=true)
names=
for t in $all; do names="$names ${t%%:*}"; done

# A tree for each: its README, and the file AKKU_TREES names under it, a
# directory holding one library when it names no file.
for t in $all; do
  name=${t%%:*} f=${t#*:}
  mkdir -p "$src/$name"
  echo "$name" > "$src/$name/README"
  case $f in
    Makefile | *.sls) mkdir -p "$(dirname "$src/$name/$f")"; echo "$name" > "$src/$name/$f" ;;
    *) mkdir -p "$src/$name/$f"; echo "(library ($name) (export) (import (rnrs)))" > "$src/$name/$f/$name.sls" ;;
  esac
done
mkdir -p "$src/chez-libuv/src/libuv/private"
echo '(library (libuv) (export) (import (rnrs)))' > "$src/chez-libuv/src/libuv.sls"
echo '(library (libuv private ffi) (export) (import (rnrs)))' > "$src/chez-libuv/src/libuv/private/ffi.sls"
cat > "$src/chez-libuv/Makefile" <<'EOF'
.PHONY: build
build:
	@mkdir -p build/lib src/libuv/private
	@echo shim > build/lib/libchezlibuv.so
	@echo '(library (libuv private config) (export) (import (rnrs)))' > src/libuv/private/config.sls
EOF
mkdir -p "$src/hashing"
echo '(library (hashing sha-2) (export) (import (rnrs)))' > "$src/hashing/sha-2.scm"

# Each tree's archive, and a lock in Akku 1.2.0's layout pinning each one,
# hashing, chez-cmark-gfm, which nothing here fetches, and the server, which
# its submodule stands in for.
entry() { # NAME URL SHA
  printf '  ((name "%s")\n    (location\n      (url "%s"))\n    (content\n      (sha256\n        "%s")))\n' "$1" "$2" "$3"
}
{ echo '#!r6rs ; -*- mode: scheme; coding: utf-8 -*-'
  echo '(import (akku format lockfile))'
  echo '(projects'
  for name in hashing $names; do
    tar -cf - -C "$src/$name" . | xz -c > "$srv/$name.tar.xz"
    entry "$name" "file://$srv/$name.tar.xz" "$(sha256 "$srv/$name.tar.xz")"
  done
  entry chez-cmark-gfm "file://$srv/chez-cmark-gfm.tar.xz" 00
  entry chez-http-server "file://$srv/chez-http-server.tar.xz" 22
  echo ')'; } > "$lock"

# A lock like it, with one more project, NAME, nothing fetches.
more() { sed '$d' "$lock" > "$scratch/$1.lock"; { entry "$1" "file://$srv/$1.tar.xz" 11; echo ')'; } >> "$scratch/$1.lock"; }

if ! mk fetch; then
  echo "check-pins: make fetch of the fake trees failed:" >&2; cat "$scratch/out" >&2; exit 1
fi

# 1. Each tree as the lock pins it, and no copy yet: check-pins passes.
if mk check-pins && holds "fetch-akku-lock: chez-uri is its archive as $lock pins it ($trees/chez-uri)" \
     "check-lock-projects: $lock pins exactly the projects named, each once" \
     "check-libuv-copy: $copy isn't made yet" \
     "check-server-pin: $sdir is v1.0.0, $c1, its gitlink's commit, with no change"; then
  pass "check-pins passes each tree as the lock pins it, with no copy of chez-libuv"
else
  fail "check-pins passes each tree as the lock pins it, with no copy of chez-libuv"; cat "$scratch/out" >&2
fi

# 2. deps copies chez-libuv and builds the copy, and check-pins passes it,
#    the build's two products and all.
if mk -o check-chez deps && holds "deps: $trees/chez-libuv copied to $copy" \
   && [ -f "$copy/build/lib/libchezlibuv.so" ] && [ -f "$copy/src/libuv/private/config.sls" ] \
   && mk check-pins && holds "check-libuv-copy: $copy is $trees/chez-libuv, and its build's products"; then
  pass "deps copies chez-libuv and builds the copy, and check-pins passes it"
else
  fail "deps copies chez-libuv and builds the copy, and check-pins passes it"; cat "$scratch/out" >&2
fi

# 3. deps keeps a copy that is the tree and its build's products: what its
#    build wrote stays.
echo kept > "$copy/build/kept"
if mk -o check-chez deps && ! holds "copied" && [ -f "$copy/build/kept" ]; then
  pass "deps keeps a copy that is the tree and its build's products"
else
  fail "deps keeps a copy that is the tree and its build's products"; cat "$scratch/out" >&2
fi

# copied-again ROW: deps copies the copy again, whole, and check-pins
# passes after it.
copied_again() {
  if mk -o check-chez deps && holds "deps: $trees/chez-libuv copied to $copy" \
     && cmp -s "$trees/chez-libuv/src/libuv.sls" "$copy/src/libuv.sls" && [ ! -e "$copy/build/kept" ] \
     && [ -f "$copy/src/libuv/private/config.sls" ] && mk check-pins; then
    pass "$1"
  else
    fail "$1"; cat "$scratch/out" >&2
  fi
}

# refused ROW TEXT...: check-pins fails, naming each TEXT.
refused() {
  row=$1; shift
  if ! mk check-pins && holds "$@"; then
    pass "$row"
  else
    fail "$row"; cat "$scratch/out" >&2
  fi
}

# 4. A file of the copy's edited: check-pins fails, naming it; deps copies
#    it again.
echo '; edited' >> "$copy/src/libuv.sls"
refused "check-pins fails on an edited copy, naming the file" \
  "check-libuv-copy: $copy differs from $trees/chez-libuv beyond its build's products:" \
  "  Files $trees/chez-libuv/src/libuv.sls and $copy/src/libuv.sls differ"
echo kept > "$copy/build/kept"
copied_again "deps copies an edited copy again"

# 5. A file added to the copy: check-pins fails, naming it; deps copies it
#    again, without it.
echo '(library (extra) (export) (import (rnrs)))' > "$copy/src/extra.sls"
refused "check-pins fails on a file added to the copy, naming it" \
  "  Only in $copy/src: extra.sls"
copied_again "deps copies a copy with a file added again"
[ ! -e "$copy/src/extra.sls" ] || fail "the file added to the copy is still there after deps"

# 6. The products' names, anywhere but where the build writes them, are
#    files added like any other.
mkdir -p "$copy/src/build" && echo x > "$copy/src/build/x"
refused "check-pins fails on a build directory in the copy but the build's own" \
  "  Only in $copy/src: build"
rm -rf "$copy/src/build"
echo x > "$copy/src/config.sls"
refused "check-pins fails on a config.sls in the copy but the build's own" \
  "  Only in $copy/src: config.sls"
rm -f "$copy/src/config.sls"
mkdir -p "$copy/src/libuv/private/build" && echo x > "$copy/src/libuv/private/build/x"
refused "check-pins fails on a build directory beside the build's config.sls" \
  "  Only in $copy/src/libuv/private: build"
rm -rf "$copy/src/libuv/private/build"

# 7. A tree with a file edited: check-pins fails, naming it.
echo '; edited' >> "$trees/chez-uri/src/chez-uri.sls"
refused "check-pins fails on an edited tree, naming the file" \
  "fetch-akku-lock: $trees/chez-uri differs from its archive:" "chez-uri.sls"
mk fetch

# 8. A tree that isn't there: check-pins fails, naming it.
mv "$trees/chez-websocket" "$scratch/away"
refused "check-pins fails on a tree that isn't there, naming it" \
  "fetch-akku-lock: $trees/chez-websocket not found, so chez-websocket isn't fetched"
mv "$scratch/away" "$trees/chez-websocket"

# 9. A lock with a project nothing fetches: check-pins and deps fail,
#    naming it, and deps copies nothing.
more chez-new
if ! mk check-pins AKKU_LOCK_FILE="$scratch/chez-new.lock" \
   && holds "check-lock-projects: $scratch/chez-new.lock pins chez-new, which nothing fetches"; then
  pass "check-pins fails on a lock with a project nothing fetches, naming it"
else
  fail "check-pins fails on a lock with a project nothing fetches, naming it"; cat "$scratch/out" >&2
fi
echo '; edited' >> "$copy/src/libuv.sls"
if ! mk -o check-chez deps AKKU_LOCK_FILE="$scratch/chez-new.lock" \
   && holds "check-lock-projects: $scratch/chez-new.lock pins chez-new, which nothing fetches" \
   && ! holds "copied"; then
  pass "deps fails on a lock with a project nothing fetches, naming it, before it copies"
else
  fail "deps fails on a lock with a project nothing fetches, naming it, before it copies"; cat "$scratch/out" >&2
fi
mk -o check-chez deps

# 10. A name in AKKU_TREES the lock doesn't pin: check-pins and deps fail,
#     naming it.
mkdir -p "$trees/chez-extra/src"
if ! mk check-pins AKKU_TREES="$all chez-extra:src" \
   && holds "check-lock-projects: chez-extra is to be fetched, but $lock doesn't pin it"; then
  pass "check-pins fails on a name in AKKU_TREES the lock doesn't pin, naming it"
else
  fail "check-pins fails on a name in AKKU_TREES the lock doesn't pin, naming it"; cat "$scratch/out" >&2
fi
if ! mk -o check-chez deps AKKU_TREES="$all chez-extra:src" \
   && holds "check-lock-projects: chez-extra is to be fetched, but $lock doesn't pin it"; then
  pass "deps fails on a name in AKKU_TREES the lock doesn't pin, naming it"
else
  fail "deps fails on a name in AKKU_TREES the lock doesn't pin, naming it"; cat "$scratch/out" >&2
fi
rm -rf "$trees/chez-extra"

# 11. A lock that pins a project twice, and an AKKU_TREES that names one
#     twice: check-pins fails, naming each.
sed '$d' "$lock" > "$scratch/twice.lock"
{ entry chez-uri "file://$srv/chez-uri.tar.xz" "$(sha256 "$srv/chez-uri.tar.xz")"; echo ')'; } >> "$scratch/twice.lock"
refused_with() { # ROW VAR=VALUE TEXT...
  row=$1 var=$2; shift 2
  if ! mk check-pins "$var" && holds "$@"; then pass "$row"; else fail "$row"; cat "$scratch/out" >&2; fi
}
refused_with "check-pins fails on a lock that pins a project twice, naming it" \
  AKKU_LOCK_FILE="$scratch/twice.lock" "check-lock-projects: $scratch/twice.lock pins chez-uri more than once"
refused_with "check-pins fails on an AKKU_TREES that names a tree twice, naming it" \
  AKKU_TREES="$all chez-uri:src" "check-lock-projects: chez-uri is named more than once"

# 12. Before any target runs, make fails on a LIBDIR_LIST entry under the
#     trees that AKKU_TREES doesn't name, and on an AKKU_TREES without a
#     tree the Makefile's directories name.
if ! mk -n libdirs LIBDIR_LIST="src $trees/chez-uri/src $trees/nope/src" \
   && holds "LIBDIR_LIST holds $trees/nope/src, which no tree AKKU_TREES names gives" \
   && ! holds "$trees/chez-uri/src,"; then
  pass "make fails, before any target runs, on a LIBDIR_LIST entry no tree in AKKU_TREES gives"
else
  fail "make fails, before any target runs, on a LIBDIR_LIST entry no tree in AKKU_TREES gives"; cat "$scratch/out" >&2
fi
without=
for t in $all; do [ "${t%%:*}" = chez-uri ] || without="$without $t"; done
if ! mk -n libdirs AKKU_TREES="$without" && holds "AKKU_TREES names no chez-uri"; then
  pass "make fails, before any target runs, on an AKKU_TREES without a tree the Makefile's directories name"
else
  fail "make fails, before any target runs, on an AKKU_TREES without a tree the Makefile's directories name"; cat "$scratch/out" >&2
fi

# --- the server's submodule ------------------------------------------------------

# server_refused ROW TEXT...: check-pins fails, naming each TEXT and the
# Makefile's hint, while the trees and the copy pass, so only the server's
# check can be what failed.
server_refused() {
  row=$1; shift
  if ! mk check-pins && holds "$@" "PIN MISMATCH: $sdir isn't v1.0.0, $c1, with no change" \
     "check-lock-projects: $lock pins exactly the projects named, each once" \
     "check-libuv-copy: $copy is $trees/chez-libuv, and its build's products"; then
    pass "$row"
  else
    fail "$row"; cat "$scratch/out" >&2
  fi
}

# deps_refused ROW TEXT [VAR=VALUE...]: with the copy edited first, deps
# fails, naming TEXT and its hint, and copies nothing: the edit stays.
deps_refused() {
  row=$1 text=$2; shift 2
  echo '; edited' >> "$copy/src/libuv.sls"
  if ! mk -o check-chez deps "$@" && holds "$text" "deps: so the server's submodule isn't SERVER_VERSION, 1.0.0." \
     && ! holds "copied" && tail -n 1 "$copy/src/libuv.sls" | grep -qxF '; edited'; then
    pass "$row"
  else
    fail "$row"; cat "$scratch/out" >&2
  fi
}

# recopied ROW: with the server back as it was, deps copies the edited
# copy again, and check-pins passes.
recopied() {
  if mk -o check-chez deps && holds "deps: $trees/chez-libuv copied to $copy" && mk check-pins; then
    pass "$1"
  else
    fail "$1"; cat "$scratch/out" >&2
  fi
}

# 13. The submodule checked out at the next release: check-pins names its
#     HEAD; deps, which reads its Akku.manifest without git, names the
#     version, and copies nothing.
g -C "$sdir" checkout -q --detach "$c2" 2>/dev/null
server_refused "check-pins fails on the server's submodule at another commit than its pin, naming both" \
  "check-server-pin: $sdir is at $c2, not $c1"
deps_refused "deps fails on the server's submodule at another release, naming its version, before it copies" \
  "check-server-pin: $sdir's Akku.manifest names (akku-package (\"chez-http-server\" \"1.1.0\"), not chez-http-server 1.0.0."
g -C "$sdir" checkout -q --detach "$c1" 2>/dev/null
recopied "deps copies the copy again once the server's submodule is back at its pin"

# 14. The gitlink at another commit than the pin, the checkout at the pin:
#     check-pins names the gitlink's commit.
g -C "$super" update-index --cacheinfo "160000,$c2,vendor/chez-http-server"
server_refused "check-pins fails on a gitlink at another commit than the pin, naming it" \
  "check-server-pin: the gitlink records $sdir at $c2, not $c1"
g -C "$super" update-index --cacheinfo "160000,$c1,vendor/chez-http-server"

# 15. A pin that isn't its version's tag: SERVER_VERSION 1.1.0 at c1, whose
#     tag v1.1.0 is c2, and 9.9.9, which has no tag. check-pins names each.
if ! mk check-pins SERVER_VERSION=1.1.0 && holds "check-server-pin: $sdir's tag v1.1.0 is $c2, not $c1"; then
  pass "check-pins fails on a pin that isn't its version's tag, naming the tag's commit"
else
  fail "check-pins fails on a pin that isn't its version's tag, naming the tag's commit"; cat "$scratch/out" >&2
fi
if ! mk check-pins SERVER_VERSION=9.9.9 && holds "check-server-pin: $sdir's tag v9.9.9 is <absent>, not $c1"; then
  pass "check-pins fails on a version with no tag, naming it"
else
  fail "check-pins fails on a version with no tag, naming it"; cat "$scratch/out" >&2
fi

# 16. A file in the submodule edited, deleted or added, an ignored one, and
#     a nested submodule at another commit than its gitlink, as a checkout
#     from v0.3.0 or earlier keeps the server's own: check-pins names each,
#     as git status's porcelain gives it. Deinit undoes the last.
echo '; edited' >> "$sdir/src/http-server.sls"
server_refused "check-pins fails on a file edited in the server's submodule, naming it" \
  "check-server-pin: $sdir holds changes:" "   M src/http-server.sls"
g -C "$sdir" checkout -q -- src/http-server.sls
rm "$sdir/src/http-server.sls"
server_refused "check-pins fails on a file deleted from the server's submodule, naming it" "   D src/http-server.sls"
g -C "$sdir" checkout -q -- src/http-server.sls
echo '(library (extra) (export) (import (rnrs)))' > "$sdir/src/extra.sls"
server_refused "check-pins fails on a file added to the server's submodule, naming it" "  ?? src/extra.sls"
rm "$sdir/src/extra.sls"
mkdir -p "$sdir/build" && echo x > "$sdir/build/x"
server_refused "check-pins fails on an ignored file in the server's submodule, naming it" "  !! build/x"
rm -rf "$sdir/build"
g -C "$sdir" submodule update -q --init inner 2>/dev/null
linked=$(git -C "$sdir/inner" rev-parse HEAD)
other=$(git -C "$sdir/inner" rev-list --all | grep -vxF "$linked" | head -n 1)
g -C "$sdir/inner" checkout -q --detach "$other" 2>/dev/null
server_refused "check-pins fails on a nested submodule at another commit than its gitlink, naming it" "   M inner"
g -C "$sdir" submodule deinit -q -f --all
if mk check-pins; then
  pass "deinit in the server's submodule clears a nested submodule, and check-pins passes"
else
  fail "deinit in the server's submodule clears a nested submodule, and check-pins passes"; cat "$scratch/out" >&2
fi

# 17. One run names every fault: at another commit, and a file added.
g -C "$sdir" checkout -q --detach "$c2" 2>/dev/null
echo x > "$sdir/src/extra.sls"
server_refused "check-pins names every fault of the server's submodule in one run" \
  "check-server-pin: $sdir is at $c2, not $c1" "  ?? src/extra.sls"
rm "$sdir/src/extra.sls"
g -C "$sdir" checkout -q --detach "$c1" 2>/dev/null

# 18. No submodule cloned there: check-pins and deps each say so.
mkdir -p "$scratch/bare/vendor/chez-http-server"
if ! mk check-pins SERVER_DIR="$scratch/bare/vendor/chez-http-server" \
   && holds "check-server-pin: $scratch/bare/vendor/chez-http-server isn't cloned. Run 'make fetch' on the host."; then
  pass "check-pins fails on a server submodule that isn't cloned, naming it"
else
  fail "check-pins fails on a server submodule that isn't cloned, naming it"; cat "$scratch/out" >&2
fi
deps_refused "deps fails on a server submodule that isn't cloned, before it copies" \
  "check-server-pin: $scratch/bare/vendor/chez-http-server isn't cloned. Run 'make fetch' on the host." \
  SERVER_DIR="$scratch/bare/vendor/chez-http-server"
recopied "deps copies the copy again once the server's submodule is there"

# 19. --version reads an Akku.manifest's package as it is written, whole: a
#     cloned tree whose manifest names another package, or names none, is
#     refused, naming what it found.
mkdir -p "$scratch/other" && echo 'gitdir: x' > "$scratch/other/.git"
printf '(akku-package ("chez-http-server-extra" "1.0.0"))\n' > "$scratch/other/Akku.manifest"
sh scripts/check-server-pin --version "$scratch/other" 1.0.0 > "$scratch/out" 2>&1
if [ "$?" -eq 1 ] && holds "check-server-pin: $scratch/other's Akku.manifest names (akku-package (\"chez-http-server-extra\" \"1.0.0\"), not chez-http-server 1.0.0."; then
  pass "check-server-pin --version refuses a manifest naming another package"
else
  fail "check-server-pin --version refuses a manifest naming another package"; cat "$scratch/out" >&2
fi
rm "$scratch/other/Akku.manifest"
sh scripts/check-server-pin --version "$scratch/other" 1.0.0 > "$scratch/out" 2>&1
if [ "$?" -eq 1 ] && holds "check-server-pin: $scratch/other's Akku.manifest names no package, not chez-http-server 1.0.0."; then
  pass "check-server-pin --version refuses a tree with no manifest"
else
  fail "check-server-pin --version refuses a tree with no manifest"; cat "$scratch/out" >&2
fi

if [ "$fails" -eq 0 ]; then
  echo "check-pins: all checks passed"
else
  echo "check-pins: $fails check(s) failed" >&2
  exit 1
fi
