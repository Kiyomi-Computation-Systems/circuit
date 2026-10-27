# Slice 6 design: upgrades, the router and WebSocket

Approved by the owner on 2026-10-27; the circuit design's §15.16 records it. It builds
on the circuit design
([2026-10-24-circuit-design.md](2026-10-24-circuit-design.md)): §8 for upgrades, §11 for
the libraries, §17 for the slice. §7 records the owner's answers.

## 1. Order

Slice 6 is three PRs in circuit and one in chez-websocket. The owner agreed to split it
on 2026-10-27.

1. **6a, upgrades:** `make-upgrade-res` in the core, and the adapter's `switch-protocols`.
2. **6b, the router:** `(circuit router)`, plain R6RS. It needs nothing from 6a, so it can go first.
3. **chez-websocket, a host-neutral handshake:** its own PR, under its rules, then a release (§6).
4. **6c, WebSocket:** circuit's side, once 6a and that release are in.

## 2. Upgrades (6a)

This part is the circuit design's §8, with what 6a settles:

- **The response:** `(make-upgrade-res headers take-over)` is a response with status 101
  and the headers as given, checked as `make-res` checks them. Its body is an upgrade
  holding `take-over : Transport Bytevector -> Any`. A take-over that is no procedure is
  an assertion violation.
- **The body kind:**
  - `res-upgrade-body? : Any -> Boolean` is in the `(circuit)` facade, so middleware can
    pass an upgrade by;
  - `res-upgrade-body-take-over` is in the facade too, so middleware can rebuild an
    upgrade around a wrapped take-over with `make-upgrade-res`. The draft kept it out, as
    the sized and wrapped bodies' accessors are; the review showed middleware then
    couldn't change an upgrade at all (the owner, design §15.19).
- **`res-remove-header : Res String -> Res`** joins the response helpers. It drops every
  field of a name, in any case, and keeps the body as `res-set-header` does, an
  upgrade's included (§15.19).
- **An upgrade body sits only in a 101 that `make-upgrade-res` made:**
  - `make-res` and `res-with-body` refuse an upgrade body;
  - `res-with-body`, `res-with-status` and `res-wrap-body` refuse an upgrade response;
  - `res-set-header`, `res-add-header` and `res-remove-header` keep it an upgrade;
  - `make-res` with 101 and any other body is still allowed, and the server answers it
    500 (design §5).
- **What the core says of an upgrade:**
  - `res-body-length` answers `#f`, since a 101 carries no `Content-Length`;
  - `res-body-port` answers `#f`;
  - `res-body-stream` refuses one, and so does `(circuit test)`'s `res-body->bytevector`,
    since after the 101 the stream is the taker's.
- **The adapter:**
  - It answers `(switch-protocols headers take-over)` from the `awaiting` thunk, its
    headers encoded as any response's.
  - The take-over is passed as it is. The server calls it with its transport and the
    bytes it had already read past the request, and it may answer `awaiting`.
  - The check costs one record predicate, so G3 shouldn't move.
- **The adapter re-exports the server's transport procedures** (the owner, 2026-10-27):
  `transport?`, `transport-write!`, `transport-read-start!`, `transport-read-stop!`,
  `transport-close!`, `transport-abort!`, `transport-deadline!`, `transport-on-drain!`
  and `transport-on-close!`.
  - It re-exports `awaiting` too, which a take-over answers to wait. The review found
    that without it an app whose taker waits had to import `(http-server)` (the owner,
    design §15.18).
  - They are the same bindings, so an app that upgrades needs only `(circuit)` and
    `(circuit http-server)`. ADR-0005 is amended, and the names suite holds them.
  - `make-transport` isn't re-exported: it's for testing a taker without a server, and
    a test imports it from `(http-server)`.
- **Around an upgrade, `(circuit middleware waits)`:**
  - `wrap-catch` passes one through.
  - `wrap-timeout`'s deadline covers the handler, not the take-over.
  - `wrap-log` logs `101 written` once the 101 is written. The server tells `written`
    before the hand-off (`vendor/chez-http-server/src/http-server/connection.sls:158`).
    A switch the server refuses for a request that asked for no upgrade is a 500,
    logged `invalid-response not-an-upgrade`, and the line reads `101 failed`.
- **Tests:** they run through `(http-server testing)`, whose `make-test-host` takes a
  handler that answers a `Switch`. What the client sends after the 101 goes to the
  taker, and what the taker writes is what the client reads.
- **The example:** `examples/upgrade.sps` answers `Upgrade: echo` by echoing the bytes
  back, as the server's `docs/upgrades.md` does. It runs over loopback with bash's
  `/dev/tcp`, which the container has.

## 3. Prior art

### Compojure

Compojure's own [`core.clj`](https://github.com/weavejester/compojure/blob/master/src/compojure/core.clj)
and its [routing wiki](https://github.com/weavejester/compojure/wiki/Routes-In-Detail) show
how it routes:
- **Routes are handlers that answer `nil` when they don't match.** `routes` tries each in
  order, `(some #(% request) handlers)`, and the first non-`nil` answer wins.
- **`GET` also matches HEAD**, and drops the body from the response.
- **The path syntax is Clout's.** `:id` matches up to the next `/` or `.`. A parameter
  can be held to a regex, `"/user/:id{[0-9]+}"`. The params it matches are merged into
  `:route-params` and `:params`.
- **`context` mounts routes under a prefix.** It sets `:path-info` to the rest of the
  path, `"/"` when nothing is left, and `:context` to the prefix.
- **`wrap-routes` exists because middleware on a route runs for every request tried
  against it, matched or not.** It applies middleware only once the route has matched.
- **A form can override POST's method** with its `_method` field.

### Reitit

Reitit's docs cover this:
[ring router](https://cljdoc.org/d/metosin/reitit/CURRENT/doc/ring/ring-router),
[route syntax](https://cljdoc.org/d/metosin/reitit/CURRENT/doc/basics/route-syntax),
[conflicts](https://cljdoc.org/d/metosin/reitit/CURRENT/doc/basics/route-conflicts),
[default handler](https://cljdoc.org/d/metosin/reitit/CURRENT/doc/ring/default-handler),
[routers](https://cljdoc.org/d/metosin/reitit/CURRENT/doc/advanced/different-routers),
[compiled middleware](https://cljdoc.org/d/metosin/reitit/CURRENT/doc/ring/compiling-middleware).
- **Routes are data:** nested vectors of a path, a map of data and child routes. Paths
  join down the tree, and a child takes its parents' data, their middleware among it.
- **The router is compiled once, from the whole table.** Reitit picks an implementation
  by the table's shape: a hash lookup when every path is static, a trie, or a linear scan
  for routes that conflict.
- **Conflicting paths are refused at creation by default.** `/:user-id/orders` and
  `/bulk/:bulk-id` raise "Router contains conflicting route paths". A route marked
  `{:conflicting true}`, or the option `:conflicts nil`, allows the overlap.
- **Methods are keys in a route's data:** `{:get h :post h}`, plus a `:handler` for any
  method.
- **Every path answers OPTIONS by default,** for CORS.
- **A default handler answers the requests no route takes:**
  - 404 when no path matches;
  - 405 when the path matches but no route has the method;
  - 406 when a handler answers `nil`.
- **Middleware in a route's data is compiled into that route's handler when the router
  is made.** Middleware with `:compile` sees the route's data and can opt out by answering
  `nil`. Middleware given to the router itself runs before routing.
- **The syntax:** `:id` or `{id}`, a catch-all `*path`, and bracket params mid-segment,
  `"/files/{name}.{ext}"`.
- **The match goes on the request:** its template, its path params and the router.
  Named routes can be reversed into paths, and two routes with one name are always
  refused.

## 4. What circuit takes, and leaves

| From | Taken | Why |
|:--|:--|:--|
| Reitit | the table compiled once into one handler | a table reads as a set; order never matters |
| Reitit | the router answers 404 and 405 itself | ADR-0004 allows no `nil` answer, so nothing falls through |
| Reitit | a group's middleware applied to each route under it, at construction | runs only on a match: no `wrap-routes` trap |
| Reitit | the match on the request: template and params | logging and metrics want the template, not the path |
| Reitit | a catch-all, `*rest` | static files and sub-apps |
| Compojure | HEAD served by GET | the server already sends no body for HEAD (`vendor/chez-http-server/src/http-server/decisions.sls:156`) |
| Compojure | `context` as `mount`: a handler under a prefix sees the rest of the path | sub-apps compose, through `req-with-path` |
| Compojure | short constructors, `(GET h)` | terse tables without quasiquote |

| Left | Why |
|:--|:--|
| `nil` fall-through and first-listed-wins | ADR-0004, and order-dependence hides conflicts |
| regex constraints | R6RS has no regex; a predicate could come later |
| mid-segment params, `{name}.{ext}` | later, if an app needs them |
| coercion and schemas | middleware's job |
| several router implementations | one trie; a static lookup only if the gate shows the need |
| an automatic OPTIONS answer, and 406 | CORS is middleware's; a handler can't answer `nil` |
| the `_method` override | middleware's, if anyone wants it |

## 5. The router (6b)

### Its surface

```scheme
(import (circuit router))

(define app
  (make-router
    (list
      (route "/"          (GET home))
      (route "/users"     (GET list-users) (POST create-user))
      (route "/users/new" (GET new-user-form))
      (route "/users/:id" (GET show-user) (DELETE delete-user))
      (group "/admin" (list wrap-admin)
        (route "/stats" (GET stats)))
      (mount "/assets" assets))))

(define (show-user req)
  (make-res 200 '() (req-path-param req "id")))
```

The exports. Slice 6b settled the names and a constructor for other methods. The
owner added `req-mount-path` at the review (design §15.20):

```text
make-router : (Listof Route) [Handler] -> Handler      the optional not-found handler
route       : String [Symbol] MethodEntry ... -> Route  the symbol names the route
GET POST PUT PATCH DELETE OPTIONS ANY : Handler -> MethodEntry
METHOD      : Symbol Handler -> MethodEntry            any other method, and HEAD
group       : String (Listof Middleware) Route ... -> Route
mount       : String Handler -> Route
req-path-param  : Req String -> (U String #f)
req-path-params : Req -> (Listof (Pair String String))
req-route       : Req -> (U String #f)                  the matched template
req-mount-path  : Req -> String                         the part the mounts took
```

- **The names suite holds them apart from the server's** (ADR-0005).
- **`(circuit router)` isn't in the `(circuit)` facade:** an app imports it beside it.
- **`METHOD`:**
  - Its symbol is an RFC 9110 token in upper case, as the server takes a method.
    `(METHOD 'PROPFIND h)` is one; `(METHOD 'HEAD h)` gives HEAD its own handler.
  - `(METHOD 'GET h)` is `(GET h)`, and `(METHOD 'ANY h)` is `(ANY h)`.
- **A route's name:**
  - It is a symbol right after the template, `(route "/users/:id" 'user (GET h))`.
  - Two routes of one name are refused. Nothing reads the name yet: it is kept for
    reverse routing (§7.3).
- **A route lists one method entry or more, each method once.** `(route "/x")` is
  refused, and so are two GETs, or `(METHOD 'ANY h)` beside `(ANY h)`.
- **Each constructor checks its own arguments,** with its own name as the who. The checks
  that need the whole table are `make-router`'s, and they run before any middleware is
  applied.

### Templates

- **A template given to `route`, `group` or `mount` is `""` or begins with `/`.**
  - Group prefixes join a route's or a mount's template by plain concatenation:
    `(group "/admin" mws (route "" ...))` serves `/admin`.
  - Every joined template must begin with `/`.
- **A template splits at `/` into segments.** A segment is a word, a parameter `:name`, or
  a catch-all `*name`.
  - **A name** is one or more ASCII letters, digits, `-` and `_`.
  - **A word** holds what a path carries unescaped: RFC 3986 `pchar` without
    `pct-encoded`. That is letters, digits, `- . _ ~`, `! $ & ' ( ) * + , ; =`, `:` and
    `@`. A word can't begin with `:` or `*`.
  - **The words `.` and `..` are refused:** clients remove dot segments (RFC 3986 §5.2.4),
    so such a route could never be reached.
- **In a joined template:**
  - an empty segment comes only last, the trailing slash of `/users/`;
  - a catch-all comes only last;
  - each name comes once.
- **A mount's joined template** has no catch-all and doesn't end in `/`, so it isn't `/`
  alone: the not-found handler takes every path.
- **`make-router` refuses two templates of one shape** (§7.1), whatever their names. One
  shape means the same segments, with equal words and with parameters and catch-alls
  equal whatever they're called. So it refuses `/u/:id` beside `/u/:name`, a template
  listed twice, and a mount `/p` beside a catch-all `/p/*r`.

### Matching

- **Segments are matched as the client sent them,** since `req-path` isn't decoded
  (design §3).
  - A word matches its segment exactly, case and all.
  - A parameter takes one segment that isn't empty.
  - A catch-all takes the rest after the slash before it: slashes kept, possibly empty.
    So `/files/*p` takes `/files/` and `/files/a/b`, not `/files`.
  - A mount `/p` takes `/p` and every `/p/...`, not `/px`.
  - A path that doesn't begin with `/`, such as `*`, matches nothing.
- **The trailing slash counts:** `/users/` isn't `/users`.
- **When several templates match a path, the leftmost segment where they differ
  decides** (§7.1). This holds whatever order the table lists them in.
  - A word beats a parameter, and a parameter beats a catch-all or a mount.
  - A template that ends where the path does beats a mount taking nothing: route `/p`
    beats mount `/p` for `/p`.
  - The empty last word beats a catch-all or a mount: `/p/` beats both for `/p/`.
  - The match backtracks. For `/users/new/edit`, `/users/:id/edit` wins over
    `/users/new`, which takes the first two segments but not the third.
- **Then the captures are percent-decoded, strictly, as UTF-8.**
  - These answer an empty 400, and no handler runs:
    - a malformed escape, anywhere in a value;
    - bytes that aren't UTF-8: an overlong form, a surrogate, past U+10FFFF, cut short,
      or a stray continuation byte;
    - a raw character past ASCII.
  - The server refuses raw non-ASCII and malformed escapes itself, before any handler
    runs. They reach the router only through `req-with-path` or a test request. Bytes that
    aren't UTF-8, such as `%FF`, do come from the wire.
  - `+` stays `+`.
  - `%2F` stays inside its segment for matching, and decodes to `/` in the value. So
    `/users/%6Eew` is `/users/:id` with id `new`, not the word `new`.
- **Then the method picks the handler, as in Reitit.** A path has one route, so
  `DELETE /users/new` is `/users/new`'s 405, even beside `/users/:id`'s DELETE.
  - HEAD goes to the route's own HEAD, else its GET, else its ANY. The handler sees the
    method as it came.
  - ANY takes every other method the route doesn't list, HEAD only when the route has no
    GET. So a route with ANY never answers 405.
- **When nothing matches:**
  - **No route takes the path:** the not-found handler runs. By default it answers an
    empty 404. It gets the request as it came to the router: under a mount, the mount's
    match and the rest of the path; reached through a route, that route's match.
  - **The route has no handler for the method:** an empty 405, with `allow` listing the
    route's methods.
    - The methods come in the order the route lists them, joined by `", "`.
    - HEAD comes right after GET when the route has a GET and no HEAD of its own.
    - RFC 9110 §15.5.6 requires the header.

### The request

- **The match goes on the request with one `req-set` for each router it passes,** under
  the router's own key from `make-req-key` (ADR-0005; G4 bounds one `req-set` at 88 B).
  - The match holds the template, the params and the nearest mount above.
  - A mount's match also keeps the path it matched, and where its rest begins.
  - A mount that a group's middleware wraps takes a second `req-set` (design §15.21).
- **What the match answers:**
  - `req-route` answers the joined template, and `#f` when no router matched.
  - `req-path-params` answers the params left to right in the template, and `'()` when
    there are none.
  - `req-path-param` answers the last param of that name.
- **A mounted handler sees the rest of the path,** through `req-with-path`.
  - It is `"/"` when nothing or only `/` follows, as with Compojure's `context`.
  - It is the rest of the path the router matched, even if a middleware between rewrote
    the path.
  - A request a group's middleware hands on without the mount's match reaches the
    handler as it is (design §15.23); see Middleware.
- **A router under a mount joins its match onto that mount's,** even when it is reached
  through a route under that mount. The templates join and the params join:
  `/api/:v` and `/users/:id` read `/api/:v/users/:id`. A router with no mount above it
  uses its own match alone.
- **`req-mount-path`** answers the part of the path the mounts above took, undecoded
  (design §15.20).
  - Under `mount "/api/:v"`, `/api/2/users/7` reads `"/api/2"`. Nested mounts join, and
    under no mount it is `""`.
  - It is built only when it is called.
  - Wherever a handler or a middleware reads it, it followed by `req-path` is the path the
    server read, unless a middleware rewrote the path. The one other exception is a rest
    of `"/"` standing for nothing after the mount.
- **A decoded value is the client's.**
  - It can hold `/` (from `%2F`), `..`, and NUL (from `%00`).
  - The server passes dot segments through as sent, so `/f/../../etc/passwd` reaches
    `/f/*p` with p `../../etc/passwd`.
  - Check a decoded value, not `req-path`, before using it as a file name.
- **`req-route`'s template and the params' names are the router's own strings,** shared
  by every request. Don't mutate them.

### Middleware

- **A group's middleware wraps each method's handler under it, and each mounted
  handler,** as Reitit's does.
  - It is applied once, when the router is made.
  - The outer group's middleware sits outermost, in `wrap`'s order.
  - It runs only for a request whose path and method matched: not for a 404, a 405 or a
    400.
- **Around a mount, a group's middleware sees what it sees around a route.** That is the
  path as the router matched it, the mount's template and params, and as
  `req-mount-path` the part the mounts above the router took (design §15.21). Only the
  mount's handler sees the rest.
  - A request the middleware hands `next` without the mount's match reaches the mount's
    handler as it is, as a route's handler would get it (design §15.23). That is a
    request the middleware made, or one a router of its own matched.
- **Middleware that wraps the router itself runs for every request,** 404s, 405s and
  400s included.

### Cost

- **The matcher walks the path by index,** comparing words in place. So a match
  allocates only the values it captures, the match, and its `req-set`. A mount also
  allocates the rest of the path, and the request `req-with-path` copies.
- **A words-only route with no mount above it** has its match made once, when the router
  is made: such a request costs its one `req-set`.
- **What the router allocates a request,** in plain Chez, the router called alone
  (6b's probes; `tests/test-router.sps` bounds the words-only route at 88 B, a mount at
  340 B, and a wrapped one at 80–112 B more):

  | Request | Bytes |
  |:--|--:|
  | a words-only route, its one `req-set` | 80 |
  | a route with one parameter | 160 |
  | a route with a catch-all | 176 |
  | a path no route takes | 0 |
  | through a mount | 336 |
  | through a mount a group's middleware wraps: a second `req-set` and a 16 B marker | 432 |

- **The gate holds three rows, G10:** a router of twenty routes asked a word, a
  parameter, and a path no route takes.
  - Each row is measured over an adapter base that reads `req-path` at the same URL, so
    it is the router's own work.
  - A counter in each handler proves oha asked that path.
  - Its worst figures in 6b's seven final runs: a word 90 B, a parameter 167 B, a miss
    4 B.
  - It holds them at 128 B a word, 256 B a parameter and 64 B a miss (design §15.24).

### Testing

- **`tests/test-router.sps` holds each rule above by example.**
- **`tests/test-router-properties.sps` holds them by property** (the owner, design
  §15.22). It generates tables and paths from a fixed seed, and checks the router against
  an oracle written from this section alone.

## 6. WebSocket

### What chez-websocket has

- **`websocket-accept : Request (WebSocket -> Any) [HandshakeSettings [WebsocketLimits]]
  -> Answer`** (`src/websocket.sls:12`) needs the server's request, and answers the
  server's own types. It reads `request-method`, `request-header-values` and
  `request-host`. Then it answers `switch-protocols` around a take-over, or
  `make-response` for a refusal (`src/websocket/private/binding.sls:140`).
- **The handshake's decision is already plain R6RS.** `handshake-answer`, in
  `(websocket handshake)`, takes the method, a field reader, the host and the settings.
  It answers `(accept headers subprotocol)` or `(refuse status headers why)`, its headers
  as bytevector pairs (`src/websocket/handshake.sls:115`).
- **The take-over is private:** `take-over` in `(websocket private binding)`, which
  imports `(http-server)` (`binding.sls:170`).
- **Its pins and releases:**
  - it's tagged v0.1.0 and v0.2.0, but neither has a GitHub release;
  - v0.2.0 pins the server at v0.7.0;
  - its main has pinned v0.9.0 since #96 (a0c57c0), which is circuit's pin, but no
    release carries it yet.

### The change in chez-websocket

**All the WebSocket logic stays there.** Each host's side is only a mapping onto its own
response types.

1. **Export a handshake neutral to the host:**

   ```text
   websocket-handshake : Symbol (String -> (Listof String)) String (WebSocket -> Any)
                         [HandshakeSettings [WebsocketLimits]] -> Handshake
   ```

   It takes the method, a reader of each line of a field, the host and the procedure. It
   answers one of two records:
   - **accepted:** the 101's headers as string pairs, and its take-over,
     `Transport Bytevector -> Answer`;
   - **refused:** the status and its headers.

   The header lines are joined there, as `field-lines` does today. The argument checks
   move there too.
2. **Rebuild `websocket-accept` on it.** Its contract doesn't change, so its suites and
   the Autobahn lane passing unchanged prove the refactor. The headers are turned into
   bytes there, once a connection.
3. **Release v0.3.0** with the server at v0.9.0, under chez-websocket's own rules: its
   ledger in `.superpowers/sdd/` and its own closing ritual.

### Circuit's side (6c)

- **The dependency:** chez-websocket becomes a submodule at `vendor/chez-websocket`,
  pinned at v0.3.0 (ADR-0003's rule).
  - Its own server pin must equal `SERVER_PIN`, and `make check-pins` holds that.
  - Circuit uses its own server checkout, and doesn't clone chez-websocket's.
- **The library:** `(circuit websocket)` exports `websocket-res : Req (WebSocket -> Any)
  [HandshakeSettings [WebsocketLimits]] -> Res`.
  - An accepted handshake answers `make-upgrade-res`, and a refused one `make-res`.
  - It imports `(websocket)` and the core, not `(http-server)`. Since `(websocket)`
    imports the server, 6c amends ADR-0006 and the audit to name it (§7.4).
- **Tests:** a handshake through `(http-server testing)`, and each refusal. An echo
  example runs over loopback. The container's curl, 8.20, lists `ws` among its
  protocols; 6c checks whether its command line can drive an echo.

## 7. Decided

The owner answered these on 2026-10-27:

1. **Two templates matching one path:** the leftmost segment where they differ decides.
   A word beats a parameter, and a parameter beats a catch-all or a mount. Only
   same-shape duplicates are refused. Reitit's rule, which refuses any overlap unless
   it's marked, and Compojure's, where the first listed wins, were weighed and set aside.
2. **The table's shape:** constructor procedures, `(route "/u/:id" (GET h))`, which check
   their arguments and name the bad one. Quasiquoted nested lists, as in Reitit, were set
   aside.
3. **Reverse routing:** later, not in slice 6. The route record keeps an optional name
   field now, so adding it changes no table.
4. **WebSocket's glue:** a small `(circuit websocket)`. 6c amends ADR-0006 and the audit
   to allow a third library that depends on the server, through `(websocket)`. The
   alternative was no library, with an example showing apps the five lines.
