#!r6rs
;;; (circuit router): matching and its precedence, the captures decoded and
;;; the raw characters they may hold, the method's pick, 404, 405 and 400
;;; and the app's own handlers for them, groups' middleware, mounts and the
;;; routers under them, the request's accessors, req-mount-path among them,
;;; the cost of a words-only route and of the options, and every refusal at
;;; construction.
;;;
;;; Handlers here answer what they saw, as a list, not a response: the
;;; router hands back whatever its handler answers. A response the router
;;; makes itself is read whole, as (res STATUS HEADERS BODY). Every table is
;;; built inside a row's actual expression, so a construction that raises
;;; fails that row, not the suite. Requests carry a query, q=7, which the
;;; router must leave alone.
;;;
;;; Oracles: the slice 6 design's §5 and the slice's briefs, which settle
;;; each rule; RFC 3986's pchar, written out below as the word allowlist;
;;; RFC 9110's tchar, written out as the method allowlist; and UTF-8's
;;; table of well-formed byte sequences (RFC 3629 §4).
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (only (chezscheme) statistics sstats-bytes)
        (circuit-testing)
        (circuit)
        (circuit test)
        (circuit router))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner names a failing test but not its values. Print both.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (memq (test-result-kind r) '(fail xpass))
        (display "  expected: ")
        (write (test-result-ref r 'expected-value))
        (newline)
        (display "  actual:   ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

;; raised : (-> Any) -> Any
;; What THUNK raised: (assertion-violation WHO IRRITANTS) for an assertion
;; violation, (other-raise X) for anything else, and no-raise if it returned.
(define (raised thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (irritants-condition? e))
             (list 'assertion-violation (condition-who e) (condition-irritants e)))
            ((condition? e) (list 'other-raise (describe e)))
            (#t (list 'other-raise e)))
    (thunk)
    'no-raise))

(define the-log '())
(define (note! x) (set! the-log (cons x the-log)))
(define (take-log!)
  (let ((taken (reverse the-log)))
    (set! the-log '())
    taken))

;; seen : Any -> Any
;; A response as (res STATUS HEADERS BODY); anything else as it is.
(define (seen x)
  (if (res? x) (list 'res (res-status x) (res-headers x) (res-body x)) x))

;; ask : Handler Symbol String -> Any
;; What APP answers a test request for METHOD and TARGET, seen.
(define (ask app method target)
  (seen (app (make-test-req method target))))

;; asks : Handler (Listof (List Symbol String)) -> (Listof Any)
;; ask for each request, in order.
(define (asks app requests)
  (let loop ((requests requests) (acc '()))
    (if (null? requests)
        (reverse acc)
        (loop (cdr requests) (cons (ask app (caar requests) (cadar requests)) acc)))))

;; in-both-orders : (Listof Route) (Listof (List Symbol String)) -> (List (Listof Any) (Listof Any))
;; asks of a router of ROUTES, then of one of ROUTES reversed.
(define (in-both-orders routes requests)
  (let* ((forward (asks (make-router routes) requests))
         (backward (asks (make-router (reverse routes)) requests)))
    (list forward backward)))

;; twice : Any -> (List Any Any)
(define (twice x) (list x x))

;; tell : Symbol -> Handler
;; A handler that answers what it saw: NAME, the request's method and path,
;; req-route, req-path-params and the query.
(define (tell name)
  (lambda (req)
    (list name (req-method req) (req-path req) (req-route req) (req-path-params req)
          (req-query req))))

;; the-param : Handler — answers req-path-param's "id".
(define (the-param req) (req-path-param req "id"))

;; tagging : Symbol -> Middleware
;; Notes NAME when applied, and on the way in and out, and conses NAME onto
;; what the handler answered, seen.
(define (tagging name)
  (lambda (next)
    (note! (list 'applied name))
    (lambda (req)
      (note! (list 'in name))
      (let ((answer (next req)))
        (note! (list 'out name))
        (cons name (seen answer))))))

;; running : Symbol -> Handler — notes (ran NAME) and answers NAME.
(define (running name)
  (lambda (req) (note! (list 'ran name)) name))

;; place : Symbol -> Handler
;; A handler that answers NAME, the path, req-route, req-path-params and
;; req-mount-path.
(define (place name)
  (lambda (req)
    (list name (req-path req) (req-route req) (req-path-params req) (req-mount-path req))))

;; seeing : Symbol -> Middleware
;; Notes what a request shows as it passes, as place answers it, and
;; passes it on.
(define (seeing name)
  (lambda (next)
    (lambda (req)
      (note! (list 'saw name (req-path req) (req-route req) (req-path-params req)
                   (req-mount-path req)))
      (next req))))

(define (h req) 'h)

(define not-found '(res 404 () #f))
(define bad-request '(res 400 () #f))
(define (not-allowed allow) (list 'res 405 (list (cons "allow" allow)) #f))

;; The word allowlist: RFC 3986's pchar without pct-encoded, each written
;; out. (string-ref allowed-chars i) is the i-th.
(define allowed-chars
  (string->list "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:@"))

;; A parameter's or a catch-all's name: ASCII letters, digits, - and _.
(define name-chars
  (string->list "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"))

;; A method's name: RFC 9110's tchar, but the lower-case letters.
(define method-chars
  (string->list "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"))

;; ascii : (Listof Char) — #\x0 to #\x7F.
(define ascii
  (let loop ((i 127) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons (integer->char i) acc)))))

;; ascii-but-slash : (Listof Char) — #\x0 to #\x7F, but #\/, which ends a segment.
(define ascii-but-slash
  (let loop ((i 127) (acc '()))
    (cond ((< i 0) acc)
          ((= i 47) (loop (- i 1) acc))
          (else (loop (- i 1) (cons (integer->char i) acc))))))

;; constructed : (-> Any) -> Any — 'constructed if THUNK returns, else what it raised.
(define (constructed thunk)
  (let ((r (raised thunk)))
    (if (eq? r 'no-raise) 'constructed r)))

;; bytes-a-call : (-> Any) Nat -> Real
;; The bytes this process allocates a call of THUNK, over N calls after one.
(define (bytes-a-call thunk n)
  (thunk)
  (let ((before (sstats-bytes (statistics))))
    (let loop ((i 0))
      (when (< i n)
        (thunk)
        (loop (+ i 1))))
    (/ (- (sstats-bytes (statistics)) before) n)))

(test-begin "router")

;;; ------------------------------------------------------------------------
;;; Matching

(test-equal
  "a word route: its handler sees the request as it came, req-route its template, no params"
  '(new-user PUT "/users/new" "/users/new" () "q=7")
  (ask (make-router (list (route "/users/new" (PUT (tell 'new-user))))) 'PUT "/users/new?q=7"))

(test-equal (string-append "a parameter takes one segment: req-path-params left to right, "
                           "req-path-param by name, #f for none")
  '("42" "7" #f (("id" . "42") ("post" . "7")))
  (ask (make-router (list (route "/users/:id/posts/:post"
                                 (GET (lambda (req)
                                        (list (req-path-param req "id")
                                              (req-path-param req "post")
                                              (req-path-param req "nope")
                                              (req-path-params req)))))))
       'GET "/users/42/posts/7?q=7"))

(test-equal "precedence: a word beats a parameter, whichever is listed first"
  (twice '((new-user GET "/users/new" "/users/new" () "q=7")
           (show-user GET "/users/42" "/users/:id" (("id" . "42")) "q=7")))
  (in-both-orders (list (route "/users/:id" (GET (tell 'show-user)))
                        (route "/users/new" (GET (tell 'new-user))))
                  '((GET "/users/new?q=7") (GET "/users/42?q=7"))))

(test-equal (string-append "precedence backtracks: /users/new/edit is /users/:id/edit's, though "
                           "/users/new takes its first two segments")
  (twice '((edit-user GET "/users/new/edit" "/users/:id/edit" (("id" . "new")) "q=7")
           (new-user GET "/users/new" "/users/new" () "q=7")))
  (in-both-orders (list (route "/users/new" (GET (tell 'new-user)))
                        (route "/users/:id/edit" (GET (tell 'edit-user))))
                  '((GET "/users/new/edit?q=7") (GET "/users/new?q=7"))))

(test-equal "precedence: the leftmost segment where two templates differ decides, whatever follows"
  (twice '((a-first GET "/a/b/c" "/a/:x/c" (("x" . "b")) "q=7")
           (y-first GET "/z/b/c" "/:y/b/c" (("y" . "z")) "q=7")))
  (in-both-orders (list (route "/:y/b/c" (GET (tell 'y-first)))
                        (route "/a/:x/c" (GET (tell 'a-first))))
                  '((GET "/a/b/c?q=7") (GET "/z/b/c?q=7"))))

(test-equal "precedence: a parameter beats a catch-all, which takes what the parameter can't"
  (twice '((by-name GET "/files/a" "/files/:name" (("name" . "a")) "q=7")
           (by-path GET "/files/a/b" "/files/*path" (("path" . "a/b")) "q=7")
           (by-path GET "/files/" "/files/*path" (("path" . "")) "q=7")))
  (in-both-orders (list (route "/files/*path" (GET (tell 'by-path)))
                        (route "/files/:name" (GET (tell 'by-name))))
                  '((GET "/files/a?q=7") (GET "/files/a/b?q=7") (GET "/files/?q=7"))))

(test-equal (string-append "precedence against a mount: a route ending at the path's end, the "
                           "empty last word and a parameter each beat it")
  (twice '((p GET "/p" "/p" () "q=7")
           (p-slash GET "/p/" "/p/" () "q=7")
           (p-x GET "/p/a" "/p/:x" (("x" . "a")) "q=7")
           (mounted GET "/a/b" "/p" () "q=7")))
  (in-both-orders (list (mount "/p" (tell 'mounted))
                        (route "/p" (GET (tell 'p)))
                        (route "/p/" (GET (tell 'p-slash)))
                        (route "/p/:x" (GET (tell 'p-x))))
                  '((GET "/p?q=7") (GET "/p/?q=7") (GET "/p/a?q=7") (GET "/p/a/b?q=7"))))

(test-equal "precedence: the empty last word beats a catch-all"
  (twice '((p-slash GET "/p/" "/p/" () "q=7")
           (rest GET "/p/x" "/p/*r" (("r" . "x")) "q=7")
           (res 404 () #f)))
  (in-both-orders (list (route "/p/*r" (GET (tell 'rest)))
                        (route "/p/" (GET (tell 'p-slash))))
                  '((GET "/p/?q=7") (GET "/p/x?q=7") (GET "/p?q=7"))))

(test-equal "precedence: a mount's word beats a mount above it"
  (twice '((inner GET "/x" "/p/q" () "q=7")
           (outer GET "/r/x" "/p" () "q=7")))
  (in-both-orders (list (mount "/p" (tell 'outer))
                        (mount "/p/q" (tell 'inner)))
                  '((GET "/p/q/x?q=7") (GET "/p/r/x?q=7"))))

(test-equal "the trailing slash counts: /users takes no /users/, and /users/ no /users"
  (list not-found '(users-slash GET "/users/" "/users/" () "q=7") not-found)
  (list (ask (make-router (list (route "/users" (GET (tell 'users))))) 'GET "/users/?q=7")
        (ask (make-router (list (route "/users/" (GET (tell 'users-slash))))) 'GET "/users/?q=7")
        (ask (make-router (list (route "/users/" (GET (tell 'users-slash))))) 'GET "/users?q=7")))

(test-equal "a parameter takes no empty segment"
  (list not-found not-found '(x GET "/u/a/x" "/u/:id/x" (("id" . "a")) "q=7"))
  (let ((app (make-router (list (route "/u/:id" (GET (tell 'u)))
                                (route "/u/:id/x" (GET (tell 'x)))))))
    (asks app '((GET "/u/?q=7") (GET "/u//x?q=7") (GET "/u/a/x?q=7")))))

(test-equal "a word matches its whole segment, case and all"
  (list not-found not-found not-found '(new GET "/users/new" "/users/new" () "q=7"))
  (asks (make-router (list (route "/users/new" (GET (tell 'new)))))
        '((GET "/Users/new?q=7") (GET "/users/newer?q=7") (GET "/users/ne?q=7")
          (GET "/users/new?q=7"))))

(test-equal "/ takes / alone, and without it / is not found"
  (list '(home GET "/" "/" () "q=7") not-found not-found)
  (list (ask (make-router (list (route "/" (GET (tell 'home))))) 'GET "/?q=7")
        (ask (make-router (list (route "/" (GET (tell 'home))))) 'GET "/x?q=7")
        (ask (make-router (list (route "/x" (GET (tell 'x))))) 'GET "/?q=7")))

(test-equal "a path not beginning with / matches nothing, not even /*all"
  (list not-found not-found '(all GET "/x" "/*all" (("all" . "x")) "q=7"))
  (let ((app (make-router (list (route "/*all" (GET (tell 'all))))))
        (base (make-test-req 'GET "/x?q=7")))
    (list (seen (app (req-with-path base "*")))
          (seen (app (req-with-path base "")))
          (seen (app base)))))

(test-equal (string-append "a catch-all takes the rest after its slash, slashes kept, possibly "
                           "empty, but not the path without the slash")
  (list not-found
        '(files GET "/files/" "/files/*p" (("p" . "")) "q=7")
        '(files GET "/files/a" "/files/*p" (("p" . "a")) "q=7")
        '(files GET "/files/a/b/" "/files/*p" (("p" . "a/b/")) "q=7"))
  (asks (make-router (list (route "/files/*p" (GET (tell 'files)))))
        '((GET "/files?q=7") (GET "/files/?q=7") (GET "/files/a?q=7") (GET "/files/a/b/?q=7"))))

(test-equal "an empty table finds nothing"
  (list not-found not-found)
  (asks (make-router '()) '((GET "/?q=7") (POST "/x?q=7"))))

(test-equal "every character a word may hold matches itself in place"
  (map string allowed-chars)
  (let ((app (make-router (map (lambda (c) (route (string #\/ #\a c #\b)
                                                  (GET (lambda (req) (string c)))))
                               allowed-chars))))
    (map (lambda (c) (ask app 'GET (string #\/ #\a c #\b))) allowed-chars)))

;;; ------------------------------------------------------------------------
;;; The captures, decoded

(test-equal (string-append "a capture is percent-decoded as UTF-8, in either case of hex; + stays "
                           "+; the query is left as sent")
  '(("été" "€" "\x1F600;" "é" "a+b" "a b")
    (show GET "/u/a%20b" "/u/:id" (("id" . "a b")) "x=%20&y=+"))
  (let ((app (make-router (list (route "/u/:id" (GET the-param))))))
    (list (asks app '((GET "/u/%C3%A9t%C3%A9") (GET "/u/%E2%82%AC") (GET "/u/%F0%9F%98%80")
                      (GET "/u/%c3%a9") (GET "/u/a+b") (GET "/u/a%20b")))
          (ask (make-router (list (route "/u/:id" (GET (tell 'show))))) 'GET
               "/u/a%20b?x=%20&y=+"))))

(test-equal "%2F stays inside its segment for matching, and decodes to / in the value"
  (twice '((one GET "/u/a%2Fb" "/u/:id" (("id" . "a/b")) "q=7")
           (two GET "/u/a/b" "/u/:a/:b" (("a" . "a") ("b" . "b")) "q=7")))
  (in-both-orders (list (route "/u/:id" (GET (tell 'one))) (route "/u/:a/:b" (GET (tell 'two))))
                  '((GET "/u/a%2Fb?q=7") (GET "/u/a/b?q=7"))))

(test-equal "an escaped word is a parameter's: /users/%6Eew is /users/:id with id new"
  (twice '((show GET "/users/%6Eew" "/users/:id" (("id" . "new")) "q=7")))
  (in-both-orders (list (route "/users/new" (GET (tell 'new)))
                        (route "/users/:id" (GET (tell 'show))))
                  '((GET "/users/%6Eew?q=7"))))

(test-equal "a catch-all's value is decoded whole, %2F and all"
  '(files GET "/files/a%20b/c%2Fd" "/files/*p" (("p" . "a b/c/d")) "q=7")
  (ask (make-router (list (route "/files/*p" (GET (tell 'files))))) 'GET "/files/a%20b/c%2Fd?q=7"))

(define malformed-values
  '("%yz" "%4yz" "%G1yz" "%4Gyz" "x%yz" "x%4yz" "x%G1yz" "x%4Gyz" "x%" "x%4" "x%G1" "x%4G"))

(test-equal (string-append "a malformed escape, %, %4, %G1 or %4G, at a value's start, middle or "
                           "end, is a 400, and no handler runs")
  (list (map (lambda (v) (cons v bad-request)) malformed-values) '())
  (let ((app (make-router (list (route "/u/:id" (GET (running 'u)))))))
    (take-log!)
    (let ((answers (map (lambda (v) (cons v (ask app 'GET (string-append "/u/" v "?q=7"))))
                        malformed-values)))
      (list answers (take-log!)))))

(test-equal (string-append "a malformed escape is a 400 in a catch-all's later segment, before a "
                           "slash, and in a second parameter")
  (list (list bad-request bad-request bad-request bad-request "a/A") '((ran files)))
  (let ((app (make-router (list (route "/files/*p" (GET (lambda (req) (note! '(ran files))
                                                                (req-path-param req "p"))))
                                (route "/two/:a/:b" (GET (running 'two)))
                                (route "/one/:a/x" (GET (running 'one)))))))
    (take-log!)
    (let ((answers (asks app
                         '((GET "/files/a/b%4G?q=7") (GET "/files/a/%/b?q=7")
                           (GET "/one/a%4/x?q=7")
                               (GET "/two/%41/%4?q=7") (GET "/files/a/%41?q=7")))))
      (list answers (take-log!)))))

(test-equal (string-append "bytes that aren't UTF-8 are a 400: overlong, a lone continuation, a "
                           "surrogate, past U+10FFFF, cut short, or no lead")
  (let ((escapes '("%C0%AF" "%C1%BF" "%E0%80%AF" "%E0%9F%BF" "%F0%80%80%AF" "%F0%8F%BF%BF"
                   "%80" "%BF" "%ED%A0%80" "%ED%BF%BF" "%F4%90%80%80" "%F5%80%80%80" "%FF"
                   "%E2%82" "%C3x" "%E2%82x" "%F0%9F%98" "%C3%C3%A9")))
    (map (lambda (e) (cons e bad-request)) escapes))
  (let ((app (make-router (list (route "/u/:id" (GET the-param)))))
        (escapes '("%C0%AF" "%C1%BF" "%E0%80%AF" "%E0%9F%BF" "%F0%80%80%AF" "%F0%8F%BF%BF"
                   "%80" "%BF" "%ED%A0%80" "%ED%BF%BF" "%F4%90%80%80" "%F5%80%80%80" "%FF"
                   "%E2%82" "%C3x" "%E2%82x" "%F0%9F%98" "%C3%C3%A9")))
    (map (lambda (e) (cons e (ask app 'GET (string-append "/u/" e)))) escapes)))

(test-equal "UTF-8 at each edge of each length decodes to its code point"
  '((#x7F) (#x80) (#x7FF) (#x800) (#xD7FF) (#xE000) (#xFFFF) (#x10000) (#x10FFFF) (#x41 #xE9 #x42))
  (let ((app (make-router
              (list (route "/u/:id"
                           (GET (lambda (req)
                                  (map char->integer
                                       (string->list (req-path-param req "id"))))))))))
    (asks app '((GET "/u/%7F") (GET "/u/%C2%80") (GET "/u/%DF%BF") (GET "/u/%E0%A0%80")
                (GET "/u/%ED%9F%BF") (GET "/u/%EE%80%80") (GET "/u/%EF%BF%BF")
                (GET "/u/%F0%90%80%80") (GET "/u/%F4%8F%BF%BF") (GET "/u/A%C3%A9B")))))

;; The server refuses a raw byte past ASCII in a target, as it refuses a
;; malformed escape, before any handler runs: such a path reaches a router
;; only from a test request or req-with-path.
(test-equal (string-append "a character past ASCII in a captured value is a 400, wherever it "
                           "stands, as a malformed escape is")
  (list bad-request bad-request bad-request bad-request bad-request bad-request)
  (asks (make-router (list (route "/u/:id" (GET the-param)) (route "/f/*p" (GET the-param))))
        (list (list 'GET (string #\/ #\u #\/ (integer->char #xC3) (integer->char #xA9)))
              (list 'GET (string #\/ #\u #\/ (integer->char #xE9)))
              (list 'GET (string #\/ #\u #\/ #\a (integer->char #x20AC) #\b))
              (list 'GET (string-append "/u/%C3" (string (integer->char #xA9))))
              (list 'GET (string #\/ #\u #\/ #\a #\b (integer->char #x80)))
              (list 'GET (string #\/ #\f #\/ #\a #\/ #\b (integer->char #xFF))))))

;; raw-ask : Handler Symbol String -> Any
;; What APP answers a request for METHOD whose path is PATH exactly, seen:
;; a ? or # in PATH stays in the path, where make-test-req would split a
;; target at its ?. The query is q=7.
(define (raw-ask app method path)
  (seen (app (req-with-path (make-test-req method "/?q=7") path))))

;; What a capture holds raw: RFC 3986's pchar without pct-encoded, the word
;; allowlist above, and / in a catch-all's rest. The server refuses the
;; rest of ASCII on the wire; they reach a router through req-with-path.
(define (capture-char? c) (and (memv c allowed-chars) #t))
(define (rest-char? c) (or (capture-char? c) (char=? c #\/)))

(test-equal (string-append "a parameter's value holds raw only RFC 3986's pchar: every other ASCII "
                           "character is a 400, a lone % among them")
  (map (lambda (c) (if (capture-char? c) (string #\a c #\b) bad-request)) ascii-but-slash)
  (let ((app (make-router (list (route "/u/:id" (GET the-param))))))
    (map (lambda (c) (raw-ask app 'GET (string #\/ #\u #\/ #\a c #\b))) ascii-but-slash)))

(test-equal (string-append "a catch-all's value holds raw only RFC 3986's pchar and /: every other "
                           "ASCII character is a 400")
  (map (lambda (c) (if (rest-char? c) (string #\a c #\b) bad-request)) ascii)
  (let ((app (make-router (list (route "/f/*p" (GET (lambda (req) (req-path-param req "p"))))))))
    (map (lambda (c) (raw-ask app 'GET (string #\/ #\f #\/ #\a c #\b))) ascii)))

(test-equal (string-append "a mount's parameter holds raw only RFC 3986's pchar: every other ASCII "
                           "character is a 400, and the mount's handler doesn't run")
  (map (lambda (c) (if (capture-char? c) (list (string #\a c #\b) "/x") bad-request))
       ascii-but-slash)
  (let ((app (make-router (list (mount "/m/:k"
                                       (lambda (req) (list (req-path-param req "k") (req-path req))))))))
    (map (lambda (c) (raw-ask app 'GET (string #\/ #\m #\/ #\a c #\b #\/ #\x))) ascii-but-slash)))

(test-equal (string-append "a mount's rest is no capture: every ASCII character reaches the mount's "
                           "handler as it came")
  (map (lambda (c) (string #\/ #\x c #\y)) ascii)
  (let ((app (make-router (list (mount "/m" (lambda (req) (req-path req)))))))
    (map (lambda (c) (raw-ask app 'GET (string #\/ #\m #\/ #\x c #\y))) ascii)))

;; unpathable : (Listof Char) — the ASCII a capture can't hold raw, but %,
;; which the escape rows hold: the controls, space, " # < > ? [ \ ] ^ ` { |
;; } and DEL.
(define unpathable
  (filter (lambda (c) (not (or (rest-char? c) (char=? c #\%)))) ascii))

;; at-every-position : String String -> (Listof String)
;; BASE with PIECE put before each of its characters in turn, then after
;; its last.
(define (at-every-position base piece)
  (let loop ((k (string-length base)) (acc '()))
    (if (< k 0)
        acc
        (loop (- k 1)
              (cons (string-append (substring base 0 k) piece
                                   (substring base k (string-length base)))
                    acc)))))

;; Escapes that don't decode: malformed, then bytes that aren't UTF-8.
(define undecodable
  '("%" "%4" "%G1" "%4G" "%FF" "%80" "%BF" "%C0%AF" "%C1%BF" "%E0%80%AF" "%E0%9F%BF"
    "%ED%A0%80" "%F0%8F%BF%BF" "%F4%90%80%80" "%F5%80%80%80" "%E2%82" "%C3"))

;; A parameter's value of ten characters and a catch-all's of eleven, none
;; of them a hex digit.
(define plain-value "ghijklmnop")
(define plain-rest "gh/ij/kl/mn")

(define (every-undecodable base)
  (apply append (map (lambda (piece) (at-every-position base piece)) undecodable)))

(test-equal
  "an escape that doesn't decode is a 400 at every position of a parameter's ten-character value"
  (map (lambda (v) (cons v bad-request)) (every-undecodable plain-value))
  (let ((app (make-router (list (route "/u/:id" (GET the-param))))))
    (map (lambda (v) (cons v (ask app 'GET (string-append "/u/" v))))
         (every-undecodable plain-value))))

(test-equal "an escape that doesn't decode is a 400 at every position of a catch-all's value"
  (map (lambda (v) (cons v bad-request)) (every-undecodable plain-rest))
  (let ((app (make-router (list (route "/f/*p" (GET the-param))))))
    (map (lambda (v) (cons v (ask app 'GET (string-append "/f/" v))))
         (every-undecodable plain-rest))))

(test-equal
  "escapes that decode decode at every position of a value, a parameter's or a catch-all's"
  (list (at-every-position plain-value "é\x1F600;/") (at-every-position plain-rest "é\x1F600;/"))
  (let ((app (make-router (list (route "/u/:id" (GET (lambda (req) (req-path-param req "id"))))
                                (route "/f/*p" (GET (lambda (req) (req-path-param req "p"))))))))
    (list (map (lambda (v) (ask app 'GET (string-append "/u/" v)))
               (at-every-position plain-value "%C3%A9%F0%9F%98%80%2F"))
          (map (lambda (v) (ask app 'GET (string-append "/f/" v)))
               (at-every-position plain-rest "%C3%A9%F0%9F%98%80%2F")))))

;; every-unpathable : String -> (Listof String)
;; BASE with each character of unpathable put at each of its positions.
(define (every-unpathable base)
  (apply append (map (lambda (c) (at-every-position base (string c))) unpathable)))

;; A parameter's value and a catch-all's with escapes in them, so a raw
;; character after the first % is read by the decoder, not the plain scan.
(define escaped-value "g%C3%A9h%2Fi")
(define escaped-rest "g%C3%A9/h%2Fi/j")

(test-equal (string-append "a raw character a path can't hold is a 400 at every position of a "
                           "parameter's value, plain or escaped")
  (map (lambda (v) (cons v bad-request))
       (append (every-unpathable plain-value) (every-unpathable escaped-value)))
  (let ((app (make-router (list (route "/u/:id" (GET the-param))))))
    (map (lambda (v) (cons v (raw-ask app 'GET (string-append "/u/" v))))
         (append (every-unpathable plain-value) (every-unpathable escaped-value)))))

(test-equal (string-append "a raw character a path can't hold is a 400 at every position of a "
                           "catch-all's value, plain or escaped")
  (map (lambda (v) (cons v bad-request))
       (append (every-unpathable plain-rest) (every-unpathable escaped-rest)))
  (let ((app (make-router (list (route "/f/*p" (GET the-param))))))
    (map (lambda (v) (cons v (raw-ask app 'GET (string-append "/f/" v))))
         (append (every-unpathable plain-rest) (every-unpathable escaped-rest)))))

(test-equal "the escaped bases decode, so the rows above are about the raw character alone"
  (list "géh/i" "gé/h/i/j")
  (let ((app (make-router (list (route "/u/:id" (GET the-param))
                                (route "/f/*p" (GET (lambda (req) (req-path-param req "p"))))))))
    (list (raw-ask app 'GET (string-append "/u/" escaped-value))
          (raw-ask app 'GET (string-append "/f/" escaped-rest)))))

(test-equal
  "the captures are decoded before the method is asked: a malformed one is a 400, not the 405"
  (list bad-request (not-allowed "GET, HEAD"))
  (asks (make-router (list (route "/u/:id" (GET the-param)))) '((DELETE "/u/%G1") (DELETE "/u/a"))))

;;; ------------------------------------------------------------------------
;;; The method

(test-equal "the method picks the route's handler"
  '((show GET "/users/42" "/users/:id" (("id" . "42")) "q=7")
    (update PUT "/users/42" "/users/:id" (("id" . "42")) "q=7")
    (delete DELETE "/users/42" "/users/:id" (("id" . "42")) "q=7"))
  (asks (make-router (list (route "/users/:id" (GET (tell 'show)) (PUT (tell 'update))
                                  (DELETE (tell 'delete)))))
        '((GET "/users/42?q=7") (PUT "/users/42?q=7") (DELETE "/users/42?q=7"))))

(test-equal
  "a path has one route: DELETE /users/new is /users/new's 405, though /users/:id has a DELETE"
  (twice (list (not-allowed "GET, HEAD")))
  (in-both-orders (list (route "/users/new" (GET (tell 'new)))
                        (route "/users/:id" (GET (tell 'show)) (DELETE (tell 'delete))))
                  '((DELETE "/users/new?q=7"))))

(test-equal (string-append "a 405's Allow is the route's methods as listed, HEAD right after GET "
                           "when the route has no HEAD of its own")
  (list (not-allowed "POST, GET, HEAD, PROPFIND")
        (not-allowed "HEAD, PUT, GET")
        (not-allowed "PUT, PATCH, DELETE, OPTIONS")
        (not-allowed "GET, HEAD"))
  (list (ask (make-router (list (route "/x" (POST h) (GET h) (METHOD 'PROPFIND h)))) 'PATCH
             "/x?q=7")
        (ask (make-router (list (route "/x" (METHOD 'HEAD h) (PUT h) (GET h)))) 'POST "/x?q=7")
        (ask (make-router (list (route "/x" (PUT h) (PATCH h) (DELETE h) (OPTIONS h)))) 'GET
             "/x?q=7")
        (ask (make-router (list (route "/x" (GET h)))) 'POST "/x?q=7")))

(test-equal (string-append "HEAD goes to the route's own HEAD, else its GET, else its ANY, the "
                           "method left HEAD; with none of them, a 405")
  (list '(own-head HEAD "/x" "/x" () "q=7")
        '(get HEAD "/x" "/x" () "q=7")
        '(get HEAD "/x" "/x" () "q=7")
        '(any HEAD "/x" "/x" () "q=7")
        (not-allowed "POST"))
  (list (ask (make-router (list (route "/x" (GET (tell 'get)) (METHOD 'HEAD (tell 'own-head))
                                       (ANY (tell 'any))))) 'HEAD "/x?q=7")
        (ask (make-router (list (route "/x" (GET (tell 'get))))) 'HEAD "/x?q=7")
        (ask (make-router (list (route "/x" (ANY (tell 'any)) (GET (tell 'get))))) 'HEAD "/x?q=7")
        (ask (make-router (list (route "/x" (POST (tell 'post)) (ANY (tell 'any))))) 'HEAD "/x?q=7")
        (ask (make-router (list (route "/x" (POST (tell 'post))))) 'HEAD "/x?q=7")))

(test-equal "ANY takes every method the route doesn't list, and a route with ANY never answers 405"
  '((get GET "/x" "/x" () "q=7")
    (any POST "/x" "/x" () "q=7")
    (any PROPFIND "/x" "/x" () "q=7")
    (only-any BREW "/y" "/y" () "q=7"))
  (asks (make-router (list (route "/x" (GET (tell 'get)) (ANY (tell 'any)))
                           (route "/y" (ANY (tell 'only-any)))))
        '((GET "/x?q=7") (POST "/x?q=7") (PROPFIND "/x?q=7") (BREW "/y?q=7"))))

(test-equal
  "METHOD names any method: (METHOD 'GET h) is GET, HEAD and all, and (METHOD 'PROPFIND h) PROPFIND"
  (list '(get HEAD "/x" "/x" () "q=7") '(find PROPFIND "/x" "/x" () "q=7")
        (not-allowed "GET, HEAD, PROPFIND"))
  (asks (make-router (list (route "/x" (METHOD 'GET (tell 'get)) (METHOD 'PROPFIND (tell 'find)))))
        '((HEAD "/x?q=7") (PROPFIND "/x?q=7") (PUT "/x?q=7"))))

(test-equal "each method constructor names its own method"
  '((get GET) (post POST) (put PUT) (patch PATCH) (delete DELETE) (options OPTIONS))
  (let ((app (make-router (list (route "/x" (OPTIONS (tell 'options)) (DELETE (tell 'delete))
                                       (PATCH (tell 'patch))
                                       (PUT (tell 'put)) (POST (tell 'post)) (GET (tell 'get)))))))
    (map (lambda (a) (list (car a) (cadr a)))
         (asks app
               '((GET "/x") (POST "/x") (PUT "/x") (PATCH "/x") (DELETE "/x") (OPTIONS "/x"))))))

;;; ------------------------------------------------------------------------
;;; Middleware

(test-equal (string-append "a group's middleware wraps each handler under it in wrap's order, the "
                           "outer group's outermost: (wrap (wrap h m3) m1 m2)")
  '(((applied m3) (applied m1) (applied m2))
    (m2 m1 m3 c GET "/a/b/c" "/a/b/c" () "q=7")
    ((in m2) (in m1) (in m3) (out m3) (out m1) (out m2)))
  (begin
    (take-log!)
    (let* ((app (make-router (list (group "/a" (list (tagging 'm1) (tagging 'm2))
                                     (group "/b" (list (tagging 'm3))
                                       (route "/c" (GET (tell 'c))))))))
           (applied (take-log!))
           (answer (ask app 'GET "/a/b/c?q=7")))
      (list applied answer (take-log!)))))

(test-equal (string-append "a group's middleware is applied once a handler, mounts' included, when "
                           "the router is made, not again a request")
  '(((applied m) (applied m) (applied m)) ((in m) (out m) (in m) (out m) (in m) (out m)))
  (begin
    (take-log!)
    (let* ((app (make-router (list (group "/g" (list (tagging 'm))
                                     (route "/x" (GET (tell 'get)) (POST (tell 'post)))
                                     (mount "/m" (tell 'mounted))))))
           (applied (take-log!)))
      (asks app '((GET "/g/x") (POST "/g/x") (GET "/g/m/a")))
      (list applied (take-log!)))))

(test-equal (string-append "a group's middleware runs only for a request that matched path and "
                           "method: not for a 404, a 405 or a 400")
  (list (list not-found (not-allowed "GET, HEAD") bad-request '(m x GET "/g/x" "/g/x" () "q=7"))
        '((in m) (out m)))
  (let ((app (make-router (list (group "/g" (list (tagging 'm))
                                  (route "/x" (GET (tell 'x)))
                                  (route "/u/:id" (GET (tell 'u))))))))
    (take-log!)
    (let ((answers (asks app '((GET "/g/nope?q=7") (PUT "/g/x?q=7") (GET "/g/u/%G1?q=7")
                               (GET "/g/x?q=7")))))
      (list answers (take-log!)))))

(test-equal "a group's middleware wraps a mount under it, and no route beside the group"
  (list '((m mounted DELETE "/a" "/g/m" () "q=7") (y GET "/y" "/y" () "q=7")) '((in m) (out m)))
  (let ((app (make-router (list (group "/g" (list (tagging 'm)) (mount "/m" (tell 'mounted)))
                                (route "/y" (GET (tell 'y)))))))
    (take-log!)
    (let ((answers (asks app '((DELETE "/g/m/a?q=7") (GET "/y?q=7")))))
      (list answers (take-log!)))))

(test-equal "middleware around the router runs for every request: 404, 405, 400 and a match"
  (list (list (cons 'outer not-found) (cons 'outer (not-allowed "GET, HEAD"))
              (cons 'outer bad-request)
              '(outer x GET "/u/7" "/u/:id" (("id" . "7")) "q=7"))
        '((applied outer) (in outer) (out outer) (in outer) (out outer) (in outer) (out outer)
          (in outer) (out outer)))
  (begin
    (take-log!)
    (let* ((app (wrap (make-router (list (route "/u/:id" (GET (tell 'x))))) (tagging 'outer)))
           (answers (asks app '((GET "/nope?q=7") (PUT "/u/7?q=7") (GET "/u/%4?q=7")
                                (GET "/u/7?q=7")))))
      (list answers (take-log!)))))

(test-equal "wrap-body-cap in a group gives its routes a cap of their own, inside the app's: the innermost wins"
  '((POST "/small" 4) (POST "/up/file" 100))
  (let* ((seen (lambda (req) (list (req-method req) (req-path req) (req-body-cap req))))
         (app (wrap (make-router (list (route "/small" (POST seen))
                                       (group "/up" (list (wrap-body-cap 100))
                                         (route "/file" (POST seen)))))
                    (wrap-body-cap 4))))
    (let* ((small (app (make-test-req 'POST "/small?q=7")))
           (file (app (make-test-req 'POST "/up/file?q=7"))))
      (list small file))))

(test-equal "(route \"\" ...) inside a group takes the group's prefix as its template"
  '((m admin GET "/admin" "/admin" () "q=7") (m stats GET "/admin/stats" "/admin/stats" () "q=7"))
  (let ((app (make-router (list (group "/admin" (list (tagging 'm))
                                  (route "" (GET (tell 'admin)))
                                  (route "/stats" (GET (tell 'stats))))))))
    (asks app '((GET "/admin?q=7") (GET "/admin/stats?q=7")))))

;;; ------------------------------------------------------------------------
;;; Mounts

(test-equal (string-append "a mount's handler sees the rest of the path, / when nothing or only / "
                           "follows, for any method; its req-route is its template")
  (list '(mounted GET "/" "/p" () "q=7")
        '(mounted POST "/" "/p" () "q=7")
        '(mounted BREW "/a" "/p" () "q=7")
        '(mounted GET "/a/" "/p" () "q=7")
        '(mounted GET "/a/b" "/p" () "q=7")
        not-found)
  (asks (make-router (list (mount "/p" (tell 'mounted))))
        '((GET "/p?q=7") (POST "/p/?q=7") (BREW "/p/a?q=7") (GET "/p/a/?q=7") (GET "/p/a/b?q=7")
          (GET "/px?q=7"))))

(test-equal "a mount captures its parameters, decoded"
  '((mounted GET "/x" "/api/:v" (("v" . "2")) "q=7")
    (mounted GET "/" "/api/:v" (("v" . "a b")) "q=7"))
  (asks (make-router (list (mount "/api/:v" (tell 'mounted))))
        '((GET "/api/2/x?q=7") (GET "/api/a%20b?q=7"))))

(test-equal (string-append "a mount whose capture doesn't decode is a 400: neither its group's "
                           "middleware nor its handler runs")
  (list (list bad-request bad-request '(m mounted GET "/x" "/g/api/:v" (("v" . "2")) "q=7"))
        '((in m) (out m)))
  (let ((app (make-router (list (group "/g" (list (tagging 'm))
                                       (mount "/api/:v" (tell 'mounted)))))))
    (take-log!)
    (let ((answers (asks app '((GET "/g/api/%G1/x?q=7") (GET "/g/api/gh%FFij/x?q=7")
                               (GET "/g/api/2/x?q=7")))))
      (list answers (take-log!)))))

(test-equal
  "a router under a mount joins: the mount's template then its own, the mount's params then its own"
  '(show GET "/users/7" "/api/:v/users/:id" (("v" . "2") ("id" . "7")) "q=7")
  (ask (make-router (list (mount "/api/:v"
                                 (make-router (list (route "/users/:id" (GET (tell 'show))))))))
       'GET "/api/2/users/7?q=7"))

(test-equal "routers under mounts under routers under mounts join all the way down"
  '(deep GET "/c/2" "/a/b/:x/c/:y" (("x" . "1") ("y" . "2")) "q=7")
  (let* ((inner (make-router (list (route "/c/:y" (GET (tell 'deep))))))
         (middle (make-router (list (mount "/b/:x" inner)))))
    (ask (make-router (list (mount "/a" middle))) 'GET "/a/b/1/c/2?q=7")))

(test-equal "req-path-param answers the last param of its name: a router's own, under a mount's"
  '("2" (("id" . "1") ("id" . "2")))
  (let ((inner (make-router
                (list (route "/p/:id"
                             (GET (lambda (req)
                                    (list (req-path-param req "id") (req-path-params req)))))))))
    (ask (make-router (list (mount "/u/:id" inner))) 'GET "/u/1/p/2")))

(test-equal "a mount over a router whose route or mount captures nothing joins all the same"
  '((users GET "/users" "/api/:v/users" (("v" . "2")) "q=7")
    (deep GET "/c" "/a/b" () "q=7"))
  (list (ask (make-router (list (mount "/api/:v"
                                       (make-router (list (route "/users" (GET (tell 'users))))))))
             'GET "/api/2/users?q=7")
        (ask (make-router (list (mount "/a" (make-router (list (mount "/b" (tell 'deep)))))))
             'GET "/a/b/c?q=7")))

(test-equal
  "a router reached through a route under a mount joins onto the mount, as one right under it does"
  '((r3 GET "/users/7" "/api/:v/users/:id" (("v" . "2") ("id" . "7")) "q=7")
    (r2 GET "/other/7" "/api/:v/other/*rest" (("v" . "2") ("rest" . "7")) "q=7"))
  (let* ((r3 (make-router (list (route "/users/:id" (GET (tell 'r3))))))
         (r2 (make-router (list (route "/users/*rest" (GET r3))
                                (route "/other/*rest" (GET (tell 'r2)))))))
    (asks (make-router (list (mount "/api/:v" r2)))
          '((GET "/api/2/users/7?q=7") (GET "/api/2/other/7?q=7")))))

(test-equal "a router reached through a words-only route at the top replaces the match"
  '(inner GET "/admin" "/admin" () "q=7")
  (ask (make-router (list (route "/admin"
                                 (GET (make-router (list (route "/admin" (GET (tell 'inner)))))))))
       'GET "/admin?q=7"))

(test-equal
  "a router reached other than through a mount replaces the match: it matched the whole path itself"
  '(show GET "/a/z/c" "/a/:b/c" (("b" . "z")) "q=7")
  (ask (make-router (list (route "/a/*rest"
                                 (GET (make-router (list (route "/a/:b/c" (GET (tell 'show)))))))))
       'GET "/a/z/c?q=7"))

(test-equal (string-append "a group's middleware sees around a mount what it sees around a route: "
                           "the path as matched, the match set")
  (list (list '(stats "/admin/stats" "/admin/stats" () "")
              '(assets "/x.css" "/admin/assets" () "/admin/assets"))
        '((saw m "/admin/stats" "/admin/stats" () "")
          (saw m "/admin/assets/x.css" "/admin/assets" () "")))
  (let ((app (make-router (list (group "/admin" (list (seeing 'm))
                                  (route "/stats" (GET (place 'stats)))
                                  (mount "/assets" (place 'assets)))))))
    (take-log!)
    (let ((answers (asks app '((GET "/admin/stats") (GET "/admin/assets/x.css")))))
      (list answers (take-log!)))))

(test-equal (string-append "req-mount-path then req-path is the path the server read, for every "
                           "middleware and handler: around a route and a mount in one group, in a "
                           "mount's handler, under a mount, with groups at both levels")
  (list (list '(outer-route "/o/x" "/o/x" () "")
              '(inner-route "/g/r/7" "/o/a/:v/g/r/:id" (("v" . "2") ("id" . "7")) "/o/a/2")
              '(inner-mount "/c/d" "/o/a/:v/g/b" (("v" . "2")) "/o/a/2/g/b")
              '(inner-mount "/" "/o/a/:v/g/b" (("v" . "2")) "/o/a/2/g/b"))
        '((saw outer "/o/x" "/o/x" () "")
          (saw outer "/o/a/2/g/r/7" "/o/a/:v" (("v" . "2")) "")
          (saw inner "/g/r/7" "/o/a/:v/g/r/:id" (("v" . "2") ("id" . "7")) "/o/a/2")
          (saw outer "/o/a/2/g/b/c/d" "/o/a/:v" (("v" . "2")) "")
          (saw inner "/g/b/c/d" "/o/a/:v/g/b" (("v" . "2")) "/o/a/2")
          (saw outer "/o/a/2/g/b" "/o/a/:v" (("v" . "2")) "")
          (saw inner "/g/b" "/o/a/:v/g/b" (("v" . "2")) "/o/a/2")))
  (let* ((inner (make-router (list (group "/g" (list (seeing 'inner))
                                     (route "/r/:id" (GET (place 'inner-route)))
                                     (mount "/b" (place 'inner-mount))))))
         (app (make-router (list (group "/o" (list (seeing 'outer))
                                   (route "/x" (GET (place 'outer-route)))
                                   (mount "/a/:v" inner))))))
    (take-log!)
    (let ((answers (asks app '((GET "/o/x") (GET "/o/a/2/g/r/7") (GET "/o/a/2/g/b/c/d")
                               (GET "/o/a/2/g/b")))))
      (list answers (take-log!)))))

(test-equal (string-append "req-mount-path then req-path is the path the server read under a "
                           "mount no middleware wraps, around a mount one does")
  (list '((inner-mount "/c" "/m/g/b" () "/m/g/b"))
        '((saw inner "/g/b/c" "/m/g/b" () "/m")))
  (let* ((inner (make-router (list (group "/g" (list (seeing 'inner))
                                     (mount "/b" (place 'inner-mount))))))
         (app (make-router (list (mount "/m" inner)))))
    (take-log!)
    (let ((answers (asks app '((GET "/m/g/b/c")))))
      (list answers (take-log!)))))

(test-equal (string-append "a mount's handler sees the rest of the path the router matched, even "
                           "when its group's middleware rewrote it")
  '(mounted "/a" "/g/m" () "/g/m")
  (let ((elsewhere (lambda (next)
                     (lambda (req) (next (req-with-path req "/else/z"))))))
    (ask (make-router (list (group "/g" (list elsewhere) (mount "/m" (place 'mounted)))))
         'GET "/g/m/a?q=7")))

(test-equal (string-append "a router under a mount that finds nothing hands its not-found handler "
                           "the request as the mount left it")
  '(inner-missing GET "/nope" "/api" () "q=7")
  (ask (make-router (list (mount "/api"
                                 (make-router (list (route "/x" (GET h))) (tell 'inner-missing)))))
       'GET "/api/nope?q=7"))

(test-equal (string-append "a router under a mount a group's middleware wraps hands its not-found "
                           "handler the mount's match and the rest, / for nothing")
  '((nf "/nope" "/g/m/:k" (("k" . "5")) "/g/m/5")
    (nf "/" "/g/m/:k" (("k" . "5")) "/g/m/5"))
  (asks (make-router (list (group "/g" (list (lambda (next) (lambda (req) (next req))))
                             (mount "/m/:k"
                                    (make-router (list (route "/x" (GET h))) (place 'nf))))))
        '((GET "/g/m/5/nope") (GET "/g/m/5"))))

(test-equal (string-append "a router reached through a route that finds nothing hands its "
                           "not-found handler that route's match: at the top, and under a mount")
  '((top-nf "/r/7" "/r/:id" (("id" . "7")) "")
    (under-nf "/r/7" "/m/:k/r/:id" (("k" . "5") ("id" . "7")) "/m/5"))
  (let ((inner (lambda (name) (make-router (list (route "/r/x" (GET h))) (place name)))))
    (list (ask (make-router (list (route "/r/:id" (GET (inner 'top-nf))))) 'GET "/r/7")
          (ask (make-router
                (list (mount "/m/:k"
                             (make-router (list (route "/r/:id" (GET (inner 'under-nf))))))))
               'GET "/m/5/r/7"))))

(test-equal (string-append "a request a group's middleware hands on without the mount's match "
                           "reaches the mount's handler as it is, as a route's handler gets it: "
                           "one the middleware made, one a router of its own matched")
  '((route "/fresh" #f () "") (mounted "/fresh" #f () "")
    (route "/g/m/5" "/g/m/:x" (("x" . "5")) "") (mounted "/g/m/5" "/g/m/:x" (("x" . "5")) ""))
  (let ((fresh (lambda (next) (lambda (req) (next (make-test-req 'GET "/fresh")))))
        (routing (lambda (next) (make-router (list (route "/g/m/:x" (GET next))) next))))
    (list (ask (make-router (list (group "/g" (list fresh) (route "/m/:k" (GET (place 'route))))))
               'GET "/g/m/5")
          (ask (make-router (list (group "/g" (list fresh) (mount "/m" (place 'mounted)))))
               'GET "/g/m/5")
          (ask (make-router (list (group "/g" (list routing) (route "/m/:k" (GET (place 'route))))))
               'GET "/g/m/5")
          (ask (make-router (list (group "/g" (list routing) (mount "/m" (place 'mounted)))))
               'GET "/g/m/5"))))

;;; ------------------------------------------------------------------------
;;; Not found, and the request's accessors

(test-equal "with no route for the path, the default not-found answers an empty 404"
  not-found
  (ask (make-router (list (route "/x" (GET h)))) 'GET "/y?q=7"))

(test-equal "a not-found handler of the app's own gets the request as it came, no match on it"
  '(missing POST "/y" #f () "q=7")
  (ask (make-router (list (route "/x" (GET h))) (tell 'missing)) 'POST "/y?q=7"))

;;; ------------------------------------------------------------------------
;;; The app's own 404, 400 and 405

;; refusing : Symbol Nat Headers -> Handler
;; Notes what it saw, as tell answers it, and answers STATUS with HEADERS
;; and no body.
(define (refusing name status headers)
  (lambda (req)
    (note! ((tell name) req))
    (make-res status headers #f)))

(test-equal "on-not-found's handler is the not-found handler: it gets the request as it came, no match on it"
  '(missing POST "/y" #f () "q=7")
  (ask (make-router (list (route "/x" (GET h))) (on-not-found (tell 'missing))) 'POST "/y?q=7"))

(test-equal (string-append "the 400 handler gets the request as it came, no match on it, for each "
                           "capture that doesn't decode, in a parameter, a catch-all and a mount's "
                           "parameter; nothing else runs")
  (list (map (lambda (p) (list 'bad 'GET p #f '() "q=7"))
             (list "/u/%G1" "/u/%FF" (string #\/ #\u #\/ #\a (integer->char #xE9)) "/u/a b"
                   "/u/a?b" "/f/a/b%4" "/f/a/b c" "/m/a%FF/x" "/m/a b/x"))
        '())
  (let ((app (make-router (list (route "/u/:id" (GET (running 'u)))
                                (route "/f/*p" (GET (running 'f)))
                                (mount "/m/:k" (running 'm)))
                          (on-bad-request (tell 'bad)))))
    (take-log!)
    (let ((answers (map (lambda (p) (raw-ask app 'GET p))
                        (list "/u/%G1" "/u/%FF" (string #\/ #\u #\/ #\a (integer->char #xE9))
                              "/u/a b" "/u/a?b" "/f/a/b%4" "/f/a/b c" "/m/a%FF/x" "/m/a b/x"))))
      (list answers (take-log!)))))

(test-equal (string-append "a router under a mount hands its 400 handler the request as the mount "
                           "left it, as its not-found handler: the mount's match and the rest, a "
                           "group's middleware around the mount or not")
  '((bad "/u/%FF" "/api/:v" (("v" . "2")) "/api/2")
    (bad "/u/a b" "/g/api/:v" (("v" . "3")) "/g/api/3"))
  (let ((inner (lambda () (make-router (list (route "/u/:id" (GET h))) (on-bad-request (place 'bad))))))
    (list (raw-ask (make-router (list (mount "/api/:v" (inner)))) 'GET "/api/2/u/%FF")
          (raw-ask (make-router (list (group "/g" (list (lambda (next) (lambda (req) (next req))))
                                        (mount "/api/:v" (inner)))))
                   'GET "/g/api/3/u/a b"))))

(test-equal (string-append "the 405 handler gets the request with the route's match: req-route its "
                           "template, req-path-params decoded; the router sets allow on its answer, "
                           "as the default 405 carries it")
  '((res 405 (("content-type" . "text/plain") ("allow" . "GET, HEAD, PROPFIND")) #f)
    ((na DELETE "/users/a%20b" "/users/:id" (("id" . "a b")) "q=7")))
  (let ((app (make-router (list (route "/users/:id" (GET h) (METHOD 'PROPFIND h)))
                          (on-method-not-allowed
                           (refusing 'na 405 '(("content-type" . "text/plain")))))))
    (take-log!)
    (let ((answer (ask app 'DELETE "/users/a%20b?q=7")))
      (list answer (take-log!)))))

(test-equal (string-append "the router's allow replaces every allow the 405 handler set, in any "
                           "case, where the first stood; a status of the handler's own gets it too")
  (list '(res 405 (("x-a" . "1") ("allow" . "GET, HEAD") ("x-b" . "2")) #f)
        '(res 404 (("allow" . "POST")) "gone"))
  (list (ask (make-router (list (route "/x" (GET h)))
                          (on-method-not-allowed
                           (lambda (req)
                             (make-res 405 '(("x-a" . "1") ("Allow" . "PUT") ("x-b" . "2")
                                             ("allow" . "DELETE"))
                                       #f))))
             'PUT "/x?q=7")
        (ask (make-router (list (route "/y" (POST h)))
                          (on-method-not-allowed (lambda (req) (make-res 404 '() "gone"))))
             'GET "/y?q=7")))

(test-equal (string-append "a 405 handler's answer that is no res goes on untouched; at a words-only "
                           "route it sees that route's match")
  '(na PUT "/x" "/x" () "q=7")
  (ask (make-router (list (route "/x" (GET h))) (on-method-not-allowed (tell 'na))) 'PUT "/x?q=7"))

(test-equal "HEAD at a route with no GET, HEAD or ANY is the 405 handler's, which sees HEAD"
  '(res 405 (("allow" . "POST")) #f)
  (begin
    (take-log!)
    (let ((answer (ask (make-router (list (route "/x" (POST h)))
                                    (on-method-not-allowed (refusing 'na 405 '())))
                       'HEAD "/x?q=7")))
      (if (equal? (take-log!) '((na HEAD "/x" "/x" () "q=7"))) answer 'not-seen-as-head))))

(test-equal (string-append "a router under a mount hands its 405 handler the joined template and "
                           "params, groups' prefixes in it; no group's middleware runs around it, "
                           "and middleware around the router does")
  '((outer na "/g/r/7" "/api/:v/g/r/:id" (("v" . "2") ("id" . "7")) "/api/2")
    ((in outer) (out outer)))
  (let* ((inner (make-router (list (group "/g" (list (tagging 'm)) (route "/r/:id" (GET h))))
                             (on-method-not-allowed (place 'na))))
         (app (wrap (make-router (list (mount "/api/:v" inner))) (tagging 'outer))))
    (take-log!)
    (let ((answer (ask app 'PUT "/api/2/g/r/7?q=7")))
      (list answer (take-log!)))))

(test-equal (string-append "the captures are decoded before the method is asked: a capture that "
                           "doesn't decode is the 400 handler's, not the 405 handler's")
  '((bad DELETE "/u/%G1" #f () "q=7") (bad DELETE "/u/a b" #f () "q=7")
    (na DELETE "/u/a" "/u/:id" (("id" . "a")) "q=7"))
  (let ((app (make-router (list (route "/u/:id" (GET h)))
                          (on-bad-request (tell 'bad)) (on-method-not-allowed (tell 'na)))))
    (list (raw-ask app 'DELETE "/u/%G1") (raw-ask app 'DELETE "/u/a b") (raw-ask app 'DELETE "/u/a"))))

;; The routes and requests the option rows ask: a path no route takes, a
;; capture that doesn't decode, and a method the route doesn't take.
(define option-routes (lambda () (list (route "/u/:id" (GET h)))))
(define option-requests '((GET "/nope?q=7") (GET "/u/%FF?q=7") (PUT "/u/7?q=7")))

;; The six orders of three things, as the places to take them from.
(define orders '((0 1 2) (0 2 1) (1 0 2) (1 2 0) (2 0 1) (2 1 0)))

(test-equal (string-append "the options come in any order, a bare procedure among them the "
                           "not-found handler: each answer goes to its own handler")
  (map (lambda (o)
         '((nf GET "/nope" #f () "q=7") (br GET "/u/%FF" #f () "q=7")
           (na PUT "/u/7" "/u/:id" (("id" . "7")) "q=7")))
       (append orders orders))
  (let ((options (lambda (bare?)
                   (list (if bare? (tell 'nf) (on-not-found (tell 'nf)))
                         (on-bad-request (tell 'br))
                         (on-method-not-allowed (tell 'na))))))
    (map (lambda (bare? order)
           (let ((os (options bare?)))
             (asks (apply make-router (option-routes) (map (lambda (k) (list-ref os k)) order))
                   option-requests)))
         (append (map (lambda (o) #f) orders) (map (lambda (o) #t) orders))
         (append orders orders))))

(test-equal "each option left out keeps its default: the empty 404, the empty 400, the empty 405 with its allow"
  (list (list not-found '(br GET "/u/%FF" #f () "q=7") (not-allowed "GET, HEAD"))
        (list not-found bad-request '(na PUT "/u/7" "/u/:id" (("id" . "7")) "q=7"))
        (list '(nf GET "/nope" #f () "q=7") bad-request (not-allowed "GET, HEAD"))
        (list not-found bad-request (not-allowed "GET, HEAD")))
  (list (asks (make-router (option-routes) (on-bad-request (tell 'br))) option-requests)
        (asks (make-router (option-routes) (on-method-not-allowed (tell 'na))) option-requests)
        (asks (make-router (option-routes) (on-not-found (tell 'nf))) option-requests)
        (asks (make-router (option-routes)) option-requests)))

(test-equal (string-append "the default 404, 400 and 405 are made once: each request gets the same "
                           "response, beside the other options or without them")
  '((#t #t #t) (#t #t) (#t #t))
  (let ((same (lambda (app method target)
                (eq? (app (make-test-req method target)) (app (make-test-req method target))))))
    (let ((bare (make-router (option-routes)))
          (nf (make-router (option-routes) (on-not-found (tell 'nf))))
          (br-na (make-router (option-routes) (on-bad-request (tell 'br))
                              (on-method-not-allowed (tell 'na)))))
      (list (list (same bare 'GET "/nope") (same bare 'GET "/u/%FF") (same bare 'PUT "/u/7"))
            (list (same nf 'GET "/u/%FF") (same nf 'PUT "/u/7"))
            (list (same br-na 'GET "/nope") (same br-na 'GET "/nope?q=7"))))))

(test-equal
  "req-route, req-path-params and req-path-param on a request no router matched: #f, () and #f"
  '(#f () #f)
  (let ((r (make-test-req 'GET "/users/42?q=7")))
    (list (req-route r) (req-path-params r) (req-path-param r "id"))))

(test-equal
  "req-mount-path is \"\" on a request no router matched, and on one a route at the top took"
  '("" (top "/users/7" "/users/:id" (("id" . "7")) ""))
  (list (req-mount-path (make-test-req 'GET "/users/7"))
        (ask (make-router (list (route "/users/:id" (GET (place 'top))))) 'GET "/users/7")))

(test-equal "req-mount-path is what a mount took of the path, undecoded, whatever follows it"
  '((m "/users/7" "/api/:v" (("v" . "2")) "/api/2")
    (m "/" "/api/:v" (("v" . "2")) "/api/2")
    (m "/" "/api/:v" (("v" . "2")) "/api/2")
    (m "/x" "/api/:v" (("v" . "a b")) "/api/a%20b"))
  (asks (make-router (list (mount "/api/:v" (place 'm))))
        '((GET "/api/2/users/7") (GET "/api/2") (GET "/api/2/") (GET "/api/a%20b/x"))))

(test-equal
  "req-mount-path: a route under a mount answers the mount's part, and nested mounts' parts join"
  '((users "/users/7" "/api/:v/users/:id" (("v" . "2") ("id" . "7")) "/api/2")
    (files "/a/b" "/api/:v/files" (("v" . "2")) "/api/2/files")
    (v1 "/f" "/api/:v/v1/files" (("v" . "2")) "/api/2/v1/files")
    (via-route "/d" "/api/:v/b/c" (("v" . "2")) "/api/2/b/c"))
  (let* ((via (make-router (list (mount "/b/c" (place 'via-route)))))
         (inner (make-router (list (route "/users/:id" (GET (place 'users)))
                                   (mount "/files" (place 'files))
                                   (group "/v1" '() (mount "/files" (place 'v1)))
                                   (route "/b/*r" (GET via))))))
    (asks (make-router (list (mount "/api/:v" inner)))
          '((GET "/api/2/users/7") (GET "/api/2/files/a/b") (GET "/api/2/v1/files/f")
            (GET "/api/2/b/c/d")))))

(test-equal "req-mount-path joins the parts of three nested mounts"
  '(c "/d" "/a/:x/b/c" (("x" . "1")) "/a/1/b/c")
  (ask (make-router
        (list (mount "/a/:x"
                     (make-router
                      (list (mount "/b" (make-router (list (mount "/c" (place 'c))))))))))
       'GET "/a/1/b/c/d"))

(test-equal "req-mount-path refuses a non-request, and answers a string of the caller's own"
  '((assertion-violation req-mount-path (not-a-req)) "/api/2")
  (list (raised (lambda () (req-mount-path 'not-a-req)))
        (ask (make-router (list (mount "/api/:v" (lambda (req)
                                                   (let ((s (req-mount-path req)))
                                                     (string-set! s 1 #\X)
                                                     (req-mount-path req))))))
             'GET "/api/2/x")))

(test-equal (string-append "req-route, req-path-params and req-path-param refuse a non-request, "
                           "and req-path-param a name that is no string")
  '((assertion-violation req-route (not-a-req))
    (assertion-violation req-path-params (not-a-req))
    (assertion-violation req-path-param (not-a-req))
    (assertion-violation req-path-param (id)))
  (list (raised (lambda () (req-route 'not-a-req)))
        (raised (lambda () (req-path-params 'not-a-req)))
        (raised (lambda () (req-path-param 'not-a-req "id")))
        (raised (lambda () (req-path-param (make-test-req 'GET "/") 'id)))))

;;; ------------------------------------------------------------------------
;;; Cost: G4 bounds one req-set at 88 B.

(test-equal
  "a words-only route costs the request its one req-set and nothing more: at most 88 B a request"
  '(new-user at-most-88)
  (let* ((app (make-router (list (route "/" (GET h))
                                 (route "/users" (GET h) (POST h))
                                 (route "/users/new" (GET (lambda (req) 'new-user)))
                                 (route "/users/:id" (GET h) (DELETE h))
                                 (route "/users/:id/edit" (GET h))
                                 (group "/admin" (list (lambda (next) next))
                                   (route "/stats" (GET h)))
                                 (route "/static/*path" (GET h))
                                 (mount "/api" h))))
         (req (make-test-req 'GET "/users/new?q=7"))
         (per (bytes-a-call (lambda () (app req)) 10000)))
    (list (app req) (if (<= per 88) 'at-most-88 (list 'bytes-a-request (inexact per))))))

;; table-of-eight : -> (Listof Route) — the cost row's table above.
(define (table-of-eight)
  (list (route "/" (GET h))
        (route "/users" (GET h) (POST h))
        (route "/users/new" (GET (lambda (req) 'new-user)))
        (route "/users/:id" (GET h) (DELETE h))
        (route "/users/:id/edit" (GET h))
        (group "/admin" (list (lambda (next) next))
          (route "/stats" (GET h)))
        (route "/static/*path" (GET h))
        (mount "/api" h)))

(test-equal (string-append "the options cost the hit path nothing: a word route, a parameter route, "
                           "a catch-all and a mount each allocate in a router with all three what "
                           "they do in one without")
  '(same same same same)
  (let ((plain (make-router (table-of-eight)))
        (optioned (make-router (table-of-eight) (on-method-not-allowed h) (on-not-found h)
                               (on-bad-request h))))
    (map (lambda (target)
           (let* ((req (make-test-req 'GET target))
                  (without (bytes-a-call (lambda () (plain req)) 10000))
                  (with (bytes-a-call (lambda () (optioned req)) 10000)))
             (if (<= (abs (- with without)) 1) 'same (list target (inexact without) (inexact with)))))
         '("/users/new?q=7" "/users/42?q=7" "/static/a/b?q=7" "/api/x?q=7"))))

;; A mount's cost: the one req-set and its match, the rest of the path, and
;; the request req-with-path copies, 336 B here. A mount that a group's
;; middleware wraps pays a second req-set and a marker, inside that
;; middleware, so the middleware sees the part of the path the mounts above
;; it took.
(test-equal (string-append "a mount no group's middleware wraps costs 336 B, in a group with no "
                           "middleware too; one a middleware wraps pays one req-set more")
  '(at-most-336 at-most-336 one-req-set-more)
  (let* ((cost (lambda (app target)
                 (let ((req (make-test-req 'GET target)))
                   (bytes-a-call (lambda () (app req)) 10000))))
         (bare (cost (make-router (list (mount "/m" h))) "/m/x"))
         (in-group (cost (make-router (list (group "/g" '() (mount "/m" h)))) "/g/m/x"))
         (wrapped (cost (make-router (list (group "/g" (list (lambda (next) next)) (mount "/m" h))))
                        "/g/m/x")))
    (list (if (<= bare 340) 'at-most-336 (list 'bare (inexact bare)))
          (if (<= in-group 340) 'at-most-336 (list 'in-group (inexact in-group)))
          (if (<= 80 (- wrapped in-group) 112)
              'one-req-set-more
              (list 'wrapped-over-in-group (inexact (- wrapped in-group)))))))

;;; ------------------------------------------------------------------------
;;; Refusals at construction

(test-equal "route refuses a template that is no string, or neither \"\" nor beginning with /"
  '((assertion-violation route (users)) (assertion-violation route ("users"))
    (assertion-violation route ("users/")))
  (list (raised (lambda () (route 'users (GET h))))
        (raised (lambda () (route "users" (GET h))))
        (raised (lambda () (route "users/" (GET h))))))

(test-equal (string-append "a word holds exactly RFC 3986's pchar, unescaped: every other ASCII "
                           "character is refused, % included")
  (map (lambda (c)
         (if (memv c allowed-chars)
             'constructed
             (list 'assertion-violation 'route (list (string #\/ #\a c #\b) (string #\a c #\b)))))
       ascii-but-slash)
  (map (lambda (c) (constructed (lambda () (route (string #\/ #\a c #\b) (GET h)))))
       ascii-but-slash))

(test-equal
  "a parameter's name holds ASCII letters, digits, - and _: every other ASCII character is refused"
  (map (lambda (c)
         (if (memv c name-chars)
             'constructed
             (list 'assertion-violation 'route (list (string #\/ #\: #\a c) (string #\: #\a c)))))
       ascii-but-slash)
  (map (lambda (c) (constructed (lambda () (route (string #\/ #\: #\a c) (GET h)))))
       ascii-but-slash))

(test-equal
  "a catch-all's name holds ASCII letters, digits, - and _: every other ASCII character is refused"
  (map (lambda (c)
         (if (memv c name-chars)
             'constructed
             (list 'assertion-violation 'route (list (string #\/ #\* #\a c) (string #\* #\a c)))))
       ascii-but-slash)
  (map (lambda (c) (constructed (lambda () (route (string #\/ #\* #\a c) (GET h)))))
       ascii-but-slash))

(test-equal "a character past ASCII is refused in a word or a name"
  '((assertion-violation route ("/é" "é"))
    (assertion-violation route ("/x/aéb" "aéb"))
    (assertion-violation route ("/:é" ":é"))
    (assertion-violation route ("/*aé" "*aé")))
  (list (raised (lambda () (route "/é" (GET h))))
        (raised (lambda () (route "/x/aéb" (GET h))))
        (raised (lambda () (route "/:é" (GET h))))
        (raised (lambda () (route "/*aé" (GET h))))))

(test-equal (string-append "a parameter or catch-all needs a name, and holds no : or * after its "
                           "first; inside a word they are the word's")
  '((assertion-violation route ("/:" ":")) (assertion-violation route ("/x/*" "*"))
    (assertion-violation route ("/:a:b" ":a:b")) (assertion-violation route ("/*a*b" "*a*b"))
    constructed)
  (list (raised (lambda () (route "/:" (GET h))))
        (raised (lambda () (route "/x/*" (GET h))))
        (raised (lambda () (route "/:a:b" (GET h))))
        (raised (lambda () (route "/*a*b" (GET h))))
        (constructed (lambda () (route "/a:b/c*d" (GET h))))))

(test-equal
  "the words . and .. are refused: a client removes them from a path, so no request could reach one"
  '((assertion-violation route ("/a/../b" ".."))
    (assertion-violation route ("/./c" "."))
    (assertion-violation group ("/.." ".."))
    (assertion-violation mount ("/x/." "."))
    constructed)
  (list (raised (lambda () (route "/a/../b" (GET h))))
        (raised (lambda () (route "/./c" (GET h))))
        (raised (lambda () (group "/.." '() (route "/x" (GET h)))))
        (raised (lambda () (mount "/x/." h)))
        (constructed (lambda () (route "/.../.a/a./a.b" (GET h))))))

(test-equal "route refuses a route with no method entry"
  '((assertion-violation route ("/x")) (assertion-violation route ("/x")))
  (list (raised (lambda () (route "/x")))
        (raised (lambda () (route "/x" 'named)))))

(test-equal "route refuses what is no method entry: a name that is no symbol, a bare handler"
  (list '(assertion-violation route ("named")) (list 'assertion-violation 'route (list h)))
  (list (raised (lambda () (route "/x" "named" (GET h))))
        (raised (lambda () (route "/x" (GET h) h)))))

(test-equal
  "route refuses two entries for one method: (METHOD 'GET h) is GET, and (METHOD 'ANY h) ANY"
  '((assertion-violation route ("/x" GET))
    (assertion-violation route ("/x" GET))
    (assertion-violation route ("/x" ANY))
    (assertion-violation route ("/x" ANY))
    (assertion-violation route ("/x" PROPFIND)))
  (list (raised (lambda () (route "/x" (GET h) (POST h) (GET h))))
        (raised (lambda () (route "/x" 'named (GET h) (METHOD 'GET h))))
        (raised (lambda () (route "/x" (ANY h) (ANY h))))
        (raised (lambda () (route "/x" (ANY h) (METHOD 'ANY h))))
        (raised (lambda () (route "/x" (METHOD 'PROPFIND h) (METHOD 'PROPFIND h))))))

(test-equal "each method constructor refuses a handler that is no procedure"
  '((assertion-violation GET (x)) (assertion-violation POST (x)) (assertion-violation PUT (x))
    (assertion-violation PATCH (x)) (assertion-violation DELETE (x))
    (assertion-violation OPTIONS (x)) (assertion-violation ANY (x)))
  (map (lambda (make) (raised (lambda () (make 'x)))) (list GET POST PUT PATCH DELETE OPTIONS ANY)))

(test-equal "METHOD refuses a method that is no symbol, and a handler that is no procedure"
  '((assertion-violation METHOD ("PROPFIND")) (assertion-violation METHOD (x)))
  (list (raised (lambda () (METHOD "PROPFIND" h)))
        (raised (lambda () (METHOD 'PROPFIND 'x)))))

(test-equal (string-append "METHOD takes a name only of RFC 9110's tchar, no lower case: every "
                           "other ASCII character is refused")
  (map (lambda (c)
         (if (memv c method-chars)
             'constructed
             (list 'assertion-violation 'METHOD (list (string->symbol (string #\A c #\B))))))
       ascii)
  (map (lambda (c) (constructed (lambda () (METHOD (string->symbol (string #\A c #\B)) h)))) ascii))

(test-equal
  "METHOD refuses an empty name, a lower-case letter anywhere in one, and a character past ASCII"
  (list (list 'assertion-violation 'METHOD (list (string->symbol "")))
        '(assertion-violation METHOD (get)) '(assertion-violation METHOD (Get))
        '(assertion-violation METHOD (GEt))
        (list 'assertion-violation 'METHOD (list (string->symbol "GÉT")))
        'constructed 'constructed)
  (list (raised (lambda () (METHOD (string->symbol "") h)))
        (raised (lambda () (METHOD 'get h)))
        (raised (lambda () (METHOD 'Get h)))
        (raised (lambda () (METHOD 'GEt h)))
        (raised (lambda () (METHOD (string->symbol "GÉT") h)))
        (constructed (lambda () (METHOD 'M-SEARCH h)))
        (constructed (lambda () (METHOD 'PROPFIND h)))))

(test-equal (string-append "group refuses a bad prefix, middlewares that are no list, a middleware "
                           "that is no procedure, and what is no route")
  (list '(assertion-violation group (admin))
        '(assertion-violation group ("admin"))
        '(assertion-violation group ("/ad min" "ad min"))
        '(assertion-violation group (m))
        '(assertion-violation group (x))
        '(assertion-violation group ("/x")))
  (list (raised (lambda () (group 'admin '() (route "/x" (GET h)))))
        (raised (lambda () (group "admin" '() (route "/x" (GET h)))))
        (raised (lambda () (group "/ad min" '() (route "/x" (GET h)))))
        (raised (lambda () (group "/admin" 'm (route "/x" (GET h)))))
        (raised (lambda () (group "/admin" (list (lambda (next) next) 'x) (route "/x" (GET h)))))
        (raised (lambda () (group "/admin" '() (route "/y" (GET h)) "/x")))))

;; A method entry and a route, made once under a guard, so a refusal can't
;; end the suite.
(define an-entry (guard (e (#t 'no-entry)) (GET h)))
(define a-route (guard (e (#t 'no-route)) (route "/y" (GET h))))

(test-equal "group and make-router refuse a method entry where a route goes"
  (list (list 'assertion-violation 'group (list an-entry))
        (list 'assertion-violation 'make-router (list an-entry)))
  (list (raised (lambda () (group "/admin" '() an-entry)))
        (raised (lambda () (make-router (list an-entry))))))

(test-equal "mount refuses a bad template and a handler that is no procedure"
  '((assertion-violation mount (p)) (assertion-violation mount ("p"))
    (assertion-violation mount ("/p%" "p%"))
    (assertion-violation mount (x)))
  (list (raised (lambda () (mount 'p h)))
        (raised (lambda () (mount "p" h)))
        (raised (lambda () (mount "/p%" h)))
        (raised (lambda () (mount "/p" 'x)))))

(test-equal (string-append "make-router refuses routes that are no list, what is no route in them, "
                           "and a not-found that is no procedure")
  '((assertion-violation make-router (routes))
    (assertion-violation make-router ("/x"))
    (assertion-violation make-router (x)))
  (list (raised (lambda () (make-router 'routes)))
        (raised (lambda () (make-router (list (route "/y" (GET h)) "/x"))))
        (raised (lambda () (make-router (list (route "/y" (GET h))) 'x)))))

(test-equal (string-append "on-not-found, on-bad-request and on-method-not-allowed each refuse a "
                           "handler that is no procedure, naming itself")
  '((assertion-violation on-not-found (x)) (assertion-violation on-bad-request (x))
    (assertion-violation on-method-not-allowed (x)))
  (list (raised (lambda () (on-not-found 'x)))
        (raised (lambda () (on-bad-request 'x)))
        (raised (lambda () (on-method-not-allowed 'x)))))

(test-equal (string-append "make-router refuses two options for one answer: two not-found handlers, "
                           "bare or not, in either order, two 400 handlers, two 405 handlers")
  '((assertion-violation make-router (on-not-found))
    (assertion-violation make-router (on-not-found))
    (assertion-violation make-router (on-not-found))
    (assertion-violation make-router (on-not-found))
    (assertion-violation make-router (on-bad-request))
    (assertion-violation make-router (on-method-not-allowed)))
  (let ((routes (list (route "/x" (GET h)))))
    (list (raised (lambda () (make-router routes h h)))
          (raised (lambda () (make-router routes (on-not-found h) (on-not-found h))))
          (raised (lambda () (make-router routes h (on-bad-request h) (on-not-found h))))
          (raised (lambda () (make-router routes (on-not-found h) (on-method-not-allowed h) h)))
          (raised (lambda () (make-router routes (on-bad-request h) h (on-bad-request h))))
          (raised (lambda () (make-router routes (on-method-not-allowed h)
                                          (on-method-not-allowed h)))))))

(test-equal (string-append "make-router refuses an option that is neither an option nor a procedure: "
                           "a symbol, a route, a method entry, after a good option too")
  (list '(assertion-violation make-router (x))
        (list 'assertion-violation 'make-router (list a-route))
        (list 'assertion-violation 'make-router (list an-entry)))
  (let ((routes (list (route "/x" (GET h)))))
    (list (raised (lambda () (make-router routes (on-bad-request h) 'x)))
          (raised (lambda () (make-router routes a-route)))
          (raised (lambda () (make-router routes an-entry (on-not-found h)))))))

(test-equal "make-router refuses two options for one answer before it applies any middleware"
  '((assertion-violation make-router (on-bad-request)) ())
  (begin
    (take-log!)
    (let ((r (raised (lambda () (make-router (list (group "/g" (list (tagging 'm)) (route "/x" (GET h))))
                                             (on-bad-request h) (on-bad-request h))))))
      (list r (take-log!)))))

(test-equal (string-append "make-router refuses a joined template that doesn't begin with /: "
                           "(route \"\" ...) outside a prefix")
  '((assertion-violation make-router ("")) (assertion-violation make-router ("")))
  (list (raised (lambda () (make-router (list (route "" (GET h))))))
        (raised (lambda () (make-router (list (group "" '() (route "" (GET h)))))))))

(test-equal "make-router refuses an empty segment but last, in a template or joined through a group"
  '((assertion-violation make-router ("/a//b")) (assertion-violation make-router ("/a//b"))
    (assertion-violation make-router ("//")) constructed)
  (list (raised (lambda () (make-router (list (route "/a//b" (GET h))))))
        (raised (lambda () (make-router (list (group "/a/" '() (route "/b" (GET h)))))))
        (raised (lambda () (make-router (list (route "//" (GET h))))))
        (constructed (lambda () (make-router (list (group "/a" '() (route "/" (GET h)))))))))

(test-equal "make-router refuses a catch-all but last, in a template or joined through a group"
  '((assertion-violation make-router ("/a/*r/b")) (assertion-violation make-router ("/a/*r/b"))
    (assertion-violation make-router ("/a/*r/")))
  (list (raised (lambda () (make-router (list (route "/a/*r/b" (GET h))))))
        (raised (lambda () (make-router (list (group "/a/*r" '() (route "/b" (GET h)))))))
        (raised (lambda () (make-router (list (route "/a/*r/" (GET h))))))))

(test-equal "make-router refuses a name twice in one joined template, side by side or apart"
  '((assertion-violation make-router ("/:a/:b/:a" "a"))
    (assertion-violation make-router ("/:a/x/:b/:a" "a"))
    (assertion-violation make-router ("/:a/:b/:c/:b" "b"))
    (assertion-violation make-router ("/:id/:id" "id"))
    (assertion-violation make-router ("/:p/*p" "p"))
    (assertion-violation make-router ("/:id/x/:id" "id"))
    (assertion-violation make-router ("/:v/:v" "v")))
  (list (raised (lambda () (make-router (list (route "/:a/:b/:a" (GET h))))))
        (raised (lambda () (make-router (list (group "/:a/x" '() (route "/:b/:a" (GET h)))))))
        (raised (lambda () (make-router (list (group "/:a/:b" '() (route "/:c/:b" (GET h)))))))
        (raised (lambda () (make-router (list (route "/:id/:id" (GET h))))))
        (raised (lambda () (make-router (list (route "/:p/*p" (GET h))))))
        (raised (lambda () (make-router (list (group "/:id" '() (route "/x/:id" (GET h)))))))
        (raised (lambda () (make-router (list (group "/:v" '() (mount "/:v" h))))))))

(test-equal
  "make-router refuses a mount whose joined template has a catch-all, ends in /, or is / alone"
  '((assertion-violation make-router ("/a/*r"))
    (assertion-violation make-router ("/a/"))
    (assertion-violation make-router ("/"))
    (assertion-violation make-router ("/a/"))
    (assertion-violation make-router ("/a/*r"))
    constructed)
  (list (raised (lambda () (make-router (list (mount "/a/*r" h)))))
        (raised (lambda () (make-router (list (mount "/a/" h)))))
        (raised (lambda () (make-router (list (mount "/" h)))))
        (raised (lambda () (make-router (list (group "/a/" '() (mount "" h))))))
        (raised (lambda () (make-router (list (group "/a" '() (mount "/*r" h))))))
        (constructed (lambda () (make-router (list (group "/a" '() (mount "" h))))))))

(test-equal (string-append "make-router refuses two templates of one shape, naming both in the "
                           "table's order: parameters and catch-alls whatever their names")
  '((assertion-violation make-router ("/u/:id" "/u/:name"))
    (assertion-violation make-router ("/u/:name" "/u/:id"))
    (assertion-violation make-router ("/x" "/x"))
    (assertion-violation make-router ("/f/*a" "/f/*b"))
    (assertion-violation make-router ("/m" "/m"))
    (assertion-violation make-router ("/u/:id" "/u/:name"))
    (assertion-violation make-router ("/a/" "/a/")))
  (list (raised (lambda () (make-router (list (route "/u/:id" (GET h))
                                              (route "/u/:name" (POST h))))))
        (raised (lambda () (make-router (list (route "/u/:name" (POST h))
                                              (route "/u/:id" (GET h))))))
        (raised (lambda () (make-router (list (route "/x" (GET h)) (route "/x" (POST h))))))
        (raised (lambda () (make-router (list (route "/f/*a" (GET h)) (route "/f/*b" (GET h))))))
        (raised (lambda () (make-router (list (mount "/m" h) (mount "/m" h)))))
        (raised (lambda () (make-router (list (group "/u" '() (route "/:id" (GET h)))
                                              (route "/u/:name" (GET h))))))
        (raised (lambda () (make-router (list (group "/a" '() (route "/" (GET h)))
                                              (route "/a/" (GET h))))))))

(test-equal
  "make-router refuses a mount beside a catch-all of its path: they take the same paths at one rank"
  '((assertion-violation make-router ("/p" "/p/*r"))
    (assertion-violation make-router ("/p/*r" "/p")))
  (list (raised (lambda () (make-router (list (mount "/p" h) (route "/p/*r" (GET h))))))
        (raised (lambda () (make-router (list (route "/p/*r" (GET h)) (mount "/p" h)))))))

(test-equal "make-router builds templates that overlap at different ranks"
  '(constructed constructed)
  (list (constructed (lambda () (make-router (list (route "/p" (GET h)) (route "/p/" (GET h))
                                                   (route "/p/:x" (GET h))
                                                   (route "/p/:x/*r" (GET h))
                                                   (mount "/p" h) (mount "/p/q" h)))))
        (constructed (lambda () (make-router (list (route "/:a" (GET h)) (route "/a" (GET h))
                                                   (route "/*a" (GET h))))))))

(test-equal
  "make-router refuses two routes of one name, naming it and both templates, through groups too"
  '((assertion-violation make-router (home "/a" "/b"))
    (assertion-violation make-router (stats "/admin/stats" "/stats")))
  (list (raised (lambda () (make-router (list (route "/a" 'home (GET h))
                                              (route "/b" 'home (GET h))))))
        (raised (lambda () (make-router (list (group "/admin" '() (route "/stats" 'stats (GET h)))
                                              (route "/stats" 'stats (GET h))))))))

(test-equal "a table make-router refuses applies no middleware"
  '((assertion-violation make-router ("/g/x" "/g/x")) ())
  (begin
    (take-log!)
    (let ((r (raised (lambda () (make-router (list (group "/g" (list (tagging 'm))
                                                          (route "/x" (GET h)))
                                                   (route "/g/x" (GET h))))))))
      (list r (take-log!)))))

(test-end "router")

(exit (suite-exit-status runner))
