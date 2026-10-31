# Slice 9 design: CORS and security headers, params, and cookies

Approved by the owner on 2026-10-31; the circuit design's §15.30 records it. It builds
on the circuit design
([2026-10-24-circuit-design.md](2026-10-24-circuit-design.md)): §3 for the request's
keys, §5 for headers and bodies, §6 for middleware, §11 for the libraries, §17 for the
slices. Sessions come after it, as a design of their own (§7). §8 records the owner's
answers.

## 1. Order

Slice 9 is three PRs, in the order the owner chose on 2026-10-31, building towards
sessions:

1. **9a, CORS and security headers:** `(circuit middleware cors)` and
   `(circuit middleware headers)`.
2. **9b, params:** `(circuit params)`, the query and urlencoded forms.
3. **9c, cookies:** `(circuit cookies)`, read from the request and written on the
   response.

None needs another, so the order is the owner's, not the code's. Each PR adds its entries
to `CHANGELOG.md`'s Unreleased; a release after 9c is the owner's call.

Left out on 2026-10-31: Ring's `content-type` (the owner, for now), and `content-length`
and `head`, which circuit doesn't need. The server already sends `Content-Length` for a
body with a length, and refuses an app's own with a 500 (design §5). The router hands a
HEAD to the route's GET, and the server sends no body for a HEAD. A note for apps coming
from Ring says so on the middleware page.

## 2. What the three share

- **Each is a core library: plain R6RS, importing no server.** `make check-imports` holds
  that unchanged: every library but the three it names is core (its rule (b)). ADR-0006
  doesn't move.
- **The facade `(circuit)` re-exports none of them,** as it doesn't the router. An app
  imports what it uses.
- **Each joins `tests/test-reference.sps`'s public libraries,** with a section in
  `docs/reference.md` in that order, and every export a signature comment. The suite and
  the docs say "six public libraries", and each slice moves the count.
- **Settings come in as arguments, checked when given.** A bad one is an assertion
  violation, raised when the middleware is made or the helper called, never at a
  request. The core can't read the environment (`getenv` is Chez's), so an app that keeps
  a setting there reads it and passes it in.
- **Options are constructor procedures,** as the router's are: `(cors-max-age 600)`,
  `(cookie-secure)`. Each checks its argument and names it. An option given twice, or
  bare where its call was meant, is refused.
- **Middleware only where something must happen around the handler.** Ring needs
  `wrap-cookies` because a request is a map. Here a reader that parses the header when
  asked does the same with no middleware: the query and cookies are readers; the form,
  which must read the body once, is middleware.
- **Data a middleware adds goes under a key of its library's own,** read through an
  exported reader (design §3).
- **No cost gate row.** None of these runs unless an app wraps or calls it. The gate's
  rows stay as they are.

### What circuit takes, and leaves

| From | Taken | Why |
|:--|:--|:--|
| Ring | a library per concern | an app imports only what it uses |
| Ring `params` | the query and an urlencoded form, parsed into pairs; the form read before the handler | the body can be read once |
| Ring `cookies` | the request's cookies as name and value pairs | the common case, with no map |
| ring-cors | an allowlist of origins, and the preflight answered by the middleware | the router would answer a preflight 405 |
| ring-headers, ring-ssl | `nosniff`, frame options, HSTS | the headers every app should send |

| Left | Why |
|:--|:--|
| Ring's merged `:params`, query and form in one map | which one wins is a trap; two readers say where a value came from |
| keyword and nested params, `a[b]=c` | Clojure's maps; an app can fold the pairs itself |
| cookie values form-decoded and encoded by default | a decoder misreads a cookie another system set; circuit refuses a value a cookie can't hold instead |
| `{:cookies ...}` on the response | circuit's response has no keys; `res-add-cookie` writes the field |
| a regex for origins | R6RS has no regex; a predicate |
| `Expires` | the core has no clock; `Max-Age` covers it and wins over it (RFC 6265bis §5.7) |
| `X-XSS-Protection` | browsers removed the filter it controlled |

## 3. CORS (9a)

### Its surface

```scheme
;; (circuit middleware cors)
;; wrap-cors : CorsOption ... -> Middleware
;; cors-origins : String String ... -> CorsOption      ; exact origins
;; cors-origin-when : (String -> Any) -> CorsOption    ; an origin the predicate takes
;; cors-any-origin : -> CorsOption                     ; *
;; cors-methods : Symbol Symbol ... -> CorsOption      ; Access-Control-Allow-Methods
;; cors-headers : String String ... -> CorsOption      ; Access-Control-Allow-Headers
;; cors-any-header : -> CorsOption                     ; the preflight's own list, echoed
;; cors-expose-headers : String String ... -> CorsOption
;; cors-credentials : -> CorsOption                    ; Access-Control-Allow-Credentials
;; cors-max-age : Nat -> CorsOption                    ; seconds
```

```scheme
(run-server
 (wrap router
       wrap-catch
       (wrap-cors (cors-origins "https://app.example")
                  (cors-methods 'PUT 'DELETE)
                  (cors-headers "content-type" "x-api-key")
                  (cors-credentials))
       wrap-log))
```

- **Exactly one origin option,** and each option at most once. `cors-credentials` with
  `cors-any-origin` is refused: Fetch never shares a credentialed response under `*`
  (§3.3.5).
- **A method is a symbol,** as `req-method` answers and the router takes. It is written as
  given, since a method is case-sensitive. Fetch upper-cases only `DELETE`, `GET`,
  `HEAD`, `OPTIONS`, `POST` and `PUT` (its "normalize a method"), so a script's `patch`
  stays `patch` and never matches `PATCH`. The docs say so.
- **A header name is a token, written in lower case.**
- **With no `cors-methods` or `cors-headers`, the preflight lists none.** The browser then
  allows only what Fetch safelists: `GET`, `HEAD` and `POST`, and the safelisted headers.

### Origins

- **A listed origin must be one a browser sends:** `scheme://host` or
  `scheme://host:port`.
  - The scheme and host are in lower case. The host holds letters, digits, `-`, `.` and
    `_`, or is an IPv6 address in brackets.
  - There is no path, no trailing `/`, and no default port (`:80` for `http`, `:443` for
    `https`).
  - Anything else is refused when the option is made. A browser serializes an origin this
    way (HTML's "serialization of an origin"), so `https://app.example/` or
    `https://App.example` would never match, and the mistake would show only in a
    browser.
- **`null` is never an origin wrap-cors allows,** whatever the option.
  - A sandboxed iframe, a `file:` page and some redirects send `null`. Any page can make
    one, so allowing it allows everyone.
  - `cors-origins` refuses `"null"`, and the predicate is never asked about it.
  - `cors-any-origin`'s `*` is the way to allow everyone.
- **The predicate is asked only about an Origin of that shape.** So a check such as "ends
  in `.example.com`" can't be passed by `https://evil.test/.example.com`. The docs show
  that check with its leading dot: `https://evilexample.com` ends in `example.com`.
- **A request with two or more Origin fields matches no origin.**

### The rules

A request's Origin matches when it is a single field that the origin option allows. A
**preflight** is an `OPTIONS` request whose Origin matches, carrying one
`Access-Control-Request-Method` field (Fetch §3.3.2). An `OPTIONS` request without that
field is an ordinary request.

- **A preflight is answered by wrap-cors itself, `204`,** and never reaches the handler.
  Its fields are, in this order:
  - `access-control-allow-origin`: the origin, or `*` for `cors-any-origin`;
  - `access-control-allow-credentials: true`, with `cors-credentials`;
  - `access-control-allow-methods`, the methods joined by `, `, when given;
  - `access-control-allow-headers`, when given or echoed;
  - `access-control-max-age`, when given;
  - `vary` (below).
- **wrap-cors doesn't check the preflight's method or headers against its lists.** The
  browser does that with the lists the preflight answers. A server-side check would only
  move the same refusal earlier.
- **`cors-any-header` echoes the preflight's `Access-Control-Request-Headers`.** It must
  be one field, a comma-separated list of tokens. Otherwise no
  `access-control-allow-headers` is sent, and the browser refuses.
  - The echo works with credentials and without. Fetch's `*` covers neither credentialed
    requests (§3.3.4) nor `Authorization` (§2.2.2, a "CORS non-wildcard request-header name"),
    so circuit doesn't send `*` here.
- **Any other request goes to the handler, and its response gets the fields.**
  - With an origin list or a predicate, and an Origin that matches: the origin,
    `access-control-allow-credentials: true` with `cors-credentials`, and
    `access-control-expose-headers` when given.
  - With `cors-any-origin`: `*` on every response, whether the request has an Origin or
    not, and the expose list. Fetch asks for this when the answer is `*` (its "CORS
    protocol and HTTP caches"), so no `Vary` is needed.
  - wrap-cors's fields replace any of the same name the handler set.
- **A preflight whose Origin doesn't match goes to the handler,** as any request does.
  Behind a router it gets the router's 405, or the route's own `OPTIONS` answer. Either
  way it carries no CORS fields, and the browser refuses.

### Vary

With an origin list or a predicate, the answer depends on the Origin. So **every
response wrap-cors passes carries `Vary: Origin`**: a match, a miss, a request with no
Origin, and a preflight.

Fetch gives the reason. Without it, a cache can keep a response made for no Origin, which
has no `access-control-allow-origin`, and hand it to a CORS request later.

A preflight that echoes the request's headers also varies on
`Access-Control-Request-Headers`.

wrap-cors adds `origin` to a response's `vary` unless one of its `vary` fields already
lists it, in any case, or is `*`. It adds `origin` as a field of its own, which RFC 9110
§5.3 allows for a list.

### Where it goes in the stack

- **Outside the router.** A group's middleware runs only for a request whose path and
  method matched (slice 6 design §5), so a group's wrap-cors never sees a preflight
  unless the route has its own `OPTIONS` or `ANY`. The docs say to wrap the router.
- **Outside `wrap-catch` and `wrap-timeout`,** so their `500` and `504` carry the fields.
  A browser shown a `500` with no `access-control-allow-origin` reports a CORS error,
  not the `500`.
- **Inside `wrap-log`,** which then logs the preflights wrap-cors answers.
- **WebSockets aren't CORS.** A browser's handshake sends an Origin but doesn't preflight
  it or read these fields. A WebSocket handler checks the Origin itself; the upgrades page
  says so. A `101` that passes wrap-cors gets the fields, which do nothing: the response
  stays an upgrade (`res-set-header` keeps it one).

## 4. Security headers (9a)

### Its surface

```scheme
;; (circuit middleware headers)
;; wrap-default-headers : Headers -> Middleware
;; security-headers : Headers
;; wrap-hsts : Nat HstsOption ... -> Middleware      ; max-age in seconds
;; hsts-include-subdomains : -> HstsOption
```

```scheme
(wrap app (wrap-default-headers security-headers) (wrap-hsts 31536000))
```

- **`wrap-default-headers` adds each field the response lacks.** The fields are matched
  by name, in any case, and added after the handler's own, in the list's order. A handler
  that sets its own `x-frame-options` keeps it. The list is checked as headers when given.
- **`security-headers` is the list:**

  | Field | Value | Why |
  |:--|:--|:--|
  | `x-content-type-options` | `nosniff` | a browser takes the declared type, never a sniffed one |
  | `x-frame-options` | `SAMEORIGIN` | no other site frames the page; ring-defaults' and helmet's default |
  | `referrer-policy` | `strict-origin-when-cross-origin` | another site sees the origin, never the path |

  A content security policy, `cross-origin-opener-policy` and `permissions-policy` depend
  on the app, so the list leaves them out. An app adds them in a list of its own, after
  this one.
- **`wrap-hsts` sends `strict-transport-security` on an `https` request alone.** RFC 6797
  §7.2 says a host MUST NOT send it over plain HTTP. That's why it is a middleware of its
  own, reading `req-scheme`.
  - Behind a proxy that ends TLS, `req-scheme` is `http` unless a middleware outside
    wrap-hsts believes the proxy, as the middleware page's `wrap-proxy` does.
  - The value is `max-age=N`, with `; includeSubDomains` for `hsts-include-subdomains`.
  - `preload` is left out. The preload list has its own rules, and joining it is hard to
    undo.
- **The middleware page's own `wrap-hsts` example gives way to the shipped one.** The
  page keeps its example of changing a response, but shows it with another header.

### Testing (9a)

- **`tests/test-cors.sps` holds each rule above by example,** each asserting the
  response's whole header list, in order. A counter in the handler shows a preflight
  never reaches it.
- **The origin check is tested against its whole complement.** Each case below must miss
  an allowed `https://app.example`:
  - a different scheme, port, or case;
  - a trailing `/`, or a path;
  - a prefix or a suffix (`https://app.example.evil`, `https://evilapp.example`);
  - `null`;
  - two Origin fields.
- **Every refused option has its own sentinel:** `*` with credentials, a malformed origin,
  `"null"`, an option twice, and a constructor given bare.
- **`Vary` rows:** none on a response yet; one with `vary: accept`; one already listing
  `Origin`; one with `*`.
- **`tests/test-headers-middleware.sps`** holds `wrap-default-headers`'s rule against a
  field set in another case. It holds `wrap-hsts` on `http` and `https`, and its max-age
  as a bignum as well as a fixnum.
- **Each new row is watched failing,** under a mutant that breaks the rule it holds.

## 5. Params (9b)

### Its surface

```scheme
;; (circuit params)
;; Params = (Listof (Pair String String))       ; in order, duplicates kept
;; req-query-params : Req -> Params
;; wrap-form-params : Nat -> Middleware          ; the most bytes it reads
;; req-form-params : Req -> Params
;; param-value : Params String -> (U String #f)  ; the first of that name
;; param-values : Params String -> (Listof String)
;; parse-params : Bytevector -> Params
;; params->string : Params -> String
```

```scheme
(define (search req)
  (let ((q (param-value (req-query-params req) "q")))
    (make-res 200 '(("content-type" . "text/plain")) (or q "nothing"))))

(wrap (route-table ...) (wrap-form-params 65536))
```

- **Names match exactly.** A param's name is data, unlike a header's, so `param-value`
  doesn't fold case.
- **`req-query-params` parses `req-query` each time it is asked,** so a middleware that
  rewrites the query with `req-with-query` is seen. A request with no query answers `'()`.

### Decoding

**Both readers use the urlencoded parser of WHATWG's URL standard (§5.1), the one
browsers and `URLSearchParams` use:**
1. Split on `&`, skipping empty pieces.
2. Split each at its first `=`. A piece with none is a name with an empty value.
3. Read `+` as a space.
4. Percent-decode.
5. Decode as UTF-8 without a BOM.

This parser never fails:
- A `%` that starts no escape stays a `%`.
- Bytes that aren't UTF-8 become U+FFFD.

That differs from the router, which answers a capture that doesn't decode with 400. A
path names a resource, and a malformed one names none. A param is data the handler
judges. The owner chose it (§8.1).

- **The query's characters are its bytes.** The server reads the request target as
  Latin-1, one character a byte, so `req-query-params` turns each character back into its
  byte before parsing.
  - A raw UTF-8 `é`, as curl sends it, reads as `é`.
  - A character past 255 can be in a query only if code put it there. It is an assertion
    violation.
  - So a test writes a non-ASCII value percent-encoded, as a browser sends it. The
    Testing page says so.
- **`parse-params` takes bytes,** so a string can't be read two ways. An app with a
  string calls `(parse-params (string->utf8 s))`.
- **circuit decodes UTF-8 itself, by the Encoding standard's decoder.** Chez's
  `utf8->string` differs from it on malformed bytes. A probe on 2026-10-31
  (`build/probe-utf8/`) found:

  | Bytes | Chez | WHATWG |
  |:--|:--|:--|
  | `C0 AF`, an overlong `/` | one U+FFFD | two |
  | `ED A0 80`, a surrogate | one U+FFFD | three |
  | `EF BB BF 41`, a BOM, then `A` | `A` | U+FEFF `A` ("without BOM" keeps it) |

  A value that reads differently from what the browser's own `URLSearchParams` read is a
  bug an app can't see. The decoder is small, and is checked against the same
  vectors.
- **`params->string` is WHATWG's serializer (§5.2):** UTF-8, the urlencoded
  percent-encode set, a space as `+`, and pairs joined by `&`. Apps build query strings
  and test bodies with it, and it gives the property suite its round trip.

### The form

- **`wrap-form-params` reads a form body before the handler.**
  - It reads one only when the request's `content-type` is
    `application/x-www-form-urlencoded`: the media type, in any case, its parameters
    ignored.
  - It reads the whole body, parses it, and puts the pairs under its key.
  - Any other request passes untouched, and `req-form-params` answers `'()` for it.
- **The cap is required.** The server's `CHEZ_HTTP_MAX_BODY_BYTES` is unbounded by
  default, and a form is held whole in memory.
  - The middleware reads under the smaller of its cap and the request's own
    (`req-body-cap`), so it never lifts a cap set outside it.
  - A body past it raises the server's `&body-failed`, `413`, as any capped read does
    (design §4), and no handler runs. `wrap-catch` outside it, or the server, answers
    the `413`.
- **The body is read once.** After the middleware, `req-body` reads eof.
  - A body already taken outside it is `req-with-body-cap`'s assertion violation, a 500:
    two readers of one body is a bug.
- **`charset` is ignored.** WHATWG's parser decodes UTF-8 alone, and browsers send UTF-8
  from a UTF-8 page.
- **It waits as the body does,** so `wrap-timeout` outside it covers a slow client.
- **Multipart forms are left for later.** They need a streaming parser, and their files
  need somewhere to go.

### Testing (9b)

- **The parser is held to the web-platform-tests' urlencoded vectors**
  (`url/urlencoded-parser.any.js` and the `URLSearchParams` files, BSD-3-Clause), ported
  as rows, and to the Encoding standard's UTF-8 decoder vectors.
- **Rows on bytes where the encodings differ:**
  - `+` and `%2B`, `%20` and a raw space;
  - a malformed escape at every position: the end, one digit, a non-hex digit;
  - each malformed UTF-8 row in the table above.
- **A property suite** generates params from every kind of string, the empty one, `=`,
  `&`, `+` and `%` included, and holds `(parse-params (string->utf8 (params->string p)))`
  equal to `p`. It runs from a fixed seed, as the router's does.
- **The cap from both sides:**
  - a body of exactly the cap, which is read;
  - a body one byte past it, which is a `413`;
  - a declared `Content-Length` past it, refused at the first read;
  - the request's own cap lower than the middleware's, which wins;
  - a cap given as a bignum.

## 6. Cookies (9c)

### Its surface

```scheme
;; (circuit cookies)
;; Cookies = (Listof (Pair String String))
;; req-cookies : Req -> Cookies
;; req-cookie : Req String -> (U String #f)
;; res-add-cookie : Res String String CookieOption ... -> Res
;; res-expire-cookie : Res String CookieOption ... -> Res
;; cookie-path : String -> CookieOption
;; cookie-domain : String -> CookieOption
;; cookie-max-age : Nat -> CookieOption             ; seconds, at least 1
;; cookie-secure : -> CookieOption
;; cookie-http-only : -> CookieOption
;; cookie-same-site : Symbol -> CookieOption        ; strict, lax or none
```

```scheme
(res-add-cookie res "__Host-theme" "dark"
                (cookie-path "/") (cookie-secure) (cookie-http-only)
                (cookie-same-site 'lax) (cookie-max-age 2592000))
;; set-cookie: __Host-theme=dark; Path=/; Max-Age=2592000; Secure; HttpOnly; SameSite=Lax
```

### Reading

- **`req-cookies` reads every `cookie` field, in order, with no middleware.**
  - Each field is split on `;`.
  - Each piece is trimmed of spaces and tabs at both ends.
  - A piece is split at its first `=`. The name and the value are each trimmed.
  - A piece with no `=`, or an empty name, is skipped.
- **A value's quotes are kept.** RFC 6265bis §4.1.1: "the initial and trailing DQUOTE
  characters are not stripped. They are part of the cookie-value". Ring and Go strip
  them; circuit follows the RFC.
- **Characters aren't checked.** A cookie another system set reads as it was sent, Latin-1
  as the server reads every header.
- **`req-cookie` answers the first of a name, which names match exactly.**
  - Two cookies of one name come from different paths or domains. RFC 6265bis §4.2.2
    says servers "SHOULD NOT rely upon the order".
  - The docs point to `__Host-` names, which have one path and no domain, and to
    `req-cookies` for the rest.

### Writing

- **`res-add-cookie` adds one `set-cookie` field** (`res-add-header`: duplicates kept).
  Its attributes always go in this order, whatever the order of the options: `Path`,
  `Domain`, `Max-Age`, `Secure`, `HttpOnly`, `SameSite`.
- **It refuses, with an assertion violation, what a browser would drop without a word:**
  - a name that isn't a token, or is empty;
  - a value that isn't `cookie-octet`s, bare or inside quotes (RFC 6265bis §4.1.1). A
    space, `,`, `;`, `\` and anything outside ASCII need encoding first. The docs show
    base64url, which sessions will use;
  - a name and value over 4096 bytes together (§5.6, "ignore the set-cookie-string
    entirely"), held from both sides: 4096 passes, 4097 is refused;
  - a `Path` or `Domain` over 1024 bytes, or holding a control character or `;`. A
    `Path` must start with `/`;
  - a `Max-Age` under 1. The grammar's `non-zero-digit *DIGIT` has no 0.
    `res-expire-cookie` is the way to expire one. A large `Max-Age` is sent as given,
    a bignum included; the browser caps it at 400 days;
  - `SameSite=None` without `Secure`, which a browser ignores (§5.7, the storage model);
  - a `__Secure-` name without `Secure`, and a `__Host-` name without `Secure`, without
    `Path=/`, or with a `Domain` (§4.1.3). The prefixes match in any case, as browsers
    match them (§5.4): `__SECURE-id` without `Secure` would otherwise be dropped;
  - an option twice, or a `same-site` other than `strict`, `lax` or `none`.
- **`res-expire-cookie` writes `name=; Expires=Thu, 01 Jan 1970 00:00:00 GMT`,** with the
  path and domain it is given. A browser removes a cookie only when they match the
  cookie's. It is a fixed date, so no clock is needed, and the grammar allows it, where
  `Max-Age=0` breaks the grammar. It takes the same options but `cookie-max-age`, and the
  same prefix rules.
- **`Partitioned` is left for later.** It isn't in RFC 6265bis, and only embedded
  third-party content needs it.
- **Signing and encrypting are sessions' work** (§7).

### Testing (9c)

- **Reading rows:**
  - the RFC's own examples;
  - two `cookie` fields;
  - empty pieces, a piece with no `=`, a value with `=` in it;
  - quotes kept;
  - tabs and spaces at each end;
  - a Latin-1 byte.
- **Writing rows** assert the whole field. Each refusal has its own sentinel.
- **Each byte is tested against `cookie-octet`.** All 256 byte values, each alone in a
  value, are held against the RFC's set: an allowlist against its whole complement.
- **A property suite** holds that any cookie `res-add-cookie` accepts reads back by
  `req-cookies` to the same name and value, its `name=value` sent as a browser sends it.

## 7. Sessions, after slice 9

Sessions get a design of their own, written after 9c. The owner wants more discussion
first, cryptography above all. Its questions, as of 2026-10-31:

- **Where a session lives:**
  - 12-factor's processes keep no state, so a signed cookie store fits.
  - A memory store loses every session on a restart, and two processes don't share
    one. It would be for development and tests. The server's one event loop on one
    thread means it would need no locks.
  - A store interface, so other stores can come later.
- **Cryptography:**
  - Signing needs HMAC-SHA-256, which neither R6RS nor Chez has. It could be written in
    R6RS and held to RFC 4231's vectors, or taken from Akku (weinholt's `hashing`, to
    confirm), which would be circuit's first runtime dependency and an ADR.
  - Encrypting, as Ring's cookie store does, needs AES. Circuit shouldn't write that
    itself.
  - Comparing signatures in constant time.
  - Rotating keys.
  - Reading the secret from the environment, with the app passing it in (§2).
- **Randomness:** session ids from `/dev/urandom`, which plain R6RS can open on Linux and
  macOS.
- **How a handler hands back a new session:**
  - keys on the response, like the request's (`make-res-key`, `res-ref`, `res-set`): a
    core change, but pure, and Ring's model;
  - or a mutable session on the request.
- **Size:** a cookie store holds under 4096 bytes, name included (§6).
- **What follows sessions:** flash messages and CSRF protection.

## 8. Decided

The owner answered these on 2026-10-31:

1. **A param that doesn't decode:** WHATWG's parser, which never fails (§5). Weighed and
   set aside: a 400, as the router answers a capture that doesn't decode.
   `req-query-params` is a reader, not middleware, so that would have meant a raise that a
   catch maps to 400, or else a 500.
2. **Library names:** split by kind. The two middlewares are `(circuit middleware cors)`
   and `(circuit middleware headers)`. The readers and helpers are `(circuit params)`
   and `(circuit cookies)`.
   - Weighed and set aside: all four under `(circuit middleware ...)`, as Ring names
     its own; and `(circuit middleware security)`, to keep the name apart from
     `(circuit headers)`, the header-list helpers.
3. **`security-headers`' list:** the three in §4. Weighed and set aside: a content
   security policy and `cross-origin-opener-policy` as well, as helmet sends.
   - helmet's policy breaks inline scripts, and `same-origin` breaks OAuth popups.
   - An app adds either in a list of its own.
4. **A preflight whose origin doesn't match:** passed to the handler (§3), as ring-cors
   does. Weighed and set aside: wrap-cors answering it `403` with no fields, which would
   answer `403` for a path that doesn't exist.
5. **`null`:** never allowed (§3). Weighed and set aside: allowed when listed, for an app
   serving sandboxed iframes. `cors-any-origin` remains the way to allow every origin.
6. **`wrap-form-params`' cap:** required (§5). Weighed and set aside: 1 MiB unless
   given, which hides the choice and is far more than most forms need.
