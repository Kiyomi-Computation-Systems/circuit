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
- **Slice 3, the pure core and the cost gate, is merged**, squashed from
  [PR #3](https://github.com/Kiyomi-Computation-Systems/circuit/pull/3) on 2026-10-26
  (9720d90); its close-out is below.
- **Slice 4, the adapter, is merged**, squashed from
  [PR #4](https://github.com/Kiyomi-Computation-Systems/circuit/pull/4) on 2026-10-26;
  its close-out is below. The owner's answers in it are design §15.12 and ADR-0007.
- **Slice 5, `(circuit middleware waits)`, is merged**, squashed from
  [PR #5](https://github.com/Kiyomi-Computation-Systems/circuit/pull/5) on 2026-10-27;
  its close-out is below. The owner's answers before and in it are design §15.13–§15.15.
- **Slice 6 is designed** in [2026-10-27-slice-6-design.md](2026-10-27-slice-6-design.md),
  approved by the owner on 2026-10-27 (design §15.16): 6a upgrades, 6b the router, a
  host-neutral handshake released in chez-websocket, then 6c WebSocket.
- **Slice 6a, upgrades, is merged**, squashed from
  [PR #6](https://github.com/Kiyomi-Computation-Systems/circuit/pull/6) on 2026-10-27;
  its close-out is below. The owner's answers in it are design §15.17–§15.19.
- **Slice 6b, `(circuit router)`, is merged**, squashed from
  [PR #7](https://github.com/Kiyomi-Computation-Systems/circuit/pull/7) on 2026-10-27;
  its close-out is below. The owner's answers in it are design §15.20–§15.24.
- **The handshake in chez-websocket is released**: `websocket-handshake` in v0.3.0, and
  `websocket-limits-from-environment` in its facade in v0.4.0, each closed out in its own
  ledger.
- **Slice 6c, `(circuit websocket)`, is merged**, squashed from
  [PR #8](https://github.com/Kiyomi-Computation-Systems/circuit/pull/8) on 2026-10-28;
  its close-out is below. chez-websocket is pinned at v0.4.0 (4456814). The owner's
  answers in it are the slice 6 design §7.5–§7.6. Slice 6 is done.
- **Slice 7, a request's own cap on its body, is merged**, squashed from
  [PR #9](https://github.com/Kiyomi-Computation-Systems/circuit/pull/9) on 2026-10-28;
  its close-out is below. The owner's answer is design §15.25, which settles §16.1.
- **Slice 8, `res-wrap-body` split into a wrap and a tap, is merged**, squashed from
  [PR #10](https://github.com/Kiyomi-Computation-Systems/circuit/pull/10) on
  2026-10-29; its close-out is below. The owner's answer is design §15.26, which
  settles §16.4. No API question in §16 awaits the owner now.
- **Two testing rules are in AGENTS.md**, from slices 7 and 8, squashed from
  [PR #11](https://github.com/Kiyomi-Computation-Systems/circuit/pull/11) on 2026-10-29;
  its close-out is below.
- **The pins are at the server's v0.9.1 and chez-websocket's v0.4.1**, squashed from
  [PR #12](https://github.com/Kiyomi-Computation-Systems/circuit/pull/12) on 2026-10-29;
  its close-out is below. The server's fixes for #241, #243 and #245 reach circuit.
- **CI runs on arm64 as well as amd64**, squashed from
  [PR #13](https://github.com/Kiyomi-Computation-Systems/circuit/pull/13) on 2026-10-29;
  its close-out is below. It holds the cost gate on both.
- **v0.1.0, the first release, is merged**, squashed from
  [PR #14](https://github.com/Kiyomi-Computation-Systems/circuit/pull/14) on 2026-10-29;
  its close-out is below. main's CI on its squash, 0ae889b, failed a timing row, so the
  tag waits for that row's fix.
- **The timing row's fix is merged**, squashed from
  [PR #15](https://github.com/Kiyomi-Computation-Systems/circuit/pull/15) on 2026-10-29;
  its close-out is below.
- **v0.1.0 is tagged and released** on bf38a4b, #15's squash, recorded in
  [PR #16](https://github.com/Kiyomi-Computation-Systems/circuit/pull/16) on 2026-10-29;
  its close-out is below.
- **A docs site renders `docs/`**, squashed from
  [PR #17](https://github.com/Kiyomi-Computation-Systems/circuit/pull/17) on 2026-10-30;
  its close-out is below. Its first pages are Home, Installing and Quickstart.
- **The docs' pages and an API reference held to the code are merged**, squashed from
  [PR #18](https://github.com/Kiyomi-Computation-Systems/circuit/pull/18) on 2026-10-30;
  its close-out is below. README.org points to `docs/`.
- **v0.1.1, the docs, is merged**, squashed from
  [PR #19](https://github.com/Kiyomi-Computation-Systems/circuit/pull/19) on 2026-10-30;
  its close-out is below. GitHub Pages is on, its source GitHub Actions, and its
  `github-pages` environment takes `main` and `v*` tags, as the server's does.
- **v0.1.1 is tagged and released** on 55ca6df, #19's squash, and its site is live at
  [kiyomi-computation-systems.github.io/circuit](https://kiyomi-computation-systems.github.io/circuit/),
  recorded in [PR #20](https://github.com/Kiyomi-Computation-Systems/circuit/pull/20) on
  2026-10-30; its close-out is below.
- **The pins are at the server's v0.10.0 and chez-websocket's v0.5.1**, squashed from
  [PR #22](https://github.com/Kiyomi-Computation-Systems/circuit/pull/22) on 2026-10-30;
  its close-out is below. The server logs a request it refuses itself, and every log line,
  `wrap-catch`'s default line among them, stays one line with a record inside it short:
  the server's #249, #250 and #251, and chez-websocket's #105 and #106, filed from here.
- **The property suite's case starts are mixed and its `g-int` uniform**, squashed from
  [PR #23](https://github.com/Kiyomi-Computation-Systems/circuit/pull/23) on 2026-10-30,
  which closes the owner's #21; its close-out is below.
- **v0.1.2, the pins at the server's v0.10.0 and chez-websocket's v0.5.1, is merged**,
  squashed from [PR #24](https://github.com/Kiyomi-Computation-Systems/circuit/pull/24)
  on 2026-10-30; its close-out is below.
- **v0.1.2 is tagged and released** on 12f5944, #24's squash, and its site is live,
  recorded in [PR #25](https://github.com/Kiyomi-Computation-Systems/circuit/pull/25) on
  2026-10-30; its close-out is below.
- **`wrap-catch-with`, `wrap-log-with` and the client's address in `wrap-log`'s line are
  merged**, squashed from [PR #26](https://github.com/Kiyomi-Computation-Systems/circuit/pull/26)
  on 2026-10-30; its close-out is below. The owner's answers are design §15.27.
- **The router's own 400 and 405 handlers, and a 400 for a raw character a path can't
  hold, are merged**, squashed from
  [PR #27](https://github.com/Kiyomi-Computation-Systems/circuit/pull/27) on 2026-10-31;
  its close-out is below. The owner's answers are design §15.28.
- **Next:** the design plans no slice past 8 (§17). The owner chose to work through the
  Open list below. One more PR is under way: the list's housekeeping.

## Open

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
  to the Akku index and awaits review**: the owner submitted 0.8.0 on 2026-10-24, then
  0.9.0 and 0.9.1 (0.10.0, of 2026-10-30, is the latest). On 2026-10-29 the index, last
  rebuilt on 2026-10-25, listed no version of it, and its four dependencies at the
  versions it needs. Until it is published,
  circuit can't be installed with Akku, and the submodule stays its only way in
  (ADR-0003).
- **A wrap's `f` can meet a closed port in the test host** once the client has gone while
  the app waited (design §6, §9), and the test host drops `f`'s raise. Over a real socket,
  a FIN is heard at once, but the request stays open until its response is written: `f`
  reads its port, and the write fails, logged `read-error EPIPE` (slice 5, reproduced).
  Whether a reset makes `f` meet a closed port is unverified: curl can't send one.
- **Unverified off Linux:** the adapter suite's FIFO row opens a FIFO read-write, which
  POSIX leaves undefined; it works on Linux. CI runs Linux alone.
- **Left from the owner's `/code-review` of slice 4, not fixed:**
  - a procfs file such as `/proc/self/status` reports a length of 0, so it is measured at
    0 and goes out empty (design §5 says to read such a file whole yourself). Taking a
    measured 0 as unknown would stream it, at the cost of an empty file's
    `Content-Length: 0`;
  - `res-body->bytevector` reads a port whole at 64 KiB whatever the app's
    `CIRCUIT_PORT_PIECE_BYTES`, so for a smaller setting a file that shrinks after it is
    measured passes its test and ends short in production;
  - `examples/long-poll.sps` may wake a waiter whose deadline fired in the same instant,
    answering "woke 1" and logging `late-resume`, as the server's example would.
    Unverified.
- **CI's curl can't drive a WebSocket:** ubuntu-24.04's curl, 8.5.0, is built without it
  (curl has it by default from 8.11), so the examples suite's curl echo row is skipped in
  CI and runs only in the container, on curl 8.20. The `/dev/tcp` rows prove the echo in
  both (slice 6c).
- **No test runs the docs' code.** Every program on the pages was run by hand for PR #18,
  and shows what it printed; the owner chose a reference check over running the blocks
  (2026-10-30). A change to the code can leave a page's program, or its output, wrong
  until someone reruns it, and `tests/test-reference.sps` checks names, signatures and
  links, not an entry's prose.
- **`req-remote-address` costs about 50 B a call on a real connection:** the server's
  `request-remote-address` copies its string each time (its `view.sls:133`). So
  `wrap-log`'s own share, G8 own, reads 340 B from about 290 since PR #26, under its 384 B
  bound.
- **`(site slug)` isn't GitHub's:** `slugify` drops `_`, merges runs of spaces and hyphens,
  and trims hyphens, where GitHub keeps `_` and makes each space a hyphen. Checked against
  GitHub's own anchors: `uv_eof` against `uveof`, `012---2026-10-30` against
  `012-2026-10-30`. `check-site` holds each heading to its own `github-slug`, which states
  GitHub's rule, and refuses one where the two differ: no link breaks, but a page can't
  have such a heading. Filed as
  [chez-http-server#255](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/255):
  the generator is the server's, and circuit's and chez-websocket's are copies.
- **A re-export's own comment is unchecked:** `(circuit http-server)` says
  `awaiting : (-> Any) -> Awaiting`, the server's reference `(-> Answer) -> Awaiting`.
  The reference gives re-exports no signature, so `tests/test-reference.sps` holds neither.
- **Nothing prints the library path but `make run`,** which echoes its command line: the
  docs say to run that, from the checkout, to start a program without make. A target
  that prints it, or a deploying page, would serve a service or a container better.
- **Chez 10.4.1's cp0 miscompiles multiple values returned through a closure a procedure
  returns** (slice 6b, reproduced; its close-out has the repro). Circuit's libraries
  return values only from direct calls. Not filed: the owner chose not to, on 2026-10-30.
- **The overview** ([circuit-ringlike-http-layer.md](circuit-ringlike-http-layer.md)) still
  uses Racket syntax (`#"..."`, `#:keywords`) and names `chez-web`, `chez-router` and
  `chez-http1`. It stays as background; the design supersedes it where they differ.

## Close-outs

### 2026-10-31: the router's own 400 and 405, and a 400 for a raw character, in PR #27

On the owner's "start the open list items": of the Open list's router items they chose
both changes, and option entries over positional handlers or none (design §15.28). The
entries offered were `not-found`, `bad-request` and `method-not-allowed`; I renamed them
`on-…` before building, since Chez refuses a program that defines a name it imports
("multiple definitions for not-found in body", probed) and routing's page and
`test-router` define two of them, and told the owner. Commits on `open/router-handlers`:
the code, tests and docs (bbdc0f8), their records (8753384), the review's fixes (70da6e6)
and theirs (558a1f7), main with #26 merged in (65d4899), this close-out, and its CI run
named here. `make test` passes 16 suites, and `make check-site` passes.

- **the options:** `make-router` takes `(on-not-found h)`, `h` bare, `(on-bad-request h)`
  and `(on-method-not-allowed h)` after its table, in any order, refusing two for one
  answer, anything else, and a constructor given bare, before any middleware is applied.
  The 400 handler gets the request as it came to the router; the 405 handler gets the
  route's match, one `req-set` on that path alone. When it answers a 405, the router sets
  `allow` on it, replacing any the handler set; any other answer goes on untouched;
- **the raw-character rule:** a capture holding a raw ASCII character outside pchar, `/`
  aside in a catch-all, is the 400; the builder added `?`, which the brief's list left
  out and RFC 3986 refuses. The server, probed at v0.10.0 with all 128 bytes in GET and
  POST, origin-form and absolute-form, lets exactly pchar and `/` reach a handler; a raw
  `|` in an origin-form GET gets a 301 to `%7C`. A mount's rest stays unchecked;
- **the rows:** 24 new in `test-router`, each watched failing under a mutant of its own,
  28 router mutants in all; the property suite models the options, its option handlers
  drawn as leaves, wrapped handlers and routers, its 405 handlers answering 405, 404 or
  200, a third with an `Allow` of their own. It passes at the default seed and five more;
- **the gate:** G10's word, parameter and miss rows read 82–84, 163–165 and 2–6 B, before
  and after; `test-router` holds a router with all three options to the bytes of one
  without, at a word, a parameter, a catch-all and a mount;
- **the review**, read-only on Opus, of #27 and #28 together, found three things in #27,
  each fixed and its row watched failing: `allow` set on any status, so a 404 that hid a
  route carried `allow: POST` where an unknown path's 404 had none (my brief's rule); a
  bare `on-bad-request` taken as the not-found handler, so every unknown path raised; and
  option handlers drawn only as leaves. Left as documented: a 405 handler runs outside
  its route's group middleware and sees the match, as the default 405 always did;
- **traps, from the builder:** a relative cost row can't see a cost both sides pay, so
  the absolute 88 B row stays; `make-test-req` splits a target at its first `?`, so the
  raw-`?` rows set the path with `req-with-path`;
- **agents:** the builder, Opus, 372,978 tokens and 25.4 min, then 72,710 and 10.8 min for
  the review's fixes; the reviewer, Opus, 268,829 tokens and 19.8 min, for #27 and #28.

### 2026-10-30: `wrap-catch-with`, `wrap-log-with` and the client's address, in PR #26

On the owner's "start the open list items": they chose, among the options offered, the
makers over a breaking change or none, and the address at the end of the line, as the
server's `request-refused` line has it, over first, as the Common Log Format has it
(design §15.27). Commits on `open/waits-makers`: the code, tests and docs (4dae195), this
close-out (3ec4245), and its CI run named here. `make test` passes 16 suites, and `make
check-site` passes. CI passed on the PR (run 41152317541, 3m43s), on amd64, arm64 and the
site job.

- **the makers:** `(wrap-catch-with on-raise)` and `(wrap-log-with clock)` each check
  their setting when called, and the handler, with their own name as the who, when
  applied. The catch and the log they make are `make-catch`'s and `make-log`'s, as
  `wrap-catch`'s and `wrap-log`'s are. Middleware's page shows
  `(wrap app (wrap-catch-with on-raise))` where it showed a lambda;
- **the address:** `wrap-log`'s line ends with `req-remote-address`, or `-` for `#f` or
  `""`. The method, the path and the address are each written a character at a time, a
  control character as a space (the server's #250 rule): a middleware can take the address
  from a client's header, and before this, `req-with-path` could already break the line.
  The log reads the request it was handed, so a middleware that sets the address goes after
  it, and the page says so;
- **the rows first:** the suite failed to load on the old code, then passed 80 rows.
  Twelve mutants each failed their own rows: a maker that drops its `on-raise`, its clock
  or its early check, or names `wrap-catch` as the who; no address; `""` printed empty;
  the method, the path or the address written raw; DEL kept; line feeds alone made
  spaces. The every-character row holds the rule at all 128 ASCII characters, U+0085 and
  U+00E9, in each of the three fields;
- **the examples suite's 504 row** now times the wait by curl's own clock,
  `time_starttransfer` less `time_pretransfer`, at 998 ms or more, the log row's floor.
  Its old clock started before curl was spawned, so it passed with the example's timeout
  at 990 ms (PR #15's mutant). That mutant now fails it: curl waited 994.6 ms;
- **the gate passes.** G5 reads 380–388 and 333–335 with a park, as before. G8 own reads
  340, from about 290. Two mutants of the gate's run split it: reading the address and
  printing `-` reads 340, not reading it 288, so the copy in the server's
  `request-remote-address` is the whole rise (Open);
- **the docs:** every program whose output changed was rerun in the container over
  loopback, and the pages show what it printed: Middleware's four, Quickstart's middleware
  program, and Testing's `wrap-log` line, `-` for a test request;
- **the slug item, corrected:** the Open list said `check-site`'s GitHub-anchor invariant
  used the same `slugify`, so it couldn't catch a heading where they differ. It has its
  own `github-slug`, and a heading `## a_b` fails `make check-site` (probed). Filed as
  chez-http-server#255, with three anchors read from GitHub's own pages;
- **no agents ran for this PR.** The router and the housekeeping went to two Opus agents
  in worktrees, for PRs of their own.

### 2026-10-30: v0.1.2 tagged, released and published, recorded in PR #25

On the owner's "Ritual, then the whole chain" for v0.1.2. This PR holds this close-out
alone; CI passed on it (run 41126419813).

- **CI on the tagged commit:** main's run on 12f5944, #24's squash, 41125275154, passed on
  amd64, arm64 and the site job, every job completed;
- **the tag:** `v0.1.2` (tag object 5770fab) on 12f5944, annotated and signed with the
  Kiyomi release key (`git tag -v`: a good signature), pushed alone. Its message:
  "circuit v0.1.2 — the server's v0.10.0 and chez-websocket's v0.5.1", then a paragraph
  from `[0.1.2]`'s intro;
- **the site:** the tag's push ran the Pages workflow (41125981606): its build in 23s and
  its deploy in 11s. Live, each of the 12 pages answers 200; links to circuit's files
  name `blob/v0.1.2/` (11), to the server's `blob/v0.10.0/` (31) and to chez-websocket's
  `blob/v0.5.1/` (3); the home page says v0.1.2, Installing clones `--branch v0.1.2`, and
  Middleware shows `request-refused 400 invalid-host 127.0.0.1`;
- **the GitHub Release:** that title, from the tag with `--verify-tag`, not a draft or a
  prerelease, and the repository's latest (`releases/latest` answers v0.1.2). Its notes
  are `[0.1.2]` as the tag holds it, intro to last bullet, 1,799 bytes, and the published
  body is those notes, byte for byte. The recipe first rebuilt v0.1.1's published notes,
  1,472 bytes, byte for byte;
- **a fresh clone of the tag**, as Installing says: `git clone --branch v0.1.2` from
  GitHub (HEAD 12f5944), `make submodules`, `make check-pins`, `make site-deps`, and in its
  own Guix container `make test`, 16 suites, `make check-site` and `make check-help`;
- **GitHub's source tarball** for the tag: 320 entries, `vendor/`'s two directories
  empty, neither `.plans/` nor `AGENTS.md`, the 12 docs pages and the generator in it,
  and `Akku.manifest` naming 0.1.2;
- **no agents ran.**

### 2026-10-30: v0.1.2, the pins at the server's v0.10.0 and chez-websocket's v0.5.1, in PR #24

On the owner's "lets do v0.1.2". Commits on `release/v0.1.2`: the release (30f938e), this
close-out, and its CI run named here.

- **`[0.1.2]`:** Unreleased's pin move and `wrap-catch`'s fix, under an intro: "The third
  release, a patch". The pin entry names what the server carries plainly: the same
  chez-libuv, chez-httparse and uriparse as v0.9.1. The links gain `[0.1.2]`, and
  Unreleased compares from v0.1.2;
- **the version:** 0.1.2 in `Akku.manifest`; README.org's status, the home page's and
  Installing's clone of the tag name v0.1.2;
- **a patch:** since v0.1.1, `src/` changed only in `(circuit middleware waits)`'s
  imports and its default line's code, and no export line (`git diff v0.1.1 -- src`);
  `examples/` is unchanged. The siblings went minor for the same server change because
  their test hosts' logs are their API; circuit's testing page uses the server's test host
  but never its log;
- `make test` passes 16 suites, `make check-site` twelve pages, and `make check-pins` on
  the host. CI passed on the PR (run 41123854479): amd64 in 2m03s, arm64 in 3m54s, and
  the site job in 23s;
- **no agents ran.**

### 2026-10-30: the property suite's case starts mixed and `g-int` uniform, in PR #23

On the owner's "tackle issue 21": their
[#21](https://github.com/Kiyomi-Computation-Systems/circuit/issues/21), found porting
`tests/test-router-properties.sps`'s generators to jsonparse, with jsonparse's fix.
Commits on `fix/property-generators-21`: the generators and two rows (c3749ff), this
close-out (f83960e), and its CI run named here. `make test` passes 16 suites; the
property suite's 31 rows run in 5 s, as before. CI passed on the PR (run 41120484328,
4m17s), on amd64, arm64 and the site job.

- **the rows first**, each held from both sides, and watched failing on the old code:
  - neighbouring cases start apart: of each property's first 4,000 cases, 10 to 90 of the
    3,999 neighbouring pairs draw the same first `(g-int 100)`. The affine `case-state`
    gave 1,294–1,300 for P1–P7 at the default seed, as #21 measured; chance is about 40;
  - `g-int` is uniform: of 32,768 draws of `(g-int 20000)` from one fixed state, 20,316 to
    21,627 (62–66%) fall below 12,768. The 15 bits taken modulo n gave 25,565 (78.0%);
- **the fix**, #21's: `case-state` mixes the seed, the property and the index by
  murmur3's 32-bit finalizer, `mix`, giving 25–54 neighbours alike; `g-int` draws again
  while the bits are at or above the largest multiple of n not above 32,768, giving 20,972
  (64.0%). Each row is driven by its own half alone: the new `case-state` with the old
  `g-int` gives 25–53, the old with the new 1,291–1,297. Two mutants of the new code, the
  outer `mix` dropped and the redraw dropped, each fail their row alone;
- **the new cases:** every fixed seed's cases changed. No row holds a recorded case or a
  tally, so none needed regenerating. P1–P7 find nothing at the default seed, at seeds
  1, 7, 42, 99999, 20261030, 123456789, 2^31 − 1 and 2^40, and at 1 and 31337 with ten
  times the cases. `mix` keeps a seed's low 32 bits, so seeds 2^32 apart give the same
  cases, as the old start did 2^31 apart;
- **no agents ran.** No review: the change is #21's own code, measured, and its rows
  were watched failing both ways.

### 2026-10-30: the pins at the server's v0.10.0 and chez-websocket's v0.5.1, in PR #22

On the owner's "circuit can pin chez-websocket v0.5.1 together with chez-http-server
v0.10.0 in one commit". Before it, three log items from this ledger's Open list went to
the server as Kiyomi-Computation-Systems/chez-http-server#249 (a line feed in a raised
value breaks the line), #250 (a record inside a condition logged whole: 781 characters
for the server's own late-pull raise) and #251 (a refusal logged nowhere), each
reproduced at v0.9.1 over loopback; the server's session fixed them in #252 and #253 and
released v0.10.0 (5c16f64). chez-websocket's v0.5.0 pinned it but kept its own copy of the
log code, which still broke on a line feed and wrote a raise naming the `websocket` record
in 1,169 characters (reproduced); its row against the server's `log-line` passed because
none of its raises was one v0.10.0 changed (reproduced: with them added it fails on
v0.10.0). That went to chez-websocket as #105 and #106, fixed in its #107 and released as
v0.5.1 (4b70f22), whose server gitlink is 5c16f64. Commits on
`pins/server-0.10.0-websocket-0.5.1`: the pins, the code, the rows and the docs (1fb2436),
the records with this close-out (79bde28), and its CI run named here. `make test` passes
16 suites, 954 rows;
`make check-site` and `make gate` pass, and `make check-pins` on the host. The gate's
worst figures: G1 1,442, G2 1,437, G3 306 a GET and 277 a POST, G4 81 and 406, G5 385 and
350 with a park, G7 308, G8 533, G8 own 293, G8 on-done 248, G9 606 and 596 with a park,
G10 87, 165 and 4: none moved from v0.9.1's. CI passed on the PR (run 41115454175,
4m02s), on amd64 and arm64: 16 suites, 953 rows and the curl row skipped, beside the
site's 78; the gate's worst figures, amd64 then arm64, G3 307 and 275, 307 and 273, G4 81
and 403, 80 and 400, G5 382 and 338, 380 and 340, G7 308 and 304, G8 532 on both, G8 own
292 on both, G8 on-done 243 and 240, G9 609 and 593, 609 and 604, G10 83, 164 and 0, 84,
164 and 3.

- **the trial first:** circuit's `main` on the new server, before any change, failed 3 of
  16 suites, and only where expected: the adapter suite's five rows on a body past a cap,
  the `wrap-catch` row that compares its line with the server's, and the reference's
  links and `SERVER_PIN` comment at the old tags;
- **the pins**, on one commit: both gitlinks with `SERVER_PIN` and `WEBSOCKET_PIN`, and the
  docs' links into both repositories, which `tests/test-reference.sps` holds at the tags;
- **`wrap-catch`'s default line** copies the server's new `put-detail`: every control
  character a space (below U+0020, and delete), and a record inside a condition, list or
  vector shown as `#<record of type point>` under `print-record` #f. The comparison row's
  raises gain what v0.10.0 changed, the lesson of chez-websocket's row; three exact rows
  hold the new rule. Watched: the old copy, records printed whole, line feeds alone made
  spaces, and delete kept each fail an exact row and the comparison row;
- **the allowlist** takes `print-record` and `parameterize`, which R6RS lacks: ADR-0006
  amended, the global constraints and the design's §6 passage with it. The owner was told
  of `print-record` before the pin; `parameterize` came with it, as `(rnrs)` exports none
  (probed). The owner accepted both on this PR, over setting and restoring `print-record`
  by `dynamic-wind`, which would take one name but no longer be the server's code. The audit's suite was watched
  failing first (5 rows), then passing (57); its fixtures take both names, bare and under
  `prefix` and `rename`, and refuse `print-graph`, `print-level` and `fluid-let` beside
  them;
- **the rows:** the adapter suite's five rows on a body past a cap, which PR #12 moved to
  an empty log, now expect the test host's `(request-refused 413 body-too-large "-")`;
- **the docs:** Middleware and Bodies say the server logs a refusal itself, with the line;
  Installing names the new tags. The CHANGELOG's `[Unreleased]` has the pins and the fix.
  Open loses the three log items and gains `wrap-log`'s missing address and the owner's
  #21, which PR #23 then closed;
- **no agents ran.** No review: the change copies the server's reviewed code, and each
  row it moved was watched failing.

### 2026-10-30: v0.1.1 tagged, released and published, recorded in PR #20

On the owner's "Run the whole chain" for v0.1.1. This PR holds this close-out alone; CI
passed on it (run 41057528711).

- **CI on the tagged commit:** main's run on 55ca6df, #19's squash, 41056456599, passed on
  amd64, arm64 and the site job;
- **the tag:** `v0.1.1` (tag object 4b579a4) on 55ca6df, annotated and signed with the
  Kiyomi release key (`git tag -v`: a good signature), checked absent locally and on
  origin first, then pushed alone. Its message: "circuit v0.1.1 — the docs", then a
  paragraph from `[0.1.1]`'s intro;
- **the site:** the tag's push ran the Pages workflow (41057052851): its build gated the
  site and wrote 12 pages with `SITE_REF=v0.1.1` in 27s, and its deploy took 9s. Live,
  each of the 12 pages and the stylesheet answers 200, links to repository files name
  `blob/v0.1.1/`, and Installing clones `--branch v0.1.1`;
- **the GitHub Release:** that title, from the tag with `--verify-tag`, not a draft or a
  prerelease, and the repository's latest. Its notes are `[0.1.1]` as the tag holds it,
  intro to last bullet, and the published body is those notes, byte for byte. The recipe
  first rebuilt v0.1.0's published notes from its tag, byte for byte: a first try ended
  the section at any line opening with `[`, which v0.1.0's intro has, and was fixed to
  end at the link definitions;
- **a fresh clone of the tag**, as Installing says: `git clone --branch v0.1.1` from
  GitHub (HEAD 55ca6df), `make submodules`, `make check-pins`, `make site-deps`, and in its
  own Guix container `make test`, 16 suites, `make check-site` and `make check-help`;
- **GitHub's source tarball** for the tag: 320 entries, `vendor/`'s two directories
  empty, neither `.plans/` nor `AGENTS.md`, the docs and the generator in it;
- **no agents ran.**

### 2026-10-30: v0.1.1, the docs, in PR #19

On the owner's "Run the whole chain" for v0.1.1, a release with only the docs. Commits on
`release/v0.1.1`: the release (83f954c), this close-out, and its CI run named here.

- **GitHub Pages, before the PR:** turned on with `gh api`, its source GitHub Actions
  (`build_type: workflow`), at kiyomi-computation-systems.github.io/circuit. Its
  `github-pages` environment allowed `main` alone, so a tag's deploy would have been
  refused: a `v*` tag policy was added, as the server's environment has;
- **`[0.1.1]`:** Unreleased's docs site, pages and reference check, under an intro: "The
  second release, a patch: documentation", with the site's address. The reference
  check's bullet now says what #18's review added: arity, guide links that name the
  entry, and the pin's tag read from the vendored `Akku.manifest`. The links gain
  `[0.1.1]`, and Unreleased compares from v0.1.1;
- **the version:** 0.1.1 in `Akku.manifest`; README.org's status, the home page's and
  Installing's clone of the tag name v0.1.1;
- **no library or example changed** since v0.1.0: `git diff v0.1.0` over `src/` and
  `examples/` is empty, so a patch;
- `make test` passes 16 suites, and `make check-site` twelve pages. CI passed on the PR
  (run 41055346017): amd64 in 3m43s, arm64 in 4m00s, and the site job in 29s;
- **no agents ran.**

### 2026-10-30: the docs' pages and an API reference held to the code, in PR #18

The second of the owner's two PRs for the docs, built on `docs/pages`, which sat on
`docs/site` until #17 merged, then moved onto its squash before its first push. Commits:
the pages and the suite (489f92c), this close-out, and its CI run named here.

- **the pages:** Requests and responses, Bodies and streaming, Middleware, Routing,
  Waiting, Upgrades and WebSockets, Testing handlers, Configuration and an API reference,
  in `site/pages.sls` and the home page's Read next; Quickstart's steps link the pages
  that go further. README.org went from 197 lines to 88: its guide sections moved to the
  pages, as the two writers' reports listed, fact by fact;
- **the reference:** an entry for each of the six libraries' 105 exports, with its
  signature from the source and a guide link; the 25 names `(circuit http-server)`
  re-exports link the server's reference at v0.9.1 instead. Every export had a signature
  comment, so none was added;
- **`tests/test-reference.sps`**, in `make test`, 170 rows: the sections are the six
  libraries, in order; every other library under `src/` exports only names the six
  export or the suite's `internal-exports` list; the entries are each library's exports,
  sorted lists compared whole; each signature is its source comment, whitespace collapsed,
  and agrees with `procedure-arity-mask`; the type aliases are the source's alias
  comments, which agree with each other; each re-export, found by `eq?` binding, has no
  signature and one link to its upstream's reference at the pinned tag, under a heading
  whose section names it; each other entry links a guide page that names it in code; and
  every link into chez-http-server's or chez-websocket's repository, in `docs/` and
  README.org, names the pin's tag, `v` and the vendored `Akku.manifest`'s version, which
  the Makefile's pin comments must also give. The brief's "names it in a code span"
  became "in code, inline or fenced": eight entries are named only in Requests' examples;
- **the footer rows:** `site-render-unit` holds each footer whole, labels included,
  against the neighbours `(site pages)`'s order calls for, at the nav's first page, a
  middle one and its last;
- **the review**, read-only, on Opus, found and I reproduced: three untrue statements (a
  wrap's `f` runs before the head, a `HEAD`'s included; `(wrap-body-cap #f)` lifts the
  caps outside it; a port goes whole only when Chez knows its length), snippets on
  Routing whose handlers no block defined, a subprotocol example that missed `/echo`,
  two `text` helpers of different arity, and gaps: a catch of one's own, the query and
  form parsing circuit doesn't do, the server's other refusals (`connection`, a status
  outside 200 to 599, an `upgrade` naming no protocol the client offered), and running
  without make. Fixed, with the cuts it named. In the suite it found six holes, each
  passing a mutant: a pin tag the Makefile alone vouched for (its comment and every link
  at v0.9.2 over v0.9.1's commit), a re-export anchor that only had to exist, unchecked
  aliases, signatures held to comments and not to arity (`run-server` with a third
  argument), any page counting as a guide link, and re-exports found by a missing
  definition. Each is closed, and its mutant fails;
- **verified:** every whole program on every page, 39, loads; the hand-backs' programs,
  rerun on my own port, printed what the pages show; Routing assembled into one program
  from its own blocks reproduces every output on it; each changed block was rerun; every
  mutant the reference writer made, 39, exits 1, and two of mine did (an entry moved to
  another library, a signature fenced as `scheme`); the footer rows fail on a `neighbors`
  with no previous page and on a label written as the file's name;
- `make test` passes 16 suites, and `make check-site` all twelve pages. CI passed on the
  PR (run 41050770299): amd64 and arm64 in 3m47s each, each running the 16 suites and
  checking the site, and the site job, which built all 12 pages on apt's Chez, in 24s;
- **agents**, all on Opus, none committing:
  - the guide writer for Requests, Bodies, Middleware and Testing: 284,277 tokens, 78 tool
    calls, 21m51s;
  - the guide writer for Routing, Waiting, Upgrades and Configuration: 246,392 tokens, 64
    tool calls, 18m48s;
  - the reference writer, page and suite: 299,722 tokens, 70 tool calls, 23m44s; then the
    suite's holes: 409,411 tokens, 27 tool calls, 13m36s;
  - the read-only review: 337,316 tokens, 78 tool calls, 22m13s.

### 2026-10-30: the docs site, in PR #17

On the owner's decisions of 2026-10-30: hold the docs to the code by the site's gates and a
reference check, cut README.org down, release v0.1.1 with the docs alone, and two PRs, this
one the machinery and the first pages. Commits on `docs/site`: the site (928e073), this
close-out, and its CI run named here.

- **the generator:** chez-websocket's `site/` and `build-site.sps`, which are the server's
  but for names, copied, with links to repository files pinned to circuit's blob, the
  template's names and the nav changed. Its three programs come with it: `site-unit`, 59
  rows, and `site-render-unit`, 18, rewritten into circuit's suite form, and
  `site-check`, the seven invariants;
- **three pages, not one:** the render suite renders pages under the nav's own names, as
  a page's title is its label and a page links its neighbours, and with Home alone the nav
  is empty. So Installing and Quickstart came with Home, and the footer row holds both
  ends of a two-page nav, where chez-websocket's held the middle page of three;
- **chez-cmark-gfm:** `Akku.lock` is chez-websocket's, copied whole: it locks the same one
  dependency, and `akku` isn't installed here to regenerate it. `Akku.manifest` names it as
  a development dependency and no `depends`; `.akkuignore`, `scripts/fetch-akku-lock` and
  its offline test come with it, the last two unchanged. ADR-0003 gains item 7;
- **the container:** chez-cmark-gfm finds cmark-gfm by searching `/usr/lib` and the like,
  which the server's container has through `--emulate-fhs` and circuit's doesn't. So
  `guix-env-enter` exports `CHEZ_CMARK_GFM_LIBS`, chez-cmark-gfm's own override, naming the
  profile's two libraries by absolute path, and nothing loads by bare name. `manifest.scm`
  gains cmark-gfm, tar and xz. The launcher test's T7a, T7e and T7f hold the export, and
  the self-test's assertion 7 holds both loads;
- **the Makefile:** `site-deps`, `site`, `check-site` and `check-site-deps`, as
  chez-websocket's, and `srfi`, which links SRFI-64 alone, for a machine with no libuv or
  compiler; it shares its link loop with `deps` as a canned recipe. A first split made
  `srfi` a prerequisite of `deps`, which broke launcher row M2: in a tree with no
  `vendor/`, the missing submodule was named before the missing Chez;
- **CI:** the linux job runs `check-site-deps` and `check-site` on both architectures, and
  a site job builds the site on apt's Chez, as `pages.yml` does. `pages.yml` deploys on a
  `v*` tag or by hand, its actions pinned by SHA: upload-pages-artifact v5.0.0 and
  deploy-pages v5.0.1;
- **the pages:** each Quickstart program ran in the container, and the output on the page
  is what curl and the server printed. One finding is on the page: `/boom`'s 500 has no
  `server` field, its middleware being inside `wrap-catch`. The claims were probed: the
  libraries' exports the Home page names, and `req-set` and `res-add-header` leaving the
  old value as it was;
- **watched to fail:** `check-site` against a page missing from the nav, an anchor that
  doesn't exist, a repository link to no file, a `neighbors` that never gives a next page
  (the first-page row failed), and no `CHEZ_CMARK_GFM_LIBS` (chez-cmark-gfm: not-found);
  T7a and T7f against an entry that drops the export or the check; the self-test's two
  cmark-gfm assertions against fake libraries. Swapping the two paths fails only the
  variable's assertion: Guix's RUNPATH lets the extensions library load first;
- `make check-guix` passes: the launcher test's 73 rows, and in the container every
  assertion, `make test` with 15 suites among them. CI passed on the PR (run 41041967931):
  amd64 in 2m24s and arm64 in 3m53s, each rendering and checking the site, and the site
  job on apt's Chez in 29s;
- **no agents ran.**

### 2026-10-29: v0.1.0 tagged and released, recorded in PR #16

On the owner's "Run the whole chain" for v0.1.0, and their "Yes, like the server" for a
release page. This PR holds this close-out alone; CI passed on it (run 40985448682).

- **CI on the tagged commit:** main's run on bf38a4b, 40984525973, passed on amd64 and
  arm64. main's run on #14's squash, 0ae889b, had failed a timing row, so the tag waited
  for #15's fix;
- **the tag:** `v0.1.0` (tag object 30960aa) on bf38a4b, annotated and signed with the
  Kiyomi release key (`git tag -v`: a good signature), checked absent locally and on
  origin first, then pushed alone. Its message: "circuit v0.1.0 — an HTTP layer in the
  manner of Ring, for R6RS Scheme", then a paragraph from `[0.1.0]`'s intro. The tag's
  day is `[0.1.0]`'s date;
- **the GitHub Release:** that title, from the tag with `--verify-tag`, not a draft or a
  prerelease, and the repository's latest. Its notes are `[0.1.0]` as the tag holds it,
  intro to last bullet; the published body is those notes, byte for byte;
- **a fresh clone of the tag**, as README.org says: `git clone --branch v0.1.0` from
  GitHub (HEAD bf38a4b), `make submodules`, `make check-pins`, and in its own Guix
  container `make test`, 15 suites, 783 rows, and `make check-help`;
- **GitHub's source tarball** for the tag: 286 entries, `vendor/`'s two directories
  empty, and neither `.plans/` nor `AGENTS.md`;
- **no agents ran.**

### 2026-10-29: a 504's logged ms, at least 998, in PR #15

main's CI on #14's squash, 0ae889b (run 40982985674), failed on amd64 and passed on
arm64. One row failed: a 504 that `wrap-log` logged at 999 ms, where the row asked at
least 1000. The owner chose to fix the row before the tag. Commits on
`test/timeout-row-clocks`: the row (931f8d1), this close-out, and its CI run named here.

- **why:** the timeout's deadline counts 1000 ms of libuv's loop clock (the server's
  waits read `uv-now` after `uv-update-time!`), and `wrap-log` counts on Chez's
  `real-time`; each counts whole milliseconds. As the deadline is armed the loop's
  clock can trail by a millisecond, and the log's two readings each truncate, so the
  log can count 998 or 999 for the deadline's 1000. `wrap-log` is outermost in the
  example, so it reads its clock before the deadline is armed;
- **the fix:** the floor is 998, the reason in a comment over the row. The ceiling,
  under 1500, is as it was;
- **watched to fail:** with the example's timeout at 990 the row failed, reading 994 ms
  twice, and no other row did. That run showed the client's "no sooner than 1000 ms" row
  passing at 990, now in Open;
- `make test` passes 15 suites, 783 rows. CI passed on the PR (run 40983685657): amd64 in
  1m55s and arm64 in 3m37s;
- **no agents ran.**

### 2026-10-29: v0.1.0, the first release, in PR #14

On the owner's "Do v0.1.0". Commits on `release/v0.1.0`: the release (421e40a), this
close-out, and its CI run named here. No code or suite changed. `make test` passes 15
suites, 783 rows. CI passed on the PR (run 40982073168): amd64 in 3m48s and arm64 in
4m06s, its Chez restored from `main`'s cache, each 782 rows and the curl row skipped.

- **CHANGELOG.md:** Unreleased, kept since slice 1 as a log in slice order, becomes
  `[0.1.0] - 2026-10-29` in the siblings' first-release form: an intro (a Ring-like
  layer for R6RS; the core plain R6RS; the server's v0.9.1 and chez-websocket's v0.4.1,
  pinned; the API may change before 1.0), then what each library does as it stands.
  Entries such as "`same?` is gone" spoke of states no release had. Every name in a code
  span was checked against the six public libraries' exports, 105 names read by
  `library-exports`; the rest by hand: the server's `handler-failed`, the variables, the
  forms and the make targets. A fresh empty Unreleased, and the links;
- **README.org:** Status names v0.1.0 and the API's terms before 1.0. Build and test says
  to clone the tag: a release's source archive leaves `vendor/` empty (checked:
  `git archive` holds `vendor/`'s two directories and nothing in them, and neither
  `.plans/` nor `AGENTS.md`, which `.gitattributes` leaves out);
- **the version:** 0.1.0, the owner's. No other file names one: circuit has no Akku
  manifest while the server isn't on the index (ADR-0003);
- **no agents ran.**

### 2026-10-29: CI on arm64, in PR #13

On the owner's "do it", after they asked whether a public repository can use an arm64
runner: GitHub's standard runners, `ubuntu-24.04-arm` among them, are free and
unlimited on one. Commits on `ci/arm64`: the workflow (f1a7b46), the records with this
close-out, and its CI run named here. No code or suite changed.

- **the workflow:** a matrix runs the one job on `ubuntu-24.04` (amd64) and
  `ubuntu-24.04-arm` (arm64), with `fail-fast: false`. Two new steps check the arch before
  anything is trusted: the machine is the one the label names, and Chez's machine type
  is the one its configure chose, `ta6le` or `tarm64le`. Each step's script was run here
  first: it passed on this machine and failed by name with the other arch's value. The
  Chez cache key already held the arch, and the server's oha fetch pins a linux-arm64
  binary;
- **the first run**, by hand on the branch (40976751724): both jobs passed. arm64 took
  7m23s, its Chez built cold (the cache missed on its ARM64 key), and amd64 3m42s. arm64
  read `machine aarch64` and `Chez machine type tarm64le`, and fetched `oha-linux-arm64`
  v1.16.0. `make test` passed 15 suites, 782 rows and the curl row skipped on each;
- **the gate on arm64**, held as on amd64: every gate's worst figure read within 12 B of
  amd64's in the same run (G9 park; most within 5 B), so the same bounds hold. arm64's worst figures: G1 1,445, G2 1,440, G3 307
  and 275, G4 80 and 400, G5 385 and 340, G7 308, G8 529, G8 own 289, G8 on-done 243,
  G9 602 and 597, G10 80, 166 and 0;
- **CI on the PR** (run 40977747024) passed both jobs, the gate held on each, and arm64
  built Chez cold again, in 7m21s: GitHub scopes a cache to the ref that saved it, so the
  hand run's, under `refs/heads/ci/arm64`, can't be read from `refs/pull/13/merge`. The
  PR saved its own, and `main`'s first run after the merge builds it once more, under
  `main`, where every later run reads it;
- **the records:** the global constraints and ADR-0007 say CI holds the gate on both;
  Open loses its amd64 item;
- **no agents ran.**

### 2026-10-29: the pins at the server's v0.9.1 and chez-websocket's v0.4.1, in PR #12

On the owner's "lets go ahead and pin chez-websocket and then move the circuit pins", and
their "Run the whole chain". Before it: the server's v0.9.1, its #248 tagged on b7381a0,
and chez-websocket's v0.4.1, its #101 and #102 tagged on 579c118, each closed out in its
own ledger. Commits on `chore/pins-server-v0.9.1-websocket-v0.4.1`: the pins and the rows
(d1e54b8), the records with this close-out, and its CI run named here. `make test` passes
15 suites, 783 rows, as on `main`. `make gate` passes in two runs; no held gate moved.
Their worst figures: G1 1,446, G2 1,438, G3 312 a GET and 276 a POST, G4 81 and 403, G5
382 and 347 with a park, G7 310, G8 532, G8 own 296, G8 on-done 246, G9 611 and 597 with
a park, and G10 83, 168 and 1. CI passed on the PR (run 40878917032, 2m45s): 15 suites,
782 rows and the curl row skipped; the gate's worst figures G3 308 and 272, G4 81 and
405, G5 382 and 351, G7 304, G8 535, G8 own 292, G8 on-done 243, G9 609 and 610, G10 81,
168 and 3.

- **the pins**, on one commit: both gitlinks with `SERVER_PIN` and `WEBSOCKET_PIN`.
  `make check-pins` was watched failing first, with the gitlinks moved and the pins not
  (five mismatches, the carried pins ok), then passing;
- **the rows:** on the new pins, exactly the five rows this ledger named failed: slice 4's
  let-out `&body-failed` row and slice 7's four cap rows. Each expected the test host's
  `handler-failed` line, which v0.9.1 leaves out, as `serve` does (#243). They now expect
  none, and say so. No other row moved;
- **the gate:** G8 on-done, a no-op `req-on-done!` procedure, reads 236–243 B at 1
  connection and 231–246 B at 50, from 858–870 B and 528–557 B (#245). G8 reads 524–531 B
  and 518–532 B, from about 1,145 B and 834 B. G8 own reads 284–296 B, where it was;
- **the records:** the design's opening, §7, §11 and §12; ADR-0003 and ADR-0007 amended;
  the global constraints; README.org's links at the new tags, each answering 200; the
  CHANGELOG's build lines. Open loses the items for #241, #243 and #245, and the Akku item
  says where the index stands;
- **no agents ran.** No review: the change moves pins and five rows' expected logs, and
  no library's code.

### 2026-10-29: two testing rules in AGENTS.md, in PR #11

On the owner's "add the AGENTS.md rules", offered in slice 7's and slice 8's reflections.
One commit (3a3a90b), the records with this close-out, and its CI run named here. No code
changed; `make check-help` passes. CI passed on the PR (run 40853412223, 2m49s).

- **under Testing & mutation discipline:** a mutant's suites run under a timeout and a
  memory cap, and a test producer ends, answering a call past its last piece once, then
  eof. Slice 8's close-out has the run it comes from;
- **under Tests:** a limit is held from both sides, at the limit and a step past it, and
  a number check is given a bignum. Slice 7's close-out has the review findings they
  come from;
- neither is a rule about how Chez behaves, so neither needed a probe.

### 2026-10-29: slice 8, `res-wrap-body` split into a wrap and a tap, in PR #10

Commits on `slice/8-tap-body`: the slice (2f25f37), the records with this close-out,
and its CI run named here. Built, reviewed and fixed on 2026-10-28 and 2026-10-29, by
the session. `make test` passes 15 suites, 783 rows (check-imports 57, check-suites 14,
circuit-testing 45, examples 94, headers 24, http-server 82, middleware 13,
middleware-waits 68, names 20, request 52, response 106, router 101, router-properties
29, test 43, websocket 35), and `make gate` passes, no gate moved: no gate measures a
wrap or a tap. Its worst figures, on the first build, before the review's piece check:
G1 1,438, G2 1,433, G3 306 a GET and 273 a POST, G4 81 and 404, G5 381 and 340 with a
park, G7 306, G8 1,142, G8 own 287, G8 on-done 868, G9 607 and 595 with a park, and G10
83, 167 and 5. CI passed on the PR (run 40849487510, 2m35s): 15 suites, 782 rows and the
curl row skipped, as CI's curl has no WebSocket; the gate's worst figures G3 308 and 279,
G4 80 and 401, G5 381 and 343, G7 310, G8 own 291, G9 602 and 593, G10 81, 161 and 0.

- **The owner's decision** (design §15.26): `res-wrap-body` takes `f` alone and always
  drops the length; `res-tap-body` hands each piece to `on-piece` and keeps it. The
  name was weighed against `res-observe-body`. Weighed too: keeping `same?`, and a
  length procedure in its place;
- **the build**, the session's, with no build agent:
  - a tapped body is a kind of its own, its accessors kept out of the facade;
    `res-wrapped-body-same?` is gone;
  - the rows that used `same? #t` are taps or plain wraps. `(circuit test)`'s
    `counted`, which told a measured port by a counter that reported at eof, is
    `measured`, which tells it by whether the port is closed when a tap sees the last
    piece;
  - each new row was watched failing under a stub `res-tap-body` first;
  - 12 mutants, their predictions hashed before the run (`fca75ff7`), all killed. 10
    went as predicted. Two predictions missed, neither a gap: `t-on-piece-eof` left
    the adapter's sized tap row passing, since the server never asks a body with a
    length for its end; `w-no-count` failed one row more than predicted;
- **the first mutant run exhausted the machine's memory**, and Claude Code stopped it.
  Under `t-drop-length`, `res-body->bytevector` read a tapped body to its eof, and
  `(circuit test)`'s `pieces` answered "XYZ" forever past its pieces; the harness ran
  suites with no timeout. `pieces` now answers "XYZ" once, then eof, and the harness
  runs each suite under `timeout 120` and a 4 GiB `ulimit -v`. The owner had the run
  restarted so;
- **a read-only Opus review** (Opus 5.5; 189,020 tokens, 10.7 minutes) found no wrong
  behaviour. It ran 6 mutants; 4 survived, and each is now killed by a row:
  - a sized port under a tap was never held: a tap that measured it, or never
    registered its close, passed. A row for it, and a parity case;
  - a wrap's count over a tap was never held. A row for it, and parity's wrap over a
    tap now runs past its length;
  - "HEAD, 204 or 304 calls `on-piece` never" is false under a wrap whose `f` reads
    eagerly, before the head. The claim is qualified, and a row holds a plain tap
    there;
  - `on-piece` was handed pieces that never go out, past a sized body's length, and a
    string or an empty bytevector. The tap now checks each piece as the wrap's count
    does: such a piece raises before `on-piece` sees it, logged `handler-failed`, where
    without the tap the server logs the piece itself. Two mutants of the check, hashed
    first (`b1338137`), went as predicted;
  - a raise from `on-piece` after the head now has a row;
  - the design's stale lines, among them "a wrap may ask past a length" and "the test
    is the stricter", and lists that left taps out;
- **traps:**
  - a test producer that answers forever past its end turns a mutant that reads past it
    into an unbounded read, which can take a machine's memory: bound such producers,
    and run mutants under a timeout and a memory cap;
  - a wrap's `f` runs before the head, so what it reads through a tap reaches
    `on-piece` even for a HEAD.

### 2026-10-28: slice 7, a request's own cap on its body, in PR #9

Commits on `slice/7-body-cap`: the slice (b741810), the records with this close-out,
and its CI run named here. Built, reviewed and fixed on 2026-10-28, by the session.
`make test` passes 15 suites, 769 rows (check-imports 57, check-suites 14,
circuit-testing 45, examples 94, headers 24, http-server 77, middleware 13,
middleware-waits 68, names 20, request 52, response 96, router 101, router-properties 29,
test 44, websocket 35), and `make gate` passes, no gate moved. Its worst figures: G1
1,441, G2 1,434, G3 308 a GET and 274 a POST, G4 80 and 400, G5 385 and 343 with a park,
G7 306, G8 1,146, G8 own 291, G8 on-done 869, G9 606 and 604 with a park, and G10 81, 164
and 4. CI passed on the PR (run 40785095018, 2m29s): 15 suites, 768 rows and the curl
row skipped, as CI's curl has no WebSocket; the gate's worst figures G3 309 and 275, G4
81 and 404, G5 384 and 339, G7 305, G8 own 291, G9 605 and 610, G10 87, 163 and 2.

- **The owner's decision** (design §15.25): the server's `CHEZ_HTTP_MAX_BODY_BYTES`
  stays the one cap a deployer sets, and a request carries one of its own, from code,
  the innermost winning. Weighed: circuit's own `CIRCUIT_MAX_BODY_BYTES`; asking the
  server for a finite default; a helper that reads a body whole under a cap;
- **the build**, the session's, with no build agent:
  - `req-with-body-cap` and `req-body-cap` in `(circuit request)`, `wrap-body-cap` in
    `(circuit middleware)`, all in the facade;
  - the cap is the request record's fifth field: a sealed record of four fields or five
    is 48 B, so G4 holds as it was;
  - the view's body is handed the cap, and the adapter hands it to `body-input-port`,
    calling `(body-input-port)` as before when there is none;
  - `make-test-req` ignores the cap; `examples/echo.sps` caps its body at 1 MiB;
  - each new row was watched failing under stubs first. One, the server's cap as the
    ceiling over a request's, passed under the stubs too: circuit can't raise the
    server's cap, so the row held only the server. It was dropped (AGENTS.md);
  - 17 mutants, 16 of the libraries and one of the echo example, their predictions
    hashed before the run (`31834857`), went as predicted;
- **a read-only Opus review** (Opus 5.5; 202,453 tokens, 13.3 minutes) found nothing
  severe. It ran README.org's Configuration snippet in the test host: `/notes` refused
  65,537 bytes and took 65,536, and `/uploads` took 65,537. Of its 19 mutants, 16 were
  killed and one, the adapter always naming the cap, is equivalent. Fixed:
  - the echo example's cap was held only between 300,001 and 1,048,576 B. A row now reads
    a body of 1 MiB whole, and a 512 KiB echo fails it;
  - no row took a cap past the fixnum range, so a fixnum-only check survived. 2^100 is
    now a cap in the request and middleware rows, and that mutant fails both;
  - comments that said `req-body-cap` is the cap in force (it is the copy's), that the
    host enforces it (a test request doesn't), and that a read, not the port, fixes it;
  - this ledger's #243 item: slice 7's four cap rows pin the test host's line too;
- **corrected in Open:** the server's #241, #243 and #245 are fixed on its `main`, by
  #242, #244 and #246, in no release yet; §16.1's item is gone;
- **traps:**
  - `curl -i` prints a `100 Continue` as a head of its own, which the examples suite would
    read as the answer. The 1 MiB row sends `Expect:` empty, so curl asks for none
    whatever its version's threshold;
  - a failing row that echoes a large body prints it whole, a megabyte here: the rows
    give a long body as its length;
  - the server checks a declared length against the pull's cap at the first read, before
    it sends `100 Continue`, so a client that waits sends nothing.

### 2026-10-28: slice 6c, `(circuit websocket)`, in PR #8

Commits on `slice/6c-websocket`: AGENTS.md's rule from slice 6b's final review (d96b2a4),
the pin (b1f5401), the slice (32b6e41), the records with this close-out, and its CI run
named here. Built, reviewed and fixed on 2026-10-28. `make test` passes 15 suites, 752
rows (check-imports 57, check-suites 14, circuit-testing 45, examples 92, headers 24,
http-server 73, middleware 9, middleware-waits 68, names 20, request 47, response 96,
router 100, router-properties 29, test 43, websocket 35), and `make gate` passes, no gate
moved. Its worst figures on the final code: G1 1,441, G2 1,434, G3 305 a GET and 276 a
POST, G4 81 and 404, G5 382 and 357 with a park, G7 305, G8 1,137, G8 own 295, G8
on-done 866, G9 605 and 629 with a park, and G10 84, 167 and 2. CI passed on the PR (run
40713181539, 4m07s): 15 suites, 751 rows and the curl row skipped, as CI's curl has no
WebSocket; the gate's worst figures G3 311 and 272, G5 382 and 340, G8 own 298, G9 606
and 607, G10 84, 164 and 4.

- **chez-websocket first**, each PR closed out in its ledger,
  `.superpowers/sdd/progress.md`: `websocket-handshake`, for a host whose requests and
  responses are its own (#97; its decision 0009), released as v0.3.0 (#98); then
  `websocket-limits-from-environment` in its facade (#99), released as v0.4.0 (#100),
  the tag signed;
- **the owner's decisions:**
  - an app passes limits from its own env, `(websocket-limits-from-environment env)`, to
    `websocket-res`; the default stays the process's environment, read at start (the
    slice 6 design §7.5). The adapter carrying its env on every request was set aside;
  - chez-websocket exports that procedure and releases v0.4.0 before 6c pins it (§7.6);
  - the README's Try line gives curl, 8.11 or later, and websocat;
  - AGENTS.md's argument-order rule corrected (the traps below);
- **the build** (Opus 5.5; 860,914 tokens over two rounds, 40.2 and 17.3 minutes):
  `src/circuit/websocket.sls`, `tests/test-websocket.sps`, the audit's rule (i) and its
  five fixtures, the names suite's exact exports, `examples/websocket.sps` and its
  loopback rows, `/websocket` in the loopback app, and the records. Its mutants'
  predictions were hashed before each run (`5d8e21ee`, then `0bba6a33`). Round 2's set,
  43 regenerated from the final library, the example and the audit, went as predicted.
  L7a and L7b, the procedure checked inside the handshake's first or last argument,
  survive: equivalent under Chez 10.4.1 as it compiles the library today. The builder
  added a rule the brief didn't name, that no library imports `(circuit websocket)`;
  the session kept it (ADR-0006);
- **curl:** the container's 8.20 speaks `ws://`, but `-T -` sends its whole input as one
  binary message and exits only at `--max-time`, 28. The docs give websocat for typing
  messages;
- **a read-only Opus review of round 1** (Opus 5.5; 223,475 tokens, 16.0 minutes) found,
  each fixed:
  - CI's curl, 8.5.0, has no WebSocket, so the curl row would go red there. It now runs
    only where `curl --version` lists `ws`; under a shim that acts as 8.5 does, the
    examples suite passed 91 rows, that one skipped;
  - nothing held that the default limits are the environment's: its m1 and m2 survived.
    Now two loopback rows with `CHEZ_WS_MAX_MESSAGE_BYTES=4`, for the example's
    2-argument form and the loopback app's 3-argument form;
  - nothing held a field's line order: its m3 survived. Now a row splits
    `X-Forwarded-Proto` over two lines;
  - `run-server`'s env never reaches the limits: the question behind §7.5 and v0.4.0;
  - stale records: the slice 6 design's `-> Any`, AGENTS.md's two libraries and its
    Dependencies, ci.yml's comments, and design §8's handshake as work to come;
- **round 3, the session's:** the pin at v0.4.0, README.org's recipe for limits from an
  app's env, and a websocket row that runs it through the test host: an env with
  `CHEZ_WS_MAX_MESSAGE_BYTES` 4 closes a Hello 1009, and an empty one echoes it. Its
  predictions were hashed first (`8e4b4df5`): the 4-argument form dropping its limits
  fails it and the limits row, exactly;
- **traps:**
  - Chez chooses a call's argument order as it compiles the call. main's AGENTS.md, and
    the brief, said compiled library code runs right to left. A probe library's calls ran
    left to right, `((a b c d) (check method host) (method host check))`, a `begin`
    argument included. Yet in `(circuit websocket)`, L7b's `begin` in the last argument
    ran before the reads ahead of it: probed, no field was read before "not a procedure".
    The session's first correction, that a `begin` runs first wherever it stands, was
    wrong too, found while writing this; AGENTS.md now says what was seen;
  - chez-websocket reads `CHEZ_WS_` through `getenv` as its binding loads, so neither a
    value set later nor `run-server`'s env reaches the default limits;
  - Chez's `--libdirs` skips a missing directory silently: each mutant folder is a source
    root, its load proved by a mutant that turns every row red.

### 2026-10-27: slice 6b, `(circuit router)`, in PR #7

Commits on `slice/6b-router`: the slice (485bf5d), the records with this close-out
(ab7aab7), and its CI run named here. Built, reviewed and fixed on 2026-10-27. `make test`
passes 14 suites, 695 rows (check-imports 51, check-suites 14, circuit-testing 45,
examples 77, headers 24, http-server 73, middleware 9, middleware-waits 68, names 19,
request 47, response 96, router 100, router-properties 29, test 43), and `make gate`
passes. Its worst figures in the three runs on the final code: G1 1,448, G2 1,441, G3 314
a GET and 278 a POST, G4 80 and 402, G5 384 and 342 with a park, G7 308, G8 1,145, G8 own
289, G8 on-done 864, G9 606 and 612 with a park, and G10, now held, 85 a word, 167 a
parameter and 4 a miss. CI passed on the PR (run 40605288848, 2m52s): 14
suites, and the gate's worst figures G3 305 and 272, G5 382 and 341, G8 own 294, G9 609
and 593, G10 84, 164 and 3.

- **the owner's decisions** (design §15.20–§15.24):
  - in the slice, `req-mount-path` (§15.20);
  - around a mount, a group's middleware reads the enclosing mounts' part, and a wrapped
    mount pays a second `req-set` (§15.21);
  - route matching tested by property in 6b, with an oracle written from §5 alone
    (§15.22);
  - at the final review, a request that a group's middleware hands on without the
    mount's match reaches the mount's handler as it is (§15.23);
  - G10 held at 128, 256 and 64 B (§15.24);
- **the build** (Opus 5.5; 572,002 tokens over three rounds, 32.9, 27.4 and 7.4 minutes):
  `src/circuit/router.sls`, `tests/test-router.sps`, the names suite's exact exports, G10
  in the gate, `examples/router.sps` and its loopback rows. Round 1 watched 103 of its
  mutants fail. The session regenerated every mutant set from the final router, 219 in
  all, its own and the reviews' included: the example suite alone leaves 4 alive, each
  equivalent (`rev-head-to-get-only-if-no-any`, `rev-hex-needs-two-before-e-one`,
  `rev-rest-of-gt`, `rev-walk-word-no-backtrack-to-rest`);
- **the property suite** (Opus 5.5; 523,982 tokens over two rounds, 66.9 and 30.1
  minutes), `tests/test-router-properties.sps`:
  - a naive oracle written from §5 before the router was read (the session checked the
    agent's transcript), 21 sanity rows from §5's examples, and P1–P7 with a shrinker,
    4.4 s at the fixed seed;
  - its generators nest routers four deep, and give groups middleware that rewrites the
    path, makes a fresh request, or is a router of its own;
  - no disagreement with the router at the default seed, 25 others, or ten times the
    cases; the session reran eight seeds, two at ten times;
  - alone it kills 188 of the 219 mutants. The ones left: the 4 equivalents and 3 more
    (the 404's body as `""`, which sends the same bytes; a memo of a pure function; a
    path only read where no middleware sits between), 7 cost-only, and 17 argument
    checks, each of which the example suite kills;
  - its round 1 found two gaps in §5, now rules: a route takes one method entry or more,
    each once; and what a nested router's not-found handler reads;
- **a read-only Opus review of round 1** (Opus 5.5; 232,270 tokens, 16.3 minutes) found
  flaws in the session's brief, each fixed:
  - a router reached through a route lost the mount's part of the match;
  - group middleware around a mount saw the rest of the path;
  - the mount's prefix was dropped (now `req-mount-path`, §15.20);
  - `METHOD` took any symbol, and names were too loose;
  - dot words were allowed;
  - the Latin-1 branch rested on a false premise;
  - G10 measured the server's path string, and couldn't prove which path oha asked;
  - test gaps: the join without params, UTF-8 checks at every position, the mount 400, a
    name repeated apart, a router under a words-only route; the decoding hazards and
    shared strings undocumented;
- **the final read-only Opus review** (Opus 5.5; 285,611 tokens, 19.2 minutes) found,
  each fixed:
  - the router crashed, `ahead-match: not of type ahead`, when a group's middleware
    around a mount handed `next` a fresh request, or one a router of its own matched
    (§15.23; two rows, and both kinds now in the property suite's generators);
  - no row held what a nested router's not-found handler reads under a route, or under
    a wrapped mount: two of its mutants survived both suites. Now two example rows, and
    P1 compares every not-found read;
  - P3 took a crash inside `make-router` for a refusal; P5 passed for a router that
    answers 400 to everything, and P6 for one that runs no handler; escaped words came
    from five plain words alone; a router under a route under a mount, and four routers
    deep, were reached 68 and 27 times in 32,000. Each fixed in the property suite;
  - §5 over-claimed: mount path then path is the whole path only unless a middleware
    rewrote it; HEAD on a route with GET and ANY goes to GET, against "ANY takes every
    method the route doesn't list"; a mount also allocates its rest. The README and
    changelog said "HEAD goes to GET";
  - the example suite missed a `req-mount-path` that joins at most two mounts: now a
    three-mount row;
- **G10, held:** a word compared through a substring reads 341, 401 and 323 B and fails
  all three rows. A word route's match made per request reads 117 B, under the 128 B
  bound: the example suite's 88 B row holds that one (ADR-0007);
- **traps:**
  - Chez 10.4.1's cp0 miscompiles multiple values returned through a closure a procedure
    returns. With `(define (g-int n) (lambda (s) (values (mod s n) (+ s 1))))`, a
    `g-pick` that takes `let-values` of `((g-int (length xs)) s)` and returns the item
    and the state, and a second procedure that does the same `let-values`,
    `((g-pick '(a)) 5)` raises "incorrect number of values from rhs" with cp0 on, and
    gives `a` and `6` with `run-cp0` off (reproduced by the session). The property
    suite's generators return pairs. Circuit's libraries return values only from direct
    calls; not filed;
  - Chez's `utf8->string` never raises: each invalid sequence becomes U+FFFD, so the
    router decodes by hand;
  - Chez's `--libdirs` silently skips a missing directory, so a mutant run with a wrong
    path passes every mutant;
  - mutants copy the whole library: after a fix, regenerate them, or each carries the old
    code and dies of it;
  - the server refuses raw bytes past ASCII and malformed escapes itself, with a 400 and
    `Connection: close`; `%FF` and dot segments reach the router as sent.

### 2026-10-27: slice 6a, upgrades, in PR #6

Commits on `slice/6a-upgrades`: the slice 6 design (16577d4), upgrades in the core and
the adapter (c4abbee), the example and its loopback rows (70d0db3), the records with this
close-out (42dfdaa), and its CI run named here. Built, reviewed and fixed on 2026-10-27. `make test`
passes 12 suites, 553 rows (check-imports 51, check-suites 14, circuit-testing 45,
examples 65, headers 24, http-server 73, middleware 9, middleware-waits 68, names 18,
request 47, response 96, test 43), and `make gate` passes. Its worst figures in the three
runs on the final code: G1 1,445, G2 1,440, G3 308 a GET and 281 a POST, G4 81 and 407,
G5 383 and 361 with a park, G7 308, G8 1,142, G8 own 311, G8 on-done 873, G9 610 and 609
with a park. No held gate measures an upgrade: on a GET or a POST the new code is one
record predicate: the review ran the gate on main's libraries and on the slice's, and read
G3 at main's 308 B against the slice's 309 B a GET, and 276 B against 278 B a POST. CI
passed on the PR (run 40520270891, 3m1s): 12 suites, and the gate's worst figures within
those ranges (G3 308 and 276, G5 382 and 343, G8 own 298, G9 607 and 598):

- **the owner's decisions** (design §15.16–§15.19): before the slice, slice 6's design
  (§15.16); in it, the transport procedures re-exported (§15.17); at the review, `awaiting`
  re-exported (§15.18), and `res-remove-header` and `res-upgrade-body-take-over` in the
  facade (§15.19);
- **the build** (Opus 5.5; 365,450 tokens over two rounds, 24.6 and 9.4 minutes): the
  upgrade body and its refusals in `(circuit response)`, the facade, the adapter's switch
  and re-exports, `res-body->bytevector`'s refusal, `examples/upgrade.sps`, and rows in
  seven suites. Its first round watched 39 mutants fail. Its second regenerated its 43
  library mutants and 7 example mutants from the final source and watched each fail. A
  dropped re-export, or one of the adapter's own, fails by killing a suite at its import,
  not a named row (traps below). It added two curl rows unasked, for the server's 500s
  the example's docs now claim, which the session kept. The session reran six mutants of
  its own, and the review's status-101 mutant rebuilt on the final adapter;
- **a read-only Opus review** (Opus 5.5; 195,894 tokens, 12.4 minutes) found eight
  things, each fixed:
  - a take-over that waits needed `(http-server)` for `awaiting`: now re-exported
    (§15.18);
  - middleware couldn't remove an upgrade's header: through `make-res`, every upgrade
    became a 500 (the review's probe). Now `res-remove-header`, and the take-over's
    accessor in the facade (§15.19);
  - no row held the server's 500 for a 101 that `make-res` made: switching on status 101
    instead of the body passed every suite. Now an adapter row, logged
    `invalid-response invalid-status`;
  - the example's docs said every other request gets the 200: one with `Upgrade: echo`
    and no `Connection: upgrade`, or over HTTP/1.0, gets the server's 500, logged
    `invalid-response not-an-upgrade`, now held over loopback by the two curl rows;
  - a transport `eq?` row in the adapter suite that couldn't fail, dropped; a comment's
    ordering claim that no row held, dropped; `retained` described as all the client
    sent behind its request, where it is what the server had already read; design §17's
    link to PR #6, made before the PR existed;
- **traps:**
  - a suite that imports `(http-server)` and `(circuit http-server)` without a prefix
    dies at the import, "multiple definitions", exit 255, once a re-export isn't the
    server's own binding, so the names suite's `eq?` rows only restate the import
    (reproduced by the session);
  - curl 8.20 prints a 101's head, then waits and times out, exit 28 (reproduced by the
    session and the review), so bash's `/dev/tcp` drives the echo;
  - over loopback the bytes sent right behind the request arrive as `retained`. Were they
    to come by a read instead, correct code would still pass, and a dropped `retained`
    would go unseen by the examples suite; the adapter suite's own row still holds it
    (the builder's).

### 2026-10-27: slice 5, `(circuit middleware waits)`, in PR #5

Commits on `slice/5-middleware-waits`: the import audit's two names (3d6140c), the library
and its suite (d5e7adb), the example and its loopback rows (09f8698), the gate on the real
middleware (8db56bf), the records with this close-out (4b99942), and its CI run named
here. Built, reviewed and fixed on 2026-10-26 and 27. `make test` passes 12 suites, 514
rows (check-imports 51, check-suites 14, circuit-testing 45, examples 58, headers 24,
http-server 64, middleware 9, middleware-waits 64, names 17, request 47, response 79,
test 42), and `make gate` passes. Its worst figures in the three runs on the final code:
G1 1,445, G2 1,442, G3 310 a GET and 278 a POST, G4 81 and 406, G5 385 and 341 with a
park, G7 309, G8 1,141, G8 own 302, G8 on-done 870, G9 609 and 612 with a park. CI
passed on the PR (run 40481062189, 3m6s): 12 suites, and the gate's worst figures within
those ranges (G5 385 and 340, G8 own 288, G9 606 and 605):

- **the owner's decisions** (design §15.13–§15.15): before the slice, the log's clock is
  Chez's `real-time`, logging is on `req-on-done!` with its cost filed upstream, the catch
  helper reports through `on-raise`, and the line has the server's shape; in it, G9 held
  with a park, and `wrap-log`'s own share held, G8 own, after the review. At the review,
  on 2026-10-27, the owner accepted G8 own's 384 B and G9's 768 B bounds, and the
  allowlist's `real-time` and `display-condition`;
- **upstream:** [chez-http-server #245](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/245),
  filed 2026-10-26: a no-op `request-on-done!` procedure costs 706–843 B a request on the
  server alone, and 858–870 B through the adapter;
- **the library** (Opus 5.5; 387,045 tokens over four rounds, 28, 5.5, 4.6 and 1.5
  minutes): `(circuit middleware waits)`, its suite through the test host, the audit's two
  names, and the names suite. Its first round watched 62 of 64 mutants fail; the two
  `call/1cc` escapes fail the gate instead. The session reran twelve mutants of its own, three
  of them through the gate, and nine of the review's. The gate on its first build read G5 at 485–487 B against 512: the
  brief had `on-raise` run after the escape, a frame after the `call/cc`. Run inside the
  handler, it reads 373–385 B. Writing the log line straight to the port took `wrap-log`'s
  own share from about 655 B to about 273 B;
- **the example and loopback rows** (Opus 5.5; 229,926 tokens, 50 minutes):
  `examples/middleware.sps` and 21 rows. 28 mutants were watched failing, and no process
  outlives a run; the session reran four. It found that a FIN mid-response is heard at
  once, and that over one a wrap's `f` reads an open port, which corrected design §6 and
  §9 and the Open item;
- **the gate** (the session): G5 on the real helper, G8 printed, G8 own and G9 held, each
  held gate watched failing: `call/1cc` escapes read G5 875–927 B and 3,674–3,725 B with a
  park, and G9 1,131–1,137 B and 3,895–3,904 B; the line built in a string port reads
  G8 own 653–688 B;
- **a read-only Opus review** (Opus 5.5; 290,803 tokens, 26 minutes) found no defect in
  what the middleware does. It found, and the session reproduced, then fixed:
  - records that overclaimed: requests the server refuses before the handler are logged
    nowhere (Open); a line can read `200 failed` while the client got the server's 500;
    an `on-raise` that waits needs `wrap-timeout` outside `wrap-catch`;
  - `wrap-log`'s own cost held by nothing: now G8 own;
  - nine mutants passing every suite, among them a 504 with an empty-string body, a
    non-res `on-raise` answer, `(wrap-timeout 0)` and a coarse default clock: each now
    fails a row;
  - figures that disagreed between the records, now ranges over every run;
- **traps, reproduced by the session:**
  - `(rnrs)`'s `current-output-port` is not Chez's parameter: `parameterize` raises
    "incorrect number of arguments"; parameterize Chez's own through a rename;
  - `display-condition` shows one irritant as `with irritant 7`, and several as
    `with irritants (7 "x")`;
  - the server's log line breaks on a raised string holding a line feed (Open);
  - R6RS's `record?` is false for an opaque record, so the server's log writes it;
  - Chez buffers a custom textual output port until a flush, and its console port writes
    out at each line feed when standard output is a file, which hides a missing flush;
  - a `call/cc` outside tail position costs about 100 B a request more on a coroutine.

### 2026-10-26: slice 4, the adapter, in PR #4

Six commits on `slice/4-adapter`: the import audit's allowlist (63d26c9), the adapter
and small port bodies read whole (81e710a), the examples and the loopback suite
(8a8079e), the gate on the real adapter with G7 (f1ec23f), the records with this
close-out (8e6b6b2), and its CI run named here. Built, reviewed and fixed on
2026-10-26. `make test` passes 11 suites, 425 rows (check-imports 48, check-suites 14,
circuit-testing 45, examples 37, headers 24, http-server 64, middleware 9, names 16,
request 47, response 79, test 42), and `make gate` passes. CI passed on the PR (run 40410155928, 2m22s), its first run of
the loopback suite: 11 suites, and the gate's worst figures within ADR-0007's ranges
(G1 1,441, G2 1,440, G3 307 a GET and 276 a POST, G4 81 and 403, G5 365 and 343 with a
park, G7 305):

- **the adapter** (Opus 5.5; 445,883 tokens over three rounds, 35, 4 and 16 minutes):
  `(circuit http-server)`, its suite through the test host, the audit's two names, and
  the names suite. Its first round watched 55 mutant runs fail; the session reran 13
  mutants, three of them its own, and the builder's four Chez traps;
- **the gate** (Opus 5.5; 182,650 tokens, 20 minutes): the real adapter, the pulled
  POST, and final bounds from eight runs, each held gate watched failing (ADR-0007). The
  session reran the gate and its G3 and G4 mutants, and the port-body probe;
- **the examples** (Opus 5.5; 267,072 tokens over two rounds, 36 and 3 minutes): hello,
  echo, a stream, a long poll, and `tests/loopback-app.sps`, run as processes over
  loopback. 31 mutants were watched failing, and no process outlives a run; the session
  reran six mutants;
- **a read-only Opus review** (Opus 5.5; 342,005 tokens, 24 minutes) found no defect in
  what the adapter does, and found tests that passed with it wrong. The session
  reproduced each, and the builders fixed them:
  - three mutants passed every suite: `run-server`'s env not reaching `serve`, the
    Latin-1 bound at 257, and the measure's length guard dropped. Each now fails a row;
  - the long poll's 504 and the server's cap were claimed, not held: each is a row now;
  - a wrap's `f` meets a closed port once the client has gone while the app waited
    (design §6, §9);
  - the test host logs `handler-failed` for a let-out `&body-failed`, which `serve`
    doesn't: filed as chez-http-server #243;
- **the owner's decisions** (design §15.12): ADR-0007's bounds accepted; a port body of
  a piece or less read whole, which took a 6-byte port body from about 5.1 KB a request
  over a bytevector to about 300 B; and G7 held at 384 B, watched failing on the
  streamed code (5,098 B) and with the `guard`s back (658 B);
- **the owner's `/code-review`** (Opus 5.5; 112,540 tokens, 5 minutes) found nine. Two
  were fixed, each watched failing first: the README's threshold read "smaller", and
  `stream.sps` took `+3` for digits. Three are Open, and four are design-recorded
  limits or deliberate (a pipe's 500, a producer's `req-body`, the gate's
  `get-bytevector-n`, the adapter's fast paths);
- **traps, reproduced by the session:**
  - Chez gives no custom port a length;
  - `get-bytevector-n` refuses a count past `(greatest-fixnum)`;
  - a bytevector port refuses a position past its end;
  - a FIFO reports a length of 0 and its `port-position` raises;
  - a declared body past the server's cap is answered 413 before the handler runs;
  - a child of `open-process-ports` stays a zombie while its parent lives.

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
