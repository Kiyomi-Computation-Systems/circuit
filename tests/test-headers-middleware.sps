#!r6rs
;;; (circuit middleware headers): wrap-default-headers, security-headers and
;;; wrap-hsts (the slice 9 design §4).
;;;
;;; Oracles: RFC 9110, for a token (§5.6.2) and a field value (§5.5), as the
;;; server's serializer refuses them; RFC 6797, for HSTS's value (§6.1) and
;;; that it goes over https alone (§7.2). Each row about a request asserts
;;; the whole answer: its status, every field in order, and its body.
(import (rnrs)
        (rnrs mutable-pairs)
        (rnrs mutable-strings)
        (srfi :64)
        (circuit-testing)
        (circuit response)
        (only (circuit request) req-with-scheme)
        (only (circuit test) make-test-req)
        (circuit middleware headers))

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


;; The handler's own fields: none a default.
(define base '(("content-type" . "text/plain") ("x-from" . "handler")))

;; handler-with : Headers -> Handler
(define (handler-with headers)
  (lambda (req) (make-res 200 headers "from the handler")))

;; answer : Middleware Headers Req -> (List Integer Headers Any)
;; What MIDDLEWARE, around a handler answering HEADERS, answers REQ.
(define (answer middleware headers req)
  (let ((res ((middleware (handler-with headers)) req)))
    (list (res-status res) (res-headers res) (res-body res))))

(define (get) (make-test-req 'GET "/"))
(define (https) (req-with-scheme (make-test-req 'GET "/") 'https))

;; every-char : (Listof Char)
;; Every character from 0 to 255, and one past it.
(define every-char
  (let loop ((i 256) (out '()))
    (if (< i 0) out (loop (- i 1) (cons (integer->char i) out)))))

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

(define (tchar? c)
  (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9)
      (memv c (string->list "!#$%&'*+-.^_`|~"))))

;; field-char? : Char -> Boolean
;; What the server's serializer takes in a value: HTAB, SP, VCHAR and
;; obs-text, each one byte.
(define (field-char? c)
  (let ((n (char->integer c)))
    (or (= n 9) (and (>= n 32) (<= n 255) (not (= n 127))))))

(test-begin "headers-middleware")

;; --- security-headers ---------------------------------------------------------------

(test-equal "security-headers is the three fields, in order"
  '(("x-content-type-options" . "nosniff")
    ("x-frame-options" . "SAMEORIGIN")
    ("referrer-policy" . "strict-origin-when-cross-origin"))
  security-headers)

;; --- wrap-default-headers -------------------------------------------------------------

(test-equal "wrap-default-headers adds each field the response lacks, after the handler's own, in the list's order"
  (list 200 (append base security-headers) "from the handler")
  (answer (wrap-default-headers security-headers) base (get)))

(test-equal "a field the handler set, in any case, is kept as it set it, and the rest are added"
  (list 200
        '(("content-type" . "text/plain") ("X-FRAME-OPTIONS" . "DENY") ("x-from" . "handler")
          ("x-content-type-options" . "nosniff") ("referrer-policy" . "strict-origin-when-cross-origin"))
        "from the handler")
  (answer (wrap-default-headers security-headers)
          '(("content-type" . "text/plain") ("X-FRAME-OPTIONS" . "DENY") ("x-from" . "handler"))
          (get)))

(test-equal "a default named in another case matches the handler's field all the same, and one it adds is written in lower case"
  (list (list 200 '(("x-thing" . "mine")) "from the handler")
        (list 200 '(("x-other" . "mine") ("x-thing" . "default")) "from the handler"))
  (let ((m (wrap-default-headers '(("X-Thing" . "default")))))
    (list (answer m '(("x-thing" . "mine")) (get))
          (answer m '(("x-other" . "mine")) (get)))))

(test-equal "a default list that names a field twice adds both when the response lacks it, and neither when it has one"
  (list (list 200 '(("x-from" . "handler") ("link" . "</a>") ("link" . "</b>")) "from the handler")
        (list 200 '(("Link" . "</mine>")) "from the handler"))
  (let ((m (wrap-default-headers '(("link" . "</a>") ("link" . "</b>")))))
    (list (answer m '(("x-from" . "handler")) (get))
          (answer m '(("Link" . "</mine>")) (get)))))

(test-equal "an empty list adds nothing"
  (list 200 base "from the handler")
  (answer (wrap-default-headers '()) base (get)))

(test-equal "a list changed after the middleware is made changes nothing it adds, its pairs or its strings: it keeps its own copy"
  (list (list 200 '(("x-from" . "handler") ("x-a" . "1")) "from the handler")
        (list 200 '(("x-from" . "handler") ("x-b" . "2")) "from the handler"))
  (let* ((fields (list (cons "x-a" "1")))
         (name (string-copy "x-b"))
         (value (string-copy "2"))
         (strings (list (cons name value)))
         (m (wrap-default-headers fields))
         (n (wrap-default-headers strings)))
    (set-cdr! (car fields) "bad\nvalue")
    (set-car! (car fields) "bad name")
    (string-set! name 1 #\space)
    (string-set! value 0 #\newline)
    (list (answer m '(("x-from" . "handler")) (get))
          (answer n '(("x-from" . "handler")) (get)))))

(test-equal "an answer that is no response passes as it is"
  '(answered not-a-response)
  (((wrap-default-headers security-headers) (lambda (r) '(answered not-a-response))) (get)))

(test-equal "an upgrade gets the fields and stays an upgrade, its take-over kept"
  (list 101 '(("upgrade" . "x-proto") ("x-content-type-options" . "nosniff")
              ("x-frame-options" . "SAMEORIGIN") ("referrer-policy" . "strict-origin-when-cross-origin"))
        #t #t)
  (let* ((take-over (lambda (transport bytes) 'taken))
         (res (((wrap-default-headers security-headers)
                (lambda (r) (make-upgrade-res '(("upgrade" . "x-proto")) take-over)))
               (get))))
    (list (res-status res) (res-headers res) (res-upgrade-body? (res-body res))
          (eq? take-over (res-upgrade-body-take-over (res-body res))))))

(test-equal "wrap-default-headers refuses what is no header list when it is made"
  '((assertion-violation wrap-default-headers (not-a-list))
    (assertion-violation wrap-default-headers ((("x-a" . "1") . oops)))
    (assertion-violation wrap-default-headers (x-a))
    (assertion-violation wrap-default-headers ((x-a . "1")))
    (assertion-violation wrap-default-headers (("x-a" . 1))))
  (map (lambda (fields) (raised (lambda () (wrap-default-headers fields))))
       (list 'not-a-list '(("x-a" . "1") . oops) '(x-a) '((x-a . "1")) '(("x-a" . 1)))))

(test-equal "wrap-default-headers refuses a name that is no token, and a value the server can't write"
  '((assertion-violation wrap-default-headers (("" . "1")))
    (assertion-violation wrap-default-headers (("x a" . "1")))
    (assertion-violation wrap-default-headers (("x-a" . "1\r\nx-b: 2"))))
  (map (lambda (field) (raised (lambda () (wrap-default-headers (list '("x-ok" . "1") field)))))
       (list '("" . "1") '("x a" . "1") '("x-a" . "1\r\nx-b: 2"))))

(test-equal "wrap-default-headers refuses the fields the server writes itself, in any case: the server would refuse every response"
  '((assertion-violation wrap-default-headers (("content-length" . "0")))
    (assertion-violation wrap-default-headers (("Transfer-Encoding" . "chunked")))
    (assertion-violation wrap-default-headers (("CONNECTION" . "close"))))
  (map (lambda (field) (raised (lambda () (wrap-default-headers (list '("x-ok" . "1") field)))))
       (list '("content-length" . "0") '("Transfer-Encoding" . "chunked") '("CONNECTION" . "close"))))

(test-equal "a default's name takes a token at every character, and no other"
  (expected-verdicts tchar?)
  (verdicts 'wrap-default-headers (lambda (c) (wrap-default-headers (list (cons (string #\x c #\y) "1"))))))

(test-equal "a default's value takes HTAB, SP, VCHAR and obs-text at every character, and no other"
  (expected-verdicts field-char?)
  (verdicts 'wrap-default-headers (lambda (c) (wrap-default-headers (list (cons "x-a" (string #\a c #\b)))))))

(test-equal "an empty value is a value"
  (list 200 '(("x-from" . "handler") ("x-a" . "")) "from the handler")
  (answer (wrap-default-headers '(("x-a" . ""))) '(("x-from" . "handler")) (get)))

(test-equal "wrap-default-headers refuses a handler that is no procedure when it is applied"
  '(assertion-violation wrap-default-headers (not-a-handler))
  (raised (lambda () ((wrap-default-headers security-headers) 'not-a-handler))))

;; --- wrap-hsts ------------------------------------------------------------------------

(test-equal "wrap-hsts sends strict-transport-security on an https request, after the handler's fields"
  (list 200 (append base '(("strict-transport-security" . "max-age=31536000"))) "from the handler")
  (answer (wrap-hsts 31536000) base (https)))

(test-equal "wrap-hsts sends nothing on an http request: the handler's response is answered as it is"
  #t
  (let ((res (make-res 200 base "from the handler")))
    (eq? res (((wrap-hsts 31536000) (lambda (r) res)) (get)))))

(test-equal "wrap-hsts reads the scheme of the request it is handed, so a middleware outside it that believes a proxy decides"
  (list (list 200 (append base '(("strict-transport-security" . "max-age=60"))) "from the handler")
        (list 200 base "from the handler"))
  (let ((app ((wrap-hsts 60) (handler-with base))))
    (let* ((a (app (req-with-scheme (get) 'https)))
           (b (app (req-with-scheme (https) 'http))))
      (list (list (res-status a) (res-headers a) (res-body a))
            (list (res-status b) (res-headers b) (res-body b))))))

(test-equal "hsts-include-subdomains adds includeSubDomains"
  (list 200 (append base '(("strict-transport-security" . "max-age=31536000; includeSubDomains")))
        "from the handler")
  (answer (wrap-hsts 31536000 (hsts-include-subdomains)) base (https)))

(test-equal "wrap-hsts's field replaces the handler's, in any case, where the first stood"
  (list 200 '(("strict-transport-security" . "max-age=600") ("x-from" . "handler")) "from the handler")
  (answer (wrap-hsts 600)
          '(("Strict-Transport-Security" . "max-age=1") ("x-from" . "handler")
            ("strict-transport-security" . "max-age=2"))
          (https)))

(test-equal "a max-age is written in decimal: 0, which tells the browser to forget, a fixnum and a bignum"
  (map (lambda (v) (list 200 (list (cons "strict-transport-security" v)) "from the handler"))
       (list "max-age=0" "max-age=31536000" "max-age=1267650600228229401496703205376"))
  (map (lambda (n) (answer (wrap-hsts n) '() (https)))
       (list 0 31536000 (expt 2 100))))

(test-equal "wrap-hsts refuses a max-age that is no count of seconds"
  '((assertion-violation wrap-hsts (-1))
    (assertion-violation wrap-hsts (1.5))
    (assertion-violation wrap-hsts (600.))
    (assertion-violation wrap-hsts ("600"))
    (assertion-violation wrap-hsts (#f)))
  (map (lambda (n) (raised (lambda () (wrap-hsts n)))) (list -1 1.5 600. "600" #f)))

(test-equal "wrap-hsts refuses an option twice, hsts-include-subdomains given bare, and what no constructor made"
  '((assertion-violation wrap-hsts (hsts-include-subdomains))
    (assertion-violation wrap-hsts (hsts-include-subdomains))
    (assertion-violation wrap-hsts (include-subdomains)))
  (list (raised (lambda () (wrap-hsts 60 (hsts-include-subdomains) (hsts-include-subdomains))))
        (raised (lambda () (wrap-hsts 60 hsts-include-subdomains)))
        (raised (lambda () (wrap-hsts 60 'include-subdomains)))))

(test-equal "an answer that is no response passes wrap-hsts as it is, over https too"
  '(answered not-a-response)
  (((wrap-hsts 60) (lambda (r) '(answered not-a-response))) (https)))

(test-equal "an upgrade over https gets the field and stays an upgrade"
  (list 101 '(("upgrade" . "x-proto") ("strict-transport-security" . "max-age=60")) #t)
  (let ((res (((wrap-hsts 60) (lambda (r) (make-upgrade-res '(("upgrade" . "x-proto")) (lambda (t b) 'taken))))
              (https))))
    (list (res-status res) (res-headers res) (res-upgrade-body? (res-body res)))))

(test-equal "wrap-hsts refuses a handler that is no procedure when it is applied"
  '(assertion-violation wrap-hsts (not-a-handler))
  (raised (lambda () ((wrap-hsts 60) 'not-a-handler))))

(test-end "headers-middleware")

(exit (suite-exit-status runner))
