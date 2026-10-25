# Progress ledger

Where circuit stands. Read it with [global-constraints.md](global-constraints.md)
before starting slice work. When a slice merges, update **Now** and add a
close-out under **Close-outs**, newest first.

## Now

- **The design** is [2026-10-24-circuit-design.md](2026-10-24-circuit-design.md). Its §15
  records the owner's decisions; ADR-0004 to ADR-0006 take them up.
- **Slice 1, scaffolding (design §17), on `chore/scaffolding`**, stacked on the design
  branch. Both are in [PR #1](https://github.com/Kiyomi-Computation-Systems/circuit/pull/1),
  not yet merged:
  - AGENTS.md describes circuit; ADR-0001 (no Windows);
  - the server pinned at v0.8.0 under `vendor/` (ADR-0003), with `make submodules` and
    `make check-pins` on the host;
  - the Guix container (ADR-0002): `make check-guix` passes, 66 host-side checks and the
    self-test inside;
  - the Makefile and the test harness: `(circuit-testing)`, `check-suites`, `make test`
    under GNU timeout;
  - the import audit (`make check-imports`, ADR-0006) and the Linux CI workflow, each
    built by a Sonnet agent;
  - **CI's first run, on PR #1, passed** (run 40231893692, 2026-10-25, 6m1s). It built
    Chez 10.4.1 from the pinned tarball in 5m29s and saved it to the cache (3.29 MiB, keyed
    on `scripts/ci/build-chez.sh`), so later runs skip the build. The three suites passed
    with the container's counts: check-imports 39, check-suites 14, circuit-testing 45;
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
- **Slice 2, spikes S1 and S2 (design §13), on `spike/s1-s2`**, stacked on
  `chore/scaffolding`. Each ran as an Opus agent. The session reran each one, checked its
  claims against the code and the server's records, and took both into the design:
  - **S1, a port that waits** ([findings](research/s1-a-port-that-waits.md); 278,281
    tokens, 27 minutes): **the request body is a port.** A custom port's `read!` parks
    soundly under the real server, and Chez 10.4.1 holds nothing across the park. A raise
    loses what a gathering read had collected, and `get-bytevector-some` loses nothing; a
    text port loses data even through `get-string-some`; a park runs every
    `dynamic-wind`'s after thunk. Design §2, §4, §6, §12's A4 row, §13 and §14 take it up;
  - **S2, the cost of a coroutine for every request**
    ([findings](research/s2-coroutine-cost.md); 267,024 tokens, 30 minutes):
    - a GET through an adapter-shaped prototype costs raw + 1,324–1,440 B a request, the
      coroutine 1,036–1,154 B of it, and answers 93–95% of raw's requests a second at 50
      connections, on a quiet rerun;
    - a POST read whole costs raw + 2,863–2,951 B, for three coroutines, not two;
    - the catch helper escapes by `call/cc`, not `call/1cc`, which costs 3.4–4.3 KB on a
      coroutine once a park or Chez's `error` falls inside it;
    - decision 0025's `guard` figure stands, and the server's `docs/waiting.md`'s is
      stale.

    Design §2, §3, §4, §6, §11, §12, §13, §15 and §16 take it up.
- **Next: slice 3, the pure core** (design §17), once the owner has ruled on the gate
  (design §16) and on ADR-0006's `call/1cc` (below).

## Open

- **CI runs on amd64 alone**, as the siblings' do. AGENTS.md asks for arm64 portability,
  and an `ubuntu-24.04-arm` runner would cover it.
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
  A6 a call when a response is done as #217. **A4 and A8 are drafted, not filed**:
  [a4-read-the-body-by-waiting.md](upstream/a4-read-the-body-by-waiting.md) carries S1's
  guarantees for a port over the verb (a fresh piece, a sticky eof, a sticky close, a
  raise only before taking a piece), and
  [a8-request-has-body.md](upstream/a8-request-has-body.md) S2's cost, 143–149 B a
  request, and a probe: the server keeps `Content-Length: 00` alive as no body, which a
  copy of its rule that tests for `"0"` takes for one. Held: A3 until the server's
  side is decided, A7 until the adapter's tests are written. Besides the asks, two fixes
  to the server's `docs/waiting.md` (design §12): its stale `guard` figure, and a park's
  running every `dynamic-wind`. Not in the design yet: **publishing chez-http-server on
  the Akku index**, without which circuit can't be installed with Akku (ADR-0003).
- **The gate on circuit's cost over the raw server** (design §16): S2 proposes G1–G6.
  The owner decides.
- **ADR-0006 allows `(only (chezscheme) call/1cc)`, and nothing needs it now.** S2 moved
  the catch helper to `call/cc`, which is plain R6RS. The allowance, its line in
  `global-constraints.md`, `tests/check-imports.sps`'s `chez-names` and its rows could
  go, leaving the impure libraries nothing from `(chezscheme)`. The owner decides.
- **ADR-0004 says a request with a body pays for two coroutines.** S2 counts three for a
  body in one piece, and one more for each further piece (design §4).
- **A7's shape**, the fake shell as a supported library (design §16).
- **The overview** ([circuit-ringlike-http-layer.md](circuit-ringlike-http-layer.md)) still
  uses Racket syntax (`#"..."`, `#:keywords`) and names `chez-web`, `chez-router` and
  `chez-http1`. It stays as background; the design supersedes it where they differ.

## Close-outs

None yet.
