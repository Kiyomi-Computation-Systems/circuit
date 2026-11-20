#!/bin/sh
# tests/check-pins.sh: what `make check-pins` and `make deps` promise of
# the fetched trees and of chez-libuv's copy, checked on small fake trees,
# a fake lock of their own (file:// URLs) and the Makefile itself, its
# directories and lock given on make's command line. A tree for each name
# AKKU_TREES gives, as the Makefile reads it, holds the file AKKU_TREES
# names; chez-libuv's has a Makefile whose build makes the two products the
# real one makes. So it needs curl, tar, xz, sha256sum or shasum, diff and
# make, but no network, no Chez and no compiler. `make check-site-deps`
# runs it.
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

src=$scratch/src srv=$scratch/srv trees=$scratch/trees akku=$scratch/akku
copy=$scratch/build/chez-libuv lock=$scratch/Akku.lock
mkdir -p "$src" "$srv" "$scratch/bin"

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
    LIBUV_DIR="$copy" BUILD_DIR="$scratch/build" "$@" > "$scratch/out" 2>&1
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
# hashing and chez-cmark-gfm, which nothing here fetches.
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
  echo ')'; } > "$lock"

# A lock like it, with one more project, NAME, nothing fetches.
more() { sed '$d' "$lock" > "$scratch/$1.lock"; { entry "$1" "file://$srv/$1.tar.xz" 11; echo ')'; } >> "$scratch/$1.lock"; }

if ! mk fetch; then
  echo "check-pins: make fetch of the fake trees failed:" >&2; cat "$scratch/out" >&2; exit 1
fi

# 1. Each tree as the lock pins it, and no copy yet: check-pins passes.
if mk check-pins && holds "fetch-akku-lock: chez-uri is its archive as $lock pins it ($trees/chez-uri)" \
     "check-lock-projects: $lock pins exactly the projects named, each once" \
     "check-libuv-copy: $copy isn't made yet"; then
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

if [ "$fails" -eq 0 ]; then
  echo "check-pins: all checks passed"
else
  echo "check-pins: $fails check(s) failed" >&2
  exit 1
fi
