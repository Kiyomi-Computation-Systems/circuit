# Slice 10 design: sessions

Proposed on 2026-11-01, for the owner's approval. It builds on the circuit design
([2026-10-24-circuit-design.md](2026-10-24-circuit-design.md)): §3 for the request's
keys, §5 for responses, §6 for middleware. It also builds on the slice 9 design
([2026-10-31-slice-9-design.md](2026-10-31-slice-9-design.md)): §2 for what its libraries
share, §5 for params, §6 for cookies, and §7 for the questions sessions began with. §8
records the owner's answers, which the circuit design's §15.33 holds, and §9 what a
read-only review found.

## 1. Order

Slice 10 is two PRs:

1. **10a, response keys:** `make-res-key`, `res-key?`, `res-ref` and `res-set` in
   `(circuit response)` and the facade. A core change, small and pure, which 10b needs
   and other middleware can use.
2. **10b, sessions:** `(circuit session)`, a signed cookie store, with `hashing` from
   Akku, circuit's first runtime dependency (ADR-0008).

10b needs 10a. Each PR adds its entries to `CHANGELOG.md`'s Unreleased. A release after
10b is the owner's call.

## 2. What the owner chose

The owner answered on 2026-11-01, after a survey of eight frameworks' sessions and of
the cryptography R6RS can reach (§7):

- **HMAC-SHA-256 comes from weinholt's `hashing`,** from Akku, as circuit will be
  published on Akku once chez-http-server is.
- **The cookie is signed, not encrypted.** Whoever holds it can read the session but not
  change it.
- **The cookie is the store.** A server-side store is left for later.
- **A signed timestamp bounds a cookie's life,** checked against a max age by a clock the
  app passes in.
- **A handler hands back its session on a response key.**
- **A session holds string pairs.**
- **The cookie is written only when a session is handed back.**
- **The cookie is `__Host-session`, with `Path=/`, `Secure`, `HttpOnly` and
  `SameSite=Lax`, by default,** and the app may name another cookie and attributes.

## 3. Response keys (10a)

### Its surface

```scheme
;; (circuit response), and the facade (circuit)
;; make-res-key : Any -> ResKey
;; res-key? : Any -> Boolean
;; res-ref : Res ResKey [Any] -> Any
;; res-set : Res ResKey Any -> Res
```

- **They mirror the request's keys** (design §3, ADR-0005): an alist in the record,
  newest first; `res-set` copies the record and conses the key's pair onto it; `res-ref`
  answers the newest pair's value, or the default, `#f` unless given.
- **A response key is its own kind.** `res-set` and `res-ref` refuse a request key, and
  `req-set` and `req-ref` refuse a response key, so a key's kind says where its data
  lives.
- **Every response helper keeps the keys:** `res-with-status`, `res-with-body`,
  `res-set-header`, `res-add-header`, `res-remove-header`, `res-wrap-body` and
  `res-tap-body`. `make-res` and `make-upgrade-res` make a response with none. `res-set`
  on an upgrade keeps it one, its take-over kept, as the header helpers do; on a port
  body it closes nothing.
- **Keys never reach the wire.** The adapter and the test host ignore them.
- **ADR-0005 gains the response's keys** in its fourth decision, amended in 10a.

### Its cost

- **Probed:** a sealed, opaque record of three fields takes 32 B on Chez 10.4.1, and one
  of four takes 48 B (`build/sessions-probe/record.sps`, git-ignored). So every response
  record costs 16 B more: each `make-res`, and each helper's copy.
- **The gate measures it.** G3's latest readings are 306 to 314 B against its 384 B
  bound; G3 and G7 should move by about 16 B, and the gates that difference two paths
  shouldn't move. 10a reports G3 and G5 to G10 before and after. A held gate that fails
  stops the slice for the owner's call.

### Testing (10a)

- The rows `req-set` and `req-ref` have, for responses: the default, a key set twice,
  two keys, a key of the other kind refused, each with its own sentinel.
- Each helper keeps every key, a row for each, on a response holding two.
- **Keys never reach the wire:** a response with keys and the same response without
  send the same bytes through the test host.
- `res-set` on an upgrade keeps its take-over; on a port body it leaves the port open.
- Mutants on the record, the copy in each helper, and the refusals.

## 4. The dependency (10b)

- **`Akku.manifest` names its first `depends`,** `("hashing" "^1.4.0")`. `Akku.lock`
  pins the archive Akku's index gives for 1.4.0, the newest there:
  `https://archive.akkuscm.org/archive/pkg/h/hashing_1.4.0_repack.tar.xz`, sha256
  `f3340fdb07279b1aed7f6102e7c80e13f6af47142410c1be9accf2df3d03f8d3`. The lock is
  `akku lock`'s output; the owner regenerates it, or 10b writes the entry as the index
  gives it, beside chez-cmark-gfm's.
- **Fetched on the host, into `vendor/akku/`.** `make submodules` also runs
  `scripts/fetch-akku-lock hashing` there, which checks the sha256, so a fresh clone
  still needs one host step before `make deps`. `vendor/akku/` is git-ignored and outside
  `build/`, so `make clean` keeps it and the container, which can't fetch, still finds
  it (found in review: under `build/akku`, `make clean` would strand the container).
- **`vendor/akku` joins the library path.** It holds `hashing/` and the archive's `dl/`,
  and nothing else; chez-cmark-gfm stays in `build/akku/`, off the path. Chez loads
  `hashing`'s `.scm` files: its `library-extensions` hold `.scm` (probed).
- **`make deps` checks for it,** `vendor/akku/hashing/sha-2.scm` beside the submodules'
  files, and names `make submodules` when it's missing.
- **The host's tools:** `submodules`' `require-tools` names curl or wget, xz and
  sha256sum beside git, and CI installs them before `make submodules` runs (today its
  toolchain step comes after).
- **`make check-imports` gains three rules:**
  - `(circuit session)` may import `(hashing sha-2)`, and only through `only`; no other
    library imports a `(hashing ...)` library. ADR-0006 is amended for it;
  - `(hashing sha-2)`'s closure, resolved as Chez would resolve it, imports only
    `(rnrs ...)` libraries but `(rnrs eval)`, `(hashing fixnums)` and `(hashing hmac)`.
    Chez prefers a `.chezscheme.sls` to a `.scm`, so a later pin that shipped one would
    otherwise load unread (found in review);
  - only `vendor/akku` holds a `hashing` directory on the path, as rule (j) holds
    `circuit`, so no other copy stands in for the pinned one.
- **`hashing` is plain R6RS on Chez today:** `sha-2.scm` imports `(rnrs ...)` libraries
  and its own `(hashing fixnums)` and `(hashing hmac)`, read in full before it ran.
- **ADR-0008 records it,** and `global-constraints.md`'s Dependency section gains it.
- **Probed on the pin,** in the container on Chez 10.4.1 with the server's pinned
  chez-srfi (`build/hashing-probe/`, git-ignored), and rerun in review:
  - `hashing`'s own suites pass: 80 of 80 HMAC checks, RFC 4231's seven cases at four
    sizes, and 16 of 16 SHA-256 checks;
  - a probe of circuit's matched RFC 4231's printed values for cases 1 and 2;
  - an HMAC-SHA-256 over 4096 bytes took about 0.2 ms and allocated 1,200 B.

## 5. Sessions (10b)

### Its surface

```scheme
;; (circuit session)
;; Session = (Listof (Pair String String))
;; wrap-session : (Listof String) (-> Integer) Nat SessionOption ... -> Middleware
;; req-session : Req -> Session
;; res-with-session : Res Session -> Res
;; session-name : String -> SessionOption
;; session-path : String -> SessionOption
;; session-domain : String -> SessionOption
;; session-same-site : Symbol -> SessionOption     ; strict, lax or none
;; session-insecure : -> SessionOption             ; no Secure: plain http, in development
```

```scheme
(import (rnrs) (only (chezscheme) current-time time-second) (circuit) (circuit session))

(define (now) (time-second (current-time)))
(define with-session
  (wrap-session (list (getenv "SESSION_SECRET")) now 1209600))

(define (visits req)
  (let* ((seen (assoc "visits" (req-session req)))
         (n (+ 1 (if seen (string->number (cdr seen)) 0))))
    (res-with-session (make-res 200 '() (number->string n))
                      (list (cons "visits" (number->string n))))))
;; set-cookie: __Host-session=visits=1.1793536476.<64 hex digits>; Path=/;
;;             Max-Age=1209600; Secure; HttpOnly; SameSite=Lax
```

- **A core library,** outside the facade, as the slice 9 design's §2 has them. It
  imports `(circuit cookies)`, `(circuit params)` and `(hashing sha-2)`, among circuit's
  core libraries.
- **The example's `only` is needed:** a program importing `(rnrs)` and all of
  `(chezscheme)` is refused, "multiple definitions for with-output-to-file and other
  identifiers" (probed in review).
- **`Session` is `Params`,** the pairs `(circuit params)` reads and writes: in order, a
  name given twice kept twice. An app finds a value with `assoc`, and encodes a number or
  an id as a string.

### Its settings

Checked together when `wrap-session` is called, each refusal an assertion violation
naming it. The clock's later answers are the one thing checked at a request, an
exception to the slice 9 design's §2:

- **The secrets:** a non-empty list of strings, each at least 32 bytes as UTF-8. The
  first signs; each verifies, in order. The docs show `openssl rand -base64 32`, 44
  characters, read from the environment by the app (the slice 9 design §2).
- **The clock:** a procedure of no arguments that answers the time in whole seconds since
  the Unix epoch, an exact integer, 0 or more. `wrap-session` calls it once when it is
  made, and checks every answer; one that is no such integer is refused when it comes.
  The docs show `(time-second (current-time))`: Chez's `current-time` is UTC (probed).
- **The max age:** an exact integer of seconds, from 1 to 34,560,000, the 400 days a
  browser keeps a cookie at most (RFC 6265bis). It is the cookie's `Max-Age`, and the
  most a signature's time may lag the clock: a longer one would let a copied cookie live
  on the server past any browser's.
- **The attributes are the session's own options,** each turned into the cookie option
  of `(circuit cookies)`, which exports no way to read an option back (found in review):
  - `session-name`: the cookie's name, `__Host-session` unless given;
  - `session-path`: `/` unless given;
  - `session-domain`: none unless given;
  - `session-same-site`: `lax` unless given;
  - `session-insecure`: drops `Secure`, for plain http in development. Safari doesn't
    keep a `Secure` cookie from `http://localhost` (unverified);
  - `HttpOnly` always: no option drops it. The cookie is signed, not encrypted, and can
    be replayed while it lives, so a script reading it gains an app nothing worth the
    exposure (found in review: replacing the defaults whole would drop it silently).
- **The name and attributes are tried together:** `wrap-session` writes a trial cookie
  with `res-add-cookie` and expires it with `res-expire-cookie`, so their refusals, a
  prefix's rules among them, come when the middleware is made, raised by `wrap-session`
  with the cookies library's message. `__Host-session` with `session-insecure`, a
  `session-path` but `/` or a `session-domain` is refused there.
- **An option given twice, or bare where its call was meant, is refused,** as the router's
  and the cookies' are.

### The cookie

```
<payload>.<time>.<mac>
```

- **`payload`:** the session by `params->string`. It writes only ASCII letters and
  digits, `*`, `-`, `.`, `_`, `+`, `=`, `&` and `%XX` (9b's property P2), each a
  `cookie-octet`, so the value needs no further encoding.
- **`time`:** the clock's answer when the cookie was written, in decimal digits.
- **`mac`:** HMAC-SHA-256 of `name=payload.time`, as ASCII, under the first secret's
  signing key, written by `hashing`'s `sha-256->string` in 64 lower-case hex digits. The
  cookie's name is signed with it, as gorilla's securecookie signs it, so a value can't
  move to another cookie. A token holds no `=`, the time is digits and the mac hex, so
  the signed text has one reading.
- **A signing key for each secret:** HMAC-SHA-256 of `circuit session` under the
  secret's UTF-8, made when `wrap-session` is called. A later use, CSRF tokens, derives
  its own under another label, so one key never signs for two purposes.
- **Its size:** `res-add-cookie` refuses a name and value over 4096 bytes together, `=`
  not counted (RFC 6265bis §5.6), an assertion violation when the cookie is written,
  which a catch outside turns into a 500 (the slice 9 design §6). The separators, ten
  digits and the mac take 76 bytes, so with `__Host-session` a payload may take 4006
  (probed in review: 4006 passes, 4007 is refused). A longer name, or a time past ten
  digits, takes from it.
- **The server caps a header's value at 8 KiB** (its `limits.sls`, answered 431). A
  session near 4 KiB beside the host's other cookies can push a request's `cookie` field
  past it, answered before any handler can expire the cookie. The page says so.

### Reading

On each request, before the handler:

- **The first cookie of the name that verifies is the session,** of those
  `req-cookies` gives, in order. `__Host-` names have one path and no domain, so a
  browser sends one; another name may come from two paths, or from a sibling host.
- **A value holding anything but `cookie-octet`s sets no session,** checked before
  anything else: `req-cookies` reads a byte past ASCII as Latin-1, and the signed text
  is ASCII.
- **Each is split from its right:** the mac is the 64 characters after the last `.`;
  the time is the digits between that `.` and the one before; the payload is what is
  left. A value that doesn't split so, or whose mac isn't 64 lower-case hex digits, or
  whose time is empty or holds a non-digit, sets no session.
- **The mac is checked before anything else is read:** decoded to 32 bytes, then held
  against each secret's HMAC of `name=payload.time` by `hashing`'s `sha-256-hash=?`.
  That compares every word, with no early exit, and ignores bytes past 32 (read in
  `sha-2.scm`, probed in review), so the 64-digit check is what holds the length.
  `bytevector=?` and `string=?` are never used on it.
- **Then the time, by one call of the clock:** the cookie is live while its time plus
  the max age is past the clock's answer, and its time is at most 60 seconds ahead of
  it. A time further ahead sets no session: one server instance whose clock jumped would
  otherwise mint cookies that outlive the max age by the jump (found in review; Flask
  refuses any time ahead, and the 60 seconds allow instances' clocks to differ).
- **Then the payload,** by `parse-params`, which never fails.
- **A cookie that fails any step sets no session,** never an error and never a log line,
  as every framework surveyed does. `req-session` answers `'()` then, and on a request
  no `wrap-session` saw, as `req-form-params` does.
- **A session under an old secret reads as any other.** It is signed with the first
  only when it is next handed back.

### Writing

After the handler, on its response:

- **No session key: the response is untouched,** but for `vary`, below. No
  `set-cookie`; the browser keeps the cookie it holds, and the max age counts from that
  cookie's write. An app that wants an idle timeout hands the session back on each
  request.
- **A session handed back is written whole:** the payload, the clock's time, the mac
  under the first secret, by `res-add-cookie` with the attributes and `Max-Age`.
- **`'()` ends it:** `res-expire-cookie` with the name and every attribute but the max
  age. A browser drops a cookie only when its path and domain match, and ignores an
  expiry without `Secure` for a `Secure` cookie; and `res-expire-cookie` holds a
  `__Host-` name to `Secure` and `Path=/` (found in review: with the path alone, every
  logout was refused).
- **A response that sets or expires the cookie gets `cache-control: private`,** unless
  it holds a `cache-control` field. `Set-Cookie` "does not inhibit caching" (RFC 9111
  §7.3), and `Vary` alone keys every cookieless client together, so a shared cache could
  hand one new session to every first visitor (found in review; Flask's
  GHSA-m2qf-hxjv-5gpq names both).
- **Every response gets `vary: cookie`,** unless a `vary` field of it lists `cookie` or
  `*`, in any case, as `wrap-cors` adds `origin`. A cache otherwise may serve one
  browser's page to another: Flask's CVE-2023-30861 was a missing `Vary: Cookie`. An
  app mounts `wrap-session` only where a session matters.
- **Once written, the key holds a mark of its own,** so an outer `wrap-session` leaves
  the response alone. Nested, the innermost writes.
- **`res-with-session` checks its session,** a list of pairs of strings, when it is
  called. On a response no `wrap-session` sees, it sets a key nothing reads; the docs
  say so.
- **What passes untouched:** a raise from the handler, with nothing written; an answer
  that isn't a response, as `wrap-cors` passes one. An inner middleware that answers a
  fresh response drops the key, and the session with it; the page says so.
- **A handler that writes a `set-cookie` of the session's name itself,** and hands back
  a session too, is refused at the write: `res-add-cookie` refuses a second field of one
  name (design §15.32).
- **Where it goes:** inside `wrap-catch`, so a refusal at the write is a 500; around the
  router, or a group of its routes.

### What it leaves

- **Encryption,** which needs an authenticated cipher R6RS lacks (§7).
- **A server-side store, and ids from `/dev/urandom`.** Plain R6RS reads it in the
  container (probed); a missing file must raise, never fall back as industria's entropy
  does, to SRFI-27 seeded from one of 65,536 clock values (read in the pinned chez-srfi).
- **Revoking a cookie before its max age.** A cookie store can't. An app that must keeps
  a check of its own on the server, a version in the session held against a store, as
  iron-session's docs advise.
- **Renewing an id against fixation.** A cookie store has no id: a login hands back a
  new session, which replaces the cookie whole.
- **Re-signing every response** (§8.3), flash messages and CSRF protection, which follow
  sessions.

The page warns of what a signed cookie can't stop:

- **A holder can send an older cookie back while it lives,** so a counter, a balance or
  a one-time token doesn't belong in a session.
- **A name without `__Host-` can be planted:** a sibling host sets its own valid-looking
  cookie with a longer path, and a browser sends it first. It fails the mac unless that
  host holds the secret, but it shadows the real one.
- **Two apps on one host share cookies,** whatever their ports. Two with one name and one
  secret take each other's sessions.

### Testing (10b)

- **The dependency:** RFC 4231's cases 1 to 7 through the pinned `(hashing sha-2)`, so a
  pin that moves is held to the vectors.
- **A known answer from outside circuit:** a fixed secret, clock and session give a whole
  `set-cookie` field computed apart from the library, by openssl's HMAC in the
  container, or by `hashing` driven by hand in the row. A wrong key derivation, or a mac
  that leaves out the name, still round-trips; this row doesn't.
- **Round trips:** a property that any session `res-with-session` takes, written by
  `wrap-session`, sent back as a browser sends it, reads back whole through
  `req-session`. It draws names and values as 9b's P1 draws them, and the cookie's name,
  the secret's place in the list and the clock's answer too. A row with `.` and digits
  in names and values holds the split from the right.
- **Tampering, each against its control:** every row asserts the untampered cookie reads
  back and the changed one doesn't, in one assertion, so a reader that refuses
  everything fails it. Each byte changed, at every position; the value cut short and
  lengthened; a mac of 63 and of 65 hex digits; a mac in upper case; a time with `+`; a
  Latin-1 byte; another name; a mac under a secret not in the list.
- **Several cookies of the name:** a bad one then a good one reads the good one; two good
  ones read the first.
- **Rotation, with three secrets:** a cookie under the middle one reads; a session handed
  back is signed with the first, neither the one that verified nor the last (Flask's
  CVE-2025-47278 signed with the last).
- **Limits held from both sides,** each with its own sentinel: secrets of 31 and 32
  bytes, and one of sixteen `é`, 16 characters and 32 bytes; a max age of 0, 1,
  34,560,000 and 34,560,001, and a bignum; payloads of 4006 and 4007 bytes; clock answers
  of -1, 0, a bignum and a non-integer; a time 60 and 61 seconds ahead; a time one
  second before its expiry, and at it.
- **The order:** a test clock counts its calls, and a cookie whose mac fails never calls
  it, so the mac is held to come first. What a compare's timing does isn't held by any
  row: a mutant swapping `sha-256-hash=?` for `bytevector=?` survives, recorded as the
  one equivalent the review accepts.
- **Writing:** whole `set-cookie` fields; `'()` expires a `__Host-session` whole; no
  key, no field; `cache-control: private` added, and not over one the response holds;
  `vary` added once, and not over a `vary` that lists `cookie` or `*`, with
  `set-cookie` in a `vary` (the substring trap), `Cookie` in a list, and two `vary`
  fields; nested `wrap-session`s write once.
- **Settings:** each refusal with its own sentinel, the trial cookie's among them.
- **A program over loopback,** run by hand with curl's cookie engine and recorded in the
  close-out, as 9c's was: its cookie stored, sent back and expired.
- **Mutants** as each slice's: every row watched failing.

## 6. The records

- **10a:**
  - ADR-0005 amended;
  - `global-constraints.md`'s line on keys;
  - the reference gains the response keys, and the counts don't move;
  - the slice 9 design's table, which says circuit's response has no keys.
- **10b:**
  - ADR-0008 accepted, ADR-0006 and ADR-0003 amended (its decisions on the manifest
    and the lock, and its consequences that `Akku.manifest` exists for the lock alone
    and `.akkuignore` keeps `akku install` to chez-cmark-gfm);
  - `global-constraints.md`'s Dependency section;
  - AGENTS.md: `make submodules` fetches as well as clones, the manifest names a
    `depends`, and the core imports `hashing` too;
  - the `Akku.manifest` comment, the Makefile's header and `submodules`' help, `ci.yml`'s
    comments, `.gitignore`;
  - a Sessions page in `site/pages.sls`, the Installing page, the reference's section
    for `(circuit session)`, and eleven public libraries;
  - the home page, whose "No framework" line says circuit has no sessions.

## 7. What the choice rested on

Read and probed on 2026-11-01, the survey and the cryptography each by a research agent,
spot-checked here against their sources:

- **Eight frameworks' sessions** (Ring 1.15.6, express-session 1.19.0 and cookie-session
  2.1.1, Rails 8.1.4, Plug 1.20.3, Django 6.1.2, Flask 3.1.3, gorilla 1.4.0,
  iron-session 9.0.1):
  - signed only: Flask, Django's signed cookies, cookie-session; encrypted: Rails, Plug,
    Ring, iron-session;
  - rotation, everywhere: the first secret signs and every one verifies;
  - a timestamp in the signature: Flask, Django, gorilla, iron-session; none in Ring's,
    Plug's or cookie-session's, so a copied cookie works forever there;
  - the worst bugs were readers on the far side of a leaked secret: Ring before 1.1.7,
    Rails' Marshal, Django's pickle.
- **The cryptography R6RS can reach:**
  - `hashing` 1.4.0 (MIT, no dependencies, `(rnrs)` only on Chez): SHA-2 and HMAC,
    tested against RFC 4231;
  - industria 2.3.0's AES indexes tables by state bytes, open to cache timing, and its
    GCM branches on key bits; its ChaCha20 has no Poly1305;
  - no Chez binding to libsodium's or OpenSSL's crypto; macOS aborts a process that loads
    its unversioned libcrypto;
  - chez-libuv binds no `uv_random`.

## 8. Decided

The owner answered these on 2026-11-01:

1. **`hashing` signs.** Weighed and set aside: HMAC-SHA-256 written in circuit, held to
   RFC 4231, NIST and CAVP vectors, which would need no dependency; and both, `hashing`
   as a test oracle beside circuit's own.
2. **Signed, not encrypted.** Weighed and set aside: encrypted, which needs an AEAD that
   circuit would write or bind itself.
3. **Rewritten only when handed back.** Weighed and set aside: every response that came
   with a session re-signed, an idle timeout at an HMAC and a field a response.
4. **The cookie store alone.** Weighed and set aside: a memory store for development,
   which needs random ids and a clock to evict.
5. **The clock passed in.** Weighed and set aside: `(circuit session)` importing Chez's
   `current-time`, a third impure library; and no timestamp, `Max-Age` alone.
6. **Response keys.** Weighed and set aside: a mutable session on the request, as
   Express, Django and Flask have.
7. **String pairs.** Weighed and set aside: Scheme data by `write` and `read`.
8. **`__Host-session`, with `Path=/`, `Secure`, `HttpOnly` and `SameSite=Lax`, by
   default; the app may name another cookie and attributes.** Weighed and set aside: no
   defaults, the name and attributes required; and `session` without `Secure`, as
   Django and Flask default.

## 9. The review

A read-only review on Opus, on 2026-11-01, found one blocking flaw and the rest above,
each marked "found in review":

- **Blocking:** `'()` expired the cookie with its path alone, which `res-expire-cookie`
  refuses for a `__Host-` name, so every logout raised. It expires with every attribute
  now, and the trial at `wrap-session` tries the expiry too.
- **Changed:** a time ahead of the clock is refused past 60 seconds; the attributes are
  the session's own options, `HttpOnly` always; `cache-control: private` on a write;
  `hashing` in `vendor/akku`, which `make clean` keeps; three rules in `check-imports`;
  the size budget is 4006, not 4005; the max age is capped at 400 days; the clock
  refuses a negative answer; nested middleware, raises, non-responses and placement
  specified; the tests' controls, known answer, limits and order.
- **Accepted as unheld:** the compare's timing, which no row can see.
- **The owner accepted the five that were new choices** with "commit and open" on
  2026-11-01: a time more than 60 seconds ahead refused; the attributes as the session's
  own options, `HttpOnly` always; `cache-control: private` on a write; the 400-day cap;
  `hashing` in `vendor/akku`.
