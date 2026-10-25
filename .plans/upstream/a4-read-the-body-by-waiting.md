Title: Let a handler that waits read its body by waiting
Filed: chez-http-server #227, 2026-10-25

**The problem**

A handler that answered `awaiting` can wait for anything but its own body.
The body comes only through a reader the handler answers with, and the
server pushes it: each piece to `on-piece`, then `on-end`, which gives the
response. So code that reads a body is split at the body, at v0.8.0
(a996eef):

- What runs before the body runs in the thunk, and what runs after it runs
  in `on-end`. Each piece and the end run on coroutines of their own
  (`deliver-body!` and `deliver-body-end!`,
  `src/http-server/private/shell.sls:961` and `:976`), so a
  `with-deadline`, an exception handler or a `parameterize` around the
  thunk's code covers neither the body nor what follows it.
- Code written to pull its input, such as a parser that reads a port,
  can't read the body as it arrives. It must be handed the body whole,
  held in memory to a cap (`read-whole-body`), or be rewritten to be pushed
  pieces.
- A handler can't answer partway through the body. Once the thunk has
  answered a streaming reader, only `on-end` answers: an answer before then
  is dropped (`on-handler-responded`, `src/http-server/connection.sls:2017`
  and `:2033`: "An answer the core did not ask for changes nothing").
- A body read whole from the thunk costs three coroutines: the thunk's,
  one for the body, which the core hands a whole reader as its only piece,
  and the end's. A streaming reader's costs one for each piece, and one for
  the end.

circuit, a Ring-like layer over the server, gives every app its request
body as a binary input port, as Ring's `InputStream` and Rack's
`rack.input` are. Today it reads the body whole first, capped, and hands
the app a bytevector port over it. That gives up what the server's readers
do well: backpressure on a body of any size, and a `100 Continue` the app
can decline to send.

A layer above the server can't turn the push into a pull. Re-entering the
thunk's continuation from each `on-piece` re-runs the drain it was captured
in (decision 0025).

**What you propose**

A wait that gives the next piece of the request's body, for example
`(next-body-piece)`, for code on the coroutine of a handler that answered
`awaiting`. The details are the server's to decide. A port over it is
sound: a custom binary input port whose `read!` parks on the server's
coroutine served every standard read under the server, binary and text,
and Chez 10.4.1 puts no lock, critical section or `dynamic-wind` around
`read!` (`s/io.ss`, the custom binary input port's handler). These are what
a port over it needs:

- **It answers a fresh bytevector of a byte or more, or the eof object.**
  The caller owns the bytevector: the piece shares no memory with the read
  it came in, since a port keeps a piece across calls and parks. It never
  answers an empty piece, which a port's `read!` would pass on as eof.
- **It may be called from the thunk, before the thunk has answered.** It is
  refused, as a wait is off a coroutine, anywhere else and once the thunk
  has answered.
- **The first call sends `100 Continue`**, after the declared length has
  been checked against the caps, as answering a reader does now. A declared
  length past a cap is a 413 with no 100, and the handler that never calls
  it sends no 100.
- **It reads on credit.** The server reads from the socket only as the
  handler takes pieces, so a slow handler holds at most one read, as a
  streaming reader on credit does now.
- **It can take a cap of its own**, as a reader can, below
  `CHEZ_HTTP_MAX_BODY_BYTES`. A body past the cap raises. Let out, it is
  answered 413, as a body past a reader's cap is now; caught, the
  handler's own answer is sent. Either way the connection closes after it.
- **An answer before the body's end is sent**, and the connection closes
  after it, as it does now for a response answered instead of a reader
  (`'unread-body`).
- **Its ends stick.** Once it has answered eof, every later call answers eof
  without waiting: Chez calls a port's `read!` again after eof. Once the
  client has closed, or the body has failed (a framing error, a cap passed),
  every later call raises without waiting. `&client-closed` is raised once
  today, so a read after a caught close would wait for good.
- **It raises only before taking a piece.** A raise then never drops bytes
  that left the connection, and code that reads on after a raise, its own
  deadline say, loses nothing.
- **It is a wait like the others.** Inside a `with-deadline` that has passed
  it raises before waiting, and it raises `&client-closed` as every wait
  does.

**What the RFCs say**

RFC 9110 §10.1.1 (Expect): the 100 goes out when the body is first asked
for, as it does now when a reader is answered, and a server that answers
before reading the whole body should say whether it will close; this one
closes (RFC 9112 §9.6). Nothing the server accepts or refuses changes.

**Meanwhile**

circuit reads the body with `read-whole-body` from the thunk, capped at
1 MiB unless `CIRCUIT_MAX_BODY_BYTES` says otherwise, and hands the app a
bytevector port.
A client that sent `Expect: 100-continue` is told to send its body even
when the app would refuse it. A body over the cap gets a 413 before the app
sees the request. And an app that reads a large body holds it whole.
