# ADR-0003: chez-http-server is a submodule pinned at a release tag

- **Status:** Accepted
- **Date:** 2026-10-25
- **Scope:** circuit's one dependency
- **Prior art:** chez-websocket, which takes the server the same way
- **Related:** [ADR-0002](0002-builds-and-tests-run-in-a-pinned-guix-container-with-no-network.md)

## Context

Circuit's adapter and `(circuit middleware waits)` import `(http-server)`. The server carries
its own pins as submodules: chez-libuv, chez-httparse (with byte-machine under it),
uriparse, chez-srfi for SRFI-64, and vtest2 for its own tests. Its Akku package leaves out
`tests/`, which holds the fake shell circuit's tests need (design §10). The server isn't on
the Akku index: on 2026-10-25 its page there answered 404, while chez-libuv's,
chez-httparse's, byte-machine's and chez-srfi's answered 200. chez-websocket isn't on it
either, and takes the server as a submodule.

## Decision

1. **The server is a submodule at `vendor/chez-http-server`, pinned at a release tag**,
   v0.8.0 (`a996eef`) first. `SERVER_PIN` in the Makefile names the same commit.
2. **Circuit uses the pins the server carries**, through the server's checkout. It clones
   none of them itself and pins none of them itself.
3. **`make submodules`, on the host, clones the server and what the build needs**: chez-libuv,
   uriparse, chez-srfi, and chez-httparse with byte-machine. Not vtest2, nor chez-libuv's own
   vendored libuv.
4. **`make check-pins`, on the host and in CI, holds them**: the gitlink and the checkout at
   `SERVER_PIN`, each pin the server carries where the server's tree records it, and no
   local edits to tracked files in any of them.
5. **No Akku dependency on the server** while it isn't on the index.

## Consequences

- **Moving the pin is one commit**: the gitlink and `SERVER_PIN` together.
- **A pin move brings the server's pins along**, and `make check-pins` holds them where the
  server records them.
- **Circuit can't be installed with Akku as a whole** until the server is on the index. Until
  then a consumer takes circuit's `src/` and the server's tree as this repository does.
  Publishing the server is an ask on the server, not yet filed.
