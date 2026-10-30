# Changelog

All notable changes to circuit are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The API may change in any
release before 1.0.

## [Unreleased]

### Added

- **A docs site.** `docs/` is Markdown for developers, and `make site` renders it into
  `build/site/` through chez-cmark-gfm, as chez-http-server and chez-websocket render
  theirs. `make check-site` gates it in CI, and the Pages workflow publishes it on each
  release tag. The first pages are Home, Installing and Quickstart.

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

[Unreleased]: https://github.com/Kiyomi-Computation-Systems/circuit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Kiyomi-Computation-Systems/circuit/releases/tag/v0.1.0
