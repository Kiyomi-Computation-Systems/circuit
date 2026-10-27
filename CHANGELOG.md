# Changelog

All notable changes to circuit are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The API may change in any
release before 1.0.

## [Unreleased]

### Added

- The build: chez-http-server v0.9.0 as a pinned submodule, a pinned Guix development
  container, and `make test`.
- The pure core, `(circuit)`: requests (`req`) read through a view, with keys and
  `req-with-` helpers; responses (`res`) with bytevector, string, producer, port, sized
  and wrapped bodies (`res-wrap-body` provisional); header helpers; and `wrap`.
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
