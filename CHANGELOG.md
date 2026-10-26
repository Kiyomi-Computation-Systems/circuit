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
