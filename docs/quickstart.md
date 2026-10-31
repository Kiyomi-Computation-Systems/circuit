# Quickstart

A first app, one step at a time. Each step is a whole program: save it as
`app.sps` in the checkout, run it with `make run PROGRAM=app.sps`, and try it
with `curl` from another terminal. Ctrl-C stops it.

## 1. Answer every request

```scheme
(import (rnrs) (circuit) (circuit http-server))

(run-server
 (lambda (req)
   (make-res 200 '(("content-type" . "text/plain")) "Hello\n")))
```

- `run-server` starts the server and runs until you stop it. It listens on
  `127.0.0.1:8080` and prints `listening 127.0.0.1 8080`.
- The `lambda` is your handler. It gets each request, `req`, and returns a
  response.
- `(make-res status headers body)` makes the response. Headers are a list of
  `(name . value)` strings. A string body is sent as UTF-8.

```text
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:29:02 GMT
content-type: text/plain
Content-Length: 6

Hello
```

The server added `Date` and `Content-Length` for you.

## 2. Look at the request

```scheme
(import (rnrs) (circuit) (circuit http-server))

(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

(run-server
 (lambda (req)
   (let ((path (req-path req)))
     (cond ((string=? path "/") (text 200 "home\n"))
           ((string=? path "/hello")
            (text 200 (string-append "hello, " (or (req-query req) "stranger") "\n")))
           (else (text 404 "not found\n"))))))
```

```text
$ curl 'http://127.0.0.1:8080/hello?you'
hello, you
$ curl http://127.0.0.1:8080/hello
hello, stranger
```

`req-path` is the path, and `req-query` what follows the `?`, or `#f` when
there is none. `req-method` is the method, as a symbol such as `GET`.
[Requests and responses](requests.md) has the rest.

## 3. Route with the router

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit router))

(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

(define (home req) (text 200 "home\n"))

(define (show-user req)
  (text 200 (string-append "user " (req-path-param req "id") "\n")))

(run-server
 (make-router
  (list (route "/" (GET home))
        (route "/users/:id" (GET show-user)))))
```

```text
$ curl http://127.0.0.1:8080/users/42
user 42
$ curl http://127.0.0.1:8080/users/ann%20lee
user ann lee
$ curl -i -X DELETE http://127.0.0.1:8080/users/42
HTTP/1.1 405 Method Not Allowed
Date: Fri, 30 Oct 2026 10:29:13 GMT
allow: GET, HEAD
Content-Length: 0
```

- `route` takes a path and a handler for each method. `:id` matches one
  segment of the path, which `req-path-param` reads, percent-decoded.
- A route with a GET answers HEAD too.
- A path no route takes gets an empty `404`, and a method the route doesn't
  take an empty `405`.

[Routing](routing.md) has templates, groups and mounts.

## 4. Add middleware

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit router)
        (circuit middleware waits))

(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

(define (home req) (text 200 "home\n"))

(define (boom req) (error 'boom "something broke"))

(define app
  (make-router
   (list (route "/" (GET home))
         (route "/boom" (GET boom)))))

(define (wrap-server-header handler)
  (lambda (req)
    (res-add-header (handler req) "server" "circuit")))

(run-server (wrap app wrap-server-header wrap-catch wrap-log))
```

- `wrap-server-header` is a middleware you write. It takes a handler and
  returns one that adds a header to what that handler answers.
- `(wrap app a b c)` means `(c (b (a app)))`: the last is outermost.
- `wrap-catch` turns a raise into an empty `500`. `wrap-log` prints a line
  once each response is done.

```text
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:29:22 GMT
content-type: text/plain
server: circuit
Content-Length: 5

home
$ curl -i http://127.0.0.1:8080/boom
HTTP/1.1 500 Internal Server Error
Date: Fri, 30 Oct 2026 10:29:22 GMT
Content-Length: 0
```

The server's terminal shows:

```text
listening 127.0.0.1 8080
request GET / 200 written 0 127.0.0.1
handler-failed Exception in boom: something broke
request GET /boom 500 written 0 127.0.0.1
```

The `500` has no `server` field: `wrap-server-header` is inside
`wrap-catch`, so the raise went past it. Put it after `wrap-catch` to add the
field to every response. [Middleware](middleware.md) has the rest.

## 5. Read a body

```scheme
(import (rnrs) (circuit) (circuit http-server))

(define (read-all port)
  (let ((bytes (get-bytevector-all port)))
    (if (eof-object? bytes) (make-bytevector 0) bytes)))

(define (app req)
  (let ((body (read-all (req-body req))))
    (make-res 200 '(("content-type" . "text/plain"))
              (string-append "got " (number->string (bytevector-length body))
                             " bytes\n"))))

(run-server (wrap app (wrap-body-cap 1024)))
```

```text
$ curl --data 'hello there' http://127.0.0.1:8080/
got 11 bytes
```

- `(req-body req)` is a binary input port that reads the body as it
  arrives. Read it inside the handler, before you answer.
- The server caps no body by default. `(wrap-body-cap 1024)` caps this
  app's at 1 KiB, and a longer one gets an empty `413`.

[Bodies and streaming](bodies.md) has caps, streaming and server-sent
events.

## 6. Change where it listens

Settings come from the environment:

```sh
CHEZ_HTTP_PORT=3000 make run PROGRAM=app.sps
```

It prints `listening 127.0.0.1 3000`. `CHEZ_HTTP_HOST=0.0.0.0` listens on
every interface. The server's timeouts and limits are `CHEZ_HTTP_` variables
too: see [Configuration](configuration.md).

## More

[examples/](../examples/README.md) has more, each one file: streaming,
server-sent events, a long poll, an upgrade and a WebSocket.
