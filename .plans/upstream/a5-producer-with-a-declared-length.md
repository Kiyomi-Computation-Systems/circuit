Title: A producer body with a declared length
Filed: chez-http-server #216, 2026-10-25

**The problem**

A body is a bytevector, whose length the server counts, or a producer, whose
length it doesn't know: at v0.8.0 (a996eef) a producer goes chunked to
HTTP/1.1 and close-delimited to 1.0 (`response-framing`,
`src/http-server/decisions.sls:146`), and a handler's own `Content-Length` is
a `framing-field` fault, answered 500 (`serializer.sls:457`).

So a body whose length is known but which shouldn't be held whole in memory,
a file, can't be sent with its length:

- the client gets no size: no download progress, no way to tell a cut-off
  body from a whole one but the chunked framing;
- a HEAD can't announce the length a GET would send: a producer's HEAD is
  answered with no `Content-Length` (`decisions.sls:155`);
- an HTTP/1.0 client loses keep-alive, since a close-delimited body ends
  with the connection;
- a range response, later, needs a known length.

circuit, a Ring-like layer over the server, lets an app answer with a file's
port, which it streams as a producer. It goes chunked today.

**What you propose**

A body made of a length and a producer, for example
`(sized-body n producer)` from `(http-server response)`, whose type
`make-response` accepts beside the two it takes now:

- `response-framing` gets `n` as the length, so the response is
  `content-length`, and a HEAD's is `content-length-only`, the producer
  never called;
- the producer is called as now: below the write high water, on a coroutine
  for a handler that waits;
- its pieces are written as they come, unframed: `serialize-piece`
  (`serializer.sls:277`) refuses `content-length` mode today;
- the core counts the bytes. The head is on the wire by then, so a producer
  that gives more than `n`, or the eof object short of `n`, can't be
  answered otherwise: the server writes no more than `n`, closes the
  connection, and logs it, as it does for a producer that raises after the
  head;
- `n` of 0 is an empty body, and the producer isn't called.

**What the RFCs say**

RFC 9110 §8.6 and RFC 9112 §6.2 (Content-Length); §6.3 of RFC 9112 for how a
client reads the length, and §8 for a message that ends short of it, which
is why a short producer must close the connection rather than leave it open.
This changes what the server writes, not what it accepts.

**Meanwhile**

circuit sends such bodies chunked. Nothing to probe: the ask adds a body
type, and circuit moves to it once a release has it.
