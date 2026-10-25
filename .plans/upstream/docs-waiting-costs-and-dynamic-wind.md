Title: docs/waiting.md: stale costs, and what a wait does to dynamic-wind
Label: documentation
Filed: chez-http-server #231, 2026-10-25

**The problem**

Two things in `docs/waiting.md`, at v0.8.0 (a996eef), mislead someone
writing a handler that waits.

**1. "Costs to know" is stale.** It says (`docs/waiting.md:111`):
"Inside a handler that waits, `guard` costs about 3.7 KB each time it
runs. `with-exception-handler` costs next to nothing."

The 3.7 KB dates from before decision 0025. Then, M7.1's scheduler
allocated 3,756 B a coroutine, because the `guard` that caught a
coroutine's raise sat inside the one-shot continuation the drain entered
(decision 0015, `:23`). Decision 0025 made the drain's continuation full,
and its amendment gives a guard on a coroutine 1,238 to 1,304 B (`:170`).

These were measured through the whole server at v0.8.0, by the method of
`.plans/research/spike/hoist-request-alloc.sps`: oha, 5,000 GETs against
25,000 (10,000 in a rerun), kept alive, at 1 and 50 connections, on Linux
x86_64 with Chez 10.4.1. Each figure is the bytes a request allocates over the same handler
unwrapped, for a handler that answers `awaiting`:

| around the app | nothing raised | nothing raised, after one `(sleep-ms 0)` | catching `(error …)` | catching, after one `(sleep-ms 0)` |
|:--|--:|--:|--:|--:|
| `guard` | 377–414 | 341–393 | 1,288–1,306 | 1,197–1,259 |
| `with-exception-handler` alone | 154–176 | 301–319 | | |
| an escape by `call/cc` around `with-exception-handler` | 309–365 | 307–325 | 1,028–1,038 | 955–971 |
| an escape by `call/1cc` around `with-exception-handler` | 407–860 | 3,418–3,538 | 4,215–4,333 | 4,052–4,173 |

So, with today's numbers:
- `guard` costs about 0.4 KB with nothing raised, and 1.2–1.3 KB when it
  catches, as 0025's amendment says, not 3.7 KB;
- `with-exception-handler` costs 0.15–0.3 KB, not next to nothing;
- an escape by `call/1cc` is the dearest of the four. Once a park, or a
  raise by Chez's `error`, falls inside it, it costs 3.4–4.3 KB. `error`'s
  condition carries a continuation, so `continuation-condition?` is `#t`.
  An escape by `call/cc` costs less than `guard`.

**2. The guide doesn't say what a wait does to `dynamic-wind`.** A wait
leaves the coroutine's dynamic extent. The after thunk of every
`dynamic-wind` around the wait runs as the code starts waiting, and the
before thunk as it resumes. The server relies on this itself:
`with-deadline`'s after thunk asks `coroutine-suspending?` to tell a park
from a leaving (`src/http-server/private/waits.sls:385`).

A handler author can't know it from the guide. Code that releases a lock,
a transaction or a pooled connection in an after thunk releases it at
every wait inside, and its before thunk runs again at every resume.

Seen under the server: a reader parked inside Chez's `critical-section`,
which is a `dynamic-wind`. While it was parked, another handler saw
interrupts enabled and collections running. On the resume, the
interrupt-disable count was back to 1.

**What you propose**

In "Costs to know", the two lines replaced with, for example:

> Inside a handler that waits, `guard` costs about 0.4 KB each time it
> runs, and about 1.3 KB when it catches. `with-exception-handler` costs
> about 0.15 KB, or 0.3 KB if the code inside it waits. To escape on a
> raise, use `call/cc`: an escape by `call/1cc` costs 3.4 KB or more once
> the code inside it waits, or raises with `error`.

And a bullet under "Waiting for an event", for example:

> A wait leaves your code's `dynamic-wind`s and comes back into them: the
> after thunk of each one around the wait runs as the handler starts
> waiting, and the before thunk as it resumes. So don't release a resource
> in an after thunk, since it is released at every wait. Release it when
> your code returns, or in an exception handler.

**Where it comes from**

circuit, a Ring-like layer over the server, measured both while choosing
how its middleware catches raises:

- S2, the costs: [findings](https://github.com/Kiyomi-Computation-Systems/circuit/blob/bafb5f1/.plans/research/s2-coroutine-cost.md)
  and [program](https://github.com/Kiyomi-Computation-Systems/circuit/blob/bafb5f1/.plans/research/spike/s2-coroutine-cost.sps);
- S1, the `dynamic-wind` probe, its item 7: [findings](https://github.com/Kiyomi-Computation-Systems/circuit/blob/bafb5f1/.plans/research/s1-a-port-that-waits.md)
  and [program](https://github.com/Kiyomi-Computation-Systems/circuit/blob/bafb5f1/.plans/research/spike/s1-port-that-waits.sps).

**What the RFCs say**

Nothing: this is docs only.
