# Cookies

Read the cookies a browser sends, and set and remove them.

## Read and set a cookie

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit cookies))

(define (app req)
  (cond ((string=? (req-path req) "/dark")
         (res-add-cookie (make-res 303 '(("location" . "/")) #f)
                         "__Host-theme" "dark"
                         (cookie-path "/") (cookie-secure) (cookie-http-only)
                         (cookie-same-site 'lax) (cookie-max-age 2592000)))
        ((string=? (req-path req) "/light")
         (res-expire-cookie (make-res 303 '(("location" . "/")) #f)
                            "__Host-theme" (cookie-path "/") (cookie-secure)))
        (else
         (make-res 200 '(("content-type" . "text/plain"))
                   (string-append "theme: " (or (req-cookie req "__Host-theme") "light")
                                  ", " (number->string (length (req-cookies req)))
                                  " cookies\n")))))

(run-server app)
```

```text
$ curl http://127.0.0.1:8080/
theme: light, 0 cookies
$ curl -b '__Host-theme=dark; lang=en' http://127.0.0.1:8080/
theme: dark, 2 cookies
$ curl -i http://127.0.0.1:8080/dark
HTTP/1.1 303 See Other
Date: Sat, 31 Oct 2026 19:19:03 GMT
location: /
set-cookie: __Host-theme=dark; Path=/; Max-Age=2592000; Secure; HttpOnly; SameSite=Lax
Content-Length: 0

$ curl -i http://127.0.0.1:8080/light
HTTP/1.1 303 See Other
Date: Sat, 31 Oct 2026 19:19:03 GMT
location: /
set-cookie: __Host-theme=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure
Content-Length: 0

```

- `(req-cookies req)` is every cookie the request sends, as
  `(name . value)` strings, in order. A name sent twice is there twice.
- `(req-cookie req name)` is the first value of that name, or `#f`. A name
  matches in its case.
- A browser sends two cookies of one name when they were set for two
  paths or domains, in no order you can rely on. A `__Host-` name has one
  path and no domain, so it has one value. For the rest, read
  `req-cookies`.
- A value reads as it was sent: its quotes kept, nothing decoded, nothing
  checked.
- `(res-add-cookie res name value option ...)` adds one `set-cookie` field
  and keeps the response's others. Write each name once a response:
  RFC 6265bis asks a server not to send two.
- The options, each at most once, in any order:
  - `(cookie-path "/")`: the paths it is sent to;
  - `(cookie-domain "example.com")`: that host and its subdomains too;
  - `(cookie-max-age seconds)`, at least 1: how long the browser keeps it;
    without one, for the browser's session;
  - `(cookie-secure)`: sent over `https` alone;
  - `(cookie-http-only)`: no script on the page can read it;
  - `(cookie-same-site 'lax)`: sent from your own site's pages, and when a
    link from another site is followed. `'strict` is your pages alone, and
    `'none` other sites' requests too.
- `(res-expire-cookie res name option ...)` removes a cookie. A browser
  removes it only when the path and domain match the ones it was set with,
  so give the same. Give a path whenever you set one: without it, the
  browser takes the path of the page that set it, which a `/logout` page
  won't match. It writes a date in 1970, so it needs no clock.

Coming from Ring? There is no `wrap-cookies`: `req-cookies` reads the
field when you ask. Values aren't URL-decoded, and a response has no
`:cookies` key: `res-add-cookie` writes the field.

## What it refuses

```scheme
(import (rnrs) (circuit) (circuit cookies))

(define res (make-res 200 '() #f))

(define (try thunk)
  (guard (e ((assertion-violation? e) (display (condition-message e)) (newline)))
    (write (res-headers (thunk)))
    (newline)))

(try (lambda () (res-add-cookie res "name" "Zoë Ada")))
(try (lambda () (res-add-cookie res "__Host-id" "abc" (cookie-secure))))
(try (lambda () (res-add-cookie res "id" "abc" (cookie-same-site 'none))))
(try (lambda () (res-add-cookie res "name" "Wm_DqyBBZGE" (cookie-max-age 3600))))
```

```text
a cookie value is cookie-octets, bare or between two quotes: encode a space, a quote, a comma, a semicolon, a backslash, a control or anything past ASCII first
a __Host- name needs cookie-secure and (cookie-path "/"), and no cookie-domain: a browser ignores the cookie otherwise
SameSite=None needs cookie-secure: a browser ignores the cookie without it
(("set-cookie" . "name=Wm_DqyBBZGE; Max-Age=3600"))
```

A browser drops many bad cookies without a word. Circuit refuses these
when you write one, an assertion violation:

- A name is letters, digits and ``!#$%&'*+-.^_`|~``.
- A value is ASCII letters, digits and punctuation, but no `"`, `,`, `;`
  or `\`, and no space; or that between two quotes, which stay part of the
  value. Encode anything else first. base64url's letters, digits, `-` and
  `_` are all allowed: `Wm_DqyBBZGE` is `Zoë Ada`.
- A name and its value are 4096 bytes at most together, and a path or a
  domain 1024.
- A path starts with `/`, and holds nothing a URL's path escapes: no
  space, `"`, `#`, `<`, `>`, `?`, `^`, `` ` ``, `{`, `}` or `\`.
- A domain is a host alone: `example.com`, never `localhost:8080`,
  `https://example.com` or `example.com/`.
- A path or a domain is ASCII, with no `;` and no control. A max-age is a
  whole number, at least 1.
- A `__Secure-` name needs `(cookie-secure)`. A `__Host-` name needs
  `(cookie-secure)`, `(cookie-path "/")` and no domain. A browser checks
  these in any case, so `__HOST-` is one too.
- `(cookie-same-site 'none)` needs `(cookie-secure)`.

## Test with cookies

```scheme
(import (rnrs) (circuit) (circuit test) (circuit cookies))

(define (app req)
  (res-add-cookie (make-res 200 '() (or (req-cookie req "seen") "first"))
                  "seen" "yes" (cookie-path "/") (cookie-http-only)))

(define (show req)
  (let ((res (app req)))
    (write (header-values (res-headers res) "set-cookie"))
    (display " ")
    (display (utf8->string (res-body->bytevector res)))
    (newline)))

(show (make-test-req 'GET "/"))
(show (make-test-req 'GET "/" '(("cookie" . "lang=en; seen=yes"))))
```

```text
("seen=yes; Path=/; HttpOnly") first
("seen=yes; Path=/; HttpOnly") yes
```

- Send a cookie as a browser does, in a `cookie` field:
  `name=value; name=value`.
- `(header-values (res-headers res) "set-cookie")` is every field the
  response sets, in order.

See [`req-cookies`](reference.md#req-cookies),
[`req-cookie`](reference.md#req-cookie),
[`res-add-cookie`](reference.md#res-add-cookie),
[`res-expire-cookie`](reference.md#res-expire-cookie),
[`cookie-path`](reference.md#cookie-path),
[`cookie-domain`](reference.md#cookie-domain),
[`cookie-max-age`](reference.md#cookie-max-age),
[`cookie-secure`](reference.md#cookie-secure),
[`cookie-http-only`](reference.md#cookie-http-only) and
[`cookie-same-site`](reference.md#cookie-same-site) for the signatures.
