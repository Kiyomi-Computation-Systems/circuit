# circuit
#
# On a Guix host, run targets through the container:
#   scripts/guix-env make <target>
#
# Every dependency comes from the Akku index. Akku.manifest names each one,
# and Akku.lock pins each one's archive and sha256: `make lock` has Akku
# 1.2.0 write it, and `make check-akku-lock` fails unless it is what Akku
# makes of the manifest against today's index. `make fetch` downloads each
# archive the lock pins, checks its sha256 and unpacks it
# (scripts/fetch-akku-lock): hashing, for (circuit session), into
# vendor/akku, and the others into vendor/akku-trees: chez-http-server;
# chez-websocket, for (circuit websocket); what the server brings,
# chez-libuv, chez-httparse, chez-uri and byte-machine, the path's one,
# which jsonparse runs on too; jsonparse, for (circuit json); and
# chez-srfi, for the suites' SRFI-64. On the library path are vendor/akku,
# and each tree's src/ but two: chez-libuv's copy's src/ stands in for its
# tree's, and chez-srfi's SRFIs are linked into build/scheme-libs, which
# is on the path instead. `make check-pins` holds that the lock pins
# exactly what `make fetch` gets, each tree to its archive, an edit
# included, and the copy to its tree and its build's products; `make
# check-imports` holds that no other directory on the path holds a
# byte-machine. Those that download run on the host: the container has no
# network. `make deps` never fetches: it fails unless the lock pins exactly
# what `make fetch` gets and each tree is there, recording the sha256 the
# lock pins; it builds chez-libuv's shim in a copy, build/chez-libuv, so
# that the fetched tree stays its archive, and links SRFI-64.

# The Chez binary. In the container, scripts/guix-env-enter exports the
# profile's real `scheme` binary. Elsewhere, scripts/require-chez --find
# runs `scheme` and `chez`, the name Homebrew installs it under on macOS,
# to ask what each is, under a time limit, and takes the first on PATH that
# is Chez Scheme 10.4.1 or later, threaded, else the first that is Chez at
# all, else the first on PATH, else `scheme`, which check-chez then
# refuses: on a Mac, another Scheme may own `scheme`. A CHEZ given on the
# command line or in the environment stays as given. Asked once, when make
# reads this file, and exported, so that chez-libuv's build, which make runs
# below, and every make under this one use this one.
ifeq ($(strip $(CHEZ)),)
CHEZ := $(shell scripts/require-chez --find scheme chez)
endif
export CHEZ

# The C compiler chez-libuv's shim is built with. In the container,
# scripts/guix-env-enter exports the profile's gcc.
CC ?= cc
export CC

# chez-libuv's make, which deps runs in its copy, gets none of this command
# line's variables: it builds the shim under its own $(BUILD_DIR), which
# `make deps BUILD_DIR=..`, as tests/test-check-imports.sps's rows run it,
# would otherwise point outside the copy. CHEZ and CC reach it through the
# environment, exported above.
MAKEOVERRIDES =

# The make target to name in a missing-tool hint (scripts/require-tools):
# what the user typed, $(MAKECMDGOALS), or, when that is empty, the
# recipe's own target, $@. Recursively expanded (=, not :=), so each
# reference picks up whichever recipe is running it.
GOAL = $(strip $(if $(MAKECMDGOALS),$(MAKECMDGOALS),$@))

# --- the trees ----------------------------------------------------------------
# Every package `make fetch` unpacks into vendor/akku-trees, as NAME:FILE,
# FILE a path under its tree that deps looks for. fetch, deps and
# check-pins each take every one. hashing goes into vendor/akku on its own,
# and chez-cmark-gfm, for the docs site alone, into build/akku (site-deps).
# deps and check-pins fail unless Akku.lock pins exactly those projects,
# each once (CHECK_LOCKED, below).
AKKU_LOCK_FILE := Akku.lock
AKKU_DIR := vendor/akku
AKKU_TREES_DIR := vendor/akku-trees
AKKU_TREES := chez-http-server:src/http-server.sls \
  chez-websocket:src/websocket.sls \
  chez-libuv:Makefile \
  chez-httparse:src \
  byte-machine:src \
  chez-uri:src \
  jsonparse:src/jsonparse/easy.sls \
  chez-srfi:%3a64.sls
AKKU_TREE_NAMES := $(foreach t,$(AKKU_TREES),$(firstword $(subst :, ,$(t))))

# tree NAME: NAME's tree under vendor/akku-trees. make stops at once, before
# any target runs, unless AKKU_TREES names NAME: no directory below names a
# tree nothing fetches.
tree = $(if $(filter $(1),$(AKKU_TREE_NAMES)),$(AKKU_TREES_DIR)/$(1),$(error AKKU_TREES names no $(1), which a directory of the Makefile's is in))

SERVER_DIR       := $(call tree,chez-http-server)
WEBSOCKET_DIR    := $(call tree,chez-websocket)
LIBUV_TREE       := $(call tree,chez-libuv)
HTTPARSE_DIR     := $(call tree,chez-httparse)
BYTE_MACHINE_DIR := $(call tree,byte-machine)
URI_DIR          := $(call tree,chez-uri)
JSONPARSE_DIR    := $(call tree,jsonparse)
SRFI_DIR         := $(call tree,chez-srfi)

# chez-libuv's copy, where deps builds its shim. Written out, not under
# $(BUILD_DIR): a make with a BUILD_DIR of its own, as
# tests/test-check-imports.sps's rows run, takes the checkout's built shim,
# and builds none of its own. `make clean` removes it with build/.
LIBUV_DIR := build/chez-libuv

# --- the library paths --------------------------------------------------------
# LIBDIRS is the path `make run` and `make dev` use: circuit's src/, then the
# server's, chez-websocket's, chez-libuv's copy's and those of the other
# libraries the server brings, then jsonparse's, then build/scheme-libs,
# which carries (srfi :64), then vendor/akku, which holds hashing.
# chez-libuv locates its C shim by an absolute path baked into the
# config.sls its build generates in the copy, so only the copy's src/ is
# needed. vendor/akku comes last, so it can stand in for none of the
# others' libraries.
#
# TEST_LIBDIRS is the suites' path: LIBDIRS, then tests/, which holds
# (circuit-testing). Test code stays off LIBDIRS.
BUILD_DIR := build
SRFI_LIBS := $(BUILD_DIR)/scheme-libs
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
LIBDIR_LIST := src \
  $(SERVER_DIR)/src \
  $(WEBSOCKET_DIR)/src \
  $(LIBUV_DIR)/src \
  $(HTTPARSE_DIR)/src $(BYTE_MACHINE_DIR)/src \
  $(URI_DIR)/src \
  $(JSONPARSE_DIR)/src \
  $(SRFI_LIBS) \
  $(AKKU_DIR)
LIBDIRS := $(subst $(SPACE),:,$(strip $(LIBDIR_LIST)))
TEST_LIBDIRS := $(LIBDIRS):tests

# make stops at once, before any target runs, on an entry of LIBDIR_LIST
# under vendor/akku-trees but a tree's src/ that AKKU_TREES names.
LIBDIR_STRAYS := $(filter-out $(foreach n,$(AKKU_TREE_NAMES),$(AKKU_TREES_DIR)/$(n)/src),$(filter $(AKKU_TREES_DIR)/%,$(LIBDIR_LIST)))
$(if $(LIBDIR_STRAYS),$(error LIBDIR_LIST holds $(LIBDIR_STRAYS), which no tree AKKU_TREES names gives))

# Every suite, in one order everywhere: make 3.82 to 4.2 leave $(wildcard)
# unsorted.
SUITES := $(sort $(wildcard tests/test-*.sps))

# Seconds a suite may run before timeout kills it and make test names it
# HUNG.
TEST_TIMEOUT ?= 300

# GNU timeout. Homebrew's coreutils installs it as gtimeout on macOS.
TIMEOUT ?= $(or $(shell command -v timeout 2>/dev/null),$(shell command -v gtimeout 2>/dev/null),timeout)

# --- the cost gate ------------------------------------------------------------
# oha, the gate's load client: the release the server's tests/fetch-oha.sh
# pins, which `make oha` fetches on the host, where the network is, into
# build/, where the container sees it.
OHA := $(BUILD_DIR)/oha

# The gate's program, and its path: LIBDIRS, then chez-libuv's copy's
# tests/, which holds (uv-testing), whose byte collector takes oha's report. GATE_FIRST,
# empty unless given, goes before them, so a mutant of a core library under
# build/ runs as `make gate GATE_FIRST=build/mutant`; a mutant of the
# program runs as `make gate GATE=build/mutant/gate.sps`.
GATE := tests/gate.sps
GATE_LIBDIRS = $(if $(GATE_FIRST),$(GATE_FIRST):)$(LIBDIRS):$(LIBUV_DIR)/tests

# Every directory on the library paths above that load circuit's libraries,
# LIBDIRS, TEST_LIBDIRS and GATE_LIBDIRS, each once, but GATE_FIRST, whose
# mutant stands in for src's on purpose. check-imports holds that none but
# src holds a (circuit ...) library Chez could load, its rule (j), so the
# one Chez loads is the one the audit read, whatever a path's order.
LIBRARY_DIRS = $(sort $(subst :, ,$(LIBDIRS) $(TEST_LIBDIRS) $(LIBDIRS):$(LIBUV_DIR)/tests))

# Seconds `make gate` or `make gate-rps` may run before timeout kills it
# and make names it HUNG. Each takes under a minute here; under CI's
# 30-minute job timeout, so the job names a hang rather than being killed.
GATE_TIMEOUT ?= 600

# One physical line: check-help reads it with awk, and fails if it ends in
# a backslash.
.PHONY: help check-help check-guix check-guix-inside fetch check-pins akku-deps lock check-akku-lock oha check-chez srfi deps dev run libdirs test check-suites check-imports gate gate-rps site-deps site check-site check-site-deps clean

.DEFAULT_GOAL := help

# The name column is as wide as the longest target's name.
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / \
	  { n++; name[n] = $$1; text[n] = $$2; if (length($$1) > width) width = length($$1) } \
	  END { format = "  \033[36m%-" width "s\033[0m %s\n"; \
	        for (i = 1; i <= n; i++) printf format, name[i], text[i] }' $(MAKEFILE_LIST)

# Reads what `make help` prints, colour codes stripped, so it checks the
# listing itself. Both directions: every .PHONY target is listed, and every
# listed target is in .PHONY. A listed target left out of .PHONY silently
# stops running once a file of its name exists.
check-help: ## Fail unless `make help` lists exactly the .PHONY targets
	@status=0; \
	if grep -qE '^\.PHONY:.*\\$$' Makefile; then \
	  echo "check-help: the .PHONY line ends in a backslash; keep it on one line" >&2; \
	  status=1; \
	fi; \
	help=$$($(MAKE) --no-print-directory help) || { \
	  echo "check-help: make help failed" >&2; \
	  exit 1; \
	}; \
	esc=$$(printf '\033'); \
	listed=$$(printf '%s\n' "$$help" | sed "s/$$esc\[[0-9;]*m//g" | awk '{ print $$1 }'); \
	phony=$$(awk '/^\.PHONY:/ { $$1 = ""; print }' Makefile); \
	for t in $$phony; do \
	  printf '%s\n' $$listed | grep -qxF "$$t" || { \
	    echo "check-help: make help does not list .PHONY target '$$t'; give it a '## ' description on its target line" >&2; \
	    status=1; \
	  }; \
	done; \
	for t in $$listed; do \
	  printf '%s\n' $$phony | grep -qxF "$$t" || { \
	    echo "check-help: make help lists '$$t', which is not in .PHONY" >&2; \
	    status=1; \
	  }; \
	done; \
	exit $$status

check-guix: ## Test scripts/guix-env on the host, then the toolchain inside the container
	@scripts/require-tools "$(GOAL)" guix
	@sh tests/guix-env-launcher.sh
	@scripts/guix-env make check-guix-inside

check-guix-inside: ## (inside the container) Assert the pinned toolchain, isolation and loopback-only network
	@CHEZ='$(CHEZ)' CC='$(CC)' sh scripts/guix-env-selftest

# Each package as Akku.lock pins it, downloaded, its sha256 checked, and
# unpacked by scripts/fetch-akku-lock: hashing into vendor/akku, and every
# one AKKU_TREES names into vendor/akku-trees. It needs curl or wget, tar,
# sha256sum or shasum, and diff, and xz with GNU tar, which reads the
# archive through it: bsdtar, macOS's, reads it itself. A tree that already
# records the lock's sha256 is held to its archive under its directory's
# dl/, the archive downloaded again first if dl/ lacks it or holds another,
# and the tree unpacked again if it differs. So with every archive in dl/
# it needs no network.
FETCH_TOOL = $(if $(shell command -v curl 2>/dev/null),curl,$(if $(shell command -v wget 2>/dev/null),wget,"curl or wget"))
SHA256_TOOL = $(if $(shell command -v sha256sum 2>/dev/null),sha256sum,$(if $(shell command -v shasum 2>/dev/null),shasum,"sha256sum or shasum"))
XZ_TOOL = $(if $(findstring GNU,$(shell tar --version 2>/dev/null)),xz)

fetch: ## (host) Fetch every dependency as Akku.lock pins it, each sha256 checked: hashing into vendor/akku, the others into vendor/akku-trees
	@scripts/require-tools "$(GOAL)" $(FETCH_TOOL) tar $(XZ_TOOL) $(SHA256_TOOL) diff
	AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_DIR) sh scripts/fetch-akku-lock hashing
	AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_TREES_DIR) sh scripts/fetch-akku-lock $(AKKU_TREE_NAMES)

# The two checks deps and check-pins share, each in one place.
# CHECK_LOCKED fails unless Akku.lock pins exactly hashing, chez-cmark-gfm
# and every tree AKKU_TREES names, each once, naming a project nothing
# fetches and a tree the lock doesn't pin (scripts/check-lock-projects).
# CHECK_LIBUV_COPY fails unless chez-libuv's copy is its tree plus its
# build's two products, build/ and src/libuv/private/config.sls, naming
# every other line `diff -rq` gives; a copy not made yet passes it
# (scripts/check-libuv-copy).
CHECK_LOCKED = AKKU_LOCK=$(AKKU_LOCK_FILE) sh scripts/check-lock-projects hashing chez-cmark-gfm $(AKKU_TREE_NAMES)
CHECK_LIBUV_COPY = sh scripts/check-libuv-copy $(LIBUV_TREE) $(LIBUV_DIR)

# CHECK_LOCKED, then scripts/fetch-akku-lock --check, which downloads
# nothing: each tree must record Akku.lock's sha256 and be the archive
# under its directory's dl/, with that sha256, unpacked, and it names each
# file that differs. Then CHECK_LIBUV_COPY. It goes on past a check that
# fails, so one run names every fault. Read-only, and it needs no git or
# network, so it runs in the container too. CI runs it after the tests and
# the gate, so it holds that they wrote into no tree, nor into the copy.
check-pins: ## Fail unless Akku.lock pins exactly what make fetch gets, each tree in vendor/akku and vendor/akku-trees is its archive, and chez-libuv's copy is its tree and its build's products
	@scripts/require-tools "$(GOAL)" awk sort uniq grep tar $(XZ_TOOL) $(SHA256_TOOL) diff
	@fail=0; \
	if ! $(CHECK_LOCKED); then \
	  echo "PIN MISMATCH: Akku.lock and the Makefile's AKKU_TREES name different packages. A lock move that adds or drops a package changes both, on one commit." >&2; fail=1; \
	fi; \
	trees=0; \
	AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_DIR) sh scripts/fetch-akku-lock --check hashing || trees=1; \
	AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_TREES_DIR) sh scripts/fetch-akku-lock --check $(AKKU_TREE_NAMES) || trees=1; \
	if [ $$trees -ne 0 ]; then \
	  echo "PIN MISMATCH: a tree above isn't the one Akku.lock pins. Run 'make fetch' on the host, which unpacks it again: an edit there is lost." >&2; fail=1; \
	fi; \
	if ! $(CHECK_LIBUV_COPY); then \
	  echo "PIN MISMATCH: $(LIBUV_DIR) isn't chez-libuv's tree and its build's products. Run 'make deps', which copies it again: an edit there is lost." >&2; fail=1; \
	fi; \
	exit $$fail

# --- Akku itself ---------------------------------------------------------------
# Akku 1.2.0, the release for Chez Scheme, as scripts/akku-tool.lock pins
# it, unpacked into build/akku-tool, where scripts/akku runs it from: the
# path is written out, as scripts/akku names it. Guix's Akku is 1.1.0,
# which knows only the archive's old signing key. `make clean` removes it,
# so akku-deps runs again after it.
AKKU := scripts/akku

akku-deps: ## (host, and after make clean) Fetch Akku 1.2.0 into build/akku-tool, as scripts/akku-tool.lock pins it, its sha256 checked
	@scripts/require-tools "$(GOAL)" $(FETCH_TOOL) tar $(XZ_TOOL) $(SHA256_TOOL) diff
	@AKKU_LOCK=scripts/akku-tool.lock AKKU_DEST=build/akku-tool sh scripts/fetch-akku-lock akku

# `akku update`, so that Akku reads today's index, then `akku lock`, which
# writes Akku.lock from Akku.manifest. Akku downloads the index with curl,
# and checks its signature itself.
lock: ## (host) Write Akku.lock from Akku.manifest with Akku 1.2.0, against today's index
	@scripts/require-tools "$(GOAL)" curl $(CHEZ)
	$(AKKU) update
	$(AKKU) lock

# scripts/check-akku-lock: `akku update`, then `akku lock` on a copy of
# Akku.manifest in a scratch directory, and it fails unless every token
# `akku lock` writes for each project, symbols and strings alike, in order,
# is Akku.lock's; layout, comments and the projects' order aside. So a
# release on the index that a range in the manifest admits fails it until
# `make lock` moves the lock. It never skips: where Akku isn't there, it
# fails naming `make akku-deps`, and where the index can't be fetched, the
# network. scripts/akku unsets AKKU_SETTINGS, so no-network can't leave it
# on an old index. Its own test, tests/check-akku-lock.sh, runs it on a fake
# akku in check-site-deps.
check-akku-lock: ## (host) Fail unless Akku.lock is what Akku 1.2.0 makes of Akku.manifest against today's index
	@scripts/require-tools "$(GOAL)" curl $(CHEZ) awk sort cmp diff
	@AKKU=$(AKKU) AKKU_LOCK=$(AKKU_LOCK_FILE) sh scripts/check-akku-lock

# The server's tests/fetch-oha.sh, in its tree, pins oha's version and each
# platform's sha256, and keeps a build/oha that already matches. It needs
# the network, so it runs on the host, and refuses in the container at once.
oha: ## (host) Fetch oha, the gate's load client, into build/oha: the release the server's tree pins, its sha256 checked
	@if [ -n "$${GUIX_ENVIRONMENT:-}" ]; then \
	  echo "make oha fetches oha from GitHub, and this container has no network: run it on the host." >&2; \
	  exit 2; \
	fi
	sh $(SERVER_DIR)/tests/fetch-oha.sh $(OHA)

# Never fetches: the container has no network, so a missing tree is
# fetched on the host. chez-srfi ships Akku's percent-encoded filenames
# (%3a64.sls) and Chez resolves (srfi :64) only from the decoded spelling
# (:64.sls), so every entry is linked under both and the tree itself is left
# alone. The links from before are removed first, so the directory holds
# this tree's entries and no other's. `ln -sfn` replaces a link in place,
# and the -n is what stops it following an existing link to a directory
# into the tree. deps and srfi both run it: the docs site's suites need
# SRFI-64 and nothing else, so srfi needs neither libuv nor a compiler.
define link-srfi
	@rm -rf $(SRFI_LIBS)/srfi
	@mkdir -p $(SRFI_LIBS)/srfi
	@set -e; \
	src="$(abspath $(SRFI_DIR))"; dst="$(abspath $(SRFI_LIBS))/srfi"; \
	for f in "$$src"/*; do \
	  b=$$(basename "$$f"); \
	  ln -sfn "$$f" "$$dst/$$b"; \
	  d=$$(printf '%s' "$$b" | sed 's/%3a/:/g'); \
	  [ "$$d" = "$$b" ] || ln -sfn "$$f" "$$dst/$$d"; \
	done
endef

# Runs $(CHEZ) once, asking its version and build, and refuses one that is
# not Chez Scheme 10.4.1 or later, threaded, chez-http-server's floor,
# naming what it found and what it needs (scripts/require-chez).
# A CHEZ that is empty or not on PATH it refuses itself, so require-tools
# doesn't ask first. deps takes it first, so every target that runs Chez on
# circuit's libraries, deps itself, which builds chez-libuv's shim with it,
# test, run, dev, gate, gate-rps, check-suites and check-imports, holds it
# before Chez runs. The docs site's targets ask less of it: see site.
check-chez: ## Fail unless CHEZ is Chez Scheme 10.4.1 or later, threaded, naming what it found
	@scripts/require-chez "$(GOAL)" "$(CHEZ)"

# CHECK_LOCKED first. Then each tree must be there, by the file AKKU_TREES
# names under it, and record the sha256 Akku.lock pins
# (scripts/fetch-akku-lock --check-record), as hashing must under
# vendor/akku. chez-libuv's tree is copied to build/chez-libuv again
# whenever CHECK_LIBUV_COPY fails, a copy not made yet aside, and
# chez-libuv's own `make build` builds the shim and its config.sls in the
# copy: the fetched tree stays its archive, which check-pins holds.
deps: check-chez ## Copy chez-libuv to build/chez-libuv and build its shim there, and link SRFI-64 into build/scheme-libs; never fetches
	@scripts/require-tools "$(GOAL)" $(CHEZ) $(CC) pkg-config
	@if ! $(CHECK_LOCKED) > /dev/null; then \
	  echo "deps: so Akku.lock and the Makefile's AKKU_TREES name different packages. A lock move that adds or drops a package changes both, on one commit." >&2; \
	  exit 1; \
	fi
	@if [ ! -e $(AKKU_DIR)/hashing/sha-2.scm ]; then \
	  echo "deps: $(AKKU_DIR)/hashing/sha-2.scm not found, so hashing, which Akku.lock pins, isn't fetched. Run 'make fetch' on the host: make deps never fetches, and the container has no network." >&2; \
	  exit 1; \
	fi
	@if ! AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_DIR) sh scripts/fetch-akku-lock --check-record hashing > /dev/null; then \
	  echo "deps: so $(AKKU_DIR) holds another hashing than the one Akku.lock pins. Run 'make fetch' on the host: make deps never fetches, and the container has no network." >&2; \
	  exit 1; \
	fi
	@for t in $(AKKU_TREES); do \
	  name=$${t%%:*}; f=$(AKKU_TREES_DIR)/$$name/$${t#*:}; \
	  if [ ! -e "$$f" ]; then \
	    echo "deps: $$f not found, so $$name, which Akku.lock pins, isn't fetched. Run 'make fetch' on the host: make deps never fetches, and the container has no network." >&2; \
	    exit 1; \
	  fi; \
	done
	@if ! AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_TREES_DIR) sh scripts/fetch-akku-lock --check-record $(AKKU_TREE_NAMES) > /dev/null; then \
	  echo "deps: so $(AKKU_TREES_DIR) holds another tree than one Akku.lock pins. Run 'make fetch' on the host: make deps never fetches, and the container has no network." >&2; \
	  exit 1; \
	fi
	@if [ ! -e $(LIBUV_DIR) ] || ! $(CHECK_LIBUV_COPY) > /dev/null; then \
	  rm -rf $(LIBUV_DIR) $(LIBUV_DIR).tmp && \
	  mkdir -p $(dir $(LIBUV_DIR)) && \
	  cp -R $(LIBUV_TREE) $(LIBUV_DIR).tmp && \
	  mv $(LIBUV_DIR).tmp $(LIBUV_DIR) && \
	  echo "deps: $(LIBUV_TREE) copied to $(LIBUV_DIR)" || exit 1; \
	fi
	@$(MAKE) --no-print-directory -C $(LIBUV_DIR) build
	$(link-srfi)
	@echo "deps: chez-libuv's shim built in $(LIBUV_DIR); $(SRFI_DIR) linked into $(SRFI_LIBS)/srfi"

srfi: ## Link SRFI-64 into build/scheme-libs, for the docs site's suites; never fetches
	@if [ ! -e $(SRFI_DIR)/%3a64.sls ]; then \
	  echo "srfi: $(SRFI_DIR)/%3a64.sls not found, so chez-srfi, which Akku.lock pins, isn't fetched. Run 'make fetch' on the host: make srfi never fetches, and the container has no network." >&2; \
	  exit 1; \
	fi
	@if ! AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(AKKU_TREES_DIR) sh scripts/fetch-akku-lock --check-record chez-srfi > /dev/null; then \
	  echo "srfi: so $(AKKU_TREES_DIR) holds another chez-srfi than the one Akku.lock pins. Run 'make fetch' on the host: make srfi never fetches, and the container has no network." >&2; \
	  exit 1; \
	fi
	$(link-srfi)

dev: deps ## Start a REPL with circuit and the server on the library path
	$(CHEZ) --libdirs $(LIBDIRS)

run: deps ## Run a program on the library path: make run PROGRAM=examples/hello.sps
	@test -n "$(PROGRAM)" || { echo "run: set PROGRAM=path/to/program.sps" >&2; exit 2; }
	$(CHEZ) --libdirs $(LIBDIRS) --program $(PROGRAM)

# One line, the path and nothing else, so a service or a container can take
# it: scheme --libdirs "$(make libdirs)" --program app.sps, from the
# checkout, where its relative directories resolve. It builds nothing: run
# make deps first.
libdirs: ## Print the library path a program needs, LIBDIRS, on one line: for running it without make
	@printf '%s\n' '$(LIBDIRS)'

# Runs each suite as its own process under GNU timeout and reports its exit
# status, or HUNG when timeout killed it (exit 124). It fails if any suite
# failed or hung, or if none matched. At a terminal, --foreground keeps a
# suite in make's process group, so Ctrl-C reaches it at once; but then
# timeout kills the suite alone, and a child it started (curl, a server)
# lives on, holding its port. Anywhere else, CI and pipes included, timeout
# kills the suite's whole process group. The checks come first:
# check-chez, through deps, check-help, check-suites and, once src/ exists,
# check-imports each stop it, so the first library under src/ is audited
# without anyone remembering to.
test: deps check-help check-suites $(if $(wildcard src),check-imports) ## Run every tests/test-*.sps under timeout; fail if one fails or hangs, or none exists
	@scripts/require-tools "$(GOAL)" $(TIMEOUT) $(CHEZ)
	@if [ -z "$(SUITES)" ]; then \
	  echo "test: no suites: nothing matches tests/test-*.sps" >&2; \
	  exit 1; \
	fi; \
	passed=0; failed=0; hung=0; fg=; \
	if [ -t 0 ]; then fg=--foreground; fi; \
	for t in $(SUITES); do \
	  echo "=== $$t"; \
	  $(TIMEOUT) $$fg $(TEST_TIMEOUT) $(CHEZ) --libdirs $(TEST_LIBDIRS) --program $$t; \
	  rc=$$?; \
	  if [ $$rc -eq 0 ]; then \
	    echo "test: pass $$t"; passed=$$((passed + 1)); \
	  elif [ $$rc -eq 124 ]; then \
	    echo "test: HUNG $$t (no exit within $(TEST_TIMEOUT)s)"; hung=$$((hung + 1)); \
	  else \
	    echo "test: FAIL $$t (exit $$rc)"; failed=$$((failed + 1)); \
	  fi; \
	done; \
	echo "test: ran $$((passed + failed + hung)), passed $$passed, failed $$failed, hung $$hung"; \
	[ $$failed -eq 0 ] && [ $$hung -eq 0 ]

# Reads every suite as data and fails unless each one's last datum is the
# shared exit form, (circuit-testing)'s suite-exit-form, and no datum before
# it holds an exit form but (exit 1), naming each suite that breaks either
# rule (tests/check-suites.sps). With no suite it passes: make test fails
# that case itself.
check-suites: deps ## Fail unless every tests/test-*.sps ends with the shared exit form
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@$(CHEZ) --libdirs $(TEST_LIBDIRS) --program tests/check-suites.sps $(SUITES)

# Reads every file under src as data and fails unless each is a .sls library
# at its name's path, only (circuit http-server) and (circuit middleware
# waits) import the server or (chezscheme), and only (circuit websocket)
# imports chez-websocket, through its facade (websocket) alone: the core is
# plain R6RS, importing its own libraries and (rnrs ...) alone, but
# (circuit session), which imports (hashing sha-2) through only, and
# (circuit json), which imports (jsonparse easy) through only
# (tests/check-imports.sps). (hashing sha-2), read from AKKU_DIR as Chez
# resolves it, and the libraries it imports, import (rnrs ...) and each
# other alone; (jsonparse easy), read from byte-machine's src/ and
# JSONPARSE_DIR's, in LIBDIRS' order, and the libraries it imports, import
# (rnrs ...), each other and byte-machine's runtime alone. And no other directory of
# LIBRARY_DIRS holds a (circuit ...) library, nor any but AKKU_DIR a hashing
# one, nor any but JSONPARSE_DIR's src/ a jsonparse one, nor any but
# BYTE_MACHINE_DIR's src/ a byte-machine. It names each breach on
# stderr. make test runs it once src/ exists; an src/ with no library fails
# it. Its own suite, tests/test-check-imports.sps, runs in make test whether
# src/ exists or not.
check-imports: deps ## Fail unless only the two impure libraries import the server or (chezscheme), only (circuit websocket) imports (websocket), only (circuit session) imports hashing, only (circuit json) imports jsonparse, the core imports nothing else, only src holds circuit's libraries, only vendor/akku hashing, and the path one jsonparse and one byte-machine
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@$(CHEZ) --libdirs $(TEST_LIBDIRS) --program tests/check-imports.sps src --akku $(AKKU_DIR) --jsonparse $(JSONPARSE_DIR)/src --byte-machine $(BYTE_MACHINE_DIR)/src $(LIBRARY_DIRS)

# The cost gate, outside `make test`: bytes a
# request through circuit's adapter, against the raw server and its
# `awaiting` path, in one process, with the counts fixed (tests/gate.sps).
# It prints G1, G2, G8 and G8 on-done, and fails when a held gate, G3 to G5, G7, G8 own, G9
# or G10, is over its bound, naming it. CI runs it as a step of its own: noise doesn't move a
# byte count. At a terminal, timeout runs with --foreground, as in `make
# test`, and an oha it started may outlive a HUNG gate.
gate: deps ## Run the cost gate: bytes a request over the raw server; fail if a held gate (G3 to G5, G7, G8 own, G9, G10) is over its bound
	@scripts/require-tools "$(GOAL)" $(TIMEOUT) $(CHEZ)
	@[ -x $(OHA) ] || { echo "gate: $(OHA) not found. Run 'make oha' on the host: it fetches oha, and the container has no network." >&2; exit 1; }
	@fg=; if [ -t 0 ]; then fg=--foreground; fi; \
	$(TIMEOUT) $$fg $(GATE_TIMEOUT) $(CHEZ) --libdirs $(GATE_LIBDIRS) --program $(GATE) bytes $(OHA); \
	rc=$$?; \
	[ $$rc -ne 124 ] || echo "gate: HUNG (no exit within $(GATE_TIMEOUT)s)" >&2; \
	exit $$rc

# G6, the smoke: requests a second, a GET through the adapter against raw, oha
# -z 5s, two rounds at 1 and 50 connections, alternating. It prints the
# rate at 50 connections against 90% of raw's and never fails on it: a rate
# is noise-bound. Not in CI; run it before a release.
gate-rps: deps ## (before a release) Print requests a second through the adapter against raw's (G6); never fails on the ratio
	@scripts/require-tools "$(GOAL)" $(TIMEOUT) $(CHEZ)
	@[ -x $(OHA) ] || { echo "gate-rps: $(OHA) not found. Run 'make oha' on the host: it fetches oha, and the container has no network." >&2; exit 1; }
	@fg=; if [ -t 0 ]; then fg=--foreground; fi; \
	$(TIMEOUT) $$fg $(GATE_TIMEOUT) $(CHEZ) --libdirs $(GATE_LIBDIRS) --program $(GATE) rps $(OHA); \
	rc=$$?; \
	[ $$rc -ne 124 ] || echo "gate-rps: HUNG (no exit within $(GATE_TIMEOUT)s)" >&2; \
	exit $$rc

# --- the docs site ------------------------------------------------------------
# docs/*.md rendered to build/site/ through chez-cmark-gfm, as chez-http-server
# and chez-websocket render their own. Akku.lock pins chez-cmark-gfm for the
# site alone: nothing under src/ and no tests/test-*.sps imports it, so `make
# test` needs none of this. The site needs the system cmark-gfm library
# (`cmark-gfm` from Homebrew or apt), not libuv. In the container,
# scripts/guix-env-enter hands chez-cmark-gfm the profile's by absolute path
# (CHEZ_CMARK_GFM_LIBS).
#
# chez-cmark-gfm comes from an `akku install` tree when there is one, and
# otherwise from the archive Akku.lock pins, downloaded and checked against the
# lock's sha256 by scripts/fetch-akku-lock. Run `make site-deps` once on the
# host, where the network is; after that it needs none, and the container finds
# the tree under build/. Akku.lock is `akku lock`'s output for Akku.manifest,
# where chez-cmark-gfm is a development dependency.
SITE_CMARK   := $(if $(wildcard .akku/lib/cmark/gfm.sls),.akku/lib,$(BUILD_DIR)/akku/chez-cmark-gfm/src)
SITE_LIBDIRS := .:$(SITE_CMARK)
SITE_REF     ?= main

site-deps: ## (host, once) Get chez-cmark-gfm as Akku.lock pins it: an `akku install` tree, else the locked archive
	@if [ -f .akku/lib/cmark/gfm.sls ]; then \
	  echo "site-deps: using .akku/lib (akku install)"; \
	else \
	  AKKU_LOCK=$(AKKU_LOCK_FILE) AKKU_DEST=$(BUILD_DIR)/akku sh scripts/fetch-akku-lock chez-cmark-gfm; \
	fi

# The site's targets refuse a $(CHEZ) that is not a threaded Chez Scheme,
# but not one below the server's floor: nothing they run loads the server
# or libuv, and CI's site job and the Pages workflow run them on apt's
# Chez, which is below it. Threaded, since check-site's suites import
# (circuit-testing), which takes Chez's mutexes, a threaded build's alone
# (scripts/require-chez --any-version).
site: site-deps ## Render docs/ into build/site/ (open build/site/index.html); SITE_REF=<tag> pins links to repository files
	@scripts/require-chez --any-version "$(GOAL)" "$(CHEZ)"
	@mkdir -p $(BUILD_DIR)/site
	@SITE_REF="$(SITE_REF)" SITE_OUT=$(BUILD_DIR)/site \
	  $(CHEZ) --libdirs $(SITE_LIBDIRS) --program build-site.sps
	@cp site/style.css $(BUILD_DIR)/site/style.css
	@echo "site: $(BUILD_DIR)/site ready (open $(BUILD_DIR)/site/index.html)"

# The generator's own suites (SRFI-64, so `srfi` too), then the real site,
# rendered in memory and checked. site-unit runs with no chez-cmark-gfm on its
# path, so a site library it tests that starts importing (cmark gfm) fails
# there at import.
check-site: site-deps srfi ## Test the site generator, then render docs/ in memory: nav, links, anchors (GitHub's too), no .md leak, no <pre> reflow
	@scripts/require-chez --any-version "$(GOAL)" "$(CHEZ)"
	@$(CHEZ) --libdirs .:tests:$(SRFI_LIBS) --program tests/site-unit.sps
	@$(CHEZ) --libdirs $(SITE_LIBDIRS):tests:$(SRFI_LIBS) --program tests/site-render-unit.sps
	@SITE_REF="$(SITE_REF)" $(CHEZ) --libdirs $(SITE_LIBDIRS) --program tests/site-check.sps

# The Akku scripts' own tests, offline, each on fakes of its own:
# fetch-akku-lock, which fetch, akku-deps and site-deps run, against an
# archive and a lock; check-akku-lock and scripts/akku, on a fake akku and
# a fake Chez; and check-pins and deps, on fake trees, a fake lock and a
# fake chez-libuv build. CI's linux job runs it.
check-site-deps: ## Test the Akku scripts, check-pins and deps' copy offline, on fake archives, locks, trees and akku
	@sh tests/fetch-akku-lock.sh
	@sh tests/check-akku-lock.sh
	@sh tests/akku.sh
	@sh tests/check-pins.sh

# Removes build/, and with it chez-libuv's copy and its shim, and Akku
# 1.2.0 (akku-deps). The path is written out, not a variable. vendor/akku
# and vendor/akku-trees stay: `make fetch` got them, and the container can't.
clean: ## Remove build/, chez-libuv's copy and its shim with it
	rm -rf build
