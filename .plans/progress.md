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
  - the Guix container (ADR-0002): `make check-guix` passes, 66 host-side checks and the
    self-test inside;
  - the Makefile and the test harness: `(circuit-testing)`, `check-suites`, `make test`
    under GNU timeout;
  - the import audit (`make check-imports`, ADR-0006) and the Linux CI workflow, each
    built by a Sonnet agent;
  - ADR-0002 to ADR-0006, this ledger, `global-constraints.md`, `CHANGELOG.md`, README;
  - **a read-only Opus review** (307,746 tokens, 28 minutes) found 15 problems. Fixed,
    each watched failing first:
    - `make test` runs `make check-imports` once `src/` exists; a bad library and an
      empty `src/` each stop it;
    - an impure library took the server's private libraries through a body `import`,
      which a bare `(chezscheme)` gives it: now it takes from `(chezscheme)` only
      `call/1cc`, through `only` (ADR-0006, amended). The reviewer's probe is refused,
      and three mutants of the new rule fail named rows;
    - a hung suite's children outlived `timeout --foreground`: off a terminal, timeout
      now kills the process group;
    - `check-suites` got a suite, `test-check-suites`, with ten fixtures; four mutants
      each fail it;
    - `make clean BUILD_DIR=..` reached chez-libuv's `rm -rf`: no command-line variable
      reaches chez-libuv's make now;
    - CI builds Chez from the sha256-pinned 10.4.1 tarball (`scripts/ci/build-chez.sh`,
      after chez-curl's), serially, and names `CHEZ` by its path;
    - inside the container, a target that needs git says to run it on the host;
    - a case-mismatched path (`circuit/Request.sls`), a surviving mutant's gap;
    - two citations in `global-constraints.md`, and the launcher test's copy skips
      `.claude/`.
- **Next: slice 2, spikes S1 and S2** (design §13): a port whose reads wait, which decides
  the request body's interface; and the cost of a coroutine for every request, which sets
  the gate on circuit's cost over the raw server.

## Open

- **CI has never run.** Its first run is the first push of this branch, which waits for the
  owner. It runs on amd64 alone, as the siblings' do; AGENTS.md asks for arm64 portability,
  and an `ubuntu-24.04-arm` runner would cover it.
- **The design's §11 fix lives on this branch**: it no longer calls the server an Akku
  dependency. The design branch, if merged first on its own, lacks it.
- **Left from the review, not fixed:**
  - outside the container and CI, nothing refuses a Chez below 10.4.1 or without threads:
    this host's own Chez is 10.4.0;
  - the Makefile's default `CHEZ` prefers `scheme` to `chez`, as chez-curl's does; on a
    Mac where another Scheme owns `scheme` it picks that one. Unverified;
  - two rows (`test-check-imports`'s and `test-check-suites`'s unreadable cases) hold
    Chez's exact read-error text, so a Chez that words it otherwise fails them;
  - the audit's rule (g) assumes `src` comes first on the library path.
- **Upstream asks** (design §12). Filed on chez-http-server on 2026-10-25, the owner's
  word, from the drafts in [upstream/](upstream/): A1 `request-header-list` as #214, A2
  the HTTP version in the facade as #215, A5 a producer with a declared length as #216,
  A6 a call when a response is done as #217. Held: A4 and A8 until spikes S1 and S2
  report, A3 until the server's side is decided, A7 until the adapter's tests are
  written. Not in the design yet: **publishing chez-http-server on the Akku index**,
  without which circuit can't be installed with Akku (ADR-0003).
- **A7's shape**, the fake shell as a supported library (design §16).
- **The overview** ([circuit-ringlike-http-layer.md](circuit-ringlike-http-layer.md)) still
  uses Racket syntax (`#"..."`, `#:keywords`) and names `chez-web`, `chez-router` and
  `chez-http1`. It stays as background; the design supersedes it where they differ.

## Close-outs

None yet.
