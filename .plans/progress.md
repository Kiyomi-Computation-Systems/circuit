# Progress ledger

Where circuit stands. Read it with [global-constraints.md](global-constraints.md)
before starting slice work. When a slice merges, update **Now** and add a
close-out under **Close-outs**, newest first.

## Now

- **The design** is [2026-10-24-circuit-design.md](2026-10-24-circuit-design.md), on
  `design/circuit-on-coroutines`, not yet merged. Its §15 records the owner's decisions;
  ADR-0004 to ADR-0006 take them up.
- **Slice 1, scaffolding (design §17), on `chore/scaffolding`**, stacked on the design
  branch:
  - AGENTS.md describes circuit; ADR-0001 (no Windows);
  - the server pinned at v0.8.0 under `vendor/` (ADR-0003), with `make submodules` and
    `make check-pins` on the host;
  - the Guix container (ADR-0002): `make check-guix` passes, 63 host-side checks and the
    self-test inside;
  - the Makefile and the test harness: `(circuit-testing)`, `check-suites`, `make test`
    under GNU timeout;
  - the import audit (`make check-imports`, ADR-0006) and the Linux CI workflow, built in
    worktrees of their own;
  - ADR-0002 to ADR-0006, this ledger, `global-constraints.md`, `CHANGELOG.md`, README.
- **Next: slice 2, spikes S1 and S2** (design §13): a port whose reads wait, which decides
  the request body's interface; and the cost of a coroutine for every request, which sets
  the gate on circuit's cost over the raw server.

## Open

- **`make check-imports` joins `make test`'s prerequisites** when `src/` gets its first
  library (slice 3). Until then it fails on purpose, for want of a library, and its fixture
  suite runs in `make test`.
- **CI has never run.** Its first run is the first push of this branch, which waits for the
  owner.
- **Upstream asks A1 to A8** (design §12) are drafts, not filed. A3 needs the server's side
  decided first. Not in the design yet: **publishing chez-http-server on the Akku index**,
  without which circuit can't be installed with Akku (ADR-0003).
- **A7's shape**, the fake shell as a supported library (design §16).
- **The overview** ([circuit-ringlike-http-layer.md](circuit-ringlike-http-layer.md)) still
  uses Racket syntax (`#"..."`, `#:keywords`) and names `chez-web`, `chez-router` and
  `chez-http1`. It stays as background; the design supersedes it where they differ.

## Close-outs

None yet.
