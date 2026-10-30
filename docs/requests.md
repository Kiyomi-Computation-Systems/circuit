# Requests and responses

A handler takes a request, a `req`, and returns a response, a `res`. Here
you read a request, keep values on it, change it, and make a response.

## Read a request

```scheme
(import (rnrs) (circuit) (circuit http-server))

;; line : String Any -> String — LABEL, then VALUE as write writes it
(define (line label value)
  (call-with-string-output-port
   (lambda (p) (put-string p label) (put-string p " ") (write value p) (newline p))))

(define (app req)
  (make-res 200 '(("content-type" . "text/plain"))
            (string-append
             (line "method " (req-method req))
             (line "path   " (req-path req))
             (line "query  " (req-query req))
             (line "host   " (req-host req))
             (line "scheme " (req-scheme req))
             (line "version" (req-http-version req))
             (line "x-tag  " (req-header req "X-Tag"))
             (line "x-tags " (req-header-values req "x-tag"))
             (line "headers" (req-headers req))
             (line "remote " (list (req-remote-address req) (req-remote-port req)))
             (line "local  " (list (req-local-address req) (req-local-port req))))))

(run-server app)
```

```text
$ curl -H 'X-Tag: a' -H 'X-Tag: b' 'http://127.0.0.1:8080/a%20b?x=1&y'
method  GET
path    "/a%20b"
query   "x=1&y"
host    "127.0.0.1:8080"
scheme  http
version (1 . 1)
x-tag   "a"
x-tags  ("a" "b")
headers (("host" . "127.0.0.1:8080") ("user-agent" . "curl/8.20.0") ("accept" . "*/*") ("x-tag" . "a") ("x-tag" . "b"))
remote  ("127.0.0.1" 57096)
local   ("127.0.0.1" 8080)
```

- `req-path` is the path as it came: `%20` stays `%20`. `req-query` is what
  follows the first `?`, or `#f` when there is none. Circuit parses neither
  a query nor a form body:
  [middleware.sps](../examples/middleware.sps) splits a query by hand.
- `req-header` finds a name in any case, and answers the first field, or
  `#f`. `req-header-values` answers every one, in order. `req-headers` is
  all of them, in order, each name in lower case.
- A header's value is one character a byte (Latin-1), so a UTF-8 `é` reads
  as two characters.
- `req-scheme` is `http`, since the server has no TLS, until middleware
  changes it. `req-host` is `""` when the request names no host.
- The addresses are the connection's two ends, or `#f` where it can't say.
  Behind a proxy, the remote end is the proxy (the server's
  [Deploying](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.9.1/docs/deploying.md#behind-a-proxy)).

## Keep values on a request

Middleware passes values to the handlers inside it on the request, under a
key. The snippets from here on make their requests with `make-test-req`,
from `(circuit test)`, which needs no server ([Testing handlers](testing.md)).

```scheme
(define user-key (make-req-key 'user))

(define req (make-test-req 'GET "/"))
(define with-user (req-set req user-key "ann"))

(req-ref with-user user-key)      ; => "ann"
(req-ref req user-key)            ; => #f
(req-ref req user-key "guest")    ; => "guest"
```

- `(make-req-key name)` makes a key no other call makes, whatever its name,
  so two libraries can't clash. The name is for you to read.
- `(req-set req key value)` answers a new request that holds the value.
  `req` is unchanged.
- `(req-ref req key)` answers the newest value set, or `#f`. A third
  argument answers instead of `#f`.
- A library exports a reader, such as `req-user`, and keeps its key to
  itself. [Middleware](middleware.md) has one.

## Change a request

```scheme
(define req (make-test-req 'POST "/api/users?page=2"))
(define new (req-with-path (req-with-method req 'DELETE) "/users"))

(req-method new)    ; => DELETE
(req-path new)      ; => "/users"
(req-query new)     ; => "page=2"
(req-method req)    ; => POST
```

- Each `req-with-` helper answers a copy with one field changed:
  `req-with-method`, `req-with-scheme`, `req-with-host`, `req-with-path`,
  `req-with-query`, `req-with-remote-address` and `req-with-remote-port`.
- The copy keeps the request's keys and its body.
- A value of the wrong kind is an assertion violation: a method is a
  symbol, `'DELETE`, not `"DELETE"`.

## Make a response

```scheme
(import (rnrs) (circuit) (circuit http-server))

(run-server
 (lambda (req)
   (make-res 201
             '(("content-type" . "text/plain")
               ("set-cookie" . "a=1")
               ("set-cookie" . "b=2"))
             "created\n")))
```

```text
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 201 Created
Date: Fri, 30 Oct 2026 10:56:28 GMT
content-type: text/plain
set-cookie: a=1
set-cookie: b=2
Content-Length: 8

created
```

- `(make-res status headers body)` takes them in Ring's order. The status
  is an exact integer, and the server writes its reason, `Created`.
- Headers are a list of `(name . value)` strings, sent in order, duplicates
  kept. Each character goes out as one byte (Latin-1): one past 255 gets a
  `500`.
- `make-res` changes nothing. The server adds `Date` and `Content-Length`.
  It answers `500` in place of a response that sets `content-length` or
  `transfer-encoding` itself, a `connection` other than `close`, or a
  status outside 200 to 599.
- `res-status`, `res-headers` and `res-body` read a response. `req?`,
  `res?` and `req-key?` tell a request, a response and a key from any other
  value.
  `res-with-status` and `res-with-body` answer a copy with a new status or
  body.

## Work with headers

```scheme
(define res (make-res 200 '(("Content-Type" . "text/plain") ("Set-Cookie" . "a=1")) "hi\n"))

(res-header res "content-type")
; => "text/plain"
(res-headers (res-set-header res "Content-Type" "text/html"))
; => (("content-type" . "text/html") ("Set-Cookie" . "a=1"))
(res-headers (res-add-header res "Set-Cookie" "b=2"))
; => (("Content-Type" . "text/plain") ("Set-Cookie" . "a=1") ("set-cookie" . "b=2"))
(res-headers (res-remove-header res "set-cookie"))
; => (("Content-Type" . "text/plain"))
```

- A lookup matches a name in any case. A helper that writes a name writes
  it in lower case.
- `res-set-header` puts one field in place of every field of that name,
  where the first stood, or appends it. `res-add-header` appends one and
  keeps the rest.
- Each answers a new response. `res` is unchanged.
- The same helpers work on a header list of your own: `header-value`,
  `header-values`, `header-set`, `header-add` and `header-remove`.
  `header-names-downcase` puts every name in lower case.

## The body kinds

| Body | What goes out |
|:--|:--|
| `#f` | nothing |
| a bytevector | its bytes, with their length |
| a string | its UTF-8 bytes, with their length |
| a binary input port | its bytes, with their length when Chez knows it |
| a producer, `(-> (U Bytevector Eof))` | each piece it answers, chunked |
| `(make-sized-body n body)` | `n` bytes from a producer or a port, with that length |

`res-wrap-body` changes a body on its way out, and `res-tap-body` watches
it. [Bodies and streaming](bodies.md) has each one.

See [`make-res`](reference.md#make-res) and
[`make-req-key`](reference.md#make-req-key) for the signatures.
