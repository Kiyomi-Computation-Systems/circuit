# ADR-0011: Every dependency comes from Akku

- **Status:** Accepted, 2026-11-20, on the owner's answers the same day
  ([the design](../2026-11-20-akku-dependencies-design.md)'s §8):
  - the lock check runs on the host and in CI;
  - chez-srfi akku.291 was evaluated, and is locked;
  - `make fetch` replaces `make submodules`;
  - publishing circuit on Akku is a slice of its own;
  - after the review, circuit runs the newest release that each range admits, not the
    combination each sibling's own lock was tested on ("Accept, and record it").
- **Date:** 2026-11-20
- **Supersedes:**
  - [ADR-0003](0003-chez-http-server-is-a-submodule-pinned-at-a-release-tag.md)'s items 1
    to 6 and 8. Its item 7, chez-cmark-gfm pinned by `Akku.lock` for the site, stands.
  - [ADR-0010](0010-jsonparse-comes-from-akku-on-the-servers-byte-machine.md)'s items 3
    and 4. Its item 2 stands, under `make fetch`.
- **Scope:** how every dependency reaches the build, the container, CI and an app
- **Related:** [ADR-0002](0002-builds-and-tests-run-in-a-pinned-guix-container-with-no-network.md),
  [ADR-0006](0006-only-the-adapter-and-middleware-waits-import-the-server.md),
  [ADR-0008](0008-hashing-from-akku-is-the-first-runtime-dependency.md),
  [ADR-0009](0009-jsonparse-is-a-submodule-on-the-servers-byte-machine.md)

## Context

Until now, chez-http-server and chez-websocket were submodules, and circuit used the pins
the server carries (ADR-0003). Since 2026-11-19 the Akku index lists the server at 0.11.0
and chez-websocket at 0.6.0, and ADR-0003 had waited for both.

Read on 2026-11-20:

- **Every package circuit would lock is on the index.** Each archive's sha256 matched the
  index. Each archive held the same files as `git archive` of the commit circuit's path
  used:
  - chez-http-server 0.11.0, `SERVER_PIN`;
  - chez-libuv 0.11.0, chez-httparse 0.6.0 and chez-uri 0.9.0, each where the server
    carried it;
  - byte-machine 0.9.0, chez-httparse's;
  - chez-srfi akku.181, the server's.
- **chez-websocket 0.6.0 changes no library** from 0.5.2, the version circuit pinned.
- **chez-srfi akku.291, its newest release, leaves what circuit loads unchanged.**
  `(srfi :1)` and `(srfi :64)` are the only SRFIs circuit's paths import. In their
  import closure, the files Chez loads are akku.181's, byte for byte; the four that
  differ are for Loko and Ypsilon.
- **Akku 1.2.0's `akku lock`** resolves the manifest below to exactly those versions, ten
  packages with chez-cmark-gfm. On the old manifest it gave the old lock's four entries,
  laid out differently.
- **Guix's Akku is 1.1.0,** which knows only the archive's old signing key. jsonparse
  runs 1.2.0 from its release tarball, pinned by sha256.
- **chez-libuv's `make build` writes the shim and `src/libuv/private/config.sls` into its
  own tree.** Its Akku install hook writes `config.sls` there too, but into Akku's copy
  under `.akku/src`.

## Decision

1. **`Akku.manifest`'s `depends` names chez-http-server `^0.11.0`, chez-websocket
   `^0.6.0`, hashing `^1.4.0` and jsonparse `^0.2.0`.** Its `depends/dev` names
   chez-cmark-gfm `^2.0.0` and chez-srfi `^0.0.0-akku.291.5219353`, for the suites'
   SRFI-64.
2. **`akku lock` writes `Akku.lock`, on Akku 1.2.0.**
   - `scripts/akku-tool.lock` pins Akku 1.2.0's tarball by sha256;
   - `make akku-deps`, on the host, fetches it into `build/akku-tool/`;
   - `scripts/akku` runs it from source on `$CHEZ`, with its data and cache under
     `build/akku-tool/`;
   - `make lock`, on the host, runs `akku update`, then `akku lock`;
   - `make check-akku-lock`, on the host and in CI, runs `akku update`, then `akku lock`
     on a copy of the manifest. It fails unless every token of each project, symbols and
     strings alike, is `Akku.lock`'s, in order; layout and comments don't count. It fails
     without Akku, rather than skipping. `scripts/akku` unsets `AKKU_SETTINGS`, under
     whose `no-network` `akku update` would keep the old index.
3. **`make fetch`, on the host, replaces `make submodules`.** By `scripts/fetch-akku-lock`,
   it fetches hashing into `vendor/akku`, and every other locked package, chez-srfi
   included, into `vendor/akku-trees/<name>`. Each tree's `src/` is on the library path,
   in the order the submodules' were, with two exceptions: chez-libuv's comes from its
   copy (item 5), and chez-srfi's libraries are linked into `build/scheme-libs`, as the
   submodule's were. Both directories are git-ignored and kept by
   `make clean`. The submodules, `.gitmodules`, `SERVER_PIN` and `WEBSOCKET_PIN` are gone.
4. **The lock's byte-machine is the path's one.** Akku solved it for every package that
   names it: chez-httparse, chez-uri, the server and jsonparse.
5. **chez-libuv's shim is built in a copy.** `make deps` copies chez-libuv's tree to
   `build/chez-libuv` and builds it there, and the copy's `src/` is on the path. The
   fetched tree stays its archive. `make deps` copies it again whenever it differs from
   the tree by more than its build's two products, and `make check-pins` fails on such a
   copy, an edit to the copy included.
6. **`make check-pins` holds every fetched tree to its archive** by
   `scripts/fetch-akku-lock --check`, an edit included. It no longer needs git.
   `make deps` never fetches, and fails without a tree, or on another than the lock's.
   Both fail unless `Akku.lock` pins exactly hashing, chez-cmark-gfm and the Makefile's
   `AKKU_TREES`, each once. Make stops when a tree directory, or a library path entry
   under `vendor/akku-trees`, names a package `AKKU_TREES` doesn't.
   `tests/check-pins.sh` runs the real targets on fake trees and a fake lock to hold
   this. CI runs `make check-pins` after the tests and the gate, so it also holds that
   they wrote nothing into a tree or the copy.
7. **The records follow the lock.**
   - The docs' links into a sibling name the tag of the version the lock pins.
   - The global constraints name each locked package's version but chez-cmark-gfm's,
     once each, as `<package>, now <version>`.
   - `tests/test-reference.sps` holds both to `Akku.lock`.
8. **A move of the lock is tried first.** circuit's suites, the gate, the site, and
   hashing's own suites pass on it before it lands.

## Consequences

- **The libraries on the path are the bytes they were,** apart from chez-websocket's and
  chez-srfi's, in which nothing circuit loads changed. So the move changes no behaviour
  and no cost.
- **circuit no longer runs only the combination each sibling was tested on.** As
  submodules, circuit ran the commits the server carried, and chez-websocket on
  circuit's own server. Now `akku lock` takes the newest release each range admits, so
  a chez-libuv 0.11.1 would put circuit on a libuv that the server's own lock, at 0.11.0,
  never tested. The owner chose this on 2026-11-20 over a check holding circuit's lock
  to each sibling's, which would keep CI red until every sibling had released on the
  new version. A move is tried on circuit's suites before it lands, and each sibling's
  own lock check turns red on the same release, so each one tests it in turn. An app
  that installs circuit from Akku will get the same newest combination anyway. On
  2026-11-20 the server's, chez-websocket's and jsonparse's own locks agree with
  circuit's on every project they share.
- **A sibling's release that a range admits turns CI red** until `make lock` moves the
  lock and the move is tried. That's the signal to take it. For chez-srfi, taking a
  release means checking its SRFI-1 and SRFI-64 closure again: its `main` has a commit
  from 2026-11-17 that isn't on Akku yet.
- **An older checkout deletes `vendor/chez-http-server`, `vendor/chez-websocket` and their
  `.git/modules/vendor/` directories, then runs `make fetch`.** `.gitignore` keeps the
  old directories out of `git add`.
- **`make check-pins` could run in the container,** since it needs no git now. It runs on
  the host and in CI, as before.
- **circuit is still not installed through Akku.** `.akkuignore` keeps its own libraries
  out of `akku install`. ADR-0008's condition for publishing circuit is met, and
  publishing it is a slice of its own.
