#!r6rs
;;; (circuit session): sessions read from a signed cookie and written back.
;;;
;;; Oracles: RFC 4231's HMAC-SHA-256 cases 1 to 7, for the pinned (hashing
;;; sha-2), each confirmed by openssl; and two whole set-cookie fields
;;; whose macs openssl made, apart from circuit and hashing, by:
;;;
;;;   key=$(printf '%s' 'circuit session' \
;;;         | openssl dgst -sha256 -hmac "$secret" -hex | sed 's/.*= //')
;;;   printf '%s' "$signed" \
;;;     | openssl dgst -sha256 -mac HMAC -macopt hexkey:$key -hex
;;;
;;; The rows:
;;;   - the dependency: RFC 4231's seven cases;
;;;   - known answers: the default cookie, and another name with every
;;;     attribute, whole fields;
;;;   - round trips: a session read back, dots and digits in it, one empty
;;;     pair; no cookie, another name, no wrap-session;
;;;   - tampering, each row's control the untampered cookie, read back in
;;;     the same assertion: each character changed at every position; cut
;;;     and lengthened; a mac of 63 and 65 digits, in upper case; a time
;;;     with + or a letter, empty, or missing, and a Latin-1 byte, a space,
;;;     a quote and a backslash, each signed by hand, so the mac holds and
;;;     the step under test alone refuses it; another name; another secret;
;;;     the clock never called for a mac that fails;
;;;   - several cookies of the name; the time 60 and 61 seconds ahead, one
;;;     second before its expiry and at it; rotation with three secrets;
;;;   - writing: '() expires the cookie; no session, vary alone;
;;;     cache-control and vary not added over the response's own; nested,
;;;     the innermost; what passes untouched; the handler's own set-cookie;
;;;     a payload of 4006 bytes and 4007; an upgrade; other keys kept;
;;;   - res-with-session's refusals, and a response no wrap-session sees;
;;;   - the settings: each limit from both sides, each refusal with its
;;;     words, the trial cookie's among them, and their order.
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (circuit-testing)
        (circuit)
        (circuit test)
        (circuit session)
        (only (circuit cookies) cookie-secure)
        (only (hashing sha-2) hmac-sha-256 sha-256->bytevector sha-256->string))

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

(test-begin "session")

;; raised : (-> Any) -> Any
;; What THUNK raised: (refused WHO MESSAGE IRRITANTS) for an assertion
;; violation, (other-raise X) for anything else, and (returned V) if it
;; returned V.
(define (raised thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (message-condition? e)
                  (irritants-condition? e))
             (list 'refused (condition-who e) (condition-message e) (condition-irritants e)))
            ((condition? e) (list 'other-raise (describe e)))
            (#t (list 'other-raise e)))
    (list 'returned (thunk))))

(define (refused who message . irritants) (list 'refused who message irritants))

(define (iota n) (let loop ((i (- n 1)) (out '())) (if (< i 0) out (loop (- i 1) (cons i out)))))

;; map-in-order : (a -> b) (Listof a) -> (Listof b)
;; map, calling F on each element in turn: map's order is unspecified.
(define (map-in-order f xs)
  (let loop ((xs xs) (out '()))
    (if (null? xs) (reverse out) (loop (cdr xs) (cons (f (car xs)) out)))))

;; --- the setting --------------------------------------------------------------

;; Secrets of 44 characters, as openssl rand -base64 32 makes them.
(define secret-a "kV9n2Qe0w4tX7bYc1LpR8sZ3uJ6mH5aDfG0hN2oT4iU=")
(define secret-b "Zx8cV7bN6mL5kJ4hG3fD2sA1qW0eR9tY8uI7oP6aS5d=")
(define secret-c "Mn0bV9cX8zL7kJ6hG5fD4sA3qW2eR1tY0uI9oP8lK7j=")

(define t0 1793536476)
(define (clock-at t) (lambda () t))

;; safely : (-> a) a -> a
;; THUNK's answer, or FALLBACK if it raised. SRFI-64 catches no raise in a
;; suite's top-level definitions, so each that can raise is made through
;; it, with a fallback its rows fail on.
(define (safely thunk fallback) (guard (e (#t fallback)) (thunk)))

;; no-session : Middleware — what a middleware that could not be made
;; stands in as: it reads and writes nothing.
(define (no-session handler) handler)

;; mw : Middleware — wrap-session as the app's example has it, at t0.
(define mw (safely (lambda () (wrap-session (list secret-a) (clock-at t0) 1209600)) no-session))

;; handing : Session -> Handler — a handler that hands back SESSION.
(define (handing session)
  (lambda (req) (res-with-session (make-res 200 '() "ok") session)))

;; set-cookies : Res -> (Listof String) — R's set-cookie fields, in order.
(define (set-cookies r)
  (map cdr (filter (lambda (f) (string-ci=? (car f) "set-cookie")) (res-headers r))))

;; written : Middleware Session -> String
;; The first set-cookie field MIDDLEWARE writes for SESSION handed back,
;; or a string no field is when it writes none.
(define (written middleware session)
  (let ((fields (set-cookies ((middleware (handing session)) (make-test-req 'GET "/")))))
    (if (pair? fields) (car fields) "<no set-cookie field>")))

;; pair-of : String -> String
;; A set-cookie FIELD's name=value, before its first ;, as a browser sends
;; it back.
(define (pair-of field)
  (let loop ((i 0))
    (if (or (= i (string-length field)) (char=? (string-ref field i) #\;))
        (substring field 0 i)
        (loop (+ i 1)))))

;; value-of : String -> String — a set-cookie FIELD's value.
(define (value-of field)
  (let ((pair (pair-of field)))
    (let loop ((i 0))
      (if (char=? (string-ref pair i) #\=)
          (substring pair (+ i 1) (string-length pair))
          (loop (+ i 1))))))

;; read-back : Middleware String -> Any
;; The session MIDDLEWARE reads from a request whose cookie field is
;; FIELD, or what it raised: the handler answers (req-session req), which
;; is no response, so it comes back untouched.
(define (read-back middleware field)
  (raised (lambda () ((middleware req-session) (make-test-req 'GET "/" (list (cons "cookie" field)))))))

;; reads : Session -> Any — what read-back answers for SESSION.
(define (reads session) (list 'returned session))

(define visits '(("visits" . "1")))

;; the-cookie : String — mw's cookie for visits, as a browser sends it.
(define the-cookie (safely (lambda () (pair-of (written mw visits))) "__Host-session=<none written>"))
(define the-value (safely (lambda () (value-of (written mw visits))) "<none written>"))

;; visits-field : String — mw's whole field for visits, for the rows'
;; expected values.
(define visits-field (safely (lambda () (written mw visits)) "<none written>"))

;; key-of : String -> Bytevector — SECRET's signing key, by hand.
(define (key-of secret)
  (sha-256->bytevector (hmac-sha-256 (string->utf8 secret) (string->utf8 "circuit session"))))

;; hand-signed : String String String -> String
;; TEXT, a dot and the mac of NAME=TEXT under SECRET's key: a value whose
;; mac holds, whatever TEXT is.
(define (hand-signed name text secret)
  (string-append text "."
                 (sha-256->string (hmac-sha-256 (key-of secret) (string->utf8 (string-append name "=" text))))))

;; with-control : Middleware String String -> Any
;; The untampered cookie read back, then the tampered one, FIELD: a reader
;; that refuses everything fails the first.
(define (with-control middleware field)
  (list (read-back middleware the-cookie) (read-back middleware field)))

(define control-and-none (list (reads visits) (reads '())))

;; counting : Nat -> (Pair (-> Nat) (-> Nat))
;; A clock at T, and how many times it was called.
(define (counting t)
  (let ((calls (vector 0)))
    (cons (lambda () (vector-set! calls 0 (+ (vector-ref calls 0) 1)) t)
          (lambda () (vector-ref calls 0)))))

;; --- the dependency ------------------------------------------------------------

(define (hex-of bv)
  (string-downcase
   (apply string-append
          (map (lambda (b) (string-append (if (< b 16) "0" "") (number->string b 16)))
               (bytevector->u8-list bv)))))

(define (rfc4231 key data) (hex-of (sha-256->bytevector (hmac-sha-256 key data))))

(test-equal "RFC 4231's cases 1 to 7 through the pinned (hashing sha-2), case 5 truncated to 128 bits"
  '("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
    "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
    "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"
    "a3b6167473100ee06e0c796c2955552b"
    "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
    "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")
  (let ((aa131 (make-bytevector 131 #xaa)))
    (list (rfc4231 (make-bytevector 20 #x0b) (string->utf8 "Hi There"))
          (rfc4231 (string->utf8 "Jefe") (string->utf8 "what do ya want for nothing?"))
          (rfc4231 (make-bytevector 20 #xaa) (make-bytevector 50 #xdd))
          (rfc4231 (u8-list->bytevector (map (lambda (i) (+ i 1)) (iota 25))) (make-bytevector 50 #xcd))
          (substring (rfc4231 (make-bytevector 20 #x0c) (string->utf8 "Test With Truncation")) 0 32)
          (rfc4231 aa131 (string->utf8 "Test Using Larger Than Block-Size Key - Hash Key First"))
          (rfc4231 aa131 (string->utf8 (string-append "This is a test using a larger than block-size key"
                                                      " and a larger than block-size data. The key needs"
                                                      " to be hashed before being used by the HMAC algorithm."))))))

;; --- known answers -------------------------------------------------------------

(test-equal "a known answer: the default cookie, its mac made by openssl, with cache-control and vary"
  '(("set-cookie" . "__Host-session=visits=1.1793536476.2ebcb9fd170d59720998cf744fedd6e752668b109a1eec27623832cf2d58fa39; Path=/; Max-Age=1209600; Secure; HttpOnly; SameSite=Lax")
    ("cache-control" . "private")
    ("vary" . "cookie"))
  (res-headers ((mw (handing visits)) (make-test-req 'GET "/"))))

(test-equal "a known answer: another name and every attribute, the name signed with the pairs and the time"
  '(("x-own" . "kept")
    ("set-cookie" . "sid=user=ada+lovelace&%C3%A9=a%26b%3Dc.1793536476.b8b9a8abe53b18ba8be88f330d8b55620469e2c430cd9138905d8b82c56cac43; Path=/app; Domain=example.com; Max-Age=3600; HttpOnly; SameSite=Strict")
    ("cache-control" . "private")
    ("vary" . "cookie"))
  (res-headers
   (((wrap-session (list secret-a) (clock-at t0) 3600
                   (session-insecure) (session-same-site 'strict) (session-domain "example.com")
                   (session-path "/app") (session-name "sid"))
     (lambda (req)
       (res-with-session (make-res 200 '(("x-own" . "kept")) "ok")
                         '(("user" . "ada lovelace") ("\xE9;" . "a&b=c")))))
    (make-test-req 'GET "/"))))

;; --- round trips ---------------------------------------------------------------

(test-equal "a session handed back reads back whole on the next request"
  (reads '(("user" . "ada") ("role" . "admin") ("user" . "again")))
  (read-back mw (pair-of (written mw '(("user" . "ada") ("role" . "admin") ("user" . "again"))))))

(test-equal "names and values with dots and digits read back: the value is split from its right"
  (reads '(("a.1" . "2.3") ("." . "..") ("1793536476" . ".0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")))
  (read-back mw (pair-of (written mw '(("a.1" . "2.3") ("." . "..")
                                       ("1793536476" . ".0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))))))

(test-equal "a session of one empty pair reads back"
  (reads '(("" . "")))
  (read-back mw (pair-of (written mw '(("" . ""))))))

(test-equal "no cookie, a cookie of another name, and the name in another case read '()"
  (list (reads '()) (reads '()) (reads '()))
  (list (raised (lambda () ((mw req-session) (make-test-req 'GET "/"))))
        (read-back mw (string-append "other=" the-value))
        (read-back mw (string-append "__host-session=" the-value))))

(test-equal "req-session on a request no wrap-session saw is '(), and what is no request is refused"
  (list '() (refused 'req-session "not a request" 'nope))
  (list (req-session (make-test-req 'GET "/" (list (cons "cookie" the-cookie))))
        (raised (lambda () (req-session 'nope)))))

;; --- tampering -----------------------------------------------------------------

;; changed : Char -> Char
;; Another character of C's kind: a digit for a digit, a hex letter for a
;; hex letter, a letter for any other, and - for a dot.
(define (changed c)
  (cond ((char=? c #\9) #\0)
        ((char<=? #\0 c #\8) (integer->char (+ (char->integer c) 1)))
        ((char=? c #\f) #\a)
        ((char<=? #\a c #\e) (integer->char (+ (char->integer c) 1)))
        ((char=? c #\.) #\-)
        (else #\a)))

(test-equal "each character of the value changed, at every position, reads '(), and the cookie itself reads back"
  (list (reads visits) '())
  (let ((n (string-length the-value)))
    (list (read-back mw the-cookie)
          (filter (lambda (i)
                    (let ((tampered (string-copy the-value)))
                      (string-set! tampered i (changed (string-ref the-value i)))
                      (not (equal? (read-back mw (string-append "__Host-session=" tampered)) (reads '())))))
                  (iota n)))))

(test-equal "the value cut short or lengthened, at either end, reads '()"
  (list (reads visits) (list (reads '()) (reads '()) (reads '()) (reads '())))
  (let ((n (string-length the-value))
        (as-cookie (lambda (v) (string-append "__Host-session=" v))))
    (list (read-back mw the-cookie)
          (map-in-order (lambda (v) (read-back mw (as-cookie v)))
                        (list (substring the-value 1 n) (substring the-value 0 (- n 1))
                              (string-append "v" the-value) (string-append the-value "0"))))))

(test-equal "a mac of 63 and of 65 hex digits reads '(): the 64-digit check holds the length"
  (list (reads visits) (list (reads '()) (reads '())))
  (let ((n (string-length the-value)))
    (list (read-back mw the-cookie)
          (list (read-back mw (string-append "__Host-session=" (substring the-value 0 (- n 1))))
                (read-back mw (string-append "__Host-session=" the-value "0"))))))

(define (upcased s)
  (list->string (map (lambda (c) (if (char<=? #\a c #\f) (integer->char (- (char->integer c) 32)) c))
                     (string->list s))))

(test-equal "the mac in upper case reads '()"
  control-and-none
  (let* ((n (string-length the-value)) (mac-at (- n 64)))
    (with-control mw (string-append "__Host-session=" (substring the-value 0 mac-at)
                                    (upcased (substring the-value mac-at n))))))

;; signed-cookie : String -> String
;; A __Host-session cookie of TEXT, its mac good under secret-a.
(define (signed-cookie text) (string-append "__Host-session=" (hand-signed "__Host-session" text secret-a)))

;; at-100 : Middleware — the clock at 100, where a time read as 0 is live,
;; so a reader that took a time it can't parse for 0 reads its session.
(define at-100 (safely (lambda () (wrap-session (list secret-a) (clock-at 100) 1209600)) no-session))

(test-equal "signed by hand, so the mac holds, with the clock at 100: the control reads back, and a time with + or a letter, an empty time, and no time read '()"
  (list (reads visits) (list (reads '()) (reads '()) (reads '()) (reads '())))
  (list (read-back at-100 (signed-cookie "visits=1.100"))
        (map-in-order (lambda (text) (read-back at-100 (signed-cookie text)))
                      '("visits=1.+100" "visits=1.1x0" "visits=1." "visits=1"))))

(test-equal "signed by hand: a Latin-1 byte, a space, a quote and a backslash in the value read '(), and the clock is never called for them"
  (list (reads '(("caf" . "1"))) 2 (list (reads '()) (reads '()) (reads '()) (reads '())) 2)
  (let* ((clock (counting t0))
         (counted (wrap-session (list secret-a) (car clock) 1209600))
         (control (read-back counted (signed-cookie "caf=1.1793536476")))
         (after-control ((cdr clock)))
         (refused (map-in-order (lambda (text) (read-back counted (signed-cookie text)))
                                '("caf\xE9;=1.1793536476" "caf =1.1793536476" "caf\"=1.1793536476"
                                  "caf\\=1.1793536476"))))
    (list control after-control refused ((cdr clock)))))

(test-equal "a cookie moved to another name reads '(): the name is signed"
  (list (reads visits) (reads '()))
  (let ((other (wrap-session (list secret-a) (clock-at t0) 1209600 (session-name "__Host-other"))))
    (list (read-back other (pair-of (written other visits)))
          (read-back other (string-append "__Host-other=" the-value)))))

(test-equal "a cookie signed under a secret not in the list reads '()"
  (list (reads visits) (reads '()))
  (let ((under-b (wrap-session (list secret-b) (clock-at t0) 1209600)))
    (list (read-back under-b (pair-of (written under-b visits)))
          (read-back mw (pair-of (written under-b visits))))))

;; wrong-mac : String — the-cookie with its mac's last digit changed.
(define wrong-mac
  (safely (lambda ()
            (let ((n (string-length the-cookie)))
              (string-append (substring the-cookie 0 (- n 1)) (string (changed (string-ref the-cookie (- n 1)))))))
          "__Host-session=<none written>"))

(test-equal "the clock is called once when the middleware is made, never for a cookie whose mac fails, and once for one whose mac holds"
  '(1 1 2 (returned ()) (returned (("visits" . "1"))))
  (let* ((clock (counting t0))
         (counted (wrap-session (list secret-a) (car clock) 1209600))
         (made ((cdr clock)))
         (bad (read-back counted wrong-mac))
         (after-bad ((cdr clock)))
         (good (read-back counted the-cookie))
         (after-good ((cdr clock))))
    (list made after-bad after-good bad good)))

;; --- several cookies, the time, rotation ----------------------------------------

(test-equal "of two cookies of the name, a bad one then a good one, the good one is read"
  (reads visits)
  (read-back mw (string-append "__Host-session=" the-value "0; " the-cookie)))

(test-equal "of two good cookies of the name, the first is read"
  (reads '(("first" . "1")))
  (read-back mw (string-append (pair-of (written mw '(("first" . "1")))) "; other=x; "
                               (pair-of (written mw '(("second" . "2")))))))

(test-equal "a time 60 seconds ahead of the clock reads; 61 seconds ahead doesn't"
  (list (reads visits) (reads '()))
  (list (read-back mw (signed-cookie (string-append "visits=1." (number->string (+ t0 60)))))
        (read-back mw (signed-cookie (string-append "visits=1." (number->string (+ t0 61)))))))

(test-equal "a cookie reads one second before its expiry, and not at it"
  (list (reads visits) (reads '()))
  (list (read-back (wrap-session (list secret-a) (clock-at (+ t0 1209599)) 1209600) the-cookie)
        (read-back (wrap-session (list secret-a) (clock-at (+ t0 1209600)) 1209600) the-cookie)))

(define three (safely (lambda () (wrap-session (list secret-a secret-b secret-c) (clock-at t0) 1209600))
                      no-session))
(define (under secret) (wrap-session (list secret) (clock-at t0) 1209600))

(test-equal "rotation: a cookie under the middle of three secrets, and one under the last, reads"
  (list (reads visits) (reads visits))
  (list (read-back three (pair-of (written (under secret-b) visits)))
        (read-back three (pair-of (written (under secret-c) visits)))))

(test-equal "rotation: a session handed back is signed with the first secret, neither the one that verified nor the last"
  (list #t #f #f)
  (let ((field (car (set-cookies
                     ((three (lambda (req) (res-with-session (make-res 200 '() "ok") (req-session req))))
                      (make-test-req 'GET "/" (list (cons "cookie" (pair-of (written (under secret-b) visits))))))))))
    (list (string=? field (written (under secret-a) visits))
          (string=? field (written (under secret-b) visits))
          (string=? field (written (under secret-c) visits)))))

;; --- writing -------------------------------------------------------------------

(test-equal "'() expires a __Host-session whole, with every attribute but the max age, and cache-control and vary"
  '(("set-cookie" . "__Host-session=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=Lax")
    ("cache-control" . "private")
    ("vary" . "cookie"))
  (res-headers ((mw (handing '())) (make-test-req 'GET "/" (list (cons "cookie" the-cookie))))))

(test-equal "'() expires a cookie of another name and every option with each of them but the max age"
  '(("set-cookie" . "sid=; Path=/app; Domain=example.com; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Strict")
    ("cache-control" . "private")
    ("vary" . "cookie"))
  (res-headers
   (((wrap-session (list secret-a) (clock-at t0) 3600
                   (session-insecure) (session-same-site 'strict) (session-domain "example.com")
                   (session-path "/app") (session-name "sid"))
     (handing '()))
    (make-test-req 'GET "/"))))

(test-equal "no session handed back: no set-cookie, vary: cookie alone, the response's own fields and body kept"
  (list 203 '(("x-own" . "kept") ("set-cookie" . "theme=dark") ("vary" . "cookie")) (string->utf8 "body"))
  (let ((r ((mw (lambda (req) (make-res 203 '(("x-own" . "kept") ("set-cookie" . "theme=dark")) "body")))
            (make-test-req 'GET "/" (list (cons "cookie" the-cookie))))))
    (list (res-status r) (res-headers r) (res-body->bytevector r))))

(test-equal "cache-control: private is not added over a cache-control field the response holds, for a set or an expiry"
  '((("cache-control" . "no-store")
     ("set-cookie" . "__Host-session=visits=1.1793536476.2ebcb9fd170d59720998cf744fedd6e752668b109a1eec27623832cf2d58fa39; Path=/; Max-Age=1209600; Secure; HttpOnly; SameSite=Lax")
     ("vary" . "cookie"))
    (("Cache-Control" . "public")
     ("set-cookie" . "__Host-session=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=Lax")
     ("vary" . "cookie")))
  (map-in-order (lambda (case)
                  (res-headers ((mw (lambda (req) (res-with-session (make-res 200 (list (car case)) "") (cdr case))))
                                (make-test-req 'GET "/"))))
                (list (cons '("cache-control" . "no-store") visits)
                      (cons '("Cache-Control" . "public") '()))))

;; vary-after : Headers -> Headers — what mw does to a response of HEADERS.
(define (vary-after headers)
  (res-headers ((mw (lambda (req) (make-res 200 headers ""))) (make-test-req 'GET "/"))))

(test-equal "vary: cookie is added, once, unless a vary field lists cookie, in any ASCII case, or *: the Kelvin sign is no k"
  '((("vary" . "set-cookie") ("vary" . "cookie"))
    (("vary" . "cookies") ("vary" . "cookie"))
    (("vary" . "coo\x212A;ie") ("vary" . "cookie"))
    (("vary" . "accept, Cookie"))
    (("Vary" . "COOKIE"))
    (("vary" . " accept ,\tcookie "))
    (("vary" . "accept") ("vary" . "cookie"))
    (("vary" . "*"))
    (("vary" . "accept") ("vary" . "origin") ("vary" . "cookie")))
  (map-in-order vary-after
                '((("vary" . "set-cookie"))
                  (("vary" . "cookies"))
                  (("vary" . "coo\x212A;ie"))
                  (("vary" . "accept, Cookie"))
                  (("Vary" . "COOKIE"))
                  (("vary" . " accept ,\tcookie "))
                  (("vary" . "accept") ("vary" . "cookie"))
                  (("vary" . "*"))
                  (("vary" . "accept") ("vary" . "origin")))))

(test-equal "a session written on a response whose vary lists Cookie gets no second vary"
  (list '("vary" . "Cookie") (cons "set-cookie" visits-field) '("cache-control" . "private"))
  (res-headers ((mw (lambda (req) (res-with-session (make-res 200 '(("vary" . "Cookie")) "") visits)))
                (make-test-req 'GET "/"))))

(define inner-mw
  (safely (lambda () (wrap-session (list secret-b) (clock-at t0) 1209600 (session-name "__Host-inner")))
          no-session))

(define seen-field (safely (lambda () (written inner-mw '(("seen" . "yes")))) "<none written>"))

(test-equal "nested wrap-sessions: the innermost reads, and writes once, with one vary"
  (list (reads '(("inner" . "1")))
        (list (cons "set-cookie" seen-field)
              '("cache-control" . "private")
              '("vary" . "cookie")))
  (let ((field (string-append the-cookie "; " (pair-of (written inner-mw '(("inner" . "1")))))))
    (list (read-back (lambda (h) (mw (inner-mw h))) field)
          (res-headers ((mw (inner-mw (handing '(("seen" . "yes")))))
                        (make-test-req 'GET "/" (list (cons "cookie" field))))))))

(test-equal "nested wrap-sessions: with the outer cookie good and no inner one, the inner handler reads '()"
  (list (reads visits) (reads '()))
  (list (read-back mw the-cookie)
        (read-back (lambda (h) (mw (inner-mw h))) the-cookie)))

(test-equal "nested wrap-sessions: the outer one leaves a written response alone, even one a middleware between took vary from"
  (list (cons "set-cookie" seen-field) '("cache-control" . "private"))
  (res-headers ((mw ((lambda (h) (lambda (req) (res-remove-header (h req) "vary")))
                     (inner-mw (handing '(("seen" . "yes"))))))
                (make-test-req 'GET "/"))))

(test-equal "nested wrap-sessions of one name write once"
  (list visits-field)
  (set-cookies ((mw (mw (handing visits))) (make-test-req 'GET "/"))))

(test-equal "an answer that is no response passes untouched, and a raise from the handler passes with nothing written"
  (list (list 'returned 'not-a-response) (list 'other-raise 'from-the-handler))
  (list (raised (lambda () ((mw (lambda (req) 'not-a-response)) (make-test-req 'GET "/"))))
        (raised (lambda () ((mw (lambda (req) (raise 'from-the-handler))) (make-test-req 'GET "/"))))))

(test-equal "an inner middleware that answers a fresh response drops the session: vary alone"
  '(("vary" . "cookie"))
  (res-headers ((mw ((lambda (h) (lambda (req) (h req) (make-res 200 '() ""))) (handing visits)))
                (make-test-req 'GET "/"))))

(test-equal "a handler's own set-cookie of the session's name, with a session handed back, is refused at the write"
  (refused 'res-add-cookie
           "a response sets each cookie name once: it holds a set-cookie field of this name already"
           "__Host-session")
  (raised (lambda ()
            ((mw (lambda (req)
                   (res-with-session (make-res 200 '(("set-cookie" . "__Host-session=mine")) "") visits)))
             (make-test-req 'GET "/")))))

;; session-of : Nat -> Session — one pair whose payload is N bytes.
(define (session-of n) (list (cons "" (make-string (- n 1) #\a))))

(test-equal "a payload of 4006 bytes is written, under __Host-session and a ten-digit time; 4007 is refused at the write"
  (list 4096 (refused 'res-add-cookie
                      "a cookie's name and value are at most 4096 bytes together: a browser ignores a longer one"
                      4097))
  (list (let ((field (written mw (session-of 4006))))
          (+ (string-length "__Host-session") (string-length (value-of field))))
        (raised (lambda () (written mw (session-of 4007))))))

(test-equal "an upgrade with a session handed back stays an upgrade, its take-over kept and its cookie written"
  (list 101 #t #t (list visits-field))
  (let* ((take-over (lambda (transport bytes) 'taken))
         (r ((mw (lambda (req) (res-with-session (make-upgrade-res '(("upgrade" . "x")) take-over) visits)))
             (make-test-req 'GET "/"))))
    (list (res-status r) (res-upgrade-body? (res-body r))
          (eq? (res-upgrade-body-take-over (res-body r)) take-over)
          (set-cookies r))))

(define other-key (make-res-key 'other))

(test-equal "the response's other keys are kept, a write and none alike"
  '("kept" "kept")
  (map-in-order (lambda (handed)
                  (res-ref ((mw (lambda (req)
                                  (let ((r (res-set (make-res 200 '() "") other-key "kept")))
                                    (if handed (res-with-session r handed) r))))
                            (make-test-req 'GET "/"))
                           other-key))
                (list visits #f)))

;; --- res-with-session ----------------------------------------------------------

(test-equal "res-with-session refuses what is no response, and a session that is no list of pairs of strings"
  (list (refused 'res-with-session "not a response" 'nope)
        (refused 'res-with-session "a session is a list of (name . value) pairs of strings" "a=b")
        (refused 'res-with-session "a session is a list of (name . value) pairs of strings" '(("a" . 1)))
        (refused 'res-with-session "a session is a list of (name . value) pairs of strings" '((a . "b")))
        (refused 'res-with-session "a session is a list of (name . value) pairs of strings" '("a"))
        (refused 'res-with-session "a session is a list of (name . value) pairs of strings" '(("a" . "b") . x)))
  (map-in-order (lambda (args) (raised (lambda () (apply res-with-session args))))
                (list (list 'nope visits)
                      (list (make-res 200 '() "") "a=b")
                      (list (make-res 200 '() "") '(("a" . 1)))
                      (list (make-res 200 '() "") '((a . "b")))
                      (list (make-res 200 '() "") '("a"))
                      (list (make-res 200 '() "") '(("a" . "b") . x)))))

(test-equal "res-with-session on a response no wrap-session sees changes nothing it sends"
  (list 200 '(("x-own" . "kept")) (string->utf8 "body"))
  (let ((r (res-with-session (make-res 200 '(("x-own" . "kept")) "body") visits)))
    (list (res-status r) (res-headers r) (res-body->bytevector r))))

;; --- the settings ---------------------------------------------------------------

(define (made . args) (raised (lambda () (apply wrap-session args) 'made)))

(define secrets-message "secrets are a list of strings, at least one: the first signs, and each verifies")
(define short-message "a secret is at least 32 bytes as UTF-8: openssl rand -base64 32 makes one")

(test-equal "the secrets: one of 31 bytes is refused, naming its size alone; 32 bytes, and sixteen é, 32 bytes, are taken"
  (list (refused 'wrap-session short-message 31)
        (refused 'wrap-session short-message 31)
        '(returned made) '(returned made))
  (list (made (list (make-string 31 #\s)) (clock-at t0) 60)
        (made (list secret-a (make-string 31 #\s) secret-b) (clock-at t0) 60)
        (made (list (make-string 32 #\s)) (clock-at t0) 60)
        (made (list (make-string 16 #\xE9)) (clock-at t0) 60)))

(test-equal "the secrets: a string, an empty list, and a list holding a non-string are refused, naming no secret"
  (list (refused 'wrap-session secrets-message)
        (refused 'wrap-session secrets-message)
        (refused 'wrap-session secrets-message))
  (list (made secret-a (clock-at t0) 60)
        (made '() (clock-at t0) 60)
        (made (list secret-a 'b) (clock-at t0) 60)))

(define clock-message "a clock is a procedure of no arguments that answers the seconds since the Unix epoch")
(define answer-message "a clock answers the seconds since the Unix epoch, an exact integer, 0 or more")

(test-equal "the clock: what is no procedure is refused; its first answer -1, 1.5, 1.0 and a string are refused, and 0 and a bignum taken"
  (list (refused 'wrap-session clock-message t0)
        (refused 'wrap-session answer-message -1)
        (refused 'wrap-session answer-message 1.5)
        (refused 'wrap-session answer-message 1.0)
        (refused 'wrap-session answer-message "1793536476")
        '(returned made) '(returned made))
  (list (made (list secret-a) t0 60)
        (made (list secret-a) (clock-at -1) 60)
        (made (list secret-a) (clock-at 1.5) 60)
        (made (list secret-a) (clock-at 1.0) 60)
        (made (list secret-a) (clock-at "1793536476") 60)
        (made (list secret-a) (clock-at 0) 60)
        (made (list secret-a) (clock-at (expt 2 100)) 60)))

;; drifting : (Listof Any) -> (-> Any) — a clock answering each of TIMES in turn, then the last.
(define (drifting times)
  (let ((left (vector times)))
    (lambda ()
      (let ((ts (vector-ref left 0)))
        (unless (null? (cdr ts)) (vector-set! left 0 (cdr ts)))
        (car ts)))))

(test-equal "the clock at a request: an answer that is no such integer is refused when a cookie's mac holds, and when a session is written"
  (list (refused 'wrap-session answer-message -1)
        (refused 'wrap-session answer-message 'later))
  (list (read-back (wrap-session (list secret-a) (drifting (list t0 -1)) 1209600) the-cookie)
        (raised (lambda () (written (wrap-session (list secret-a) (drifting (list t0 'later)) 1209600) visits)))))

(define age-message
  "a max age is a whole number of seconds from 1 to 34560000, the 400 days a browser keeps a cookie at most")

(test-equal "the max age: 1 and 34560000 are taken; 0, 34560001, a bignum, 1.0 and a string are refused"
  (list '(returned made) '(returned made)
        (refused 'wrap-session age-message 0)
        (refused 'wrap-session age-message 34560001)
        (refused 'wrap-session age-message (expt 2 100))
        (refused 'wrap-session age-message 1.0)
        (refused 'wrap-session age-message 'string))
  (map-in-order (lambda (age) (made (list secret-a) (clock-at t0) age))
                (list 1 34560000 0 34560001 (expt 2 100) 1.0 "60")))

(test-equal "a secret given where the clock, the max age or an option goes is named by its kind alone"
  (list (refused 'wrap-session clock-message 'string)
        (refused 'wrap-session age-message 'string)
        (refused 'wrap-session "an option is what a session- constructor makes" 'string))
  (list (made (list secret-a) secret-b 60)
        (made (list secret-a) (clock-at t0) secret-b)
        (made (list secret-a) (clock-at t0) 60 secret-b)))

(test-equal "a max age of 34560000 is the cookie's Max-Age"
  "__Host-session=visits=1.1793536476.2ebcb9fd170d59720998cf744fedd6e752668b109a1eec27623832cf2d58fa39; Path=/; Max-Age=34560000; Secure; HttpOnly; SameSite=Lax"
  (written (wrap-session (list secret-a) (clock-at t0) 34560000) visits))

(test-equal "the options: what no session- constructor made, a constructor given bare, and an option given twice are refused"
  (list (refused 'wrap-session "an option is what a session- constructor makes" 'secure)
        (refused 'wrap-session "an option's constructor, given bare: call it" 'session-insecure)
        (refused 'wrap-session "each option once" 'session-path)
        (refused 'wrap-session "each option once" 'session-name))
  (list (made (list secret-a) (clock-at t0) 60 (session-insecure) 'secure)
        (made (list secret-a) (clock-at t0) 60 session-insecure)
        (made (list secret-a) (clock-at t0) 60 (session-path "/") (session-path "/"))
        (made (list secret-a) (clock-at t0) 60 (session-name "a") (session-insecure) (session-name "b"))))

(test-equal "the options: a cookie option is no session option"
  #t
  (let ((got (made (list secret-a) (clock-at t0) 60 (cookie-secure))))
    (and (eq? (car got) 'refused) (equal? (caddr got) "an option is what a session- constructor makes"))))

(define host-message
  "a __Host- name needs cookie-secure and (cookie-path \"/\"), and no cookie-domain: a browser ignores the cookie otherwise")

(test-equal "the trial cookie: __Host-session with session-insecure, a path but /, or a domain is refused with the cookies' words"
  (list (refused 'wrap-session host-message "__Host-session")
        (refused 'wrap-session host-message "__Host-session")
        (refused 'wrap-session host-message "__Host-session")
        (refused 'wrap-session host-message "__host-x"))
  (list (made (list secret-a) (clock-at t0) 60 (session-insecure))
        (made (list secret-a) (clock-at t0) 60 (session-path "/app"))
        (made (list secret-a) (clock-at t0) 60 (session-domain "example.com"))
        (made (list secret-a) (clock-at t0) 60 (session-name "__host-x") (session-insecure))))

(test-equal "the trial cookie: a name that is no token, a __Secure- name without Secure, SameSite=None without Secure, and a name too long to hold a session are refused"
  (list (refused 'wrap-session "a cookie name is a token: letters, digits and !#$%&'*+-.^_`|~, at least one" "a b")
        (refused 'wrap-session "a cookie name is a token: letters, digits and !#$%&'*+-.^_`|~, at least one" "")
        (refused 'wrap-session "a __Secure- name needs cookie-secure: a browser ignores the cookie without it" "__Secure-s")
        (refused 'wrap-session "SameSite=None needs cookie-secure: a browser ignores the cookie without it" "sid")
        (refused 'wrap-session "a cookie's name and value are at most 4096 bytes together: a browser ignores a longer one" 4097)
        '(returned made))
  (list (made (list secret-a) (clock-at t0) 60 (session-name "a b"))
        (made (list secret-a) (clock-at t0) 60 (session-name ""))
        (made (list secret-a) (clock-at t0) 60 (session-name "__Secure-s") (session-insecure))
        (made (list secret-a) (clock-at t0) 60 (session-name "sid") (session-same-site 'none) (session-insecure))
        (made (list secret-a) (clock-at t0) 60 (session-name (make-string 4020 #\n)))
        (made (list secret-a) (clock-at t0) 60 (session-name (make-string 4019 #\n)))))

(test-equal "the session options check their settings, naming themselves, with the cookies' words"
  (list (refused 'session-name "a cookie name is a string" 'sid)
        (refused 'session-path "a path starts with /: a browser ignores any other" "app")
        (refused 'session-domain "a domain is not empty, nor . alone: a browser reads either as no Domain" "")
        (refused 'session-same-site "a same-site is strict, lax or none" 'loose))
  (list (raised (lambda () (session-name 'sid)))
        (raised (lambda () (session-path "app")))
        (raised (lambda () (session-domain "")))
        (raised (lambda () (session-same-site 'loose)))))

(test-equal "session-name copies its string: a change to it after changes nothing"
  "sid="
  (let* ((name (string-copy "sid"))
         (option (session-name name)))
    (string-set! name 0 #\x)
    (let ((field (written (wrap-session (list secret-a) (clock-at t0) 60 option (session-insecure)) visits)))
      (substring field 0 (min 4 (string-length field))))))

(test-equal "a handler that is no procedure is refused when the middleware is applied"
  (refused 'wrap-session "a handler is a procedure" 'nope)
  (raised (lambda () (mw 'nope))))

(test-equal "the settings are checked in order: the secrets, the clock, the max age, the options, the clock's answer, the trial"
  (list (refused 'wrap-session secrets-message)
        (refused 'wrap-session clock-message 'clock)
        (refused 'wrap-session age-message 0)
        (refused 'wrap-session "an option's constructor, given bare: call it" 'session-insecure)
        (refused 'wrap-session answer-message -1))
  (list (made '() 'clock 0 session-insecure)
        (made (list secret-a) 'clock 0 session-insecure)
        (made (list secret-a) (clock-at -1) 0 session-insecure)
        (made (list secret-a) (clock-at -1) 60 session-insecure)
        (made (list secret-a) (clock-at -1) 60 (session-insecure))))

(test-end "session")

(exit (suite-exit-status runner))
