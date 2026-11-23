# Global constraints

These rules bind every task brief. Each one cites the decision record in
[decisions/](decisions/) it comes from. If a rule here and its record disagree, the record
wins and this file gets fixed. Rules from a record that is still Proposed are marked
provisional. They bind until that record is accepted or amended.

## Platforms and versions

- **Platforms:** Linux and macOS, on amd64 and arm64. No Windows code paths or CI
  (ADR-0001). CI runs on Linux only (AGENTS.md), on amd64 and arm64, and holds the cost
  gate on both (ADR-0007).
- **Chez:** 10.4.1 or later, threaded: chez-http-server's floor (ADR-0002).
- **libuv:** 1.48.0 or later, which pkg-config can see, and a C compiler, for chez-libuv's
  shim (ADR-0002).

## Dependency

- **Every runtime dependency comes from the Akku index** (ADR-0011), but the server,
  for now (ADR-0012, below). `Akku.manifest`'s `depends` names each one, and `Akku.lock`
  pins each one's archive and sha256:
  - chez-http-server, now 0.12.0, from its submodule, and what it brings: chez-libuv,
    now 0.11.0;
    chez-httparse, now 0.6.0; chez-uri, now 0.9.0; and byte-machine, now 0.9.0, the
    path's one byte-machine, which jsonparse runs on too;
  - chez-websocket, now 0.6.0, for `(circuit websocket)`;
  - hashing, now 1.4.0, for `(circuit session)` (ADR-0008);
  - jsonparse, now 0.2.0, for `(circuit json)` (ADR-0010).

  chez-srfi, now 0.0.0-akku.291.5219353, a development dependency, gives the suites
  SRFI-64. No dependency is a submodule.
- **`akku lock` writes `Akku.lock`,** never a hand. `make lock` runs it on the host on
  Akku 1.2.0, as `scripts/akku-tool.lock` pins it and `make akku-deps` fetches it.
  `make check-akku-lock`, on the host and in CI, fails unless the lock is what `akku lock`
  makes of the manifest against today's index, so a new release that a range admits
  fails it until the lock moves (ADR-0011).
- **`make fetch`, on the host, fetches each tree as the lock pins it,** its sha256
  checked:
  - hashing goes into `vendor/akku`, on the library path last;
  - the others go into `vendor/akku-trees/<name>`. The path takes each one's `src/`, in
    the Makefile's order, with two exceptions: chez-libuv's comes from its copy (below),
    and chez-srfi's libraries are linked into `build/scheme-libs` by `make deps`.

  Both are git-ignored and kept by `make clean`. `make deps` never fetches, and fails
  without a tree, or on another than the lock's. `make check-pins` holds each tree to its
  archive, an edit included. Both fail unless `Akku.lock` pins exactly hashing,
  chez-cmark-gfm, the Makefile's `AKKU_TREES` and its `AKKU_EXCEPTED`, each once, so a lock move that adds or
  drops a package changes the Makefile on the same commit. Make itself stops on a tree
  directory, or a library path entry under `vendor/akku-trees`, that `AKKU_TREES`
  doesn't name. `tests/check-pins.sh` holds all of it (ADR-0011).
- **chez-http-server is a git submodule, `vendor/chez-http-server`, at `SERVER_PIN`,**
  v0.12.0's commit written in full, until the Akku index has that release and a
  chez-websocket whose range admits it (provisional, ADR-0012). `Akku.manifest` and
  `Akku.lock` stay what Akku makes of them: the lock still pins the server at 0.11.0,
  which nothing fetches, and the Makefile's `AKKU_EXCEPTED` names it, so the lock checks
  count it. `SERVER_VERSION` names the release, 0.12.0. `make fetch` clones the
  submodule, and `make deps`, without git, fails unless its `Akku.manifest` names
  `SERVER_VERSION`. `make check-pins`, which needs git for it, fails unless its HEAD,
  its gitlink and its tag `v` and `SERVER_VERSION` are `SERVER_PIN`, and it holds no
  change. `tests/check-pins.sh` holds both on a fake submodule (ADR-0012).
- **chez-libuv's shim is built by `make deps` in a copy, `build/chez-libuv`,** whose
  `src/` is on the path, so the fetched tree stays its archive. `make deps` copies it
  again whenever it differs from the tree by more than its build's two products,
  `build/` and `src/libuv/private/config.sls`, and `make check-pins` fails on such a
  copy (ADR-0011).
- **A move of the lock is tried first.** circuit's suites, the gate and the site pass on
  it, and so do hashing's own suites and circuit's rows holding RFC 4231's cases through
  it, before it lands. On the same commit, the docs' links into a sibling move to the tag
  of the version the lock pins, and this section's `<package>, now <version>` lines to
  the lock's versions, the server's to its submodule's while it is one:
  `tests/test-reference.sps` holds both (ADR-0008, ADR-0011, ADR-0012).
- **chez-cmark-gfm, the docs site's renderer, is pinned by `Akku.lock`**, a development
  dependency alone: nothing under `src/` and no `tests/test-*.sps` imports it.
  `make site-deps` fetches it on the host (ADR-0003).
- **circuit is not installed through Akku yet:** `.akkuignore` keeps its own libraries
  out of `akku install`. Publishing it is a slice of its own (ADR-0011).

## Tooling

- **On a Guix host, every build and test runs through `scripts/guix-env`.** The container
  has no network and no git: `make fetch`, `make akku-deps`, `make lock`,
  `make check-akku-lock`, and, while the server is a submodule, `make check-pins` and
  `make check-site-deps` run on the host, all but `make lock` in CI too, and `make deps`
  never fetches (ADR-0002, ADR-0011, ADR-0012).
- **`make check-guix` must pass after any change to `channels.scm`, `manifest.scm` or the
  `guix-env` scripts** (ADR-0002's consequences, AGENTS.md).
- **`make check-site` gates `docs/`**: CI runs it on every pull request, on both
  architectures, and the Pages workflow before each deploy (AGENTS.md).

## The contract

- **A handler is `Req -> Res`; middleware is `Handler -> Handler`.** No callbacks, futures
  or answer sum in circuit's API (ADR-0004).
- **The adapter answers every request with `awaiting`**, and the thunk answers a response
  or a switch, never a reader: the app reads its body through the server's
  `body-input-port`, on the thunk's coroutine. No option calls an app in place (ADR-0004).
- **The server's waits are the one async model.** Circuit defines no async primitive
  (ADR-0004).

## Names and libraries

- **Requests are `req`, responses `res`**: `req-path`, `make-res`, `res-status` and so on.
  The adapter's entry is `run-server`, its handler maker `circuit->handler` (ADR-0005).
- **No circuit export names a binding `(http-server)` exports**, except the server's waits,
  conditions, transport procedures and `awaiting` that `(circuit http-server)` re-exports
  as the same bindings (ADR-0005).
- **Middleware's data on a request goes under unique keys** from `make-req-key`, read with
  `req-ref` and set with `req-set`, and a handler's data on a response under keys from
  `make-res-key`, read with `res-ref` and set with `res-set`. Each side refuses the other's
  keys, and every response helper keeps them (ADR-0005).
- **The core is plain R6RS.** Only `(circuit http-server)` and `(circuit middleware waits)`,
  and the worker's shell (under "The worker" below),
  may import the server's libraries, never `(http-server private ...)`, and they take from
  `(chezscheme)` only through `(only (chezscheme) name ...)`, each name on the audit's
  allowlist for that library: for the first two `getenv`, `port-has-port-length?`,
  `port-length`, `real-time`, `display-condition`, `print-record` and `parameterize`
  today, and for the shell its own thirteen. Every file under
  `src/` begins with the line `#!r6rs` and holds `#!` nowhere else. `make check-imports`
  holds it, and `make test` runs it once `src/` exists (ADR-0006).
- **Only `(circuit session)` may import a `hashing` library: `(hashing sha-2)` alone,
  through `only`.** `(hashing sha-2)`, as Chez resolves it from `vendor/akku`, and the
  libraries it imports, import `(rnrs ...)` but `(rnrs eval)`, `(hashing fixnums)` and
  `(hashing hmac)` alone, and no other directory on the library path holds a `hashing`.
  `make check-imports` holds it (ADR-0006, ADR-0008).
- **Only `(circuit json)` may import a `jsonparse` library: `(jsonparse easy)` alone,
  through `only`.** `(jsonparse easy)`, as Chez resolves it from byte-machine's `src/`
  and jsonparse's, in the path's order, and the libraries it imports, import `(rnrs ...)` but `(rnrs eval)`,
  jsonparse's own libraries, `(generated jsonparse)`, and byte-machine's runtime and its
  two private libraries alone, and no other directory on the library path holds a
  `jsonparse`, a `generated/jsonparse` or a `byte-machine`. `make check-imports` holds
  it (ADR-0006, ADR-0009).
- **Only `(circuit websocket)` may import `(websocket)`, chez-websocket's facade**, which
  imports the server. No circuit library imports any other `(websocket ...)` library,
  nor `(circuit websocket)`, and `(circuit websocket)` imports neither `(chezscheme)` nor
  the server's libraries. `make check-imports` holds it (ADR-0006).

## The worker

These rules are from ADR-0013, and the worker's design holds them in full. The worker
lands in slices W1 to W3. W2 amended ADR-0006 and the audit for the import rules.

- **Three libraries.**
  - `(circuit worker machine)` is pure, plain R6RS and internal.
  - `(circuit worker shell)` is internal. It imports `(http-server)` only through an
    `only` naming some of `await-outside`, `deadline-passed?` and `client-closed?`, and
    takes from `(chezscheme)`, through `only`, thirteen thread, lock, condition,
    interrupt and thread-parameter names on an allowlist of its own, which no other
    library may take.
  - `(circuit worker)` is public, and imports the shell. It imports neither
    `(chezscheme)` nor a server or `(websocket ...)` library.

  No other library imports either one. `make check-imports`' rules (b), (d) and (q) hold
  it (ADR-0006 as ADR-0013 amends it).
- **Every decision about jobs, threads and the queue is in the machine's `step`, under
  one mutex.** Only the broken worker and the double's mark are the shell's own, and
  real-thread rows check those. The shell carries out
  `step`'s effects outside the lock, and follows the design's rules R1 to R12. The rows
  of the design's §4.2 are data in the suite, and every row is driven.
- **No `guard` around a job, a set-up, a tear-down or a wait.**
  - A job runs under a two-layer `with-exception-handler` catch.
  - `worker-call` sees abandonment through a pass-through handler.
  - A `guard` leaves and re-enters a job's `dynamic-wind` when it lets a warning
    through.
- **A job whose caller left before it began never runs.** `worker-stop!` refuses
  every job not yet begun, waits for the running ones, and joins every thread.
- **Each mutant in the design's §8.8 is seen to fail its layer** before that layer is
  accepted (ADR-0013).
- **The explorer runs in `make test`, and its larger worlds in `make
  check-worker-model`,** which CI runs on amd64 alone, since the machine is pure. Both
  fail unless every row of the table fires, and unless each configuration reaches its
  floor of worlds (ADR-0013).

## Cost

- **`make gate`'s held gates bind**: circuit's own work over the server's `awaiting` path
  at most 384 B a GET and 352 B a POST (G3); one `req-set` at most 88 B, and five at most
  440 B (G4); the catch helper over the app, with nothing raised, at most 512 B, with a
  park and without (G5); a 6-byte port body over the same bytes as a bytevector at most
  384 B (G7); `wrap-log`'s own work, over the app registering a no-op `req-on-done!`, at
  most 384 B (G8 own); `wrap-timeout` over the app, its deadline never passing, at most
  768 B, with a park and without (G9); the router's own work, at most 128 B a word route,
  256 B a one-parameter route and 64 B a path no route takes (G10); the worker machine's
  own work for one job, a call, a next and an end through `step` on one thread, at most
  512 B (G11); `wrap-busy` over the app, with nothing raised, at most 512 B, with a park
  and without (G12). CI fails over any of them (ADR-0007).
