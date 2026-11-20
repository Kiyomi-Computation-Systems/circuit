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

- **Every runtime dependency comes from the Akku index** (ADR-0011). `Akku.manifest`'s
  `depends` names each one, and `Akku.lock` pins each one's archive and sha256:
  - chez-http-server, now 0.11.0, and what it brings: chez-libuv, now 0.11.0;
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
  chez-cmark-gfm and the Makefile's `AKKU_TREES`, each once, so a lock move that adds or
  drops a package changes the Makefile on the same commit. Make itself stops on a tree
  directory, or a library path entry under `vendor/akku-trees`, that `AKKU_TREES`
  doesn't name. `tests/check-pins.sh` holds all of it (ADR-0011).
- **chez-libuv's shim is built by `make deps` in a copy, `build/chez-libuv`,** whose
  `src/` is on the path, so the fetched tree stays its archive. `make deps` copies it
  again whenever it differs from the tree by more than its build's two products,
  `build/` and `src/libuv/private/config.sls`, and `make check-pins` fails on such a
  copy (ADR-0011).
- **A move of the lock is tried first.** circuit's suites, the gate and the site pass on
  it, and so do hashing's own suites and circuit's rows holding RFC 4231's cases through
  it, before it lands. On the same commit, the docs' links into a sibling move to the tag
  of the version the lock pins, and this section's `<package>, now <version>` lines to
  the lock's versions: `tests/test-reference.sps` holds both (ADR-0008, ADR-0011).
- **chez-cmark-gfm, the docs site's renderer, is pinned by `Akku.lock`**, a development
  dependency alone: nothing under `src/` and no `tests/test-*.sps` imports it.
  `make site-deps` fetches it on the host (ADR-0003).
- **circuit is not installed through Akku yet:** `.akkuignore` keeps its own libraries
  out of `akku install`. Publishing it is a slice of its own (ADR-0011).

## Tooling

- **On a Guix host, every build and test runs through `scripts/guix-env`.** The container
  has no network and no git: `make fetch`, `make akku-deps`, `make lock` and
  `make check-akku-lock` run on the host, all but `make lock` in CI too, and `make deps`
  never fetches (ADR-0002, ADR-0011).
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
- **The core is plain R6RS.** Only `(circuit http-server)` and `(circuit middleware waits)`
  may import the server's libraries, never `(http-server private ...)`, and they take from
  `(chezscheme)` only through `(only (chezscheme) name ...)`, each name on the audit's
  allowlist, `getenv`, `port-has-port-length?`, `port-length`, `real-time`,
  `display-condition`, `print-record` and `parameterize` today. Every file under
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

## Cost

- **`make gate`'s held gates bind**: circuit's own work over the server's `awaiting` path
  at most 384 B a GET and 352 B a POST (G3); one `req-set` at most 88 B, and five at most
  440 B (G4); the catch helper over the app, with nothing raised, at most 512 B, with a
  park and without (G5); a 6-byte port body over the same bytes as a bytevector at most
  384 B (G7); `wrap-log`'s own work, over the app registering a no-op `req-on-done!`, at
  most 384 B (G8 own); `wrap-timeout` over the app, its deadline never passing, at most
  768 B, with a park and without (G9); the router's own work, at most 128 B a word route,
  256 B a one-parameter route and 64 B a path no route takes (G10). CI fails over any of
  them (ADR-0007).
