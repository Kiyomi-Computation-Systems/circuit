#!r6rs
;;; (circuit middleware cors): wrap-cors's options and their refusals, the
;;; origins it takes, the preflight it answers itself, the fields it puts on
;;; the handler's response, and Vary (the slice 9 design §3).
;;;
;;; Oracles: Fetch, for what a preflight is (§3.3.2), the fields' names, and
;;; why a response from an origin list varies on Origin while one under *
;;; doesn't (its "CORS protocol and HTTP caches"), and that a credentialed
;;; request reads * in a list as a name (§3.3.4); HTML's serialization of an
;;; origin, and URL's host serializers and default ports, for the origins a
;;; browser sends; Fetch's bad ports, for port 0; RFC 9110, for a token
;;; (§5.6.2) and a list (§5.6.1, §12.5.5). Each row about a request asserts
;;; the whole answer: the status, every field in order, the body, and how
;;; many times the handler ran, so a row also shows a preflight never
;;; reaches it.
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (circuit-testing)
        (circuit response)
        (only (circuit test) make-test-req)
        (circuit middleware cors))

(define runner (test-runner-simple))
(test-runner-current runner)

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

;; raised-message : (-> Any) -> (U String Symbol)
;; The message of the assertion violation THUNK raised, or no-raise.
(define (raised-message thunk)
  (guard (e ((and (assertion-violation? e) (message-condition? e)) (condition-message e))
            (#t 'other-raise))
    (thunk)
    'no-raise))

;; --- the handler ---------------------------------------------------------------

;; How many times the handler ran since answer last reset it.
(define calls 0)

;; The handler's own fields: none a default, and none wrap-cors writes.
(define base '(("content-type" . "text/plain") ("x-from" . "handler")))

;; handler-with : Headers -> Handler
(define (handler-with headers)
  (lambda (req)
    (set! calls (+ calls 1))
    (make-res 200 headers "from the handler")))

(define handler (handler-with base))

;; answer : Middleware Req [Handler] -> (List Integer Headers Any Nat)
;; The status, fields and body of what MIDDLEWARE, around HANDLER unless
;; another is given, answers REQ, and how many times that handler ran.
(define (answer middleware req . given)
  (set! calls 0)
  (let* ((app (middleware (if (pair? given) (car given) handler)))
         (res (app req)))
    (list (res-status res) (res-headers res) (res-body res) calls)))

;; handled : Headers -> (List Integer Headers String Nat)
;; The handler's answer, run once, with FIELDS after its own.
(define (handled . fields)
  (list 200 (append base fields) "from the handler" 1))

;; preflight : Headers -> (List Integer Headers #f Nat)
;; wrap-cors's own 204 with FIELDS, the handler never run.
(define (preflight . fields)
  (list 204 fields #f 0))

;; req : Symbol (Pair String String) ... -> Req
(define (req method . fields) (make-test-req method "/things" fields))

(define app-origin "https://app.example")
(define (from origin) (cons "origin" origin))
(define (asking method) (cons "access-control-request-method" method))
(define (asking-headers names) (cons "access-control-request-headers" names))

(define (acao v) (cons "access-control-allow-origin" v))
(define acac (cons "access-control-allow-credentials" "true"))
(define (acam v) (cons "access-control-allow-methods" v))
(define (acah v) (cons "access-control-allow-headers" v))
(define (aceh v) (cons "access-control-expose-headers" v))
(define (acma v) (cons "access-control-max-age" v))
(define vary-origin (cons "vary" "origin"))

(define listed (wrap-cors (cors-origins app-origin)))
(define anyone (wrap-cors (cors-any-origin)))

;; --- chars --------------------------------------------------------------------

;; every-char : (Listof Char)
;; Every character from 0 to 255, and one past it.
(define every-char
  (let loop ((i 256) (out '()))
    (if (< i 0) out (loop (- i 1) (cons (integer->char i) out)))))

(define (lower? c) (and (char<=? #\a c) (char<=? c #\z)))
(define (upper? c) (and (char<=? #\A c) (char<=? c #\Z)))
(define (digit? c) (and (char<=? #\0 c) (char<=? c #\9)))

;; RFC 9110's tchar, written out.
(define (tchar? c)
  (or (lower? c) (upper? c) (digit? c) (memv c (string->list "!#$%&'*+-.^_`|~"))))

;; expected-verdicts : (Char -> Boolean) -> (Listof (U 'taken 'refused))
;; For each character of every-char, taken when TAKES? takes it, else refused.
(define (expected-verdicts takes?)
  (map (lambda (c) (if (takes? c) 'taken 'refused)) every-char))

;; verdicts : Symbol (Char -> Any) -> (Listof Any)
;; For each character of every-char, what (MAKE c) did: taken when it
;; returned, refused when it raised WHO's assertion violation, and (odd c
;; raised) for any other raise, which no check made.
(define (verdicts who make)
  (map (lambda (c)
         (let ((r (raised (lambda () (make c)))))
           (cond ((eq? r 'no-raise) 'taken)
                 ((and (eq? (car r) 'assertion-violation) (eq? (cadr r) who)) 'refused)
                 (else (list 'odd c r)))))
       every-char))

;; map-in-order : (A -> B) (Listof A) -> (Listof B)
;; map, with F called on each element in turn: map's own order is Chez's.
(define (map-in-order f xs)
  (if (null? xs)
      '()
      (let ((y (f (car xs))))
        (cons y (map-in-order f (cdr xs))))))

(test-begin "cors")

;; --- the options ------------------------------------------------------------------

(test-equal "wrap-cors takes exactly one origin option: none is refused"
  '(assertion-violation wrap-cors ())
  (raised (lambda () (wrap-cors (cors-methods 'PUT)))))

(test-equal "wrap-cors refuses two origin options, of one kind or two"
  '((assertion-violation wrap-cors (cors-any-origin))
    (assertion-violation wrap-cors (cors-origins))
    (assertion-violation wrap-cors (cors-origin-when)))
  (list (raised (lambda () (wrap-cors (cors-origins app-origin) (cors-any-origin))))
        (raised (lambda () (wrap-cors (cors-origins app-origin) (cors-origins "https://b.example"))))
        (raised (lambda () (wrap-cors (cors-any-origin) (cors-origin-when string?))))))

(test-equal "wrap-cors refuses each other option given twice"
  '((assertion-violation wrap-cors (cors-methods))
    (assertion-violation wrap-cors (cors-headers))
    (assertion-violation wrap-cors (cors-any-header))
    (assertion-violation wrap-cors (cors-expose-headers))
    (assertion-violation wrap-cors (cors-credentials))
    (assertion-violation wrap-cors (cors-max-age)))
  (map (lambda (make) (raised (lambda () (wrap-cors (cors-origins app-origin) (make) (make)))))
       (list (lambda () (cors-methods 'PUT))
             (lambda () (cors-headers "x-a"))
             cors-any-header
             (lambda () (cors-expose-headers "x-a"))
             cors-credentials
             (lambda () (cors-max-age 1)))))

(test-equal "wrap-cors refuses cors-headers with cors-any-header, either first"
  '((assertion-violation wrap-cors (cors-any-header))
    (assertion-violation wrap-cors (cors-headers)))
  (list (raised (lambda () (wrap-cors (cors-any-origin) (cors-headers "x-a") (cors-any-header))))
        (raised (lambda () (wrap-cors (cors-any-origin) (cors-any-header) (cors-headers "x-a"))))))

(test-equal "wrap-cors refuses cors-credentials with cors-any-origin, either first: Fetch never shares a credentialed response under *"
  '((assertion-violation wrap-cors (cors-credentials cors-any-origin))
    (assertion-violation wrap-cors (cors-credentials cors-any-origin)))
  (list (raised (lambda () (wrap-cors (cors-any-origin) (cors-credentials))))
        (raised (lambda () (wrap-cors (cors-credentials) (cors-any-origin))))))

(test-equal "wrap-cors refuses each constructor given bare, naming it: not the refusal of no origin option, which names none"
  '((assertion-violation wrap-cors (cors-origins))
    (assertion-violation wrap-cors (cors-origin-when))
    (assertion-violation wrap-cors (cors-any-origin))
    (assertion-violation wrap-cors (cors-methods))
    (assertion-violation wrap-cors (cors-headers))
    (assertion-violation wrap-cors (cors-any-header))
    (assertion-violation wrap-cors (cors-expose-headers))
    (assertion-violation wrap-cors (cors-credentials))
    (assertion-violation wrap-cors (cors-max-age)))
  (map (lambda (bare) (raised (lambda () (wrap-cors bare))))
       (list cors-origins cors-origin-when cors-any-origin cors-methods cors-headers
             cors-any-header cors-expose-headers cors-credentials cors-max-age)))

(test-equal "wrap-cors refuses what no constructor made"
  '((assertion-violation wrap-cors (credentials))
    (assertion-violation wrap-cors (#t))
    (assertion-violation wrap-cors ("https://app.example")))
  (map (lambda (x) (raised (lambda () (wrap-cors (cors-any-origin) x))))
       (list 'credentials #t app-origin)))

(test-equal "wrap-cors refuses a handler that is no procedure when it is applied"
  '(assertion-violation wrap-cors (not-a-handler))
  (raised (lambda () (listed 'not-a-handler))))

(test-equal "cors-origin-when refuses what is no procedure"
  '(assertion-violation cors-origin-when ("https://app.example"))
  (raised (lambda () (cors-origin-when app-origin))))

(test-equal "cors-methods refuses what is no symbol, and a symbol that is no token"
  (map (lambda (m) (list 'assertion-violation 'cors-methods (list m)))
       (list "PUT" (string->symbol "PU T") (string->symbol "") (string->symbol "PUT,GET")))
  (map (lambda (m) (raised (lambda () (cors-methods 'GET m))))
       (list "PUT" (string->symbol "PU T") (string->symbol "") (string->symbol "PUT,GET"))))

(test-equal "cors-methods takes a symbol whose name is a token at every character, and no other"
  (expected-verdicts tchar?)
  (verdicts 'cors-methods (lambda (c) (cors-methods (string->symbol (string #\P c #\T))))))

(test-equal "cors-headers and cors-expose-headers refuse what is no string, and a name that is no token"
  '((assertion-violation cors-headers (x-a))
    (assertion-violation cors-headers (""))
    (assertion-violation cors-headers ("x a"))
    (assertion-violation cors-expose-headers (x-a))
    (assertion-violation cors-expose-headers (""))
    (assertion-violation cors-expose-headers ("x a")))
  (append (map (lambda (n) (raised (lambda () (cors-headers "x-ok" n)))) (list 'x-a "" "x a"))
          (map (lambda (n) (raised (lambda () (cors-expose-headers "x-ok" n)))) (list 'x-a "" "x a"))))

(test-equal "cors-headers and cors-expose-headers each take a token at every character, and no other"
  (list (expected-verdicts tchar?) (expected-verdicts tchar?))
  (list (verdicts 'cors-headers (lambda (c) (cors-headers (string #\x c #\y))))
        (verdicts 'cors-expose-headers (lambda (c) (cors-expose-headers (string #\x c #\y))))))

(test-equal "wrap-cors refuses * in cors-methods, cors-headers or cors-expose-headers beside cors-credentials, either first, alone or in a list: a credentialed request reads it as a name"
  '((assertion-violation wrap-cors (cors-credentials cors-methods))
    (assertion-violation wrap-cors (cors-credentials cors-headers))
    (assertion-violation wrap-cors (cors-credentials cors-expose-headers))
    (assertion-violation wrap-cors (cors-credentials cors-methods))
    no-raise)
  (list (raised (lambda () (wrap-cors (cors-origins app-origin) (cors-credentials) (cors-methods '*))))
        (raised (lambda () (wrap-cors (cors-origins app-origin) (cors-headers "x-a" "*") (cors-credentials))))
        (raised (lambda () (wrap-cors (cors-credentials) (cors-expose-headers "*") (cors-origins app-origin))))
        (raised (lambda () (wrap-cors (cors-credentials) (cors-origins app-origin) (cors-methods 'PUT '*))))
        (raised (lambda () (wrap-cors (cors-origins app-origin) (cors-credentials) (cors-any-header) (cors-methods 'PUT))))))

(test-equal "without credentials, a * in a list is written as given: a browser reads it as every method or header"
  (list (preflight (acao "*") (acam "*") (acah "*"))
        (handled (acao "*") (aceh "*")))
  (let ((cors (wrap-cors (cors-any-origin) (cors-methods '*) (cors-headers "*") (cors-expose-headers "*"))))
    (list (answer cors (req 'OPTIONS (from app-origin) (asking "PUT")))
          (answer cors (req 'GET (from app-origin))))))

(test-equal "cors-max-age refuses what is no count of seconds"
  '((assertion-violation cors-max-age (-1))
    (assertion-violation cors-max-age (1.5))
    (assertion-violation cors-max-age (600.))
    (assertion-violation cors-max-age ("600")))
  (map (lambda (n) (raised (lambda () (cors-max-age n)))) (list -1 1.5 600. "600")))

;; --- origins: what cors-origins takes ---------------------------------------------

(define good-origins
  '("https://app.example" "http://localhost:8080" "https://127.0.0.1" "http://192.168.0.10:8080"
    "https://0.0.0.0" "https://255.255.255.255" "https://a.b.example.123a" "https://a.0x1g"
    "http://[::1]:3000" "https://[2001:db8::7]" "https://[::ffff:c000:201]" "https://[::]"
    "https://[1::]" "https://[1:0:0:2::3]" "https://[1::2:0:0:3:4]" "https://[1:2:3:4:5:6:7:8]"
    "https://[1:0:2:3:4:5:6:7]" "https://a_b.example"
    "https://xn--bcher-kva.example" "chrome-extension://abcdefgh" "web+app.x-1://app.example"
    "https://app.example:1" "https://app.example:65535" "http://app.example:443"
    "https://app.example:80" "ftp://app.example:80"))

(test-equal "cors-origins takes an origin as a browser writes one, and a request from it gets it back: a port that isn't its scheme's default is kept"
  (map (lambda (o) (handled (acao o) vary-origin)) good-origins)
  (map (lambda (o) (answer (wrap-cors (cors-origins o)) (req 'GET (from o)))) good-origins))

(define bad-origins
  '("https://app.example/" "https://app.example/path" "https://app.example?q" "https://app.example#f"
    "https://App.example" "HTTPS://app.example" "Https://app.example"
    "http://app.example:80" "https://app.example:443" "ws://app.example:80" "wss://app.example:443"
    "ftp://app.example:21"
    "https://app.example:" "https://app.example:08443" "https://app.example:65536"
    "https://app.example:123456" "https://app.example:-1" "https://app.example:8a"
    "https://" "https://:8443" "app.example" "//app.example" "https:/app.example" "https:app.example"
    "1https://app.example" "+https://app.example" "://app.example"
    "https://user@app.example" "https://app example" "https://app.example " " https://app.example"
    "https://[::1" "https://[]" "https://[1.2.3.4]" "https://[::A]" "https://[::1]x" "https://[::1]:"
    "https://[::1]:0443" "https://[0:0:0:0:0:0:0:1]" "https://[::0001]" "https://[:::]" "https://[.:.]"
    "https://[::1::2]" "https://[1:2:3:4:5:6:7:8:9]" "https://[1:2:3:4:5:6:7]" "https://[::ffff:192.0.2.1]"
    "https://[1::2:0:0:0:3]" "https://[1:0:0:2::3:4]" "https://[1:2:3:4:5:6:7::]" "https://[1:0:0:0:0:0:0:0]"
    "https://[1::0:2]" "https://[12345::]" "https://[::1]]" "https://[1:2:3:4::5:6:7:8]"
    "https://01.02.03.04" "https://127.1" "https://0x7f.0.0.1" "https://999.1.1.1" "https://256.0.0.1"
    "https://127.0.0.1." "https://1.2.3" "https://1.2.3.4.5" "https://example.123" "https://a.0x" "https://a.0x1f"
    "https://app.example:0" "https://app.example:99999999999999999999999"
    "file://host" "data://x" "about://x" "javascript://x" "blob://x"
    "*" ""))

(test-equal "cors-origins refuses anything else, each when the option is made"
  (map (lambda (o) (list 'assertion-violation 'cors-origins (list o))) bad-origins)
  (map (lambda (o) (raised (lambda () (cors-origins app-origin o)))) bad-origins))

(test-equal "cors-origins refuses what is no string"
  '(assertion-violation cors-origins (app.example))
  (raised (lambda () (cors-origins 'app.example))))

(test-equal "cors-origins refuses \"null\", saying why: any page can send it"
  (list '(assertion-violation cors-origins ("null"))
        "null is never an origin wrap-cors allows: a sandboxed iframe, a file: page and some redirects send it, and any page can make one; cors-any-origin allows every origin")
  (list (raised (lambda () (cors-origins app-origin "null")))
        (raised-message (lambda () (cors-origins "null")))))

(test-equal "a host takes a lower-case letter, a digit, -, . and _ at every character, and no other"
  (expected-verdicts (lambda (c) (or (lower? c) (digit? c) (memv c '(#\- #\. #\_)))))
  (verdicts 'cors-origins (lambda (c) (cors-origins (string-append "https://a" (string c) "b.example")))))

(test-equal "a scheme takes, after its first letter, a lower-case letter, a digit, +, - and . at every character, and no other"
  (expected-verdicts (lambda (c) (or (lower? c) (digit? c) (memv c '(#\+ #\- #\.)))))
  (verdicts 'cors-origins (lambda (c) (cors-origins (string-append "h" (string c) "ttps://app.example")))))

(test-equal "a scheme's first character is a lower-case letter, and no other"
  (expected-verdicts lower?)
  (verdicts 'cors-origins (lambda (c) (cors-origins (string-append (string c) "ttps://app.example")))))

(test-equal "a bracketed host takes a lower-case hex digit at every character, and no other"
  (expected-verdicts (lambda (c) (or (digit? c) (memv c (string->list "abcdef")))))
  (verdicts 'cors-origins (lambda (c) (cors-origins (string-append "https://[1:2:3:4:5:6:7:" (string c) "]")))))

(test-equal "a host whose last label is a number is an IPv4 address with no leading 0: its third part takes 1 to 9 before a 0 at every character, and no other"
  (expected-verdicts (lambda (c) (and (char<=? #\1 c) (char<=? c #\9))))
  (verdicts 'cors-origins (lambda (c) (cors-origins (string-append "https://10.0." (string c) "0.1")))))

(test-equal "an origin changed after cors-origins is made changes nothing it allows: it keeps its own copy"
  (list (handled (acao app-origin) vary-origin) (handled vary-origin))
  (let* ((o (string-copy app-origin))
         (cors (wrap-cors (cors-origins o))))
    (string-set! o 18 #\/)
    (let* ((a (answer cors (req 'GET (from app-origin))))
           (b (answer cors (req 'GET (from "https://app.exampl/")))))
      (list a b))))

(test-equal "a port takes a digit at every character, and no other"
  (expected-verdicts digit?)
  (verdicts 'cors-origins (lambda (c) (cors-origins (string-append "https://app.example:8" (string c))))))

;; --- origins: what a request must send ----------------------------------------------

(define missing-origins
  '("http://app.example" "https://app.example:8443" "https://APP.example" "https://App.example"
    "HTTPS://app.example" "https://app.example/" "https://app.example/x" "https://app.example.evil"
    "https://evilapp.example" "https://app.exampl" "https://pp.example" "null" ""))

(test-equal "a request's Origin matches only the very origin listed: each miss reaches the handler, with no access-control field but Vary"
  (map (lambda (o) (handled vary-origin)) missing-origins)
  (map (lambda (o) (answer listed (req 'GET (from o)))) missing-origins))

(test-equal "an Origin listed matches: the handler runs, and its response gets the origin and Vary"
  (handled (acao app-origin) vary-origin)
  (answer listed (req 'GET (from app-origin))))

(test-equal "any listed origin matches, each getting its own back"
  (list (handled (acao app-origin) vary-origin)
        (handled (acao "https://b.example") vary-origin)
        (handled vary-origin))
  (let ((two (wrap-cors (cors-origins app-origin "https://b.example"))))
    (list (answer two (req 'GET (from app-origin)))
          (answer two (req 'GET (from "https://b.example")))
          (answer two (req 'GET (from "https://c.example"))))))

(test-equal "a request with two Origin fields matches no origin, the same one twice too"
  (list (handled vary-origin) (handled vary-origin))
  (list (answer listed (req 'GET (from app-origin) (from app-origin)))
        (answer listed (req 'GET (from app-origin) (from "https://b.example")))))

(test-equal "a request with no Origin reaches the handler, and its response varies on Origin all the same"
  (handled vary-origin)
  (answer listed (req 'GET)))

(test-equal "the Origin is matched whatever the method: POST, DELETE and a method of the app's own"
  (list (handled (acao app-origin) vary-origin)
        (handled (acao app-origin) vary-origin)
        (handled (acao app-origin) vary-origin))
  (list (answer listed (req 'POST (from app-origin)))
        (answer listed (req 'DELETE (from app-origin)))
        (answer listed (req 'PURGE (from app-origin)))))

;; --- origins: a predicate ---------------------------------------------------------

;; ends-with? : String String -> Boolean
(define (ends-with? s tail)
  (let ((n (string-length s)) (k (string-length tail)))
    (and (>= n k) (string=? (substring s (- n k) n) tail))))

(test-equal "the predicate is asked only about an Origin a browser could send: a path, null and a malformed one never reach it, and ending in .example.com takes a subdomain, not evilexample.com"
  (list (list (handled (acao "https://api.example.com") vary-origin)
              (handled vary-origin)
              (handled vary-origin)
              (handled vary-origin)
              (handled vary-origin)
              (handled vary-origin))
        '("https://api.example.com" "https://evilexample.com"))
  (let* ((asked '())
         (cors (wrap-cors (cors-origin-when
                           (lambda (o) (set! asked (cons o asked)) (ends-with? o ".example.com")))))
         (answers (map-in-order (lambda (o) (answer cors (req 'GET (from o))))
                       '("https://api.example.com" "https://evil.test/.example.com" "null"
                         "https://evilexample.com" "https://API.example.com" "https://x.example.com/"))))
    (list answers (reverse asked))))

(test-equal "a predicate's answer allows when it is anything but #f, 0 included"
  (list (handled (acao app-origin) vary-origin) (handled vary-origin))
  (list (answer (wrap-cors (cors-origin-when (lambda (o) 0))) (req 'GET (from app-origin)))
        (answer (wrap-cors (cors-origin-when (lambda (o) #f))) (req 'GET (from app-origin)))))

(test-equal "a request with two Origin fields never reaches the predicate"
  (list (handled vary-origin) '())
  (let* ((asked '())
         (cors (wrap-cors (cors-origin-when (lambda (o) (set! asked (cons o asked)) #t))))
         (a (answer cors (req 'GET (from app-origin) (from app-origin)))))
    (list a asked)))

;; --- origins: any -------------------------------------------------------------------

(test-equal "cors-any-origin puts * on every response, with an Origin, without one, and with two; and no Vary"
  (list (handled (acao "*")) (handled (acao "*")) (handled (acao "*")) (handled (acao "*")))
  (list (answer anyone (req 'GET (from app-origin)))
        (answer anyone (req 'GET))
        (answer anyone (req 'GET (from app-origin) (from "https://b.example")))
        (answer anyone (req 'GET (from "null")))))

;; --- the fields on the handler's response ---------------------------------------

(test-equal "with cors-credentials and cors-expose-headers, a match gets the origin, credentials, the expose list in lower case, then Vary"
  (handled (acao app-origin) acac (aceh "x-total, x-page") vary-origin)
  (answer (wrap-cors (cors-credentials) (cors-expose-headers "X-Total" "x-page") (cors-origins app-origin))
          (req 'GET (from app-origin))))

(test-equal "a miss gets none of them: Vary alone"
  (handled vary-origin)
  (answer (wrap-cors (cors-credentials) (cors-expose-headers "x-total") (cors-origins app-origin))
          (req 'GET (from "https://b.example"))))

(test-equal "cors-any-origin's response gets the expose list too"
  (handled (acao "*") (aceh "x-total"))
  (answer (wrap-cors (cors-any-origin) (cors-expose-headers "x-total")) (req 'GET (from app-origin))))

(test-equal "the methods, the allowed headers and the max-age go on a preflight's answer alone"
  (handled (acao app-origin) vary-origin)
  (answer (wrap-cors (cors-origins app-origin) (cors-methods 'PUT) (cors-headers "x-a") (cors-max-age 600))
          (req 'GET (from app-origin))))

(test-equal "wrap-cors's fields replace the handler's of the same name, in any case, where the first stood"
  (list 200
        '(("access-control-allow-origin" . "https://app.example") ("x-from" . "handler")
          ("access-control-allow-credentials" . "true")
          ("access-control-expose-headers" . "x-total") ("vary" . "origin"))
        "from the handler" 1)
  (answer (wrap-cors (cors-origins app-origin) (cors-credentials) (cors-expose-headers "x-total"))
          (req 'GET (from app-origin))
          (handler-with '(("Access-Control-Allow-Origin" . "https://other.example") ("x-from" . "handler")
                          ("access-control-allow-credentials" . "false")
                          ("ACCESS-CONTROL-EXPOSE-HEADERS" . "x-secret")
                          ("access-control-allow-origin" . "https://third.example")))))

(test-equal "on a miss, the handler's own access-control fields stay as it set them"
  (list 200 '(("access-control-allow-origin" . "https://other.example") ("vary" . "origin"))
        "from the handler" 1)
  (answer listed (req 'GET (from "https://b.example"))
          (handler-with '(("access-control-allow-origin" . "https://other.example")))))

(test-equal "cors-any-origin's * replaces the handler's origin"
  (list 200 '(("access-control-allow-origin" . "*") ("x-from" . "handler")) "from the handler" 1)
  (answer anyone (req 'GET)
          (handler-with '(("access-control-allow-origin" . "https://other.example") ("x-from" . "handler")))))

(test-equal "an answer that is no response passes wrap-cors as it is"
  '(answered not-a-response)
  (((wrap-cors (cors-origins app-origin)) (lambda (r) '(answered not-a-response)))
   (req 'GET (from app-origin))))

(test-equal "an upgrade that passes wrap-cors gets the fields and stays an upgrade, its take-over kept"
  (list 101 '(("upgrade" . "x-proto") ("access-control-allow-origin" . "https://app.example") ("vary" . "origin"))
        #t #t)
  (let* ((take-over (lambda (transport bytes) 'taken))
         (res ((listed (lambda (r) (make-upgrade-res '(("upgrade" . "x-proto")) take-over)))
               (req 'GET (from app-origin)))))
    (list (res-status res) (res-headers res) (res-upgrade-body? (res-body res))
          (eq? take-over (res-upgrade-body-take-over (res-body res))))))

;; --- the preflight -----------------------------------------------------------------

(define full
  (wrap-cors (cors-origins app-origin) (cors-methods 'PUT 'DELETE 'patch)
             (cors-headers "Content-Type" "x-api-key") (cors-credentials) (cors-max-age 600)
             (cors-expose-headers "x-total")))

(test-equal "a preflight is answered 204 by wrap-cors itself, the handler never run, its fields in order: the methods as given, the headers in lower case, no expose list"
  (preflight (acao app-origin) acac (acam "PUT, DELETE, patch") (acah "content-type, x-api-key")
             (acma "600") vary-origin)
  (answer full (req 'OPTIONS (from app-origin) (asking "PUT"))))

(test-equal "wrap-cors doesn't check the preflight's method or headers against its lists: the browser does"
  (preflight (acao app-origin) acac (acam "PUT, DELETE, patch") (acah "content-type, x-api-key")
             (acma "600") vary-origin)
  (answer full (req 'OPTIONS (from app-origin) (asking "PATCH") (asking-headers "x-not-listed"))))

(test-equal "with the origin alone, a preflight's answer is the origin and Vary"
  (preflight (acao app-origin) vary-origin)
  (answer listed (req 'OPTIONS (from app-origin) (asking "PUT"))))

(test-equal "an OPTIONS without Access-Control-Request-Method, or with two, is an ordinary request"
  (list (handled (acao app-origin) acac (aceh "x-total") vary-origin)
        (handled (acao app-origin) acac (aceh "x-total") vary-origin))
  (list (answer full (req 'OPTIONS (from app-origin)))
        (answer full (req 'OPTIONS (from app-origin) (asking "PUT") (asking "DELETE")))))

(test-equal "a preflight whose Origin doesn't match goes to the handler, with Vary alone"
  (list (handled vary-origin) (handled vary-origin) (handled vary-origin))
  (list (answer full (req 'OPTIONS (from "https://b.example") (asking "PUT")))
        (answer full (req 'OPTIONS (from app-origin) (from app-origin) (asking "PUT")))
        (answer full (req 'OPTIONS (asking "PUT")))))

(test-equal "a GET or a POST with Access-Control-Request-Method is no preflight, nor is a method named options in lower case"
  (list (handled (acao app-origin) vary-origin) (handled (acao app-origin) vary-origin)
        (handled (acao app-origin) vary-origin))
  (list (answer listed (req 'GET (from app-origin) (asking "PUT")))
        (answer listed (req 'POST (from app-origin) (asking "PUT")))
        (answer listed (req 'options (from app-origin) (asking "PUT")))))

(test-equal "under cors-any-origin, a preflight from any one Origin, null too, gets * and no Vary"
  (list (preflight (acao "*") (acam "PUT"))
        (preflight (acao "*") (acam "PUT"))
        (handled (acao "*")))
  (let ((cors (wrap-cors (cors-any-origin) (cors-methods 'PUT))))
    (list (answer cors (req 'OPTIONS (from app-origin) (asking "PUT")))
          (answer cors (req 'OPTIONS (from "null") (asking "PUT")))
          (answer cors (req 'OPTIONS (asking "PUT"))))))

(test-equal "a preflight the predicate allows gets its origin"
  (preflight (acao "https://api.example.com") (acam "PUT") vary-origin)
  (answer (wrap-cors (cors-origin-when (lambda (o) (ends-with? o ".example.com"))) (cors-methods 'PUT))
          (req 'OPTIONS (from "https://api.example.com") (asking "PUT"))))

(test-equal "a max-age is written in decimal: 0, a fixnum and a bignum"
  (list (preflight (acao "*") (acma "0"))
        (preflight (acao "*") (acma "86400"))
        (preflight (acao "*") (acma "1267650600228229401496703205376")))
  (map (lambda (n) (answer (wrap-cors (cors-any-origin) (cors-max-age n))
                           (req 'OPTIONS (from app-origin) (asking "PUT"))))
       (list 0 86400 (expt 2 100))))

;; --- cors-any-header ---------------------------------------------------------------

(define echoing (wrap-cors (cors-origins app-origin) (cors-any-header)))
(define vary-both (cons "vary" "origin, access-control-request-headers"))

(test-equal "cors-any-header echoes the preflight's Access-Control-Request-Headers as it came, and varies on it too"
  (list (preflight (acao app-origin) (acah "content-type,x-api-key") vary-both)
        (preflight (acao app-origin) (acah "Authorization") vary-both)
        (preflight (acao app-origin) (acah "a , b") vary-both))
  (map (lambda (names) (answer echoing (req 'OPTIONS (from app-origin) (asking "PUT") (asking-headers names))))
       '("content-type,x-api-key" "Authorization" "a , b")))

(test-equal "cors-any-header sends no allowed headers for a list that is no list of tokens, two fields, or none, and still varies on it"
  (list (preflight (acao app-origin) vary-both)
        (preflight (acao app-origin) vary-both)
        (preflight (acao app-origin) vary-both)
        (preflight (acao app-origin) vary-both)
        (preflight (acao app-origin) vary-both)
        (preflight (acao app-origin) vary-both))
  (list (answer echoing (req 'OPTIONS (from app-origin) (asking "PUT") (asking-headers "a b")))
        (answer echoing (req 'OPTIONS (from app-origin) (asking "PUT") (asking-headers "a,,b")))
        (answer echoing (req 'OPTIONS (from app-origin) (asking "PUT") (asking-headers "a,")))
        (answer echoing (req 'OPTIONS (from app-origin) (asking "PUT") (asking-headers "")))
        (answer echoing (req 'OPTIONS (from app-origin) (asking "PUT") (asking-headers "a") (asking-headers "b")))
        (answer echoing (req 'OPTIONS (from app-origin) (asking "PUT")))))

(test-equal "cors-any-header's echo takes a token's characters, and the comma between two, at every character, and no other"
  (map (lambda (c)
         (if (or (tchar? c) (char=? c #\,))
             (preflight (acao app-origin) (acah (string #\x c #\y)) vary-both)
             (preflight (acao app-origin) vary-both)))
       every-char)
  (map (lambda (c)
         (answer echoing (req 'OPTIONS (from app-origin) (asking "PUT") (asking-headers (string #\x c #\y)))))
       every-char))

(test-equal "under cors-any-origin, cors-any-header's preflight varies on Access-Control-Request-Headers alone, and its other responses not at all"
  (list (preflight (acao "*") (acah "x-a") (cons "vary" "access-control-request-headers"))
        (handled (acao "*")))
  (let ((cors (wrap-cors (cors-any-origin) (cors-any-header))))
    (list (answer cors (req 'OPTIONS (from app-origin) (asking "PUT") (asking-headers "x-a")))
          (answer cors (req 'GET (from app-origin) (asking-headers "x-a"))))))

(test-equal "cors-any-header and credentials: the echo, not *, which Fetch doesn't take for a credentialed request"
  (preflight (acao app-origin) acac (acah "authorization") vary-both)
  (answer (wrap-cors (cors-origins app-origin) (cors-any-header) (cors-credentials))
          (req 'OPTIONS (from app-origin) (asking "PUT") (asking-headers "authorization"))))

;; --- Vary --------------------------------------------------------------------------

;; handled-with : Headers -> (List Integer Headers String Nat)
;; The handler's answer, run once, its fields FIELDS.
(define (handled-with fields)
  (list 200 fields "from the handler" 1))

(define listing-origin
  '((("vary" . "Accept, Origin")) (("Vary" . "ORIGIN")) (("vary" . "accept,origin"))
    (("vary" . " origin ")) (("vary" . "accept") ("vary" . "origin")) (("vary" . "*"))
    (("vary" . "accept, *"))))

(test-equal "Vary: origin is added as a field of its own after a vary that lists something else"
  (list (handled-with (list '("vary" . "accept") (acao app-origin) vary-origin))
        (handled-with (list '("vary" . "accept-origin, origins") (acao app-origin) vary-origin)))
  (list (answer listed (req 'GET (from app-origin)) (handler-with '(("vary" . "accept"))))
        (answer listed (req 'GET (from app-origin)) (handler-with '(("vary" . "accept-origin, origins"))))))

(test-equal "no Vary is added when one of the handler's vary fields lists origin, in any case, with or without space, or is *"
  (map (lambda (vary) (handled-with (append vary (list (acao app-origin))))) listing-origin)
  (map (lambda (vary) (answer listed (req 'GET (from app-origin)) (handler-with vary))) listing-origin))

(test-equal "the Vary rule holds on a miss and with no Origin as well"
  (list (handled-with '(("vary" . "accept") ("vary" . "origin"))) (handled-with '(("vary" . "Origin"))))
  (list (answer listed (req 'GET (from "https://b.example")) (handler-with '(("vary" . "accept"))))
        (answer listed (req 'GET) (handler-with '(("vary" . "Origin"))))))

;; --- made once -------------------------------------------------------------------

(test-equal "a wrap-cors made once answers each request on its own"
  (list (preflight (acao app-origin) acac (acam "PUT, DELETE, patch") (acah "content-type, x-api-key")
                   (acma "600") vary-origin)
        (handled (acao app-origin) acac (aceh "x-total") vary-origin)
        (handled vary-origin)
        (preflight (acao app-origin) acac (acam "PUT, DELETE, patch") (acah "content-type, x-api-key")
                   (acma "600") vary-origin))
  (let* ((a (answer full (req 'OPTIONS (from app-origin) (asking "PUT"))))
         (b (answer full (req 'GET (from app-origin))))
         (c (answer full (req 'GET (from "https://b.example"))))
         (d (answer full (req 'OPTIONS (from app-origin) (asking "DELETE")))))
    (list a b c d)))

(test-end "cors")

(exit (suite-exit-status runner))
