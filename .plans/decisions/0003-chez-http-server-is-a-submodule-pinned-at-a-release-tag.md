# ADR-0003: chez-http-server is a submodule pinned at a release tag

- **Status:** Accepted
- **Date:** 2026-10-25
- **Amended:** 2026-10-26: the pin moved to v0.9.0 (`d928e41`), and the server's package now
  installs the test host circuit's tests use; 2026-10-28, in slice 6c: chez-websocket is a
  second submodule, pinned at v0.4.0 (`4456814`), its own server pin held to `SERVER_PIN`
  and not cloned (item 6; the slice 6 design §6); 2026-10-29: the pins moved together to
  the server's v0.9.1 (`b7381a0`) and chez-websocket's v0.4.1 (`579c118`), on one commit;
  2026-10-30: the pins moved together again, to the server's v0.10.0 (`5c16f64`) and
  chez-websocket's v0.5.1 (`4b70f22`), and chez-cmark-gfm, which renders the docs site, is
  a development dependency that `Akku.lock` pins (item 7); 2026-11-06, in slice 10b: `Akku.manifest` names its first
  `depends`, hashing, which the same lock pins and `make submodules` fetches into
  `vendor/akku` (item 7, [ADR-0008](0008-hashing-from-akku-is-the-first-runtime-dependency.md));
  2026-11-06, after slice 10b: `make check-pins` holds `vendor/akku` too (item 4);
  2026-11-10, in slice 11: jsonparse is a third submodule, for `(circuit json)`, its own
  byte-machine pin held to chez-httparse's and not cloned (item 8,
  [ADR-0009](0009-jsonparse-is-a-submodule-on-the-servers-byte-machine.md))
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
   v0.8.0 (`a996eef`) first, v0.9.0 (`d928e41`) from 2026-10-26, v0.9.1 (`b7381a0`) from
   2026-10-29, v0.10.0 (`5c16f64`) since 2026-10-30. `SERVER_PIN` in the Makefile names the
   same commit, the tag's commit and not the tag object.
2. **Circuit uses the pins the server carries**, through the server's checkout. It clones
   none of them itself and pins none of them itself.
3. **`make submodules`, on the host, clones the server and what the build needs**: chez-libuv,
   uriparse, chez-srfi, and chez-httparse with byte-machine. Not vtest2, nor chez-libuv's own
   vendored libuv.
4. **`make check-pins`, on the host and in CI, holds them**: the gitlink and the checkout at
   `SERVER_PIN`, each pin the server carries where the server's tree records it, and no
   local edits to tracked files in any of them. Since 2026-11-06 it holds `vendor/akku`
   too, by `scripts/fetch-akku-lock --check`, which downloads nothing: hashing's tree
   records the lock's sha256 and is its archive under `dl/`, with that sha256, unpacked.
5. **No Akku dependency on the server** while it isn't on the index.
6. **chez-websocket is a submodule at `vendor/chez-websocket`, pinned at a release tag**,
   v0.4.0 (`4456814`) first, v0.4.1 (`579c118`) from 2026-10-29, v0.5.1 (`4b70f22`) since
   2026-10-30, for `(circuit websocket)`. `WEBSOCKET_PIN` names the same commit.
   It pins a server of its own, which circuit doesn't clone: circuit's checkout is the one
   on the library path. So chez-websocket's gitlink for its server must equal
   `SERVER_PIN`. `make submodules` clones chez-websocket alone, none of its submodules;
   `make check-pins` holds its gitlink and its checkout at `WEBSOCKET_PIN`, its server's
   gitlink at `SERVER_PIN`, and no local edits in it. No Akku dependency on it either.
7. **chez-cmark-gfm, which renders `docs/` into the docs site, is pinned by `Akku.lock`**,
   as the server and chez-websocket pin theirs: a development dependency of `Akku.manifest`.
   No library under `src/` and no `tests/test-*.sps` imports it.
   `make site-deps`, on the host, downloads the archive the lock names and checks its
   sha256 (`scripts/fetch-akku-lock`), or takes an `akku install` tree when there is one.
   Since slice 10b, `Akku.manifest`'s `depends` names hashing, circuit's one runtime
   dependency from the index, which the same lock pins and `make submodules` fetches into
   `vendor/akku` by the same script (ADR-0008).
8. **jsonparse is a submodule at `vendor/jsonparse`, pinned at a release tag**, v0.1.0
   (`a939f31`) since 2026-11-10, for `(circuit json)` (ADR-0009). `JSONPARSE_PIN` names
   the same commit. It pins a byte-machine of its own, which circuit doesn't clone: the
   server's, under chez-httparse, is the one on the library path. So jsonparse's
   gitlink for its byte-machine must equal chez-httparse's. `make submodules` clones
   jsonparse alone, none of its submodules; `make check-pins` holds its gitlink and its
   checkout at `JSONPARSE_PIN`, its byte-machine's gitlink at chez-httparse's, and no
   local edits in it. No Akku dependency on it either: it isn't on the index.

## Consequences

- **Moving the pin is one commit**: the gitlink and `SERVER_PIN` together. So is moving
  chez-websocket's: its gitlink and `WEBSOCKET_PIN`.
- **The server's pin moves only with a chez-websocket release on the same server**, or
  `make check-pins` fails: circuit runs chez-websocket on circuit's server, not its own.
- **A server pin that moves chez-httparse's byte-machine moves jsonparse's too**, to a
  jsonparse release on the same byte-machine, on the same commit, or `make check-pins`
  fails.
- **A pin move brings the server's pins along**, and `make check-pins` holds them where the
  server records them.
- **`Akku.manifest` names what the lock pins:** hashing in `depends`, and chez-cmark-gfm,
  for the site, in `depends/dev`. It names circuit's version, which a release moves with
  `CHANGELOG.md`, and `.akkuignore` keeps circuit's own files out of `akku install`.
- **Circuit can't be installed with Akku as a whole** until the server is on the index. Until
  then a consumer takes circuit's `src/` and the server's tree as this repository does.
  Publishing the server is an ask on the server, not yet filed.
