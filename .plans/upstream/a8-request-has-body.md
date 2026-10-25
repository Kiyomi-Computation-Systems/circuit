Title: Say whether a request has a body: request-has-body?
Drafted: 2026-10-25, not filed

**The problem**

The server decides at the head whether a body follows: one that is
chunked, or that has a Content-Length above 0 (`framed?` in
`conn-headers-complete-step`, `src/http-server/connection.sls:1768`, at
v0.8.0, a996eef). It acts on that decision:
- a response answered for a request with a body closes the connection
  after it (`'unread-body`);
- a reader answered for a request with none gets its end at once.

The facade doesn't expose the decision. A handler that answers a reader only
when there is a body must copy the rule from the headers, reading
`request-header` for `transfer-encoding` and every `request-header-values`
for `content-length`. Such a handler might want to save a reader's
coroutines, or answer a bodiless request in place.

- **The copy drifts from the rule.** The server reads `Content-Length: 00`
  as no body. A request with it, answered by `examples/hello.sps`, is kept
  alive, as one with `0` is, while one with `1` is closed after the
  response. A copy that tests for the string `"0"` takes `00` for a body.
- **The copy costs.** Each lookup turns the name into bytes
  (`request-header`, `src/http-server/view.sls:85`, and
  `request-header-values`, `:94`), so the two lookups allocate 64 B a
  request, two 32 B bytevectors, on a request that has neither field.

circuit, a Ring-like layer over the server, answers `awaiting` for every
request. Its thunk answers a reader only when the head announces a body,
and calls the app itself otherwise. A reader answered for a bodiless
request costs a second coroutine.

**What you propose**

`request-has-body? : Request -> Boolean`, exported by the facade: the
server's own decision, `#t` when the request's framing announces a body,
chunked or a Content-Length above 0, and `#f` otherwise. A row in
`docs/handlers.md`'s table and in `docs/reference.md`.

The core knows the answer when it builds the request: the record is made at
`connection.sls:1760`, and `framed?` is decided a few lines on, at `:1768`.
The record's Body field is built `#f` for every request
(`src/http-server/request.sls:23`), so the answer could be recorded there,
or in a field of its own. Either way it is made once, and asking costs
nothing.

**What the RFCs say**

No wire change. RFC 9112 §6.3 sets how a request's body length is found; a
request with neither field has no body.

**Meanwhile**

circuit judges from the headers, leaning towards a reader: it answers one
when there is a `Transfer-Encoding` field, or a `Content-Length` that reads
anything but `0`. A wrong guess one way costs a coroutine; the other way it
would hand the app an empty body and close the connection, so circuit
leans towards the reader.
