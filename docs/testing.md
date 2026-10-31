# Testing handlers

A handler is a procedure, so a test calls it. Here you make a request with
no server, read what the handler answers, and run a handler that waits in
the server's test host.

## Call a handler

```scheme
(import (rnrs) (circuit) (circuit test))

(define (app req)
  (make-res 200 '(("content-type" . "text/plain"))
            (string-append "hello, " (or (req-query req) "stranger") "\n")))

(define res (app (make-test-req 'GET "/hello?you")))

(write (res-status res)) (newline)
(write (res-headers res)) (newline)
(display (utf8->string (res-body->bytevector res)))
```

Save it as `call.sps` in the checkout, and `make run PROGRAM=call.sps`
prints:

```text
200
(("content-type" . "text/plain"))
hello, you
```

- `(make-test-req method target [headers [body]])` makes a request with no
  server. The target begins with `/`, and splits at its first `?` into the
  path and the query.
- Headers are a list of `(name . value)` strings, and the host is the
  `host` field's, or `""`. A body is a bytevector, a string, read as its
  UTF-8 bytes, or `#f` for none.
- Write a query's value past ASCII escaped, `/?q=caf%C3%A9`, as a browser
  sends it: the server answers a target holding a byte past ASCII `400`
  ([Query strings and forms](params.md)).
- A test request is HTTP/1.1, and has no addresses: `req-remote-address`
  and the other three read `#f`.
- `(res-body->bytevector res)` reads any body as the server would send it
  by default: a string, a port, a producer, a sized or a wrapped body. One
  that ends short of its length, or runs past it, is an assertion
  violation.
- It reads a port in pieces of 65,536 bytes, the default, whatever your
  app's `CIRCUIT_PORT_PIECE_BYTES`. A wrap or a tap sees those pieces
  ([below](#test-a-wrap-across-pieces)).
- A test request reads its body whatever its cap. The server holds caps,
  so test one in the server's test host
  ([below](#test-a-handler-that-waits)).

## End a response

```scheme
(import (rnrs) (circuit) (circuit test) (circuit middleware waits))

(define (app req) (make-res 200 '() "hello\n"))

;; clock : -> Nat — 5 ms later each time it is read
(define clock (let ((now 0)) (lambda () (set! now (+ now 5)) now)))

(define req (make-test-req 'GET "/hello?x=1"))
(define res ((wrap-log app clock) req))

(write (test-req-done! req 'written)) (newline)
```

It prints `wrap-log`'s line, then what `test-req-done!` answers:

```text
request GET /hello 200 written 5 -
()
```

- A test request keeps what `req-on-done!` registers.
  `(test-req-done! req ending)` calls each, newest first, with `written`,
  `client-closed` or `failed`.
- It answers a list of what they raised, `()` when nothing did. A raise
  doesn't stop the rest.
- The first call ends the response: a later one calls nothing.
- `wrap-log` takes a clock, so a test's line has a known time. A test
  request has no address, so the line ends with `-`.

## Test a handler that waits

A handler that waits, with `sleep-ms`, `await` or `wrap-timeout`, needs the
server: called directly, its wait raises `a wait on no coroutine`. The
server's test host, `(http-server testing)`, runs it as the server does,
with no socket and a clock that only your test moves.

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit middleware waits)
        (http-server testing))

(define (app req)
  (sleep-ms 2000)
  (make-res 200 '() "late\n"))

;; no-env : String -> #f — every setting at its default
(define (no-env name) #f)

(define host (make-test-host (circuit->handler (wrap app (wrap-timeout 1000)) no-env) no-env))
(define client (test-host-connect! host))

(test-client-send! client (string->utf8 "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
(test-host-advance! host 999)
(write (map test-response-status (test-client-responses client))) (newline)
(test-host-advance! host 1)
(write (map test-response-status (test-client-responses client))) (newline)
```

It prints the statuses the client has read, at 999 ms and at 1000 ms:

```text
()
(504)
```

- `(circuit->handler app env)` makes your app the server's handler. Give
  it and `make-test-host` the same `env`, a procedure from a setting's name
  to its value or `#f`, so the test never reads the process's environment.
- `test-client-send!` sends the bytes a client would, `test-host-advance!`
  moves the clock, and `test-client-responses` lists what the client has
  read.
- Nothing runs between your calls, so a test never sleeps and never hangs.
- `wrap-catch` alone needs no host, as long as the handler doesn't wait.
- The server's
  [Testing handlers](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.10.0/docs/testing.md)
  has the rest: a body in pieces, a client that leaves, the server's log.

## Test a wrap across pieces

A wrap's `f` gets the body a piece at a time. `res-body->bytevector`
reads a port of 64 KiB or less as one piece, so a test on a small file
never splits it. Give the handler a producer instead: its pieces go out as
they are, so you choose where they split.

```scheme
(import (rnrs) (circuit) (circuit test))

;; wrap-shout : Middleware — upper-cases each piece of ASCII text, as in Bodies
(define (wrap-shout handler)
  (lambda (req)
    (res-wrap-body (handler req)
                   (lambda (produce)
                     (lambda ()
                       (let ((piece (produce)))
                         (if (eof-object? piece)
                             piece
                             (string->utf8 (string-upcase (utf8->string piece))))))))))

;; pieces : Bytevector ... -> Producer — each bytevector a piece, then eof
(define (pieces . all)
  (lambda ()
    (if (null? all)
        (eof-object)
        (let ((piece (car all)))
          (set! all (cdr all))
          piece))))

;; shouted : Bytevector ... -> String — what wrap-shout sends for a body in these pieces
(define (shouted . all)
  (let ((app (lambda (req) (make-res 200 '() (apply pieces all)))))
    (utf8->string (res-body->bytevector ((wrap-shout app) (make-test-req 'GET "/"))))))

(write (shouted (string->utf8 "café"))) (newline)
(write (shouted #vu8(99 97 102 195) #vu8(169))) (newline)
```

It prints `café` in one piece, then split inside the `é`:

```text
"CAFÉ"
"CAF��"
```

- `wrap-shout` reads each piece as text, and half a character isn't
  text. Pieces that split every character find it.
- To read a port in your app's own pieces, run the app in the test host
  ([above](#test-a-handler-that-waits)), with an `env` that gives
  `CIRCUIT_PORT_PIECE_BYTES`.

## A small suite

```scheme
(import (rnrs) (srfi :64)
        (circuit) (circuit http-server) (circuit test) (circuit middleware waits)
        (http-server testing))

(define (app req)
  (if (string=? (req-path req) "/slow")
      (begin (sleep-ms 2000) (make-res 200 '() "late\n"))
      (make-res 200 '(("content-type" . "text/plain")) "hello\n")))

;; no-env : String -> #f — every setting at its default
(define (no-env name) #f)

;; status-after : (Req -> Res) String Nat -> (Listof Nat)
;; The statuses a client has read MS ms after it sent GET PATH.
(define (status-after handler path ms)
  (let* ((host (make-test-host (circuit->handler handler no-env) no-env))
         (client (test-host-connect! host)))
    (test-client-send! client (string->utf8 (string-append "GET " path " HTTP/1.1\r\nHost: x\r\n\r\n")))
    (test-host-advance! host ms)
    (map test-response-status (test-client-responses client))))

(define runner (test-runner-simple))
(test-runner-current runner)

(test-begin "app")

(test-equal "it says hello" "hello\n"
  (utf8->string (res-body->bytevector (app (make-test-req 'GET "/")))))

(test-equal "a slow answer waits" '()
  (status-after (wrap app (wrap-timeout 1000)) "/slow" 999))

(test-equal "a slow answer times out" '(504)
  (status-after (wrap app (wrap-timeout 1000)) "/slow" 1000))

(test-end "app")

(exit (if (and (> (test-runner-pass-count runner) 0)
               (= (test-runner-fail-count runner) 0))
          0
          1))
```

Save it as `test-app.sps`, and `make run PROGRAM=test-app.sps` prints:

```text
%%%% Starting test app
# of expected passes      3
```

- `(srfi :64)` is on `make run`'s library path.
- SRFI-64 sets no exit status, so the suite ends with its own `exit`: 0 or
  1, never a count, which wraps at 256.
- A raise inside `test-equal`'s expression counts as a failure. Don't
  expect `#f` from code that can raise.
- Watch each test fail once. Change `(wrap-timeout 1000)` to
  `(wrap-timeout 1001)` in the last test, and it prints
  `FAIL a slow answer times out`.

See [`make-test-req`](reference.md#make-test-req),
[`test-req-done!`](reference.md#test-req-done) and
[`res-body->bytevector`](reference.md#res-body-bytevector) for the
signatures.
