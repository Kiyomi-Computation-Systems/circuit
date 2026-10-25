# ADR-0002: Builds and tests run in a pinned Guix container with no network and no git

- **Status:** Accepted
- **Date:** 2026-10-25
- **Scope:** development tooling. No library change.
- **Prior art:** chez-curl ADR-0006, whose launcher, self-test and launcher tests this
  copies; chez-http-server's `manifest.scm`, whose Chez 10.4.1 recipe this copies
- **Related:** [ADR-0003](0003-chez-http-server-is-a-submodule-pinned-at-a-release-tag.md)

## Context

The maintainer develops on Guix. Circuit's builds and tests need:

- Chez 10.4.1, threaded: chez-http-server's floor;
- libuv at or above chez-libuv's floor, 1.48.0, which pkg-config can see, and a C
  compiler: chez-libuv builds its shim on the machine that uses it;
- curl, the client the integration suites run against the server;
- `make` and the usual shell tools.

The host's own Chez is 10.4.0, below the server's floor. The Guix pin the siblings use,
`b532aa7d…`, packages Chez 10.4.0 and libuv 1.44.2. The server's manifest builds Chez at
the v10.4.1 tag, as chez-libuv's does, so the three share that store item, and takes
node's libuv, 1.52.1.

## Decision

1. **`scripts/guix-env` runs every build and test** in `guix shell --container`, pinned by
   `channels.scm` to the siblings' revision, from `manifest.scm`: Chez 10.4.1 built from
   its tag with its own test suite off, `libuv-for-node-lts`, `pkg-config`,
   `gcc-toolchain`, `curl` and the shell tools.
2. **The container has no network and no git**, as chez-curl's has neither. Fetching the
   submodules (`make submodules`) and checking the pins (`make check-pins`) run on the
   host and in CI. `make deps` never fetches.
3. **`scripts/guix-env-enter` exports `CHEZ`**, the profile's real `scheme` binary, **and
   `CC`**, its gcc, and sets no `LD_LIBRARY_PATH`.
4. **`make check-guix`** runs the launcher's host-side tests, then the self-test inside:
   isolation from `HOME`, the pinned tools on a login shell's path, Chez's version and
   threads, libuv at chez-libuv's floor, no load by bare name, loopback only, no git, and
   `make check-help` and `make test`.

## Consequences

- **A fresh machine's first `scripts/guix-env` builds Chez,** in about two minutes, unless
  the server's or chez-libuv's container already has.
- **Nothing that needs git or the network can run in the container.** A target that does
  says so and runs on the host.
- **Bumping the pin is changing `channels.scm` and running `make check-guix`**, as is any
  change to `manifest.scm` or the `guix-env` scripts. The Chez recipe stays until the pin
  packages 10.4.1 itself.
