# Progress ledger

Where circuit stands. Read it with [global-constraints.md](global-constraints.md)
before starting slice work. When a slice merges, update **Now** and add a
close-out under **Close-outs**, newest first.

## Now

- **The design, slice 1 and slice 2 are merged**, squashed from
  [PR #1](https://github.com/Kiyomi-Computation-Systems/circuit/pull/1) on 2026-10-25;
  their close-out is below. The design is
  [2026-10-24-circuit-design.md](2026-10-24-circuit-design.md): its §15 records the
  owner's decisions, ADR-0004 to ADR-0006 take them up, and §16 holds what is open.
- **The revision to the server's v0.9.0 and the pin's move are merged**, squashed from
  [PR #2](https://github.com/Kiyomi-Computation-Systems/circuit/pull/2) on 2026-10-26
  (c057b03); its close-out is below. The pin is at v0.9.0 (d928e41), and the owner's
  answers since are design §15.7–§15.11.
- **Slice 3, the pure core, is in review** in
  [PR #3](https://github.com/Kiyomi-Computation-Systems/circuit/pull/3); its close-out
  is below.
- **Next: slice 4, the adapter** (design §17): `(circuit http-server)` on the pin at
  v0.9.0, sending every body kind but the upgrade through `res-body-stream`, port bodies
  sized and closed by `request-on-done!` through its `on-port`, ADR-0006's allowlist
  amended for `port-has-port-length?` and `port-length`, examples over loopback, and the
  gate's final numbers from the real adapter in a decision record (design §15.6): G2's
  POST re-measured, and G4's bound set off a record's size step.

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
- **Upstream asks** (design §12): all eight filed on 2026-10-25 and landed by
  2026-10-26, with the docs fix; see PR #2's close-out. **chez-http-server is submitted
  to the Akku index and awaits review** (the owner, 2026-10-25). Until it is published,
  circuit can't be installed with Akku, and the submodule stays its only way in
  (ADR-0003).
- **A clock for request logging** (slice 5; design §16.2): R6RS has none, and the facade
  exports none. The server's own clock, the one its waits use, is the one to read, so
  `(http-server testing)`'s clock would drive it in a test: likely an upstream ask, not a
  second Chez name.
- **G2 reads 9.5 KB against its proposed 3,072 B** (printed, not held): the pulled POST
  reads its body with `get-bytevector-all`, about 8.2 KB of Chez's (design §4, §15.6).
  Slice 4 re-measures the POST and sets G2's final bound.
- **G4's bound, 96 B, sits on a record's size step** (design §15.6): a six-field request
  record failed it by 1 B. Slice 4 should set it off a step.
- **A cap of circuit's own on the request body** (design §16.1): the revision has none,
  and the server's `CHEZ_HTTP_MAX_BODY_BYTES` is unbounded by default.
- **`res-wrap-body`'s shape awaits the owner** (design §16.4). Slice 3 builds it as
  provisional.
- **The server's `docs/waiting.md` lists `&body-failed`'s statuses as 413, 400 and 408**,
  leaving out 431, a chunked body's trailers past the header limits (design §12). Filed
  as [chez-http-server #241](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/241)
  on 2026-10-26, reproduced through `(http-server testing)` at v0.9.0, with a note that
  no server test hands a pull a header reason or `chunk-extensions-too-large`.
- **The overview** ([circuit-ringlike-http-layer.md](circuit-ringlike-http-layer.md)) still
  uses Racket syntax (`#"..."`, `#:keywords`) and names `chez-web`, `chez-router` and
  `chez-http1`. It stays as background; the design supersedes it where they differ.

## Close-outs

### 2026-10-26: slice 3, the pure core and the cost gate, in PR #3

Six commits on `slice/3-pure-core`: the ledger's close-out of PR #2 (edf8605), the core
and its suites (4e4d500), the audit's `#!r6rs` rule (13a8d5d), the gate (d4f38c9), the
design's records of what the slice settled and measured (6591e03), and this close-out.
Built, reviewed and fixed on 2026-10-26. CI passed on the PR (run 40371240814, 2m6s):
`make test` ran its 9 suites in 17 s, and the Cost gate step's first run fetched oha and
passed in 78 s, its held gates' worst figures within the local runs' or a few bytes past
them (G3 288 B a GET and 279 a POST, G4 81, G5 346 and 330 with a park; G1 1,425 and
G2 9,544, printed):

- **the core** (Opus 5.5; 297,770 tokens, 29 minutes): `(circuit)` and its five
  libraries, `(circuit test)`, and six suites, among them the names suite. `make test`
  passes 9 suites. 52 mutants were watched failing; the session reran 13 and a
  name clash of its own. What it settled is in design §3, §5, §10 and §11;
- **the gate** (Opus 5.5; 216,433 tokens, 23 minutes): `make oha`, `make gate`,
  `make gate-rps` and CI's "Cost gate" step, with a stand-in adapter and catch helper
  over the real core. The held gates pass, each watched failing (design §15.6). The
  session reran the gate and its G4 mutant;
- **a read-only Opus review** (Opus 5.5; 318,604 tokens, 20 minutes) found nine
  problems, each reproduced by the session, and the core's builder fixed them (Opus 5.5;
  15 minutes, 415,113 tokens over both of its rounds):
  - `res-body-stream` gave the adapter no point between measuring a port and a wrap's
    `f` to register its close: it now takes an `on-port`, called after `measure` and
    before any `f`, and a raise from either closes the port (design §9, §11);
  - `res-body->bytevector` read a port body to eof where the adapter sends it sized, so
    a counter wrap passed its test and failed in production: it now measures a port by
    reading ahead and setting it back, and, given the request, refuses the natural echo
    as the adapter does (design §11);
  - four weak tests, each with a surviving mutant: `on-done` through a `req-with-`
    copy, `req-headers`' own list, a binary output port as a body, an inexact port;
  - `make-test-req` read an absolute-form target and padded header values otherwise than
    the server: it now refuses a target not beginning with `/`, and trims values' spaces
    and tabs as the server does (design §10);
  - the import audit passed a `#!chezscheme` library using Chez's reader syntax: it now
    requires `#!r6rs` and no other `#!` (rule (h); ADR-0006, amended);
  - the records: a stale "not yet filed", the gate's "within about 5 B", and its ranges,
    now from four runs, with what the gate doesn't hold yet (design §15.6).

  `make test` passes 9 suites (46, 14, 45, 24, 9, 12, 47, 72, 41), `make gate` passes,
  and 73 mutants are watched failing; the session reran the review's mutants and probes;
- **traps, reproduced by the session:** in compiled library code an operand can run
  before the operator's check (AGENTS.md's order rule now says so); Chez asks a
  custom port's `read!` for 8 KiB at a time; and each `get-bytevector-all` or
  `get-bytevector-some` on a custom port allocates about 8.2 KB (design §4).

### 2026-10-26: the server's v0.9.0, the pin and the design's revision, in PR #2

Two commits, squashed as c057b03: the pin's move (65a24f1) and the design's revision
after two reviews (fce9dbf). CI passed on the PR's one push (run 40335116614,
2026-10-26, 59s): every pin ok at d928e41 and the pins it carries, and the three suites
with the container's counts, 39, 14 and 45. The docs note the revision left open was
filed after the merge, as chez-http-server #241.

- **Every upstream ask has landed** on chez-http-server's main, at 9195305 by
  2026-10-26, and the server tagged them as v0.9.0 that day (d928e41): A1 #219, A2
  #218, A3 #238, A4 #234–#237, A5 #221–#223, A6 #224–#226, A7 #239, A8 #232, and the
  docs fix #233. The design is revised to them (2026-10-26; design §12): the body is
  the server's pulled port on the thunk's one coroutine, with no reader and no interim;
  a sized body kind and port bodies sent with their length; `req-on-done!`; the
  connection's addresses; tests through `(http-server testing)`. The owner's answers
  are design §15.7–§15.9. ADR-0003, ADR-0004, ADR-0006 and `global-constraints.md` are
  amended to match.
- **The pin is at v0.9.0** (design §15.7), moved on 2026-10-26: the gitlink and
  `SERVER_PIN` name d928e41, the tag's commit, and every pin the server carries is
  unchanged from v0.8.0. `make check-pins` passes on the host, and `make test` in the
  container (39, 14 and 45 passes, as before). Both spikes' programs still expand
  against v0.9.0, though v0.9.0 drops `request-body`.
- **A read-only Opus review of the revision** (Opus 5.5; 300,047 tokens, 18 minutes)
  found two design flaws and a set of gaps, fixed on 2026-10-26. The session reproduced
  the traps first: `transcoded-port` closing its binary port, `/proc/self/status` and
  `/dev/zero` reporting length 0, the 431 path, and a sized body's mismatch reported
  `failed`. The fixes:
  - **a port under streaming middleware** leaked and lost its length:
    `res-body->producer` gave way to `res-wrap-body`, a lazy wrap the adapter runs
    (design §6, §14), whose shape awaits the owner (design §16.4);
  - **`req-body`'s one port** lives in a cell of the request's record, shared by its
    copies. It is read once, a transcode or close ending it for every reader, and only
    in its own request's handler call. The adapter refuses it as a response body
    (design §3, §4, §9);
  - **the rest:**
    - the view's defaults for `body` and `on-done`, and `test-req-done!`;
    - `&body-failed`'s 431;
    - the re-exports listed, without `next-body-piece` and `body-input-port`;
    - port bodies a regular file or a bytevector port;
    - the adapter measuring a port before it registers its close;
    - `failed`'s endings;
    - stale fake-shell text in ADR-0003, ADR-0006 and AGENTS.md, and design §6's "an
      empty 500".
- **A second read-only Opus review** (Opus 5.5; 212,128 tokens, 12 minutes) found that
  the first round's `res-wrap-body` had three holes, and found smaller gaps; fixed on
  2026-10-26. The session reproduced the traps first, on Chez 10.4.0 and 10.4.1:
  `get-bytevector-n` of 0 answering an empty bytevector even on a closed port;
  `file-regular?` passing procfs and sysfs files, one sysfs file reporting 4096 bytes and
  holding 23; a FIFO's `port-position` raising; and `(http-server awaiting)` exporting
  `make-body-failed`. The fixes:
  - a wrap that drops a length stops at it, and a port's producer answers eof at its
    length, never reading 0 bytes (design §5, §6);
  - `res-with-body` closes the old port at any depth, unless the new body holds it;
  - "has a length" is defined once, and an empty body reaches `f` as eof;
  - the refusal of `req-body` as a response body looks through sized bodies too;
  - `res-body->bytevector` reads as the adapter sends;
  - `test-req-done!`'s rules are stated;
  - the core's exports for the adapter and the tests are named (design §11);
  - `f` runs on the request's coroutine;
  - the owner's answers (2026-10-26; design §15.10 and §15.11): a view must supply
    `method`, `host`, `path` and `http-version`, and slice 3 builds `res-wrap-body` as
    provisional (design §16.4).

### 2026-10-25: the design, slice 1 and slice 2, in PR #1

One squashed PR carried all three, the spikes folded in before the merge. CI passed on
every push: the first run built Chez 10.4.1 and cached it, and later runs restored it in
under a minute.

- **Slice 2, spikes S1 and S2 (design §13)**, built on `spike/s1-s2` and folded into
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

    Design §2, §3, §4, §6, §11, §12, §13, §15 and §16 take it up;
  - **a read-only Opus review** of the spikes and the design's edits (323,209 tokens, 21
    minutes) found the edits' faults, fixed after: §4 gave the interim's whole reader a
    coroutine a piece, where the server hands it its body as one piece
    (`connection.sls:1475`); several of the design's figures came from a rerun not yet
    recorded, now in S2's Rerun section; the `docs/waiting.md` fix left out
    `with-exception-handler`'s cost when the code parks; A8 would save 64 B, the two
    lookups, not the judgement's whole 137–153 B (the 64 B rerun in isolation); §15.4's
    record of the owner's reasons had lost one, now restored with a note; §4 claimed
    reads S1 didn't raise inside, and §4 now asks circuit's `read!` to wait only when it
    holds nothing, which `get-bytevector-some`'s losing nothing needs; the gate's
    measurability notes (design §16). S2's `show` verdicts for the three coroutine-count
    cases check only the status, and its findings now say so.
- **The owner's decisions after the spikes:**
  - **The gate on circuit's cost over the raw server is set** (the owner, 2026-10-25;
    design §15.6). G3, G4 and G5 fail the build: circuit's own work over the server's
    `awaiting` path, one `req-set`, and the catch helper with the app waiting inside it
    and without. G1 and G2 are printed and re-baselined at each pin move; G6, requests a
    second, is a smoke that never fails CI. `make gate` runs it outside `make test`, with
    its counts fixed, and CI runs it as a step of its own; `make oha` fetches oha through
    the vendored `tests/fetch-oha.sh`. The numbers are the prototype's, provisional until
    slice 4 measures the real adapter and records them in a decision record.
  - **ADR-0006 and ADR-0004 amended after S2** (the owner, 2026-10-25). The audit's one
    name from `(chezscheme)` is `getenv`, which the adapter's default environment needs,
    as `serve`'s does, not `call/1cc`, which nothing needs now. `make check-imports`
    refuses `call/1cc`: the impure-chezscheme fixture's new row was watched failing before
    the allowlist changed, and a mutant that keeps `call/1cc` beside `getenv` fails it.
    ADR-0004 counts three coroutines for a body the interim reads whole, and two for an
    empty one.
  - **The catch helper stays in `(circuit middleware waits)`** (the owner, 2026-10-25;
    design §15.4): its correctness rests on the server's `client-closed?` and
    `deadline-passed?`, so it lives beside `wrap-timeout` in the library that imports the
    server. A generic catch in the core was weighed and set aside.
- **Slice 1, scaffolding (design §17)**, built on `chore/scaffolding`, stacked on the
  design branch:
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
      `call/1cc`, through `only` (ADR-0006, amended; `getenv` since slice 2). The
      reviewer's probe is refused, and three mutants of the new rule fail named rows;
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
- **The design** ([2026-10-24-circuit-design.md](2026-10-24-circuit-design.md)), written
  on `design/circuit-on-coroutines` and revised with the owner: Ring's contract on the
  server's coroutines, every request on one, the `req`/`res` names, unique keys, and
  eight upstream asks, all now filed.
