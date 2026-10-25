# ADR-0006: Only the adapter and `(circuit middleware waits)` import the server

- **Status:** Accepted (the owner's decision, 2026-10-25)
- **Date:** 2026-10-25
- **Amended:** 2026-10-25, after spike S2: the allowlist's one name is `getenv`, not
  `call/1cc` (the owner's decision)
- **Scope:** which circuit libraries may import what
- **Plan:** [the design](../2026-10-24-circuit-design.md) §6, §9, §11, §15 item 4

## Context

The core (requests, responses, headers, middleware that doesn't wait) needs nothing of the
server's, and a test calls a handler built from it directly, with no server. `wrap-timeout`
and the catch helper need the server's verbs (`with-deadline`, `deadline-passed?`,
`client-closed?`), and `with-deadline` is refused off a coroutine. The catch helper escapes
by `call/cc`, which is plain R6RS (spike S2). R6RS has no `getenv`, and the adapter reads its
settings from the process's environment when it is given no environment procedure, as
`serve` does with Chez's `getenv`.

## Decision

1. **The core is plain R6RS**: every circuit library but two imports only `(rnrs ...)`
   libraries other than `(rnrs eval)`, and core circuit libraries.
2. **`(circuit http-server)`, the adapter, and `(circuit middleware waits)`**, which holds
   `wrap-timeout` and the catch helper, may also import the server's libraries, but none of
   `(http-server private ...)`, **and take from `(chezscheme)` only through
   `(only (chezscheme) name ...)`, each name on the audit's allowlist**: `getenv` alone
   today. A bare `(chezscheme)` would give a library's body `import`, `eval` and `load`,
   which reach any library, the private ones included, whatever its header says.
3. **`make check-imports` holds both rules**, reading every file under `src/` as data.
   It reads the header's imports alone, which is enough because neither rule lets a
   library's body import anything. `make test` runs it once `src/` exists.

## Consequences

- **A handler built from the core alone is tested by calling it**, and so is one wrapped
  only in the catch helper, if it doesn't wait. One wrapped in `wrap-timeout` is tested
  through the server's fake shell.
- **An app that uses `wrap-timeout` imports three circuit libraries.**
- **A second adapter would carry its own copy of the waiting middleware**, or import this one.
- **Taking another name from `(chezscheme)` is a reviewed change** to the audit's
  allowlist, and the name must not be one that can import, evaluate or load.
- **`call/1cc` left the allowlist** when S2 found it the dearest escape on a coroutine:
  3.4–4.3 KB once a wait or Chez's `error` falls inside it, against 0.3–1.0 KB by
  `call/cc`. `make check-imports` now refuses it, and a suite row holds that.
