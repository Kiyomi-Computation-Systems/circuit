# ADR-0010: jsonparse comes from Akku, on the server's byte-machine

- **Status:** Accepted, 2026-11-15, on the owner's answers the same day: wait for the
  server on byte-machine 0.9.0, then move the three pins together with jsonparse from
  Akku; unpack its tree in a second directory; hold the server's byte-machine to the lock.
  Items 3 and 4 superseded on 2026-11-20 by
  [ADR-0011](0011-every-dependency-comes-from-akku.md): the lock's byte-machine is the
  path's one, and `make fetch` replaces `make submodules` in item 2.
- **Date:** 2026-11-15
- **Supersedes:** [ADR-0009](0009-jsonparse-is-a-submodule-on-the-servers-byte-machine.md)'s
  items 1, 2 and 4. Its item 3, what `(circuit json)` imports and the audit's rules (n),
  (o) and (p), stands.
- **Scope:** how jsonparse, and the byte-machine it runs on, reach the build, the
  container, CI and an app
- **Related:** [ADR-0003](0003-chez-http-server-is-a-submodule-pinned-at-a-release-tag.md),
  [ADR-0008](0008-hashing-from-akku-is-the-first-runtime-dependency.md)

## Context

jsonparse 0.2.0 is on the Akku index, depending on byte-machine `^0.9.0`. v0.1.0, the
submodule ADR-0009 pinned, never was. chez-http-server v0.11.0 (`f1d2220`) moves to
chez-httparse v0.6.0 on byte-machine v0.9.0 (`fdd4da0`), and chez-websocket v0.5.2
(`9a8563e`) to that server. The index has the server only at 0.9.1, on byte-machine
`^0.8.0`, and no chez-websocket, so both stay submodules (ADR-0003).

Read on 2026-11-15: the index's jsonparse 0.2.0 archive is its v0.2.0 tag (`641c73d`) less
`AGENTS.md` and `.plans/`; that tag's byte-machine gitlink is `fdd4da0`, chez-httparse
v0.6.0's; and byte-machine's runtime and its two private libraries are byte-identical in
0.8.0 and 0.9.0. jsonparse 0.2.0's generated parser imports `(rnrs)` and
`(byte-machine runtime)` alone.

The archive's libraries are under its `src/`, and `vendor/akku`, which is on the library
path for hashing, may hold no directory named `jsonparse` (the audit's rule (p)).

## Decision

1. **`Akku.manifest` names `("jsonparse" "^0.2.0")` in `depends`,** and `Akku.lock` pins
   its archive and sha256, and byte-machine 0.9.0's, as `akku lock` writes them.
2. **`make submodules` fetches jsonparse into `vendor/akku-trees/`,** on the host, by
   `scripts/fetch-akku-lock` as it fetches hashing. `vendor/akku-trees/` is git-ignored,
   kept by `make clean`, and not on the library path: only `vendor/akku-trees/jsonparse/src`
   is, where `vendor/jsonparse/src` was. `make deps` fails, naming `make submodules`,
   without it or on another than the lock's, and `make check-pins` holds the tree to its
   archive.
3. **The lock's byte-machine is never fetched.** The path's one byte-machine is the
   server's, under chez-httparse, and `make check-pins` fails unless its version is the
   one `Akku.lock` pins and in the range jsonparse's tree names in its `Akku.manifest`,
   `^0.9.0` for 0.2.0, read as Akku reads a caret. The second check was added after the
   review: the first alone passed a lock whose byte-machine moved without its jsonparse.
4. **A move of the server that moves its byte-machine moves the lock's byte-machine, and a
   jsonparse on it, on the same commit,** or `make check-pins` fails. A move is tried
   first: circuit's suites pass on it before it lands.
5. **`vendor/jsonparse` and `JSONPARSE_PIN` are gone.** The docs' links into jsonparse
   name the tag of the version the lock pins.

## Consequences

- **circuit runs jsonparse 0.2.0,** whose number and ASCII-string paths are faster, on the
  same runtime bytes as before. Its API is v0.1.0's, and its docs now promise what
  `read-json` does on a port whose bytes are still coming; circuit's rows still hold
  what `wrap-json-body` relies on.
- **An older checkout runs `make submodules` again** to fetch jsonparse. Its
  `vendor/jsonparse` is no longer on the path and can be deleted.
- **circuit still can't be installed with Akku as a whole** while the index lacks
  chez-websocket, and the server at `SERVER_PIN`'s release. Once both are there, the
  manifest names them, and Akku installs one byte-machine for all three.
