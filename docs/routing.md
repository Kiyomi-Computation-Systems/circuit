# Routing

A router picks a handler by the request's path, then by its method. You
give `make-router` a table of routes, and it gives you back one handler.

## Make a router

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit router))

(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

(define (list-users req) (text 200 "ann\nbob\n"))
(define (create-user req) (text 201 "created\n"))
(define (show-user req)
  (text 200 (string-append "user " (req-path-param req "id") "\n")))

(run-server
 (make-router
  (list (route "/users" (GET list-users) (POST create-user))
        (route "/users/:id" (GET show-user)))))
```

```text
$ curl http://127.0.0.1:8080/users
ann
bob
$ curl -X POST http://127.0.0.1:8080/users
created
$ curl http://127.0.0.1:8080/users/7
user 7
```

- `(circuit router)` isn't part of `(circuit)`: import it beside it.
- `(route template entry ...)` takes a template, then an entry for each
  method it answers, such as `(GET list-users)`.
- `route` and `make-router` check the table as they make it: a bad
  template raises as the program starts, not at the first request.
- The router is a plain handler: wrap it in middleware, or hand it to
  `run-server`.

The snippets below build on this program: define their handlers beside its
own, and put their routes in its table.

## Route by method

```scheme
(define (pong req)
  (text 200 (string-append "pong " (symbol->string (req-method req)) "\n")))
(define (docs req) (text 200 "docs\n"))
(define (props req) (text 200 "props\n"))

(route "/ping" (ANY pong))
(route "/docs" (GET docs) (METHOD 'PROPFIND props))
```

```text
$ curl -X PURGE http://127.0.0.1:8080/ping
pong PURGE
$ curl -X PROPFIND http://127.0.0.1:8080/docs
props
```

- `GET`, `POST`, `PUT`, `PATCH`, `DELETE` and `OPTIONS` each take the
  handler for that method.
- `(METHOD 'PROPFIND h)` takes any other method, named in upper case.
- `(ANY h)` takes every method the route doesn't list, so that route never
  answers 405.
- A route names each method once: two `GET`s raise.

## HEAD, 405 and 404

With the routes so far in one table, and a not-found handler:

```scheme
(define (not-found req) (text 404 "no such page\n"))

(make-router
 (list (route "/users" (GET list-users) (POST create-user))
       (route "/users/:id" (GET show-user))
       (route "/ping" (ANY pong))
       (route "/docs" (GET docs) (METHOD 'PROPFIND props)))
 not-found)
```

```text
$ curl -I http://127.0.0.1:8080/users
HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:46:57 GMT
content-type: text/plain
Content-Length: 8

$ curl -i -X DELETE http://127.0.0.1:8080/docs
HTTP/1.1 405 Method Not Allowed
Date: Fri, 30 Oct 2026 10:46:57 GMT
allow: GET, HEAD, PROPFIND
Content-Length: 0

$ curl http://127.0.0.1:8080/nowhere
no such page
```

- HEAD goes to the route's own `(METHOD 'HEAD h)`, else its GET, else its
  ANY. The server sends the head and drops the body.
- A method the route doesn't take gets an empty 405. Its `allow` lists the
  route's methods in the order it gives them, with HEAD right after GET.
- The path picks the route first, then the method: `DELETE /users/new` is
  `/users/new`'s 405, even beside a `/users/:id` that takes DELETE.
- A path no route takes gets an empty 404, or what your not-found handler
  answers: a handler after the table, as here.

## Answer 404, 400 and 405 yourself

```scheme
(define (bad-request req) (text 400 "bad path\n"))
(define (not-allowed req)
  (text 405 (string-append "no " (symbol->string (req-method req))
                           " on " (req-route req) "\n")))

(make-router
 (list (route "/users" (GET list-users) (POST create-user))
       (route "/users/:id" (GET show-user)))
 (on-method-not-allowed not-allowed)
 (on-bad-request bad-request)
 (on-not-found not-found))
```

```text
$ curl -i -X DELETE http://127.0.0.1:8080/users/7
HTTP/1.1 405 Method Not Allowed
Date: Sat, 31 Oct 2026 00:40:17 GMT
content-type: text/plain
allow: GET, HEAD
Content-Length: 24

no DELETE on /users/:id
$ curl http://127.0.0.1:8080/users/%FF
bad path
$ curl http://127.0.0.1:8080/nowhere
no such page
```

- After the table, `make-router` takes options, in any order, one for
  each answer:
  - `(on-not-found h)`, or `h` alone, for a path no route takes;
  - `(on-bad-request h)` for a capture that doesn't decode (see below);
  - `(on-method-not-allowed h)` for a method the route doesn't take.
- The 404 and 400 handlers get the request as it came to the router. The
  405 handler gets it with the route's match: `req-route` and
  `req-path-params` work.
- The router sets `allow` on what the 405 handler answers, replacing any it
  set: HTTP requires it.
- A group's middleware runs for none of them. Middleware around the router
  runs for all of them.
- Two options for one answer raise.

## Write a template

```scheme
(define (show-file req)
  (text 200 (string-append "user " (req-path-param req "id")
                           ", file " (req-path-param req "path") "\n")))

(route "/users/:id/files/*path" (GET show-file))
```

```text
$ curl http://127.0.0.1:8080/users/7/files/a/b.txt
user 7, file a/b.txt
```

- A template is `""` or starts with `/`, and splits at each `/` into
  segments.
- A word matches its segment exactly, case and all. The trailing slash
  counts: `/users/` isn't `/users`.
- `:name` takes one segment that isn't empty.
- `*name`, last, takes the rest after the slash before it, slashes and all,
  maybe nothing: `/files/*path` takes `/files/` and `/files/a/b`, not
  `/files`.
- A name is ASCII letters, digits, `-` and `_`, and comes once in a
  template.

## Which route wins

```scheme
(define (edit-user req)
  (text 200 (string-append "edit user " (req-path-param req "id") "\n")))
(define (new-user-form req) (text 200 "the new user form\n"))

(make-router
 (list (route "/users/:id" (GET show-user))
       (route "/users/:id/edit" (GET edit-user))
       (route "/users/new" (GET new-user-form))))
```

```text
$ curl http://127.0.0.1:8080/users/new
the new user form
$ curl http://127.0.0.1:8080/users/new/edit
edit user new
```

- When several templates match, the leftmost segment where they differ
  decides.
- A word beats a parameter, and a parameter beats a catch-all or a mount.
- The table's order never matters: `/users/new` wins though it comes last.
- The match backtracks: `/users/new/edit` goes to `/users/:id/edit`, as
  `/users/new` has no third segment.
- `make-router` refuses two templates of one shape, such as `/users/:id`
  beside `/users/:name`.

## Group routes

```scheme
(define (wrap-admin handler)
  (lambda (req)
    (res-add-header (handler req) "x-admin" "yes")))

(define (admin-home req) (text 200 "admin\n"))
(define (stats req) (text 200 "2 users\n"))

(group "/admin" (list wrap-admin)
  (route "" (GET admin-home))
  (route "/stats" (GET stats)))
```

```text
$ curl -i http://127.0.0.1:8080/admin/stats
HTTP/1.1 200 OK
Date: Fri, 30 Oct 2026 10:46:57 GMT
content-type: text/plain
x-admin: yes
Content-Length: 8

2 users
```

- `(group prefix middlewares route ...)` puts its routes under the prefix,
  joined as strings: `(route "" ...)` serves `/admin` itself.
- Its middleware wraps each handler in the group, in `wrap`'s order, once,
  when the router is made.
- It runs only for a request that matched one of its routes and a method:
  not for a 404, a 405 or a 400. Middleware around the router runs for
  every request.
- Groups nest, the outer group's middleware outermost. A group can hold
  mounts too.

## Mount a handler

```scheme
(define (assets req)
  (text 200 (string-append "path " (req-path req)
                           ", mounted at " (req-mount-path req) "\n")))

(mount "/assets" assets)
```

```text
$ curl http://127.0.0.1:8080/assets/a/b
path /a/b, mounted at /assets
$ curl http://127.0.0.1:8080/assets
path /, mounted at /assets
```

- `(mount template handler)` takes its path and every path under it,
  whatever the method: `/assets` and `/assets/a/b`, not `/assetsx`.
- The handler sees the rest of the path as `req-path`, or `/` when nothing
  follows.
- `req-mount-path` is the part the mounts took, undecoded. Nested mounts
  join, and under none it is `""`.
- A route for the same path beats a mount: route `/assets` would take
  `/assets` from it.
- Mount another router to split an app into parts.

## Read the match

```scheme
(define (show req)
  (text 200 (call-with-string-output-port
             (lambda (out)
               (write (list (req-route req) (req-path-params req)) out)
               (newline out)))))

(define users
  (make-router (list (route "/users/:id" (GET show)))))

(run-server (make-router (list (mount "/api/:v" users))))
```

```text
$ curl http://127.0.0.1:8080/api/2/users/7
("/api/:v/users/:id" (("v" . "2") ("id" . "7")))
```

- `req-route` is the template that matched, joined onto its mounts' and
  groups'. It doesn't change with the ids, so it suits logs and metrics.
  It is `#f` when no router matched.
- `req-path-params` is every capture, `(name . value)`, left to right; `'()`
  with none.
- `(req-path-param req name)` is one capture's value, or `#f`.
- These strings are the router's own, shared by every request: don't
  mutate them.

## Percent-decoding

With the first program on this page:

```text
$ curl http://127.0.0.1:8080/users/ann%20lee
user ann lee
$ curl http://127.0.0.1:8080/users/a%2Fb
user a/b
$ curl -i http://127.0.0.1:8080/users/%FF
HTTP/1.1 400 Bad Request
Date: Fri, 30 Oct 2026 10:46:58 GMT
Content-Length: 0
```

- The path is matched as the client sent it. Then each capture is
  percent-decoded, as UTF-8.
- `%2F` stays inside its segment while matching, and is a `/` in the
  value. `+` stays `+`.
- A capture that doesn't decode gets an empty 400, or your 400 handler's
  answer, and no route's handler runs. That is a bad escape, such as `%4`;
  bytes that aren't UTF-8, such as `%FF`; or a raw character a path can't
  hold, such as a space, `"` or `<`.
- A path holds raw only letters, digits,
  `- . _ ~ ! $ & ' ( ) * + , ; = : @`, and `/` between segments (RFC
  3986). The server lets no other raw character into a path, so the router
  meets one only in a path a middleware set with `req-with-path`, or a
  test's.
- A mount's rest is no capture: the router leaves it unchecked, and the
  mounted handler sees it as it came.
- `req-path` itself stays as the client sent it.

⚠️ **A decoded value is the client's.** It can hold `/` (from `%2F`), `..`,
or NUL (from `%00`). The server passes `..` segments through as sent, so
`/files/../../etc/passwd` reaches `/files/*path` with `path` as
`../../etc/passwd`. Check a value before you use it as a file name.

See [`make-router`](reference.md#make-router) for every name and its
signature, and [examples/router.sps](../examples/router.sps) for a whole
app.
