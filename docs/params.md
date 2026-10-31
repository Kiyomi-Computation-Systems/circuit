# Query strings and forms

Read a request's query, and the fields an HTML form sends, as name and
value pairs.

## Read the query

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit params))

(define (app req)
  (let* ((query (req-query-params req))
         (q (param-value query "q"))
         (tags (param-values query "tag")))
    (make-res 200 '(("content-type" . "text/plain; charset=utf-8"))
              (string-append "q: " (or q "none") ", "
                             (number->string (length tags)) " tags\n"))))

(run-server app)
```

```text
$ curl 'http://127.0.0.1:8080/search?q=caf%C3%A9+au+lait&tag=a&tag=b'
q: café au lait, 2 tags
$ curl http://127.0.0.1:8080/search
q: none, 0 tags
$ curl 'http://127.0.0.1:8080/search?Q=x&q=%E2%9C%93&q=y'
q: ✓, 0 tags
```

- `(req-query-params req)` reads the query into a list of
  `(name . value)` strings, in order. A name given twice is there twice.
  With no query, the list is `'()`.
- `(param-value params name)` is the first value of that name, or `#f`.
  `(param-values params name)` is every value of it, in order.
- A name matches in its case: `Q` is not `q`.

## Read a form

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit params))

(define (app req)
  (let ((name (param-value (req-form-params req) "name")))
    (make-res 200 '(("content-type" . "text/plain; charset=utf-8"))
              (string-append "hello, " (or name "stranger") "\n"))))

(run-server (wrap app (wrap-form-params 1024)))
```

```text
$ curl --data 'name=Ada+Lovelace' http://127.0.0.1:8080/
hello, Ada Lovelace
$ curl --data-urlencode 'name=Zoë' http://127.0.0.1:8080/
hello, Zoë
$ curl -H 'content-type: application/json' --data '{"name": "Ada"}' http://127.0.0.1:8080/
hello, stranger
$ curl -i --data "name=$(head -c 2000 /dev/zero | tr '\0' a)" http://127.0.0.1:8080/
HTTP/1.1 413 Content Too Large
Date: Sat, 31 Oct 2026 18:05:19 GMT
Content-Length: 0
Connection: close

```

- `(wrap-form-params n)` reads the body of a request whose `content-type`
  is `application/x-www-form-urlencoded`, what an HTML form sends, before
  your handler runs. `(req-form-params req)` reads its pairs.
- It reads at most `n` bytes, under any cap outside it
  ([Bodies and streaming](bodies.md)). A longer body is a `413`, and your
  handler never runs. `n` is required: the server caps no body unless told
  to, and a form is held in memory whole. Parsed, a form of many short
  pairs takes up to about 25 times its size: choose `n` for that.
- Once it has read the body, `req-body` reads eof.
- Any other request passes as it is, its body unread, and
  `req-form-params` is `'()`. A file upload, `multipart/form-data`, is one:
  circuit doesn't read those yet. So is a request with two `content-type`
  fields.
- The query and the form are two lists. Unlike Ring's `:params`, circuit
  doesn't merge them, so you know where a value came from.

## Where it goes

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit router) (circuit params))

(define (signup req)
  (let ((name (param-value (req-form-params req) "name")))
    (make-res 200 '(("content-type" . "text/plain; charset=utf-8"))
              (string-append "welcome, " (or name "stranger") "\n"))))

(run-server
 (wrap (make-router
        (list (group "/signup" (list (wrap-form-params 1024))
                (route "" (POST signup)))))
       (wrap-body-cap 65536)))
```

```text
$ curl --data name=Ada http://127.0.0.1:8080/signup
welcome, Ada
$ curl -i --data name=Ada http://127.0.0.1:8080/nowhere
HTTP/1.1 404 Not Found
Date: Sat, 31 Oct 2026 18:29:13 GMT
Content-Length: 0
Connection: close

```

- Put `wrap-form-params` inside every cap: in `(wrap app ...)`, before any
  `wrap-body-cap`. A cap inside it comes after the body is read, and every
  form gets a `500`, from `req-with-body-cap`'s assertion violation.
- In a router, put it in the group of the routes that take forms, inside
  the group's cap if it has one ([Routing](routing.md)). Then a form sent
  to any other path is never read: `/nowhere` is a `404`.
- Wrap it once. A second `wrap-form-params` finds the body's port made, an
  assertion violation, and so does one inside a middleware that called
  `req-body`.

## How a value is read

```scheme
(import (rnrs) (circuit params))

(display (params->string '(("q" . "café au lait") ("tag" . "a&b"))))
(newline)
(write (parse-params (string->utf8 "q=caf%C3%A9+au+lait&tag=a%26b&odd=100%&bad=%FF")))
(newline)
```

```text
q=caf%C3%A9+au+lait&tag=a%26b
(("q" . "café au lait") ("tag" . "a&b") ("odd" . "100%") ("bad" . "�"))
```

- Both readers use the parser browsers use, WHATWG URL's
  `application/x-www-form-urlencoded`, so a value reads as a page's
  `URLSearchParams` reads it.
- `+` is a space, and `%2B` a `+`. `%C3%A9` is é: an escape is a byte, and
  the bytes are UTF-8.
- It never fails. A `%` that starts no escape stays a `%`, and bytes that
  are no UTF-8 read as U+FFFD, `�`. Check a value yourself when it matters.
- A form's `charset` is ignored: browsers send UTF-8 from a UTF-8 page.
- `(parse-params bytes)` reads any bytes so. For a string, give its UTF-8:
  `(parse-params (string->utf8 s))`.
- `(params->string params)` writes pairs as a browser does: a space as `+`,
  and anything but letters, digits, `*`, `-`, `.` and `_` escaped. Use it
  for a link's query, or a test's form.

## Test with params

```scheme
(import (rnrs) (circuit) (circuit test) (circuit params))

(define (app req)
  (make-res 200 '(("content-type" . "text/plain; charset=utf-8"))
            (string-append (or (param-value (req-query-params req) "q") "none") ", "
                           (or (param-value (req-form-params req) "name") "none") "\n")))

(define handler (wrap app (wrap-form-params 1024)))

(define (show req)
  (display (utf8->string (res-body->bytevector (handler req)))))

(show (make-test-req 'GET (string-append "/?" (params->string '(("q" . "café"))))))
(show (make-test-req 'GET "/?q=caf\xE9;"))
(show (make-test-req 'POST "/"
                     '(("content-type" . "application/x-www-form-urlencoded"))
                     (params->string '(("name" . "Ada Lovelace")))))
```

```text
café, none
caf�, none
none, Ada Lovelace
```

- Write a value past ASCII escaped, as a browser sends it, or build the
  query with `params->string`. The server answers a target holding a byte
  past ASCII `400`, so only a test can hold one. In a test's target, a raw
  `é` is the one byte `E9`, which is no UTF-8 on its own.
- A test request reads its body whatever its cap. To test a form's cap,
  run it in the server's test host ([Testing handlers](testing.md)).

See [`req-query-params`](reference.md#req-query-params),
[`wrap-form-params`](reference.md#wrap-form-params),
[`req-form-params`](reference.md#req-form-params),
[`param-value`](reference.md#param-value),
[`param-values`](reference.md#param-values),
[`parse-params`](reference.md#parse-params) and
[`params->string`](reference.md#params-string) for the signatures.
