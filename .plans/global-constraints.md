# Global constraints

These rules bind every task brief. Each one cites the decision record in
[decisions/](decisions/) it comes from. If a rule here and its record disagree, the record
wins and this file gets fixed. Rules from a record that is still Proposed are marked
provisional. They bind until that record is accepted or amended.

## Platforms and versions

- **Platforms:** Linux and macOS, on amd64 and arm64. No Windows code paths or CI
  (ADR-0001). CI runs on Linux only (AGENTS.md).
- **Chez:** 10.4.1 or later, threaded: chez-http-server's floor (ADR-0002).
- **libuv:** 1.48.0 or later, which pkg-config can see, and a C compiler, for chez-libuv's
  shim (ADR-0002).

## Dependency

- **chez-http-server is a submodule at `vendor/chez-http-server`, pinned at a release
  tag**, now v0.9.0 (`d928e41`). Circuit uses the pins the server carries and pins none
  itself. Move the gitlink and `SERVER_PIN` on one commit, `SERVER_PIN` naming the tag's
  commit; `make check-pins` holds them (ADR-0003).
- **No Akku dependency on the server** while it isn't on the Akku index (ADR-0003).

## Tooling

- **On a Guix host, every build and test runs through `scripts/guix-env`.** The container
  has no network and no git: `make submodules` and `make check-pins` run on the host and
  in CI, and `make deps` never fetches (ADR-0002).
- **`make check-guix` must pass after any change to `channels.scm`, `manifest.scm` or the
  `guix-env` scripts** (ADR-0002's consequences, AGENTS.md).

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
  `req-ref` and set with `req-set` (ADR-0005).
- **The core is plain R6RS.** Only `(circuit http-server)` and `(circuit middleware waits)`
  may import the server's libraries, never `(http-server private ...)`, and they take from
  `(chezscheme)` only through `(only (chezscheme) name ...)`, each name on the audit's
  allowlist, `getenv`, `port-has-port-length?`, `port-length`, `real-time` and
  `display-condition` today. Every file under
  `src/` begins with the line `#!r6rs` and holds `#!` nowhere else. `make check-imports`
  holds it, and `make test` runs it once `src/` exists (ADR-0006).

## Cost

- **`make gate`'s held gates bind**: circuit's own work over the server's `awaiting` path
  at most 384 B a GET and 352 B a POST (G3); one `req-set` at most 88 B, and five at most
  440 B (G4); the catch helper over the app, with nothing raised, at most 512 B, with a
  park and without (G5); a 6-byte port body over the same bytes as a bytevector at most
  384 B (G7); `wrap-log`'s own work, over the app registering a no-op `req-on-done!`, at
  most 384 B (G8 own); `wrap-timeout` over the app, its deadline never passing, at most
  768 B, with a park and without (G9). CI fails over any of them (ADR-0007).
