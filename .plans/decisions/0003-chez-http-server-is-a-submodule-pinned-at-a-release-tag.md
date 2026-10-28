# ADR-0003: chez-http-server is a submodule pinned at a release tag

- **Status:** Accepted
- **Date:** 2026-10-25
- **Amended:** 2026-10-26: the pin moved to v0.9.0 (`d928e41`), and the server's package now
  installs the test host circuit's tests use; 2026-10-28, in slice 6c: chez-websocket is a
  second submodule, pinned at v0.4.0 (`4456814`), its own server pin held to `SERVER_PIN`
  and not cloned (item 6; the slice 6 design §6)
- **Scope:** circuit's dependencies
- **Prior art:** chez-websocket, which takes the server the same way
- **Related:** [ADR-0002](0002-builds-and-tests-run-in-a-pinned-guix-container-with-no-network.md)

## Context

Circuit's adapter and `(circuit middleware waits)` import `(http-server)`. The server carries
its own pins as submodules: chez-libuv, chez-httparse (with byte-machine under it),
uriparse, chez-srfi for SRFI-64, and vtest2 for its own tests. Its Akku package leaves out
`tests/`, which at v0.8.0 held the fake shell circuit's tests would have needed; since
v0.9.0 the package installs `(http-server testing)`, the test host they use instead (design
§10). The server isn't on
the Akku index: on 2026-10-25 its page there answered 404, while chez-libuv's,
chez-httparse's, byte-machine's and chez-srfi's answered 200. chez-websocket isn't on it
either, and takes the server as a submodule.

## Decision

1. **The server is a submodule at `vendor/chez-http-server`, pinned at a release tag**,
   v0.8.0 (`a996eef`) first, v0.9.0 (`d928e41`) since 2026-10-26. `SERVER_PIN` in the
   Makefile names the same commit, the tag's commit and not the tag object.
2. **Circuit uses the pins the server carries**, through the server's checkout. It clones
   none of them itself and pins none of them itself.
3. **`make submodules`, on the host, clones the server and what the build needs**: chez-libuv,
   uriparse, chez-srfi, and chez-httparse with byte-machine. Not vtest2, nor chez-libuv's own
   vendored libuv.
4. **`make check-pins`, on the host and in CI, holds them**: the gitlink and the checkout at
   `SERVER_PIN`, each pin the server carries where the server's tree records it, and no
   local edits to tracked files in any of them.
5. **No Akku dependency on the server** while it isn't on the index.
6. **chez-websocket is a submodule at `vendor/chez-websocket`, pinned at a release tag**,
   v0.4.0 (`4456814`), for `(circuit websocket)`. `WEBSOCKET_PIN` names the same commit.
   It pins a server of its own, which circuit doesn't clone: circuit's checkout is the one
   on the library path. So chez-websocket's gitlink for its server must equal
   `SERVER_PIN`. `make submodules` clones chez-websocket alone, none of its submodules;
   `make check-pins` holds its gitlink and its checkout at `WEBSOCKET_PIN`, its server's
   gitlink at `SERVER_PIN`, and no local edits in it. No Akku dependency on it either.

## Consequences

- **Moving the pin is one commit**: the gitlink and `SERVER_PIN` together. So is moving
  chez-websocket's: its gitlink and `WEBSOCKET_PIN`.
- **The server's pin moves only with a chez-websocket release on the same server**, or
  `make check-pins` fails: circuit runs chez-websocket on circuit's server, not its own.
- **A pin move brings the server's pins along**, and `make check-pins` holds them where the
  server records them.
- **Circuit can't be installed with Akku as a whole** until the server is on the index. Until
  then a consumer takes circuit's `src/` and the server's tree as this repository does.
  Publishing the server is an ask on the server, not yet filed.
