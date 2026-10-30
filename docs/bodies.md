# Bodies and streaming

Read a request's body and cap it. Send a body whole, from a port, or a
piece at a time as you make it.

## Read a body

```scheme
(import (rnrs) (circuit) (circuit http-server))

;; read-lines : TextualInputPort -> (Listof String)
(define (read-lines port)
  (let loop ((lines '()))
    (let ((line (get-line port)))
      (if (eof-object? line) (reverse lines) (loop (cons line lines))))))

(define (app req)
  (let* ((text (transcoded-port (req-body req) (make-transcoder (utf-8-codec))))
         (lines (read-lines text)))
    (make-res 200 '(("content-type" . "text/plain"))
              (string-append (number->string (length lines)) " lines, the first "
                             (if (null? lines) "none" (car lines)) "\n"))))

(run-server (wrap app (wrap-body-cap 65536)))
```

```text
$ printf 'one\ntwo\nthree\n' | curl --data-binary @- http://127.0.0.1:8080/
3 lines, the first one
$ curl http://127.0.0.1:8080/
0 lines, the first none
```

- `(req-body req)` is a binary input port that reads the body as it
  arrives. With no body, it reads eof at once.
- Read it inside the handler's call, middleware's included. A producer
  can't read it, and a response whose body is `req-body`'s port gets a
  `500`: read the bytes, then send them.
- The body is one stream, read once, and every copy of the request has the
  same port. For text, transcode it once, as here, and read on through the
  text port.
- A handler that answers without reading the body sends its answer at
  once, and the server closes the connection after it.

## Cap a body

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit router))

;; read-all : BinaryInputPort -> Bytevector
(define (read-all port)
  (let ((bytes (get-bytevector-all port)))
    (if (eof-object? bytes) (make-bytevector 0) bytes)))

(define (count req)
  (let ((body (read-all (req-body req))))
    (make-res 200 '(("content-type" . "text/plain"))
              (string-append "got " (number->string (bytevector-length body)) " bytes\n"))))

(run-server
 (wrap (make-router
        (list (route "/notes" (POST count))
              (group "/uploads" (list (wrap-body-cap 1024))
                (route "" (POST count)))))
       (wrap-body-cap 16)))
```

```text
$ curl --data 'a short note' http://127.0.0.1:8080/notes
got 12 bytes
$ curl -i --data 'a note of more than sixteen bytes' http://127.0.0.1:8080/notes
HTTP/1.1 413 Content Too Large
Date: Fri, 30 Oct 2026 10:56:32 GMT
Content-Length: 0
Connection: close

$ curl --data 'a note of more than sixteen bytes' http://127.0.0.1:8080/uploads
got 33 bytes
```

- The server caps no body unless `CHEZ_HTTP_MAX_BODY_BYTES` says so
  ([Configuration](configuration.md)).
- `(wrap-body-cap n)` caps the body of each request that passes it at `n`
  bytes, under the server's cap. `(wrap-body-cap #f)` lifts any cap outside
  it, leaving only the server's.
- The innermost cap wins: here `/uploads` takes 1 KiB, and the rest
  16 bytes.
- `(req-with-body-cap req n)` caps one request, and `(req-body-cap req)`
  reads its cap, `#f` for none of its own.
- Cap a body before anything reads it. Once `req-body` has made the port,
  a new cap is an assertion violation.

## When a body is too big

A client that waits for `100 Continue` before it sends its body gets the
`413` instead. The same server as above:

```text
$ curl -i -H 'Expect: 100-continue' --data 'short' http://127.0.0.1:8080/notes
HTTP/1.1 100 Continue

HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:56:32 GMT
content-type: text/plain
Content-Length: 12

got 5 bytes
$ curl -i -H 'Expect: 100-continue' --data 'a note of more than sixteen bytes' http://127.0.0.1:8080/notes
HTTP/1.1 413 Content Too Large
Date: Fri, 30 Oct 2026 10:56:32 GMT
Content-Length: 0
Connection: close

```

- A body past its cap raises `&body-failed` at the read that passes it. A
  declared `Content-Length` past it fails the first read, before any
  `100 Continue`.
- Let out of the handler, or caught by `wrap-catch`, it answers `413`. The
  connection closes after it.
- curl waits for `100 Continue` before a body over 1 MiB.
- A declared length past `CHEZ_HTTP_MAX_BODY_BYTES` never reaches your
  handler: the server answers `413` itself.
- To test a cap, see [Testing handlers](testing.md).

## Send bytes or a string

```scheme
(import (rnrs) (circuit) (circuit http-server))

(run-server
 (lambda (req)
   (make-res 200 '(("content-type" . "text/plain; charset=utf-8")) "héllo\n")))
```

```text
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:56:34 GMT
content-type: text/plain; charset=utf-8
Content-Length: 7

héllo
```

- A bytevector goes out as it is, and a string as its UTF-8 bytes, each
  with its length.
- `#f` is no body: `Content-Length: 0`.

## Send a file or a port

```scheme
(import (rnrs) (circuit) (circuit http-server))

(run-server
 (lambda (req)
   (make-res 200 '(("content-type" . "text/plain"))
             (open-file-input-port "LICENSE"))))
```

```text
$ curl -I http://127.0.0.1:8080/
HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:56:36 GMT
content-type: text/plain
Content-Length: 1517

```

- A port goes out with its length when Chez knows it: a file's, or a
  bytevector port's. Any other port goes out chunked.
- A port whose length Chez knows, of one piece or less, is read whole at
  once, and closed. A piece is 64 KiB, unless `CIRCUIT_PORT_PIECE_BYTES`
  says otherwise ([Configuration](configuration.md)).
- Any other port streams a piece at a time, and is closed however the
  response ends: sent, a `HEAD`, or the client gone, under a wrap or a tap
  too.
- `res-with-body` swaps a response's body, and closes a port the old one
  held. `(res-body-length res)` is the length circuit can tell, `#f` for a
  port, a producer or a wrap.
- Check Chez's `file-regular?` before you open a path. A FIFO stops the
  whole server while it waits for a writer, then gets a `500`. A file
  under `/proc` reports a size it doesn't hold, so it goes out empty: read
  one whole and send its bytes.

## Stream a response

```scheme
(import (rnrs) (circuit) (circuit http-server))

;; counting : Nat -> Producer — the lines 1 to N, a piece each
(define (counting n)
  (let ((i 0))
    (lambda ()
      (set! i (+ i 1))
      (if (> i n)
          (eof-object)
          (string->utf8 (string-append (number->string i) "\n"))))))

(run-server
 (lambda (req)
   (make-res 200 '(("content-type" . "text/plain")) (counting 3))))
```

```text
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:56:37 GMT
content-type: text/plain
Transfer-Encoding: chunked

1
2
3
```

- A producer is a procedure of no arguments. Each call answers the next
  piece, a bytevector of one byte or more, and the eof object at the end.
- It has no length, so it goes out chunked. A `HEAD`, a `204` or a `304`
  never calls it.
- It runs after the handler has returned, outside every middleware, so
  `wrap-catch` and `wrap-timeout` don't cover it.
- It may wait, with `sleep-ms` or the server's other waits
  ([Waiting](waiting.md)).
- A raise, or an empty piece, comes after the head is sent: the server cuts
  the body short, closes the connection and logs `handler-failed`.

## Stream with a length

In the program above, answer with a sized body instead:

```scheme
(make-res 200 '(("content-type" . "text/plain"))
          (make-sized-body 6 (counting 3)))
```

```text
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:56:39 GMT
content-type: text/plain
Content-Length: 6

1
2
3
```

- `(make-sized-body n body)` says a producer or a port holds `n` bytes. It
  goes out with that length, so a `HEAD` learns it too.
- The server stops asking at `n`. A body that ends short, or a piece that
  would pass `n`, is cut short: the server closes the connection and logs
  `body-length-mismatch`, then the length and the bytes the producer gave.
- Don't set `content-length` yourself: the server answers `500` to that.
- A port in a sized body always streams.

## Server-sent events

An event stream is a producer that waits for each event.
[stream.sps](../examples/stream.sps) has one:

```scheme
;; ticking : Nat Nat -> (-> (U Bytevector Eof)) — N events, MS apart.
(define (ticking n ms)
  (let ((i 0))
    (lambda ()
      (set! i (+ i 1))
      (cond ((> i n) (eof-object))
            (else (when (> i 1) (sleep-ms ms))
                  (string->utf8 (string-append "data: tick " (number->string i) "\n\n")))))))

(make-res 200 '(("content-type" . "text/event-stream") ("cache-control" . "no-cache"))
          (ticking 3 1000))
```

Run the example with `make run PROGRAM=examples/stream.sps`:

```text
$ curl -N 'http://127.0.0.1:8080/ticks?n=3&ms=1000'
data: tick 1

data: tick 2

data: tick 3

```

- Each event is `data: `, its text, and a blank line.
- `sleep-ms` waits without holding up other requests. To wait for
  something else, such as another request, see [Waiting](waiting.md).
- `curl -N` shows each event as it comes, a second apart.

## Change a body on its way out

```scheme
(import (rnrs) (circuit) (circuit http-server))

(define (app req)
  (make-res 200 '(("content-type" . "text/plain")) "hello, world\n"))

;; wrap-shout : Middleware — upper-cases each piece of ASCII text as it goes out
(define (wrap-shout handler)
  (lambda (req)
    (res-wrap-body (handler req)
                   (lambda (produce)
                     (lambda ()
                       (let ((piece (produce)))
                         (if (eof-object? piece)
                             piece
                             (string->utf8 (string-upcase (utf8->string piece))))))))))

;; wrap-count : Middleware — counts the bytes sent, and prints the count once done
(define (wrap-count handler)
  (lambda (req)
    (let ((sent 0))
      (req-on-done! req (lambda (ending)
                          (display (list 'sent sent ending))
                          (newline)))
      (res-tap-body (handler req)
                    (lambda (piece) (set! sent (+ sent (bytevector-length piece))))))))

(run-server (wrap app wrap-shout wrap-count))
```

```text
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:56:45 GMT
content-type: text/plain
Transfer-Encoding: chunked

HELLO, WORLD
```

The server's terminal shows `(sent 13 written)`.

- `(res-wrap-body res f)` hands `f` the body as a producer, and sends the
  producer `f` answers. Use it to change the bytes, as compression does.
  The body loses its length, so it goes out chunked.
- `(res-tap-body res on-piece)` hands `on-piece` each piece as it goes out,
  unchanged. Use it to count or to throttle: it may wait. The body keeps
  its length.
- A tap never sees the end: report a total from `req-on-done!`, as here.
- Like any producer, the one `f` returns must never answer an empty piece:
  loop until you have bytes or reach eof.
- A wrap's `f` runs as soon as the handler returns, before the head goes
  out, even for a `HEAD`. The producer it returns, and a tap, run as the
  body is sent, so a `HEAD`, a `204` or a `304` calls neither, unless an
  `f` outside them reads the body itself.

## Know when a response is done

```scheme
(import (rnrs) (circuit) (circuit http-server))

;; slowly : Nat -> Producer — the lines 1 to N, a second apart
(define (slowly n)
  (let ((i 0))
    (lambda ()
      (set! i (+ i 1))
      (cond ((> i n) (eof-object))
            (else (when (> i 1) (sleep-ms 1000))
                  (string->utf8 (string-append (number->string i) "\n")))))))

(define (app req)
  (req-on-done! req (lambda (ending)
                      (display (list 'done (req-path req) ending))
                      (newline)))
  (make-res 200 '(("content-type" . "text/plain")) (slowly 3)))

(run-server app)
```

```text
$ curl http://127.0.0.1:8080/a
1
2
3
$ curl --max-time 1 http://127.0.0.1:8080/b
1
curl: (28) Operation timed out after 1003 milliseconds with 2 bytes received
```

The server's terminal shows:

```text
listening 127.0.0.1 8080
(done /a written)
read-error ECONNRESET
(done /b client-closed)
```

curl reset the connection as it gave up, and the server logs that as
`read-error ECONNRESET`.

- `(req-on-done! req proc)` calls `(proc ending)` once, when the response
  is done. The ending is `written`, `client-closed` or `failed`.
- `failed` means the server ended it: with its own status in place of
  yours, or cut short after a producer raised or a body had the wrong
  length.
- The newest is called first, so an outer middleware, which registers
  first, hears last.
- Keep it quick: it can't wait. A raise from one is logged
  `on-done-failed`, and the others still run.
- A request the server refuses before any handler runs, such as a
  malformed one, calls nothing: the server logs it as `request-refused`.

See [`make-sized-body`](reference.md#make-sized-body),
[`res-wrap-body`](reference.md#res-wrap-body) and
[`req-on-done!`](reference.md#req-on-done) for the signatures.
