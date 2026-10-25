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
  reads may all wait. No option calls an app in place; S2 measures the cost
  (§13, §15).
- **Waiting is ambient inside the handler call**, as blocking I/O is in
  Ring and Rack. Circuit defines no async primitive. Handlers wait with the
  server's verbs, and middleware is oblivious: `(handler req)` may park
  inside and returns when it is done.
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
  conses one pair, so a stack of n middlewares that each set a key costs
  n record copies and n pairs. S2 measures a stack of five.
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
- A read is a wait, so it raises `&client-closed` when the client leaves
  and `&deadline-passed` inside a `with-deadline` that has passed. Chez's
  `get-bytevector-n` gathers large reads block by block before returning,
  so a raise from a later block loses the bytes already taken off the
  port. A body reader that must resume after a raise reads with
  `get-bytevector-some`.

**Until A4 lands**, the adapter answers `read-whole-body` with a cap, 1 MiB
unless `CIRCUIT_MAX_BODY_BYTES` says otherwise, and hands the app a
bytevector input port over the result. App code is the same either way.
What the interim loses: a body under the cap is read whole before the app
runs, so a client that sent `Expect: 100-continue` is told to send it even
when the app would have refused; a declared length over the cap, or over
`CHEZ_HTTP_MAX_BODY_BYTES`, is a 413 from the server with no `100`, and a
chunked body gets its 413 at the piece that passes the cap.

The adapter answers a reader **only when the head announces a body**, a
`Content-Length` above 0 or a `Transfer-Encoding`. Otherwise it calls the
app in the thunk itself. An upgrade request has no body, so it never goes
through a reader (§8), and a bodiless request costs one coroutine, not two
(S2 counts both paths).

Spike S1 checks that a custom port's read procedure can park on the
server's coroutine. If it can't, the body is a source read by
`(body-read source)`, with helpers that do what the port procedures do.

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
- **Catch with an escape, not `guard`.** On a coroutine `guard` costs
  about twice what the server's own exception handler does (about 1.3 KB
  against 0.65 KB). The cheap escape is Chez's `call/1cc`; a portable
  `call/cc` on a coroutine captures the full continuation and costs what
  `guard` does. Circuit's catch helper uses `call/1cc` and is the one
  Chez-only piece in its middleware (§11); S2 measures it.
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
  `(http-server)` (§11). A handler wrapped in them can't be called
  directly in a test; they are tested through the fake shell (§10).

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

- `(circuit->handler app [env])` gives a server handler. For a request
  with no body it answers `(awaiting thunk)`, and the thunk builds the
  request, calls `app`, and turns the response into the server's answer.
  For a request with a body it answers `read-whole-body` (§4), and the app
  runs in the reader's end, which the server calls on a coroutine too.
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
- **A handler that waits**, or one wrapped in `wrap-timeout` or the catch
  helper, needs a host where waits work. The server has one,
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
impure libraries import `(http-server)`; the catch helper's `call/1cc` is
Chez-only, and lives in `(circuit middleware waits)` with it.
chez-http-server is a pinned submodule under `vendor/`, as it is in
chez-websocket, and an Akku dependency.

## 12. Upstream asks (drafts, not filed)

On chez-http-server, in the table form of its decision 0008. Each
workaround carries a probe that goes red when its ask lands, and one that
goes red when the library it reaches into changes shape: `(http-server
request)`, `(http-server span)` and `(http-server headers)` are installed
and importable, but `docs/reference.md` documents only the facade, so
nothing holds them stable between releases. The names in this table are
the server's.

| # | Ask | Unblocks | Workaround |
|:--|:--|:--|:--|
| A1 | `request-header-list : Request -> (Listof (Pair String String))`: every header as strings, names as sent, values as `request-header` gives them, wire order. Not `request-headers`: `(http-server request)` exports that name with the span type | `req-headers`; logging, proxying | read the spans from `(http-server request)` with `(http-server span)`, trimmed as `(http-server headers)` trims, imported with `only` |
| A2 | the HTTP version in the facade | `req-http-version` | `request-http-major` and `-minor` from `(http-server request)` |
| A3 | the peer's and the local address of the connection a request came on | `req-remote-address`; trusting `X-Forwarded-For` only from your own proxy, which the server's deploying guide advises and which needs the peer's address | none: `#f`. It reverses a choice the server made on purpose, so it needs the argument made |
| A4 | a waiting handler reads its body by waiting: a verb that gives the next piece (a copy) or eof, usable before the handler has answered and refused after; sends `100 Continue` at the first call, after the declared-length check against the caps (a 413 comes with no `100`); reads on credit; takes an optional cap of its own; and an answer before the body's end closes the connection after the response, as an unread body does today. Today an answer that arrives while a streaming reader is mid-body is dropped, so this is a new core path | §4's port with backpressure; refusing a body before reading it | `read-whole-body`, capped |
| A5 | a producer with a declared length: the server writes `Content-Length` and closes on a producer that gives more or less | files with a length, HEAD on files, ranges later | chunked |
| A6 | a call once a response is done, saying how: sent, the client left, a write failed | §7's moment 3; closing a port body when the client leaves | moments 1 and 2 only; a port whose client left is never closed by the adapter |
| A7 | ship the fake shell as a supported library: run a handler, its waits included, against scripted requests and a fake clock | testing handlers that wait, and the adapter, with no socket | reach into `vendor/chez-http-server/tests/` |

A1, A2 and A4 matter most: A1 and A2 have workarounds, while A4 changes
what circuit can be. A3 needs a decision on the server's side before it is
filed.

## 13. Spikes before the decision records

- **S1, a port that waits.** A custom binary input port whose read
  procedure calls `await`, read with `get-bytevector-n` across several parks
  under the real server. Also: `with-deadline` around the reads;
  `&client-closed` raised from inside the read procedure and out of
  `get-bytevector-n`; two coroutines parked in two ports at once; and a
  raise after a partial `get-bytevector-n` followed by another read, to
  see what the port has lost. This decides §4's interface. It can run
  today, with a second request resuming the first.
- **S2, the cost of a coroutine for every request.** A hello-world GET,
  measured raw, under `awaiting`, and a POST under `awaiting` with
  `read-whole-body`, so both of §4's paths are counted: bytes a request
  with the allocation probe the server's spikes use (the server's
  `.plans/research/spike/hoist-request-alloc.sps`), and requests a second
  with oha. Also measured: a stack of five middlewares that each `req-set`
  a key, and the catch helper against `guard`. The server weighed the
  coroutine's cost in its decision 0014 and kept handlers in place by
  default. Circuit runs every request on a coroutine whatever the number
  (§15), so S2 doesn't decide that. It records the cost and sets the gate
  on circuit's cost over the raw server.

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
   an app in place. S2 measures what that costs, and its number sets the
   gate on circuit's cost over the raw server (§13).
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
5. **A1 asks for `request-header-list`**, the third of the family
   `request-header`, `request-header-values`, `request-header-list`.
   Weighed: `request-fields`, RFC 9110's term but a stranger beside the
   others; `request-headers*`, whose star says "variant", not "all".

## 16. Open

1. **A7's shape**: what the fake shell's supported surface should be.

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
