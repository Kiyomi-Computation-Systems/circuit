# S2: what a coroutine for every request costs

Date: 2026-10-25. Design §13 (S2), §15 item 2. Every request runs on a coroutine
whatever this says; S2 records the cost and proposes the gate.

## Answer

- **A GET through an adapter-shaped prototype allocates 1,324–1,409 B a request more
  than the raw server**: 6,406–6,624 B against 5,081–5,215 B. The coroutine is
  1,036–1,124 B of it. At 50 keep-alive connections it answers **93.5–95.3% of raw's
  rate**.
- **A 13-byte POST read whole costs 2,863–2,951 B more**, because it makes three
  coroutines, not two: the thunk, the body's one piece, and the reader's end. It runs
  at 94.4% of raw's rate.
- **Five `req-set` middlewares add 398–403 B**: 80 B each, a record copy and *two* pairs.
- **The catch helper should escape by `call/cc`, not `call/1cc`.** On a coroutine,
  `call/1cc` is the dear escape. It costs 3.4–4.3 KB once anything captures a full
  continuation between its capture and its use, and a park or Chez's own `error` does.
  `call/cc` is the cheapest of the three, and it is plain R6RS.
- **0025's `guard` figure is the right one**, not `docs/waiting.md`'s.
- **Proposed gate**: see the last section.

## Setup

- **Machine**: Intel Core Ultra 5 125H (14 cores, 18 threads), 62 GB, Linux
  7.1.1-76070101-generic x86_64, in the pinned Guix container.
- **Software**: Chez Scheme 10.4.1 (ta6le), threaded. libuv 1.52.1. The server is
  v0.8.0 (a996eef), carrying chez-libuv v0.11.0, chez-httparse v0.5.0 and uriparse
  v0.8.0. oha 1.16.0 (`build/oha`), curl 8.20.0.
- **chez-libuv's shim**: the dev flavour, `-g -O0 -DCHEZ_LIBUV_DEBUG_COUNTERS`
  (`build/.flavor-dev`), as in the server's `docs/performance.md`.
- **Compilation**: `scheme --program` compiles the libraries from source as it loads
  them, at the default optimize level.
- **One process per mode.** It runs one server, started as `serve` starts one, and
  switches its handler between variants. So every variant runs in the same build as its
  baseline. oha or curl is spawned on the server's loop, and the loop is turned as
  `serve` turns it. This is the method of the server's `hoist-request-alloc.sps`.
- **Bytes** are `sstats-bytes` across oha runs of 5,000 and 25,000 requests,
  alternating. The figure is the difference over the extra 20,000.
- **Noise**: spike S1 ran on the same machine throughout. Requests-a-second figures are
  noisy at 1 connection; allocation counts are per process and are not affected.

The prototype (`s2-coroutine-cost.sps`) holds:

- §3's `req`, with a view built once and keys in an alist;
- §5's `res`;
- the adapter: `awaiting` for every request, then §4's judgement from the head
  (`Transfer-Encoding`, or a `Content-Length` other than `0`), then the `req`, the app's
  `(make-res 200 '(("content-type" . "text/plain")) "hello\n")`, and the conversion,
  with headers as Latin-1 and the body as UTF-8.

`get-raw` returns the same response, built once. `get-raw-built` builds it per request,
which is the deliberate difference between the two.

## Commands

From the worktree root:

```sh
scripts/guix-env sh .plans/research/spike/s2-run.sh bytes          # 2 rounds, 25,000: ~15 min
scripts/guix-env sh .plans/research/spike/s2-run.sh rps            # oha -z 5s, 2 rounds: ~10 min
scripts/guix-env sh .plans/research/spike/s2-run.sh rps 10 3 main  # the main rows only, longer
scripts/guix-env sh .plans/research/spike/s2-run.sh show           # coroutines; catch helper
```

Each mode ends by printing its whole table. Raw output from the runs reported here is in
`build/s2/` (git-ignored).

## Bytes a request

Two rounds. An earlier run of the same rows (`build/s2/bytes-1.txt`) agreed within 6 B.

| variant | baseline | 1 conn | 50 conns | over baseline, 1 | over baseline, 50 |
|:--|:--|--:|--:|--:|--:|
| get-raw | | 5,210–5,215 | 5,081–5,083 | | |
| get-raw-built | get-raw | 5,277–5,278 | 5,144–5,146 | +64–67 | +62–63 |
| get-awaiting | get-raw | 6,334–6,335 | 6,118–6,119 | +1,121–1,124 | +1,036–1,037 |
| get-adapter-no-check | get-raw | 6,475 | 6,260–6,263 | +1,260–1,265 | +1,177–1,181 |
| **get-adapter** | get-raw | 6,619–6,624 | 6,406–6,407 | **+1,409** | **+1,324–1,325** |
| get-five | get-adapter | 7,022 | 6,808–6,810 | +398–403 | +401–403 |
| post-raw | | 6,770–6,773 | 6,633–6,634 | | |
| post-awaiting | post-raw | 9,273–9,274 | 9,045–9,049 | +2,500–2,503 | +2,412–2,415 |
| **post-adapter** | post-raw | 9,721–9,722 | 9,496–9,500 | **+2,949–2,951** | **+2,863–2,865** |

**Where get-adapter's 1,324–1,409 B go**, as paired differences (1 conn / 50 conns):

| Part | Bytes |
|:--|:--|
| The coroutine (get-awaiting − get-raw) | 1,120–1,124 / 1,036–1,037 |
| `req`, `res`, the conversion, a response built per request (no-check − awaiting) | 140–141 / 141–145 |
| ↳ of which any app that builds its response pays (raw-built − raw) | 63–67 / 63 |
| §4's judgement from the head (adapter − no-check) | 144–149 / 143–147 |

§4's judgement costs as much as the request and response records together. The
facade's `request-header` and `request-header-values` call `string->utf8` on the name at
every call; A8 removes the cost. **POST**: post-adapter − post-awaiting is 447–451 B,
which includes a bytevector port over the body.

## Requests a second

`oha -z 5s`, two rounds. Within a round the variants take turns, each round starting
one variant further on. "Of baseline" pairs the two rates round by round.

| variant | baseline | 1 conn | 50 conns | of baseline, 1 | of baseline, 50 |
|:--|:--|--:|--:|--:|--:|
| get-raw | | 27,813–28,359 | 120,337–122,363 | | |
| get-raw-built | get-raw | 27,007–27,153 | 119,238–121,346 | 95.2–97.6% | 97.4–100.8% |
| get-awaiting | get-raw | 26,104–29,801 | 114,065–118,407 | 92.0–107.1% | 94.8–96.8% |
| **get-adapter** | get-raw | 25,627–26,521 | 114,451–114,634 | 92.1–93.5% | **93.5–95.3%** |
| get-five | get-adapter | 26,346–26,380 | 112,676–113,629 | 99.5–102.8% | 98.3–99.3% |
| post-raw | | 25,960–26,117 | 105,262–105,548 | | |
| post-awaiting | post-raw | 24,399–24,861 | 103,417–103,550 | 93.4–95.8% | 98.0–98.4% |
| **post-adapter** | post-raw | 24,235–25,664 | 99,404–99,656 | 92.8–98.9% | **94.4%** |

- **The 1-connection column is noise-bound.** `catch-none-ok` is the same handler as
  get-adapter, and it read 96.4–114.2% of get-adapter.
- **The catch rows** (below) run at 94–103% of their baseline at 50 connections,
  except an unwrapped raise.

## The coroutines each path makes

From `show` mode. Each line names where code ran: the handler, the thunk, the reader's
piece and end, the app or the reader's procedure. Coroutines are numbered by first
appearance, and "none" means no coroutine. Had the end run on the piece's or the
thunk's coroutine, a path would have printed two coroutines, or one.

```text
GET, raw: the handler in place                     handler on none; coroutines: 0
GET, the adapter                                   app on #1; coroutines: 1
GET, awaiting a reader (no body)                   handler on none, thunk on #1, end on #2, proc on #2; coroutines: 2
POST, raw: read-whole-body in place                handler on none, piece on none, end on none, proc on none; coroutines: 0
POST, awaiting: read-whole-body from the thunk     handler on none, thunk on #1, piece on #2, end on #3, proc on #3; coroutines: 3
POST chunked, awaiting                             handler on none, thunk on #1, piece on #2, end on #3, proc on #3; coroutines: 3
```

- **A request with a body costs three coroutines, not two**: the server calls a waiting
  handler's every piece on a coroutine (`deliver-body!`), and a whole reader is handed
  its body as one piece. A streaming reader would cost one coroutine a piece, plus the
  end.
- **A reader on a bodiless request costs two**, one more than calling the app in the
  thunk, as §4 and §14 say.

## The catch helper: cost

The rows are variant 3's app wrapped in each catch. Each figure is over the unwrapped app
with the same park, as paired differences: 1 conn / 50 conns, in bytes.

- **guard**: `(guard (e ((not (passes? e)) (error-res))) ...)`.
- **helper, `call/1cc`**: the brief's helper, `call/1cc` around `with-exception-handler`.
- **helper, `call/cc`**: the same with `call/cc`.
- **`w-e-h` alone**: `with-exception-handler`, which raises again and never escapes.

| | nothing raised | `error` raised | plain `(raise (make-error))` | park, nothing raised | park, `error` raised |
|:--|--:|--:|--:|--:|--:|
| **guard** | 392–393 / 382–385 | 1,300–1,301 / 1,288–1,292 | 901 / 892–898 | 370–373 / 365–373 | 1,230–1,240 / 1,217–1,228 |
| **helper, `call/1cc`** | 852–853 / 407–410 | 4,215–4,216 / 4,327–4,333 | 1,130–1,133 / 652–672 | 3,418–3,424 / 3,527–3,538 | 4,052–4,062 / 4,160–4,173 |
| **helper, `call/cc`** | 343–345 / 336 | 1,030–1,038 / 1,028–1,031 | 585 / 575–578 | 322–325 / 317–320 | 955–965 / 961–971 |
| `w-e-h` alone | 161–164 / 161–168 | | | 304–305 / 301 | |
| none | 0 | 7,677–7,686 / 7,856–7,858 | 7,177–7,184 / 7,353–7,360 | 0 | 7,604–7,612 / 8,248–8,254 |

**The baselines.** "Nothing raised" is over the app answering 200 (6,618–6,619 /
6,402–6,407 B, which equals get-adapter). The park itself, one `(sleep-ms 0)`, costs
1,364–1,374 / 828–835 B.

**Why `call/1cc` costs the most.** Chez's `error` puts the raise's continuation in its
condition: `continuation-condition?` is `#t`, and a hand-made `&error` carries none.
Either that capture or a park's `call/cc` promotes the one-shot continuation, so Chez
cannot reuse the stack segment `call/1cc` started. That is the server's decision 0025's
mechanism. Without the capture (the plain-raise column), `call/1cc` costs 652–1,133 B.
That is still more than `call/cc`, and it varies with the connection count.

**Each raise row includes the same things**: building the catch's 500 `res` and
converting it, and the condition. "none" with a raise is the server's own 500 with
`handler-failed`. The server then closes the connection, so the figure includes a new
connection a request, and its rate is 28–33% of the baseline at 50 connections. A
catch keeps the connection.

**Requests a second at 50 connections** for the catch rows (no run of `w-e-h` alone or
the plain raise):

| | of baseline |
|:--|:--|
| guard | 100.2–101.5% nothing raised, 96.4–97.5% raised; 101.4–101.9% and 94.9–95.6% with a park |
| helper, `call/1cc` | 98.3–101.6%, 94.2–98.7%; 99.7–99.9%, 94.1–95.7% |
| helper, `call/cc` | 98.4–101.3%, 95.1–97.9%; 100.1–102.6%, 98.0–98.4% |
| park alone, over get-adapter | 90.2–90.6% |

## The catch helper: correctness across a park

From `show` mode. The responses come through curl, and Date headers are cut. An outer
recorder notes what left the wrapped app: a return with its status, or a raise by kind.
"resumed" counts runs of the app's code after its park.

```text
helper, the app parks once then raises: the helper's 500, no handler-failed
  curl exit 0 after 7 ms: HTTP/1.1 500 Internal Server Error | content-type: text/plain | Content-Length: 31 |  | circuit: internal server error |
  recorded ((returned 500)), resumed 1, logged ()                                  as expected
helper, the app parks three times then raises: the same                            (same output)   as expected
helper by call/cc, parks once / three times then raises                            (same output)   as expected
guard, the app parks once then raises: guard's 500 too                             (same output)   as expected
control, no catch: the server's own 500, handler-failed logged, the connection closed
  curl exit 0 after 6 ms: HTTP/1.1 500 Internal Server Error | Content-Length: 0 | Connection: close |  |
  recorded ((raised error)), resumed 1, logged (handler-failed)                    as expected
control, a dead escape: a one-shot continuation already returned through, invoked after a park
  curl exit 0 after 8 ms: HTTP/1.1 500 Internal Server Error | Content-Length: 0 | Connection: close |  |
  recorded ((raised other)), resumed 1, logged (handler-failed)                    as expected
deadline: wrap-timeout 50 ms outside the helper, the app parked 3 s: a 504, the helper re-raised it
  curl exit 0 after 56 ms: HTTP/1.1 504 Gateway Timeout | content-type: text/plain | Content-Length: 16 |  | deadline passed |
  recorded ((raised deadline-passed)), resumed 0, logged ()                        as expected
deadline, the helper by call/cc: the same 504, re-raised                           (60 ms)         as expected
control, a catch that swallows the deadline: a 500, not a 504
  curl exit 0 after 60 ms: HTTP/1.1 500 ... | circuit: internal server error |
  recorded ((returned 500)), resumed 0, logged ()                                  as expected
client-closed: curl leaves after 300 ms, the app parked 3 s inside the helper: re-raised, not logged
  curl exit 28 after 313 ms:
  recorded ((raised client-closed)), resumed 0, logged ()                          as expected
client-closed, the helper by call/cc: re-raised, not logged                        (314 ms)        as expected
control, the swallowing catch and the client's close: the close is taken for an error
  recorded ((returned 500)), resumed 0                                             as expected
```

What each claim would have printed had it been false:

- **The escape works after a park.** A dead escape looks like the control: the server's
  empty 500 with `Connection: close`, a raise recorded, and `handler-failed` logged. The
  helper's runs show its own 500 body, one return, and nothing logged. So the
  `call/1cc` continuation, captured before a full-continuation park, still escapes
  after it: the park's capture promotes it. That promotion is also what makes it
  expensive.
- **The code after the park ran once** (`resumed 1`). A re-run landing would read 2, or
  the server's refusal would show as `handler-failed`.
- **`&deadline-passed` passes through.** Had the helper swallowed it, the response would
  be its 500, as the swallowing control's is, not the 504. It came at 56–60 ms, not
  after 3 s.
- **`&client-closed` passes through.** Swallowed, the recorder reads `(returned 500)`,
  as in its control.

## Which guard figure

**0025's.** `guard` on a coroutine, catching an `error`, costs 1,217–1,301 B here,
against 0025's 1,238–1,304 B. When nothing raises, which is the per-request case, it
costs 365–393 B.

`docs/waiting.md`'s "about 3.7 KB" is decision 0015's 3,756 B a coroutine. That was
measured when the drain entered coroutines on a one-shot continuation, before 0025's
amendment made it full. In circuit's setting, the 3.4–4.3 KB class belongs to a
`call/1cc` escape, once a park or an `error` falls inside it.

`with-exception-handler` alone costs 161–168 B: small, but not "next to nothing". At
circuit's level, `guard` is not "about twice" an exception handler's escape:
- nothing raised: 46–49 B more than the `call/cc` helper;
- catching an `error`: 260–270 B more.

## Proposed gate

Bytes are exact and repeatable, so the suite can hold them. Each figure is measured in
one process beside the raw handler, at 1 and 50 keep-alive connections, with this
spike's method.

| # | Gate | Measured | Headroom |
|:--|:--|:--|:--|
| G1 | a GET through the adapter allocates ≤ raw + **1,536 B** | +1,324–1,409 | 127–212 B |
| G2 | a 13-byte POST read whole through the adapter allocates ≤ raw + **3,072 B** | +2,863–2,951 | 121–209 B |
| G3 | circuit's own work over the server's `awaiting` path: ≤ **384 B** for a GET, ≤ **512 B** for a POST | 285–288; 447–451 | 96–99; 61–65 B |
| G4 | a `req-set` allocates ≤ **96 B**; five, ≤ 480 B | 80; 398–403 | 77–82 B |
| G5 | the catch helper, nothing raised, ≤ **512 B** over the unwrapped app | 336–345 (`call/cc`) | 167–176 B |
| G6 | at 50 keep-alive connections, a GET through the adapter answers ≥ **90%** of raw's rate, alternating, 2 rounds at least | 93.5–95.3% | 3.5–5.3 points |

- **G1 and G2 include the server's coroutines** (1,036–1,124 and 2,412–2,503 B), so a pin
  move can trip them. G3 is the part circuit controls. The gate's run should print the
  `awaiting` row beside them, so a failure names whose cost moved.
- **G5 passes `guard` (365–393 B) and fails a `call/1cc` helper**: 852 B at 1
  connection, and 3,418 B or more once the app parks.
- **G6 is a smoke, not a suite gate.** At 1 connection the spread here was ±7%, so there
  is no gate there. The 90% wants confirming on the quiet rerun.

## What the design gets wrong

1. **§6, the escape**: "The cheap escape is Chez's `call/1cc`; a portable `call/cc` on a
   coroutine … costs what `guard` does." It is the other way round. `call/cc` is the
   cheapest, `guard` is within 50 B of it, and `call/1cc` is the dearest, by 3.4–4.3 KB
   once a park or an `error` falls inside it. So:
   - the catch helper needs nothing from `(chezscheme)`;
   - §11's "the catch helper's `call/1cc` is Chez-only" goes;
   - ADR-0006's allowlist (`call/1cc` alone), `global-constraints.md`'s line on it, and
     `tests/check-imports.sps`'s `chez-names` could go to none.
2. **§6, the figures**: "1,238 to 1,304 B against 625 to 691 B" is `guard` *catching a
   raise* against the scheduler's handler catching one. With nothing raised, `guard`
   costs 365–393 B here.
3. **§4 and ADR-0004**: "a bodiless request costs one coroutine, not two" and "one with
   a body for two". A body read whole costs **three** (thunk, piece, end), 2,412–2,503 B
   over raw. A reader on a bodiless request costs two. A streaming reader costs one a
   piece, plus the end.
4. **§3, `req-set`**: "n record copies and n pairs" should read **n record copies and 2n
   pairs**: the binding and the alist's cell. That is 80 B a set.
5. **§4's judgement is not free**: 143–149 B a request, about a tenth of circuit's cost
   over raw, because the facade converts each header name with `string->utf8`. That
   strengthens A8.
6. **Not in the design**: an app's raise that reaches the server costs the client its
   connection (`Connection: close`). With no catch, that is 28–33% of the rate at 50
   connections, for every failing request.

## Rerun

Rerun by the session that set the spike, 2026-10-25, once S1 had ended and
nothing else ran on the machine.

**Requests a second**, `s2-run.sh rps`, as above. At 50 connections, of
baseline:

| variant | quiet rerun | above, with S1 running |
|:--|--:|--:|
| get-awaiting | 95.8–98.6% | 94.8–96.8% |
| get-adapter | 93.0–95.1% | 93.5–95.3% |
| get-five, of get-adapter | 99.6–100.2% | 98.3–99.3% |
| post-awaiting | 94.6–96.5% | 98.0–98.4% |
| post-adapter | 91.2–92.6% | 94.4% |
| catch-none-raise, of catch-none-ok | 30.5–31.5% | |

At 1 connection the spread was ±10% even on the quiet machine. G6 holds.

**Bytes a request**, `s2-run.sh bytes 1 10000`: one round, so each figure
is read over 5,000 requests more and is coarser than the tables above; the
zero control, catch-none-ok over get-adapter, read -30 / -3 B. Over
baseline, at 1 / 50 connections:

| variant | rerun | | variant | rerun |
|:--|--:|:--|:--|--:|
| get-awaiting | +1,154 / +1,043 | | catch-guard-ok | +414 / +377 |
| get-adapter-no-check | +1,293 / +1,180 | | catch-helper-ok | +860 / +410 |
| get-adapter | +1,440 / +1,333 | | catch-helper-cc-ok | +365 / +309 |
| get-five, over get-adapter | +383 / +409 | | catch-handler-only-ok | +176 / +154 |
| post-awaiting | +2,493 / +2,413 | | catch-guard-ok-park | +393 / +341 |
| post-adapter | +2,944 / +2,865 | | catch-helper-ok-park | +3,424 / +3,525 |
| catch-guard-raise | +1,306 / +1,295 | | catch-helper-cc-ok-park | +324 / +307 |
| catch-helper-raise | +4,216 / +4,316 | | catch-handler-only-ok-park | +319 / +302 |
| catch-helper-cc-raise | +1,034 / +1,038 | | catch-guard-raise-park | +1,259 / +1,197 |
| catch-none-raise | +7,710 / +7,869 | | catch-helper-raise-park | +4,067 / +4,135 |
| catch-none-raise-park | +7,631 / +8,254 | | catch-helper-cc-raise-park | +970 / +971 |

Each agrees with the tables above to about 30 B, the coarser count's
precision. The judgement from the head, get-adapter over
get-adapter-no-check, read +147 / +153 B. After the rerun the gate's
headroom is G1 96 B (1 connection), G5 147 B, G6 3.0 points.

**Show**: the 19 cases as expected. Three of them, the coroutine counts
for the POST paths and a reader on a GET, check only the status: their
evidence is the printed story, read against `shell.sls:961-983`. `(guard (e (#t (continuation-condition?
e))) X)`, run as a script in the container: `#t` for `(error 'app "boom")`
and for `assertion-violation`, `#f` for `(raise (make-error))`. The 3.7 KB in
the server's `docs/waiting.md` traces to its milestone plan before the
guides moved to Markdown (ca82ff5~1): "M7.1's scheduler allocates 3,756 B a
coroutine, because its `guard` sits…", before decision 0025.
