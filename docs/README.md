# circuit

An HTTP layer for [Chez Scheme](https://cisco.github.io/ChezScheme/), in the
manner of Clojure's [Ring](https://github.com/ring-clojure/ring).

You write a *handler*: a procedure that takes a request and returns a
response. A *middleware* takes a handler and returns a new one that does a
little more: logs each request, adds a header, gives up after five seconds.
Circuit runs your handler on
[chez-http-server](https://github.com/Kiyomi-Computation-Systems/chez-http-server),
an HTTP/1.1 server built on libuv.

💡 These pages are Markdown in the repository's [docs](../docs) directory.

## A taste

```scheme
(import (rnrs) (circuit) (circuit http-server))

(run-server
 (lambda (req)
   (make-res 200 '(("content-type" . "text/plain")) "Hello\n")))
```

Save it as `hello.sps` in the checkout, start it with
`make run PROGRAM=hello.sps`, and ask:

```text
$ curl http://127.0.0.1:8080/
Hello
```

Press Ctrl-C and the server finishes what it is doing, then stops.

## Ideas to keep in mind

- **A handler is a procedure.** Request in, response out. To test one, call
  it.
- **A middleware is a procedure too.** Handler in, handler out.
  `(wrap app a b c)` stacks three, and the last, `c`, is outermost.
- **Requests and responses are values.** `req-set` and `res-add-header`
  return a new one and leave the old one as it was.
- **A body is a port.** `(req-body req)` reads the request's body as it
  arrives. Read it inside your handler, before you answer.
- **A handler may wait.** For a timer, a deadline or another request: other
  requests go on meanwhile, as each one runs on a coroutine of its own.
- **Settings come from the environment.** `CHEZ_HTTP_PORT=3000` moves the
  port. Nothing to edit in your code.

## What's in it

| Library | What it gives you |
|:--|:--|
| `(circuit)` | requests, responses, headers, `wrap`, body caps |
| `(circuit http-server)` | `run-server`, and the server's waits, such as `sleep-ms` |
| `(circuit router)` | `make-router`: routes by the path, then the method |
| `(circuit params)` | `req-query-params` and `wrap-form-params`: the query and a form, as pairs |
| `(circuit middleware waits)` | `wrap-catch`, `wrap-timeout` and `wrap-log` |
| `(circuit middleware cors)` | `wrap-cors`: lets a page on another origin call you |
| `(circuit middleware headers)` | `wrap-default-headers` and `wrap-hsts`: safe headers on every response |
| `(circuit websocket)` | `websocket-res`, which answers a WebSocket handshake |
| `(circuit test)` | `make-test-req`, to call a handler with no server |

## What it is not

- **No TLS, no HTTP/2.** The server speaks HTTP/1.1 over plain TCP. For
  `https://`, put a proxy such as Caddy or nginx in front (the server's
  [Deploying](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/deploying.md)).
- **No framework.** There are no templates, sessions or database layer.
  Write what you need as middleware.
- **No Windows.** Linux and macOS, on x86-64 and arm64.

## Status

v0.1.2, the latest release. The API may change in any release before 1.0;
the [changelog](../CHANGELOG.md) says what each release has.

## Read next

- [Installing](installing.md): what you need, building, and running your
  own program.
- [Quickstart](quickstart.md): a first app, step by step: the request, a
  router, middleware and a body.
- [Requests and responses](requests.md): what a request holds, and how to
  make a response.
- [Bodies and streaming](bodies.md): reading a body, capping it, and
  sending one as it is made.
- [Query strings and forms](params.md): reading the query and a form's
  fields.
- [Middleware](middleware.md): writing one, and the catch, timeout, log,
  CORS and headers that come with circuit.
- [Routing](routing.md): routes, groups and mounts.
- [Waiting](waiting.md): sleeping, deadlines, and waiting for another
  request.
- [Upgrades and WebSockets](upgrades.md): taking a connection over.
- [Testing handlers](testing.md): calling a handler with no server.
- [Configuration](configuration.md): the environment variables.
- [API reference](reference.md): every name, with its signature.
