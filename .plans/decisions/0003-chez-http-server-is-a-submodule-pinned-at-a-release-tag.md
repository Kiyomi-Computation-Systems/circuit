# ADR-0003: chez-http-server is a submodule pinned at a release tag

- **Status:** Accepted. Items 1 to 6 and 8 superseded on 2026-11-20 by
  [ADR-0011](0011-every-dependency-comes-from-akku.md): every dependency comes from the
  Akku index, and no dependency is a submodule. Item 7 stands. The lines below are its
  history up to then.
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
  [ADR-0009](0009-jsonparse-is-a-submodule-on-the-servers-byte-machine.md)); 2026-11-15:
  the pins moved together to the server's v0.11.0 (`f1d2220`) and chez-websocket's v0.5.2
  (`9a8563e`), on byte-machine v0.9.0, and jsonparse left `vendor/` for the Akku index
  (items 5 and 8, [ADR-0010](0010-jsonparse-comes-from-akku-on-the-servers-byte-machine.md))
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
   2026-10-29, v0.10.0 (`5c16f64`) from 2026-10-30, v0.11.0 (`f1d2220`) since 2026-11-15.
   `SERVER_PIN` in the Makefile names the same commit, the tag's commit and not the tag
   object.
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
   Since 2026-11-15 it holds jsonparse's tree in `vendor/akku-trees` the same way, and
   the server's byte-machine to the version the lock pins and to the range jsonparse's
   tree names (ADR-0010).
5. **No Akku dependency on the server** while the index doesn't have it at `SERVER_PIN`'s
   release: on 2026-11-15 it has 0.9.1.
6. **chez-websocket is a submodule at `vendor/chez-websocket`, pinned at a release tag**,
   v0.4.0 (`4456814`) first, v0.4.1 (`579c118`) from 2026-10-29, v0.5.1 (`4b70f22`) from
   2026-10-30, v0.5.2 (`9a8563e`) since 2026-11-15, for `(circuit websocket)`.
   `WEBSOCKET_PIN` names the same commit. It pins a server of its own, which circuit
   doesn't clone: circuit's checkout is the one on the library path. So chez-websocket's
   gitlink for its server must equal `SERVER_PIN`. `make submodules` clones chez-websocket alone, none of its submodules;
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
8. **jsonparse was a submodule at `vendor/jsonparse`**, v0.1.0 (`a939f31`) from
   2026-11-10 to 2026-11-15, for `(circuit json)` (ADR-0009), its byte-machine's gitlink
   held to chez-httparse's. Since 2026-11-15 it comes from the Akku index, 0.2.0, which
   `Akku.lock` pins and `make submodules` fetches into `vendor/akku-trees` by the same
   script as hashing, and `make check-pins` holds the server's byte-machine to the
   version the lock pins (ADR-0010).

## Consequences

- **Moving the pin is one commit**: the gitlink and `SERVER_PIN` together. So is moving
  chez-websocket's: its gitlink and `WEBSOCKET_PIN`.
- **The server's pin moves only with a chez-websocket release on the same server**, or
  `make check-pins` fails: circuit runs chez-websocket on circuit's server, not its own.
- **A server pin that moves chez-httparse's byte-machine moves `Akku.lock`'s byte-machine
  and jsonparse too**, to a jsonparse release whose range takes it, on the same commit,
  or `make check-pins` fails (ADR-0010).
- **A pin move brings the server's pins along**, and `make check-pins` holds them where the
  server records them.
- **`Akku.manifest` names what the lock pins:** hashing and jsonparse in `depends`, and
  chez-cmark-gfm, for the site, in `depends/dev`. The lock also pins byte-machine, which
  `akku lock` adds for jsonparse and the build never fetches. It names circuit's version, which a release moves with
  `CHANGELOG.md`, and `.akkuignore` keeps circuit's own files out of `akku install`.
- **Circuit can't be installed with Akku as a whole** until the index has the server at
  `SERVER_PIN`'s release, and chez-websocket. Until then a consumer takes circuit's `src/`
  and the server's tree as this repository does. On 2026-11-15 the index has the server at
  0.9.1, and no chez-websocket.
