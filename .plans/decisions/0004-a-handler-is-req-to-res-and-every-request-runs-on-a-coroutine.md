# ADR-0004: A handler is Req -> Res, and every request runs on a coroutine

- **Status:** Accepted (the owner's decision, 2026-10-25)
- **Date:** 2026-10-25
- **Scope:** the contract every circuit handler and middleware is written against
- **Plan:** [the design](../2026-10-24-circuit-design.md) §1, §2, §9, §14, §15 item 2

## Context

chez-http-server's handler answers `Response | BodyReader | Awaiting | Switch`. A handler
that answers `(awaiting thunk)` runs `thunk` on a coroutine, where `await`, `sleep-ms`,
`with-deadline` and `resolve` park it on a continuation and return when it is resumed; the
server calls that handler's reader and producer on coroutines too. Any other handler, and
its reader and producer, run in place, where every wait is refused. Ring grew a
three-argument async handler because parking a JVM thread was expensive; here a parked
handler costs about 0.7 KB.

## Decision

1. **A handler is `Req -> Res`, and middleware is `Handler -> Handler`.** Circuit's API has
   no callbacks, no futures and no answer sum.
2. **The adapter answers every request with `awaiting`.** The app and every middleware run
   on that coroutine, and may wait with the server's verbs. A request with a body has its
   reader answered from the thunk, so the reader's end, where the app then runs, is on a
   coroutine too.
3. **No option calls an app in place.**
4. **The server's waits are the one async model.** Circuit defines no async primitive.

## Consequences

- **Waiting is ambient**: middleware calls `(handler req)` and gets a response back, however
  long the handler parked inside.
- **A response's producer runs after the handler has returned**, on a coroutine of its own
  for each piece, outside every middleware's dynamic extent.
- **Every request pays for a coroutine**, and one with a body for two. Spike S2 measures the
  cost; its number sets the gate on circuit's cost over the raw server. It doesn't reopen
  item 3.
