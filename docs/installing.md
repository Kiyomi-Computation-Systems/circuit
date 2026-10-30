# Installing

Circuit is a set of R6RS libraries. You clone it with the server it runs on,
build one small C library, and run your program from the checkout.

## What you need

- **Linux or macOS**, on x86-64 or arm64.
- **Chez Scheme 10.4.1 or newer, threaded.** Threaded is Chez's default
  build. Homebrew installs it as `chez`, and `make` finds either name.
- **libuv 1.48 or newer**, where `pkg-config` can see it: `brew install libuv`
  on macOS, `apt install libuv1-dev` on Ubuntu 24.04 or newer. An older one,
  such as Debian 12's 1.44, won't do.
- **A C compiler, `make`, `git` and `curl`.** The compiler builds the small
  C library under the server's libuv binding. The tests run curl.
- **GNU `timeout`**, which `make test` runs each suite under. On macOS,
  `brew install coreutils`.

## Build it

```sh
git clone https://github.com/Kiyomi-Computation-Systems/circuit.git
cd circuit
make submodules
make test
```

- `make submodules` clones the pinned dependencies. It needs git and the
  network.
- `make test` builds the C library, then runs every suite under `tests/`.
  Its last line counts them: none should fail or hang.

`make help` lists every other target.

To build a release, clone its tag: `git clone --branch v0.1.0` and the URL
above. A release's source download leaves `vendor/` empty, as every git
archive leaves out submodules.

## On a Guix host

Run builds and tests in the project's pinned container:

```sh
scripts/guix-env make test
```

It has no network and no git, so run `make submodules` on the host first.

## The pinned dependencies

Two git submodules under `vendor/`, each pinned at a release tag:

- **chez-http-server v0.9.1**, the server. It carries its own pins:
  chez-libuv, chez-httparse, uriparse, and chez-srfi for the tests.
- **chez-websocket v0.4.1**, for `(circuit websocket)`.

To check every checkout sits at its pin:

```sh
make check-pins
```

Neither is on the Akku package index yet, so Akku can't install circuit:
the checkout is the way in.

## Run a program

```sh
make run PROGRAM=examples/hello.sps
```

`make run` puts circuit, the server and what they need on Chez's library
path, then runs the program. Yours can live anywhere:
`make run PROGRAM=/path/to/app.sps`. In the Guix container it must be under
the checkout, as the container sees nothing else.

`make dev` starts a REPL with the same library path.

Each file under `examples/` is one small server, and
[examples/README.md](../examples/README.md) says what each one shows.
