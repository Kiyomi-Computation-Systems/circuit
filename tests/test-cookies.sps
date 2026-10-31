#!r6rs
;;; (circuit cookies): the request's cookies read, set-cookie fields
;;; written, and their refusals (the slice 9 design §6).
;;;
;;; Oracles: RFC 6265bis (draft-ietf-httpbis-rfc6265bis-22), its §4.1.1
;;; grammar, cookie-octet and av-octet as its ranges, with token from RFC
;;; 9110 §5.6.2; its §3.1 examples; its §4.1.3 and §5.4 prefix examples;
;;; and §5.6 and §5.7 for what a browser ignores.
;;;
;;; The rows:
;;;   - req-cookies: the RFC's examples; every cookie field, in order;
;;;     empty pieces, a piece with no =, an empty name; a value with = in
;;;     it; quotes kept; every character beside a name and a value, only a
;;;     space and a tab trimmed; a Latin-1 byte; characters not checked;
;;;   - req-cookie: the first of a name, matched exactly;
;;;   - res-add-cookie and res-expire-cookie: the RFC's and the design's
;;;     examples, whole fields; one attribute order for every order of the
;;;     options; the response's own fields kept;
;;;   - the allowlists against their whole complements: each of the 256
;;;     bytes and six characters past 255 alone in a value, bare and
;;;     quoted, against cookie-octet; in a name against token; in a path
;;;     and a domain against av-octet; a refused character at every
;;;     position;
;;;   - the limits from both sides: a name and value of 4096 bytes and
;;;     4097, a path and a domain of 1024 and 1025, a max-age of 1 and 0,
;;;     and a bignum;
;;;   - the prefixes, matched in any case, the RFC's examples among them;
;;;     SameSite=None without Secure; each option twice, bare, or no
;;;     option; a max-age to res-expire-cookie; every refusal's message;
;;;   - through the server's test host: two cookie fields and a Latin-1
;;;     byte read, and the fields written going out in order.
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (circuit-testing)
        (http-server testing)
        (circuit)
        (circuit http-server)
        (circuit test)
        (circuit cookies))

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

;; set-cookies : Res -> (Listof String) — R's set-cookie fields, in order.
(define (set-cookies r)
  (map cdr (filter (lambda (f) (string-ci=? (car f) "set-cookie")) (res-headers r))))

;; written : (-> Res) -> Any
;; The set-cookie fields of the response THUNK answers, or what it raised.
(define (written thunk)
  (raised (lambda () (set-cookies (thunk)))))

;; one : String -> Any — what written answers for one field, FIELD.
(define (one field) (list 'returned (list field)))

(define (refused who message . irritants) (list 'refused who message irritants))

(define (iota n) (let loop ((i (- n 1)) (out '())) (if (< i 0) out (loop (- i 1) (cons i out)))))

;; map-in-order : (a -> b) (Listof a) -> (Listof b)
;; map, calling F on each element in turn: map's order is unspecified.
(define (map-in-order f xs)
  (let loop ((xs xs) (out '()))
    (if (null? xs) (reverse out) (loop (cdr xs) (cons (f (car xs)) out)))))

(define (distinct xs)
  (fold-left (lambda (acc x) (if (member x acc) acc (append acc (list x)))) '() xs))

(define (permutations xs)
  (if (null? xs)
      '(())
      (apply append
             (map (lambda (x)
                    (map (lambda (p) (cons x p)) (permutations (remp (lambda (y) (eq? y x)) xs))))
                  xs))))

;; Every byte, and six characters past 255: the last of two UTF-8 bytes,
;; the first and last of three, and the first and last of four.
(define every-char
  (append (iota 256) '(#x100 #x7FF #x800 #xFFFF #x10000 #x10FFFF)))

(define (char-string n) (string (integer->char n)))

;; The RFC's sets, as its ranges.
(define (cookie-octet? n)
  (or (= n #x21) (<= #x23 n #x2B) (<= #x2D n #x3A) (<= #x3C n #x5B) (<= #x5D n #x7E)))
(define (tchar? n)
  (or (<= 48 n 57) (<= 65 n 90) (<= 97 n 122)
      (and (memv n (map char->integer (string->list "!#$%&'*+-.^_`|~"))) #t)))
(define (av-octet? n) (or (<= #x20 n #x3A) (<= #x3C n #x7E)))

;; What a URL's path escapes beyond C0 controls and past ~, WHATWG URL's
;; path percent-encode set, and \, which an http URL reads as /; and the
;; forbidden domain code points of the same standard, none of which a host
;; holds.
(define path-escaped (map char->integer (string->list " \"#<>?^`{}\\")))
(define host-forbidden (map char->integer (string->list " #%/:<>?@[\\]^|")))

;; path-outcome, domain-outcome : Nat String -> Any — what writing a path,
;; or a domain, holding the character C answers, by those sets.
(define (path-outcome c p)
  (cond ((not (av-octet? c)) (refused 'cookie-path path-chars p))
        ((memv c path-escaped) (refused 'cookie-path path-url p))
        (else (one (string-append "a=1; Path=" p)))))
(define (domain-outcome c d)
  (cond ((not (av-octet? c)) (refused 'cookie-domain domain-chars d))
        ((memv c host-forbidden) (refused 'cookie-domain domain-host d))
        (else (one (string-append "a=1; Domain=" d)))))

(define base (make-res 200 '(("content-type" . "text/plain")) "hi"))

(define epoch "Expires=Thu, 01 Jan 1970 00:00:00 GMT")

;; The messages.
(define not-a-request "not a request")
(define not-a-response "not a response")
(define name-string "a cookie name is a string")
(define name-token "a cookie name is a token: letters, digits and !#$%&'*+-.^_`|~, at least one")
(define value-string "a cookie value is a string")
(define value-octets
  (string-append "a cookie value is cookie-octets, bare or between two quotes: encode a space,"
                 " a quote, a comma, a semicolon, a backslash, a control or anything past"
                 " ASCII first"))
(define too-big "a cookie's name and value are at most 4096 bytes together: a browser ignores a longer one")
(define path-string "a path is a string")
(define path-chars "a path holds ASCII from a space to ~ alone, with no ;")
(define path-long "a path is at most 1024 bytes: a browser ignores a longer one")
(define path-slash "a path starts with /: a browser ignores any other")
(define path-url
  (string-append "a path holds no space, \", #, <, >, ?, ^, `, {, } or \\:"
                 " a URL's path never does, so a browser would never send the cookie"))
(define domain-string "a domain is a string")
(define domain-chars "a domain holds ASCII from a space to ~ alone, with no ;")
(define domain-long "a domain is at most 1024 bytes: a browser ignores a longer one")
(define domain-empty "a domain is not empty, nor . alone: a browser reads either as no Domain")
(define domain-host
  (string-append "a domain holds no space, #, %, /, :, <, >, ?, @, [, \\, ], ^ or |:"
                 " no host does, so a browser ignores the cookie"))
(define max-age-count "a max-age is a whole number of seconds, at least 1: res-expire-cookie expires a cookie")
(define max-age-digits "a max-age is at most 1024 digits: a browser ignores a longer one")
(define same-site-kind "a same-site is strict, lax or none")
(define none-secure "SameSite=None needs cookie-secure: a browser ignores the cookie without it")
(define secure-prefix "a __Secure- name needs cookie-secure: a browser ignores the cookie without it")
(define host-prefix
  (string-append "a __Host- name needs cookie-secure and (cookie-path \"/\"), and no cookie-domain:"
                 " a browser ignores the cookie otherwise"))
(define once "each option once")
(define bare "an option's constructor, given bare: call it")
(define no-option "an option is what a cookie- constructor makes")
(define no-max-age "res-expire-cookie takes no max-age: its date in the past expires the cookie")

;;; ------------------------------------------------------------------------
;;; req-cookies and req-cookie

;; cookie-req : String ... -> Req — a test request with a cookie field each.
(define (cookie-req . fields)
  (make-test-req 'GET "/" (map (lambda (f) (cons "cookie" f)) fields)))

(test-equal "the RFC's §3.1 Cookie fields read as a browser sends them, names in their case"
  '((("SID" . "31d4d96e407aad42"))
    (("SID" . "31d4d96e407aad42") ("lang" . "en-US"))
    (("SID" . "31d4d96e407aad42") ("sid" . "31d4d96e407aad42")))
  (list (req-cookies (cookie-req "SID=31d4d96e407aad42"))
        (req-cookies (cookie-req "SID=31d4d96e407aad42; lang=en-US"))
        (req-cookies (cookie-req "SID=31d4d96e407aad42; sid=31d4d96e407aad42"))))

(test-equal "req-cookies reads every cookie field, in order, its name in any case, and no other field"
  '(("a" . "1") ("b" . "2") ("c" . "3") ("d" . "4"))
  (req-cookies (make-test-req 'GET "/" '(("cookie" . "a=1; b=2") ("x-other" . "z=9") ("Cookie" . "c=3")
                                         ("set-cookie" . "y=8") ("COOKIE" . "d=4")))))

(test-equal "with no cookie field, req-cookies answers '() and req-cookie #f; with an empty one, '() and #f"
  '(() #f () #f)
  (list (req-cookies (make-test-req 'GET "/" '(("x-other" . "a=1"))))
        (req-cookie (make-test-req 'GET "/" '(("x-other" . "a=1"))) "a")
        (req-cookies (cookie-req ""))
        (req-cookie (cookie-req "") "")))

(test-equal "empty pieces, a piece with no =, and an empty name are skipped"
  '(("a" . "1") ("c" . "3") ("d" . ""))
  (req-cookies (cookie-req ";; ;a=1;;b; =2;\t; c=3;==x; = ;d=;b c;")))

(test-equal "a value is all that follows the first =, = and all, and may be empty"
  '(("a" . "=b=c") ("t" . "x=") ("e" . "") ("f" . "=")
    ("g" . "h"))
  (req-cookies (cookie-req "a==b=c; t=x=; e=; f==" "g=h")))

(test-equal "a value's quotes are kept, as RFC 6265bis §4.1.1 has them, a lone quote too"
  '(("q" . "\"abc\"") ("r" . "\"\"") ("s" . "\"") ("t" . "a\"b") ("u" . "\" x \""))
  (req-cookies (cookie-req "q=\"abc\"; r=\"\"; s=\"; t=a\"b; u=\" x \"")))

(test-equal "a space and a tab inside a name or a value are kept"
  '(("a b" . "c\td") ("x" . "1"))
  (req-cookies (cookie-req "a b=c\td; x=1")))

;; around : Nat -> Cookies — the piece C a C = C b C, read between two others.
(define (around c)
  (let ((s (char-string c)))
    (req-cookies (cookie-req (string-append "x=1;" s "a" s "=" s "b" s ";y=2")))))

(test-equal "every character but ; and =, at each end of a name and a value: a space and a tab alone are trimmed"
  (map (lambda (c)
         (let ((s (char-string c)))
           (list (cons "x" "1")
                 (if (memv c '(32 9))
                     (cons "a" "b")
                     (cons (string-append s "a" s) (string-append s "b" s)))
                 (cons "y" "2"))))
       (remp (lambda (c) (memv c '(59 61))) every-char))
  (map around (remp (lambda (c) (memv c '(59 61))) every-char)))

(test-equal "a Latin-1 byte reads as the character the server reads it as"
  '(("b" . "caf\xE9;") ("c" . "\xFF;"))
  (req-cookies (cookie-req "b=caf\xE9;; c=\xFF;")))

(test-equal "characters aren't checked: a comma, a backslash, a control and a character past 255 read as given"
  (list (cons "a" "x,y\\z") (cons "b" (char-string 1)) (cons (char-string #x100) "\x10FFFF;"))
  (req-cookies (cookie-req (string-append "a=x,y\\z; b=" (char-string 1) "; " (char-string #x100)
                                          "=\x10FFFF;"))))

(test-equal "req-cookie answers the first of a name, matched exactly, in its case, across fields"
  '("1" "2" #f "4" #f #f "")
  (let ((r (cookie-req "SID=1; sid=2; SID=3" "x=4; e=")))
    (map-in-order (lambda (name) (req-cookie r name)) '("SID" "sid" "Sid" "x" "SI" "SID " "e"))))

(test-equal "req-cookies and req-cookie refuse what is no request, and req-cookie a name that is no string"
  (list (refused 'req-cookies not-a-request 'not-a-request)
        (refused 'req-cookie not-a-request 'not-a-request)
        (refused 'req-cookie not-a-request 'not-a-request)
        (refused 'req-cookie name-string 'sid))
  (list (raised (lambda () (req-cookies 'not-a-request)))
        (raised (lambda () (req-cookie 'not-a-request "sid")))
        (raised (lambda () (req-cookie 'not-a-request 'sid)))
        (raised (lambda () (req-cookie (cookie-req "sid=1") 'sid)))))

;;; ------------------------------------------------------------------------
;;; res-add-cookie and res-expire-cookie: whole fields

(test-equal "the RFC's §3.1 Set-Cookie fields, written as the RFC writes them, its removal dated at the epoch"
  (list (one "SID=31d4d96e407aad42")
        (one "SID=31d4d96e407aad42; Path=/; Domain=site.example")
        (one "SID=31d4d96e407aad42; Path=/; Secure; HttpOnly")
        (one "lang=en-US; Path=/; Domain=site.example")
        (one (string-append "lang=; " epoch)))
  (list (written (lambda () (res-add-cookie base "SID" "31d4d96e407aad42")))
        (written (lambda () (res-add-cookie base "SID" "31d4d96e407aad42"
                                            (cookie-path "/") (cookie-domain "site.example"))))
        (written (lambda () (res-add-cookie base "SID" "31d4d96e407aad42"
                                            (cookie-path "/") (cookie-secure) (cookie-http-only))))
        (written (lambda () (res-add-cookie base "lang" "en-US"
                                            (cookie-path "/") (cookie-domain "site.example"))))
        (written (lambda () (res-expire-cookie base "lang")))))

(test-equal "the design's example"
  (one "__Host-theme=dark; Path=/; Max-Age=2592000; Secure; HttpOnly; SameSite=Lax")
  (written (lambda ()
             (res-add-cookie base "__Host-theme" "dark"
                             (cookie-path "/") (cookie-secure) (cookie-http-only)
                             (cookie-same-site 'lax) (cookie-max-age 2592000)))))

(test-equal "each attribute alone, and each same-site"
  (list (one "a=1; Path=/p") (one "a=1; Domain=site.example") (one "a=1; Max-Age=60")
        (one "a=1; Secure") (one "a=1; HttpOnly") (one "a=1; SameSite=Strict")
        (one "a=1; SameSite=Lax") (one "a=1; Secure; SameSite=None"))
  (map-in-order (lambda (options) (written (lambda () (apply res-add-cookie base "a" "1" options))))
                (list (list (cookie-path "/p")) (list (cookie-domain "site.example"))
                      (list (cookie-max-age 60)) (list (cookie-secure)) (list (cookie-http-only))
                      (list (cookie-same-site 'strict)) (list (cookie-same-site 'lax))
                      (list (cookie-same-site 'none) (cookie-secure)))))

(test-equal "res-add-cookie writes its attributes in one order, whatever the order of the six options: all 720"
  (list (one "a=1; Path=/p; Domain=site.example; Max-Age=60; Secure; HttpOnly; SameSite=Strict"))
  (let ((options (list (cookie-path "/p") (cookie-domain "site.example") (cookie-max-age 60)
                       (cookie-secure) (cookie-http-only) (cookie-same-site 'strict))))
    (distinct (map (lambda (order) (written (lambda () (apply res-add-cookie base "a" "1" order))))
                   (permutations options)))))

(test-equal "res-expire-cookie writes no value and the epoch in Max-Age's place, whatever the order of its five options"
  (list (one (string-append "a=; Path=/p; Domain=site.example; " epoch "; Secure; HttpOnly; SameSite=None")))
  (let ((options (list (cookie-path "/p") (cookie-domain "site.example") (cookie-secure)
                       (cookie-http-only) (cookie-same-site 'none))))
    (distinct (map (lambda (order) (written (lambda () (apply res-expire-cookie base "a" order))))
                   (permutations options)))))

(test-equal "res-expire-cookie with a path and a domain alone, as a browser must match them to remove a cookie"
  (list (one (string-append "a=; Path=/p; Domain=site.example; " epoch))
        (one (string-append "a=; Path=/; " epoch)))
  (list (written (lambda () (res-expire-cookie base "a" (cookie-domain "site.example") (cookie-path "/p"))))
        (written (lambda () (res-expire-cookie base "a" (cookie-path "/"))))))

(test-equal "res-add-cookie appends one field, keeping the response's status, body and fields, set-cookie among them"
  (list 201 "hi"
        `(("Set-Cookie" . "a=0") ("content-type" . "text/plain") ("set-cookie" . "a=1")
          ("set-cookie" . "b=2; Secure") ("set-cookie" . ,(string-append "a=; " epoch))))
  (let* ((r0 (make-res 201 '(("Set-Cookie" . "a=0") ("content-type" . "text/plain")) "hi"))
         (r1 (res-add-cookie r0 "a" "1"))
         (r2 (res-add-cookie r1 "b" "2" (cookie-secure)))
         (r3 (res-expire-cookie r2 "a")))
    (list (res-status r3) (res-body r3) (res-headers r3))))

(test-equal "an empty value, and a quoted one, are written as given"
  (list (one "a=") (one "a=\"\"") (one "a=\"x=y\"") (one "a=x=y"))
  (map-in-order (lambda (v) (written (lambda () (res-add-cookie base "a" v))))
                '("" "\"\"" "\"x=y\"" "x=y")))

;;; ------------------------------------------------------------------------
;;; The allowlists, against their whole complements

(test-equal "each byte, and six characters past 255, alone in a value, is taken exactly when it is a cookie-octet"
  (map (lambda (c)
         (let ((v (char-string c)))
           (if (cookie-octet? c) (one (string-append "a=" v)) (refused 'res-add-cookie value-octets v))))
       every-char)
  (map-in-order (lambda (c) (written (lambda () (res-add-cookie base "a" (char-string c))))) every-char))

(test-equal "each of them between two quotes, too"
  (map (lambda (c)
         (let ((v (string-append "\"" (char-string c) "\"")))
           (if (cookie-octet? c) (one (string-append "a=" v)) (refused 'res-add-cookie value-octets v))))
       every-char)
  (map-in-order (lambda (c)
                  (written (lambda () (res-add-cookie base "a" (string-append "\"" (char-string c) "\"")))))
                every-char))

;; at-every-position : Nat String -> (Listof String)
;; TEXT with the character C put in at each position, first to last.
(define (at-every-position c text)
  (map (lambda (i) (string-append (substring text 0 i) (char-string c)
                                  (substring text i (string-length text))))
       (iota (+ (string-length text) 1))))

(define non-octets (filter (lambda (c) (not (cookie-octet? c))) every-char))

(test-equal "a character that is no cookie-octet is refused at every position of a value, bare or inside quotes"
  (apply append
         (map (lambda (c)
                (map (lambda (v) (refused 'res-add-cookie value-octets v))
                     (append (at-every-position c "xyz")
                             (map (lambda (inner) (string-append "\"" inner "\""))
                                  (at-every-position c "xy")))))
              non-octets))
  (apply append
         (map-in-order (lambda (c)
                         (map-in-order (lambda (v) (written (lambda () (res-add-cookie base "a" v))))
                                       (append (at-every-position c "xyz")
                                               (map (lambda (inner) (string-append "\"" inner "\""))
                                                    (at-every-position c "xy")))))
                       non-octets)))

(test-equal "quotes: a pair around cookie-octets is taken; one alone, one at one end, or one inside, is refused"
  (append (map (lambda (v) (one (string-append "a=" v))) '("\"\"" "\"x\"" "\"xyz\""))
          (map (lambda (v) (refused 'res-add-cookie value-octets v))
               '("\"" "\"x" "x\"" "\"\"\"" "\"x\"y\"" "x\"\"" "\"\"x" "x\"y")))
  (map-in-order (lambda (v) (written (lambda () (res-add-cookie base "a" v))))
                '("\"\"" "\"x\"" "\"xyz\"" "\"" "\"x" "x\"" "\"\"\"" "\"x\"y\"" "x\"\"" "\"\"x" "x\"y")))

(test-equal "each byte, and six characters past 255, alone as a name, is taken exactly when it is a token's"
  (map (lambda (c)
         (let ((n (char-string c)))
           (if (tchar? c) (one (string-append n "=1")) (refused 'res-add-cookie name-token n))))
       every-char)
  (map-in-order (lambda (c) (written (lambda () (res-add-cookie base (char-string c) "1")))) every-char))

(test-equal "a character no token holds is refused at every position of a name, by res-expire-cookie too, and an empty name"
  (append (apply append
                 (map (lambda (c) (map (lambda (n) (refused 'res-add-cookie name-token n))
                                       (at-every-position c "id")))
                      (filter (lambda (c) (not (tchar? c))) every-char)))
          (list (refused 'res-add-cookie name-token "")
                (refused 'res-expire-cookie name-token "")
                (refused 'res-expire-cookie name-token "i d")))
  (append (apply append
                 (map-in-order (lambda (c)
                                 (map-in-order (lambda (n) (written (lambda () (res-add-cookie base n "1"))))
                                               (at-every-position c "id")))
                               (filter (lambda (c) (not (tchar? c))) every-char)))
          (list (written (lambda () (res-add-cookie base "" "1")))
                (written (lambda () (res-expire-cookie base "")))
                (written (lambda () (res-expire-cookie base "i d"))))))

(test-equal "each byte, and six characters past 255, in a path and in a domain, is taken exactly when it is an av-octet that a URL's path, or a host, holds"
  (map (lambda (c)
         (list (path-outcome c (string-append "/" (char-string c) "p"))
               (domain-outcome c (string-append "x" (char-string c) "y"))))
       every-char)
  (map-in-order (lambda (c)
                  (let* ((p (string-append "/" (char-string c) "p"))
                         (d (string-append "x" (char-string c) "y"))
                         (by-path (written (lambda () (res-add-cookie base "a" "1" (cookie-path p))))))
                    (list by-path (written (lambda () (res-add-cookie base "a" "1" (cookie-domain d)))))))
                every-char))

(define path-refused (filter (lambda (c) (or (not (av-octet? c)) (memv c path-escaped))) every-char))
(define domain-refused (filter (lambda (c) (or (not (av-octet? c)) (memv c host-forbidden))) every-char))

(test-equal "a character a path or a domain can't hold is refused at every position of one, for its reason"
  (append (apply append
                 (map (lambda (c)
                        (map (lambda (tail) (path-outcome c (string-append "/" tail))) (at-every-position c "ab")))
                      path-refused))
          (apply append
                 (map (lambda (c) (map (lambda (d) (domain-outcome c d)) (at-every-position c "ab")))
                      domain-refused)))
  (append (apply append
                 (map-in-order (lambda (c)
                                 (map-in-order (lambda (tail)
                                                 (written (lambda ()
                                                            (res-add-cookie base "a" "1" (cookie-path (string-append "/" tail))))))
                                               (at-every-position c "ab")))
                               path-refused))
          (apply append
                 (map-in-order (lambda (c)
                                 (map-in-order (lambda (d) (written (lambda () (res-add-cookie base "a" "1" (cookie-domain d)))))
                                               (at-every-position c "ab")))
                               domain-refused))))

;;; ------------------------------------------------------------------------
;;; The limits, from both sides

(define (text-of n c) (make-string n c))

(test-equal "a name and value of 4096 bytes together are taken, and of 4097 refused, whichever holds them"
  (list (one (string-append "n=" (text-of 4095 #\v)))
        (refused 'res-add-cookie too-big 4097)
        (one (string-append (text-of 4095 #\n) "=v"))
        (refused 'res-add-cookie too-big 4097)
        (one (string-append (text-of 4096 #\n) "="))
        (refused 'res-add-cookie too-big 4097)
        (one (string-append (text-of 2048 #\n) "=" (text-of 2048 #\v)))
        (refused 'res-add-cookie too-big 4097))
  (list (written (lambda () (res-add-cookie base "n" (text-of 4095 #\v))))
        (written (lambda () (res-add-cookie base "n" (text-of 4096 #\v))))
        (written (lambda () (res-add-cookie base (text-of 4095 #\n) "v")))
        (written (lambda () (res-add-cookie base (text-of 4096 #\n) "v")))
        (written (lambda () (res-add-cookie base (text-of 4096 #\n) "")))
        (written (lambda () (res-add-cookie base (text-of 4097 #\n) "")))
        (written (lambda () (res-add-cookie base (text-of 2048 #\n) (text-of 2048 #\v))))
        (written (lambda () (res-add-cookie base (text-of 2048 #\n) (text-of 2049 #\v))))))

(test-equal "res-expire-cookie takes a name of 4096 bytes and refuses one of 4097"
  (list (one (string-append (text-of 4096 #\n) "=; " epoch))
        (refused 'res-expire-cookie too-big 4097))
  (list (written (lambda () (res-expire-cookie base (text-of 4096 #\n))))
        (written (lambda () (res-expire-cookie base (text-of 4097 #\n))))))

(test-equal "a path and a domain of 1024 bytes are taken, and of 1025 refused, a domain's leading dot counted"
  (let ((p1024 (string-append "/" (text-of 1023 #\p)))
        (p1025 (string-append "/" (text-of 1024 #\p))))
    (list (one (string-append "a=1; Path=" p1024))
          (refused 'cookie-path path-long p1025)
          (one (string-append "a=1; Domain=" (text-of 1024 #\d)))
          (refused 'cookie-domain domain-long (text-of 1025 #\d))
          (one (string-append "a=1; Domain=." (text-of 1023 #\d)))
          (refused 'cookie-domain domain-long (string-append "." (text-of 1024 #\d)))))
  (let ((p1024 (string-append "/" (text-of 1023 #\p)))
        (p1025 (string-append "/" (text-of 1024 #\p))))
    (list (written (lambda () (res-add-cookie base "a" "1" (cookie-path p1024))))
          (raised (lambda () (cookie-path p1025)))
          (written (lambda () (res-add-cookie base "a" "1" (cookie-domain (text-of 1024 #\d)))))
          (raised (lambda () (cookie-domain (text-of 1025 #\d))))
          (written (lambda () (res-add-cookie base "a" "1" (cookie-domain (string-append "." (text-of 1023 #\d))))))
          (raised (lambda () (cookie-domain (string-append "." (text-of 1024 #\d))))))))

(test-equal "a path starts with /, and a domain is neither empty nor . alone"
  (list (refused 'cookie-path path-slash "")
        (refused 'cookie-path path-slash "p")
        (refused 'cookie-path path-slash "p/")
        (refused 'cookie-path path-slash "~/p")
        (refused 'cookie-domain domain-empty "")
        (refused 'cookie-domain domain-empty ".")
        (one "a=1; Path=/")
        (one "a=1; Path=/p/q/")
        (one "a=1; Domain=.site.example"))
  (list (raised (lambda () (cookie-path "")))
        (raised (lambda () (cookie-path "p")))
        (raised (lambda () (cookie-path "p/")))
        (raised (lambda () (cookie-path "~/p")))
        (raised (lambda () (cookie-domain "")))
        (raised (lambda () (cookie-domain ".")))
        (written (lambda () (res-add-cookie base "a" "1" (cookie-path "/"))))
        (written (lambda () (res-add-cookie base "a" "1" (cookie-path "/p/q/"))))
        (written (lambda () (res-add-cookie base "a" "1" (cookie-domain ".site.example"))))))

(define never-sent '("/x y" "/x " "/a?b" "/a#b" "/a\\b" "/{id}"))
(define no-host '("localhost:8080" "https://example.com" "example.com/" "user@example.com" "a b" " site.example"
                  "[::1]" "100%.example"))

(test-equal "a path a URL's path never holds, and a domain no host holds, are refused: a host, an IP address and % in a path are taken"
  (append (map (lambda (p) (refused 'cookie-path path-url p)) never-sent)
          (map (lambda (d) (refused 'cookie-domain domain-host d)) no-host)
          (list (one "a=1; Path=/a%20b|c!") (one "a=1; Domain=_dmarc.Example.com") (one "a=1; Domain=127.0.0.1")))
  (append (map-in-order (lambda (p) (raised (lambda () (cookie-path p)))) never-sent)
          (map-in-order (lambda (d) (raised (lambda () (cookie-domain d)))) no-host)
          (list (written (lambda () (res-add-cookie base "a" "1" (cookie-path "/a%20b|c!"))))
                (written (lambda () (res-add-cookie base "a" "1" (cookie-domain "_dmarc.Example.com"))))
                (written (lambda () (res-add-cookie base "a" "1" (cookie-domain "127.0.0.1")))))))

(test-equal "a max-age of 1 is taken, and 0 refused; a large one, a bignum too, is sent as given, to 1024 digits, and 1025 refused"
  (list (one "a=1; Max-Age=1")
        (refused 'cookie-max-age max-age-count 0)
        (one "a=1; Max-Age=34560001")
        (one "a=1; Max-Age=1267650600228229401496703205376")
        (one (string-append "a=1; Max-Age=" (text-of 1024 #\9)))
        (refused 'cookie-max-age max-age-digits (expt 10 1024)))
  (list (written (lambda () (res-add-cookie base "a" "1" (cookie-max-age 1))))
        (raised (lambda () (cookie-max-age 0)))
        (written (lambda () (res-add-cookie base "a" "1" (cookie-max-age 34560001))))
        (written (lambda () (res-add-cookie base "a" "1" (cookie-max-age (expt 2 100)))))
        (written (lambda () (res-add-cookie base "a" "1" (cookie-max-age (- (expt 10 1024) 1)))))
        (raised (lambda () (cookie-max-age (expt 10 1024))))))

(test-equal "a max-age that is no whole number of seconds is refused"
  (map (lambda (x) (refused 'cookie-max-age max-age-count x))
       (list -1 (- (expt 2 100)) 1.5 1. 1/2 3/2 "1" #f))
  (map-in-order (lambda (x) (raised (lambda () (cookie-max-age x))))
                (list -1 (- (expt 2 100)) 1.5 1. 1/2 3/2 "1" #f)))

;;; ------------------------------------------------------------------------
;;; What a browser ignores

(test-equal "a same-site is strict, lax or none, as those symbols"
  (map (lambda (x) (refused 'cookie-same-site same-site-kind x))
       (list 'Strict 'LAX 'None "lax" 'other #f))
  (map-in-order (lambda (x) (raised (lambda () (cookie-same-site x))))
                (list 'Strict 'LAX 'None "lax" 'other #f)))

(test-equal "SameSite=None without Secure is refused, by res-expire-cookie too; Strict and Lax need no Secure"
  (list (refused 'res-add-cookie none-secure "a")
        (refused 'res-expire-cookie none-secure "a")
        (one "a=1; Secure; SameSite=None")
        (one (string-append "a=; " epoch "; Secure; SameSite=None"))
        (one "a=1; SameSite=Strict")
        (one "a=1; SameSite=Lax"))
  (list (written (lambda () (res-add-cookie base "a" "1" (cookie-same-site 'none))))
        (written (lambda () (res-expire-cookie base "a" (cookie-same-site 'none))))
        (written (lambda () (res-add-cookie base "a" "1" (cookie-same-site 'none) (cookie-secure))))
        (written (lambda () (res-expire-cookie base "a" (cookie-same-site 'none) (cookie-secure))))
        (written (lambda () (res-add-cookie base "a" "1" (cookie-same-site 'strict))))
        (written (lambda () (res-add-cookie base "a" "1" (cookie-same-site 'lax))))))

;; The RFC's §5.4 examples: each name, value and options, written as
;; res-add-cookie takes them.
(define (sid prefix . options) (lambda () (apply res-add-cookie base (string-append prefix "SID") "12345" options)))

(test-equal "the RFC's §5.4 fields a browser rejects are refused, a prefix matched in any case"
  (list (refused 'res-add-cookie secure-prefix "__Secure-SID")
        (refused 'res-add-cookie secure-prefix "__secure-SID")
        (refused 'res-add-cookie secure-prefix "__SECURE-SID")
        (refused 'res-add-cookie host-prefix "__Host-SID")
        (refused 'res-add-cookie host-prefix "__host-SID")
        (refused 'res-add-cookie host-prefix "__host-SID")
        (refused 'res-add-cookie host-prefix "__HOST-SID")
        (refused 'res-add-cookie host-prefix "__Host-SID")
        (refused 'res-add-cookie host-prefix "__host-SID")
        (refused 'res-add-cookie host-prefix "__HOST-SID"))
  (map-in-order
   written
   (list (sid "__Secure-" (cookie-domain "site.example"))
         (sid "__secure-" (cookie-domain "site.example"))
         (sid "__SECURE-" (cookie-domain "site.example"))
         (sid "__Host-")
         (sid "__host-" (cookie-secure))
         (sid "__host-" (cookie-domain "site.example"))
         (sid "__HOST-" (cookie-domain "site.example") (cookie-path "/"))
         (sid "__Host-" (cookie-secure) (cookie-domain "site.example") (cookie-path "/"))
         (sid "__host-" (cookie-secure) (cookie-domain "site.example") (cookie-path "/"))
         (sid "__HOST-" (cookie-secure) (cookie-domain "site.example") (cookie-path "/")))))

(test-equal "the RFC's §5.4 fields a browser accepts are taken"
  (list (one "__Secure-SID=12345; Domain=site.example; Secure")
        (one "__secure-SID=12345; Domain=site.example; Secure")
        (one "__SECURE-SID=12345; Domain=site.example; Secure")
        (one "__Host-SID=12345; Path=/; Secure")
        (one "__host-SID=12345; Path=/; Secure")
        (one "__HOST-SID=12345; Path=/; Secure"))
  (map-in-order
   written
   (list (sid "__Secure-" (cookie-domain "site.example") (cookie-secure))
         (sid "__secure-" (cookie-domain "site.example") (cookie-secure))
         (sid "__SECURE-" (cookie-domain "site.example") (cookie-secure))
         (sid "__Host-" (cookie-secure) (cookie-path "/"))
         (sid "__host-" (cookie-secure) (cookie-path "/"))
         (sid "__HOST-" (cookie-secure) (cookie-path "/")))))

(test-equal "a __Host- name needs each of Secure and Path=/, its path / alone, and no domain; a mixed case is a prefix"
  (list (refused 'res-add-cookie host-prefix "__Host-a")
        (refused 'res-add-cookie host-prefix "__Host-a")
        (refused 'res-add-cookie host-prefix "__Host-a")
        (refused 'res-add-cookie host-prefix "__Host-")
        (refused 'res-add-cookie host-prefix "__hOsT-a")
        (refused 'res-add-cookie secure-prefix "__SeCuRe-a")
        (refused 'res-add-cookie secure-prefix "__Secure-")
        (one "__Secure-=1; Secure"))
  (list (written (lambda () (res-add-cookie base "__Host-a" "1" (cookie-path "/"))))
        (written (lambda () (res-add-cookie base "__Host-a" "1" (cookie-secure))))
        (written (lambda () (res-add-cookie base "__Host-a" "1" (cookie-secure) (cookie-path "/a"))))
        (written (lambda () (res-add-cookie base "__Host-" "1" (cookie-path "/"))))
        (written (lambda () (res-add-cookie base "__hOsT-a" "1" (cookie-path "/"))))
        (written (lambda () (res-add-cookie base "__SeCuRe-a" "1")))
        (written (lambda () (res-add-cookie base "__Secure-" "1")))
        (written (lambda () (res-add-cookie base "__Secure-" "1" (cookie-secure))))))

(test-equal "a name that only looks like a prefix needs nothing: no dash, one underscore, the prefix later, or cut short"
  (map one '("__Secure=1" "_Secure-a=1" "x__Secure-a=1" "__Host=1" "__Hos=1" "_=1" "__Host_a=1" "__Secure_a=1"))
  (map-in-order (lambda (n) (written (lambda () (res-add-cookie base n "1"))))
                '("__Secure" "_Secure-a" "x__Secure-a" "__Host" "__Hos" "_" "__Host_a" "__Secure_a")))

(test-equal "res-expire-cookie holds the prefixes too"
  (list (refused 'res-expire-cookie secure-prefix "__Secure-a")
        (refused 'res-expire-cookie host-prefix "__Host-a")
        (refused 'res-expire-cookie host-prefix "__Host-a")
        (one (string-append "__Secure-a=; " epoch "; Secure"))
        (one (string-append "__Host-a=; Path=/; " epoch "; Secure")))
  (list (written (lambda () (res-expire-cookie base "__Secure-a")))
        (written (lambda () (res-expire-cookie base "__Host-a" (cookie-path "/"))))
        (written (lambda () (res-expire-cookie base "__Host-a" (cookie-path "/") (cookie-secure)
                                               (cookie-domain "site.example"))))
        (written (lambda () (res-expire-cookie base "__Secure-a" (cookie-secure))))
        (written (lambda () (res-expire-cookie base "__Host-a" (cookie-secure) (cookie-path "/"))))))

;;; ------------------------------------------------------------------------
;;; Options, and what is no cookie

(define constructors
  (list (cons 'cookie-path (lambda () (cookie-path "/")))
        (cons 'cookie-domain (lambda () (cookie-domain "site.example")))
        (cons 'cookie-max-age (lambda () (cookie-max-age 60)))
        (cons 'cookie-secure cookie-secure)
        (cons 'cookie-http-only cookie-http-only)
        (cons 'cookie-same-site (lambda () (cookie-same-site 'lax)))))

(test-equal "each option given twice is refused, by res-add-cookie and res-expire-cookie"
  (append (map (lambda (c) (refused 'res-add-cookie once (car c))) constructors)
          (map (lambda (c) (refused 'res-expire-cookie once (car c)))
               (remp (lambda (c) (eq? (car c) 'cookie-max-age)) constructors))
          (list (refused 'res-add-cookie once 'cookie-same-site)))
  (append (map-in-order (lambda (c) (written (lambda () (res-add-cookie base "a" "1" ((cdr c)) ((cdr c))))))
                        constructors)
          (map-in-order (lambda (c) (written (lambda () (res-expire-cookie base "a" ((cdr c)) ((cdr c))))))
                        (remp (lambda (c) (eq? (car c) 'cookie-max-age)) constructors))
          (list (written (lambda () (res-add-cookie base "a" "1" (cookie-same-site 'lax) (cookie-path "/")
                                                    (cookie-same-site 'strict)))))))

(test-equal "each constructor given bare is refused, by both, under its name"
  (append (map (lambda (name) (refused 'res-add-cookie bare name)) (map car constructors))
          (map (lambda (name) (refused 'res-expire-cookie bare name)) (map car constructors)))
  (let ((bare-ones (list cookie-path cookie-domain cookie-max-age cookie-secure cookie-http-only cookie-same-site)))
    (append (map-in-order (lambda (k) (written (lambda () (res-add-cookie base "a" "1" (cookie-secure) k))))
                          bare-ones)
            (map-in-order (lambda (k) (written (lambda () (res-expire-cookie base "a" k))))
                          bare-ones))))

(test-equal "what no constructor made is no option"
  (append (map (lambda (x) (refused 'res-add-cookie no-option x)) (list "Secure" 'cookie-secure #f '()))
          (list (refused 'res-expire-cookie no-option "Path=/")))
  (append (map-in-order (lambda (x) (written (lambda () (res-add-cookie base "a" "1" x))))
                        (list "Secure" 'cookie-secure #f '()))
          (list (written (lambda () (res-expire-cookie base "a" "Path=/"))))))

(test-equal "res-expire-cookie refuses a max-age: its date in the past expires the cookie"
  (list (refused 'res-expire-cookie no-max-age 'cookie-max-age)
        (refused 'res-expire-cookie no-max-age 'cookie-max-age))
  (list (written (lambda () (res-expire-cookie base "a" (cookie-max-age 60))))
        (written (lambda () (res-expire-cookie base "a" (cookie-path "/") (cookie-max-age 1) (cookie-secure))))))

(test-equal "what is no response, a name or value that is no string, a path or domain that is no string"
  (list (refused 'res-add-cookie not-a-response 'not-a-response)
        (refused 'res-expire-cookie not-a-response 'not-a-response)
        (refused 'res-add-cookie not-a-response 'not-a-response)
        (refused 'res-add-cookie name-string 'a)
        (refused 'res-add-cookie name-string #f)
        (refused 'res-expire-cookie name-string 'a)
        (refused 'res-add-cookie value-string 1)
        (refused 'res-add-cookie value-string #f)
        (refused 'cookie-path path-string 'p)
        (refused 'cookie-domain domain-string #f))
  (list (written (lambda () (res-add-cookie 'not-a-response "a" "1")))
        (written (lambda () (res-expire-cookie 'not-a-response "a")))
        (written (lambda () (res-add-cookie 'not-a-response 'a 1)))
        (written (lambda () (res-add-cookie base 'a "1")))
        (written (lambda () (res-add-cookie base #f "1")))
        (written (lambda () (res-expire-cookie base 'a)))
        (written (lambda () (res-add-cookie base "a" 1)))
        (written (lambda () (res-add-cookie base "a" #f)))
        (raised (lambda () (cookie-path 'p)))
        (raised (lambda () (cookie-domain #f)))))

(test-equal "the checks go in one order: the response, the name, the value, the size, the options, then what a browser drops"
  (list (refused 'res-add-cookie name-token "a b")
        (refused 'res-add-cookie value-octets " ")
        (refused 'res-add-cookie value-octets (string-append " " (text-of 4096 #\v)))
        (refused 'res-add-cookie too-big 4097)
        (refused 'res-add-cookie bare 'cookie-secure)
        (refused 'res-add-cookie no-option "junk")
        (refused 'res-add-cookie none-secure "__Secure-a")
        (refused 'res-expire-cookie not-a-response 'not-a-response)
        (refused 'res-expire-cookie too-big 4097)
        (refused 'res-expire-cookie once 'cookie-max-age))
  (list (written (lambda () (res-add-cookie base "a b" " " cookie-secure)))
        (written (lambda () (res-add-cookie base "a" " " cookie-secure)))
        (written (lambda () (res-add-cookie base "a" (string-append " " (text-of 4096 #\v)))))
        (written (lambda () (res-add-cookie base "a" (text-of 4096 #\v) cookie-secure)))
        (written (lambda () (res-add-cookie base "__Host-a" "1" cookie-secure)))
        (written (lambda () (res-add-cookie base "a" "1" (cookie-secure) (cookie-secure) "junk")))
        (written (lambda () (res-add-cookie base "__Secure-a" "1" (cookie-same-site 'none))))
        (written (lambda () (res-expire-cookie 'not-a-response "a b")))
        (written (lambda () (res-expire-cookie base (text-of 4097 #\n) cookie-secure)))
        (written (lambda () (res-expire-cookie base "a" (cookie-max-age 1) (cookie-max-age 1))))))

(test-equal "a path's checks go in one order, characters, then length, then /, and a domain's characters before its length"
  (list (refused 'cookie-path path-chars "\x1;")
        (refused 'cookie-path path-url "?")
        (refused 'cookie-path path-long (text-of 1025 #\p))
        (refused 'cookie-path path-chars (text-of 1025 #\;))
        (refused 'cookie-path path-url (text-of 1025 #\?))
        (refused 'cookie-domain domain-chars (text-of 1025 #\;))
        (refused 'cookie-domain domain-host (text-of 1025 #\:)))
  (map-in-order (lambda (thunk) (raised thunk))
                (list (lambda () (cookie-path "\x1;"))
                      (lambda () (cookie-path "?"))
                      (lambda () (cookie-path (text-of 1025 #\p)))
                      (lambda () (cookie-path (text-of 1025 #\;)))
                      (lambda () (cookie-path (text-of 1025 #\?)))
                      (lambda () (cookie-domain (text-of 1025 #\;)))
                      (lambda () (cookie-domain (text-of 1025 #\:))))))

(test-equal "a path and a domain are copied: a change to the string after changes nothing"
  (list (one "a=1; Path=/p; Domain=site.example") '("/x" "xite.example"))
  (let* ((p (string-copy "/p"))
         (d (string-copy "site.example"))
         (options (list (cookie-path p) (cookie-domain d))))
    (string-set! p 1 #\x)
    (string-set! d 0 #\x)
    (list (written (lambda () (apply res-add-cookie base "a" "1" options))) (list p d))))

;;; ------------------------------------------------------------------------
;;; Through the server's test host

;; octets : String -> Bytevector — S one byte a character, as a client sends it.
(define (octets s) (u8-list->bytevector (map char->integer (string->list s))))

(define (unset name) #f)

;; exchange : Handler String -> (List (Listof String) (Listof Any))
;; One client sends REQUEST: what it read, as UTF-8, and what the server
;; logged.
(define (exchange app request)
  (let* ((host (make-test-host (circuit->handler app unset) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (octets request))
    (list (map (lambda (r) (utf8->string (test-response-bytes r))) (test-client-responses c))
          (test-host-log host))))

(define (written-text x) (call-with-string-output-port (lambda (p) (write x p))))

(test-equal "through the server: two cookie fields read in order, a Latin-1 byte as its character, the spaces around a field gone"
  (let ((body (written-text '(("a" . "1") ("b" . "caf\xE9;") ("c" . "3") ("d" . "")))))
    (list (list (string-append "HTTP/1.1 200 OK\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\nContent-Length: "
                               (number->string (bytevector-length (string->utf8 body))) "\r\n\r\n" body))
          '()))
  (exchange (lambda (r) (make-res 200 '() (written-text (req-cookies r))))
            "GET / HTTP/1.1\r\nHost: x\r\nCookie: a=1; b=caf\xE9;\r\nX-Other: z=9\r\nCookie: \t c=3; d= \t\r\n\r\n"))

(test-equal "through the server: the fields res-add-cookie and res-expire-cookie write go out in order, as written"
  (list (list (string-append "HTTP/1.1 200 OK\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\n"
                             "set-cookie: __Host-id=abc; Path=/; Secure; HttpOnly; SameSite=Strict\r\n"
                             "set-cookie: lang=en-US; Max-Age=60\r\n"
                             "set-cookie: old=; Path=/a; " epoch "\r\n"
                             "Content-Length: 0\r\n\r\n"))
        '())
  (exchange (lambda (r)
              (res-expire-cookie
               (res-add-cookie (res-add-cookie (make-res 200 '() "") "__Host-id" "abc" (cookie-path "/")
                                               (cookie-secure) (cookie-http-only) (cookie-same-site 'strict))
                               "lang" "en-US" (cookie-max-age 60))
               "old" (cookie-path "/a")))
            "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))

(exit (suite-exit-status runner))
