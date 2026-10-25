# ADR-0006: Only the adapter and `(circuit middleware waits)` import the server

- **Status:** Accepted (the owner's decision, 2026-10-25)
- **Date:** 2026-10-25
- **Scope:** which circuit libraries may import what
- **Plan:** [the design](../2026-10-24-circuit-design.md) §6, §9, §11, §15 item 4

## Context

The core (requests, responses, headers, middleware that doesn't wait) needs nothing of the
server's, and a test calls a handler built from it directly, with no server. `wrap-timeout`
and the catch helper need the server's verbs (`with-deadline`, `deadline-passed?`,
`client-closed?`), and `with-deadline` is refused off a coroutine. The catch helper's cheap
escape is Chez's `call/1cc`.

## Decision

1. **The core is plain R6RS**: every circuit library but two imports only `(rnrs ...)`
   libraries other than `(rnrs eval)`, and core circuit libraries.
2. **`(circuit http-server)`, the adapter, and `(circuit middleware waits)`**, which holds
   `wrap-timeout` and the catch helper, may also import `(chezscheme)` and the server's
   libraries, but none of `(http-server private ...)`.
3. **`make check-imports` holds both rules**, reading every file under `src/` as data.

## Consequences

- **A handler built from the core alone is tested by calling it.** One wrapped in
  `wrap-timeout` or the catch helper is tested through the server's fake shell.
- **An app that uses `wrap-timeout` imports three circuit libraries.**
- **A second adapter would carry its own copy of the waiting middleware**, or import this one.
