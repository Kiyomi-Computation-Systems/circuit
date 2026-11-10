# JSON

Read a request's JSON body as a value, and answer with JSON.

## Read a JSON body

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit json) (jsonparse easy))

;; greet : Handler — says hello to the name in a JSON body
(define (greet req)
  (if (req-json? req)
      (let ((name (json-ref (req-json req) "name" 'default "stranger")))
        (make-json-res 200 (list (cons "hello" name))))
      (make-json-res 400 '(("error" . "send a JSON body")))))

(run-server (wrap greet (wrap-json-body 65536)))
```

```text
$ curl --json '{"name": "Ada"}' http://127.0.0.1:8080/
{"hello":"Ada"}
$ curl --json '{}' http://127.0.0.1:8080/
{"hello":"stranger"}
$ curl -i --json '{"name": Ada}' http://127.0.0.1:8080/
HTTP/1.1 400 Bad Request
Date: Tue, 10 Nov 2026 01:24:39 GMT
content-type: text/plain
Content-Length: 26

unexpected-byte at byte 9
$ curl --data 'name=Ada' http://127.0.0.1:8080/
{"error":"send a JSON body"}
```

- `(wrap-json-body n)` reads the body of a request whose `content-type`
  is `application/json`, or `application/` and a name ending in `+json`,
  such as `application/problem+json`, before your handler runs.
- `(req-json? req)` says whether it read a value, and `(req-json req)` is
  the value. Ask `req-json?` first: a body of `false` is `#f`.
- A body that isn't JSON gets a `400`, with the reason and the byte where
  it stopped, and your handler never runs.
- An empty body is no JSON: your handler runs, and `req-json?` is `#f`.
- Any other request passes as it is, its body unread, as the form does
  here.
- It reads at most `n` bytes, under any cap outside it
  ([Bodies and streaming](bodies.md)). A longer body is a `413`, and your
  handler never runs. `n` is required: the server caps no body unless told
  to, and the value is held in memory whole.
- `json-ref`, from jsonparse's `(jsonparse easy)`, follows a path of keys
  and indices. With `'default` and a value, it answers that value where
  the path leads nowhere. Without one, it raises, and that is your
  handler's raise: a `500` under `wrap-catch`, never a `400`.

## What you get

| JSON | Scheme |
|:--|:--|
| object | an alist, `(("key" . value) ...)`, every key kept |
| array | a vector |
| string | a string |
| number | an exact integer when it has no fraction or exponent, else a flonum |
| `true`, `false` | `#t`, `#f` |
| `null` | the symbol `null` |

- A key sent twice is there twice, and `json-ref` takes the last.
- `{}` is `'()`, and `[]` is `#()`.

## Answer with JSON

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit json) (jsonparse easy))

(define pretty (make-json-options 'indent 2))

;; show : Handler — the path, and a few values of each kind
(define (show req)
  (make-json-res 200
                 (list (cons "path" (req-path req))
                       (cons "tags" '#("a" "b"))
                       (cons "ok" #t)
                       (cons "next" 'null))
                 pretty))

(run-server show)
```

```text
$ curl -i http://127.0.0.1:8080/items
HTTP/1.1 200 OK
Date: Tue, 10 Nov 2026 01:25:01 GMT
content-type: application/json
Content-Length: 86

{
  "path": "/items",
  "tags": [
    "a",
    "b"
  ],
  "ok": true,
  "next": null
}
```

- `(make-json-res status value)` is a response whose body is the value as
  JSON, and whose `content-type` is `application/json`. Write the value as
  the table above reads it.
- Without options it writes compact JSON, on one line. Here
  `(make-json-options 'indent 2)` lays it out.
- A value JSON can't express, such as `+nan.0` or a list that isn't an
  alist, raises jsonparse's `&json-error` when you call it: a `500` under
  `wrap-catch`.

## Options

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit json) (jsonparse easy))

;; echo : Handler — answers the JSON it was sent
(define (echo req)
  (if (req-json? req)
      (make-json-res 200 (req-json req))
      (make-res 204 '() #f)))

(run-server (wrap echo (wrap-json-body 65536 (make-json-options 'depth-limit 2))))
```

```text
$ curl --json '[[1, 2.5e3, false]]' http://127.0.0.1:8080/
[[1,2500.0,false]]
$ curl --json '[[[1]]]' http://127.0.0.1:8080/
nesting-too-deep at byte 3
```

`(wrap-json-body n options)` reads under jsonparse's options, made by
`make-json-options`:

- `'depth-limit`: how many arrays and objects may be open at once, 512
  by default.
- `'number-mode`: `'flonum`, the default; `'exact`, so `1.5` is `3/2`; or
  `'text`, which keeps each number's digits.
- `'digit-limit`: how many digits a number may have, 1000 by default.
- `'object-mode`: `'alist`, the default, or `'hashtable`, keyed by string,
  the last key sent twice winning.
- `'null`: what `null` reads as, the symbol `null` by default.

jsonparse's [tree.md](https://github.com/Kiyomi-Computation-Systems/jsonparse/blob/v0.1.0/docs/tree.md)
and [string.md](https://github.com/Kiyomi-Computation-Systems/jsonparse/blob/v0.1.0/docs/string.md)
say more. Options `read-json` refuses, such as `'stream 'values`, are
refused when you call `wrap-json-body`.

## Where it goes

- Put `wrap-json-body` inside every cap: in `(wrap app ...)`, before any
  `wrap-body-cap`. A cap inside it comes after the body is read, and every
  JSON request gets a `500`.
- In a router, put it in the group of the routes that take JSON, inside
  the group's cap if it has one ([Routing](routing.md)).
- Wrap it once. `wrap-form-params` can go beside it: each reads only its
  own type of body.

See [`wrap-json-body`](reference.md#wrap-json-body),
[`req-json`](reference.md#req-json) and
[`make-json-res`](reference.md#make-json-res) for the signatures.
