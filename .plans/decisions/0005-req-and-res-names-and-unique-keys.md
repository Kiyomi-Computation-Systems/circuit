# ADR-0005: `req` and `res` names, apart from the server's, and unique keys for middleware's data

- **Status:** Accepted (the owner's decisions, 2026-10-25)
- **Date:** 2026-10-25
- **Amended:** 2026-10-27, in slice 6a: the server's transport procedures and
  `awaiting`, which a take-over answers to wait, join the re-exports, so an app that
  upgrades needs only circuit's libraries (the owner's decisions, design §15.17 and
  §15.18)
- **Amended:** 2026-11-06, in slice 10a: responses get keys of their own, for a
  handler's data to the middleware around it (the sessions design §3, which the owner
  approved on 2026-11-01, design §15.33)
- **Scope:** circuit's public names, and how middleware adds data to a request, and a
  handler to a response
- **Plan:** [the design](../2026-10-24-circuit-design.md) §3, §5, §9, §15 items 1 and 3, and
  [the sessions design](../2026-11-01-sessions-design.md) §3

## Context

`(http-server)` exports `make-response`, `response?`, `request?`, `request-method`,
`request-path`, `request-query`, `request-header`, `request-header-values`,
`request-host` and `serve`. Names of circuit's own that equal them would make an app
that imports both libraries reach for `only` or `rename`. Ring's middleware adds data to a
request as map keys, and two libraries can collide on one.

## Decision

1. **Requests are `req` and responses `res`.** The accessors are `req-method`,
   `req-path`, `req-header` and the rest; the constructor is `make-res`, and the
   accessors `res-status`, `res-headers`, `res-body`.
2. **The adapter's entry is `run-server`**, and the procedure that makes a server handler
   is `circuit->handler`.
3. **No export of circuit's names a binding `(http-server)` exports**, except the server's
   waits, conditions, transport procedures and `awaiting`, which `(circuit http-server)`
   re-exports as the same bindings.
   A suite that imports `(http-server)`, `(circuit)` and `(circuit http-server)`
   together, with no `only` or `rename`, holds it.
4. **Middleware's data goes under unique keys**: `(make-req-key name)` makes one,
   `(req-ref req key [default])` reads it, and `(req-set req key value)` gives a new
   request. A handler's data for the middleware around it goes on the response the
   same way: `(make-res-key name)`, `(res-ref res key [default])` and
   `(res-set res key value)`. Every response helper keeps a response's keys, and none
   reaches the wire. A key's kind says where its data lives: each side refuses the
   other's. A library exports accessors for its own keys, not the keys' names.

## Consequences

- **Two libraries can't collide on a key**, and a key's name is for printing only.
- **Every response costs 16 B more** for its keys: the record holds four fields, 48 B
  on Chez 10.4.1, where three took 32 B (the sessions design §3).
- **An app imports circuit and the server together freely.**
- **Names that read like Ring's are not Ring's**: `res-` and `req-` throughout.
