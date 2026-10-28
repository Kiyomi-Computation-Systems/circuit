# ADR-0006: Only the adapter and `(circuit middleware waits)` import the server

- **Status:** Accepted (the owner's decision, 2026-10-25)
- **Date:** 2026-10-25
- **Amended:** 2026-10-25, after spike S2: the allowlist's one name is `getenv`, not
  `call/1cc` (the owner's decision); 2026-10-26, once the server's asks landed: the catch
  helper needs `body-failed?` and `body-failed-status` too, and the waiting middleware is
  tested through the server's `(http-server testing)`, not its fake shell; 2026-10-26, in
  slice 3, after its review: the audit requires `#!r6rs` (item 3); 2026-10-26, in slice 4:
  the allowlist takes `port-has-port-length?` and `port-length` too, which size a port body
  (design §5, §15 item 8, the owner's decision); 2026-10-26, before slice 5: it takes
  `real-time` and `display-condition` too, the request log's clock and the catch helper's
  line (design §6, §7, §15 item 13, the owner's decision; both names accepted at slice
  5's review, 2026-10-27); 2026-10-28, in slice 6c: a third library, `(circuit
  websocket)`, may import chez-websocket's facade, `(websocket)`, which imports the server
  (item 4; the slice 6 design §6 and §7 item 4, design §15.16, the owner's decision)
- **Scope:** which circuit libraries may import what
- **Plan:** [the design](../2026-10-24-circuit-design.md) §6, §9, §11, §15 item 4

## Context

The core (requests, responses, headers, middleware that doesn't wait) needs nothing of the
server's, and a test calls a handler built from it directly, with no server. `wrap-timeout`
and the catch helper need the server's verbs (`with-deadline`, `deadline-passed?`,
`client-closed?`, `body-failed?`, `body-failed-status`), and `with-deadline` is refused off
a coroutine. `wrap-log` lives beside them: it reads Chez's clock, and this record allows
two impure libraries, not a third. The catch helper escapes
by `call/cc`, which is plain R6RS (spike S2). R6RS has no `getenv`, and the adapter reads its
settings from the process's environment when it is given no environment procedure, as
`serve` does with Chez's `getenv`. Nor does R6RS know a port's length: the adapter sends a
file or a bytevector port with its length, which it reads with Chez's
`port-has-port-length?` and `port-length` (design §5). Nor has R6RS a clock, which
request logging times a request with, nor a way to show a condition as the server's log
shows it, which the catch helper's line does (design §6, §7).

A WebSocket's logic is chez-websocket's. Its `websocket-handshake` takes what a host reads
of a request and answers string pairs and a take-over, so a host maps it onto its own
responses. But the take-over runs on the server's transport, so `(websocket)`, its facade,
imports the server (the slice 6 design §6; chez-websocket's ADR-0009).

## Decision

1. **The core is plain R6RS**: every circuit library but the three below imports only
   `(rnrs ...)` libraries other than `(rnrs eval)`, and core circuit libraries.
2. **`(circuit http-server)`, the adapter, and `(circuit middleware waits)`**, which holds
   `wrap-timeout`, the catch helper `wrap-catch` and request logging `wrap-log`, may also
   import the server's libraries, but none of
   `(http-server private ...)`, **and take from `(chezscheme)` only through
   `(only (chezscheme) name ...)`, each name on the audit's allowlist**: `getenv`,
   `port-has-port-length?`, `port-length`, `real-time` and `display-condition` today. A
   bare `(chezscheme)` would give a
   library's body `import`, `eval` and `load`, which reach any library, the private ones
   included, whatever its header says.
3. **`make check-imports` holds these rules**, reading every file under `src/` as data.
   It reads the header's imports alone, which is enough because no rule lets a
   library's body import anything. It also requires every file to begin with the line
   `#!r6rs` and hold `#!` nowhere else: without it, or after `#!chezscheme`, Chez reads a
   file with its own syntax (`'#3(0)`, `'#vfx(1 2)`), which no import shows. `make test`
   runs it once `src/` exists.
4. **`(circuit websocket)` may also import `(websocket)`**, chez-websocket's facade, and no
   other library may. No circuit library imports any other `(websocket ...)` library:
   not `(websocket handshake)`, nor any under `(websocket private ...)`. `(circuit
   websocket)` imports neither `(chezscheme)` nor an `(http-server ...)` library, as a
   core library doesn't, and since `(websocket)` imports the server, no library imports
   `(circuit websocket)`, as none imports an impure one. The audit's rule (i) holds it.

## Consequences

- **A handler built from the core alone is tested by calling it**, and so is one wrapped
  only in the catch helper, if it doesn't wait. One wrapped in `wrap-timeout` is tested
  through the server's test host, `(http-server testing)`, a public library the server's
  package installs; its fake shell is `(http-server private fake-shell)`, which item 2
  keeps out.
- **An app that uses `wrap-timeout` imports three circuit libraries.**
- **A second adapter would carry its own copy of the waiting middleware**, or import this one.
- **An app that takes a WebSocket imports `(circuit websocket)` and `(websocket)`**, beside
  `(circuit)` and `(circuit http-server)`. The names suite imports them all together.
- **`(circuit websocket)` is tested through the server's test host**, since its take-over
  runs on the server's transport.
- **A fourth library that reaches the server is a reviewed change**, as the third was.
- **Taking another name from `(chezscheme)` is a reviewed change** to the audit's
  allowlist, and the name must not be one that can import, evaluate or load.
- **The allowlist took `port-has-port-length?` and `port-length` in slice 4**, for the
  adapter's port bodies. Neither can import, evaluate or load.
  `tests/test-check-imports.sps` holds a fixture that takes both, which passes, and one that
  takes `file-length`, `set-port-length!`, `eval` and `port-has-set-port-length!?` beside
  them, each refused.
- **`call/1cc` left the allowlist** when S2 found it the dearest escape on a coroutine:
  3.4–4.3 KB once a wait or Chez's `error` falls inside it, against 0.3–1.0 KB by
  `call/cc`. `make check-imports` now refuses it, and a suite row holds that.
- **The allowlist took `real-time` and `display-condition` before slice 5**, for
  `wrap-log`'s clock and the catch helper's `handler-failed` line. `real-time` reads Chez's
  monotonic clock in milliseconds since the process started and allocates nothing.
  `display-condition` shows a condition as the server's own log does. Neither can import,
  evaluate or load. Weighed for the clock: an ask for the server to export its loop's clock
  (design §15 item 13).
