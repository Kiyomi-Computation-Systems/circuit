# Middleware

A middleware takes a handler and returns a new one that does a little
more. Here you write one, stack them, and use the three that come with
circuit.

## Write a middleware

```scheme
(import (rnrs) (circuit) (circuit http-server))

(define (app req)
  (make-res 200 '(("content-type" . "text/plain")) "hello\n"))

;; wrap-api-key : Middleware — lets in only a request with the right key
(define (wrap-api-key handler)
  (lambda (req)
    (if (equal? (req-header req "x-api-key") "let-me-in")
        (res-add-header (handler req) "x-checked" "yes")
        (make-res 401 '(("content-type" . "text/plain")) "no key\n"))))

(run-server (wrap app wrap-api-key))
```

```text
$ curl -i -H 'X-Api-Key: let-me-in' http://127.0.0.1:8080/
HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:56:52 GMT
content-type: text/plain
x-checked: yes
Content-Length: 6

hello
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 401 Unauthorized
Date: Fri, 30 Oct 2026 10:56:52 GMT
content-type: text/plain
Content-Length: 7

no key
```

- The new handler sees each request first. It can answer by itself, as the
  `401` does, or call the handler it wraps and change what that answers.
- A middleware that takes settings is a procedure that returns one:
  `(wrap-body-cap 1024)`, `(wrap-timeout 5000)`.

## Stack them with `wrap`

```scheme
(import (rnrs) (circuit) (circuit http-server))

(define (app req)
  (display "app\n")
  (make-res 200 '() "hello\n"))

;; noisy : String -> Middleware — says when a request passes it, in and out
(define (noisy name)
  (lambda (handler)
    (lambda (req)
      (display (string-append name " in\n"))
      (let ((res (handler req)))
        (display (string-append name " out\n"))
        res))))

(run-server (wrap app (noisy "a") (noisy "b") (noisy "c")))
```

One request, and the server's terminal shows:

```text
c in
b in
a in
app
a out
b out
c out
```

- `(wrap app a b c)` is `(c (b (a app)))`: the last is outermost.
- A request passes `c` first, and its response passes `c` last.
- So a middleware that should see every answer, such as a log, goes last.
- `wrap` applies each middleware once, when it is called, not once a
  request.

## Pass data down

```scheme
(import (rnrs) (circuit) (circuit http-server))

(define user-key (make-req-key 'user))

;; req-user : Req -> String — the user wrap-user found, or "guest"
(define (req-user req) (req-ref req user-key "guest"))

;; wrap-user : Middleware — takes the user from x-user
(define (wrap-user handler)
  (lambda (req)
    (let ((user (req-header req "x-user")))
      (handler (if user (req-set req user-key user) req)))))

(define (app req)
  (make-res 200 '(("content-type" . "text/plain"))
            (string-append "hello, " (req-user req) "\n")))

(run-server (wrap app wrap-user))
```

```text
$ curl -H 'X-User: ann' http://127.0.0.1:8080/
hello, ann
$ curl http://127.0.0.1:8080/
hello, guest
```

- `make-req-key` makes a key no other library can make, so two never clash.
- `req-set` hands the handler a new request, and every handler inside it
  sees the value.
- Export a reader, here `req-user`, and keep the key to yourself.
- To parse the body, as a form or JSON, read it once and keep what you
  parsed under a key: the body can be read only once.

## Change the request and the response

```scheme
(import (rnrs) (circuit) (circuit http-server))

(define (app req)
  (make-res 200 '(("content-type" . "text/plain"))
            (string-append (symbol->string (req-scheme req)) "\n")))

;; wrap-proxy : Middleware — believes the proxy on 127.0.0.1 about the scheme
(define (wrap-proxy handler)
  (lambda (req)
    (if (and (equal? (req-remote-address req) "127.0.0.1")
             (equal? (req-header req "x-forwarded-proto") "https"))
        (handler (req-with-scheme req 'https))
        (handler req))))

;; wrap-hsts : Middleware — tells an https client to stay on https
(define (wrap-hsts handler)
  (lambda (req)
    (let ((res (handler req)))
      (if (eq? (req-scheme req) 'https)
          (res-set-header res "strict-transport-security" "max-age=31536000")
          res))))

(run-server (wrap app wrap-hsts wrap-proxy))
```

```text
$ curl -i -H 'X-Forwarded-Proto: https' http://127.0.0.1:8080/
HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:56:57 GMT
content-type: text/plain
strict-transport-security: max-age=31536000
Content-Length: 6

https
$ curl http://127.0.0.1:8080/
http
```

- On the way in, hand the handler a changed copy, made with a `req-with-`
  helper ([Requests and responses](requests.md)).
- On the way out, change what the handler answered: `res-set-header`,
  `res-with-status` and the rest. To change the body's bytes, use
  `res-wrap-body` ([Bodies and streaming](bodies.md)).
- `wrap-proxy` is outside `wrap-hsts`, so `wrap-hsts` sees the scheme it
  set.
- A `101` from `make-upgrade-res` keeps its status and body:
  `res-with-status` and `res-with-body` refuse one. Tell one by
  `(res-upgrade-body? (res-body res))`
  ([Upgrades and WebSockets](upgrades.md)).

## Catch errors: `wrap-catch`

The three middlewares that know the server's waits are in
`(circuit middleware waits)`.

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit middleware waits))

(define (app req)
  (if (string=? (req-path req) "/boom")
      (error 'app "boom")
      (make-res 200 '(("content-type" . "text/plain")) "hello\n")))

;; on-raise : Req Any -> Res — a page of our own, and a line of our own
(define (on-raise req raised)
  (display (string-append "failed " (req-path req) "\n"))
  (make-res 500 '(("content-type" . "text/plain")) "sorry, that broke\n"))

(run-server (wrap app (lambda (handler) (wrap-catch handler on-raise))))
```

```text
$ curl -i http://127.0.0.1:8080/boom
HTTP/1.1 500 Internal Server Error
Date: Fri, 30 Oct 2026 10:56:59 GMT
content-type: text/plain
Content-Length: 18

sorry, that broke
```

The server's terminal shows `failed /boom`.

- `(wrap app wrap-catch)` turns a raise into an empty `500`, and writes the
  `handler-failed` line the server would have
  ([Quickstart](quickstart.md)).
- `(wrap-catch handler on-raise)` answers what `(on-raise req raised)`
  answers instead. A raise from `on-raise` goes on to the middleware
  outside.
- A `&body-failed` is answered with its own status, such as `413` for a
  body past its cap.
- `&client-closed` and `&deadline-passed` go on, untouched. Do the same in
  a catch of your own: catching the first leaves a handler that waits
  again stuck for good, and catching the second turns a `504` into a `500`.
- It covers the handler's call alone. A producer, a wrap's `f` and a tap
  run after the handler returns, so a raise there reaches the server.

A catch of your own passes the same two on, and answers `&body-failed`
with its status. The predicates come from `(circuit http-server)`:

```scheme
;; wrap-errors : Middleware — a 500 of our own
(define (wrap-errors handler)
  (lambda (req)
    (guard (e ((or (client-closed? e) (deadline-passed? e)) (raise e))
              ((body-failed? e) (make-res (body-failed-status e) '() #f))
              (else (make-res 500 '(("content-type" . "text/plain"))
                              "sorry, that broke\n")))
      (handler req))))
```

## Time out: `wrap-timeout`

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit middleware waits))

(define (app req)
  (sleep-ms 2000)
  (make-res 200 '() "late\n"))

(run-server (wrap app wrap-catch (wrap-timeout 1000) wrap-log))
```

```text
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 504 Gateway Timeout
Date: Fri, 30 Oct 2026 10:57:02 GMT
Content-Length: 0

```

The server's terminal shows `request GET / 504 written 1005`.

- `(wrap-timeout ms)` runs the handler under a deadline, and answers an
  empty `504` once `ms` milliseconds pass.
- It covers what the handler waits for: `sleep-ms`, `await`, a read of the
  body. It cuts nothing short that isn't waiting: a busy loop runs on.
- It doesn't cover a producer, which runs after the handler returns.
- Put it outside `wrap-catch`. The catch passes the deadline on, so an
  `on-raise` that waits past it still gets the `504`. With the timeout
  inside the catch, that raise reaches the server, which answers `500`.

## Log requests: `wrap-log`

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit middleware waits))

(define (app req)
  (if (string=? (req-path req) "/boom")
      (error 'app "boom")
      (make-res 200 '(("content-type" . "text/plain")) "hello\n")))

(run-server (wrap app wrap-log))
```

Ask for `/users?id=7`, then `/boom`, and the server's terminal shows:

```text
listening 127.0.0.1 8080
request GET /users 200 written 1
handler-failed Exception in app: boom
request GET /boom raised failed 0
```

- Once a response is done, `wrap-log` writes a line on standard output:
  `request`, the method, the path without its query, the status, how the
  response ended, and how many milliseconds it took.
- The status is the handler's: `raised` when it raised, and `-` for an
  answer that is no response. The ending `failed` means the server ended
  it, perhaps with a status of its own: here, its `500`.
- Put it last, outside `wrap-catch` and `wrap-timeout`, so it logs the
  `500`, `504` and `413` they answer.
- A request the server refuses before any handler runs never reaches
  `wrap-log`: a malformed one, or a declared body past
  `CHEZ_HTTP_MAX_BODY_BYTES`. The server logs it itself, with its status,
  why it refused, and the client's address:
  `request-refused 400 invalid-host 127.0.0.1`.
- A line has no timestamp: what collects standard output adds one.
  `(wrap-log handler clock)` reads a clock of your own, in milliseconds.

## A stack to start from

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit middleware waits))

(define (app req)
  (make-res 200 '(("content-type" . "text/plain")) "hello\n"))

(run-server
 (wrap app
       (wrap-body-cap 1048576)
       wrap-catch
       (wrap-timeout 30000)
       wrap-log))
```

```text
$ curl http://127.0.0.1:8080/
hello
```

The server's terminal shows `request GET / 200 written 0`.

- Each body is capped at 1 MiB, a raise answers `500`, a handler still
  waiting after 30 seconds `504`, and `wrap-log`, last, logs every answer.
  A middleware of yours that adds a header goes after `wrap-catch`, so the
  `500` gets it too.

[middleware.sps](../examples/middleware.sps) runs the last three, with a
1 s timeout.

See [`wrap-catch`](reference.md#wrap-catch),
[`wrap-timeout`](reference.md#wrap-timeout) and
[`wrap-log`](reference.md#wrap-log) for the signatures.
