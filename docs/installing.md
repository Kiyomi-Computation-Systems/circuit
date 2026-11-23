# Installing

Circuit is a set of R6RS libraries. You clone it, fetch the server it runs
on and the rest of its dependencies, build one small C library, and run your
program from the checkout.

## What you need

- **Linux or macOS**, on x86-64 or arm64.
- **Chez Scheme 10.4.1 or newer, threaded.** Threaded is Chez's default
  build. Homebrew installs it as `chez`, and `make` finds either name. It
  refuses an older Chez, or one without threads, saying which it found.
- **libuv 1.48 or newer**, where `pkg-config` can see it: `brew install libuv`
  on macOS, `apt install libuv1-dev` on Ubuntu 24.04 or newer. An older one,
  such as Debian 12's 1.44, won't do.
- **A C compiler, `make`, `git` and `curl`, and `xz` on Linux.** The
  compiler builds the small C library under the server's libuv binding.
  `make fetch` clones the server with git, downloads the other dependencies
  with curl, or wget, and unpacks them with tar, which on Linux needs `xz`.
  The tests run curl.
- **GNU `timeout`**, which `make test` runs each suite under. On macOS,
  `brew install coreutils`.

## Build it

```sh
git clone https://github.com/Kiyomi-Computation-Systems/circuit.git
cd circuit
make fetch
make test
```

- `make fetch` clones the server at its pinned commit, then downloads
  every other dependency as `Akku.lock` pins it, and checks each one's
  sha256. It needs the network.
- `make test` builds the C library, then runs every suite under `tests/`.
  Its last line counts them: none should fail or hang.

`make help` lists every other target.

To build a release, clone its tag, `git clone --branch v0.3.0` and the URL
above, then follow that tag's own `docs/installing.md`.

## On a Guix host

Run builds and tests in the project's pinned container:

```sh
scripts/guix-env make test
```

It has no network and no git, so run `make fetch` on the host first.

## Every dependency from Akku

Every dependency comes from the Akku package index: what chez-http-server
needs, chez-websocket, `hashing`, Gwen Weinholt's SHA-2 and HMAC, and
jsonparse. `Akku.lock` pins each one's archive and sha256.

`make fetch` puts `hashing` in `vendor/akku` and the rest in
`vendor/akku-trees`. `make clean` keeps both, and `make check-pins` checks
each one is still its archive.

The server itself is the one exception, for now. Circuit needs its 0.12.0,
which isn't on Akku yet, so it's a git submodule, `vendor/chez-http-server`,
pinned at v0.12.0's commit. `make check-pins` checks it is that commit,
unchanged, and needs git to. An app that names circuit's dependencies in
its own `Akku.manifest` takes the server the same way. It clones the server
at that commit, and puts the clone's `src/` before Akku's libraries on its
library path.

`(circuit session)` signs its cookie with `hashing`, and `(circuit json)`
reads JSON with jsonparse. No other library uses either.

Akku can't install circuit itself yet: run it from the checkout.

## Run a program

```sh
make run PROGRAM=examples/hello.sps
```

`make run` puts circuit, the server and what they need on Chez's library
path, then runs the program. Yours can live anywhere:
`make run PROGRAM=/path/to/app.sps`. In the Guix container it must be under
the checkout, as the container sees nothing else.

`make dev` starts a REPL with the same library path. To run a program
without make, in a service or a container, `make libdirs` prints that path
on one line. Run it from the checkout, as `make run` does:

```sh
scheme --libdirs "$(make libdirs)" --program examples/hello.sps
```

Homebrew's Chez is `chez`, not `scheme`.

Each file under `examples/` is one small server, and
[examples/README.md](../examples/README.md) says what each one shows.
