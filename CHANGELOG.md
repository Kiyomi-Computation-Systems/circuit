# Changelog

All notable changes to circuit are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The API may change in any
release before 1.0.

## [Unreleased]

### Added

- The build: chez-http-server v0.9.1 as a pinned submodule, a pinned Guix development
  container, and `make test`.
- The pure core, `(circuit)`: requests (`req`) read through a view, with keys and
  `req-with-` helpers; responses (`res`) with bytevector, string, producer, port, sized
  and wrapped bodies; header helpers; and `wrap`.
- `(circuit test)`: `make-test-req`, `test-req-done!` and `res-body->bytevector`, for
  testing a handler with no server.
- `(circuit http-server)`, the adapter: `circuit->handler` and `run-server`, with every
  body kind but the upgrade, a port body of one piece or less read whole and sent as its
  bytes, a longer one sized from its length and closed however the response ends, the
  server's waits and conditions re-exported, and `CIRCUIT_PORT_PIECE_BYTES`. The import
  audit allows `port-has-port-length?` and `port-length`.
- Examples under `examples/`: hello, echo, a stream with server-sent events, and a long
  poll, each a plain R6RS program on `(circuit)` and `(circuit http-server)`, run over
  loopback by `make test`.
- The cost gate measures the real adapter, with its final bounds, and holds a port
  body's cost, G7 (ADR-0007).
- `(circuit middleware waits)`: `wrap-catch`, which answers a raise with a response,
  passes the server's `&client-closed` and `&deadline-passed` on, answers a
  `&body-failed` with its status, and by default logs a `handler-failed` line and
  answers 500; `wrap-timeout`, which answers 504 once a deadline passes; and `wrap-log`,
  which logs a line for each request once its response is done. The import audit allows
  `real-time` and `display-condition`. `examples/middleware.sps` composes the three, and
  `make test` runs it over loopback.
- The cost gate holds the real catch helper, G5, `wrap-log`'s own work, G8 own, and
  `wrap-timeout`'s cost, G9, and prints what logging costs, G8.
- Upgrades: `make-upgrade-res` answers 101 and hands the connection to a take-over, which
  the adapter passes to the server's `switch-protocols`. `res-upgrade-body?` and
  `res-upgrade-body-take-over` are in `(circuit)`, so middleware can rebuild an upgrade
  around a wrapped take-over. `res-remove-header` drops every field of a name and keeps
  the body, an upgrade's included. `(circuit http-server)` re-exports the server's
  transport procedures, and `awaiting` for a take-over that waits. An upgrade body lives only
  in the 101 `make-upgrade-res` makes: `make-res` and `res-with-body` refuse one;
  `res-with-body`, `res-with-status` and `res-wrap-body` refuse an upgrade response;
  `res-body-stream` and `res-body->bytevector` refuse an upgrade. `examples/upgrade.sps`
  echoes bytes back after the 101, and `make test` runs it over loopback.
- `(circuit router)`, a router that picks a handler by the path, then the method.
  - **The table:** `make-router` builds one handler from a table of `route`s, `group`s
    and `mount`s.
  - **Templates:** they hold words, `:param`s and a last `*catch-all`.
    - Where two templates differ, the leftmost segment that differs decides, and a word
      beats a parameter. So the table's order never matters.
    - Two templates of one shape are refused.
  - **Captured values** are percent-decoded, strictly, as UTF-8. One that doesn't decode
    answers 400.
  - **Methods:**
    - A route's method entries are `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`,
      `ANY`, and `METHOD` for any other.
    - HEAD goes to the route's own HEAD, else its GET, else its ANY.
    - A method the route doesn't take answers 405, with `allow`.
    - A path no route takes answers an empty 404, or what the app's not-found handler
      says.
  - **Groups:** a group's middleware runs only for its own routes.
  - **Mounts:** a mount's handler sees the rest of the path.
  - **Reading the match:** `req-route`, `req-path-param`, `req-path-params` and
    `req-mount-path`.
  - **The example:** `examples/router.sps`, which `make test` runs over loopback.
- The cost gate holds the router's own work for a word, a parameter and a miss, G10.
- `(circuit websocket)`: `websocket-res` answers a WebSocket handshake through
  chez-websocket's `websocket-handshake`. Taken, it answers the 101, whose take-over runs
  the app's procedure with the WebSocket; refused, the handshake's 400 or 403, with no
  body. Its settings and limits are chez-websocket's, and an app imports `(websocket)` for
  the rest. `examples/websocket.sps` echoes each message, and `make test` runs it over
  loopback.
- A WebSocket's limits are chez-websocket's `CHEZ_WS_` variables, read from the process's
  environment as the program starts, not from the `env` given to `run-server`. An app
  that wants them from its `env` builds them with chez-websocket's
  `websocket-limits-from-environment` and gives them to `websocket-res`.
- The build: chez-websocket v0.4.1 as a second pinned submodule. Its own server pin must
  be `SERVER_PIN`, which `make check-pins` holds; circuit doesn't clone that server. The
  import audit lets `(circuit websocket)` alone import `(websocket)`, and no library
  import any other `(websocket ...)` library, nor `(circuit websocket)`.
- A take-over's answer goes to the server, so a middleware that wraps a take-over must
  answer what it answers. Dropped, the 101 is written, and a WebSocket's procedure never
  runs.
- A request's own cap on its body, under the server's `CHEZ_HTTP_MAX_BODY_BYTES`, which
  stays the one cap a deployer sets. `(wrap-body-cap n)` caps the requests that pass it,
  and `req-with-body-cap` one request; `req-body-cap` reads the cap. The innermost cap
  wins, and `#f` leaves the server's alone. The server enforces it: a body past it raises
  `&body-failed`, 413, at the read that passes it, and a declared length past it fails
  the first read, before any `100 Continue`. A cap given once the body's port is made is
  refused. `make-test-req` reads its body whatever the cap. `examples/echo.sps` caps its
  body at 1 MiB.
- `res-wrap-body` takes `f` alone, `Producer -> Producer`, and its body has no length, so
  it goes out chunked; `same?` is gone. `res-tap-body` hands each piece of a body to
  `on-piece` as it goes out, unchanged, so its body keeps the length of the one under it.
  `on-piece` may wait, and never sees the end: a total is reported from `req-on-done!`. A
  piece that is no bytevector, an empty one, or one past the length raises before
  `on-piece` sees it.
