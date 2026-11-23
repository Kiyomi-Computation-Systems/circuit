# ADR-0013: A worker runs jobs on threads of its own, decided by a pure step function under one lock

- **Status:** Accepted, 2026-11-23, when the owner approved the design: "approved".
  Three adversarial reviews had read it. The owner answered the design's questions the
  same day:
  - Q1, "Never run it";
  - Q3, "Refuse them";
  - Q8, "One thread of its own";
  - Q14, "make-test-worker".

  The design's other answers stand as recommended.
- **Date:** 2026-11-23
- **Amended:** 2026-11-23, in slice W1: the bounded proof's consequence says what is
  exhausted, as built.
- **Amends:** [ADR-0006](0006-only-the-adapter-and-middleware-waits-import-the-server.md)'s
  items 1, 2 and 4, for the worker's two impure libraries (item 2 below).
- **Scope:** `(circuit worker)`, its machine, its shell and its double
- **Related:**
  - [ADR-0004](0004-a-handler-is-req-to-res-and-every-request-runs-on-a-coroutine.md);
  - [ADR-0007](0007-the-cost-gates-final-numbers.md);
  - [ADR-0012](0012-chez-http-server-0-12-0-from-a-submodule-until-akku-has-it.md);
  - [the design](../2026-11-23-worker-design.md), which holds the tables, the rules and
    the verification in full;
  - #53.

## Context

#53, filed by Techo's planning session, asks for a worker. A handler hands a blocking
job, such as a SQLite query, to threads of its own, and waits with the server's
`await-outside` while the loop serves everyone else.

- Its first comment adds several threads with a state each, for Techo's one writer and
  many readers.
- It asks that the worker be modelled as state machines and verified, not only tested.
- The worker is the first place in this stack where two threads touch one structure.

chez-http-server v0.12.0's decision 0039 is the contract the worker rests on:

- `resume` may be called from any thread, and answers `#t` once posted, `#f` after;
- a value posted to a wait that has ended is dropped;
- a wait begun off the loop's thread raises.

Three adversarial reviews on Opus found the flaws in the design's three drafts. One
was blocking, in the first: a `guard` around a job left and re-entered its
`dynamic-wind`, so a transaction lost a write and still committed. The other two found
none blocking. Every probe the reviews wrote was rerun, and reproduced, before its
finding was taken in (the design's §12 and §14).

## Decision

1. **`(circuit worker)`, a public library**, exports:
   - `make-worker`, `worker-call`, `worker-stop!` and `worker?`;
   - `make-test-worker`;
   - `&worker-full` and `worker-full?`, `&worker-stopped` and `worker-stopped?`;
   - `wrap-busy`.

   `(make-worker set-up cap [threads] [tear-down])` forks `threads` threads, one by
   default. Each thread runs `set-up` once and keeps its value as its state.
2. **Three libraries.**
   - `(circuit worker machine)` is the pure step function, plain R6RS and internal.
   - `(circuit worker shell)` is the threads, the lock and the protocol. It is internal,
     and impure: it imports `(only (http-server) await-outside deadline-passed?
     client-closed?)` and thread names from `(chezscheme)` on an allowlist of its own.
   - `(circuit worker)` re-exports the shell, without its observer hook, and adds
     `wrap-busy`.

   ADR-0006's items 1, 2 and 4 are amended:
   - these two may import as said;
   - `(circuit worker)` may import `(circuit worker shell)`, the one exception to "no
     library imports an impure one".

   No other library imports either one. `make check-imports` holds it:
   - rule (d)'s `(chezscheme)` names become a list per library;
   - rules (b) and (c) name the new libraries;
   - a new rule like (i) allows the facade's import.
3. **Every decision about jobs, threads and the queue is in `step : Machine Event ->
   (values Machine Reply Effects)`, under one mutex.** The shell carries out the
   effects, outside the lock: posts, signals, and the wake of the maker and the
   stoppers. The design's §4.2 is the table, its rows held as data by the suite.

   Two things are the shell's alone, and real-thread rows check them, not the
   explorer:
   - the broken worker, after a raise from `step` or the protocol;
   - the double's mark.
4. **A call gives its job to an idle thread at once, under the lock.** A call is
   refused `&worker-full` only when no thread is idle and the queue holds `cap` jobs. It
   is refused `&worker-stopped` once a stop has begun.
5. **A job whose caller leaves before it begins never runs** (Q1). That covers a queued
   job, and a job given to a thread that hasn't begun it. A running job runs on, and
   its answer is not posted. So abandoned jobs count against the cap only while queued,
   and never pile up (Q2).
6. **`worker-stop!` refuses every job not yet begun with `&worker-stopped`**, waits for
   the running ones, runs `tear-down` on each thread, joins every thread, and raises
   the lowest thread's tear-down raise (Q3, Q5). It is refused on a worker's own
   thread, by thread id (Q10). The worker doesn't stop with the server (Q6).
7. **A set-up's raise leaves `make-worker`**, the lowest thread's, once every forked
   thread has been joined (Q4).
8. **The double, `make-test-worker`, is the shell with one thread and a cap of 0**
   (Q8, Q14). Its `register` blocks until its own ticket's answer is posted, by whoever
   posts it. It goes through `await-outside` as the real worker does.
9. **A job that leaves its thread stops the worker** (Q9). An `exit` is the example.
   Its caller gets an `&error`, not `&worker-stopped`, since the job may have committed.
10. **A job, a set-up and a tear-down run under a two-layer `with-exception-handler`
    catch**, never a `guard`. A continuable `&warning` passes to the thread's default
    handler, and the job goes on (Q12). A job's values, however many, are its answer.
11. **The shell's rules** are the design's R1 to R12. Among them:
    - interrupts are disabled across the update of the state alone, and a section
      releases the lock before it enables them;
    - a section's own handler releases the lock, restores the interrupt count, and
      passes the raise on with `raise`, before any outer handler runs;
    - abandonment is seen by a pass-through handler, on a deadline or a close alone;
    - a broken worker tells every ticket an `&error`, and stops.
12. **The verification is the design's §8,** in five layers, each mutant in §8.8 seen to
    fail:
    1. static checks of the tables;
    2. every row driven against `step`;
    3. exhaustive small worlds of the step function, the shell's protocol as modelled,
       and the server's contract as modelled;
    4. random walks, and the real shell under schedules an observer sets;
    5. real threads.

    Rows against the server's test host hold the modelled contract to the server. TLA+
    is not used while there is one lock.
13. **Two new held gates:** G11, the machine's own allocation per job, and G12,
    `wrap-busy` over the app. Their bounds are fixed in the build under ADR-0007.

## Consequences

- **A 504 means "didn't happen" for every job that hadn't begun,** which is most of
  them while a writer stalls. A running job's 504 still means "maybe". The docs say a
  write a client may retry should be idempotent.
- **A write still queued after the server's own stop is neither committed nor told.**
  Under item 6's refusal, its `&worker-stopped` post is lost, since the inbox has
  closed. A drain would have committed it.
  - Techo's first T5, "every accepted write is committed, or its caller was told it
    was not", held only under a drain.
  - The owner accepted a restated T5 on 2026-11-23, in Techo's ADR-0008 amendment of
    that date: no caller is told a write succeeded unless it committed, and a write
    whose caller got no answer is committed whole or not at all.
  - Refusing keeps that (the design's §6, Q3).
- **No worker procedure may be called from an interrupt handler,** and nothing refuses
  it. Most land where the lock isn't held, and run as from anywhere. One that lands
  where it is held, between taking it and disabling interrupts or around a held step:
  - a `worker-call` parks holding the lock, and the worker hangs;
  - a `worker-stop!` of the same worker raises, and breaks it.

  See the design's §3, R5 and §8.7.
- **The double is stricter than #53's inline double.** A wait in a job raises, and a
  state used across threads is caught. It hangs where the real worker wouldn't: a job
  that never ends, and a handler holding its own lock across the call.
- **The proof is bounded, and is not the whole cross of its bounds.** Layer 3
  exhausts chosen configurations, `make test`'s and `make check-worker-model`'s. Their
  suites' headers give the reasoning, and W1's close-out lists each one.
  - A flag adds optional events, so a configuration's checks at every step and world
    cover it without the flag too. Each liveness check runs where no optional event can
    rescue a stuck party.
  - A failed start never meets a handler or a stopper, since neither acts before the
    maker is answered ready. So fork and set-up failures are explored without handlers.
  - Not exhausted anywhere, and reached only by the random walks (up to 4 threads, a cap
    of 8, 50 handlers and two stoppers):
    - 3 threads with 4 handlers and two stoppers;
    - 2 threads and 3 handlers with every flag and two stoppers;
    - worlds with deadlines, or every flag, at 3 threads and 4 handlers.

  Two things are held by review alone:
  - the shell's R3, since the observer has no point inside the lock;
  - S4, that a thread's state never enters the shared record.
- **Building it is three slices,** each reviewed:
  - W1, the machine and its explorer;
  - W2, the shell, the double, `wrap-busy` and the contract rows;
  - W3, the docs page, the example and the records.
