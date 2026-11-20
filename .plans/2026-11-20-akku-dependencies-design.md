# Design: every dependency from Akku

- **Status:** Draft, 2026-11-20. The owner answered §8 the same day. Nothing is built
  yet. Its decisions become ADR-0011.
- **Scope:** how chez-http-server, chez-websocket and everything the server carries reach
  the build, the container, CI and an app; `Akku.manifest`, `Akku.lock`, `make
  submodules`, `make deps`, `make check-pins`, `make check-imports`'s paths,
  `tests/test-reference.sps`'s pin rows, CI, and the records and docs that describe them.
- **Supersedes, once accepted:** ADR-0003's items 1 to 6 and 8 (item 7, chez-cmark-gfm,
  stands), and ADR-0010's items 3 and 4. ADR-0010's item 2 changes target name. ADR-0008
  and ADR-0009's item 3 stand.

## 1. What changes

circuit stops cloning submodules. Every runtime dependency, and chez-srfi for the tests,
comes from the Akku index:

- `Akku.manifest` names each one;
- `akku lock` writes `Akku.lock`;
- `scripts/fetch-akku-lock` fetches each tree on the host, as it already does for hashing
  and jsonparse.

The libraries on the path stay byte for byte the same (§2), with two exceptions:

- chez-websocket moves from 0.5.2 to 0.6.0, which changes nothing under `src/`;
- chez-srfi moves from akku.181 to akku.291. Its SRFI-1 and SRFI-64, as Chez loads them,
  are unchanged (§2).

## 2. What the index holds

Read on 2026-11-20. The index was last modified on 2026-11-19 at 19:28 GMT.

Each archive's sha256 matched the index. Each archive also held the same files as `git
archive` of the commit circuit's path uses today, with no difference:

| Package | Version | Today's commit | Files |
|---|---|---|---|
| chez-http-server | 0.11.0 | `f1d2220` (`SERVER_PIN`) | 334 |
| chez-websocket | 0.6.0 | `5ccfaa5` (v0.5.2 is pinned today) | 90 |
| chez-libuv | 0.11.0 | `afe79a5`, which the server carries | 323 |
| chez-httparse | 0.6.0 | `46a38cb`, which the server carries | 170 |
| chez-uri | 0.9.0 | `335b0ba`, uriparse, which the server carries | 154 |
| byte-machine | 0.9.0 | `fdd4da0`, under chez-httparse | 215 |
| chez-srfi | 0.0.0-akku.181.7879b52 | `7879b52`, which the server carries | 350 |

- **chez-websocket 0.6.0 changes no library.** Since v0.5.2 it adds only the Akku
  package: its manifest, its lock, `check-akku` and the install docs. It depends on
  chez-http-server `^0.11.0`, and its server gitlink is `f1d2220`.
- **The server's package includes its test host.** Both `(http-server testing)` and
  `(http-server private fake-shell)` are in its `src/`.
- **chez-srfi's row is today's version.** The slice locks akku.291 instead (below).

### The lock, tried

I tried this with Akku 1.2.0: jsonparse's copy, which passes its own sha256 check (see
§3.2), run on the host's Chez 10.4.0 with Akku's data and cache in a scratch directory.

- **Today's lock.** `akku lock` on today's manifest resolves the same four packages, URLs
  and sha256s as today's `Akku.lock`. Only the layout differs.
- **The proposed manifest** (§3.1) resolves to exactly the table's versions: ten packages
  with chez-cmark-gfm.
- **chez-srfi's range decides its version.** An exact range locks `akku.181.7879b52`. A
  caret, `^0.0.0-akku.181.7879b52`, locks `akku.291.5219353`.
- **The lock carries chez-libuv's hook.** chez-libuv's entry has a `scripts` form: a
  pre-install `sh scripts/akku-install`, which `akku install` runs and the fetch script
  doesn't.

### chez-srfi akku.291, evaluated

akku.291 (`5219353`, 2026-10-19) is chez-srfi's latest Akku release. Its archive's sha256
matches the index. It has 445 files against akku.181's 350, and 83 paths differ.

- **What circuit loads is unchanged.** On every path circuit runs, the only SRFIs imported
  are `(srfi :1)` and `(srfi :64)`. Their import closure is `:0 :1 :6 :8 :9 :23 :39 :64`
  and `private/` `check-arg`, `include`, `vanish`, `registry`, `registry-names` and
  `platform-features`. In that closure, four files differ, and all four are for other
  Schemes: `private/include/compat.loko.sls`, `%3a6/basic-string-ports/compat.loko.sls`,
  and `private/platform-features.loko.sls` and `.ypsilon.sls`. Chez never loads those
  extensions. Nothing in the closure was added or removed.
- **hashing's own tests import `(srfi :13)`, `(srfi :14)` and `(srfi :78)`,** and `:13`
  and `:14` changed. circuit's suites never run hashing's tests. Only a hashing lock
  move's trial does (ADR-0008), so the trial in §5 runs them on akku.291 as well.
- **chez-srfi's `main` has a newer commit,** `dd0e4c9` from 2026-11-17, which isn't on
  Akku yet. With a caret range and the lock check in CI (§8), its release turns CI red.
  Taking it means repeating this closure diff.

## 3. Decisions proposed

### 3.1 The manifest

```scheme
(depends ("chez-http-server" "^0.11.0")
         ("chez-websocket" "^0.6.0")
         ("hashing" "^1.4.0")
         ("jsonparse" "^0.2.0"))
(depends/dev ("chez-cmark-gfm" "^2.0.0")
             ("chez-srfi" "^0.0.0-akku.291.5219353"))
```

- **chez-srfi is a caret at akku.291,** like every other range (§8, Q2). The SRFI-1 and
  SRFI-64 that Chez loads from it are akku.181's, byte for byte (§2).
- **The manifest's comment changes.** It no longer says the server and chez-websocket are
  submodules.
- **`.akkuignore` keeps circuit's `src/` out of `akku install`, as today.** Publishing
  circuit on Akku is a later slice (§7).

### 3.2 Akku 1.2.0, for `akku lock`

Guix and its `guix shell akku` have Akku 1.1.0. 1.1.0 knows only the archive's old
signing key, so it stops reading the index once the transition period ends (jsonparse's
ADR-0022). circuit therefore takes jsonparse's setup:

- **`scripts/akku-tool.lock`** pins the Akku 1.2.0 source tarball by sha256 (`c04010db…`).
  Its signature was checked on 2026-11-08 for jsonparse.
- **`make akku-deps`,** on the host, fetches it with `scripts/fetch-akku-lock` into
  `build/akku-tool/`.
- **`scripts/akku`** runs it from source on `$CHEZ`. Akku's data and cache stay under
  `build/akku-tool/`, and nothing under `HOME` is read or written.

Two targets use it:

- **`make lock`, on the host,** runs `akku update`, then `akku lock`, and writes
  `Akku.lock` as Akku writes it. No more hand-written locks.
- **`make check-akku-lock`** is chez-websocket's check:
  - it runs `akku update` first, so that it reads today's index, not the one the last
    run left under `build/akku-tool/`;
  - it runs `akku lock` on a copy of the manifest;
  - it compares each project's name, URL and sha256 with `Akku.lock`'s;
  - it fails on any difference.

  It runs on the host and in CI (§8, Q1). A new release in a range that the index admits
  fails it, until `make lock` is run again. That red is the signal to take the release.

### 3.3 The trees

`make fetch`, on the host, replaces `make submodules`, which is removed (§8, Q3). It runs `fetch-akku-lock`
for each locked runtime package and for chez-srfi:

- **hashing** goes into `vendor/akku`, as today;
- **every other package** goes into `vendor/akku-trees/<name>`, which is git-ignored and
  kept by `make clean`;
- **chez-cmark-gfm** stays under `build/akku` for the site.

The lock's byte-machine is now fetched, and it is the path's one byte-machine: Akku solved
it for every package that names it.

`LIBDIR_LIST` keeps today's order, with the new paths:

```
src
vendor/akku-trees/chez-http-server/src
vendor/akku-trees/chez-websocket/src
build/chez-libuv/src
vendor/akku-trees/chez-httparse/src
vendor/akku-trees/byte-machine/src
vendor/akku-trees/chez-uri/src
vendor/akku-trees/jsonparse/src
build/scheme-libs
vendor/akku
```

### 3.4 chez-libuv builds in a copy

chez-libuv's `make build` writes two things into its own tree: `build/`, which holds the
shim, and `src/libuv/private/config.sls`, which names the shim. In a submodule, git
ignores both. A fetched tree, though, is held to its archive by `diff -r`, so after a
build `make check-pins` would fail on it. Akku's own hook writes `config.sls` too, but
into Akku's copy under `.akku/src`.

So circuit does what Akku does:

- **`make deps`, in the container,** copies `vendor/akku-trees/chez-libuv` to
  `build/chez-libuv`. It copies again whenever the tree's recorded sha256 differs from the
  copy's. Then it runs `make -C build/chez-libuv build` there.
- **`LIBDIRS` takes the copy's `src/`, and `GATE_LIBDIRS` its `tests/`.**
- **`make clean` removes the copy along with `build/`.** Its separate call to chez-libuv's
  `clean` goes.
- **The fetched tree stays its archive,** and `make check-pins` holds it to that archive.

### 3.5 `make check-pins`

It holds every tree to the lock, and nothing else:

- **`fetch-akku-lock --check` runs on each fetched package.** It fails on a missing tree,
  a different sha256, or any edit.
- **Going:** the gitlink checks, the carried pins, chez-websocket's server gitlink, and
  the byte-machine version and caret checks. One byte-machine comes from the lock, and the
  lock is `akku lock`'s solution.
- **It no longer needs git.** It needs tar, xz, diff and sha256sum, which the container
  has, so it can also run there.
- **`make deps` checks each tree's record,** with `--check-record`, as it does today for
  hashing and jsonparse.

### 3.6 `make check-imports`

Only its paths move:

- `--byte-machine` becomes `vendor/akku-trees/byte-machine/src`;
- `LIBRARY_DIRS` takes the new directories.

Rules (n), (o) and (p) stand: one jsonparse, one `generated/jsonparse`, and one
byte-machine on the path. `tests/test-check-imports.sps`'s make rows expect the new
paths.

### 3.7 `tests/test-reference.sps`

- **`pin-specs` goes.** chez-http-server and chez-websocket join `locked-specs`, beside
  jsonparse. Each tree's `Akku.manifest` must give the version in the lock's archive name.
- **The docs' links are held at the lock's version's tag:**
  - the server's 31 stay at `v0.11.0`;
  - chez-websocket's 3 move from `v0.5.2` to `v0.6.0`;
  - jsonparse's 2 stay at `v0.2.0`.
- **The re-export rows read the server's and chez-websocket's references** from their
  trees' `docs/`. The archives hold `docs/`.
- **The records' "now" lines** (the global constraints, and ADR-0003's successor) are
  held to the lock's versions instead of to `SERVER_PIN` and `WEBSOCKET_PIN`. The rows on
  the Makefile's pin comments go, along with the pins.

### 3.8 The submodules go

- **Removed:** `git rm` of `vendor/chez-http-server` and `vendor/chez-websocket`, and of
  `.gitmodules`.
- **`.gitignore`** lists both old directories, as it does `vendor/jsonparse`, so that
  `git add -A` in an older checkout can't add them back.
- **`CHANGELOG.md`** tells an older checkout to delete them, along with
  `.git/modules/vendor/*`.

### 3.9 CI

- **The `linux` job:** `make fetch` and `make check-pins`, then the Chez build as today,
  then `make akku-deps` and `make check-akku-lock`, which run Akku on that Chez, then
  `make test` and `make gate`. There's no submodule step.
- **The `site` job:** `make fetch`, then `make srfi`, which takes chez-srfi from its tree.
- **`pages.yml`:** the same change.
- **The comments** that name submodules are rewritten.

### 3.10 The records and docs

All of these are rewritten for the new layout:

- `docs/installing.md`'s "pinned dependencies" section: every dependency comes from Akku,
  `make fetch` gets them, and Akku can't install circuit yet (§7);
- `README.org`;
- `AGENTS.md`'s Dependencies bullets;
- the global constraints' Dependency section;
- the Makefile's header comment;
- the CI comments.

ADR-0011 records the decisions. ADR-0003 and ADR-0010 get status notes naming what it
supersedes, and the ledger gets its Now entry and close-out.

## 4. What stays

- **The container:** no network and no git. `make deps` never fetches.
- **The Chez floor,** 10.4.1, threaded.
- **libuv's floor,** 1.48.0, found by pkg-config.
- **The cost gate's bounds.** Every library the gate loads is the same bytes, so its
  numbers shouldn't move. The trial (§5) shows whether they do.
- **What each library imports,** and ADR-0006's rules.

## 5. Trial first

Before anything lands, I run circuit's checks on the new layout in a scratch worktree:

- `make test`;
- `make gate`;
- `make check-site`;
- `make check-pins`;
- hashing's own suites, on chez-srfi akku.291 (§2).

I expect them to pass on the first run, apart from the rows that hold today's pins, which
are the rows §3.7 rewrites. Any other failure stops the slice and comes to you.

## 6. Building it

1. **I fetch everything first,** on the host: Akku 1.2.0 (`make akku-deps`), the lock
   (`make lock`) and the trees (`make fetch`). No agent downloads outside code.
2. **One build agent, on Opus,** does §3.3 to §3.10 test first. Each new check is watched
   failing before it passes:
   - a tree with one byte edited;
   - a tree that is missing;
   - a lock entry with a different sha256;
   - a chez-libuv copy whose source tree has moved;
   - a docs link at `v0.5.2`;
   - a records line still at chez-websocket 0.5.2.
3. **A read-only adversarial review, on Opus,** then checks each record line against the
   check that holds it.
4. **I verify every hand-back** by rerunning its checks, then commit and open the PR when
   you ask.

## 7. Not in this slice

- **Publishing circuit on Akku,** a slice of its own, after this one, with a release
  (§8, Q4). That needs:
  - `.akkuignore` to let `src/` in;
  - a `make check-akku` that installs circuit as a consumer would, as the siblings have;
  - `scripts/akku-publish`;
  - a release.

  ADR-0008 says the owner will publish circuit once the server is on the index. That
  condition is now met. This slice is the groundwork for it.
- **The Open list's other items.**

## 8. Decided

The owner answered on 2026-11-20:

1. **`make check-akku-lock` runs on the host and in CI.** A new release on the index that
   a range admits turns CI red, even on an unrelated PR, until `make lock` is run again.
   The red is the signal to take the release.
2. **chez-srfi: "should we evaluate the new version (akku.291.5219353) and lock to
   that?"** Evaluated (§2): SRFI-1 and SRFI-64, as Chez loads them, are unchanged. So it
   is locked at akku.291, with a caret range like the others.
3. **`make fetch`** replaces `make submodules`, which is removed.
4. **Publishing circuit on Akku is a slice of its own,** after this one, with a release.
