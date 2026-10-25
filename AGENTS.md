# AGENTS.md

## Project guidelines

### Architecture & portability

* Use the functional core / imperative shell pattern: a pure core (requests,
  responses, headers, middleware) and two libraries that import
  chez-http-server, the adapter `(circuit http-server)` and
  `(circuit middleware waits)`. No other library imports `(http-server)`;
  `make check-imports` holds it.
* Follow the 12 Factor Apps philosophy
* Project is built for Chez Scheme but should be mostly portable to R6RS:
  the core is plain R6RS, and only the two libraries above may use Chez's
  own procedures.
* Project should be portable across macos (darwin) and linux; windows is not
  supported (`.plans/decisions/0001-windows-is-not-supported.md`)
* Project should be portable across amd64 and arm64
* **DO NOT** setup macos CI runners: linux only!
* Exported functions should have a comment with a Typed Racket style type signature

### Dependencies

* chez-http-server https://github.com/Kiyomi-Computation-Systems/chez-http-server,
  a submodule under `vendor/` pinned at a release tag. It carries its own
  pins, which circuit uses through it: chez-libuv, chez-httparse (with
  byte-machine), uriparse, and chez-srfi for the tests.
* `Akku.manifest`'s `depends` names chez-http-server at `^` its vendored
  version; `make check-pins` holds the pin, its range and `Akku.lock`
  together, so move all three on one commit.
* The server's Akku package leaves out its `tests/`, so its fake shell
  (`tests/fake-shell.sls`) is reached only through the vendored copy.

### Layout, process & libraries

* Plans live in `/.plans`, decision records in `/.plans/decisions`
* The ledger is `/.plans/progress.md`: where the project stands, the next
  slice, and a close-out for each merged slice. `/.plans/global-constraints.md`
  holds the decision records' hard rules and binds every task brief. Read both
  before starting slice work. `/.superpowers/` is git-ignored plugin scratch,
  not the ledger.
* Add entries to `CHANGELOG.md` for each release
* `/docs` is for user facing documentation only.
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
* The container exports `CHEZ` (the real `scheme` binary) and `CC` (gcc;
  the toolchain has no `cc`), which builds chez-libuv's shim.
* Anything that needs the network or git runs on the host: fetches, pushes,
  downloads, `make check-pins`, and `git submodule update --init`, which a
  fresh clone needs once before `make deps`. The container has no git.

### Testing & mutation discipline

* Use TDD / test-driven development
* A test that passes whether the code is right or wrong is worse than no test.
* A test is not finished when it passes. It is finished when you have watched
  it fail.
* Prefer a check to a comment.
* **Do not** write tests that rely on reading code comments
* Chez must be a threaded build: chez-http-server needs one, so circuit has
  no `--nothreads` lane.
* `make test` runs every suite under GNU `timeout`. On macOS, run
  `brew install coreutils`, and make finds its `gtimeout`. Homebrew installs
  Chez as `chez`, which make also finds.

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
* Chez evaluates arguments right to left in compiled library code, left to
  right when interpreted, and `map` calls its procedure in no fixed order. A
  `let`'s inits are arguments too. No assertion may depend on either order;
  use `for-each` for effects, and `let*` when one init must follow another.
* A setter that refuses a value keeps the one it had. Give each round trip
  its own sentinel, and assert every return code.
* An assertion passes whenever *another* rule can produce its expected value.
  Assert whole outputs, not substrings, and build a test's base from
  non-default values. Test a scan at every position, an encoding on bytes
  where encodings differ, and an allowlist against its whole complement.
* SRFI-64 keeps one result per runner. Never run a test inside another test's
  actual expression: the outer verdict is reported under the inner test's name.

## Closing ritual

We run this when we're done and ready to merge the PR.

**Important**: ALWAYS ask before running this.

1. Squash merge the PR.
2. Catch up local `main`.
3. Clean up branches. Delete the merged branch locally and on the remote.
4. Reflect.
