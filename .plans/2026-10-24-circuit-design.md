# Circuit design: Ring on chez-http-server's coroutines

Date: 2026-10-24, revised 2026-10-25 after review, and 2026-10-26 once
the server had taken up every ask and tagged it (§12), then after review
Status: draft, for discussion; §15 records the owner's decisions so far, §16 what is open
Builds on: [circuit-ringlike-http-layer.md](circuit-ringlike-http-layer.md) (the overview)

## 1. What changed since the overview

The overview was written before chez-http-server existed, and deferred
streaming, async, cancellation and upgrades until the lower layers did.
They exist now, and the server has answered most of the overview's §28:

| Overview's open question | The server's answer |
|:--|:--|
| streaming responses, backpressure | a body may be a producer, `(-> (U Bytevector Eof))`, called only while the client keeps up (256 KiB high, 64 KiB low water; 64 and 16 pieces) |
| streaming request bodies | `body-input-port`, a port whose reads pull the body on credit, read by a handler that waits before it answers (v0.9.0, §4) |
| the async model | direct-style waits on coroutines: a handler answers `(awaiting thunk)`, and inside it `await`, `sleep-ms`, `with-deadline`, `resolve` park the coroutine |
| disconnects | the wait the code is in, or else its next, raises `&client-closed`, once |
| upgrades | `(switch-protocols headers take-over)`, the stream handed over as a transport; WebSocket is chez-websocket |

The fact that shapes this design: **code that waits looks like code that
doesn't.** A wait parks the coroutine on a continuation and returns when it
is resumed. Ring grew a three-argument async handler, `(request respond
raise)`, because parking a JVM thread was expensive. Here a parked handler
costs about 0.7 KB, so circuit can keep Ring's synchronous contract and lose
none of the server's async capabilities. The overview's options B
(callbacks) and C (futures) are not needed, and its option A loses its
drawbacks: a handler that waits does not block the loop, and bodies stream
through ports and producers.

Since v0.8.0 the server has taken up all eight of circuit's asks and the
docs fix (§12), and tagged them as v0.9.0 on 2026-10-26, at d928e41.
Circuit's pin is at v0.9.0 (§15.7). This design was revised against the
server's main at 9195305, whose `src/` and `docs/` the tag carries
unchanged.

## 2. The contract

```text
Handler    = Req -> Res
Middleware = Handler -> Handler
```

- **Every handler runs on a coroutine.** The adapter answers each request
  with `awaiting`, so the app, every middleware and the request body's
  reads may all wait. No option calls an app in place. S2 measured what
  that costs: a GET through an adapter-shaped prototype allocates about
  1.3–1.4 KB more than the raw server, and answers 93–95% of its requests
  a second at 50 connections (§13, §15).
- **Waiting is ambient inside the handler call**, as blocking I/O is in
  Ring and Rack. Circuit defines no async primitive. Handlers wait with the
  server's verbs, and middleware is oblivious: `(handler req)` may park
  inside and returns when it is done. A `dynamic-wind` around the call is
  the exception: its after thunk runs at each park (§6).
- **The request's body is inside the handler call.** The app reads it
  through a port that pulls it on the handler's coroutine, and the server
  lets only that coroutine pull, until the handler answers (§4). So a
  `with-deadline` or an exception handler around the call covers the body's
  reads.
- **The response's body is outside the handler call.** The server calls a
  response's producer on a fresh coroutine for each piece, after the
  handler has returned. A producer may wait, but it runs outside every
  middleware's dynamic extent: no `with-exception-handler`, `with-deadline`
  or `parameterize` around the handler reaches it (§5, §6).
- **One async model** (the overview's principle 14): the server's waits.
  No callbacks, futures or answer sum in circuit's API. The server's
  `Answer = Response | BodyReader | Awaiting | Switch` lives only in the
  adapter, which answers `awaiting`, and from the thunk a response or a
  switch, never a reader.

```scheme
(import (rnrs) (circuit) (circuit http-server))

(define (app req)
  (sleep-ms 10)                         ; parks this request; others go on
  (make-res 200 '(("content-type" . "text/plain")) "hello\n"))

(define (wrap-server-header handler)
  (lambda (req)
    (res-add-header (handler req) "server" "circuit")))

(run-server (wrap-server-header app))
```

## 3. The request

A record, `req`. Its host-provided fields are read through a *view*, a
record of procedures the adapter supplies (a test supplies its own), so a
request that reads only its path pays only for its path, as the server's
own accessors do. A request keeps the bytes it arrived in, as the server's
does: keep the strings you read, not the request.

| Accessor | Type | From the server | Since |
|:--|:--|:--|:--|
| `req-method` | `Req -> Symbol` | `request-method`, `'GET` | v0.8.0 |
| `req-scheme` | `Req -> Symbol` | none: always `'http` (no TLS) | constant |
| `req-host` | `Req -> String` | `request-host` | v0.8.0 |
| `req-path` | `Req -> String` | `request-path`, undecoded | v0.8.0 |
| `req-query` | `Req -> (U String #f)` | `request-query` | v0.8.0 |
| `req-http-version` | `Req -> (Pair Nat Nat)` | `request-http-major`, `request-http-minor` | v0.9.0 (A2) |
| `req-header` | `Req String -> (U String #f)` | `request-header`, any case | v0.8.0 |
| `req-header-values` | `Req String -> (Listof String)` | `request-header-values` | v0.8.0 |
| `req-headers` | `Req -> (Listof (Pair String String))` | `request-header-list`, names as sent | v0.9.0 (A1) |
| `req-body` | `Req -> BinaryInputPort` | `body-input-port`, §4 | v0.9.0 (A4) |
| `req-remote-address` | `Req -> (U String #f)` | `request-remote-address` | v0.9.0 (A3) |
| `req-remote-port` | `Req -> (U Nat #f)` | `request-remote-port` | v0.9.0 (A3) |
| `req-local-address` | `Req -> (U String #f)` | `request-local-address` | v0.9.0 (A3) |
| `req-local-port` | `Req -> (U Nat #f)` | `request-local-port` | v0.9.0 (A3) |
| `req-on-done!` | `Req (Symbol -> Any) -> Void` | `request-on-done!`, §7 | v0.9.0 (A6) |

- `req-headers` gives names in lower case, in wire order, duplicates
  kept: it folds the names the view gives, as sent, and gives the view's
  own list back when no name needs folding. `req-header` matches any case
  and reads the first. Case is ASCII's, A–Z to a–z and nothing else, as
  the server folds names, so the Kelvin sign doesn't match `k`.
- **The addresses are the connection's**, read once as the server took
  it, and `#f` where it can't say. Behind a proxy the remote end is the
  proxy, so trust `X-Forwarded-For` only when `req-remote-address` is your
  proxy's, and take its last address, the one your proxy added: a client
  can write the ones before it (the server's `docs/deploying.md`). An IPv4
  client of a server listening on `::` reads as `"::ffff:…"`. The
  server's test host has no socket, so all four read `#f` there (decision
  0037, §10).
- **The view** is a record of procedures: one per row above that the host
  supplies (`method`, `host`, `path`, `query`, `http-version`, `header`,
  `header-values`, `headers`, `body`, `remote-address`, `remote-port`,
  `local-address`, `local-port`, `on-done`), each taking the host's
  request. `make-req-view` takes them in that order, and `make-req` makes
  a request from a view and the host's request (§11). The adapter's view
  wraps the server's accessors; a test request's view reads a record of
  what the test gave.
  - **Four are required**: `method`, `host`, `path` and `http-version`,
    whose accessors' types have no `#f`. The view's constructor refuses
    `#f` for any of them with an assertion violation. A test request
    always has all four (§15.10).
  - **The rest may be `#f`.** Then the accessor answers `#f`, or `'()`
    for a list, with two exceptions. With no `body`, `req-body` answers an
    empty port, which reads eof at once. With no `on-done`,
    `req-on-done!` keeps the procedure on the request, for whoever made
    the request to call (§7).
- **Middleware adds data through unique keys**, not symbols:
  `(make-req-key name)` makes a key, `(req-ref req key [default])` reads
  it, and `(req-set req key value)` gives a new request. Two libraries
  can't collide on a key, and each exports accessors for its own (a
  session library exports `req-session`, not a symbol to look up). The
  keys live in an alist in the record; `req-set` copies the record and
  conses the key's pair onto it, so a stack of n middlewares that each set
  a key costs n record copies and 2n pairs: 80 B a set, 383–409 B for a
  stack of five (S2).
- **Core fields update functionally**, for middleware that rewrites them
  (method override, forwarded scheme and address, a mount prefix):
  `req-with-method`, `req-with-scheme`, `req-with-host`, `req-with-path`,
  `req-with-query`, `req-with-remote-address` and `req-with-remote-port`,
  each giving a new request whose view answers the new value for that
  field. A value of another type is an assertion violation.
- **Every copy shares one cell.** The record holds a cell, made with the
  request, holding the body's port once the first `req-body` has made it
  (§4), and the procedures `req-on-done!` keeps when the view has no
  `on-done`, with the ending once `test-req-done!` has given one.
  `req-set` and the `req-with-` helpers copy the record, not the cell, so
  a port made through one copy is the port every copy answers. The record
  has four fields, the view, the host's request, the keys and the cell,
  so a `req-set` stays the 80 B S2 measured (G4, §15.6).

## 4. The request body: a port that waits

`(req-body req)` is a binary input port. Ring's body is an `InputStream`
and Rack's a `rack.input`; this is the same thing, except that a read that
must wait for the client parks the coroutine.

- Read it with the standard procedures: `get-bytevector-all`,
  `get-bytevector-n`, `get-bytevector-some`, or a parser that reads ports.
- A request with no body reads eof at once.
- The body is read **only as the app reads it**: the server sends
  `100 Continue` at the first read, and reads from the socket on credit,
  so a slow consumer stops the reads. An app that answers without reading,
  such as a 401 to an upload, never takes the body in. The server sends
  that answer at once and closes the connection after it.
- **A body past the server's cap**: a declared `Content-Length` past it
  never reaches the app, the server answering 413 before the handler
  (§7), even for an app that wouldn't read it. A chunked body reaches the
  app, and fails at the read that passes the cap, with `&body-failed`'s
  413. An app that doesn't read it gets its own answer sent. The
  loopback suite holds both (§10).
- **It is the server's port, and there is one.** `req-body` answers
  `body-input-port`'s port (the server's decision 0036), made the first
  time it is asked for and kept in a cell of the request's record, so
  every copy of the request answers the same port (§3). Each port holds
  the piece it is reading, so two ports over one body would split it
  between them. Making the port reads nothing, and an app that never asks
  for it never makes one (432 B, decision 0036). Its close closes nothing
  of the connection's.
- **The body is one stream, read once**, as Ring's `InputStream` is.
  Code that closes `req-body`, or hands it to `transcoded-port` or
  `call-with-port`, closes it for everything that reads it later: R6RS's
  `transcoded-port` closes the binary port it is given, and a read of a
  closed port raises. So code that reads text transcodes it once and reads
  on through the text port, and middleware that parses the body, a form or
  JSON parser, keeps what it parsed under a key (§3).
- **Read it inside its own request's handler call.** The server lets only
  the coroutine of the `awaiting` thunk pull the body, until the thunk
  answers. The app runs on it, so every read inside the handler call
  works, middleware's included. A response's producer runs on coroutines
  of its own (§5), so a producer that reads `req-body` gets the bytes the
  port holds and then is refused with an assertion violation. That comes
  after the head is on the wire, so the server closes the connection and
  logs `handler-failed`; the adapter refuses a response whose body is its
  request's `req-body` before the head instead (§9). The port pulls the
  body of whichever request's thunk is running, not the one it was made
  for, so a port kept and read in another request's handler reads that
  request's body. A response can't stream the request's body back as it
  arrives: an echo or a proxy reads it before it answers (§16.3).
- **No cap of circuit's own.** The server's `CHEZ_HTTP_MAX_BODY_BYTES`
  caps every body. It is unbounded by default, as Ring's `InputStream` and
  Go's `r.Body` are, so an app that reads a body whole should run with it
  set (§16.1).

A read that must wait parks. S1 showed the first two and the last two of
these under the server, with a port of its own. The third and the fourth
are the server's, decision 0036's items 9 and 7.

- **A read is a wait.** It raises `&client-closed` when the client leaves,
  and `&deadline-passed` once a `with-deadline` around it has passed, out
  of the port procedure. A read the port can serve from bytes it holds
  doesn't wait, so it returns even inside a passed deadline: a deadline
  bounds waits, not reads.
- **A raise loses what that read had gathered.** A `get-bytevector-n` of
  any size gathers across waits and returns at the end, so a raise drops
  everything the port's `read!` handed it in that call: 2,000 B of a
  5,000 B and of a 20,000 B read. `get-bytevector-all`, `get-line` and
  `get-string-all` gather the same way, by Chez's source; S1 didn't raise
  inside them. The port stays open and goes on from the next byte.
  `get-bytevector-some` waits at most once and loses nothing, provided the
  port's `read!` waits only when it holds no bytes, and returns what it
  holds. The server's port does (`private/waits.sls`, `body-port`). A
  text port loses data even through `get-string-some` when a piece ends
  inside a character: its decoder drops what it had decoded in that call.
  So after a raise out of a body read, treat the body as gone: answer, or
  raise on. Code that must go on reads with `get-bytevector-some` and
  decodes the bytes itself.
- **After a close, a read raises** `&client-closed` instead of waiting
  for bytes that can't come. S1 saw v0.8.0's waits do the opposite, a wait
  after a caught close parking again. The pull's ends stick. Once it has
  answered eof it answers eof again, a close after it included. Once the
  connection has closed before the body's end, or the body has failed,
  every read that must pull raises. A read the port serves from the bytes
  it holds raises nothing.
- **A body that fails raises `&body-failed`**, an `&error`, after the
  bytes that came before the failure. `body-failed-status` gives the
  status the server answers if the raise gets out: 413 for a body past
  the cap or chunk extensions past 16 KiB, 400 for a malformed one, 408
  for one stalled past `CHEZ_HTTP_BODY_INACTIVITY_TIMEOUT`, and 431 for
  trailers past the server's header limits (its `decisions.sls`). Caught,
  the app's own answer is sent. Either way the connection closes after
  it. The catch helper answers it with that status (§6).
- **A park leaves every `dynamic-wind` around the read** and re-enters it at
  the resume: the after thunk runs at each park, the before thunk at each
  resume (§6).
- **Text reads read ahead.** A UTF-8 `transcoded-port` takes up to 1 KiB at
  a time, and finishes a character split between pieces before it returns,
  so `get-line` can wait for more of the body than its line. A body the
  client sends whole doesn't notice.
- **A read that gathers costs a buffer.** On a Chez custom port, the
  server's included, each `get-bytevector-all` and `get-bytevector-some`
  call allocates about 8.2 KB, whatever the body's size, while a
  `get-bytevector-n` of a known count costs about 30 B. Chez asks a custom
  port's `read!` for 8 KiB at a time. Slice 3 measured it, off the server
  and in it: a 13-byte body read whole costs 8,705 B with the port's 496,
  and 16,913 B read to eof by `get-bytevector-some`. So a small body is
  cheapest read by `get-bytevector-n` of its declared length.

**One path, one coroutine.** The adapter's thunk calls the app for every
request, with a body or without, and answers no reader. The pull runs on
the thunk's coroutine at any size, so a request costs one coroutine
whatever its body. The interim this design had planned until the pull
landed, `read-whole-body` answered from the thunk for a request with a
body, cost three for a body and two for an empty one (S2). It also judged
from the headers whether a body followed, a copy of the server's rule that
A8 would have replaced. The pull needs neither, so circuit never builds
the interim, and doesn't ask `request-has-body?` (§12, §14).

Spike S1 ([findings](research/s1-a-port-that-waits.md)) settled the
interface: the body is a port. Under the real server, a custom port whose
`read!` waits served the binary and text reads S1 tried
(`get-bytevector-n`, `-some` and `-all`, `get-u8`, `lookahead-u8`, and
`get-line`, `get-char` and `get-string-all` through a UTF-8
`transcoded-port`), one `get-bytevector-n` across 12 waits, with two
connections parked in their ports at once. Chez
10.4.1 calls a custom port's `read!` with no lock, critical section or
`dynamic-wind` around it, so a park leaves nothing held.
`(body-read source)` is set aside (§14).

## 5. The response

`(make-res status headers body)`, a record, `res`, in Ring's argument
order. No reason phrase: the adapter passes `#f`, and the server writes
the standard one.

```text
Body = #f                          no body
     | Bytevector
     | String                      sent as UTF-8
     | (-> (U Bytevector Eof))     a producer; may wait
     | BinaryInputPort             streamed, closed once the response is done
     | SizedBody                   (make-sized-body n body): a producer or
                                   port of n bytes, sent with Content-Length
     | WrappedBody                 (res-wrap-body res f [same?]): another
                                   body, its producer passed through f (§6)
     | Upgrade                     §8; status 101
```

- **Headers** are a list of `(name . value)` string pairs, in order, with
  duplicates kept (`set-cookie`). Lookups match any case. The helpers write
  names in lower case. The constructor rewrites nothing, and checks only
  the kinds: an exact integer status, a list of headers, a body of a kind
  above. It leaves a 1xx status to the server, which answers it 500; only
  `res-with-status` refuses one (below). The adapter
  encodes names and values as Latin-1, one byte per character, as the
  server reads request headers; a character above 255 is an assertion
  violation in the adapter, which the server answers 500. Bodies are
  UTF-8, headers Latin-1: a header that must carry non-Latin-1 text
  encodes it itself (RFC 8187).
- **Accessors**: `res-status`, `res-headers`, `res-body`, and `res?`.
- **Helpers**, each giving a new response: `res-header` (look one up),
  `res-set-header` (replace), `res-add-header` (append), `res-with-status`,
  `res-with-body`, and `res-wrap-body` (§6). `res-with-body` replaces the
  body outright, so it closes the port the old body holds, wherever it
  sits: a port body, or one under a sized body or a wrap, at any depth.
  It leaves the port open when the new body holds that same port (`eq?`),
  so `(res-with-body r (make-sized-body n (res-body r)))` keeps it.
  Middleware that keeps the bytes and changes how they go out uses
  `res-wrap-body`, which closes nothing. `res-with-status` on
  an upgrade response, or a 1xx status on any other, is an assertion
  violation: the server refuses both.
- **A producer runs on a coroutine of its own for each piece**, after the
  handler has returned, so it may wait, but no middleware's dynamic extent
  covers it (§2). An SSE body is a producer that waits for the next event
  and returns it encoded. The server's rules bind it: a piece is a
  bytevector of one byte or more, never empty; the eof object ends the
  body; a raise after the head is on the wire closes the connection with
  nothing more said, logged `handler-failed`.
- **A small port body is read whole** (the owner's choice, 2026-10-26).
  A bare port whose length Chez knows, a file or a bytevector port, of
  `CIRCUIT_PORT_PIECE_BYTES` or less, is read by one `get-bytevector-n`
  of that length as the response is built, before any wrap's `f`, and
  closed then. It goes out as a bytevector, at the count read: fewer when
  the file shrank since it was measured, never more, so it never ends
  short of its head. No producer runs and no `request-on-done!` is
  registered, a HEAD, a 204 and a 304 included, which read it and close
  it. Streamed, a 6-byte port cost about 5.1 KB a request over the same
  bytes as a bytevector: the server's producer and its on-done call were
  4 KB of it. Read whole it costs about 300 B, which G7 holds (§15.6). A
  sized body is never read whole: its `n` is the app's, and a port under
  one may wait.
  It was weighed to keep streaming every port, with cheaper close
  handling alone: that saved about 634 B of the 5.1 KB.
- **A port body of more than one piece**, a port Chez gives no length,
  and a sized one are read by a producer the adapter makes, in pieces of
  `CIRCUIT_PORT_PIECE_BYTES`, 64 KiB by default, with `get-bytevector-n`:
  one coroutine per piece, so bigger pieces cost less. Chez asks a custom
  port's `read!` for at most 8 KiB at a time, so a 64 KiB piece of a
  custom port is up to eight reads, and one that waits may wait at each
  (slice 3 measured it). The producer
  answers eof once it has read the port's last byte, at the port's eof or,
  for a sized port, at its length, and closes the port then. It never
  reads 0 bytes: Chez's `get-bytevector-n` of 0 answers an empty
  bytevector, even on a closed port, and an empty piece is no piece. The
  server never asks a sized producer past its length, but a wrap may
  (§6). The adapter also closes the port from a `request-on-done!`
  procedure it registers, so the port is closed however the response
  ends: sent whole, a HEAD, a 204 or a 304 where the server never calls
  the producer, or a client that leaves mid-stream (§7). Closing a port
  twice does nothing.
- **A port body is a regular file that holds what its size says, a
  bytevector port, or a custom port that waits.**
  - **A port whose reads block, a pipe or a socket, blocks the loop.** On
    a FIFO, Chez's `port-position` raises, so the adapter's measuring
    answers 500 (§9).
  - **Files in procfs and sysfs pass `file-regular?` but report a size
    that isn't theirs.** On Linux, `/proc/self/status` reports 0 and a
    sysfs file such as `/sys/kernel/mm/transparent_hugepage/enabled`
    reports 4096 while holding 23 bytes. So the first would go out empty
    and the second end short. Read such a file whole and answer its bytes.
  - **Check `file-regular?` before opening a path as a body**, as the
    server's file-server example does. It refuses `/dev/zero`, which
    reports 0 too, and a FIFO.
  - **A custom port is never measured.** Chez gives no custom port a
    length, so it goes out chunked, and its measuring never raises. A
    bytevector port refuses a position past its end, so only a file can
    sit past its length (slice 4 reproduced both).
- **A port body goes out with its length when Chez knows it.** For a port
  with a position and a length, a file or a bytevector port, the length
  is the bytes from its position to its length, or none when the position
  is past the length. One of a piece or less goes out as its bytes (above);
  a longer one as the server's `sized-body` of that length. A HEAD then
  announces the GET's length, and an HTTP/1.0 client that asked to keep
  its connection keeps it. Any other port goes out chunked, or
  close-delimited to an HTTP/1.0 client. `port-has-port-length?` and
  `port-length` are Chez's, so the adapter takes them through ADR-0006's
  allowlist (§11, §15.8). For a port of more than one piece, the
  adapter's producer reads no more than the length left, so a file that
  grows while it is sent goes out as long as it was. One that shrinks ends
  short of the length the head announced:
  the server closes the connection after what it sent, and logs
  `body-length-mismatch` (decision 0033).
- **`(make-sized-body n body)`** declares a producer's length, or a
  port's, where Chez can't tell it: `n` a count of bytes, `body` a
  producer or a port. The adapter answers `sized-body` with it, and the
  server's rules for a mismatch hold. Circuit's names steer clear of
  `(http-server response)`'s `sized-body?`, `sized-body-length` and
  `sized-body-producer`.
- **A body has a length** when it is one of these:
  - `#f`: 0;
  - a bytevector: its length;
  - a string: the length of its UTF-8 bytes;
  - a sized body: its `n`;
  - a port with a length: from its position to its length, or 0 past it;
  - a wrap that keeps the bytes (§6), over any of these.

  A body with a length goes out with `Content-Length`. A producer, a port
  with no length, and a wrap that drops the length go out chunked.
  `res-body-length` answers the length where the core can tell it. It
  answers `#f` for a port, and for a wrap that keeps the bytes over one:
  a port's length is Chez's, which the core can't ask (ADR-0006), so the
  adapter reads it. It answers `#f` for a body with no length too.
- What the server refuses (a `Content-Length` or `Transfer-Encoding`
  header, `Connection` other than `close`, control characters, a 1xx
  status) it still refuses: 500, logged. Circuit doesn't check these again,
  and middleware ported from Ring that sets `content-length` itself will
  meet that 500. It declares the length with `make-sized-body` instead.
- The adapter checks `res?` on what the handler returns. Anything else is
  an assertion violation naming the value, which the server answers 500
  and logs `handler-failed`.

## 6. Middleware

`Handler -> Handler`. `(wrap handler m ...)` applies each middleware in
turn, so the **last is outermost**: `(wrap h a b)` is `(b (a h))`, as
Ring's `(-> h a b)` is. A test holds the order.

Rules for middleware authors, each a fact about the server:

- **Re-raise `&client-closed` and `&deadline-passed`.** Both are
  `&error`, so a catch on `error?` takes both. Swallowing the close is
  not harmless: it is raised once, no deadline covers a handler, and a
  handler that then waits again parks for good. A handler that catches it
  may still answer: a client that half-closed its side reads the response;
  only a reset drops it. Swallowing the deadline turns a 504 into a 500. So
  `wrap-timeout` goes **outside** the catch middleware, and the catch
  middleware's helper re-raises both before catching the rest.
- **Catch with `call/cc` around `with-exception-handler`.** S2 measured
  each way to catch on a coroutine, over the app alone. With nothing
  raised, the helper by `call/cc` costs 309–365 B, `guard` 377–414 B, and
  a helper by Chez's `call/1cc` 407–860 B, which grows to 3.4–3.5 KB once
  the app parks inside it. Catching an `error`, parked or not, they cost
  955–1,038 B, 1,197–1,306 B and 4.1–4.3 KB. On a coroutine the one-shot
  escape is never the cheaper, and its cost jumps once a full capture
  falls inside it: a park, or Chez's `error`, whose condition carries the
  raise's continuation. So the catch helper escapes by `call/cc`, which is
  plain R6RS. It re-raises `&client-closed` and `&deadline-passed` from
  where they were raised, before anything unwinds, and turns any other
  raise into a 500 `res`. S2 showed it right across one and three parks, a
  deadline and a client's close. Decision 0025's figure for `guard` stands,
  and the server's `docs/waiting.md` now gives the same costs (§12).
- **Answer `&body-failed` with its status.** A body that fails while the
  app reads it raises `&body-failed`, also an `&error` (§4). A catch on
  `error?` that answers 500 turns a 413 into a 500. The catch helper
  answers it with a `res` of `body-failed-status`, so middleware outside
  it, such as logging, sees the 413 the client gets, not a raise. The
  server closes the connection after it, and every later read of the body
  raises it again (§4).
- **Catch.** A raise that reaches the server before the head is answered
  with an empty 500 and `Connection: close`, but for two: a `&body-failed`
  gets its own status, and a `&client-closed` nothing, its client gone.
  Each failing request costs the client its connection: 7.2–8.3 KB a
  request, and under a third of the rate at 50 connections (S2).
- **Don't free a resource in a `dynamic-wind` after thunk.** A park leaves
  every `dynamic-wind` around it and re-enters it at the resume (S1). The
  server's own `with-deadline` relies on it: its after thunk asks
  `coroutine-suspending?` to tell a park from a leaving
  (`private/waits.sls:385`). So an
  after thunk runs at every wait inside the handler, a body read included.
  Free the resource when the call returns, and on a raise with an exception
  handler that raises on.
- **A timeout is `with-deadline`.** `(wrap-timeout ms)` answers 504 when
  `&deadline-passed` reaches it. The deadline covers the body's reads,
  which run inside the handler call (§4). It never covers a producer (§2),
  and it cuts nothing short that isn't waiting: CPU work and a blocking
  port read run on.
- **Streaming middleware wraps the body with `res-wrap-body`.**
  `(res-wrap-body res f)` gives a response whose body is the old one
  passed through `f`, a `Producer -> Producer`. The adapter hands `f` the
  old body as a producer and sends the producer `f` gives back. A port
  is read in pieces, and a bytevector or string is one piece. `#f`, or an
  empty bytevector or string, answers eof at once: never an empty piece.
  Wrapping an upgrade is an assertion violation. So middleware handles
  one shape, compression or byte counting alike.
  - **The wrap is lazy**, because only the adapter can turn a port into a
    producer: it knows the piece size and the port's length. So a port
    under a wrap is still the adapter's to close however the response
    ends, and nothing closes it early, as `res-with-body` would (§5).
  - **The new body has no length**, since a compressor's bytes differ.
    `(res-wrap-body res f #t)` says `f` gives back as many bytes as it is
    given, as a counter does. So the body keeps the length of the one
    under it, whenever that has one (§5), a port's included.
  - **A wrap that drops a length still stops at it.** The server asks
    nothing past a sized body's length, but a compressor asks again for
    eof. So when the wrap drops the length of a body that had one, the
    adapter hands `f` a producer that counts to the length and then
    answers eof itself, never asking the producer under it again. A piece
    that would take it past the length is a mismatch, so the counting
    producer raises after the head, and the connection closes, logged
    `handler-failed`. An end short of the length just ends: the wrap's
    body has no length to fall short of.
  - **`f` runs in the adapter's thunk**, on the request's coroutine, after
    the app has returned. So it may wait, and may read `req-body`. But no
    middleware's dynamic extent covers it, so a raise from it gets the
    server's empty 500, not the catch helper's answer. The producer it
    gives back runs as any producer does (§2). Once the client has gone
    while the app waited, the request is done, and the close the adapter
    registers for a port of more than one piece runs at once, before `f`
    (§9): `f` is handed a
    producer over a closed port, so an `f` that reads a piece eagerly
    raises. The response goes nowhere, but the server may log the raise
    (slice 4 saw it in the test host, which doesn't log it).
  - **The wrapped producer keeps the server's rules**: never an empty
    piece, so a compressor loops until it has bytes or reaches eof. A
    sized body's producer is never asked past its length, so under a
    wrap that keeps the bytes it never sees eof. A counter reports its
    total from a `req-on-done!` procedure (§7).
- **`wrap-timeout` and the catch helper need the server's verbs**
  (`with-deadline`, `deadline-passed?`, `client-closed?`, `body-failed?`,
  `body-failed-status`), and
  `with-deadline` is refused off a coroutine. So they can't live in the
  pure core: they live in `(circuit middleware waits)`, which imports
  `(http-server)` (§11). A handler wrapped in `wrap-timeout` can't be
  called directly in a test, since `with-deadline` is refused off a
  coroutine; it is tested through the server's test host (§10). One
  wrapped only in the catch helper can be, when it doesn't wait: the
  helper is plain R6RS and needs only the server's predicates and
  `body-failed-status`. Its answer to `&body-failed` is tested directly
  too. The facade exports no constructor for the condition, but
  `(http-server awaiting)`, a public library, exports `make-body-failed`,
  so a test builds one. A body that fails in the test host checks the
  rest: the server closes the connection after the helper's answer.

## 7. When a response is done

Three moments, which the overview's principle 13 tells apart:

1. **The handler returned**: middleware sees this as the call returning.
2. **The body was produced**: the adapter sees the producer's eof, or a
   sized body's last byte.
3. **The response is done**: sent, or the client left, or the server
   ended it. Only the server knows, and `request-on-done!` tells it (A6,
   the server's decision 0034).

Logging and metrics middleware want 3, and so does a port body (§5).
`(req-on-done! req proc)` registers `proc` with the server's request
under `req`, and the server calls it once, with how the response ended:

- `written`: every write of the response completed;
- `client-closed`: the client closed or reset the connection first, or a
  write to it failed, or a sized body ended short after the client had
  closed;
- `failed`: the server ended it: its own status in place of the app's (a
  500 for a raise or for an answer it can't write, or a `&body-failed`'s
  status when the raise got out), a producer's raise after the head, a
  sized body that ran long or otherwise ended short, a write that timed
  out, or a close from outside the server's core.

A request the server refuses before its handler, such as one whose
declared length is past the cap, reports nothing: no code ran to
register. A failed body that the catch helper answers ends `written`,
the helper's answer sent (§6).

The server's rules hold:

- **Newest first.** Procedures run in reverse order of registration, so
  the outermost middleware, which registers first, hears last, as it
  unwinds.
- **In place, and quick.** A procedure runs on no coroutine, so a wait
  inside it is refused. A raise is logged `on-done-failed` and changes
  nothing: the others are still called.
- **After the request's code stops.** While the app or a producer still
  runs on a coroutine, the procedures wait for it to stop. Otherwise they
  run before the next request on the connection is read.
- **One registered late runs at once**, in the caller, so each procedure
  is called exactly once. Its raise is the caller's.

A test request's view has no `on-done`, so the request keeps its
procedures (§3). `(test-req-done! req ending)`, from `(circuit test)`,
calls them by the same rules, and answers what they raised:

- **Newest first**, each once.
- **A raise doesn't stop the rest.** Where the server would log
  `on-done-failed`, `test-req-done!` collects the condition, and answers
  the list of them, oldest raise first, `'()` when none raised.
- **The first ending holds.** A second call calls nothing and answers
  `'()`, as the server's `request-done!` hands back no procedures once
  the request is done.
- **One registered after it runs at once**, with the first ending, and
  its raise is the caller's.
- **An ending other than `written`, `client-closed` or `failed`** is an
  assertion violation, as it is in the server.

## 8. Upgrades

`(make-upgrade-res headers take-over)` is a response with status 101 and
an `Upgrade` body holding `take-over`, a procedure of the host's transport
and the bytes read past the request. Middleware sees the status and the
headers, and passes it through. The adapter answers
`(switch-protocols headers take-over)` from the thunk, the path the server
tests. The server takes no upgrade with a body, so the app has none to
read. The take-over may answer `awaiting`, as the server allows. A
take-over's transport carries no addresses, so a taker that needs them
reads them from the request first (§3). The
server's rules still apply: an upgrade answered to a request that can't
take one is a 500.

WebSocket through circuit needs chez-websocket's handshake to work from a
circuit request. Today `websocket-accept` takes the server's request. That
belongs to the WebSocket slice, and may be an ask on chez-websocket.

## 9. The adapter

`(circuit http-server)` and `(circuit middleware waits)` are the only
libraries that import `(http-server)`.

- `(circuit->handler app [env])` gives a server handler, which answers
  `(awaiting thunk)` for every request. The thunk builds the request,
  calls `app`, and turns the response into the server's answer. The app
  reads its body through `req-body` on the thunk's coroutine (§4), so the
  thunk never answers a reader. The server calls a response's producer on
  a coroutine only for a handler that answered `awaiting`, so a producer
  may wait too.
- **A port body is measured, then read whole or its close registered,
  then the rest done.** The thunk reads the port's position and length
  first, closing the port and raising on if that raises. A port of a
  piece or less it reads whole and closes there (§5). For any other it
  registers the close at once. Only then does it do what else can raise:
  the headers' encoding, and `f` for a wrapped body. A close registered
  before the measuring
  would run at once if the client had left while the app waited, and the
  measuring would meet a closed port; anything that raised between the
  measuring and the registration would leak the port. `res-body-stream`
  keeps the order for it: it calls the adapter's `measure`, then its
  `on-port`, where the adapter registers the close, and only then any
  `f`; a raise from either, or from the read, closes the port (§11). On
  a request already done, a client that left while the app waited, the
  registration runs the close at once, so `f` then meets a closed port
  (§6). A port read whole leaves `f` its bytes, so this is only a longer
  port's.
- **A response whose body is its request's `req-body`** is an assertion
  violation in the thunk, so the server answers 500 before the head. Its
  producer couldn't read the port (§4). The adapter looks through sized
  bodies and wraps, at any depth, so `(make-sized-body n (req-body req))`,
  the natural echo, is refused too. The cell makes it one `eq?` a layer,
  and a request whose port was never made skips the check.
- `(run-server app [env])` is `(http-server)`'s `serve` over
  `circuit->handler`, as Ring's adapters are `run-jetty` and friends.
- It re-exports the server's waits and the conditions they and the body
  raise: `await`, `sleep-ms`, `with-deadline`, `resolve`;
  `&deadline-passed`, `deadline-passed?`, `&client-closed`,
  `client-closed?`, `&resolve-error`, `resolve-error?`,
  `resolve-error-reason`; `&body-failed`, `body-failed?`,
  `body-failed-reason`, `body-failed-status`. So an app needs only
  `(circuit)` and `(circuit http-server)`. A re-export is the same
  binding, so a program that also imports `(http-server)` doesn't clash on
  them (R6RS §7.1).
- **It doesn't re-export `next-body-piece` or `body-input-port`.**
  `req-body` is the body's one port, and a second port, or a pull beside
  it, would split the body (§4). An app that also imports `(http-server)`
  gets both, and leaves them alone.
- Settings come from the environment procedure, as the server's do
  (12-factor): `CIRCUIT_PORT_PIECE_BYTES` for port bodies. The body's cap
  is the server's `CHEZ_HTTP_MAX_BODY_BYTES` (§4). Given no environment
  procedure, the adapter reads the process's environment with Chez's
  `getenv`, as `serve` does (ADR-0006).
  - **`circuit->handler` reads them once, when it is called**, not per
    request, so `run-server` refuses a bad one before anything listens.
  - **A number is the server's**: ASCII digits alone, leading zeros
    allowed, at least 1; unset or empty keeps the default, 65,536. There
    is no maximum, but a count past `(greatest-fixnum)` is taken as it:
    Chez's `get-bytevector-n` refuses a count that is no fixnum.
  - **A malformed one is a config error of the server's kind**: a
    condition type of circuit's, unexported, whose parent is
    `&http-server-config-error`, composed with a `&who`, a `&message` and
    `&irritants` naming the variable and its value, so
    `http-server-config-error?` answers `#t` as it does for `serve`'s own.
    Unlike `serve`'s, it is no `&assertion`. A value that is no string is
    malformed too.

| Response body | Server answer |
|:--|:--|
| `#f`, bytevector | `(make-response status #f headers body)` |
| string | the same, with `(string->utf8 body)` |
| producer | the same, with the producer |
| port with a length of a piece or less | the same, with the bytes one `get-bytevector-n` reads, from the port's position to its length, or none past it; the port closed then, with no producer and no `request-on-done!` (§5) |
| port with a longer length | the same, with `(sized-body n producer)`: `n` from the port's position to its length; the producer reading no more than is left, answering eof at the last byte and closing the port then; the port closed by a `request-on-done!` procedure too (§5) |
| any other port | the same, with a producer of `get-bytevector-n`, the port closed at its eof and by a `request-on-done!` procedure |
| sized body | `(sized-body n producer)`, a port's producer as above, never read whole |
| wrapped body | the body under it as a producer, passed through `f`: whole bytes, a small port's included, as one piece. Sized when the wrap keeps the bytes and the body under it has a length (§5). Otherwise sent as a producer, the one handed to `f` stopping at the length the body under it had. A port read whole or closed as above (§6) |
| the request's `req-body`, bare, sized or wrapped | refused: an assertion violation, a 500 before the head |
| upgrade | `(switch-protocols headers take-over)` |

## 10. Testing

- **A handler that doesn't wait** is called directly:
  `(app (make-test-req 'GET "/health"))`, with no server.
  `(make-test-req method target [headers [body]])` splits the target at
  its first `?` into the path and the query, takes a header list and a
  body (a bytevector, a string as its UTF-8, or `#f` for none), and
  supplies a view of its own (§3): the host is the first `host` field's,
  or `""` without one; HTTP/1.1; no addresses and no `on-done`. It reads
  as the server reads an origin-form request. A target must begin with
  `/`: an absolute-form or asterisk-form one, whose host and path the
  server reads differently, belongs in the test host. Each header value
  loses its spaces and tabs at either end, as the server's do.
- **A handler that waits**, or one wrapped in `wrap-timeout`, or one that
  reads the server's body, its credit, `100 Continue` and `&body-failed`,
  needs a host where waits work. A test request's own body is a
  bytevector port, read with no host. One wrapped only in the catch
  helper needs none either, unless it waits (§6). The server ships one,
  `(http-server testing)` (A7, the server's decision 0038):
  `make-test-host` hosts `(circuit->handler app env)`, a client sends wire
  bytes, a body in pieces among them, and closes or resets, the test
  moves the clock and answers lookups, and it reads back the responses,
  the raw bytes and the server's log. Nothing hangs: a handler still
  waiting is reported. Slice 4's `tests/test-http-server.sps` runs the
  adapter this way. A row that asserts a response asserts it whole, as
  its wire bytes, with whether the connection ended and the server's log;
  the rest assert what the app read, or the chunks and bytes sent (the
  suite's header lists which). It holds that `res-body->bytevector`
  reads, body kind by body kind, the bytes the test host's client reads.
- **What the test host leaves out, a loopback lane runs.** It has no
  socket, so no addresses, and no slow reader or write timeout; its
  timeouts fire at their earliest instant, where the server's fire up to
  `CHEZ_HTTP_TICK_MS` later (docs/testing.md). An integration lane runs
  the adapter over loopback with curl for those. Slice 4's
  `tests/test-examples.sps` runs each example, and a test-only program,
  `tests/loopback-app.sps`, as processes of their own, on the kernel's
  choice of port and an environment of the suite's own (`env -i`), and
  asks them with curl. It holds the examples' answers, read whole; the
  four addresses through a real connection, from 127.0.0.2 too, where
  curl can bind it; `run-server` reading `CIRCUIT_PORT_PIECE_BYTES` and
  the server's settings from the process's environment; a malformed
  setting ending the process before it listens; a 300,000-byte chunked
  body read whole; the server's cap, a declared body past it refused
  before the app and a chunked one past it answered by the app; and the
  long poll's wake, one send waking every waiter, and a leaving client
  forgotten, each ordered by the example's `GET /waiting`. The long
  poll's 504, 30 s away, is held in its shape by the adapter's suite: an
  app that awaits inside `with-deadline`.
- **Names don't clash, by test.** A suite imports `(http-server)`,
  `(http-server testing)`, `(circuit)`, `(circuit http-server)` and
  `(circuit test)` together with no `only` or `rename`, so an export that
  clashes fails it (§15.3). Circuit's tests import them together.
- **Order and shape, by test:**
  - `wrap`'s order;
  - a port body closed however its response ends: at its last byte, on
    HEAD, 204 and 304, and when the client leaves mid-stream, wrapped or
    not;
  - a port with a length sent sized; one that shrinks ending short; one
    under a wrap that keeps the bytes still sized;
  - a wrap that drops a length stopping at it, and an empty body reaching
    `f` as eof;
  - `res-with-body` closing the old port at any depth, but not one the
    new body holds;
  - one `req-body` port for every copy of a request;
  - refusals: a response whose body is its request's `req-body`, bare,
    sized or wrapped; a non-`res`; a view without one of the four
    required procedures;
  - `test-req-done!` keeping the server's rules;
  - the catch helper re-raising the two conditions, and answering
    `&body-failed` with its status, both with one built by
    `make-body-failed` and from a body that fails in the test host.

## 11. Libraries

```text
(circuit)               facade: the core's exports
(circuit request)       the req record, view, keys
(circuit response)      the res record, body kinds, helpers
(circuit headers)       header lists: header-value, header-values,
                        header-set, header-add, header-remove,
                        header-names-downcase
(circuit middleware)    wrap, and the pure middleware
(circuit middleware waits)
                        wrap-timeout and the catch helper; imports (http-server)
(circuit test)          make-test-req, test-req-done!, res-body->bytevector
(circuit http-server)   the adapter; imports (http-server)

later: (circuit router), (circuit websocket), middleware libraries
```

**`(res-body->bytevector res [req])` reads a body as the adapter sends
it**, through `res-body-stream` in 64 KiB pieces.
- A sized body: to its `n`, never asking past it. One that runs long or
  ends short is an assertion violation naming both counts, where the
  server would close the connection.
- A wrap: through its `f`, handed the producer the adapter would hand it,
  so it stops at the length the body under it had.
- A bare port: measured as the adapter measures it, in plain R6RS. A
  port with a position it can set is read ahead to its eof and set back,
  and sent sized, from its position, read whole when it is 64 KiB or
  less; any other is read to its eof. A custom port with position
  procedures is sized here, though Chez gives it no length and the
  adapter sends it chunked, so there the test is the stricter.
- Bytes whole are answered as they are: a bytevector body is the app's
  own bytevector, not a copy.
- Given the request, it refuses a body that holds that request's
  `req-body`, bare, sized or wrapped, as the adapter does (§9), so the
  natural echo fails its test as it would fail in production.

So a counter that reports only at eof fails its test, as it would fail
in production (§6).

**What the adapter and the tests need of the core.** They need more of
the core than an app does, and R6RS has no friend libraries. So
`(circuit request)` and `(circuit response)` export it, and the
`(circuit)` facade doesn't. The names suite holds these apart from the
server's too (ADR-0005). Slice 3 settled the names:
- `make-req-view`, the view's constructor, its fourteen procedures in
  §3's order, which refuses `#f` for the four required ones, and
  `make-req`, which makes a request from a view and the host's request
  (§3);
- `req-body-made`, `Req -> (U BinaryInputPort #f)`: the port in the
  cell, or `#f` when nothing has made it, without making one. The
  refusal of `req-body` as a response body reads it (§9), and asking
  `req-body` instead would spend 432 B on every request;
- the body kinds' accessors: `res-sized-body?`, `res-sized-body-length`
  and `res-sized-body-inner`; `res-wrapped-body?`,
  `res-wrapped-body-inner`, `res-wrapped-body-proc` and
  `res-wrapped-body-same?`;
- `res-body-port`, `Body -> (U BinaryInputPort #f)`: the port a body
  holds, bare, under a sized body or under wraps, or `#f`. A body holds
  one at most. The adapter measures it and registers its close, and the
  `req-body` refusal compares it (§9);
- `res-body-stream`, `Body (BinaryInputPort -> (U Nat #f))
  (BinaryInputPort -> Any) Nat -> (Values (U Bytevector Producer) (U Nat
  #f))`: what sends a body, and its length or `#f`, by §5's and §6's
  rules: a bytevector when the bytes are whole (`#f` as `#vu8()`, a
  bytevector itself, a string's UTF-8, a port read whole), otherwise a
  producer. For a bare port, it calls `measure` once with it; a length of
  the piece size or less it reads whole and closes, calling no `on-port`.
  Any other port, a sized body's included, it hands to `on-port` once,
  before any `f`. A raise from either, or from the read, closes the port
  and goes on, and no `f` runs; a raise from `f` closes nothing, the port
  by then the adapter's. One `with-exception-handler` closes the port on
  a raise, where two `guard`s did: about 634 B less a port. The
  last argument is the piece size. The adapter passes Chez's port
  length, a registration of the port's close, and
  `CIRCUIT_PORT_PIECE_BYTES`. It is the one place a wrap's `f` is called,
  so the adapter and the tests send a body the same way;
- `test-req-done!`, which lives in `(circuit request)` beside the cell
  it reads, and which `(circuit test)` re-exports.

The core is plain R6RS and imports nothing of the server's. The two
impure libraries import `(http-server)`, and take from `(chezscheme)` only
what ADR-0006's allowlist names, through `only`: `getenv`, and
`port-has-port-length?` and `port-length`, which the adapter sizes a port
body with (§5, §15.8). Slice 4 amended the allowlist and ADR-0006 with the
code that needs them. The catch helper is plain R6RS, and lives in
`(circuit middleware waits)` because it needs the server's
`client-closed?`, `deadline-passed?`, `body-failed?` and
`body-failed-status`. chez-http-server is a pinned submodule under
`vendor/`, as it is in chez-websocket, at v0.9.0 (§15.7). It isn't on the
Akku index, so it can't be an Akku dependency yet (ADR-0003).

## 12. Upstream asks: all landed

On chez-http-server. All eight were filed on 2026-10-25, from the drafts in
[upstream/](upstream/), and all eight merged on its main by 2026-10-26,
each closing its issue. The server tagged them as v0.9.0 on 2026-10-26,
at d928e41, and circuit's pin moved to it that day (§15.7). v0.9.0 also
drops `(http-server request)`'s `request-body`, which circuit never used.
No workaround was built, so there is no probe to remove. The names in
this table are the server's.

| # | Issue | Landed as | Circuit uses it for |
|:--|:--|:--|:--|
| A1 | [#214](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/214) | `request-header-list`, names as sent, in wire order (#219, decision 0032) | `req-headers`, names folded to lower case (§3) |
| A2 | [#215](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/215) | `request-http-major` and `request-http-minor` in the facade (#218) | `req-http-version` |
| A3 | [#229](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/229) | `request-remote-address`, `-remote-port`, `-local-address`, `-local-port`, read once a connection (#238, decision 0037) | the four `req-` accessors (§3) |
| A4 | [#227](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/227) | `next-body-piece`, and `body-input-port` over it; `&body-failed` (#234–#237, decision 0036) | `req-body`, the one path (§4); the catch helper's third rule (§6) |
| A5 | [#216](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/216) | `(sized-body n producer)` (#221–#223, decision 0033) | `make-sized-body`, and port bodies with a length (§5) |
| A6 | [#217](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/217) | `request-on-done!`, with `written`, `client-closed` or `failed` (#224–#226, decision 0034) | `req-on-done!` (§7); closing a port body (§5) |
| A7 | [#230](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/230) | `(http-server testing)`, installed with the package (#239, decision 0038) | the tests of the adapter, of `(circuit middleware waits)` and of apps that wait (§10) |
| A8 | [#228](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/228) | `request-has-body?` (#232, decision 0035) | nothing: the pull left the adapter one path (§4) |

Where the server went past the ask, or set rules of its own:

- **A4 gives a port as well as the verb**, so circuit builds no port of
  its own. Only the `awaiting` thunk's coroutine may pull, until it
  answers. A failed body raises `&body-failed`, every call after it too.
  The first read fixes the cap. Its statuses are 413, 400, 408 and 431,
  the last for a chunked body's trailers past the header limits (its
  decision 0036 item 7, its `decisions.sls`, and `connection.sls`'s
  trailers). The server's `docs/waiting.md`
  lists only the first three: a docs note upstream, filed after the
  revision as
  [#241](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/241).
- **A5 refuses a piece past the length**, none of it written. That and a
  body that ends short both end the response short, close the connection
  after it, staged, and log `body-length-mismatch n given`. A length of 0
  never calls the producer, and no producer is asked past its length.
- **A6 runs procedures in place, newest first**, once the request's code
  has stopped, and runs one registered late at once.
- **A3 gives the ports too.** The test host has no addresses, and a
  take-over's transport carries none.
- **A7 covers every point circuit listed.** The fake shell itself moved to
  `(http-server private fake-shell)`, which circuit doesn't import.

Besides the asks, the two fixes to the server's `docs/waiting.md`, filed as
[#231](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/231)
([draft](upstream/docs-waiting-costs-and-dynamic-wind.md)), landed as #233.
Its "Costs to know" now gives S2's figures. `guard` costs about 0.4 KB, and
1.2 KB catching an `error`. `with-exception-handler` costs 0.15 KB, and
0.3 KB once the code inside it waits. An escape by `call/1cc` costs 3.4 KB
or more, and one by `call/cc` a little less than `guard`. The page also
says that a wait runs the after thunk of every `dynamic-wind` around it,
and the resume its before thunk.

## 13. Spikes before the decision records

- **S1, a port that waits: done 2026-10-25. The body is a port**
  ([findings](research/s1-a-port-that-waits.md)). A custom binary input
  port whose `read!` calls `await` was read under the real server, with a
  second request resuming the first. Every standard binary and text read
  worked across parks, whole and in order. `&deadline-passed` and
  `&client-closed` came out of `get-bytevector-n`, and two ports parked at
  once on two connections stayed apart. Probes in `read!`, checked against
  a control, found no lock, critical section or `dynamic-wind`, as
  `s/io.ss` reads. A raise loses what a gathering read collected (2,000 B
  of a `get-bytevector-n`); `get-bytevector-some` loses nothing; a text
  port loses its decoder's chunk when a piece ends inside a character (§4).
  The server's own port, which A4 brought, keeps what S1 asked of one: it
  waits only when it holds nothing, and returns what it holds.
- **S2, the cost of a coroutine for every request: done 2026-10-25**
  ([findings](research/s2-coroutine-cost.md)). Through server v0.8.0, with
  an adapter-shaped prototype:
  - a hello-world GET allocates 1,324–1,440 B a request more than the raw
    server, 1,036–1,154 B of it the coroutine, and answers 93–95% of
    raw's requests a second at 50 keep-alive connections;
  - a 13-byte POST read whole costs 2,863–2,951 B more, for three
    coroutines, at 91–94%. That was the interim's path, which the pull
    replaces (§4). For a 16-byte body the server measured 10,610 B a
    request under `awaiting` with `read-whole-body`, 8,466 B pulled, and
    13,071 B through its port into a 4 KiB buffer, the buffer included
    (decision 0036, Darwin arm64). Slice 4 measured the pulled POST
    through the real adapter: 1,433–1,443 B over raw, read by
    `get-bytevector-n` of its length (§15.6);
  - five `req-set` middlewares add 383–409 B.

  The catch helper escapes by `call/cc`, not `call/1cc` (§6). Circuit runs
  every request on a coroutine whatever the number (§15.2), so S2 didn't
  decide that. The owner set the gate it proposed on circuit's cost over
  the raw server (§15.6).

## 14. Weighed and set aside

- **The answer sum in circuit.** Handlers return
  `Res | Reader | Awaiting | Upgrade`, and middleware maps over the
  eventual response with a combinator. It costs nothing for handlers that
  don't wait. But middleware that acts around a handler in time, such as
  timing, catching errors or deadlines, must wrap each of the reader's
  procedures and the thunk separately. That is Ring's async problem, which
  coroutines remove.
- **Ring's three-argument async handler**, and futures. Each adds a second
  style of handler that coroutines make unnecessary.
- **ASGI's `(scope receive send)`.** It fits coroutines well, but it is not
  Ring or Rack, and a plain response value is easier to compose and test.
- **Turning the reader's push into a pull in the adapter with `call/cc`**,
  re-entering the app's continuation from each `on-piece`. It doesn't
  work: the continuation was captured on one coroutine's drain, and
  re-entering it from another's re-runs that drain (the server's decision
  0025). The server's pull, A4, instead.
- **Buffering bodies**, with `read-whole-body` from the thunk, the interim
  this design planned until the pull landed. It was never built (§4).
- **A cap of circuit's own on the body**, the interim's
  `CIRCUIT_MAX_BODY_BYTES`, 1 MiB by default: it bounded a buffer circuit
  no longer keeps. The server's setting is the one cap (§4, §16.1).
- **A `content-length` header read as a streamed body's length**, as
  Ring's middleware sets it, and taken off before the server sees it: the
  adapter would rewrite the head the app gave (§15.8).
- **Re-raising `&body-failed` from the catch helper**, as it re-raises the
  close and the deadline: middleware outside it would see a raise, not the
  status the client gets (§15.9).
- **`res-body->producer`**, a port body turned into a producer in the
  core, which middleware wrapped and put back with `res-with-body`. That
  closed the port the new producer read, and left the adapter a producer
  where the port had been, so it could neither close the port nor size it.
  `res-wrap-body`'s lazy wrap instead (§6, §16.4). Weighed too: middleware
  that leaves port bodies alone, which rules out compressing a file.
- **A body source read by `(body-read source)`**, with helpers that do what
  the port procedures do: the fallback had a port's `read!` been unable to
  park. S1 showed it can (§4).
- **Names shared with the server's** (`make-response`, `request-path`),
  sorted out with `only` and `rename` imports. Set aside by the owner: an
  app that uses both libraries shouldn't need either.
- **A reader for any request**, and asking `request-has-body?` to choose.
  Before the pull, the plan answered a reader for a request with a body,
  and judged from the headers which had one, until A8 let it ask. A reader
  for every request was set aside too: the server's types exclude a switch
  from a reader's end, and it cost a second coroutine on every bodiless
  request. The pull serves every request from the thunk's one coroutine,
  and one with no body reads eof at once (§4).

## 15. Decided

The owner's answers to this draft's open questions (2026-10-25):

1. **Middleware's data on a request goes under unique keys**, made by
   `make-req-key`, not symbols (§3).
2. **Every request runs on a coroutine.** The adapter has no option to call
   an app in place. S2 measured what that costs (§13), and item 6 sets the
   gate on circuit's cost over the raw server.
3. **Circuit's names don't clash with `(http-server)`'s.** An app may import
   both libraries without `only` or `rename`, and a suite holds it (§10):
   - requests are `req` and responses `res`: `req-path`, `req-header`,
     `req-body`, `req-ref`; `make-res`, `res-status`, `res-set-header`;
   - the adapter's entry is `run-server`, and the procedure that makes a
     server handler is `circuit->handler`.
4. **`wrap-timeout` and the catch helper live in `(circuit middleware
   waits)`**, a second library that imports `(http-server)`, so the core
   stays pure and the adapter is only the adapter. An app that uses them
   imports three circuit libraries. Weighed: beside the adapter in
   `(circuit http-server)`, which a second adapter would have to carry;
   and in the pure core with the verbs passed as arguments, which every
   call site would repeat, and which the Chez-only `call/1cc` rules out.
   S2 has since moved the catch helper to `call/cc` (§6), so the
   `call/1cc` reason no longer holds. The owner revisited it on 2026-10-25
   and kept the helper here, on the reason that remains: its correctness
   rests on the server's `client-closed?` and `deadline-passed?`, and what
   knows the server's conditions lives in the library that imports the
   server, beside `wrap-timeout`, which must. Weighed then too: a generic
   catch in the core taking the predicates, bound to the server's in this
   library. It would serve a second host there isn't, at the cost of two
   names for one job and a core version that invites the wrong predicate;
   if a second host comes, it can be factored out then.
5. **A1 asks for `request-header-list`**, the third of the family
   `request-header`, `request-header-values`, `request-header-list`.
   Weighed: `request-fields`, RFC 9110's term but a stranger beside the
   others; `request-headers*`, whose star says "variant", not "all".
6. **The gate on circuit's cost over the raw server**, from S2's G1–G6
   ([findings](research/s2-coroutine-cost.md#proposed-gate)):
   - **Its shape is the owner's, its numbers slice 4's.** S2's prototype
     numbers were provisional until slice 4 measured the real adapter;
     [ADR-0007](decisions/0007-the-cost-gates-final-numbers.md) records the
     final ones, which the owner accepted on 2026-10-26.
   - **Four gates fail the build**, each the part circuit controls:
     - G3, circuit's own work over the server's `awaiting` path: at most
       384 B a GET and 352 B a POST (S2's prototype: 285–290 B and, on
       the interim's POST, 447–452 B against a proposed 512);
     - G4, one `req-set` measured on its own: at most 88 B, and 440 B for
       five (S2 proposed 96 B; 80 by five over five);
     - G5, the catch helper over the unwrapped app, with nothing raised: at
       most 512 B, held both with the app waiting inside it and without
       (309–365 B by `call/cc`). A `call/1cc` escape passes without a wait
       at 50 connections (407–410 B) and fails with one (3.4 KB);
     - G7, a 6-byte bytevector port body over the same bytes as a
       bytevector, through the adapter, the port made per request: at most
       384 B (§15.12).
   - **Two are printed, not held.** G1 and G2, a GET and a POST through the
     adapter over raw, at most 1,536 B each (S2 proposed 3,072 B for G2,
     on the interim's POST), include the server's own coroutines, so they
     are printed for context and re-baselined at each move of the server's
     pin.
   - **The POST is pulled** (slice 4): the app reads its 13-byte body by
     `get-bytevector-n` of its declared length, the cheapest read (§4),
     and costs about what a GET does over raw.
   - **Requests a second are a smoke.** G6, a GET through the adapter at
     ≥ 90% of raw's rate at 50 connections (93.0–95.1% on a quiet rerun),
     is printed and never fails CI. It is run locally before a release.
   - **`make gate` runs it, outside `make test`**, with its counts fixed:
     5,000 against 25,000 requests, two rounds, at 1 and 50 connections.
     A gate's worst figure moves by about 10 B from run to run, and by up
     to 25 B where the app parks (slice 4). CI runs it as a step of its
     own: noise moves a byte count far less than a rate.
   - **`make oha` fetches oha** through the vendored server's
     `tests/fetch-oha.sh`, which pins its version and sha256, on the host
     and in CI. The container has no network.
   - **Slice 3 built it** (2026-10-26). `tests/gate.sps` measures a
     stand-in adapter over the real core, and a stand-in catch helper by
     `call/cc`, until slices 4 and 5 bring the real ones. It runs in about
     30 s. The held gates' worst figures in four runs of the final
     program, the builder's, the session's and the reviewer's two: G3
     291–294 B a GET and 272–276 B a POST, G4 80–81 B, G5 343–345 B and
     328–332 B with a park. G1 reads 1,422–1,428 B. G2 reads 9,544–9,549
     B, over its
     proposed 3,072, printed and not held: the pulled POST reads its body
     with `get-bytevector-all`, 8.2 KB of Chez's (§4). G6 read 93.4–95.7%
     at 50 connections. Each held gate was watched failing: a `make-req`
     that copies the view (G3, 423 B), a request record of eight fields
     (G4, 113 B), and a `call/1cc` catch helper (G5, 853 B, and 3,523 B
     with a park).
   - **Slice 4 moved it onto the real adapter** (2026-10-26):
     `circuit->handler`, its environment answering `#f` for every name.
     Eight runs, six by the gate's builder and two by the session, read
     G1 1,439–1,447 B, G2 1,433–1,443 B, G3 305–311 B a GET and 273–280
     B a POST, G4 80–81 B and 400–406 B for five, and G5 364–374 B and
     319–343 B with a park. G6 read 93.9–95.5% at 50 connections, on a
     shared machine. Each held gate was watched failing: a view made per
     request (G3, 419–425 B a GET and 384–385 B a POST), a six-field
     request record (G4, 97 B), and a `call/1cc` catch helper (G5, 849
     B, and 3,657 B with a park).
   - **G4's bound is off a record's size step.** Chez sizes a record in
     16 B steps, so a `req-set` costs 80 B at four or five fields and 96 B
     at six, where 1 B of noise failed the old 96 B bound (97 B). Slice 4
     set it at 88 B, between the steps.
   - **G7 holds a port body** (§15.12). Streamed, a 6-byte bytevector
     port cost 5,096–5,103 B a request over the same bytes as a
     bytevector (slice 4, outside the gate): about 3 KB the server's
     sized producer from `awaiting`, about 1 KB its running of the
     `request-on-done!` procedure, and about 1,040 B `res-body-stream`'s
     two `guard`s. Read whole (§5), with one `with-exception-handler` for
     the guards, it reads 300–310 B. G7 was watched failing on the
     streamed code (5,098 B) and with the `guard`s back (658 B).
   - **What the gate doesn't hold.** A port of more than one piece, which
     streams, and a sized body. G5 holds the stand-in catch helper, which
     no change under `src/` moves until slice 5. Per-connection costs
     cancel under keep-alive, so the gate doesn't see them.

The owner's answers once the asks had landed (2026-10-26):

7. **The pin waits for v0.9.0's tag.** ADR-0003 holds: circuit pins the
   server at a release tag. The design is written against the server's
   main at 9195305, and the pin moves from v0.8.0 to v0.9.0 in one commit
   before slice 4 builds the adapter. Slice 3, the pure core, needs no
   server. Weighed: pinning main's 9195305 now, with ADR-0003 amended to
   allow an untagged commit until the next tag. **Done 2026-10-26:** the
   server tagged v0.9.0 that day, at d928e41, its `src/` and `docs/`
   those of 9195305, and the pin moved to it, with every pin it carries
   unchanged.
8. **A streamed body declares its length with a body kind, and the
   adapter sizes a port body Chez knows the length of** (§5).
   `(make-sized-body n body)` takes a producer or a port. A file or
   bytevector port needs no call: the adapter reads its length with Chez's
   `port-has-port-length?` and `port-length`, which slice 4 adds to the
   audit's allowlist. Weighed: the body kind alone, which sends a file
   chunked unless the app sizes it; and a `content-length` header read as
   the length and stripped, Ring's way, which rewrites the head (§14).
9. **The catch helper answers `&body-failed` with its status** (§6).
   Weighed: re-raising it, as the close and the deadline are (§14).

The owner's answers after the revision's second review (2026-10-26):

10. **A view must supply `method`, `host`, `path` and `http-version`**
    (§3), whose accessors' types have no `#f`. The rest may be `#f`.
    Weighed: widening those four types to allow `#f`, which every caller
    would then check.
11. **Slice 3 builds `res-wrap-body` as provisional** (§16.4, §17), so the
    core isn't held up by its shape. Weighed: slice 3 waiting for the
    answer.

The owner's answers in slice 4 (2026-10-26):

12. **A port body of a piece or less is read whole** (§5), and a held
    gate, G7, holds its cost (§15.6, ADR-0007). A 6-byte port body cost
    about 5.1 KB a request over a bytevector streamed, and costs about
    300 B read whole. Weighed: keeping every port streamed, with
    `res-body-stream`'s close on a raise made cheaper alone, which saved
    about 634 B.

## 16. Open

1. **A cap of circuit's own on the request body.** This draft has none
   (§4, §14). The server's `CHEZ_HTTP_MAX_BODY_BYTES` is unbounded by
   default, so an app that reads a body whole runs without a bound unless
   its deployer sets one. A per-route cap would be middleware's. The pull
   fixes its cap at the first read, so such middleware would set the cap
   on the request, and `req-body` would make its port with it.
2. **A clock for request logging** (slice 5). R6RS has none, and the
   server's facade exports none. The server's own clock, the one its waits
   and its test host use, is the one to read, so a test's advance would
   drive it. That is likely an ask on the server.
3. **A response can't stream the request's body back** (§4): only the
   `awaiting` thunk may pull. An echo or a proxy that streams both ways at
   once would need the server to let a producer pull. That would be an
   ask, if a use comes.
4. **`res-wrap-body`'s shape** (§6). It replaces `res-body->producer`
   after the 2026-10-26 review found that a port wrapped in the core
   leaked and lost its length (§14). The shape is this revision's answer
   and awaits the owner: a lazy wrap the adapter runs, and a flag for a
   wrap that keeps the bytes. Slice 3 builds it as provisional (§15.11),
   and changes it if the owner's answer on the shape differs.
## 17. Slices

1. Scaffolding: Makefile with `help`, the server pinned under `vendor/`, CI
   on Linux, `CHANGELOG.md`, the ledger and `global-constraints.md`, and the
   decision records this design settles.
2. Spikes S1 and S2.
3. The pure core: `req` with every accessor in §3 and its view, `res`
   with every body kind in §5 but the upgrade, `make-sized-body`,
   `res-wrap-body` (provisional, §16.4) and `res-body-length` among them,
   headers, keys, `make-test-req` and `test-req-done!`, the exports the
   adapter and the tests need (§11), `wrap`, and the suites that hold the
   names apart and `wrap`'s order. With it, `make oha`, and `make
   gate` holding the provisional numbers (§15.6).
4. The adapter, on the pin at v0.9.0 (moved 2026-10-26, §15.7), with the
   pulled body, every body kind but the upgrade, port bodies sized and
   closed by `request-on-done!`, wrapped or not, ADR-0006's allowlist
   amended for `port-has-port-length?` and `port-length`, and examples
   run over loopback: hello, echo, a stream, a long poll. The gate's final
   numbers, from the real adapter, in a decision record (§15.6).
5. `(circuit middleware waits)`: the catch helper and `wrap-timeout`,
   through `(http-server testing)`; request logging on `req-on-done!`.
6. Upgrades; then the router and WebSocket, each its own library.
