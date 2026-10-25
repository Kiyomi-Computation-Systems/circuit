# Circuit design: Ring on chez-http-server's coroutines

Date: 2026-10-24, revised 2026-10-25 after review
Status: draft, for discussion; §15 records the owner's decisions so far, §16 what is open
Builds on: [circuit-ringlike-http-layer.md](circuit-ringlike-http-layer.md) (the overview)

## 1. What changed since the overview

The overview was written before chez-http-server existed, and deferred
streaming, async, cancellation and upgrades until the lower layers did.
They exist now (v0.8.0), and the server has answered most of the overview's
§28:

| Overview's open question | The server's answer |
|:--|:--|
| streaming responses, backpressure | a body may be a producer, `(-> (U Bytevector Eof))`, called only while the client keeps up (256 KiB high, 64 KiB low water; 64 and 16 pieces) |
| streaming request bodies | `(read-body on-piece on-end)`, handed the pieces on credit when the handler waits |
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
- **The body is outside the handler call.** The server calls a response's
  producer on a fresh coroutine for each piece, after the handler has
  returned. A producer may wait, but it runs outside every middleware's
  dynamic extent: no `with-exception-handler`, `with-deadline` or
  `parameterize` around the handler reaches it (§5, §6).
- **One async model** (the overview's principle 14): the server's waits.
  No callbacks, futures or answer sum in circuit's API. The server's
  `Answer = Response | BodyReader | Awaiting | Switch` lives only in the
  adapter.

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

| Accessor | Type | From the server | Today |
|:--|:--|:--|:--|
| `req-method` | `Req -> Symbol` | `request-method`, `'GET` | yes |
| `req-scheme` | `Req -> Symbol` | none: always `'http` (no TLS) | constant |
| `req-host` | `Req -> String` | `request-host` | yes |
| `req-path` | `Req -> String` | `request-path`, undecoded | yes |
| `req-query` | `Req -> (U String #f)` | `request-query` | yes |
| `req-http-version` | `Req -> (Pair Nat Nat)` | in the record, not the facade | workaround (A2) |
| `req-header` | `Req String -> (U String #f)` | `request-header`, any case | yes |
| `req-header-values` | `Req String -> (Listof String)` | `request-header-values` | yes |
| `req-headers` | `Req -> (Listof (Pair String String))` | no way to list them | workaround (A1) |
| `req-body` | `Req -> BinaryInputPort` | §4 | interim (A4) |
| `req-remote-address` | `Req -> (U String #f)` | not exposed, on purpose | `#f` (A3) |

- `req-headers` gives names in lower case, in wire order, duplicates
  kept. `req-header` matches any case and reads the first.
- **The view** is a record of procedures: one per row above that the host
  supplies (`method`, `host`, `path`, `query`, `http-version`, `header`,
  `header-values`, `headers`, `remote-address`), each taking the host's
  request. The adapter's view wraps the server's accessors; a test
  request's view reads a plain alist. A view that leaves a procedure `#f`
  makes that accessor answer `#f` or `'()`.
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
  `req-with-path`, `req-with-method` and so on, each giving a new request
  whose view answers the new value for that field.

## 4. The request body: a port that waits

`(req-body req)` is a binary input port. Ring's body is an `InputStream`
and Rack's a `rack.input`; this is the same thing, except that a read that
must wait for the client parks the coroutine.

- Read it with the standard procedures: `get-bytevector-all`,
  `get-bytevector-n`, `get-bytevector-some`, or a parser that reads ports.
- A request with no body reads eof at once.
- Once A4 lands, the body is read **only as the app reads it**: the server
  sends `100 Continue` at the first read and reads from the socket on
  credit, so a slow consumer stops the reads. An app that answers without
  reading, such as a 401 to an upload, never takes the body in; the server
  closes the connection after that response, as it does today for an
  unread body.

Once A4 lands, a read that must wait parks. S1 showed the first, second,
fourth and fifth of these under the server, and the third is what A4 must
add:

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
  holds: circuit's port must keep to that. A text port loses data even
  through `get-string-some` when a piece ends inside a character: its
  decoder drops what it had decoded in that call. So after a raise out of
  a body read, treat the body as gone: answer, or raise on. A reader that
  must go on reads with `get-bytevector-some` and decodes the bytes
  itself.
- **After the close, every read must raise** instead of waiting for bytes
  that can't come. A4 must make the close stick: S1 saw today's waits do
  the opposite, a wait after a caught close parking again.
- **A park leaves every `dynamic-wind` around the read** and re-enters it at
  the resume: the after thunk runs at each park, the before thunk at each
  resume (§6).
- **Text reads read ahead.** A UTF-8 `transcoded-port` takes up to 1 KiB at
  a time, and finishes a character split between pieces before it returns,
  so `get-line` can wait for more of the body than its line. A body the
  client sends whole doesn't notice.

**Until A4 lands**, the adapter answers `read-whole-body` with a cap, 1 MiB
unless `CIRCUIT_MAX_BODY_BYTES` says otherwise, and hands the app a
bytevector input port over the result. App code is the same either way.
What the interim loses: a body under the cap is read whole before the app
runs, so a client that sent `Expect: 100-continue` is told to send it even
when the app would have refused; a declared length over the cap, or over
`CHEZ_HTTP_MAX_BODY_BYTES`, is a 413 from the server with no `100`, and a
chunked body gets its 413 at the piece that passes the cap.

The adapter's thunk answers a reader **only when the head announces a
body**. Otherwise it calls the app itself. An upgrade request has no body,
so it never goes through a reader (§8), and a bodiless request costs one
coroutine. The server calls a reader's pieces and its end each on a
coroutine of its own, and hands a whole reader its body as its only piece,
however it arrived (`hand-over-whole`, `connection.sls:1475`). So the
interim's `read-whole-body` costs three coroutines for a body and two for
an empty one, and a reader answered for a request with no body costs two
(S2). A streaming reader would cost one for each piece, and one for its
end.

Whether a request has a body is the server's decision, and the facade
doesn't say; A8 asks it to. Until then the adapter judges from the
headers, and leans towards a reader, because its two mistakes cost
different amounts. A reader for a request with no body gets its end at
once, and costs a coroutine. No reader for a request with a body hands the
app an empty body, and the server closes the connection after the
response. So the adapter answers a reader when there is a
`Transfer-Encoding` field, or a `Content-Length` field whose value is
anything but `0`. It calls the app directly only when neither is there, or
every `Content-Length` reads `0`. By then the server has refused a
malformed length, and any coding before `chunked`. The judgement's two
lookups allocate 64 B a request, the two names turned into bytes on every
lookup (`view.sls:85`, `:94`), which A8 would save. In the server, the
prototype with the judgement costs 137–153 B more than one without (S2,
its rerun and its review). The rest most likely comes with the adapter's
two paths, which an adapter that asks A8's `request-has-body?` keeps. The
server's rule and a copy of it differ at the edges: it reads
`Content-Length: 00` as no body, where this one answers a reader.

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
     | BinaryInputPort             streamed, closed at its eof or when not sent
     | Upgrade                     §8; status 101
```

- **Headers** are a list of `(name . value)` string pairs, in order, with
  duplicates kept (`set-cookie`). Lookups match any case. The helpers write
  names in lower case. The constructor rewrites nothing. The adapter
  encodes names and values as Latin-1, one byte per character, as the
  server reads request headers; a character above 255 is an assertion
  violation in the adapter, which the server answers 500. Bodies are
  UTF-8, headers Latin-1: a header that must carry non-Latin-1 text
  encodes it itself (RFC 8187).
- **Accessors**: `res-status`, `res-headers`, `res-body`, and `res?`.
- **Helpers**, each giving a new response: `res-header` (look one up),
  `res-set-header` (replace), `res-add-header` (append), `res-with-status`,
  `res-with-body`. `res-with-body` over a port body closes the old port.
  `res-with-status` on an upgrade response, or a 1xx status on any other,
  is an assertion violation: the server refuses both.
- **A producer runs on a coroutine of its own for each piece**, after the
  handler has returned, so it may wait, but no middleware's dynamic extent
  covers it (§2). An SSE body is a producer that waits for the next event
  and returns it encoded. The server's rules bind it: a piece is a
  bytevector of one byte or more, never empty; the eof object ends the
  body; a raise after the head is on the wire closes the connection with
  nothing more said, logged `handler-failed`.
- **A port body** is read by a producer the adapter makes, in pieces of
  `CIRCUIT_PORT_PIECE_BYTES`, 64 KiB by default, with `get-bytevector-n`:
  one coroutine per piece, so bigger pieces cost less. A port whose reads
  block, a pipe or a socket, blocks the loop; a port body is a file, a
  bytevector port or a custom port that waits. The adapter closes the port
  at its eof, and **before answering when no body will be sent**: a HEAD, a
  204, a 304, or a 2xx to a CONNECT, where the server never calls the
  producer. It still can't close the port when the client leaves
  mid-stream (§7, A6).
- A port's body is chunked until A5 lands, so a file goes out without a
  `Content-Length`.
- What the server refuses (a `Content-Length` or `Transfer-Encoding`
  header, `Connection` other than `close`, control characters, a 1xx
  status) it still refuses: 500, logged. Circuit doesn't check these again,
  and middleware ported from Ring that sets `content-length` itself will
  meet that 500.
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
  and `docs/waiting.md`'s doesn't (§12).
- **Catch.** A raise that reaches the server is answered with an empty 500
  and `Connection: close`, so each failing request costs the client its
  connection: 7.2–8.3 KB a request, and under a third of the rate at 50
  connections (S2).
- **Don't free a resource in a `dynamic-wind` after thunk.** A park leaves
  every `dynamic-wind` around it and re-enters it at the resume (S1). The
  server's own `with-deadline` relies on it: its after thunk asks
  `coroutine-suspending?` to tell a park from a leaving
  (`private/waits.sls:385`). So an
  after thunk runs at every wait inside the handler, a body read included.
  Free the resource when the call returns, and on a raise with an exception
  handler that raises on.
- **A timeout is `with-deadline`.** `(wrap-timeout ms)` answers 504 when
  `&deadline-passed` reaches it. Once A4 lands, the deadline covers body
  reads too. It never covers a producer (§2), and it cuts nothing short
  that isn't waiting: CPU work and a blocking port read run on.
- **Streaming middleware wraps the body.** Compression or byte counting
  wraps the producer, or the port turned into one. Circuit gives
  `res-body->producer` so middleware handles one shape, and the wrapped
  producer keeps the server's rules: never an empty piece, so a compressor
  loops until it has bytes or reaches eof.
- **`wrap-timeout` and the catch helper need the server's verbs**
  (`with-deadline`, `deadline-passed?`, `client-closed?`), and
  `with-deadline` is refused off a coroutine. So they can't live in the
  pure core: they live in `(circuit middleware waits)`, which imports
  `(http-server)` (§11). A handler wrapped in `wrap-timeout` can't be
  called directly in a test, since `with-deadline` is refused off a
  coroutine; it is tested through the fake shell (§10). One wrapped only in
  the catch helper can be, when it doesn't wait: the helper is plain R6RS
  and needs only the two predicates.

## 7. When a response is done

Three moments, which the overview's principle 13 tells apart:

1. **The handler returned**: middleware sees this as the call returning.
2. **The body was produced**: the adapter sees the producer's eof.
3. **The response was sent**, or the client left, or a write failed: only
   the server knows. A6 asks it to say so.

Logging and metrics middleware want 3. A port body needs it too: when the
client leaves mid-stream, the server never calls the producer again, so the
adapter never sees the eof that closes the port. The API, likely
`(on-res-done req proc)` with the outcome, waits for A6. Until then
circuit offers 1 and 2.

## 8. Upgrades

`(make-upgrade-res headers take-over)` is a response with status 101 and
an `Upgrade` body holding `take-over`, a procedure of the host's transport
and the bytes read past the request. Middleware sees the status and the
headers, and passes it through. The adapter answers
`(switch-protocols headers take-over)` from the thunk, the path the server
tests; an upgrade request has no body, so it never reaches the reader path
(§4). The take-over may answer `awaiting`, as the server allows. The
server's rules still apply: an upgrade answered to a request that can't
take one is a 500.

WebSocket through circuit needs chez-websocket's handshake to work from a
circuit request. Today `websocket-accept` takes the server's request. That
belongs to the WebSocket slice, and may be an ask on chez-websocket.

## 9. The adapter

`(circuit http-server)` and `(circuit middleware waits)` are the only
libraries that import `(http-server)`.

- `(circuit->handler app [env])` gives a server handler, which answers
  `(awaiting thunk)` for every request. For a request with no body the
  thunk builds the request, calls `app`, and turns the response into the
  server's answer. For a request with a body the thunk answers
  `read-whole-body` (§4), and the app runs in the reader's end. The server
  calls a reader's end, and a response's producer, on a coroutine only for
  a handler that answered `awaiting`; a reader answered straight from the
  handler runs in place, where every wait is refused. So the reader always
  comes from the thunk.
- `(run-server app [env])` is `(http-server)`'s `serve` over
  `circuit->handler`, as Ring's adapters are `run-jetty` and friends.
- It re-exports the server's waits and their conditions (`await`,
  `sleep-ms`, `with-deadline`, `resolve`, `client-closed?` and the rest), so
  an app needs only `(circuit)` and `(circuit http-server)`. A re-export is
  the same binding, so a program that also imports `(http-server)` doesn't
  clash on them (R6RS §7.1).
- Settings come from the environment procedure, as the server's do
  (12-factor): `CIRCUIT_MAX_BODY_BYTES` while bodies are buffered,
  `CIRCUIT_PORT_PIECE_BYTES` for port bodies.

| Response body | Server answer |
|:--|:--|
| `#f`, bytevector | `(make-response status #f headers body)` |
| string | the same, with `(string->utf8 body)` |
| producer | the same, with the producer |
| port | a producer of `get-bytevector-n` that closes the port at eof; `#f`, port closed, when no body will be sent (§5) |
| upgrade | `(switch-protocols headers take-over)` |

## 10. Testing

- **A handler that doesn't wait** is called directly:
  `(app (make-test-req 'GET "/health"))`, with no server. Test requests
  take headers and a body (bytevector or string) and supply a view of their
  own (§3).
- **A handler that waits**, or one wrapped in `wrap-timeout`, needs a host
  where waits work; one wrapped only in the catch helper doesn't, unless
  it waits (§6). The server has one,
  `tests/fake-shell.sls`, with a fake clock and resolver, which
  chez-websocket's tests reach into. A7 asks to ship it as a supported
  library. Until then circuit's tests reach into the vendored server as
  chez-websocket's do, and an integration lane runs the adapter over
  loopback with curl.
- **Names don't clash, by test.** A suite imports `(http-server)`,
  `(circuit)` and `(circuit http-server)` together with no `only` or
  `rename`, so an export that clashes fails it (§15).
- **Order and shape, by test**: `wrap`'s order; a port closed on HEAD,
  204, 304; a non-`res` refused; the catch helper re-raising the two
  conditions.

## 11. Libraries

```text
(circuit)               facade: the core's exports
(circuit request)       the req record, view, keys
(circuit response)      the res record, body kinds, helpers
(circuit headers)       header lists: lookup, set, add
(circuit middleware)    wrap, res-body->producer, and the pure middleware
(circuit middleware waits)
                        wrap-timeout and the catch helper; imports (http-server)
(circuit test)          make-test-req, res-body->bytevector
(circuit http-server)   the adapter; imports (http-server)

later: (circuit router), (circuit websocket), middleware libraries
```

The core is plain R6RS and imports nothing of the server's. The two
impure libraries import `(http-server)`. The catch helper is plain R6RS,
and lives in `(circuit middleware waits)` because it needs the server's
`client-closed?` and `deadline-passed?`.
chez-http-server is a pinned submodule under `vendor/`, as it is in
chez-websocket. It isn't on the Akku index, so it can't be an Akku
dependency yet (ADR-0003).

## 12. Upstream asks

On chez-http-server, in the table form of its decision 0008. A1, A2, A5 and
A6 were filed on 2026-10-25, each linked in its row; the rest are drafts.
Each
workaround carries a probe that goes red when its ask lands, and one that
goes red when the library it reaches into changes shape: `(http-server
request)`, `(http-server span)` and `(http-server headers)` are installed
and importable, but `docs/reference.md` documents only the facade, so
nothing holds them stable between releases. The names in this table are
the server's.

| # | Ask | Unblocks | Workaround |
|:--|:--|:--|:--|
| A1, [#214](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/214) | `request-header-list : Request -> (Listof (Pair String String))`: every header as strings, names as sent, values as `request-header` gives them, wire order. Not `request-headers`: `(http-server request)` exports that name with the span type | `req-headers`; logging, proxying | read the spans from `(http-server request)` with `(http-server span)`, trimmed as `(http-server headers)` trims, imported with `only` |
| A2, [#215](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/215) | the HTTP version in the facade | `req-http-version` | `request-http-major` and `-minor` from `(http-server request)` |
| A3 | the peer's and the local address of the connection a request came on | `req-remote-address`; trusting `X-Forwarded-For` only from your own proxy, which the server's deploying guide advises and which needs the peer's address | none: `#f`. It reverses a choice the server made on purpose, so it needs the argument made |
| A4 | a waiting handler reads its body by waiting: a verb that gives the next piece (a copy, never empty) or eof, usable before the handler has answered and refused after; sends `100 Continue` at the first call, after the declared-length check against the caps (a 413 comes with no `100`); reads on credit; takes an optional cap of its own; and an answer before the body's end closes the connection after the response, as an unread body does today; once it has answered eof it answers eof, and once the client has closed or the body has failed it raises, on every later call and without waiting; it raises only before taking a piece, so a raise drops no bytes (S1). Today an answer that arrives while a streaming reader is mid-body is dropped, so this is a new core path | §4's port with backpressure; refusing a body before reading it | `read-whole-body`, capped |
| A5, [#216](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/216) | a producer with a declared length: the server writes `Content-Length` and closes on a producer that gives more or less | files with a length, HEAD on files, ranges later | chunked |
| A6, [#217](https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/217) | a call once a response is done, saying how: sent, the client left, a write failed | §7's moment 3; closing a port body when the client leaves | moments 1 and 2 only; a port whose client left is never closed by the adapter |
| A7 | ship the fake shell as a supported library: run a handler, its waits included, against scripted requests and a fake clock | testing handlers that wait, and the adapter, with no socket | reach into `vendor/chez-http-server/tests/` |
| A8 | `request-has-body? : Request -> Boolean`, the server's own decision that a request has a body: chunked, or a Content-Length above 0 | §4's choice of path without a copy of the server's rule | judge from the headers, leaning towards a reader (§4) |

A1, A2 and A4 matter most: A1 and A2 have workarounds, while A4 changes
what circuit can be. A3 needs a decision on the server's side before it is
filed. A8 is small, and its workaround errs only towards a spare coroutine.

Besides the asks, two fixes to the server's `docs/waiting.md`, both from
the spikes:

- **Its "Costs to know" is stale.** It says `guard` costs about 3.7 KB
  inside a handler that waits, and `with-exception-handler` next to
  nothing. The 3.7 KB is M7.1's 3,756 B a coroutine (decision 0015),
  measured before decision 0025 made the drain's continuation full.
  Through v0.8.0, S2 measured `guard` at 340–415 B with nothing raised and
  1.2–1.3 KB catching an `error`, which matches 0025's 1,238–1,304 B, and
  `with-exception-handler` alone at 150–180 B, or 300–320 B when the code
  parks inside it. An escape by `call/1cc`
  costs 3.4–4.3 KB once the code parks or Chez's `error` raises inside it,
  where one by `call/cc` costs 0.3–1.0 KB (§6).
- **It doesn't say that a park runs the after thunk of every
  `dynamic-wind` around the wait**, and the resume its before thunk (S1,
  §6).

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
- **S2, the cost of a coroutine for every request: done 2026-10-25**
  ([findings](research/s2-coroutine-cost.md)). Through server v0.8.0, with
  an adapter-shaped prototype:
  - a hello-world GET allocates 1,324–1,440 B a request more than the raw
    server, 1,036–1,154 B of it the coroutine, and answers 93–95% of
    raw's requests a second at 50 keep-alive connections;
  - a 13-byte POST read whole costs 2,863–2,951 B more, for three
    coroutines, at 91–94%;
  - five `req-set` middlewares add 383–409 B.

  The catch helper escapes by `call/cc`, not `call/1cc` (§6). Circuit runs
  every request on a coroutine whatever the number (§15), so S2 didn't
  decide that. The gate it proposes on circuit's cost over the raw server
  awaits the owner (§16).

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
  0025). A4 instead.
- **Buffering every body for good.** That is the interim, not the design.
- **A body source read by `(body-read source)`**, with helpers that do what
  the port procedures do: the fallback had a port's `read!` been unable to
  park. S1 showed it can (§4).
- **Names shared with the server's** (`make-response`, `request-path`),
  sorted out with `only` and `rename` imports. Set aside by the owner: an
  app that uses both libraries shouldn't need either.
- **A reader for every request**, upgrades included. The core accepts a
  switch from a reader's end, but the server's types exclude it and no
  test covers it; and it costs a second coroutine on every bodiless
  request. The adapter answers a reader only when the head announces a
  body (§4).

## 15. Decided

The owner's answers to this draft's open questions (2026-10-25):

1. **Middleware's data on a request goes under unique keys**, made by
   `make-req-key`, not symbols (§3).
2. **Every request runs on a coroutine.** The adapter has no option to call
   an app in place. S2 measured what that costs (§13), and the gate it
   proposes on circuit's cost over the raw server awaits the owner (§16).
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
   S2 has since moved the catch helper to `call/cc` (§6), so the second
   reason no longer holds for it: it needs only `client-closed?` and
   `deadline-passed?`. The decision stands until the owner revisits it
   (§16).
5. **A1 asks for `request-header-list`**, the third of the family
   `request-header`, `request-header-values`, `request-header-list`.
   Weighed: `request-fields`, RFC 9110's term but a stranger beside the
   others; `request-headers*`, whose star says "variant", not "all".

## 16. Open

1. **A7's shape**: what the fake shell's supported surface should be.
2. **The gate on circuit's cost over the raw server.** S2 proposes G1–G6
   ([findings](research/s2-coroutine-cost.md#proposed-gate)): bytes a
   request for a GET and a POST through the adapter, circuit's own share
   of them, a `req-set`, and the catch helper, each held by a suite; and
   the GET's requests a second at 50 connections, as a smoke. The owner
   decides. Before a suite can hold them:
   - G5 must name the case it holds. A `call/1cc` helper passes 512 B at
     50 connections with nothing raised and no park (407–410 B), and fails
     it only at 1 connection or once the app parks;
   - each gate must fix its request count and rounds. The method reads
     within 5 B at 25,000 requests, and within 30 B at 10,000, against
     headroom of 59–66 B on G3's POST;
   - G4's single `req-set` is five sets over five, not measured alone;
   - oha must come from circuit's own build: today only the server's
     `make oha` fetches it;
   - after the rerun the headroom is G1 96 B, G5 147 B and G6 3.0 points.
     G6's on a shared CI runner is unknown.
3. **Where the catch helper lives**, now that it needs no Chez (§15.4).

## 17. Slices

1. Scaffolding: Makefile with `help`, the server pinned under `vendor/`, CI
   on Linux, `CHANGELOG.md`, the ledger and `global-constraints.md`, and the
   decision records this design settles.
2. Spikes S1 and S2.
3. The pure core: `req`, `res`, headers, keys, `make-test-req`, `wrap`,
   and the suites that hold the names apart and `wrap`'s order.
4. The adapter with buffered bodies, every body kind but the upgrade, and
   examples run over loopback: hello, echo, a stream, a long poll.
5. `(circuit middleware waits)`: the catch helper and `wrap-timeout`,
   through the fake shell; request logging.
6. Each ask as it lands: the workaround dropped, its probe removed.
7. Upgrades; then the router and WebSocket, each its own library.
