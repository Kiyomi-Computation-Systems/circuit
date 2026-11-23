# ADR-0012: chez-http-server 0.12.0 comes from a submodule until Akku has it

- **Status:** Proposed, 2026-11-23. The owner chose the exception on 2026-11-22, in
  Techo's session (circuit#53), and again in circuit's on 2026-11-23: "take the
  exception", "pin first, worker later", keep the manifest and the lock as Akku makes
  them, and file chez-websocket's release ask
  (Kiyomi-Computation-Systems/chez-websocket#115).
- **Date:** 2026-11-23
- **Amends:** [ADR-0011](0011-every-dependency-comes-from-akku.md)'s items 3, 6 and 7,
  for chez-http-server alone, until this record's item 6 ends it. ADR-0011's other items
  stand, for every other package.
- **Scope:** how chez-http-server reaches the build, the container, CI and an app
- **Related:** [ADR-0003](0003-chez-http-server-is-a-submodule-pinned-at-a-release-tag.md),
  [ADR-0006](0006-only-the-adapter-and-middleware-waits-import-the-server.md)

## Context

circuit#53 asks for the server's `await-outside`, re-exported, and then a worker built
on it. chez-http-server v0.12.0 (`bba2ba6`, dated 2026-11-22 in its CHANGELOG) adds it. A handler can then wait
for work done on a thread of its own, such as a blocking SQLite call, while the loop
serves everyone else.

Read on 2026-11-23:

- **The Akku index's newest chez-http-server is 0.11.0** (`akku update`, 01:05Z).
- **chez-websocket 0.6.0, the index's only release, depends on `chez-http-server
  ^0.11.0`.** Akku reads a caret on 0.x as below the next minor. So no manifest that
  names chez-websocket can lock the server at 0.12.0, even once 0.12.0 is on the index.
- **The tag v0.12.0 peels to `bba2ba6fea252996d31bffc6255d8be36e9bdfd2`**
  (`git ls-remote`).
- **0.12.0 changes six of the server's libraries:** the facade, `awaiting`, `testing`,
  and the private `scheduler`, `shell` and `waits`. It moves none of its depends:
  chez-libuv `^0.11.0`, chez-httparse `^0.6.0`, chez-uri `^0.9.0` and byte-machine
  `^0.9.0`, each of which the lock pins already, and its own lock pins the same
  versions. Its `src/` holds the same files as 0.11.0's, and the release holds every
  file 0.11.0's archive does.
- **Tried first,** as ADR-0011's item 8 asks: with the path's server taken from a clone
  at `bba2ba6`, and chez-websocket 0.6.0 from Akku, `make test` passed 26 of 26 and
  `make gate` held every bound, in the container. Neither wrote into the server's tree.

## Decision

1. **chez-http-server is a git submodule, `vendor/chez-http-server`, at `bba2ba6`.** The
   Makefile's `SERVER_PIN` names the commit in full, as a shallow checkout has no tags,
   and `SERVER_VERSION` the release it is, 0.12.0. The path takes the server's `src/`
   from the submodule.
2. **`Akku.manifest` and `Akku.lock` stay what Akku makes of them.** The manifest keeps
   `chez-http-server ^0.11.0`, which chez-websocket names anyway, and says why in a
   comment. The lock keeps its 0.11.0 entry, which nothing fetches. The Makefile's
   `AKKU_EXCEPTED` names the server, so `check-lock-projects` counts it as fetched.
   `make lock` and `make check-akku-lock` are unchanged.
3. **`make fetch` clones the submodule,** by `git submodule update --init`, then fetches
   every other package as ADR-0011 says. It needs git, on the host and in CI.
4. **The server's pin is checked like a tree's.** `scripts/check-server-pin` does it:
   - `make deps`, in the container, without git: the submodule is cloned, and its
     `Akku.manifest` names `SERVER_VERSION`. Run from a linked worktree, the container
     can't see the submodule's git directory, which is under the main checkout's
     `.git/worktrees/`, so `deps` reads nothing of git's;
   - `make check-pins`, with git: the submodule's HEAD, the gitlink the repository
     records, and its tag `v` and `SERVER_VERSION` are all `SERVER_PIN`, and it holds
     no change, ignored files and a nested submodule included.

   `check-pins` and `check-site-deps` now need git, so they run on the host and in CI,
   not in the container. `tests/check-pins.sh` holds both checks on a fake submodule.
5. **The records follow the submodule for the server.**
   - The docs' links into the server name v0.12.0.
   - The global constraints say `chez-http-server, now 0.12.0`.
   - `tests/test-reference.sps` reads the server's version from the submodule's
     `Akku.manifest`, and its reference from the submodule, through its `excepted` list.
6. **The exception ends once the index has chez-http-server 0.12.0, or a later release
   circuit needs, and a chez-websocket whose range admits it.** Then, on one commit:
   - the manifest's two ranges move;
   - `make lock` moves the lock, tried first as ADR-0011 says;
   - the submodule, `.gitmodules`, `SERVER_PIN`, `SERVER_VERSION`, `AKKU_EXCEPTED`,
     `scripts/check-server-pin` and its rows, and the reference suite's `excepted` go;
   - the records follow the lock again;
   - a record supersedes this one.

   Nothing turns CI red when that happens. The ledger's Open list holds it.
7. **A consumer that repeats circuit's depends, such as Techo, does what circuit does
   meanwhile.**
   - Its `Akku.manifest` names what circuit's does, `chez-http-server ^0.11.0` among
     them. That brings chez-libuv, chez-httparse, chez-uri and byte-machine at the
     versions circuit runs.
   - It takes the server at `bba2ba6` from git, as a submodule or a clone.
   - It puts that tree's `src/` on its library path before Akku's libraries, such as
     `.akku/lib`. 0.12.0 holds every file 0.11.0 does, so each server library then
     loads from 0.12.0.
   - A check that `(http-server)` exports `await-outside` shows it took.

## Consequences

- **circuit's manifest no longer says what circuit needs.** `^0.11.0` admits a server
  without `await-outside`, which `(circuit http-server)` can't load on. That matters
  only to a consumer that installs circuit from Akku, and circuit isn't on Akku yet
  (ADR-0011): item 7 tells a consumer what to do until it is.
- **The lock pins a server the path doesn't use.** The lock is still what Akku makes of
  the manifest, and `make check-akku-lock` still holds it.
- **`make check-pins` needs git again,** as it did before ADR-0011. It runs on the host
  and in CI, as it always did; only the container can't run it now. Neither can it run
  `make check-site-deps`, whose tests make a fake submodule with git.
- **A checkout from before this record** has a stale `vendor/akku-trees/chez-http-server`,
  which nothing reads now. Delete it and its `.sha256`, then run `make fetch`.
- **A checkout from v0.3.0 or earlier** has the old server's own submodules
  initialized: v0.3.0's `make submodules` cloned them. `make fetch` doesn't recurse, so
  they stay at the old server's commits, and `make check-pins` names each one. Run
  `git -C vendor/chez-http-server submodule deinit -f --all` once: v0.12.0 needs none of
  them. `tests/check-pins.sh` holds that a deinit clears one.
- **`make deps`'s check is weaker than `check-pins`'s.** A submodule at another commit
  of the same release passes it, as would an edit. `check-pins`, on the host and in
  CI after the tests and the gate, is what holds the commit.
- **circuit runs a server the index doesn't have,** on the libraries the index's
  0.11.0 brings. 0.12.0's own lock names those same versions, so this is the
  combination the server was tested on.
