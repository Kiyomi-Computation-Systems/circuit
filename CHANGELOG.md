# Changelog

All notable changes to circuit are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The API may change in any
release before 1.0.

## [Unreleased]

### Added

- **`wrap-catch-with` and `wrap-log-with`**, in `(circuit middleware waits)`.
  `(wrap-catch-with on-raise)` and `(wrap-log-with clock)` each make a middleware, so
  `wrap` takes them as it takes `(wrap-timeout ms)`:
  `(wrap app (wrap-catch-with on-raise) (wrap-log-with clock))`.
  `(wrap-catch handler on-raise)` and `(wrap-log handler clock)` work as before.
- **The app can answer the router's 400 and 405 itself.** `make-router` takes options
  after its table, in any order: `(on-not-found h)`, or `h` alone as before,
  `(on-bad-request h)` and `(on-method-not-allowed h)`. The 400's handler gets the request
  as it came to the router. The 405's gets it with the route's match, and when it answers
  a 405 the router sets `allow` on it; any other status goes out as it is, so a 404 can
  hide the route. Two options for one answer raise, and so does a constructor given
  without its handler. A program that defines one of the three names itself must rename
  it.
- **`make check-chez`**, run first by every target that runs Chez on circuit's libraries.
  It refuses a Chez below 10.4.1, one without threads, or a `CHEZ` that is missing or
  empty, saying what it found. The docs site's targets take a threaded Chez of any
  version. It runs Chez once, for at most `REQUIRE_CHEZ_SECONDS` (10) under GNU
  `timeout`, and reads at most 4 KiB of its answer.
- **`make libdirs`** prints the library path a program needs, for running it without
  make.

### Changed

- **`wrap-log`'s line ends with the client's address**, `req-remote-address`, or `-` for
  none, as the server's `request-refused` line does:
  `request GET /users 200 written 0 127.0.0.1`. A program that reads the milliseconds as
  the line's last field must take the one before it. A middleware that sets the address,
  such as one that believes a proxy, goes after `wrap-log`.
- **`wrap-log` writes each control character in the method, the path and the address as
  a space**, so a request is always one line, even when a middleware set the address
  from a client's header.
- **A capture holding a raw character a path can't hold is a 400**, as one that doesn't
  decode as UTF-8 already was: a control character, a space, DEL, `"`, `#`, `<`, `>`, `?`,
  `[`, `\`, `]`, `^`, a backtick, `{`, `|` or `}`. The server lets none of them into a
  path, so only a path set with `req-with-path`, or a test's, can hold one. A mount's rest
  is still unchecked.
- **The default `CHEZ`** is the first of `scheme` and `chez` on `PATH` that is Chez
  Scheme 10.4.1 or later, threaded; failing that, the first that is Chez Scheme. On a
  Mac, another Scheme may own `scheme`.
- **`make check-imports` also refuses a `(circuit ...)` library on the library path
  outside `src/`**: a `circuit` directory or `circuit.*` file, in any case. It names a
  directory it can't list.

### Fixed

- **`(circuit http-server)`'s comment for `awaiting`** gives the server's signature,
  `(-> Answer) -> Awaiting`, and the reference suite holds every re-exported procedure's
  comment to the server's reference.
- **The tests no longer depend on Chez's exact read-error wording**, and the adapter
  suite opens its FIFO as POSIX defines.
- **Testing's page said `res-body->bytevector` reads a body as the server sends it.** It
  does with `CIRCUIT_PORT_PIECE_BYTES` unset: it reads a port in 64 KiB pieces whatever
  the app's setting, so a wrap or a tap can see other pieces than in production. The page
  now says so, and shows how to test a wrap across pieces.

## [0.1.2] - 2026-10-30

The third release, a patch: the pins move to chez-http-server v0.10.0 and chez-websocket
v0.5.1. The server now logs a request it refuses before any handler runs, and every log
line, `wrap-catch`'s default line among them, stays one line with a record inside it
short. No name an app imports changes, so the release is 0.1.2.

### Changed

- **Pinned at chez-http-server v0.10.0 and chez-websocket v0.5.1**, from v0.9.1 and
  v0.4.1, on one commit. The server carries the same chez-libuv, chez-httparse and
  uriparse that v0.9.1 did. No name an app imports changes.
  - **A request the server refuses before any handler runs is logged.** A malformed
    head, a missing `Host`, a timeout or a limit gets one line from the server, such as
    `request-refused 400 invalid-host 127.0.0.1`: its status, why it refused, and the
    client's address. `wrap-log` still never sees such a request.
  - **The test host's log lists it too**, as `(request-refused 413 body-too-large "-")`,
    with `-` for the address: a test that compares the whole log, such as a body past a
    cap that the app lets out, sees the entry.
  - **chez-websocket's `websocket-handler-failed` line is one line**, as the server's
    are.
- **The docs' links into chez-http-server and chez-websocket name v0.10.0 and v0.5.1.**

### Fixed

- **`wrap-catch`'s default line stays one line, and a record inside it is short.** The
  line is the server's for the same raise, which v0.10.0 changed. A raised string, symbol
  or character holding a line feed, or any other control character, wrote it over
  several lines, the later ones naming no event. A record inside a raised condition, list
  or vector was written whole, fields and all. Every control character is now a space,
  and such a record reads `#<record of type point>`.

## [0.1.1] - 2026-10-30

The second release, a patch: documentation. `docs/` is a guide for developers, published
at [kiyomi-computation-systems.github.io/circuit](https://kiyomi-computation-systems.github.io/circuit/)
with each release, and its API reference is held to the code. No library or example
changed.

### Added

- **A docs site.** `docs/` is Markdown for developers, and `make site` renders it into
  `build/site/` through chez-cmark-gfm, as chez-http-server and chez-websocket render
  theirs. `make check-site` gates it in CI, and the Pages workflow publishes it on each
  release tag. Its pages: Home, Installing, Quickstart, Requests and responses, Bodies
  and streaming, Middleware, Routing, Waiting, Upgrades and WebSockets, Testing handlers,
  Configuration, and an API reference.
- **The API reference is held to the code.** `tests/test-reference.sps`, in `make test`,
  fails unless `docs/reference.md` has an entry for each export of the six public
  libraries and no other, each with its signature as the source comments give it, which
  must agree with the procedure's arity, and a link to a guide page that names it. A name
  re-exported from chez-http-server links the server's reference instead. It also fails
  on a link to chez-http-server's or chez-websocket's repository at any ref but the pinned
  tag, which it reads from the vendored package's `Akku.manifest`.

### Changed

- **README.org is shorter.** Its guide sections moved to `docs/`, and it points there.

## [0.1.0] - 2026-10-29

The first release: an HTTP layer in the manner of Ring for R6RS Scheme. A handler is a
procedure from a request to a response, and a middleware is a procedure from a handler
to a handler. The core is plain R6RS. The adapter runs it on
[chez-http-server](https://github.com/Kiyomi-Computation-Systems/chez-http-server)
v0.9.1, and WebSockets come from
[chez-websocket](https://github.com/Kiyomi-Computation-Systems/chez-websocket) v0.4.1,
both pinned submodules under `vendor/`. The API may change in any release before 1.0.

### Added

- **`(circuit)`, the core.** A request, `req`, is read through a view of the server's
  request: its method, path, query, host, scheme, version, headers and both ends'
  addresses. `make-req-key`, `req-ref` and `req-set` keep values on it, and the
  `req-with-` helpers change a field. A response, `res`, is
  `(make-res status headers body)`, in Ring's order. Its body is `#f`, a bytevector, a
  string sent as UTF-8, a producer, a binary input port, or `(make-sized-body n body)`, a
  producer or port of `n` bytes. `wrap` composes middleware, and the header helpers
  read and change header lists.
- **A request's body is a port**, `req-body`, that reads the body as it arrives. Read it
  inside the handler's call. `wrap-body-cap` and `req-with-body-cap` give a request a cap
  of its own under the server's `CHEZ_HTTP_MAX_BODY_BYTES`, and the innermost cap wins. A
  body past it raises `&body-failed`, which is answered 413 if the app lets it out. A cap
  given once the port is made is refused.
- **A port body** of one piece or less is read whole and sent as its bytes. A longer one
  is sent with its length, streamed, and closed however the response ends.
- **`res-wrap-body` and `res-tap-body`.** A wrap passes the body's producer through `f`,
  for compression or transcoding, and the body goes out chunked. A tap hands each piece
  to `on-piece` as it goes out, unchanged, for counting or throttling, and the body keeps
  its length. `on-piece` may wait.
- **`req-on-done!`** registers a procedure that is called once with how the response
  ended: `written`, `client-closed` or `failed`.
- **`(circuit http-server)`, the adapter.** `circuit->handler` makes an app the server's
  handler, and `run-server` serves it where the environment says. Every request runs on
  a coroutine, so a handler can wait: the server's `await`, `sleep-ms`, `with-deadline`,
  `resolve` and conditions are re-exported. `CIRCUIT_PORT_PIECE_BYTES` sets a port body's
  piece size.
- **`(circuit middleware waits)`.** `wrap-catch` answers a raise with a response: by
  default a 500, logged as the server logs `handler-failed`. It passes `&client-closed`
  and `&deadline-passed` on, and answers `&body-failed` with its status. `wrap-timeout`
  answers 504 once a deadline passes. `wrap-log` logs a line for each request once its
  response is done.
- **Upgrades.** `make-upgrade-res` answers 101 and hands the connection to a take-over,
  with the server's transport procedures re-exported for it. Middleware can rebuild an
  upgrade around a wrapped take-over with `res-upgrade-body?` and
  `res-upgrade-body-take-over`. What a take-over answers goes to the server, so a
  middleware that wraps one must answer what it answers.
- **`(circuit router)`.** `make-router` compiles a table of `route`s, `group`s and
  `mount`s into one handler.
  - A template holds words, `:param`s and a last `*catch-all`. Where two templates
    differ, the leftmost segment that differs decides, and a word beats a parameter, so
    the table's order never matters.
  - Captures are percent-decoded as UTF-8. One that doesn't decode answers 400.
  - HEAD goes to the route's own HEAD, else its GET, else its ANY. A method the route
    doesn't take answers 405 with `Allow`. A path no route takes answers 404, or what the
    app's not-found handler says.
  - A group's middleware runs only for its own routes, and a mount's handler sees the
    rest of the path.
  - `req-route`, `req-path-param`, `req-path-params` and `req-mount-path` read the match.
- **`(circuit websocket)`.** `websocket-res` answers a WebSocket handshake through
  chez-websocket. Taken, it answers 101 and runs the app's procedure with the WebSocket.
  Refused, it answers the handshake's 400 or 403. Its limits are chez-websocket's
  `CHEZ_WS_` variables, read as the program starts. An app that wants them from the
  `env` it gives `run-server` builds them with `websocket-limits-from-environment`.
- **`(circuit test)`.** `make-test-req`, `test-req-done!` and `res-body->bytevector` test
  a handler with no server. The server's `(http-server testing)` tests one that waits.
- **Examples** under `examples/`: hello, echo, server-sent events, a long poll,
  middleware, an upgrade, a router and a WebSocket echo. `make test` runs each over
  loopback.
- **The build.** `make submodules` clones the pinned server and chez-websocket, and
  `make check-pins` holds them at their pins. `make test` runs every suite, and
  `make gate` holds what circuit adds to a request, in bytes. A pinned Guix container
  runs both. CI runs on Linux, on amd64 and arm64.

[Unreleased]: https://github.com/Kiyomi-Computation-Systems/circuit/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/Kiyomi-Computation-Systems/circuit/releases/tag/v0.1.2
[0.1.1]: https://github.com/Kiyomi-Computation-Systems/circuit/releases/tag/v0.1.1
[0.1.0]: https://github.com/Kiyomi-Computation-Systems/circuit/releases/tag/v0.1.0
