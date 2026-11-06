# Sessions

Remember a visitor between requests, in a cookie they can read but not
change.

## Sign in and out

```scheme
(import (rnrs) (only (chezscheme) getenv current-time time-second)
        (circuit) (circuit http-server) (circuit params) (circuit session)
        (circuit middleware waits))

(define (now) (time-second (current-time)))

(define (app req)
  (cond ((string=? (req-path req) "/login")
         (res-with-session (make-res 303 '(("location" . "/")) #f)
                           (list (cons "user" (or (param-value (req-query-params req) "as") "guest")))))
        ((string=? (req-path req) "/logout")
         (res-with-session (make-res 303 '(("location" . "/")) #f) '()))
        (else
         (let ((user (assoc "user" (req-session req))))
           (make-res 200 '(("content-type" . "text/plain"))
                     (if user
                         (string-append "signed in as " (cdr user) "\n")
                         "not signed in\n"))))))

(run-server
 (wrap app
       (wrap-session (list (getenv "SESSION_SECRET")) now 1209600
                     (session-name "session") (session-insecure))
       wrap-catch))
```

```text
$ export SESSION_SECRET=$(openssl rand -base64 32)
$ make run PROGRAM=session.sps
```

```text
$ curl -b jar http://127.0.0.1:8080/
not signed in
$ curl -i -c jar -b jar 'http://127.0.0.1:8080/login?as=ada'
HTTP/1.1 303 See Other
Date: Fri, 06 Nov 2026 20:03:53 GMT
location: /
set-cookie: session=user=ada.1793995433.b6a2e1ce162c526e5ea9cf11b227f9c8b367bf5f46efd358be45d9322ebc9043; Path=/; Max-Age=1209600; HttpOnly; SameSite=Lax
cache-control: private
vary: cookie
Content-Length: 0

$ curl -b jar http://127.0.0.1:8080/
signed in as ada
$ curl -i -c jar -b jar http://127.0.0.1:8080/logout
HTTP/1.1 303 See Other
Date: Fri, 06 Nov 2026 20:03:53 GMT
location: /
set-cookie: session=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Lax
cache-control: private
vary: cookie
Content-Length: 0

$ curl -b jar http://127.0.0.1:8080/
not signed in
```

A real sign-in checks a password first. This one shows the session alone.

- `(req-session req)` is the session: `(name . value)` strings, in order,
  or `'()` when there is none. Find a value with `assoc`. Keep a number or
  an id as a string.
- `(res-with-session res session)` hands one back. `wrap-session` writes
  it whole, signed, in the cookie's value. `'()` removes the cookie.
- Hand back nothing and the browser keeps the cookie it has. The max age
  counts from when the cookie was last written, so to keep someone signed
  in while they are active, hand the session back on every request.
- Put `wrap-session` inside `wrap-catch`, around the router or the routes
  that use a session. A session too big for its cookie is refused when it
  is written, and `wrap-catch` makes that a 500.

## The settings

`(wrap-session secrets clock max-age option ...)` checks each setting when
it is called, and refuses a bad one there, before any request.

- **The secrets:** a list of strings, each at least 32 bytes. Make one with
  `openssl rand -base64 32`, and keep it in the environment, never in your
  code. The first signs, and each one verifies.
- **To change the secret,** put the new one first and keep the old one
  after it, until the old cookies' max age has passed:
  `(list (getenv "SESSION_SECRET") (getenv "OLD_SESSION_SECRET"))`. A
  session read under the old one is signed with the new one the next time
  it is handed back.
- **The clock:** a procedure that answers the seconds since 1970, which
  `(time-second (current-time))` does in Chez. The cookie holds the time it
  was written. One as old as the max age is refused, and so is one more
  than 60 seconds ahead of the clock.
- **The max age:** seconds, from 1 to 34560000, the 400 days a browser
  keeps a cookie at most. It is the cookie's `Max-Age` too.
- **The cookie** is `__Host-session`, with `Path=/`, `Secure`, `HttpOnly`
  and `SameSite=Lax`. The options, each at most once, change it:
  - `(session-name "session")`: another name;
  - `(session-path "/app")` and `(session-domain "example.com")`: where the
    browser sends it. A `__Host-` name allows neither, so give another name
    with them;
  - `(session-same-site 'strict)`: `'strict`, `'lax` or `'none`;
  - `(session-insecure)`: no `Secure`, so the cookie goes over plain
    `http`, as above. For development alone. A `__Host-` name needs
    `Secure`, so give another name with it.
- `HttpOnly` is always on. No script on the page needs the cookie.

## What it adds

- **Every response gets `vary: cookie`,** unless a `vary` field already
  lists `cookie` or `*`. A cache then won't hand one visitor's page to
  another.
- **A response that sets or removes the cookie gets
  `cache-control: private`,** unless it has a `cache-control` field. A
  shared cache then won't hand one visitor's new session to the next.
- **Inside another `wrap-session`,** the inner one reads and writes, and
  the outer one leaves the response alone.

## What a signed cookie can't do

- **The visitor can read it.** Its value is the session's pairs, in plain
  text: never put a password or a secret in it.
- **The visitor can send an older cookie back while it lives.** So a
  counter, a balance or a one-time token doesn't belong in a session. To
  end a session everywhere before its max age, keep a version in it and
  check it against your own store.
- **It holds about 4 KB.** With `__Host-session`, the pairs may take 4006
  bytes, encoded. Beside the site's other cookies, a big one can push a
  request's `cookie` field past the server's 8 KiB, which it answers 431.
- **A name without `__Host-` can be planted.** A sibling host, such as
  `other.example.com`, can set a cookie of the same name for a longer
  path. One that fails the signature is skipped. But a real cookie of the
  attacker's own, copied there, is sent first and read first: the visitor
  is then signed in as the attacker. Keep `__Host-` in production.
- **Two apps on one host share their cookies,** whatever their ports. Give
  each its own name and secret.
- **A middleware inside `wrap-session` that makes a fresh response drops
  the session.** The response helpers, such as `res-add-header`, keep it.

Coming from Ring? `wrap-session` with a cookie store, but signed, not
encrypted. A handler hands the session back on the response, as Ring's
`:session` key, and `'()` ends it, as `:session nil` does.

## Test with a session

```scheme
(import (rnrs) (circuit) (circuit test) (circuit session))

(define app
  (wrap (lambda (req)
          (res-with-session (make-res 200 '() (if (assoc "seen" (req-session req)) "again" "first"))
                            '(("seen" . "yes"))))
        (wrap-session (list (make-string 32 #\x)) (lambda () 1793536476) 3600)))

;; cookie-of : Res -> String — its cookie as a browser sends it back.
(define (cookie-of res)
  (let ((field (res-header res "set-cookie")))
    (let loop ((i 0))
      (if (char=? (string-ref field i) #\;) (substring field 0 i) (loop (+ i 1))))))

(define one (app (make-test-req 'GET "/")))
(define two (app (make-test-req 'GET "/" (list (cons "cookie" (cookie-of one))))))

(display (utf8->string (res-body->bytevector one))) (newline)
(display (utf8->string (res-body->bytevector two))) (newline)
(display (cookie-of one)) (newline)
```

```text
first
again
__Host-session=seen=yes.1793536476.ac98effb7df8c78c36bc0ee61496aa0b6e26698a7d9c0a11b6be8ca6129ac0f0
```

- A clock that answers one time, and a secret written in the test, make
  the same cookie on every run.
- Send the cookie back as a browser does, in a `cookie` field.

See [`wrap-session`](reference.md#wrap-session),
[`req-session`](reference.md#req-session),
[`res-with-session`](reference.md#res-with-session),
[`session-name`](reference.md#session-name),
[`session-path`](reference.md#session-path),
[`session-domain`](reference.md#session-domain),
[`session-same-site`](reference.md#session-same-site) and
[`session-insecure`](reference.md#session-insecure) for the signatures.
