# S1: a port that waits

Date: 2026-10-25
Question: design §4 and §13. Can `(req-body req)` be a binary input port whose
read procedure parks the server's coroutine?
Answer: **yes. The body is a port.** The caveats are below, in §8.

## How it ran

- [s1-port-that-waits.sps](spike/s1-port-that-waits.sps) is a server. It
  uses the facade's `serve` on port 0. There is no waiting verb yet (A4),
  so a **channel** stands in for it: `next-piece` parks with `await` until
  `POST /feed?id=I&park=N` resumes it with that request's body (an empty
  body means eof). The **waiting port** is a `make-custom-binary-input-port`
  whose `read!` hands out what is left of its piece, then calls `next-piece`.
  `GET /read?id=I&case=C` answers `awaiting` and reads the port as case C
  says.
- [s1-port-that-waits.sh](spike/s1-port-that-waits.sh) drives it with curl.
  Every feed names the park it is for and waits for the reader to be parked
  there, so the result doesn't depend on timing.
- Pieces are lines `<id><k>-<5 digits>`, so the report can say where each
  read's bytes sit in what was fed (`= fed[a,b)`). Each read is reported
  with the parks it crossed and the bytes `read!` handed to Chez meanwhile.

```sh
scripts/guix-env sh .plans/research/spike/s1-port-that-waits.sh
```

Environment: Linux 7.1.1 x86_64, Chez Scheme 10.4.1 ta6le, threaded, in the
Guix container; chez-http-server v0.8.0. `file-buffer-size` is 8192,
`custom-port-buffer-size` 128, `transcoded-port-buffer-size` 1024.

**Six runs.** Items 1 to 6 are the same in runs 3 to 6 once the times and
ports are masked (`diff` empty). Runs 1 and 2 differ only in a display fix
and the case added later. Item 7's final form is the same in runs 5 and 6.
The quotes below are from run 6.

## 1. Binary reads across parks

Ran: 19 pieces of 1,000 B, then eof (`case-bytes`, program line 332).

```text
get-bytevector-n 2500 -> 2500 B "n1-00000".."54\nn3-00" = fed[0,2500) | parks +3, read! handed 2500 B, 14 ms
get-bytevector-n 500 -> 500 B "055\nn3-0".."-00110\nn" = fed[2500,3000) | parks +0, read! handed 500 B, 0 ms
lookahead-u8 -> byte 110 #\n | parks +1, read! handed 128 B, 5 ms
get-u8 -> byte 110 #\n | parks +0, read! handed 0 B, 0 ms
get-bytevector-some -> 127 B "4-00000\n".."00013\nn4" = fed[3001,3128) | parks +0, read! handed 0 B, 0 ms
get-bytevector-some -> 872 B "-00014\nn".."-00110\nn" = fed[3128,4000) | parks +0, read! handed 872 B, 0 ms
get-bytevector-some -> 1000 B "n5-00000".."-00110\nn" = fed[4000,5000) | parks +1, read! handed 1000 B, 6 ms
get-bytevector-n 12000 (over file-buffer-size, so gathered in blocks) -> 12000 B "n6-00000".."7-00099\n" = fed[5000,17000) | parks +12, read! handed 12000 B, 63 ms
get-bytevector-all -> 2000 B "n18-0000".."9-00099\n" = fed[17000,19000) | parks +3, read! handed 2000 B, 13 ms
get-bytevector-n 1, after the end -> eof | parks +0, read! handed 0 B, 0 ms
account: fed 19000 B, the app was given 19000 B, lost 0 B; given = fed: #t
```

What it means:
- One `get-bytevector-n` crossed 3 parks, and one crossed 12 on the block
  path (over 8,192 B). Every standard binary read works, and the bytes came
  back whole and in order: the `account` line compares everything the app
  got, the `get-u8` byte included, with everything fed.
- `lookahead-u8` and `get-u8` make Chez fill its own 128 B buffer (`read!`
  asked for 128). The other reads hand `read!` the caller's buffer and
  count. So `read!` must keep the rest of a piece between calls.
- Had the reads lost, repeated or reordered bytes, a `fed[...]` range would
  not line up with the one before it, and `given = fed` would be `#f`.

## 2. A UTF-8 text port over the waiting port

Ran: `transcoded-port` with UTF-8, eol-style none and error mode `raise`.
Five pieces split `é` (2 bytes), `€` (3) and `🍕` (4) between them
(`case-text`, line 356).

```text
get-line -> 24 chars "first line, café au lait" | parks +5, read! handed 75 B, 13 ms
get-char -> char #\s | parks +0, read! handed 0 B, 0 ms
get-string-all -> 42 chars "econd: naïve, 5 € 🍕\nthird line, no newline" | parks +1, read! handed 0 B, 3 ms
line, newline, char and rest equal it: #t
```

What it means:
- A park in the middle of a character works: the decoder parks for the rest
  of it and resumes. In `raise` mode, a mangled split would have raised
  `&i/o-decoding`.
- **Text reads read ahead.** `get-line`'s newline arrived in piece 2, but it
  returned only after 5 parks, with all 75 B taken in. Chez's UTF-8 decoder
  (`io.ss` 1731) finishes a split character before it returns. Every piece
  here ended inside a character, so it read on to the end. This is harmless
  for a body the client sends whole. It matters only to an app that answers
  between lines of a body still arriving.

## 3. `with-deadline` around a read that parks

Ran: `case-deadline`, line 371. Park 1 is the deadline's.

```text
with-deadline 300: get-bytevector-n 3000, nothing fed -> RAISED &deadline-passed (who await) | parks +1, read! handed 0 B, 300 ms
port-closed? after the raise: #f
get-bytevector-n 1500, outside the deadline -> 1500 B "d1-00000".."54\nd2-00" = fed[0,1500) | parks +2, read! handed 1500 B, 12 ms
inside with-deadline 200: sleep-ms 300 -> RAISED &deadline-passed (who sleep-ms) | parks +0, read! handed 0 B, 202 ms
  then get-bytevector-n 10, inside the passed deadline -> 10 B "055\nd2-0".."5\nd2-000" = fed[1500,1510) | parks +0, read! handed 10 B, 0 ms
  then get-bytevector-n 1000, inside the passed deadline -> RAISED &deadline-passed (who await) | parks +0, read! handed 490 B, 0 ms
get-bytevector-all, outside it -> 1000 B "d3-00000".."-00110\nd" = fed[2000,3000) | parks +2, read! handed 1000 B, 8 ms
```

What it means:
- `&deadline-passed` comes out of `get-bytevector-n` to the handler.
- The port is still open afterwards. A raise at a read's first park took
  nothing: the next read began at `fed[0]`.
- **Inside a passed deadline, a read that doesn't need to wait still
  returns** (10 B from the piece `read!` held). A read that needs to wait
  raises at once, without parking (`parks +0, 0 ms`), and drops what it had
  gathered: 490 B, `fed[1510,2000)`, which the next read skipped. A
  deadline bounds waits, not reads.

## 4. The client leaves while the read is parked

Ran: `case-closed`, line 390. Piece 1 was fed at park 1, then curl was
killed (`kill -KILL`) while the read was parked at park 2. The report is
from the server's log, since the client is gone.

```text
s1 c get-bytevector-n 3000; the client is killed at park 2 -> RAISED &client-closed (who await) | parks +2, read! handed 1000 B, 7 ms
s1 c get-bytevector-some, after the close -> 1000 B "c2-00000".."-00110\nc" = fed[1000,2000) | parks +1, read! handed 1000 B, 8 ms
s1 c with-deadline 300: get-bytevector-some -> RAISED &deadline-passed (who await) | parks +1, read! handed 0 B, 302 ms
```

What it means:
- `&client-closed` is raised from inside `read!` and out of
  `get-bytevector-n`. The 1,000 B that `get-bytevector-n` had gathered are
  lost (item 6).
- **A read after the close parks again.** The server raises the close once
  ("waits work as before"), so the next read waited at park 3. The driver's
  `/until?parks=3` returned only because it did. Here a feed resumed it,
  because the stand-in's pieces come from other requests. With A4's real
  verb nothing would ever resume it, so the verb must keep refusing after a
  close (§9).
- The handler's late response went nowhere, and the server logged nothing
  for it.

## 5. Two readers parked at once

Ran: `case-two`, line 401, on four curl connections. Readers a and b were
both parked before any feed (`/state` said so). The feeds went b1, a1, a2,
b2, b3, a3, then eof to a, then eof to b. Then e and f, in the other order.

```text
parked now: a b
    (a) account: fed 3000 B, the app was given 3000 B, lost 0 B; given = fed: #t
    (a) bytes of "b", the other reader's label, in what this one was given: 0
    (b) account: fed 3000 B, the app was given 3000 B, lost 0 B; given = fed: #t
    (b) bytes of "a", the other reader's label, in what this one was given: 0
parked now: e f
    (e) ... given = fed: #t ... bytes of "f" ...: 0
    (f) ... given = fed: #t ... bytes of "e" ...: 0
```

What it means: neither reader saw the other's bytes, and all four
finished. The driver's `wait` would have hung on any reader that didn't.

## 6. A raise after a partial read: what is lost

Ran: pieces 1 and 2 fed, the deadline passes at park 3, then pieces 3 and 4,
then eof. Lines 416 (`case-partial-n`), 427 (`case-partial-some`) and 448
(`case-text-raise`).

```text
partial-n:    with-deadline 400: get-bytevector-n 5000 ... -> RAISED &deadline-passed (who await) | parks +3, read! handed 2000 B
              get-bytevector-all, after the raise -> 2000 B "p3-00000".."-00110\np" = fed[2000,4000)
              account: fed 4000 B, the app was given 2000 B, lost 2000 B; given = fed: #f
partial-big:  with-deadline 400: get-bytevector-n 20000 ... -> RAISED ... | parks +3, read! handed 2000 B
              get-bytevector-all, after the raise -> 2000 B "q3-00000".."-00110\nq" = fed[2000,4000)
              account: fed 4000 B, the app was given 2000 B, lost 2000 B; given = fed: #f
partial-some: with-deadline 400: get-bytevector-some to eof, keeping each ... -> RAISED ... | parks +3, read! handed 2000 B
              kept before the raise: 2000 B
              account: fed 4000 B, the app was given 4000 B, lost 0 B; given = fed: #t
```

Text, with `get-string-some` and error mode `replace`. Piece 1 ends inside
`é` after 10 ASCII bytes (`text-split`) or after 600 (`text-split-long`),
or ends on a character boundary (`text-boundary`):

```text
text-split:      ... -> RAISED &deadline-passed (who await) | parks +2, read! handed 11 B
                 kept before the raise: ""
                 fed decodes to "0123456789é tail", 16 chars; the app was given "� tail", 6 chars; equal: #f
text-split-long: ... -> RAISED &deadline-passed (who await) | parks +2, read! handed 601 B
                 kept before the raise: ""
                 fed decodes to "v-00000\nv-00...00074\né tail", 606 chars; the app was given "� tail", 6 chars; equal: #f
text-boundary:   ... -> RAISED &deadline-passed (who await) | parks +2, read! handed 10 B
                 kept before the raise: "0123456789"
                 fed decodes to "0123456789é tail", 16 chars; the app was given "0123456789é tail", 16 chars; equal: #t
```

What it means:
- **A raise loses exactly what `read!` had handed to the read that raised.**
  That is 2,000 B here, `fed[0,2000)`, whatever the read's size: 5,000 B
  (one buffer, `io.ss` 3787) lost the same as 20,000 B (blocks, 3822).
  Bytes `read!` still held are not lost. The design says "large reads,
  block by block", but it is every `get-bytevector-n`, small ones too: item
  3's `get-bytevector-n 1000` lost 490 B. By the source,
  `get-bytevector-all` (3897), `get-line` (4091) and `get-string-all`
  (`$get-string-all`, 3966) keep what they gather in locals the same way.
  None of those three was run under a raise.
- **`get-bytevector-some` loses nothing.** It waits at most once, and a
  raise there comes before `read!` has handed anything (3872).
- **No text read is safe across a raise.** When a piece ends inside a
  character, the decoder decodes up to the split, then waits for the rest
  inside the same call. It records its progress only when it returns
  (`io.ss` 1625, 1731). So a raise during that wait drops every character
  the call had decoded: 10, then 600, and the orphaned continuation byte
  then decodes as U+FFFD. The only difference between `text-split` and
  `text-boundary` is where piece 1 ends.

## 7. What a park inside `read!` leaves held

**The source.** Chez's source is not vendored, but it is on this machine:
`/gnu/store/vrdaswvmyj8rlzhs76w71zh3yzyddxpn-chez-scheme-10.4.1-checkout/s/`.
Two other store checkouts are byte-identical (`io.ss` sha256 `26f018aa…`).
- `make-custom-binary-input-port` (`io.ss` 3633) and its helpers
  (`bv-read!` 722, `binary-port-read!` 728, `binary-custom-port-get` 770,
  `-get-some` 783) call `read!` with no lock and no critical section. So do
  `get-bytevector-min-max` (3787), `get-bytevector-n`, `-some` and `-all`
  (3822, 3872, 3897), and `get-u8`'s slow path (`library.ss` 1045).
- `io.ss` has no bare `mutex-acquire` or `(disable-interrupts)`. Its
  tc-mutex and port mutex guard the open-files registry (348–391, which
  `open-file-input-port` enters at 1110), transcript ports (5934) and the
  console ports (6236).
- Every lock form Chez has is a `dynamic-wind`: `critical-section`,
  `with-interrupts-disabled` and `with-mutex` (`syntax.ss` 8123, 8131,
  8140), and `with-tc-mutex` (`cmacros.ss` 2209).
- The frames observed under `read!` match the source's procedure names (run
  6, below).

**The run** (`case-probe`, line 476; `/probe`, line 222). Probes inside
`read!` record the interrupt-disable count and how many `dynamic-wind`
entries are in force beyond the caller's. `/probe`, a plain handler on
another connection, runs while the reader is parked. It records its own
disable count, how many collections 64 MiB of allocation triggers, and
whether a second OS thread finishes port I/O of its own within 2 s. That
I/O includes opening a file port, whose registration takes the tc-mutex.

```text
x parked at park 1
probe: interrupt-disable count 0; collections during 64 MiB allocated: 8; a second thread's port I/O: finished: (300 "héllo"); parked now:  x
probe (control): interrupt-disable count 0; collections during 64 MiB allocated inside a critical-section: 0; ...
x parked at park 2
probe: interrupt-disable count 0; collections during 64 MiB allocated: 8; a second thread's port I/O: finished: (300 "héllo"); parked now:  x
x parked at park 3
(x is parked in the control's read, inside a critical-section)
probe: interrupt-disable count 0; collections during 64 MiB allocated: 8; a second thread's port I/O: finished: (300 "héllo"); parked now:  x
    read! called for 1500 B: interrupt-disable count 0, winders beyond the caller's 0
    read!'s frames, innermost first: (#f "binary-custom-port-get-some" "get-bytevector-min-max" "get-bytevector-n" #f "dynamic-wind" "step")
    read! resumed from its park: interrupt-disable count 0, winders beyond the caller's 0
    ...
    the control follows: a read inside a critical-section, the winders counted outside it
    read! called for 8192 B: interrupt-disable count 1, winders beyond the caller's 1
    read! resumed from its park: interrupt-disable count 1, winders beyond the caller's 1
    read! called for 8192 B: interrupt-disable count 0, winders beyond the caller's 0
```

What it means:
- **Nothing is held.** Chez puts no lock form between
  `get-bytevector-n` and `read!` (0 extra winders, disable count 0) at the
  call and after the resume. While the read is parked, the loop collects
  garbage, serves other connections, and lets another thread take the
  tc-mutex.
- **The checks can tell.** Allocating inside a `critical-section` triggered
  0 collections where 8 were expected, and the control's `read!` saw count 1
  and 1 extra winder.
- **A park leaves every `dynamic-wind` around it.** While the control's read
  was parked inside a `critical-section`, `/probe` saw interrupts enabled
  and the collector ran. On resume, the count was 1 again. A park is a jump
  to the drain's continuation, so it runs each after thunk, and the resume
  runs each before thunk. Even a lock form around `read!` would not stay
  held across a park. But app code that frees a resource in an after thunk
  frees it at every park. The server's `docs/waiting.md` doesn't say so.

## 8. Recommendation: a port

Keep `(req-body req)` as a binary input port, and set `(body-read source)`
aside. A `read!` that parks is sound under the server. Every standard
binary and text read works across parks, raises come out of the port
procedures, and two parked ports kept apart. App authors need these
caveats:

1. A raise loses what the raising read had gathered; `get-bytevector-some`
   loses nothing. After a raise out of a body read, treat the body as gone.
2. No text read is safe across a raise, because a split character's wait
   drops the decoder's chunk. A reader that must go on reads bytes with
   `get-bytevector-some` and decodes them itself.
3. Inside a passed deadline, a read that needn't wait still returns.
4. A park leaves every `dynamic-wind` around a read: release resources on a
   raise with an exception handler.
5. Text reads read ahead to finish a split character.

Proposed text for design §4 follows. Replace the bullet "A read is a wait…"
with the bullets below, and add a sentence to the opening paragraph:

> `(req-body req)` is a binary input port. Ring's body is an `InputStream`
> and Rack's a `rack.input`; this is the same thing, except that a read that
> must wait for the client parks the coroutine. Spike S1 showed that a
> custom port's `read!` can park: every standard read works across parks,
> binary and text alike, and Chez calls `read!` with no lock around it.
>
> - *(the first three bullets as they are)*
> - **A read is a wait.** It raises `&client-closed` when the client leaves,
>   and `&deadline-passed` once a `with-deadline` around it has passed,
>   out of the port procedure. A read the port can serve from bytes it holds
>   doesn't wait, so it returns even inside a passed deadline: a deadline
>   bounds waits, not reads.
> - **A raise loses what that read had gathered.** `get-bytevector-n` of
>   any size, `get-bytevector-all`, `get-line` and `get-string-all` gather
>   across waits and return at the end, so a raise drops what they
>   gathered. The port stays open and goes on from the next byte.
>   `get-bytevector-some` waits at most once and loses nothing. A text port
>   loses even with `get-string-some` when a piece ends inside a
>   character: its decoder drops all it decoded in that call. So after a
>   raise out of a body read, treat the body as gone: answer, or raise on.
>   A reader that must go on reads with `get-bytevector-some` and decodes
>   the bytes itself.
> - **After the close, every read raises** (A4 asks for this) instead of
>   waiting for bytes that can't come.
> - **A park leaves every `dynamic-wind` around the read** and re-enters it
>   when the read resumes: the after thunk runs at each park, the before
>   thunk at each resume. Free a resource on a raise with an exception
>   handler, not `dynamic-wind`.
> - **Text reads read ahead.** A UTF-8 `transcoded-port` takes up to 1 KiB
>   at a time, and finishes a character split between pieces before it
>   returns. So `get-line` can wait for more of the body than its line. A
>   body the client sends whole doesn't notice.

The last paragraph ("Spike S1 checks…") becomes:

> Spike S1 ([findings](research/s1-a-port-that-waits.md)) settled the
> interface: the body is a port. Under the real server, a custom port whose
> `read!` waits served every standard read across several waits each, with
> two connections parked in their ports at once. Chez 10.4.1 calls `read!`
> with no lock, critical section or `dynamic-wind` around it, so a park
> leaves nothing held. `(body-read source)` is set aside (§14).

## 9. What A4's verb must guarantee for a port over it

- **It is an ordinary wait**, callable from inside a custom port's `read!`
  on the handler's coroutine. Item 7 shows that is a sound place to park.
- **It answers a fresh bytevector the caller owns, or eof**, never an empty
  piece. `read!` keeps a piece across calls and parks, and to Chez a
  `read!` that answers 0 means eof.
- **It raises only before taking a piece**, so a raise drops no byte that
  left the connection. That is what keeps `get-bytevector-some` lossless.
- **Its ends stick.** After eof, every call answers eof without waiting
  (Chez calls `read!` again after eof; item 1's last read). After the
  client's close or a body error, every call raises without waiting. Today
  the close is raised once, and item 4's next read waited again.
- **It raises before waiting inside a passed deadline.** The server's waits
  already do this (item 3).

Proposed addition to A4's row in §12: "…; once it has answered eof it
answers eof, and once the client has closed or the body has failed it
raises, on every later call and without waiting; it raises only before
taking a piece, so a raise drops no bytes (S1)."

## 10. What the design gets wrong

- **§4, "Chez's `get-bytevector-n` gathers large reads block by block…, so a
  raise from a later block loses the bytes already taken off the port."**
  The loss isn't limited to large reads or to blocks. Any `get-bytevector-n`
  loses everything `read!` handed it during that call: 5,000 B and 20,000 B
  reads lost the same 2,000 B, and a 1,000 B read lost 490 B (items 3 and
  6). Bytes not yet handed over are kept.
- **§4, "A body reader that must resume after a raise reads with
  `get-bytevector-some`."** This holds for bytes only. A text port loses
  data even with `get-string-some` (item 6).
- **§4, "A read … raises `&deadline-passed` inside a `with-deadline` that
  has passed."** It raises only if it has to wait. A read served from bytes
  on hand returns (item 3).
- **§4 and A4 on `&client-closed`.** §6 says a handler that waits again
  after the close parks for good, but §4 and A4's row don't carry this to
  the body. A read after a caught close waited again (item 4). A4 must make
  the close stick.
- **§2, "middleware is oblivious".** Not for a `dynamic-wind`: a park runs
  its after thunk, and the resume runs its before thunk (item 7). The
  design never mentions `dynamic-wind`, and neither does the server's
  `docs/waiting.md`. Middleware that frees a resource, such as a
  transaction or a lock, in an after thunk frees it at every wait, a body
  read included.
- **§13 S1** is right about `s/io.ss`: no lock, critical section or
  `dynamic-wind` sits around `read!`. Chez's source isn't vendored, but it
  is in the Guix store (item 7).

## Rerun

Rerun by the session that set the spike, 2026-10-25, with the command above:
every item gave what is quoted here, with times and ports apart. Checked
besides:

- the waiting port's `read!` parks only once its piece is used up, so at a
  raise it holds nothing: the bytes item 6 lost were Chez's;
- `s/io.ss:3633`, the custom binary input port's handler, puts nothing
  around `read!`, where the file ports' handlers take a `critical-section`;
- the server's own `with-deadline` relies on a park's running every
  `dynamic-wind`'s after thunk: its after thunk asks `coroutine-suspending?`
  to tell a park from a leaving (`src/http-server/private/waits.sls:385`).
