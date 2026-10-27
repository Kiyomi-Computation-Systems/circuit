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

The exports, as drafts:

```text
make-router : (Listof Route) [Handler] -> Handler      the optional not-found handler
route       : String MethodEntry ... -> Route
GET POST PUT PATCH DELETE OPTIONS ANY : Handler -> MethodEntry
group       : String (Listof Middleware) Route ... -> Route
mount       : String Handler -> Route
req-path-param  : Req String -> (U String #f)
req-path-params : Req -> (Listof (Pair String String))
req-route       : Req -> (U String #f)                  the matched template
```

The names suite holds them apart from the server's (ADR-0005). The slice settles the
final names, and a constructor for methods past the six. A route also takes an optional
name, kept for reverse routing later (§7.3).

### Matching

- **A template splits at `/` into segments.** A segment is a word, a parameter `:name` or
  a catch-all `*name`, which comes last and takes the rest.
- **Segments are matched as the client sent them,** since `req-path` isn't decoded
  (design §3). So `%2F` stays inside its segment.
  - A template's words must be characters a path may carry unescaped (RFC 3986 `pchar`).
    Any other is an assertion violation at construction.
  - A captured value is percent-decoded as UTF-8. A malformed escape answers 400.
- **The trailing slash counts:** `/users/` isn't `/users`.
- **When several templates match a path, the leftmost segment where they differ
  decides:** a word beats a parameter, and a parameter beats a catch-all or a mount. So
  `/users/new` beats `/users/:id`, whatever order they're listed in. Two templates of one
  shape, such as `/u/:id` and `/u/:name`, are refused at construction, as is a template
  listed twice (§7.1).
- **The path picks the route, then the method picks the handler,** as in Reitit. A path
  has one route, so `DELETE /users/new` is a 405, not `/users/:id`'s DELETE.
- **HEAD goes to the GET handler** when a route has none of its own.
- **When nothing matches:**
  - no route takes the path: the not-found handler runs, a 404 with no body by default;
  - the route has no handler for the method: a 405, with an `Allow` header listing the
    route's methods, HEAD included where there's a GET. RFC 9110 §15.5.6 requires the
    header.

### The request

- **The match goes on the request with one `req-set`,** under the router's own key from
  `make-req-key` (ADR-0005; G4 bounds one `req-set` at 88 B). It holds the template, the
  params and a mount's prefix.
- **A mounted handler sees the rest of the path,** through `req-with-path`: `"/"` when
  nothing is left, as with Compojure's `context`. The params the mount captured join any
  that a router under it finds.

### Middleware

- **A group's middleware wraps each route under it,** once, when the router is made.
  The outer group's middleware sits outermost, in `wrap`'s order. It runs only for a
  request that matched.
- **Middleware that wraps the router itself runs for every request,** 404s and 405s
  included.

### Cost

The matcher walks the path by index, so a match allocates only the values it captures
and the one `req-set`. The gate prints a new row first: the router over about twenty
routes, for a word, a parameter and a 404. The bound is held only after it's measured
and the owner accepts it, as G8 own and G9 were.

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
