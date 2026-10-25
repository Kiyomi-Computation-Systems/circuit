Title: Tell the handler when its response is done, and how it ended
Filed: chez-http-server #217, 2026-10-25

**The problem**

A handler learns nothing after it answers. With a producer, the last call it
sees is the one that returns the eof object, which is not the last byte
reaching the client. And when the client leaves mid-stream the server makes
no more calls (decision 0015, item 4), so a producer that holds something, a
file's port, never learns to let it go: nothing closes the port.

Logging and metrics want the moment the response was sent, or wasn't. Rack 3
gives it as `rack.response_finished`. circuit, a Ring-like layer over the
server, wants it for that middleware, and to close a port body when its
client leaves.

The core has the moment already: `response-written`
(`src/http-server/connection.sls:998`, at v0.8.0, a996eef) runs once every
write of a response has completed. The ways a response ends short of that,
the client's close and reset, a read error, the write deadline, run through
the core's close paths.

**What you propose**

A way for handler code to register a procedure the server calls once, when
the request's response is done, with how it ended. One shape, request-scoped
as Rack's is, so middleware can register whatever response it ends up
returning:

    (request-on-done! request proc)    ; proc : Symbol -> Any

with `proc` called with one of:

- `written`: every write of the response completed;
- `client-closed`: the client closed or reset the connection first;
- `failed`: a write failed, the write deadline passed, or the handler, its
  reader or its producer raised (the server answered 500, or closed after
  the head).

The details are the server's to decide. Some that matter to a caller:

- whether it may be registered from a reader or a producer as well as the
  handler;
- that it is called in place, from the shell, so it must be quick and
  cannot wait, as a transport's callbacks are; and that a raise from it is
  logged and changes nothing;
- that, on a kept-alive connection, it is called before the next request's
  handler.

A field on the response, an optional fifth argument to `make-response`,
would work too. But a middleware that replaces a response would drop the one
it was handed.

**What the RFCs say**

Nothing on the wire changes.

**Meanwhile**

circuit can report that the handler returned and that a producer reached its
eof, and no more. A port body whose client leaves mid-stream stays open.
