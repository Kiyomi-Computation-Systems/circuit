# ADR-0004: A handler is Req -> Res, and every request runs on a coroutine

- **Status:** Accepted (the owner's decision, 2026-10-25)
- **Date:** 2026-10-25
- **Amended:** 2026-10-25, after spike S2: the coroutines a request with a body pays for,
  and the gate; 2026-10-26, once the server's pull landed (its decision 0036): the app
  reads its body on the thunk's coroutine, and the adapter answers no reader
- **Scope:** the contract every circuit handler and middleware is written against
- **Plan:** [the design](../2026-10-24-circuit-design.md) §1, §2, §4, §9, §14, §15 item 2

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
   on that coroutine, and may wait with the server's verbs. The app reads its body through
   the server's `body-input-port`, which pulls it on that coroutine, so the thunk answers a
   response or a switch, never a reader (amended 2026-10-26; it said a request with a body
   had its reader answered from the thunk, and the app ran in the reader's end).
3. **No option calls an app in place.**
4. **The server's waits are the one async model.** Circuit defines no async primitive.

## Consequences

- **Waiting is ambient**: middleware calls `(handler req)` and gets a response back, however
  long the handler parked inside.
- **A response's producer runs after the handler has returned**, on a coroutine of its own
  for each piece, outside every middleware's dynamic extent.
- **Every request pays for one coroutine, the thunk's**, whatever its request body: the
  pull runs on it at any size (the server's decision 0036; design §4). A response body that
  is a producer or a port pays one more a piece, as any producer does (design §5). The
  interim this record first described, `read-whole-body` answered from the thunk, paid for
  three for a body and two for an empty one (spike S2), and is never built. S2 measured the
  cost, and the owner set the gate on circuit's cost over the raw server from it (design
  §15.6). It doesn't reopen item 3.
- **The body's reads run inside the handler call**, so a deadline or an exception handler
  around it covers them. Only that coroutine may pull, until the thunk answers: a producer
  can't read the request's body (design §4).
- **This holds from the pin at v0.9.0**, the first tag to carry the pull, where circuit's
  pin has been since 2026-10-26 (design §15.7).
