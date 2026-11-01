# ADR-0008: `hashing`, from Akku, is circuit's first runtime dependency

- **Status:** Proposed (the owner chose `hashing` and approved the sessions design on
  2026-11-01; accepted when slice 10b brings it in, the design §6)
- **Date:** 2026-11-01
- **Scope:** HMAC-SHA-256 for `(circuit session)`, and how a runtime dependency from Akku
  reaches the build, the container, CI and an app
- **Plan:** [the sessions design](../2026-11-01-sessions-design.md) §4, §7, §8 item 1

## Context

Sessions sign a cookie with HMAC-SHA-256, which neither R6RS nor Chez has. Gwen
Weinholt's `hashing` 1.4.0, on Akku, has SHA-2 and HMAC in plain `(rnrs)` on Chez, MIT,
with no dependencies, tested against RFC 4231. Its suites pass on Chez 10.4.1 in
circuit's container (the design §4). Writing HMAC-SHA-256 in circuit was the other
choice: about 225 lines, held to the same vectors, with no dependency.

circuit's dependencies so far are submodules of the project's own (ADR-0003), because
chez-http-server isn't on the Akku index. The owner will publish circuit on Akku once
the server is there, so a dependency taken from Akku now is the one circuit's manifest
will name then.

## Decision

1. **`Akku.manifest` names `("hashing" "^1.4.0")` in `depends`,** and `Akku.lock` pins
   its archive and sha256, as it pins chez-cmark-gfm's.
2. **It is fetched on the host,** by `scripts/fetch-akku-lock hashing` into
   `vendor/akku/`, which checks the sha256. `make submodules` runs it, so a fresh clone
   needs one host step before `make deps`. `vendor/akku/` is git-ignored and outside
   `build/`, so `make clean` keeps it. The container and `make test` never fetch.
3. **`vendor/akku` is on the library path,** in make, CI and the container, and holds
   nothing but `hashing/` and the archive. `make deps` fails, naming `make submodules`,
   when it is missing.
4. **Only `(circuit session)` imports it, only `(hashing sha-2)`, through `only`.**
   `make check-imports` holds that, holds `(hashing sha-2)`'s own closure to `(rnrs ...)`
   and its two sibling libraries as Chez resolves them, and holds that no other
   directory on the path has a `hashing` (ADR-0006, amended).
5. **A move of the lock is tried first:** `hashing`'s own suites, and circuit's rows
   holding RFC 4231's cases through the pin, pass on it before it lands.

## Consequences

- **circuit runs code it didn't write in the signing path.** It is 23 lines of HMAC and
  the SHA-2 core, read before they ran, held by circuit's rows to RFC 4231, and its
  imports held by `make check-imports`.
- **An app working from a checkout runs `make submodules`,** as it does for the server.
  Once circuit is published on Akku, `depends` brings `hashing` with it.
- **A second runtime dependency from Akku** takes the same lock, fetch and checks, with a
  library path of its own if its tree isn't laid out as its libraries' names.
