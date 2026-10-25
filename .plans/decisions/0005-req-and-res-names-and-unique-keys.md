# ADR-0005: `req` and `res` names, apart from the server's, and unique keys for middleware's data

- **Status:** Accepted (the owner's decisions, 2026-10-25)
- **Date:** 2026-10-25
- **Scope:** circuit's public names, and how middleware adds data to a request
- **Plan:** [the design](../2026-10-24-circuit-design.md) §3, §5, §9, §15 items 1 and 3

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
   waits and conditions, which `(circuit http-server)` re-exports as the same bindings.
   A suite that imports `(http-server)`, `(circuit)` and `(circuit http-server)`
   together, with no `only` or `rename`, holds it.
4. **Middleware's data goes under unique keys**: `(make-req-key name)` makes one,
   `(req-ref req key [default])` reads it, and `(req-set req key value)` gives a new
   request. A library exports accessors for its own keys, not the keys' names.

## Consequences

- **Two libraries can't collide on a key**, and a key's name is for printing only.
- **An app imports circuit and the server together freely.**
- **Names that read like Ring's are not Ring's**: `res-` and `req-` throughout.
