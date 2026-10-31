# API reference

Every name the nine public libraries export, one entry each, library by
library. An entry gives the name's signature, says what it does, and links
the guide page that explains it. A name `(circuit http-server)` re-exports
from chez-http-server has no signature here: its entry links the server's
own reference, which has it.

A signature is notation, not Scheme, in Typed Racket's style: the
arguments' types, then `->`, then the result's. `[x]` is an optional
argument, `x ...` any number of them, and `(U a b)` either one.

```text
Handler    = Req -> Res
Middleware = Handler -> Handler
Headers    = (Listof (Pair String String))
Body       = (U #f Bytevector String Producer BinaryInputPort
                SizedBody WrappedBody TappedBody)
Producer   = (-> (U Bytevector Eof))
Params     = (Listof (Pair String String))
TakeOver   = (Transport Bytevector -> Answer)
Env        = (String -> (U String #f))
```

- `Req` is a request, `Res` a response, and `Nat` an exact integer, 0 or
  more.
- `Key` is what `make-req-key` makes. `SizedBody`, `WrappedBody` and
  `TappedBody` are what `make-sized-body`, `res-wrap-body` and
  `res-tap-body` make, and `UpgradeBody` is the body of
  `make-upgrade-res`'s 101.
- `MethodEntry` is what `GET` and its like make, and `Route` what `route`,
  `group` and `mount` make. `RouterOption` is what `on-not-found`,
  `on-bad-request` and `on-method-not-allowed` make, or a handler, which
  stands for `(on-not-found handler)`.
- `CorsOption` is what a `cors-` constructor makes, such as
  `cors-origins`, and `HstsOption` what `hsts-include-subdomains` makes.
- `Request`, `Transport`, `Answer` and `Awaiting` are chez-http-server's.
  `WebSocket`, `HandshakeSettings` and `WebsocketLimits` are
  chez-websocket's.

## `(circuit)`

Requests, responses, header lists and composing middleware: what every app
imports.

```scheme
(import (rnrs) (circuit))
```

### `req?`

```text
req? : Any -> Boolean
```

Whether it is a request. See [Requests and responses](requests.md).

### `req-method`

```text
req-method : Req -> Symbol
```

The method, as a symbol such as `GET`. See
[Requests and responses](requests.md).

### `req-scheme`

```text
req-scheme : Req -> Symbol
```

`http`, unless `req-with-scheme` gave the request another. See
[Requests and responses](requests.md).

### `req-host`

```text
req-host : Req -> String
```

The host the request names, `""` when it names none. See
[Requests and responses](requests.md).

### `req-path`

```text
req-path : Req -> String
```

The path, as the client sent it: not decoded. See
[Requests and responses](requests.md).

### `req-query`

```text
req-query : Req -> (U String #f)
```

What follows the target's first `?`, or `#f` when there is none. See
[Requests and responses](requests.md).

### `req-http-version`

```text
req-http-version : Req -> (Pair Nat Nat)
```

The version the request named, as its two numbers: `(1 . 1)`. See
[Requests and responses](requests.md).

### `req-header`

```text
req-header : Req String -> (U String #f)
```

The first field with that name, in any case, or `#f`. A name that is no
string is an assertion violation. See [Requests and responses](requests.md).

### `req-header-values`

```text
req-header-values : Req String -> (Listof String)
```

Every field with that name, in any case, in order: `'()` when there is
none. See [Requests and responses](requests.md).

### `req-headers`

```text
req-headers : Req -> (Listof (Pair String String))
```

Every field, in order, duplicates kept, each name in lower case. See
[Requests and responses](requests.md).

### `req-body`

```text
req-body : Req -> BinaryInputPort
```

The body, as a port that reads it as it arrives: the same port for every
copy of the request. Read it inside your handler, before you answer. See
[Bodies and streaming](bodies.md).

### `req-remote-address`

```text
req-remote-address : Req -> (U String #f)
```

The address of the connection's other end, such as `"192.0.2.7"`, or `#f`
where the host can't say: a test request has none. See
[Requests and responses](requests.md).

### `req-remote-port`

```text
req-remote-port : Req -> (U Nat #f)
```

That end's port, or `#f`. See [Requests and responses](requests.md).

### `req-local-address`

```text
req-local-address : Req -> (U String #f)
```

The address the connection came in on, or `#f`. See
[Requests and responses](requests.md).

### `req-local-port`

```text
req-local-port : Req -> (U Nat #f)
```

That end's port, or `#f`. See [Requests and responses](requests.md).

### `req-on-done!`

```text
req-on-done! : Req (Symbol -> Any) -> Void
```

Registers a procedure to be called once the response is done, with how it
ended: `written`, `client-closed` or `failed`. A non-procedure is an
assertion violation. See [Bodies and streaming](bodies.md).

### `make-req-key`

```text
make-req-key : Any -> Key
```

A key no other call makes, for a value a middleware keeps on a request. The
argument is a name for a reader. See [Requests and responses](requests.md).

### `req-key?`

```text
req-key? : Any -> Boolean
```

Whether it is a key `make-req-key` made. See
[Requests and responses](requests.md).

### `req-ref`

```text
req-ref : Req Key [Any] -> Any
```

The newest value the key was set to on the request, or the default, `#f`
unless given. See [Requests and responses](requests.md).

### `req-set`

```text
req-set : Req Key Any -> Req
```

A copy of the request with the key set to the value; the old one is left as
it was. A key `make-req-key` didn't make is an assertion violation. See
[Requests and responses](requests.md).

### `req-with-method`

```text
req-with-method : Req Symbol -> Req
```

A copy of the request with that method. A value of another type is an
assertion violation, as for each `req-with-` helper. See
[Requests and responses](requests.md).

### `req-with-scheme`

```text
req-with-scheme : Req Symbol -> Req
```

A copy of the request with that scheme, such as `https` behind a proxy. See
[Requests and responses](requests.md).

### `req-with-host`

```text
req-with-host : Req String -> Req
```

A copy of the request with that host. See
[Requests and responses](requests.md).

### `req-with-path`

```text
req-with-path : Req String -> Req
```

A copy of the request with that path. See
[Requests and responses](requests.md).

### `req-with-query`

```text
req-with-query : Req (U String #f) -> Req
```

A copy of the request with that query, or none for `#f`. See
[Requests and responses](requests.md).

### `req-with-remote-address`

```text
req-with-remote-address : Req (U String #f) -> Req
```

A copy of the request with that remote address. See
[Requests and responses](requests.md).

### `req-with-remote-port`

```text
req-with-remote-port : Req (U Nat #f) -> Req
```

A copy of the request with that remote port. See
[Requests and responses](requests.md).

### `req-body-cap`

```text
req-body-cap : Req -> (U Nat #f)
```

The most bytes this copy's body may hold, as `req-with-body-cap` gave it,
or `#f` for no cap of its own. See [Bodies and streaming](bodies.md).

### `req-with-body-cap`

```text
req-with-body-cap : Req (U Nat #f) -> Req
```

A copy of the request whose body may hold that many bytes at most, or, for
`#f`, only what the server allows. Once the body's port is made it is an
assertion violation: give the cap before anything reads the body. See
[Bodies and streaming](bodies.md).

### `make-res`

```text
make-res : Integer Headers Body -> Res
```

A response: a status, headers and a body, in that order. Nothing is
rewritten. A status that is no exact integer, headers that are no list, or
a body of none of `Body`'s kinds is an assertion violation. See
[Requests and responses](requests.md).

### `res?`

```text
res? : Any -> Boolean
```

Whether it is a response. See [Requests and responses](requests.md).

### `res-status`

```text
res-status : Res -> Integer
```

The status. See [Requests and responses](requests.md).

### `res-headers`

```text
res-headers : Res -> (Listof (Pair String String))
```

The header fields, as given. See [Requests and responses](requests.md).

### `res-body`

```text
res-body : Res -> (U Body UpgradeBody)
```

The body. See [Requests and responses](requests.md).

### `res-header`

```text
res-header : Res String -> (U String #f)
```

The value of the first field with that name, in any case, or `#f`. See
[Requests and responses](requests.md).

### `res-set-header`

```text
res-set-header : Res String String -> Res
```

A copy of the response with every field of that name replaced by one, the
name in lower case. See [Requests and responses](requests.md).

### `res-add-header`

```text
res-add-header : Res String String -> Res
```

A copy of the response with a field added at the end, the name in lower
case. See [Requests and responses](requests.md).

### `res-remove-header`

```text
res-remove-header : Res String -> Res
```

A copy of the response without the fields of that name, in any case. See
[Requests and responses](requests.md).

### `res-with-status`

```text
res-with-status : Res Integer -> Res
```

A copy of the response with that status. A 1xx status is an assertion
violation, as the server sends those itself, and so is an upgrade response.
See [Requests and responses](requests.md).

### `res-with-body`

```text
res-with-body : Res Body -> Res
```

A copy of the response with that body. The port the old body held is
closed, unless the new body holds it too. See
[Bodies and streaming](bodies.md).

### `res-body-length`

```text
res-body-length : Res -> (U Nat #f)
```

The body's length in bytes where circuit can tell it, or `#f`: for a
producer, a wrapped body, a port or an upgrade. See
[Bodies and streaming](bodies.md).

### `make-sized-body`

```text
make-sized-body : Nat (U Producer BinaryInputPort) -> SizedBody
```

A body of that many bytes, from a producer or a port, sent with that
length. Anything else is an assertion violation. See
[Bodies and streaming](bodies.md).

### `res-wrap-body`

```text
res-wrap-body : Res (Producer -> Producer) -> Res
```

A copy of the response whose body goes through the procedure as it is
sent: it gets the old body as a producer and returns the one to send. The
body has no length then, so it goes out chunked. See
[Bodies and streaming](bodies.md).

### `res-tap-body`

```text
res-tap-body : Res (Bytevector -> Any) -> Res
```

A copy of the response whose body hands each piece to the procedure as it
goes out. The pieces go out unchanged, so the body keeps its length. See
[Bodies and streaming](bodies.md).

### `make-upgrade-res`

```text
make-upgrade-res : Headers TakeOver -> Res
```

A 101 with those headers. Once it is written, the server calls the
take-over with its transport and the bytes it read past the request. See
[Upgrades and WebSockets](upgrades.md).

### `res-upgrade-body?`

```text
res-upgrade-body? : Any -> Boolean
```

Whether a body is an upgrade's, so a middleware can pass one by. See
[Upgrades and WebSockets](upgrades.md).

### `res-upgrade-body-take-over`

```text
res-upgrade-body-take-over : UpgradeBody -> TakeOver
```

The take-over an upgrade body holds, so a middleware can make an upgrade
around a wrapped one. See [Upgrades and WebSockets](upgrades.md).

### `header-value`

```text
header-value : Headers String -> (U String #f)
```

The value of the first field with that name, in any case, or `#f`. A list
that is no header list is an assertion violation, as for each header
helper. See [Requests and responses](requests.md).

### `header-values`

```text
header-values : Headers String -> (Listof String)
```

The value of every field with that name, in any case, in order. See
[Requests and responses](requests.md).

### `header-set`

```text
header-set : Headers String String -> Headers
```

The list with every field of that name replaced by one, where the first
stood, or added at the end when there is none. See
[Requests and responses](requests.md).

### `header-add`

```text
header-add : Headers String String -> Headers
```

The list with a field added at the end, the name in lower case. See
[Requests and responses](requests.md).

### `header-remove`

```text
header-remove : Headers String -> Headers
```

The list without the fields of that name, in any case. See
[Requests and responses](requests.md).

### `header-names-downcase`

```text
header-names-downcase : Headers -> Headers
```

The list with every name in lower case, in order. See
[Requests and responses](requests.md).

### `wrap`

```text
wrap : Handler Middleware ... -> Handler
```

The handler inside each middleware in turn: `(wrap h a b)` is `(b (a h))`,
so the last is outermost. One that is no procedure is an assertion
violation. See [Middleware](middleware.md).

### `wrap-body-cap`

```text
wrap-body-cap : (U Nat #f) -> Middleware
```

Middleware that caps each request's body at that many bytes, or, for `#f`,
leaves only the server's cap. A body past it raises the server's
`&body-failed`, which answers 413. See [Bodies and streaming](bodies.md).

## `(circuit http-server)`

The adapter, which runs an app on chez-http-server, and the server's waits,
conditions and transport, re-exported.

```scheme
(import (rnrs) (circuit) (circuit http-server))
```

### `run-server`

```text
run-server : (Req -> Res) [Env] -> Void
```

Starts the server with the app and runs until it is stopped. Its settings
come from the environment, or from the procedure given, and a malformed one
raises before it listens. See [Configuration](configuration.md).

### `circuit->handler`

```text
circuit->handler : (Req -> Res) [Env] -> (Request -> Awaiting)
```

The app as a server handler, for the server's `serve` or its test host. It
reads `CIRCUIT_PORT_PIECE_BYTES` once, now, and a malformed one raises. See
[Configuration](configuration.md) and [Testing handlers](testing.md).

### `await`

The server's wait for a procedure of yours to call `resume`; see [the
server's reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `sleep-ms`

The server's wait of so many milliseconds; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `with-deadline`

The server's deadline over a thunk's waits; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `resolve`

The server's wait for a host name's addresses; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `&deadline-passed`

The condition a wait raises once a `with-deadline` deadline has passed; see
[the server's reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `deadline-passed?`

Whether it is a `&deadline-passed`; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `&client-closed`

The condition a wait raises once the client has closed or reset the
connection; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `client-closed?`

Whether it is a `&client-closed`; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `&resolve-error`

The condition `resolve` raises for a name that does not resolve; see [the
server's reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `resolve-error?`

Whether it is a `&resolve-error`; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `resolve-error-reason`

Why a lookup failed, such as `EAI_NONAME`; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `&body-failed`

The condition a body's read raises when the body fails: past a cap,
malformed or stalled; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `body-failed?`

Whether it is a `&body-failed`; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `body-failed-reason`

Why a body failed, such as `body-too-large`; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `body-failed-status`

The status the server answers for a failed body, such as 413; see [the
server's reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `awaiting`

The server's answer that runs a thunk where it may wait, for a take-over
that waits; a handler never answers it, as the adapter does for every
request. See [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#waiting).

### `transport?`

Whether it is a transport, the stream a take-over gets after the 101; see
[the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#the-transport).

### `transport-write!`

Sends bytes on the transport; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#the-transport).

### `transport-read-start!`

Hands each read from the transport to a procedure, and its end to another;
see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#the-transport).

### `transport-read-stop!`

Stops reading the transport; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#the-transport).

### `transport-close!`

Closes the transport, once its writes have gone out and the client closes
too; see [the server's reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#the-transport).

### `transport-abort!`

Closes the transport now, dropping writes not yet sent; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#the-transport).

### `transport-deadline!`

Calls a procedure once so many milliseconds pass, or cancels that for
`#f`; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#the-transport).

### `transport-on-drain!`

Calls a procedure when the server shuts down; see [the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#the-transport).

### `transport-on-close!`

Calls a procedure once the transport has closed, whoever closed it; see
[the server's
reference](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/reference.md#the-transport).

## `(circuit middleware waits)`

Middleware that knows the server's waits and conditions: it catches a
raise, gives up after a time, and logs each request.

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit middleware waits))
```

### `wrap-catch`

```text
wrap-catch : Handler [(Req Any -> Res)] -> Handler
```

The handler with its raises caught: the response is what the procedure
answers, by default an empty 500 after a `handler-failed` line. A
`&body-failed` gets its own status, and `&client-closed` and
`&deadline-passed` are raised again. See [Middleware](middleware.md).

### `wrap-catch-with`

```text
wrap-catch-with : (Req Any -> Res) -> Middleware
```

A middleware that makes `(wrap-catch handler on-raise)` of the handler it
is given, for `wrap`. See [Middleware](middleware.md).

### `wrap-timeout`

```text
wrap-timeout : Nat -> Middleware
```

Middleware that runs its handler under the server's `with-deadline` of that
many milliseconds, and answers an empty 504 once it passes. Put it outside
`wrap-catch`, which raises the deadline on to it. See
[Middleware](middleware.md).

### `wrap-log`

```text
wrap-log : Handler [(-> Nat)] -> Handler
```

The handler with a line written for each request once its response is
done: `request METHOD PATH STATUS ENDING MS ADDRESS`, the address `-` for
none, and a control character in any of them a space. The clock reads
milliseconds, Chez's `real-time` unless given. See
[Middleware](middleware.md).

### `wrap-log-with`

```text
wrap-log-with : (-> Nat) -> Middleware
```

A middleware that makes `(wrap-log handler clock)` of the handler it is
given, for `wrap`. See [Middleware](middleware.md).

## `(circuit middleware cors)`

CORS: lets a page on another origin call the app from a script.

```scheme
(import (rnrs) (circuit) (circuit middleware cors))
```

### `wrap-cors`

```text
wrap-cors : CorsOption ... -> Middleware
```

Middleware that answers a preflight from an allowed origin itself, `204`,
and passes every other request to the handler. Its response gets the CORS
fields when the origin is allowed, and `vary: origin` always; under
`cors-any-origin`, `*` and no Vary. It takes one origin option and any of
the rest, each once; `cors-credentials` is refused with `cors-any-origin`,
and with a `*` in a list. Put it outside the router and `wrap-catch`.
See [Middleware](middleware.md).

### `cors-origins`

```text
cors-origins : String String ... -> CorsOption
```

The origins allowed, each written as a browser sends it:
`scheme://host` or `scheme://host:port`, in lower case, with no path and
no default port. Anything else, `"null"` too, is refused. See
[Middleware](middleware.md).

### `cors-origin-when`

```text
cors-origin-when : (String -> Any) -> CorsOption
```

The origins the predicate answers true for. It is asked only about an
origin a browser could send, never `null`. See [Middleware](middleware.md).

### `cors-any-origin`

```text
cors-any-origin : -> CorsOption
```

Every origin: `*` on every response. See [Middleware](middleware.md).

### `cors-methods`

```text
cors-methods : Symbol Symbol ... -> CorsOption
```

The methods a preflight's answer allows, beyond `GET`, `HEAD` and `POST`,
written as given. See [Middleware](middleware.md).

### `cors-headers`

```text
cors-headers : String String ... -> CorsOption
```

The request headers a preflight's answer allows, beyond the safelisted
ones, written in lower case. See [Middleware](middleware.md).

### `cors-any-header`

```text
cors-any-header : -> CorsOption
```

The request headers the preflight asks for, echoed. See
[Middleware](middleware.md).

### `cors-expose-headers`

```text
cors-expose-headers : String String ... -> CorsOption
```

The response headers a script may read, beyond the safelisted ones. See
[Middleware](middleware.md).

### `cors-credentials`

```text
cors-credentials : -> CorsOption
```

Lets a script read the answer to a request sent with cookies:
`access-control-allow-credentials: true`. See [Middleware](middleware.md).

### `cors-max-age`

```text
cors-max-age : Nat -> CorsOption
```

How many seconds a browser may keep a preflight's answer. See
[Middleware](middleware.md).

## `(circuit middleware headers)`

The fields every response should carry, and HSTS.

```scheme
(import (rnrs) (circuit) (circuit middleware headers))
```

### `wrap-default-headers`

```text
wrap-default-headers : Headers -> Middleware
```

Middleware that adds each field of the list the response lacks, by name in
any case, after the response's own. A bad list, or one holding a field
the server writes itself, such as `content-length`, is refused when it is
given. See [Middleware](middleware.md).

### `security-headers`

```text
security-headers : Headers
```

`x-content-type-options: nosniff`, `x-frame-options: SAMEORIGIN` and
`referrer-policy: strict-origin-when-cross-origin`, for
`wrap-default-headers`. See [Middleware](middleware.md).

### `wrap-hsts`

```text
wrap-hsts : Nat HstsOption ... -> Middleware
```

Middleware that sets `strict-transport-security: max-age=N` on the
response to an `https` request, and on no other. See
[Middleware](middleware.md).

### `hsts-include-subdomains`

```text
hsts-include-subdomains : -> HstsOption
```

Adds `includeSubDomains`, so every subdomain is `https` only too. See
[Middleware](middleware.md).

## `(circuit router)`

A table of routes, compiled once into one handler, which picks a route by
the path, then a handler by the method.

```scheme
(import (rnrs) (circuit) (circuit router))
```

### `make-router`

```text
make-router : (Listof Route) RouterOption ... -> Handler
```

A handler for the routes, compiled once, here. A path no route takes gets
an empty 404, a capture that doesn't decode an empty 400, and a method the
route doesn't take an empty 405, unless an option gives a handler for it.
The options come in any order, one for each answer. Two for one answer, a
constructor such as `on-bad-request` given without its handler, two
templates of one shape, or two routes of one name, are an assertion
violation. See [Routing](routing.md).

### `on-not-found`

```text
on-not-found : Handler -> RouterOption
```

The handler for a path no route takes. It gets the request as it came to
the router. A bare handler among the options means the same. See
[Routing](routing.md).

### `on-bad-request`

```text
on-bad-request : Handler -> RouterOption
```

The handler for a capture that doesn't decode: a bad escape, bytes that
aren't UTF-8, or a raw character a path can't hold, such as a space. It
gets the request as it came to the router. See [Routing](routing.md).

### `on-method-not-allowed`

```text
on-method-not-allowed : Handler -> RouterOption
```

The handler for a method the route doesn't take. It gets the request with
the route's match. When it answers a 405, the router sets `allow` on it;
any other answer goes out as it is. See [Routing](routing.md).

### `route`

```text
route : String [Symbol] MethodEntry ... -> Route
```

A route for a template, such as `"/users/:id"`, taking the methods its
entries name; a symbol after the template names it. No entry, or two for
one method, is an assertion violation. See [Routing](routing.md).

### `GET`

```text
GET : Handler -> MethodEntry
```

The handler for GET, which takes HEAD too when its route has no HEAD of its
own. See [Routing](routing.md).

### `POST`

```text
POST : Handler -> MethodEntry
```

The handler for POST. See [Routing](routing.md).

### `PUT`

```text
PUT : Handler -> MethodEntry
```

The handler for PUT. See [Routing](routing.md).

### `PATCH`

```text
PATCH : Handler -> MethodEntry
```

The handler for PATCH. See [Routing](routing.md).

### `DELETE`

```text
DELETE : Handler -> MethodEntry
```

The handler for DELETE. See [Routing](routing.md).

### `OPTIONS`

```text
OPTIONS : Handler -> MethodEntry
```

The handler for OPTIONS. See [Routing](routing.md).

### `ANY`

```text
ANY : Handler -> MethodEntry
```

The handler for every method its route doesn't list. See
[Routing](routing.md).

### `METHOD`

```text
METHOD : Symbol Handler -> MethodEntry
```

The handler for any method, named by its symbol: `(METHOD 'PROPFIND h)`. A
symbol that is no HTTP method name in upper case, such as `get`, is an
assertion violation. See [Routing](routing.md).

### `group`

```text
group : String (Listof Middleware) Route ... -> Route
```

Routes under a prefix, each of their handlers wrapped in the middlewares,
in `wrap`'s order. See [Routing](routing.md).

### `mount`

```text
mount : String Handler -> Route
```

A handler for a template and every path under it, whatever the method. The
handler sees the rest of the path. See [Routing](routing.md).

### `req-path-param`

```text
req-path-param : Req String -> (U String #f)
```

The value that the template's parameter or catch-all of that name captured,
percent-decoded, or `#f`. See [Routing](routing.md).

### `req-path-params`

```text
req-path-params : Req -> (Listof (Pair String String))
```

Every value the template captured, decoded, left to right. See
[Routing](routing.md).

### `req-route`

```text
req-route : Req -> (U String #f)
```

The template of what the router matched, such as `"/users/:id"`, or `#f`.
See [Routing](routing.md).

### `req-mount-path`

```text
req-mount-path : Req -> String
```

The part of the path that the mounts above took, such as `"/api/2"`; `""`
under none. See [Routing](routing.md).

## `(circuit params)`

The query and an urlencoded form, read as name and value pairs, by the
parser browsers use.

```scheme
(import (rnrs) (circuit) (circuit params))
```

### `req-query-params`

```text
req-query-params : Req -> Params
```

The query's pairs, in order, read each time it is asked; `'()` with no
query. See [Query strings and forms](params.md).

### `wrap-form-params`

```text
wrap-form-params : Nat -> Middleware
```

Middleware that reads an `application/x-www-form-urlencoded` body before
the handler, at most that many bytes, under any cap the request already
has. A longer one is a `413`. It goes inside every cap. See
[Query strings and forms](params.md).

### `req-form-params`

```text
req-form-params : Req -> Params
```

The pairs `wrap-form-params` read from the body, or `'()` when it read
none. See [Query strings and forms](params.md).

### `param-value`

```text
param-value : Params String -> (U String #f)
```

The value of the first pair with that name, in its case, or `#f`. See
[Query strings and forms](params.md).

### `param-values`

```text
param-values : Params String -> (Listof String)
```

The value of every pair with that name, in its case, in order. See
[Query strings and forms](params.md).

### `parse-params`

```text
parse-params : Bytevector -> Params
```

Bytes read as urlencoded pairs. It never fails: a `%` that starts no
escape stays a `%`, and bytes that are no UTF-8 read as U+FFFD. See
[Query strings and forms](params.md).

### `params->string`

```text
params->string : Params -> String
```

Pairs written urlencoded, a space as `+`, for a query or a test's form
body. See [Query strings and forms](params.md).

## `(circuit websocket)`

Answers a WebSocket's handshake; the rest is chez-websocket's
`(websocket)`, in
[its reference](https://github.com/Kiyomi-Computation-Systems/chez-websocket/blob/v0.5.1/docs/reference.md).

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit websocket) (websocket))
```

### `websocket-res`

```text
websocket-res : Req (WebSocket -> Any) [HandshakeSettings [WebsocketLimits]] -> Res
```

The answer to a handshake: a 101 whose take-over runs the procedure with the
WebSocket, or the refusal, a 400 or 403 with no body. Settings and limits
left out are chez-websocket's defaults. See
[Upgrades and WebSockets](upgrades.md).

## `(circuit test)`

What a test of a handler needs, with no server.

```scheme
(import (rnrs) (circuit) (circuit test))
```

### `make-test-req`

```text
make-test-req : Symbol String [Headers [(U Bytevector String #f)]] -> Req
```

A request for a method and a target, such as `"/users/7?full"`, with
headers and a body: HTTP/1.1, with no addresses. A target that doesn't
begin with `/` is an assertion violation. See [Testing handlers](testing.md).

### `test-req-done!`

```text
test-req-done! : Req Symbol -> (Listof Any)
```

Ends a test request's response with that ending, calling what
`req-on-done!` kept, newest first; it answers what they raised. See
[Testing handlers](testing.md).

### `res-body->bytevector`

```text
res-body->bytevector : Res [Req] -> Bytevector
```

A response's body, read as the adapter sends it by default: a port in
pieces of 65,536 bytes, whatever the app's `CIRCUIT_PORT_PIECE_BYTES`, so a
wrap or a tap sees those pieces. Given the request, a body
that holds its body port is an assertion violation, as the adapter refuses
it, and so is an upgrade response. See [Testing handlers](testing.md).
