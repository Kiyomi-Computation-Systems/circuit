# AGENTS.md

## Project guidelines

### Architecture & portability

* Use the functional core / imperative shell pattern: a pure core (requests,
  responses, headers, middleware) and two libraries that import
  chez-http-server, the adapter `(circuit http-server)` and
  `(circuit middleware waits)`. No other library imports `(http-server)`,
  and those two take from `(chezscheme)` only through `only`, naming what
  the audit allows (ADR-0006). A third, `(circuit websocket)`, imports
  chez-websocket's facade `(websocket)`, which imports the server. No other
  library imports `(websocket)`, none imports another `(websocket ...)`
  library, and none imports `(circuit websocket)` (ADR-0006). One core
  library, `(circuit session)`, imports `hashing`'s `(hashing sha-2)`,
  through `only`, and no other library imports a `(hashing ...)` one; what
  `(hashing sha-2)` imports is held to `(rnrs ...)` and its own two
  libraries (ADR-0008). Another, `(circuit json)`, imports jsonparse's
  `(jsonparse easy)`, through `only`, and no other library imports a
  `(jsonparse ...)` one; what it imports is held to `(rnrs ...)`,
  jsonparse's own libraries, `(generated jsonparse)`, and byte-machine's
  runtime and its two private libraries (ADR-0009).
  `make check-imports` holds it, and `make test` runs it once `src/` exists.
* Follow the 12 Factor Apps philosophy
* Project is built for Chez Scheme but should be mostly portable to R6RS:
  the core is plain R6RS, `hashing` and jsonparse too, and only the two
  libraries above may use Chez's own procedures.
* Project should be portable across macos (darwin) and linux; windows is not
  supported (`.plans/decisions/0001-windows-is-not-supported.md`)
* Project should be portable across amd64 and arm64
* **DO NOT** setup macos CI runners: linux only!
* Exported functions should have a comment with a Typed Racket style type signature

### Dependencies

* Every dependency comes from the Akku index (ADR-0011), but the server,
  for now (below). `Akku.manifest` names each one, and `Akku.lock` pins its
  archive and sha256:
  * chez-http-server https://github.com/Kiyomi-Computation-Systems/chez-http-server,
    and what it brings: chez-libuv, chez-httparse, chez-uri and
    byte-machine, the path's one byte-machine, which jsonparse runs on too;
  * chez-websocket https://github.com/Kiyomi-Computation-Systems/chez-websocket,
    for `(circuit websocket)`;
  * hashing, Gwen Weinholt's SHA-2 and HMAC, for `(circuit session)`
    (ADR-0008);
  * jsonparse https://github.com/Kiyomi-Computation-Systems/jsonparse, for
    `(circuit json)` (ADR-0010);
  * chez-srfi, a development dependency, for the suites' SRFI-64.
* `akku lock` writes `Akku.lock`, never a hand. `make lock`, on the host,
  runs `akku update`, then `akku lock`, on Akku 1.2.0: `scripts/akku` runs
  it, and `make akku-deps` fetches it as `scripts/akku-tool.lock` pins it.
  `make check-akku-lock`, on the host and in CI, fails unless the lock is
  what Akku makes of the manifest against today's index, so a release that
  a range admits turns CI red until `make lock` moves the lock. Try a lock
  move first: the suites, the gate, the site and hashing's own suites pass
  on it before it lands.
* **The server is a git submodule, `vendor/chez-http-server`, at
  `SERVER_PIN`** in the Makefile, v0.12.0's commit in full, until the Akku
  index has that release and a chez-websocket whose range admits it
  (ADR-0012). The manifest and the lock stay what Akku makes: the lock still
  pins the server at 0.11.0, which nothing fetches, as `AKKU_EXCEPTED`
  names it. `make fetch` clones the submodule, `make deps` fails unless its
  `Akku.manifest` names `SERVER_VERSION`, and `make check-pins` fails unless
  its HEAD, its gitlink and its tag `v$(SERVER_VERSION)` are `SERVER_PIN`
  and it holds no change. The docs' links name its
  tag, v0.12.0. When the exception ends, the submodule, `SERVER_PIN`,
  `AKKU_EXCEPTED` and the suites' `excepted` go, on one commit with the
  lock's move.
* `make fetch`, on the host, fetches each tree as the lock pins it, its
  sha256 checked: hashing into `vendor/akku`, and the others into
  `vendor/akku-trees/<name>`. Both are git-ignored and kept by `make clean`.
  On the library path are `vendor/akku`, and each tree's `src/` but two:
  chez-libuv's copy, `build/chez-libuv`, has its `src/` there in the
  tree's place, and chez-srfi's SRFIs are linked into `build/scheme-libs`,
  which is there instead.
* `make deps` never fetches. It fails unless `Akku.lock` pins exactly
  hashing, chez-cmark-gfm, the Makefile's `AKKU_TREES` and `AKKU_EXCEPTED`,
  each once, and without a tree, or on another than the lock's. It builds chez-libuv's
  shim in the copy, so the fetched tree stays its archive, and copies the
  tree again when the copy differs from it beyond its build's two
  products. `make check-pins`, on the host and in CI, holds the lock to
  those names, each tree to its archive, an edit included, the copy to its
  tree and its build's products, and the submodule to `SERVER_PIN`.
* Move the lock and the records on one commit: the docs' links into a
  sibling name the tag of the version the lock pins, the server's its
  submodule's while it is one, and the global constraints' Dependency
  section names each locked package as `<package>, now <version>`.
  `tests/test-reference.sps` holds both to `Akku.lock`, and the server's to
  its submodule's `Akku.manifest`.
* circuit isn't installed through Akku yet: `.akkuignore` keeps its own
  libraries out of `akku install`.
* chez-cmark-gfm renders `docs/` into the docs site. `Akku.lock` pins it, a
  development dependency of `Akku.manifest`. `make site-deps`, on the host,
  fetches it into `build/akku/`, off the library path.
* Circuit's tests run handlers through the server's test host,
  `(http-server testing)`, which its package installs. Its fake shell is
  `(http-server private fake-shell)`, which no circuit library imports
  (ADR-0006).

### Layout, process & libraries

* Plans live in `/.plans`, decision records in `/.plans/decisions`
* The ledger is `/.plans/progress.md`: where the project stands, the next
  slice, and a close-out for each merged slice. `/.plans/global-constraints.md`
  holds the decision records' hard rules and binds every task brief. Read both
  before starting slice work. `/.superpowers/` is git-ignored plugin scratch,
  not the ledger.
* Add entries to `CHANGELOG.md` for each release
* `/docs` is for user facing documentation only. `make site` renders it to
  `build/site/`, and the Pages workflow publishes it on a release tag.
  `make check-site` gates it: every page is in `site/pages.sls`, in the
  home page's Read next order. `tests/test-reference.sps` holds
  `docs/reference.md` to every export of the twelve public libraries and its
  signature comment: a new export needs an entry.
* Documentation should be very concise, focused, to the point, ELI5 style.
* `Makefile` should have a `help` command which lists all of its commands
* Libraries are R6RS `.sls`; libraries and programs contain their own code —
  no shared include bodies. R6RS forbids assigning an exported variable —
  reach mutable state through procedures.

### Guix development container

* **On a Guix host, run every build and test through `scripts/guix-env`**,
  e.g. `scripts/guix-env make test`. Batch commands with
  `scripts/guix-env sh -c 'make a && make b'`: each call takes a second or
  more to start.
* Edit, commit and push on the host. The container has no git identity,
  agents or tokens, and no network but loopback
* Verify it with `make check-guix`, run on the host.
* The container lets in only `TERM`, `COLORTERM` and `LANG`, and its
  `/tmp` is its own. A variable set on the host, or a file left in the
  host's `/tmp`, doesn't reach it: put scratch files, mutants and probes
  under the checkout's `build/`, which is git-ignored.
* The container exports `CHEZ` (the real `scheme` binary) and `CC` (gcc;
  the toolchain has no `cc`), which builds chez-libuv's shim.
* Anything that needs the network or git runs on the host: fetches, pushes
  and downloads. Among them are `make fetch`, which a fresh clone needs
  once before `make deps`, `make akku-deps`, `make lock`,
  `make check-akku-lock`, and `make site-deps`, once before `make site`.
  The container has no git, so while the server is a submodule
  `make check-pins` and `make check-site-deps` run on the host too.

### Testing & mutation discipline

* Use TDD / test-driven development
* A test that passes whether the code is right or wrong is worse than no test.
* A test is not finished when it passes. It is finished when you have watched
  it fail.
* Prefer a check to a comment.
* **Do not** write tests that rely on reading code comments: a test asserts
  what the code does, never what a comment says. A doc check is the one
  exception, holding comments to the docs: `tests/test-reference.sps` holds
  each signature comment to `docs/reference.md` and its procedure's arity,
  each type alias comment to the page's, each re-export's to the server's or
  chez-websocket's reference, and the global constraints' versions to
  `Akku.lock`'s.
* Chez must be a threaded build: chez-http-server needs one, so circuit has
  no `--nothreads` lane.
* `make test` runs every suite under GNU `timeout`, which kills a hung
  suite's whole process group, except at a terminal: there it runs with
  `--foreground`, so Ctrl-C reaches the suite, and a hung suite's children
  (curl, a server) outlive it. After a HUNG suite at a terminal, look for
  orphans holding ports. On macOS, run
  `brew install coreutils`, and make finds its `gtimeout`. Homebrew installs
  Chez as `chez`, which make also finds.
* Run a mutant's suites under a timeout and a memory cap, as in
  `(ulimit -v 4194304; timeout 120 "$CHEZ" --libdirs ... --program ...)`.
  A mutant can make a bounded read unbounded: in slice 8, one read a test
  producer that answered forever past its last piece, and took the host's
  memory. A test producer ends: one that notes a call past its last piece
  answers it once, then eof every call after.

**Tests**

* `guard` returns the body's value when nothing raises, and `0` is truthy.
  Assert *what was raised* against an expected value, with a distinct sentinel
  for the no-raise case.
* SRFI-64 turns an exception in the *actual* expression into `#f`. Never
  expect `#f` from something that can raise.
* SRFI-64 does not catch an exception in the *expected* expression, nor in a
  suite's top-level definitions: the suite dies and no test is named. Compute
  anything that can raise under a `guard`.
* Every `tests/test-*.sps` must end with `(exit (suite-exit-status runner))`:
  SRFI-64 sets no exit status. Anything after that line never runs, and
  `make check-suites` checks it is there.
* An exit status is taken modulo 256, so `(exit 256)` exits 0. Exit with 0 or
  1, never a count.
* A suite cannot vouch for the verdict it exits through. A suite that tests
  `suite-exit-status` must also exit 1 on its own failures, before the
  shared form.
* Chez chooses the order of a call's arguments as it compiles each call.
  In slice 6c, a probe library's calls ran left to right, a `begin`
  argument included, while in `(circuit websocket)` a `begin` in the last
  argument ran before the reads ahead of it. `map` calls its procedure in
  no fixed order. A `let`'s inits are arguments too, and so is the
  operator: in `((view-proc (check r)) (field r))` an operand can run before
  the operator's check. No assertion may depend on any order; use
  `for-each` for effects, bind a check's result with `let` before the
  call that needs it, and use `let*` when one init must follow another.
* A setter that refuses a value keeps the one it had. Give each round trip
  its own sentinel, and assert every return code.
* An assertion passes whenever *another* rule can produce its expected value.
  Assert whole outputs, not substrings, and build a test's base from
  non-default values. Test a scan at every position, an encoding on bytes
  where encodings differ, and an allowlist against its whole complement.
* Hold a limit from both sides: a row at the limit, which passes, and one a
  step past it, which is refused. In slice 7, rows at 300,000 bytes and at
  1 MiB and a byte held the echo example's 1 MiB cap only to somewhere
  between them. Give a number check a bignum as well as a fixnum: a check
  that took fixnums alone passed every row until a cap of 2^100 joined them.
* A property suite's generators draw every kind of value the interface
  takes, not only the kinds the design's examples show: a middleware that
  makes a fresh request, as well as one that passes the request on.
* SRFI-64 keeps one result per runner. Never run a test inside another test's
  actual expression: the outer verdict is reported under the inner test's name.

## Closing ritual

We run this when we're done and ready to merge the PR.

**Important**: ALWAYS ask before running this.

1. Squash merge the PR.
2. Catch up local `main`.
3. Clean up branches. Delete the merged branch locally and on the remote.
4. Reflect.
