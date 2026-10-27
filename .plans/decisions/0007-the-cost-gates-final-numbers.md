# ADR-0007: The cost gate's final numbers

- **Status:** Accepted (the owner's decision, 2026-10-26, on slice 4's measurements)
- **Date:** 2026-10-26
- **Amended:** 2026-10-26: G7, a port body, is held (the owner's decision); 2026-10-26, in
  slice 5: G5 measures the real catch helper; G8, request logging, is printed, and its own
  share, G8 own, held; G9, `wrap-timeout`, is held with and without a park (the owner's
  decisions, design §15 items 13–15). The owner accepted G8 own's 384 B and G9's 768 B
  bounds at slice 5's review, 2026-10-27
- **Scope:** the bounds `make gate` holds and prints, and what they are measured on
- **Plan:** [the design](../2026-10-24-circuit-design.md) §4, §13, §15 item 6

## Context

The owner set the gate's shape on 2026-10-25, from spike S2 (design §15.6). Three gates
fail the build: G3, circuit's own work over the server's `awaiting` path; G4, one
`req-set`; and G5, the catch helper over the app, with nothing raised. G1 and G2, a GET and
a POST through the adapter over the raw server, are printed. G6, requests a second, is a
smoke that never fails. The numbers were S2's prototype's, provisional until slice 4
measured the real adapter. Slice 3's gate measured a stand-in adapter over the real core.

Two of them no longer fit. G2's 3,072 B and G3 POST's 512 B were set on the interim's
three-coroutine POST, which was never built (design §4). And G4's 96 B sat on Chez's 16 B
record size step, where a six-field request record failed it by 1 B.

## Decision

1. **The gate measures the real adapter**: `(circuit->handler app env)`, its environment
   answering `#f` for every name, so the process's environment moves no figure. The catch
   helper stays S2's `call/cc` stand-in until slice 5 brings the real one.
2. **The POST is pulled.** The adapter's app and the raw `awaiting` thunk each read the
   13-byte body with `get-bytevector-n` of its declared length, the cheapest read (design
   §4). The raw POST reads it with `read-whole-body`.
3. **The bounds**, in bytes a request, over 5,000 against 25,000 requests, two rounds, at
   1 and 50 keep-alive connections:

   | Gate | Bound | Held | Worst in 8 runs | What a known regression reads |
   |:--|--:|:--|--:|:--|
   | G1, a GET over raw | 1,536 | printed | 1,447 | a view made per request: 1,551 |
   | G2, a POST over raw | 1,536 (was 3,072) | printed | 1,443 | the body read by `get-bytevector-all`: 9,562 |
   | G3 GET | 384 | held | 311 | a view made per request: 419–425 |
   | G3 POST | 352 (was 512) | held | 280 | a view made per request: 384–385 |
   | G4 one | 88 (was 96) | held | 81 | a six-field request record: 97 |
   | G4 five | 440 (was 480) | held | 406 | a six-field request record: 484–487 |
   | G5 | 512 | held | 374; 385 on the real helper (in 7 runs) | a `call/1cc` catch helper: 849; the real one so: 875–927 |
   | G5 park | 512 | held | 343; 351 on the real helper | a `call/1cc` catch helper: 3,657; the real one so: 3,674–3,725 |
   | G7, a port body | 384 | held | 310 (in 2 runs) | the port streamed: 5,098; closed on a raise by two `guard`s: 658 |
   | G8, `wrap-log` | none | printed | 1,145 (in 7 runs) | its line built in a string port: 1,520–1,521 |
   | G8 own, `wrap-log` over a no-op `req-on-done!` | 384 | held | 302 (in 3 runs) | its line built in a string port: 653–688 |
   | G8 on-done, a no-op `req-on-done!` | none | printed | 870 | |
   | G9, `wrap-timeout` | 768 | held | 609 (in 7 runs) | a `call/1cc` escape: 1,131–1,137 |
   | G9 park | 768 | held | 614 | a `call/1cc` escape: 3,895–3,904 |

   G6 stays a smoke: at least 90% of raw's rate at 50 connections, printed, never failing.
4. **G7 holds a port body**: a 6-byte bytevector port, made per request, as the body,
   over the same 6 bytes as a bytevector, both through the adapter. Since the owner's
   choice to read a port of a piece or less whole (design §5, §15 item 12), it reads
   300–310 B, against about 5.1 KB streamed.
5. **G4 sits between record size steps.** A `req-set` costs 80 B at the request record's
   four fields and would cost 96 B at six. G4 five is five times G4 one's bound.

## Measurements

Six runs by slice 4's gate builder and two by the session, all on 2026-10-26, on the
final program, read these worst figures: G1 1,439–1,447 B, G2 1,433–1,443, G3 GET
305–311, G3 POST 273–280, G4 one 80–81, G4 five 400–406, G5 364–374, and G5 park
319–343. G6 read 93.9–95.5% at 50 connections, on a shared machine. A gate's worst
figure moves by about 10 B from run to run, and by up to 25 B where the app parks. Each
held gate was watched failing, by the regressions in the table, and the session reran the
G3 and G4 mutants.

- **The pulled POST costs about what a GET does**, 1,433–1,443 B over raw, against the
  interim's 2.9 KB and the 9.5 KB slice 3 read through `get-bytevector-all`, which
  allocates about 8.1 KB for its buffer (design §4).
- **G3 POST reads below G3 GET**, about 30 B, so 512 B and even 384 B would have passed a
  view made per request by 1 B or less. 352 B fails it by 32–33 B, with about the 73 B
  of headroom G3 GET has.
- **The real adapter costs a few bytes more than the stand-in**: G3 GET about 15 B, and
  G5 about 25 B, though G5's helper is unchanged. The cause is unverified.

## Consequences

- **G7 came after the bounds.** Streamed, a 6-byte bytevector port as the body cost
  5,096–5,103 B a request over the same bytes as a bytevector, measured outside the gate:
  about 3 KB the server's sized producer sent from `awaiting`, about 1 KB its running of
  the `request-on-done!` procedure, and about 1,040 B `res-body-stream`'s two `guard`s. So
  the owner chose, the same day, to read a port of a piece or less whole (design §5), with
  one `with-exception-handler` closing a port on a raise, and to hold the cost. A port of
  more than one piece, which streams, and a sized body are still unheld.
- **Slice 5 measured the real middleware**, in seven runs by the session and two by its
  review, on 2026-10-26 and 27:
  - **G5, the real catch helper**, reads 373–385 B, and 319–351 B with a park. Its first
    shape called `on-raise` after the escape, which put a frame after the `call/cc` and
    read 485–487 B, 25 B under the bound. So `on-raise` runs inside the handler (design
    §6), and a suite row holds that order, since G5 wouldn't catch the costlier shape.
  - **G8, `wrap-log`**, reads 1,129–1,145 B at 1 connection and 817–834 B at 50, printed
    (the owner's decision). Of that, G8 on-done, the server's running of one no-op
    procedure, reads 858–870 B and 528–557 B, filed as chez-http-server #245.
  - **G8 own, `wrap-log`'s own share**, reads 264–302 B. Building the line in a string port
    first, as the first build did, costs about 380 B more and passes every suite, so the
    owner chose to hold it, at 384 B, after slice 5's review. The server's share is in its
    baseline too, so a fix to #245 doesn't move it.
  - **G9, `wrap-timeout`**, reads 596–609 B, and 574–614 B with a park. No suite row can
    tell a `call/1cc` escape from `call/cc`, so the owner chose to hold it, with a park
    variant, where `call/1cc` jumps to about 3.9 KB. The 768 B bounds leave about 160 B
    of headroom.
- **G1 and G2 are re-baselined at each move of the server's pin**, as before.
- **Per-connection costs cancel under keep-alive**, so the gate doesn't see them.
