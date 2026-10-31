# circuit
#
# On a Guix host, run targets through the container:
#   scripts/guix-env make <target>
#
# Two dependencies, each pinned by gitlink at a release tag under vendor/:
# chez-http-server, and chez-websocket for (circuit websocket). The server
# carries its own pins, and circuit uses them through it: chez-libuv,
# chez-httparse with byte-machine under it, uriparse, and chez-srfi for
# SRFI-64. chez-websocket pins a server of its own, which circuit doesn't
# clone: it must be SERVER_PIN. `make submodules` clones those, and not the
# server's test clients; `make check-pins` holds them where the pins say.
# Both need git and the network, so they run on the host: the container has
# neither. `make deps` builds chez-libuv's shim and links SRFI-64, and never
# fetches.

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

# chez-libuv's make, which deps and clean run, gets none of this command
# line's variables: its clean removes its own $(BUILD_DIR), which
# `make clean BUILD_DIR=..` would otherwise point outside it. CHEZ and CC
# reach it through the environment, exported above.
MAKEOVERRIDES =

# The make target to name in a missing-tool hint (scripts/require-tools):
# what the user typed, $(MAKECMDGOALS), or, when that is empty, the
# recipe's own target, $@. Recursively expanded (=, not :=), so each
# reference picks up whichever recipe is running it.
GOAL = $(strip $(if $(MAKECMDGOALS),$(MAKECMDGOALS),$@))

# --- the pins ----------------------------------------------------------------
SERVER_DIR := vendor/chez-http-server
SERVER_PIN := 5c16f64b34087ff32225de4838fe0b83a3d55bb2  # v0.10.0
WEBSOCKET_DIR := vendor/chez-websocket
WEBSOCKET_PIN := 4b70f22b9ab8716c999d2599a75c7ee6a357ecd4  # v0.5.1

# --- the pins it carries ------------------------------------------------------
LIBUV_DIR        := $(SERVER_DIR)/vendor/chez-libuv
HTTPARSE_DIR     := $(SERVER_DIR)/vendor/chez-httparse
BYTE_MACHINE_DIR := $(HTTPARSE_DIR)/vendor/byte-machine
URIPARSE_DIR     := $(SERVER_DIR)/vendor/uriparse
SRFI_DIR         := $(SERVER_DIR)/vendor/chez-srfi

# --- the library paths --------------------------------------------------------
# LIBDIRS is the path `make run` and `make dev` use: circuit's src/, then the
# server's, chez-websocket's and the libraries the server carries. chez-libuv
# locates its C shim by an absolute path baked into the config.sls its build
# generates, so only its src/ is needed. build/scheme-libs carries (srfi :64).
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
  $(URIPARSE_DIR)/src \
  $(SRFI_LIBS)
LIBDIRS := $(subst $(SPACE),:,$(strip $(LIBDIR_LIST)))
TEST_LIBDIRS := $(LIBDIRS):tests

# Every suite, in one order everywhere: make 3.82 to 4.2 leave $(wildcard)
# unsorted.
SUITES := $(sort $(wildcard tests/test-*.sps))

# Seconds a suite may run before timeout kills it and make test names it
# HUNG.
TEST_TIMEOUT ?= 300

# GNU timeout. Homebrew's coreutils installs it as gtimeout on macOS.
TIMEOUT ?= $(or $(shell command -v timeout 2>/dev/null),$(shell command -v gtimeout 2>/dev/null),timeout)

# --- the cost gate ------------------------------------------------------------
# oha, the gate's load client: the server's pinned release, which `make oha`
# fetches on the host, where the network is, into build/, where the
# container sees it.
OHA := $(BUILD_DIR)/oha

# The gate's program, and its path: LIBDIRS, then chez-libuv's tests/, which
# holds (uv-testing), whose byte collector takes oha's report. GATE_FIRST,
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
.PHONY: help check-help check-guix check-guix-inside submodules check-pins oha check-chez srfi deps dev run libdirs test check-suites check-imports gate gate-rps site-deps site check-site check-site-deps clean

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

# Targeted, so neither chez-libuv's own vendored libuv nor the server's test
# clients (vtest2) are cloned: the shim links the libuv pkg-config finds when
# it meets chez-libuv's floor, as the container's does. chez-websocket's own
# server isn't cloned either: circuit's is the one on the path.
submodules: ## (host) Clone the pinned server, the pins it carries, and chez-websocket
	@scripts/require-tools "$(GOAL)" git
	git submodule update --init $(SERVER_DIR) $(WEBSOCKET_DIR)
	git -C $(SERVER_DIR) submodule update --init vendor/chez-libuv vendor/uriparse vendor/chez-srfi
	git -C $(SERVER_DIR) submodule update --init --recursive vendor/chez-httparse

# Each checkout is asked for its own .git first: in a submodule that was
# never cloned, `git -C` would climb to the repository around it and answer
# that one's commit: for chez-websocket's server, circuit's own gitlink.
# Read-only.
check-pins: ## (host) Fail unless the server and chez-websocket sit at their pins, chez-websocket's server pin is SERVER_PIN, and each pin the server carries sits where it records
	@scripts/require-tools "$(GOAL)" git
	@fail=0; \
	check_pin() { \
	  got=; [ -e "$$1/.git" ] && got=$$(git -C "$$1" rev-parse HEAD 2>/dev/null); \
	  if [ -z "$$2" ] || [ "$$got" != "$$2" ]; then \
	    echo "PIN MISMATCH: $$1 at $${got:-<absent>}, expected $${2:-<no gitlink recorded>}" >&2; fail=1; \
	  else echo "pin ok: $$1 $$2"; fi; }; \
	recorded() { git -C "$$1" rev-parse --verify --quiet "HEAD:$$2"; }; \
	gitlink() { \
	  rec=$$(git ls-files -s -- "$$1" | awk '$$1 == "160000" && $$3 == 0 { print $$2 }'); \
	  if [ "$$rec" != "$$3" ]; then \
	    echo "PIN MISMATCH: the gitlink records $$1 at $${rec:-<none>}, $$2 says $$3" >&2; fail=1; \
	  fi; }; \
	gitlink $(SERVER_DIR) SERVER_PIN $(strip $(SERVER_PIN)); \
	check_pin $(SERVER_DIR) $(strip $(SERVER_PIN)); \
	gitlink $(WEBSOCKET_DIR) WEBSOCKET_PIN $(strip $(WEBSOCKET_PIN)); \
	check_pin $(WEBSOCKET_DIR) $(strip $(WEBSOCKET_PIN)); \
	if [ -e "$(WEBSOCKET_DIR)/.git" ]; then \
	  wsrv=$$(recorded $(WEBSOCKET_DIR) vendor/chez-http-server); \
	  if [ "$$wsrv" != "$(strip $(SERVER_PIN))" ]; then \
	    echo "PIN MISMATCH: $(WEBSOCKET_DIR) pins the server at $${wsrv:-<no gitlink recorded>}, SERVER_PIN says $(strip $(SERVER_PIN))" >&2; fail=1; \
	  else echo "pin ok: $(WEBSOCKET_DIR)'s server $$wsrv, SERVER_PIN"; fi; \
	fi; \
	for d in chez-libuv chez-httparse uriparse chez-srfi; do \
	  check_pin $(SERVER_DIR)/vendor/$$d "$$(recorded $(SERVER_DIR) vendor/$$d)"; \
	done; \
	check_pin $(BYTE_MACHINE_DIR) "$$(recorded $(HTTPARSE_DIR) vendor/byte-machine)"; \
	for d in $(SERVER_DIR) $(WEBSOCKET_DIR) $(LIBUV_DIR) $(HTTPARSE_DIR) $(BYTE_MACHINE_DIR) $(URIPARSE_DIR) $(SRFI_DIR); do \
	  if [ -e "$$d/.git" ] && [ -n "$$(git -C $$d status --porcelain --untracked-files=no 2>/dev/null)" ]; then \
	    echo "PIN DIRTY: $$d has local edits to tracked files" >&2; fail=1; fi; \
	done; \
	exit $$fail

# The server's tests/fetch-oha.sh pins oha's version and each platform's
# sha256, and keeps a build/oha that already matches. It needs the network,
# so it runs on the host, and refuses in the container at once.
oha: ## (host) Fetch oha, the gate's load client, into build/oha: the server's pinned release, its sha256 checked
	@if [ -n "$${GUIX_ENVIRONMENT:-}" ]; then \
	  echo "make oha fetches oha from GitHub, and this container has no network: run it on the host." >&2; \
	  exit 2; \
	fi
	sh $(SERVER_DIR)/tests/fetch-oha.sh $(OHA)

# Never fetches: the container has no network, so an empty submodule is
# filled on the host. chez-srfi ships Akku's percent-encoded filenames
# (%3a64.sls) and Chez resolves (srfi :64) only from the decoded spelling
# (:64.sls), so every entry is linked under both and the submodule's own
# tree is left alone. `ln -sfn` replaces a link in place, and the -n is what
# stops it following an existing link to a directory into the submodule.
# deps and srfi both run it: the docs site's suites need SRFI-64 and nothing
# else, so srfi needs neither libuv nor a compiler.
define link-srfi
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
# not Chez Scheme 10.4.1 or later, threaded, chez-http-server's floor
# (ADR-0002), naming what it found and what it needs (scripts/require-chez).
# A CHEZ that is empty or not on PATH it refuses itself, so require-tools
# doesn't ask first. deps takes it first, so every target that runs Chez on
# circuit's libraries, deps itself, which builds chez-libuv's shim with it,
# test, run, dev, gate, gate-rps, check-suites and check-imports, holds it
# before Chez runs. The docs site's targets ask less of it: see site.
check-chez: ## Fail unless CHEZ is Chez Scheme 10.4.1 or later, threaded, naming what it found
	@scripts/require-chez "$(GOAL)" "$(CHEZ)"

deps: check-chez ## Build chez-libuv's shim and link SRFI-64 into build/scheme-libs; never fetches
	@scripts/require-tools "$(GOAL)" $(CHEZ) $(CC) pkg-config
	@for f in $(SERVER_DIR)/src/http-server.sls $(WEBSOCKET_DIR)/src/websocket.sls $(LIBUV_DIR)/Makefile $(HTTPARSE_DIR)/src $(BYTE_MACHINE_DIR)/src $(URIPARSE_DIR)/src $(SRFI_DIR)/%3a64.sls; do \
	  if [ ! -e "$$f" ]; then \
	    echo "deps: $$f not found, so a submodule is empty or missing. Run 'make submodules' on the host: make deps never fetches, and the container has no network." >&2; \
	    exit 1; \
	  fi; \
	done
	@$(MAKE) --no-print-directory -C $(LIBUV_DIR) build
	$(link-srfi)
	@echo "deps: chez-libuv's shim built; $(SRFI_DIR) linked into $(SRFI_LIBS)/srfi"

srfi: ## Link SRFI-64 into build/scheme-libs, for the docs site's suites; never fetches
	@if [ ! -e $(SRFI_DIR)/%3a64.sls ]; then \
	  echo "srfi: $(SRFI_DIR)/%3a64.sls not found, so a submodule is empty or missing. Run 'make submodules' on the host: make srfi never fetches, and the container has no network." >&2; \
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
# plain R6RS, importing its own libraries and (rnrs ...) alone
# (tests/check-imports.sps). And no other directory of LIBRARY_DIRS holds a
# (circuit ...) library. It names each breach on stderr. make test runs
# it once src/ exists; an src/ with no library fails it. Its own suite,
# tests/test-check-imports.sps, runs in make test whether src/ exists or not.
check-imports: deps ## Fail unless only the two impure libraries import the server or (chezscheme), only (circuit websocket) imports (websocket), the core imports nothing else, and only src holds circuit's libraries
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@$(CHEZ) --libdirs $(TEST_LIBDIRS) --program tests/check-imports.sps src $(LIBRARY_DIRS)

# The cost gate (design §15.6, ADR-0007), outside `make test`: bytes a
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
	  AKKU_DEST=$(BUILD_DIR)/akku sh scripts/fetch-akku-lock chez-cmark-gfm; \
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

check-site-deps: ## Test scripts/fetch-akku-lock offline, against a local archive and lock of its own
	@sh tests/fetch-akku-lock.sh

# Removes build/, and chez-libuv's own build products inside its checkout.
# The path is written out, not a variable.
clean: ## Remove build/ and chez-libuv's built shim
	rm -rf build
	-@[ -f $(LIBUV_DIR)/Makefile ] && $(MAKE) --no-print-directory -C $(LIBUV_DIR) clean
