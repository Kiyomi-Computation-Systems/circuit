# Ring-Like Application Layer for the Chez HTTP Stack

## Goal

Add a small, server-independent application interface above the HTTP connection/server layer.

The purpose of this layer is to define:

- what an HTTP request looks like to application code,
- what an application returns as an HTTP response,
- how middleware composes,
- how routers and frameworks can be built without depending on the underlying server,
- how synchronous, streaming, and asynchronous behavior should relate.

The conceptual model is inspired primarily by Clojure Ring and, more broadly, Ruby Rack.

The key abstraction is:

```text
Request → Response
```

with middleware as:

```text
Handler → Handler
```

This layer should not know about `libuv`, parser state machines, socket handles, or HTTP wire encoding.

---

## Position in the Stack

The full stack becomes:

```text
                    Application
                         │
                         ▼
                     Router
                         │
                         ▼
                    Middleware
                         │
                         ▼
              Ring-like web interface
                         │
                         ▼
                 HTTP server layer
                         │
              ┌──────────┴──────────┐
              │                     │
              ▼                     ▼
         HTTP/1 parser          libuv transport
              │
              ▼
      byte-machine generator
```

Or by responsibility:

```text
libuv
    transport / event loop / TCP

HTTP parser
    bytes → HTTP syntax/events

HTTP server
    connection lifecycle
    HTTP semantics
    buffering
    backpressure
    response serialization

Ring-like layer
    request/response application contract
    middleware contract

router/framework
    dispatch
    application conveniences

application
    business logic
```

The Ring-like layer is therefore an **application boundary**, not a transport or protocol implementation.

---

# 1. Core Handler Interface

The simplest useful handler is:

```scheme
Request -> Response
```

For example:

```scheme
(lambda (request)
  (make-response
    200
    '((content-type . "text/plain"))
    #"hello\n"))
```

A possible conceptual type:

```text
Handler = Request → Response
```

This gives the rest of the ecosystem a stable target.

A router is a handler.

A framework application is a handler.

Middleware accepts and returns handlers.

A test can invoke a handler directly without creating sockets.

---

# 2. Request Representation

The request object should represent an already-parsed HTTP request.

It should not expose:

- `uv_tcp_t`,
- parser state,
- socket buffers,
- parser callbacks,
- connection internals.

Possible fields:

```text
method
scheme
authority / host
path
query-string
HTTP version
headers
body
remote address
server address
application metadata
```

For example:

```scheme
(request-method req)
(request-path req)
(request-query-string req)
(request-headers req)
(request-body req)
(request-remote-address req)
```

The request representation should probably be a Chez record rather than a raw alist for the core API.

Reasons:

- predictable field access,
- clearer invariants,
- less allocation,
- easier extension,
- better distinction between server-managed and application-managed state.

A map/alist-like interface can still be provided where useful.

---

# 3. Response Representation

A basic response contains:

```text
status
headers
body
```

For example:

```scheme
(make-response
  200
  '((content-type . "text/plain"))
  #"hello")
```

A handler should not normally call:

```scheme
uv-write!
```

or:

```scheme
http-connection-write!
```

directly.

Instead:

```text
handler
   ↓
Response
   ↓
HTTP server
   ↓
response serializer
   ↓
libuv
```

This keeps application code independent of the server implementation.

---

# 4. Why This Layer Exists

Without a standard application boundary, server details tend to leak upward.

For example:

```scheme
(lambda (connection request)
  (http-connection-write!
    connection
    ...))
```

couples application handlers to one specific HTTP server.

A Ring-like interface instead allows:

```text
                ┌── libuv HTTP server
                │
application ◀───┼── test harness
                │
                └── future server implementation
```

The application only understands:

```text
Request → Response
```

This provides:

- server independence,
- direct unit testing,
- reusable middleware,
- reusable routers,
- framework interoperability,
- cleaner layering.

---

# 5. Middleware

Middleware is one of the main reasons to define this layer.

Conceptually:

```text
Middleware = Handler → Handler
```

For example:

```scheme
(define (wrap-request-logging handler)
  (lambda (request)
    (log-request request)
    (let ([response (handler request)])
      (log-response response)
      response)))
```

Then an application can be assembled through ordinary function composition:

```scheme
(define app
  (wrap-errors
    (wrap-request-id
      (wrap-authentication
        router))))
```

Useful middleware includes:

- request logging,
- request IDs,
- exception handling,
- authentication,
- authorization,
- cookies,
- sessions,
- CORS,
- compression,
- metrics,
- tracing,
- cache policy,
- static files.

These concerns do not belong in the HTTP parser or core server.

---

# 6. Routing

Routing should sit above the Ring-like interface.

A router is simply another handler:

```scheme
(define router
  (make-router
    (GET "/"
         home-handler)
    (GET "/users/:id"
         user-handler)
    (POST "/users"
          create-user-handler)))
```

Conceptually:

```text
Request
   ↓
Router
   ↓
selected Handler
   ↓
Response
```

The HTTP server should not need to know routing exists.

---

# 7. Testing Benefits

The handler abstraction makes most application code testable without networking.

For example:

```scheme
(define response
  (app
    (make-test-request
      #:method 'GET
      #:path "/health")))
```

Then assertions can inspect:

```scheme
(response-status response)
(response-headers response)
(response-body response)
```

This means:

```text
application tests
```

do not require:

```text
socket
libuv
HTTP parser
event loop
TCP port
```

Only integration tests need the complete stack.

---

# 8. The Important Design Problem: Streaming and Async

The clean synchronous abstraction:

```text
Request → Response
```

is extremely attractive.

However, the underlying system is asynchronous:

```text
libuv
  ↓
read callback
  ↓
HTTP parser
  ↓
connection state
  ↓
application
```

A production HTTP server may also need:

- streaming request bodies,
- streaming responses,
- asynchronous database/API operations,
- server-sent events,
- long-lived responses,
- WebSocket upgrades,
- backpressure.

The application abstraction must decide how much of this asynchronous reality is exposed.

There are several possible designs.

---

# 9. Option A: Pure Synchronous Ring Model

The simplest interface remains:

```text
Handler = Request → Response
```

Example:

```scheme
(lambda (request)
  (make-response
    200
    '((content-type . "application/json"))
    (encode-result ...)))
```

## Advantages

- extremely simple,
- natural Scheme programming model,
- trivial middleware,
- trivial testing,
- easy composition,
- easy router design,
- no continuation/callback machinery in normal handlers.

## Disadvantages

The server must buffer enough information to call the handler synchronously.

For request bodies this may imply:

```text
network
   ↓
buffer complete request body
   ↓
call handler
```

That is undesirable for:

- large uploads,
- streaming JSON,
- multipart uploads,
- proxying,
- unbounded request bodies.

Likewise, a response may need to exist completely before returning.

This makes:

- streaming files,
- SSE,
- long polling,
- large generated responses

less natural.

A synchronous API can still be useful as the default even if streaming is supported separately.

---

# 10. Option B: Callback-Based Async Handler

An asynchronous handler could look like:

```scheme
(lambda (request respond)
  ...
  (respond response))
```

Conceptually:

```text
Handler = Request × (Response → Void) → Void
```

This maps directly onto event-loop systems.

For example:

```scheme
(lambda (request respond)
  (database-query
    "..."
    (lambda (result)
      (respond
        (make-response
          200
          '()
          (encode-result result))))))
```

## Advantages

- naturally fits libuv,
- supports handlers completing later,
- no need to block the event loop,
- easy to connect to callback-based async APIs.

## Disadvantages

Middleware becomes more complicated.

Instead of:

```scheme
(let ([response (handler request)])
  ...)
```

middleware must intercept the response callback:

```scheme
(lambda (request respond)
  (handler
    request
    (lambda (response)
      ...
      (respond response))))
```

Errors, cancellation, and resource lifetime also become harder to reason about.

The simple mathematical elegance of Ring is weakened.

---

# 11. Option C: Promise/Future-Based Handler

Another possibility is:

```text
Request → Future<Response>
```

or:

```text
Request → Promise<Response>
```

This retains a mostly functional handler interface while allowing asynchronous completion.

Example conceptually:

```scheme
(lambda (request)
  (future-map
    (lambda (row)
      (make-response 200 '() (encode row)))
    (database-query-async ...)))
```

## Advantages

- preserves handler return-value semantics,
- middleware remains compositional,
- asynchronous work is explicit,
- easier error propagation than callback nesting.

## Disadvantages

Chez does not provide a universally established promise/event abstraction that naturally maps to libuv.

Introducing one would create another substantial library and policy decision.

It may also impose an abstraction that is unnecessary for the first version of the HTTP stack.

---

# 12. Option D: Separate Simple and Streaming Interfaces

A pragmatic approach is:

```text
ordinary handler:
    Request → Response
```

with explicit streaming representations for cases that need them.

For example:

```scheme
(make-response
  #:status 200
  #:headers ...
  #:body #"hello")
```

versus:

```scheme
(make-streaming-response
  #:status 200
  #:headers ...
  #:producer producer)
```

The handler itself still returns a response immediately.

The response body determines whether transmission is synchronous/buffered or streaming.

This keeps normal application code simple.

Conceptually:

```text
handler
   ↓
Response
   │
   ├── bytevector/string
   │
   ├── file
   │
   └── stream producer
```

The HTTP server then drives the producer according to socket availability and backpressure.

This is likely a good initial direction.

---

# 13. Streaming Response Body

A streaming response might expose something like:

```scheme
(make-streaming-body producer)
```

where `producer` interacts with a server-provided sink.

Conceptually:

```text
application producer
        ↓
     body chunks
        ↓
HTTP connection write queue
        ↓
      libuv
```

The critical requirement is backpressure.

The producer must not be allowed to emit unbounded data while the network is slow.

Possible conceptual protocol:

```text
producer
   ↓
send chunk
   ↓
server accepts / pauses
   ↓
resume callback when writable
```

The exact API should be designed only after the lower-level connection/write queue behavior is implemented.

---

# 14. Streaming Request Bodies

Request streaming is harder because the application may need to begin handling a request before the entire body arrives.

The simple model is:

```text
parse headers
   ↓
buffer body
   ↓
construct Request
   ↓
call handler
```

A streaming model instead becomes:

```text
parse headers
   ↓
construct Request with body stream
   ↓
call handler
   ↓
parser emits body chunks
   ↓
body consumer
```

Possible request body representations:

```text
bytevector
input-port-like object
stream object
callback consumer
```

The body abstraction must allow the HTTP server to stop libuv reads when the application is not consuming data fast enough.

Thus:

```text
request body consumer saturated
          ↓
      uv_read_stop()
          ↓
consumer ready
          ↓
     uv_read_start()
```

This connection between application body consumption and transport backpressure is the most important streaming design constraint.

---

# 15. Buffered vs Streaming Bodies

A useful future policy may be:

```text
small request body
    ↓
buffer automatically
    ↓
ordinary bytevector body

large/explicit streaming body
    ↓
stream abstraction
```

However, automatic switching can make the request type unpredictable.

Another approach is for the server/application configuration to choose explicitly:

```text
buffered request mode
streaming request mode
```

The first implementation should probably support buffered bodies with strict configurable size limits, then add streaming deliberately.

---

# 16. Async Does Not Necessarily Mean Threads

The underlying server can remain single-event-loop and asynchronous even if the application API looks synchronous.

The important distinction is:

```text
network concurrency
```

versus:

```text
handler execution model
```

libuv can manage many concurrent connections while each callback performs short synchronous Scheme computations.

Problems arise when a handler performs long-running or blocking work.

Therefore a simple first implementation can define:

> Handlers must not block the libuv event-loop thread.

Later, blocking work can be delegated to:

- worker threads,
- libuv's worker pool where appropriate,
- application-managed workers,
- asynchronous APIs.

---

# 17. Middleware and Streaming

Streaming complicates middleware because middleware can no longer assume that the complete body exists when the handler returns.

For ordinary responses:

```scheme
(lambda (request)
  (let ([response (handler request)])
    (add-header response ...)))
```

works naturally.

For streaming responses, middleware may need to wrap the body producer:

```text
Response
   ↓
middleware wraps stream
   ↓
chunks produced over time
```

Compression is a good example:

```text
application body stream
       ↓
gzip middleware
       ↓
compressed body stream
       ↓
server
```

Metrics middleware may need to observe completion asynchronously.

Logging middleware may want both:

```text
request received
response completed
```

rather than merely:

```text
handler returned
```

Therefore the response abstraction should eventually distinguish:

```text
handler completion
```

from:

```text
response transmission completion
```

---

# 18. Middleware and Async Handlers

If asynchronous handlers are introduced, middleware should still preserve one canonical transformation model.

For example, with callbacks:

```text
AsyncHandler =
    Request × Responder → Void

Middleware =
    AsyncHandler → AsyncHandler
```

With futures:

```text
AsyncHandler =
    Request → Future<Response>

Middleware =
    AsyncHandler → AsyncHandler
```

Both are viable.

Avoid supporting several competing async models simultaneously.

---

# 19. WebSockets and Protocol Upgrade

WebSockets do not fit naturally into:

```text
Request → Response
```

because after the upgrade, the connection ceases to behave like ordinary HTTP request/response traffic.

A future API may allow a special response:

```text
Response
  ├── normal-response
  └── protocol-upgrade
```

The upgrade response could hand control of the underlying connection to another protocol handler.

This should remain outside the initial Ring-like core.

The important architectural point is that the HTTP server—not middleware—owns the actual transport transition.

---

# 20. Server-Sent Events

SSE fits much more naturally than WebSockets.

It can be represented as an ordinary HTTP response with:

```text
Content-Type: text/event-stream
```

and a streaming body.

Therefore a good streaming response abstraction should support SSE without special protocol machinery.

---

# 21. Cancellation and Disconnects

Streaming and asynchronous handlers introduce another concern:

```text
client disconnects
```

The application may still be:

- producing response data,
- waiting for a database result,
- reading a request body.

Eventually the web layer should expose cancellation/lifecycle information.

For example:

```scheme
(request-cancellation-token request)
```

or:

```scheme
(on-disconnect request callback)
```

This should not be added prematurely, but the design should not assume that handlers always run to completion.

---

# 22. Recommended Initial Design

Start with the simple Ring model:

```text
Handler = Request → Response
Middleware = Handler → Handler
```

Support response bodies as a tagged abstraction rather than only raw bytevectors.

For example:

```text
ResponseBody =
    bytes
  | string
  | file
  | stream
```

Initially implement:

```text
bytes
string
```

possibly followed quickly by:

```text
file
```

Design the type so that:

```text
stream
```

can be added later without changing the handler contract.

For request bodies, begin with bounded buffering:

```text
Content-Length / chunked input
        ↓
configured maximum
        ↓
buffered bytevector
```

Then add streaming request bodies once:

- parser pause/resume,
- `uv_read_stop`,
- `uv_read_start`,
- connection backpressure,
- body lifetime

are well understood.

---

# 23. Why Preserve the Synchronous Handler Contract?

The synchronous Ring-style contract has major advantages:

```text
Request → Response
```

is:

- easy to understand,
- easy to compose,
- easy to test,
- natural in Scheme,
- independent of libuv,
- independent of threads,
- independent of promises,
- sufficient for a large percentage of HTTP handlers.

Streaming can often be expressed as a property of the response body rather than the handler invocation itself.

Therefore the first design should avoid exposing libuv's callback model directly to applications.

The underlying implementation can remain asynchronous without forcing every user of the web layer to program in callbacks.

---

# 24. Possible Library Structure

```text
chez-web/
  handler.sls
  request.sls
  response.sls
  body.sls
  middleware.sls

chez-web/middleware/
  errors.sls
  logging.sls
  request-id.sls

chez-router/
  router.sls
```

The base `chez-web` package should be small.

Routing, sessions, authentication, templating, etc. should not be required dependencies of the core application interface.

---

# 25. Relationship to the Server Layer

The adapter between `chez-http-server` and `chez-web` performs the translation:

```text
HTTP connection state
        ↓
parsed HTTP request
        ↓
chez-web Request
        ↓
handler
        ↓
chez-web Response
        ↓
HTTP response serializer
        ↓
connection write queue
```

The adapter may also need to translate:

```text
request body stream
response body stream
connection cancellation
backpressure
```

when those features are added.

---

# 26. Proposed Full Stack

```text
┌──────────────────────────────────┐
│           application            │
├──────────────────────────────────┤
│             router               │
├──────────────────────────────────┤
│           middleware             │
├──────────────────────────────────┤
│            chez-web              │
│                                  │
│ Request → Response               │
│ Handler → Handler                │
├──────────────────────────────────┤
│        chez-http-server          │
│                                  │
│ connection semantics             │
│ buffering / backpressure         │
│ keep-alive / pipelining          │
│ response serialization           │
├────────────────┬─────────────────┤
│   chez-http1   │   chez-libuv    │
│                │                 │
│ HTTP parser    │ transport       │
├────────────────┤ event loop      │
│byte-machine    │ TCP / timers    │
└────────────────┴─────────────────┘
```

---

# 27. Design Principles

1. **The web application interface belongs above HTTP connection semantics.**
2. **Applications should not see libuv or parser internals.**
3. **Use `Request → Response` as the default handler abstraction.**
4. **Use `Handler → Handler` as the middleware abstraction.**
5. **Keep routing separate from the core web contract.**
6. **Make handlers directly testable without networking.**
7. **Do not expose asynchronous callbacks merely because libuv uses callbacks.**
8. **Treat streaming as an explicit extension of body semantics.**
9. **Design response bodies so streaming can be added without changing the basic handler contract.**
10. **Begin with bounded buffered request bodies.**
11. **Add request streaming only after backpressure is correct at the server/transport layers.**
12. **Streaming middleware must be able to wrap body producers.**
13. **Distinguish handler completion from response transmission completion.**
14. **Do not introduce multiple competing async abstractions.**
15. **WebSocket upgrades should be a separate extension, not distort the core request/response model.**

---

# 28. Open Questions for Later Planning

The following decisions can be deferred until the lower layers exist:

- What exact Scheme representation should headers use?
- Should request and response objects be immutable records?
- How should body streams be represented?
- Should streaming use producers, ports, generators, or another abstraction?
- How should producers receive backpressure signals?
- Should asynchronous handler completion use callbacks, futures, fibers, or something else?
- How should client disconnect/cancellation be exposed?
- How should middleware observe final response completion?
- How should file responses interact with `uv_fs` or zero-copy OS facilities?
- How should WebSocket/protocol upgrades transfer connection ownership?
- Should a router be part of the same distribution or a separate package?

These should be answered based on implementation experience rather than fixed prematurely.
