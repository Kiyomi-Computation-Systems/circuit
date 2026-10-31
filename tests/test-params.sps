#!r6rs
;;; (circuit params): the urlencoded parser and serializer, the query and
;;; form readers, param-value and param-values, and their refusals (the
;;; slice 9 design §5).
;;;
;;; Oracles: the web-platform-tests' urlencoded vectors, from
;;; url/urlencoded-parser.any.js and the URLSearchParams constructor, get,
;;; getAll and stringifier files, and the Encoding standard's UTF-8 decoder
;;; vectors, from encoding/textdecoder-fatal.any.js, -eof and
;;; -byte-order-marks, all at WPT 458d0f3, ported as rows; WHATWG URL's
;;; §1.3 percent-decode and §5.1 and §5.2, and the Encoding standard's
;;; §8.1.1 UTF-8 decoder, for the rest. A JS string WPT hands
;;; URLSearchParams is read as its UTF-8, as the constructor reads it. The
;;; fatal file says only that each sequence is an error; how many U+FFFD
;;; each reads as is §8.1.1's, worked by hand and checked against Python's
;;; decoder, which agreed with one written from §8.1.1 on 200,000 random
;;; cases.
;;;
;;; The rows:
;;;   - parse-params, req-query-params and the form agree on every WPT
;;;     parser vector;
;;;   - the decoder: WPT's malformed sequences, its end-of-queue rows, the
;;;     byte-order mark kept, every bound of a lead byte from both sides;
;;;   - escapes: every byte escaped, in either case; % before every byte;
;;;     malformed escapes at every position of a name and a value; + and
;;;     %2B, a space and %20;
;;;   - params->string: WPT's stringifier rows, and every character from 0
;;;     to 255 and six past it, each kept, a +, or its UTF-8 escaped;
;;;   - param-value and param-values: WPT's get and getAll rows, names
;;;     matched in their case;
;;;   - req-query-params: a query read as its bytes, each character from 0
;;;     to 255 the byte it names, req-with-query seen, a character past 255
;;;     refused. The server answers a target holding a byte past ASCII 400,
;;;     so only a test request or req-with-query holds one;
;;;   - wrap-form-params on test requests: which content types it reads,
;;;     the body left at eof, the cap the handler sees, a body's port made
;;;     outside it, a cap inside it, and its refusals;
;;;   - the cap through the server's test host, (http-server testing), which
;;;     enforces it: a body at the cap read, one past it refused 413 with no
;;;     handler run, declared or chunked; the request's own cap, the
;;;     server's and the middleware's, the smallest winning; a bignum cap;
;;;   - the read waits as the body does: a form that arrives in two pieces
;;;     is read whole, and wrap-timeout outside it answers 504 to a client
;;;     that stalls, the handler never run.
;;;
;;; The ported vectors are the web-platform-tests', under this notice:
;;;
;;;   Copyright © web-platform-tests contributors
;;;
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the
;;;      distribution.
;;;   3. Neither the name of the copyright holder nor the names of its
;;;      contributors may be used to endorse or promote products derived
;;;      from this software without specific prior written permission.
;;;
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
;;;   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
;;;   DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;;;   THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;;;   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
;;;   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (circuit-testing)
        (http-server testing)
        (circuit)
        (circuit http-server)
        (circuit middleware waits)
        (circuit test)
        (circuit params))

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

;; raised-message : (-> Any) -> (U String Symbol)
;; The message of the assertion violation THUNK raised, or no-raise.
(define (raised-message thunk)
  (guard (e ((and (assertion-violation? e) (message-condition? e)) (condition-message e))
            (#t 'other-raise))
    (thunk)
    'no-raise))

;; map-in-order : (a -> b) (Listof a) -> (Listof b)
;; map, calling F on each element in turn: map's order is unspecified.
(define (map-in-order f xs)
  (let loop ((xs xs) (out '()))
    (if (null? xs) (reverse out) (loop (cdr xs) (cons (f (car xs)) out)))))

(define (iota n) (let loop ((i (- n 1)) (out '())) (if (< i 0) out (loop (- i 1) (cons i out)))))

;; latin1 : Bytevector -> String
;; BV one character a byte, as req-query holds a target's bytes.
(define (latin1 bv)
  (let* ((n (bytevector-length bv)) (s (make-string n)))
    (for-each (lambda (i) (string-set! s i (integer->char (bytevector-u8-ref bv i)))) (iota n))
    s))

;; bytes : (U Nat String) ... -> Bytevector
;; Each number a byte and each string its UTF-8, joined.
(define (bytes . parts)
  (call-with-bytevector-output-port
   (lambda (out)
     (for-each (lambda (part)
                 (if (string? part) (put-bytevector out (string->utf8 part)) (put-u8 out part)))
               parts))))

;; hex2 : Nat -> String — a byte as two hex digits, in upper case.
(define (hex2 n)
  (string (string-ref "0123456789ABCDEF" (div n 16)) (string-ref "0123456789ABCDEF" (mod n 16))))

(define (lower-hex2 n)
  (string (string-ref "0123456789abcdef" (div n 16)) (string-ref "0123456789abcdef" (mod n 16))))

(define replacement (string (integer->char #xFFFD)))

;; --- readers ---------------------------------------------------------------------

(define form-type '("content-type" . "application/x-www-form-urlencoded"))

;; rest-of : Req -> (U String Symbol)
;; What is left of R's body, as UTF-8, or eof.
(define (rest-of r)
  (let ((b (get-bytevector-all (req-body r))))
    (if (eof-object? b) 'eof (utf8->string b))))

;; form-seen : (Listof Middleware) Req -> (List Params (U String Symbol) (U Nat #f))
;; What a handler inside MIDDLEWARES sees of REQ: its form params, the rest
;; of its body, and its cap.
(define (form-seen middlewares req)
  ((apply wrap (lambda (r) (list (req-form-params r) (rest-of r) (req-body-cap r))) middlewares)
   req))

;; form-of : Bytevector -> Params — BODY read as a form by wrap-form-params.
(define (form-of body)
  (car (form-seen (list (wrap-form-params 1048576)) (make-test-req 'POST "/form" (list form-type) body))))

;; query-of : Bytevector -> Params — BYTES read as a query, one character a byte.
(define (query-of bv)
  (req-query-params (req-with-query (make-test-req 'GET "/") (latin1 bv))))

;;; ------------------------------------------------------------------------
;;; WPT's urlencoded parser vectors

(define parser-vectors
  '(("test" ("test" . ""))
    ("\xFEFF;test=\xFEFF;" ("\xFEFF;test" . "\xFEFF;"))
    ("%EF%BB%BFtest=%EF%BB%BF" ("\xFEFF;test" . "\xFEFF;"))
    ("%EF%BF%BF=%EF%BF%BF" ("\xFFFF;" . "\xFFFF;"))
    ("%FE%FF" ("\xFFFD;\xFFFD;" . ""))
    ("%FF%FE" ("\xFFFD;\xFFFD;" . ""))
    ("\x2020;&\x2020;=x" ("\x2020;" . "") ("\x2020;" . "x"))
    ("%C2" ("\xFFFD;" . ""))
    ("%C2x" ("\xFFFD;x" . ""))
    ("_charset_=windows-1252&test=%C2x" ("_charset_" . "windows-1252") ("test" . "\xFFFD;x"))
    ("")
    ("a" ("a" . ""))
    ("a=b" ("a" . "b"))
    ("a=" ("a" . ""))
    ("=b" ("" . "b"))
    ("&")
    ("&a" ("a" . ""))
    ("a&" ("a" . ""))
    ("a&a" ("a" . "") ("a" . ""))
    ("a&b&c" ("a" . "") ("b" . "") ("c" . ""))
    ("a=b&c=d" ("a" . "b") ("c" . "d"))
    ("a=b&c=d&" ("a" . "b") ("c" . "d"))
    ("&&&a=b&&&&c=d&" ("a" . "b") ("c" . "d"))
    ("a=a&a=b&a=c" ("a" . "a") ("a" . "b") ("a" . "c"))
    ("a==a" ("a" . "=a"))
    ("a=a+b+c+d" ("a" . "a b c d"))
    ("%=a" ("%" . "a"))
    ("%a=a" ("%a" . "a"))
    ("%a_=a" ("%a_" . "a"))
    ("%61=a" ("a" . "a"))
    ("%61+%4d%4D=" ("a MM" . ""))
    ("id=0&value=%" ("id" . "0") ("value" . "%"))
    ("b=%2sf%2a" ("b" . "%2sf*"))
    ("b=%2%2af%2a" ("b" . "%2*f*"))
    ("b=%%2a" ("b" . "%*"))))

(test-equal "parse-params reads each of WPT's urlencoded-parser inputs, as its UTF-8"
  (map cdr parser-vectors)
  (map (lambda (v) (parse-params (string->utf8 (car v)))) parser-vectors))

(test-equal "req-query-params reads each of them as a query, its UTF-8 one character a byte, as req-with-query can give it"
  (map cdr parser-vectors)
  (map (lambda (v) (query-of (string->utf8 (car v)))) parser-vectors))

(test-equal "wrap-form-params reads each of them as a form's body, as WPT's formData() does"
  (map cdr parser-vectors)
  (map-in-order (lambda (v) (form-of (string->utf8 (car v)))) parser-vectors))

(test-equal "WPT's URLSearchParams constructor strings: +, %2B, a space, %20, NUL, %00, U+2384 and U+1F4A9, raw and escaped, in a name and a value"
  '((("a" . "") (" " . "") ("a b" . "") (" c" . "") ("m\xF8;\xF8;" . ""))
    (("a" . "b c")) (("a b" . "c"))
    (("query" . "+15555555555"))
    (("a" . "b c")) (("a b" . "c"))
    (("a" . "b c")) (("a b" . "c"))
    (("a" . "b\x0;c")) (("a\x0;b" . "c"))
    (("a" . "b\x0;c")) (("a\x0;b" . "c"))
    (("a" . "b\x2384;")) (("a\x2384;b" . "c"))
    (("a" . "b\x2384;")) (("a\x2384;b" . "c"))
    (("a" . "b\x1F4A9;c")) (("a\x1F4A9;b" . "c"))
    (("a" . "b\x1F4A9;c")) (("a\x1F4A9;b" . "c")))
  (map (lambda (s) (parse-params (string->utf8 s)))
       '("&a&&& &&&&&a+b=& c&m%c3%b8%c3%b8"
         "a=b+c" "a+b=c"
         "query=%2B15555555555"
         "a=b c" "a b=c"
         "a=b%20c" "a%20b=c"
         "a=b\x0;c" "a\x0;b=c"
         "a=b%00c" "a%00b=c"
         "a=b\x2384;" "a\x2384;b=c"
         "a=b%e2%8e%84" "a%e2%8e%84b=c"
         "a=b\x1F4A9;c" "a\x1F4A9;b=c"
         "a=b%f0%9f%92%a9c" "a%f0%9f%92%a9b=c")))

(test-equal "a leading ? is a name's: URLSearchParams' constructor drops it, the parser keeps it, and req-query is what follows the ?"
  (list '(("?a" . "b")) '(("a" . "b")))
  (list (parse-params (string->utf8 "?a=b"))
        (req-query-params (make-test-req 'GET "/?a=b"))))

;;; ------------------------------------------------------------------------
;;; The UTF-8 decoder

;; value-of : Bytevector -> String — BV, raw, read as the value of v.
(define (value-of bv)
  (let ((params (parse-params (bytevector-append (string->utf8 "v=") bv))))
    (if (and (= (length params) 1) (string=? (caar params) "v"))
        (cdar params)
        (list 'not-one-v params))))

(define (bytevector-append . bvs)
  (call-with-bytevector-output-port (lambda (out) (for-each (lambda (bv) (put-bytevector out bv)) bvs))))

;; WPT's malformed sequences, from textdecoder-fatal.any.js, each with what
;; §8.1.1 reads it as: one U+FFFD a byte, as it happens, but a NUL, which
;; is a character of its own.
(define fatal-vectors
  `((#vu8(#xFF) ,replacement)
    (#vu8(#xC0) ,replacement)
    (#vu8(#xE0) ,replacement)
    (#vu8(#xC0 #x00) ,(string-append replacement "\x0;"))
    (#vu8(#xC0 #xC0) ,(string-append replacement replacement))
    (#vu8(#xE0 #x00) ,(string-append replacement "\x0;"))
    (#vu8(#xE0 #xC0) ,(string-append replacement replacement))
    (#vu8(#xE0 #x80 #x00) ,(string-append replacement replacement "\x0;"))
    (#vu8(#xE0 #x80 #xC0) ,(string-append replacement replacement replacement))
    (#vu8(#xFC #x80 #x80 #x80 #x80 #x80) 6)
    (#vu8(#xFE #x80 #x80 #x80 #x80 #x80) 6)
    (#vu8(#xC0 #x80) 2)
    (#vu8(#xE0 #x80 #x80) 3)
    (#vu8(#xF0 #x80 #x80 #x80) 4)
    (#vu8(#xF8 #x80 #x80 #x80 #x80) 5)
    (#vu8(#xFC #x80 #x80 #x80 #x80 #x80) 6)
    (#vu8(#xC1 #xBF) 2)
    (#vu8(#xE0 #x81 #xBF) 3)
    (#vu8(#xF0 #x80 #x81 #xBF) 4)
    (#vu8(#xF8 #x80 #x80 #x81 #xBF) 5)
    (#vu8(#xFC #x80 #x80 #x80 #x81 #xBF) 6)
    (#vu8(#xE0 #x9F #xBF) 3)
    (#vu8(#xF0 #x80 #x9F #xBF) 4)
    (#vu8(#xF8 #x80 #x80 #x9F #xBF) 5)
    (#vu8(#xFC #x80 #x80 #x80 #x9F #xBF) 6)
    (#vu8(#xF0 #x8F #xBF #xBF) 4)
    (#vu8(#xF8 #x80 #x8F #xBF #xBF) 5)
    (#vu8(#xFC #x80 #x80 #x8F #xBF #xBF) 6)
    (#vu8(#xF8 #x84 #x8F #xBF #xBF) 5)
    (#vu8(#xFC #x80 #x84 #x8F #xBF #xBF) 6)
    (#vu8(#xED #xA0 #x80) 3)
    (#vu8(#xED #xB0 #x80) 3)
    (#vu8(#xED #xA0 #x80 #xED #xB0 #x80) 6)))

;; replacements : (U String Nat) -> String — N U+FFFD, or the string given.
(define (replacements x)
  (if (string? x) x (apply string-append (map (lambda (i) replacement) (iota x)))))

(test-equal "WPT's malformed UTF-8, each read as §8.1.1 reads it: an overlong form, a surrogate, a lead past U+10FFFF, a trail that isn't one"
  (map (lambda (v) (replacements (cadr v))) fatal-vectors)
  (map (lambda (v) (value-of (car v))) fatal-vectors))

(test-equal "WPT's end-of-queue rows: a truncated sequence is one U+FFFD, and the byte that ends one early is read again"
  (list replacement replacement replacement
        (string-append replacement "A") (string-append replacement "AB")
        (string-append replacement "A" replacement)
        (string-append replacement replacement replacement)
        (string-append replacement "\x80;*"))
  (map value-of
       (list #vu8(#xF0) #vu8(#xF0 #x9F) #vu8(#xF0 #x9F #x92)
             #vu8(#xF0 #x9F #x41) #vu8(#xF0 #x41 #x42) #vu8(#xF0 #x41 #xF0)
             #vu8(#xF0 #x8F #x92)
             #vu8(#xF0 #xC2 #x80 #x2A))))

(define bom-bytes #vu8(#x7A #xC2 #xA2 #xE6 #xB0 #xB4 #xF0 #x9D #x84 #x9E #xF4 #x8F #xBF #xBD))
(define bom-string "z\xA2;\x6C34;\x1D11E;\x10FFFD;")

(test-equal "WPT's byte-order marks: the UTF-8 decodes, a UTF-8 BOM is kept as U+FEFF, without BOM, and a UTF-16 BOM is two U+FFFD"
  (list bom-string (string-append "\xFEFF;" bom-string)
        (string-append replacement replacement bom-string)
        (string-append replacement replacement bom-string))
  (list (value-of bom-bytes)
        (value-of (bytevector-append #vu8(#xEF #xBB #xBF) bom-bytes))
        (value-of (bytevector-append #vu8(#xFF #xFE) bom-bytes))
        (value-of (bytevector-append #vu8(#xFE #xFF) bom-bytes))))

(test-equal "the design's three, where Chez's utf8->string reads otherwise: an overlong / is two U+FFFD, a surrogate three, and a BOM is kept"
  (list (string-append replacement replacement)
        (string-append replacement replacement replacement)
        "\xFEFF;A")
  (map (lambda (s) (cdar (parse-params (string->utf8 s))))
       '("v=%C0%AF" "v=%ED%A0%80" "v=%EF%BB%BFA")))

(test-equal "each lead byte's bounds, from both sides: C2, E0's A0, ED's 9F, F0's 90, F4's 8F and F4 itself the last taken"
  (list (string-append replacement replacement) "\x80;" "\x7FF;"
        (string-append replacement replacement replacement) "\x800;"
        "\xD7FF;" (string-append replacement replacement replacement) "\xE000;" "\xFFFF;"
        (string-append replacement replacement replacement replacement) "\x10000;"
        "\x10FFFF;" (string-append replacement replacement replacement replacement)
        (string-append replacement replacement replacement replacement)
        replacement (string-append replacement "A") replacement)
  (map value-of
       (list #vu8(#xC1 #xBF) #vu8(#xC2 #x80) #vu8(#xDF #xBF)
             #vu8(#xE0 #x9F #xBF) #vu8(#xE0 #xA0 #x80)
             #vu8(#xED #x9F #xBF) #vu8(#xED #xA0 #x80) #vu8(#xEE #x80 #x80) #vu8(#xEF #xBF #xBF)
             #vu8(#xF0 #x8F #xBF #xBF) #vu8(#xF0 #x90 #x80 #x80)
             #vu8(#xF4 #x8F #xBF #xBF) #vu8(#xF4 #x90 #x80 #x80)
             #vu8(#xF5 #x80 #x80 #x80)
             #vu8(#xE1 #x80) #vu8(#xE1 #x80 #x41) #vu8(#xF1 #x80 #x80))))

;;; ------------------------------------------------------------------------
;;; Escapes

(test-equal "every byte, escaped in upper-case hex and in lower: below 80 its character, from 80 one U+FFFD, as a lone byte is no UTF-8"
  (let ((expected (map (lambda (b) (if (< b #x80) (string (integer->char b)) replacement)) (iota 256))))
    (list expected expected))
  (list (map (lambda (b) (cdar (parse-params (string->utf8 (string-append "v=%" (hex2 b)))))) (iota 256))
        (map (lambda (b) (cdar (parse-params (string->utf8 (string-append "v=%" (lower-hex2 b)))))) (iota 256))))

;; escape-verdict : Nat -> Params
;; What v=%B0 reads as, B a byte: an escape when B is a hex digit, a split
;; at &, a space at +, and otherwise the % and the 0 kept, B read as itself,
;; or as U+FFFD from 80, where it is no UTF-8 on its own.
(define (escape-verdict b)
  (let ((c (integer->char b)))
    (cond ((memv c (string->list "0123456789ABCDEFabcdef"))
           (let ((v (* 16 (string->number (string c) 16))))
             (list (cons "v" (if (< v #x80) (string (integer->char v)) replacement)))))
          ((char=? c #\&) '(("v" . "%") ("0" . "")))
          ((char=? c #\+) '(("v" . "% 0")))
          ((< b #x80) (list (cons "v" (string #\% c #\0))))
          (else (list (cons "v" (string-append "%" replacement "0")))))))

(test-equal "% before every byte: only the 22 hex digits start an escape"
  (map escape-verdict (iota 256))
  (map (lambda (b) (parse-params (bytes "v=%" b "0"))) (iota 256)))

;; at-every-position : String -> (Listof String)
;; TEXT put into xyz at each of its four positions.
(define (at-every-position text)
  (map (lambda (i) (string-append (substring "xyz" 0 i) text (substring "xyz" i 3))) (iota 4)))

(define malformed '("%" "%4" "%4g" "%g4" "%gg" "%%"))

(test-equal "a malformed escape at every position of a name and of a value, before x, y or z (none a hex digit) and at the end, stays as it is"
  (apply append
         (map (lambda (m)
                (map (lambda (s) (list (cons s "v") (cons "n" s))) (at-every-position m)))
              malformed))
  (apply append
         (map (lambda (m)
                (map (lambda (s)
                       (list (car (parse-params (string->utf8 (string-append s "=v"))))
                             (car (parse-params (string->utf8 (string-append "n=" s))))))
                     (at-every-position m)))
              malformed)))

(test-equal "a whole escape at every position of a name and of a value is its byte"
  (map (lambda (s) (list (cons s "v") (cons "n" s))) (at-every-position "A"))
  (map (lambda (s)
         (list (car (parse-params (string->utf8 (string-append s "=v"))))
               (car (parse-params (string->utf8 (string-append "n=" s))))))
       (at-every-position "%41")))

(test-equal "+ is a space and %2B a +, and a space and %20 both a space, at every position of a name and of a value"
  (map (lambda (pair)
         (map (lambda (s) (list (cons s "v") (cons "n" s))) (at-every-position (cdr pair))))
       '(("+" . " ") ("%2B" . "+") (" " . " ") ("%20" . " ")))
  (map (lambda (pair)
         (map (lambda (s)
                (list (car (parse-params (string->utf8 (string-append s "=v"))))
                      (car (parse-params (string->utf8 (string-append "n=" s))))))
              (at-every-position (car pair))))
       '(("+" . " ") ("%2B" . "+") (" " . " ") ("%20" . " "))))

;;; ------------------------------------------------------------------------
;;; params->string

(test-equal "WPT's stringifier rows: a space as +, empty names and values, +, =, &, *-._ kept, %, NUL, U+1F4A9, no newline normalized"
  '("a=b+c" "a+b=c"
    "a=" "a=&a=" "a=&a=&=b" "a=&a=&=b&=" "a=&a=&=b&=&="
    "=b" "=b&=b" "=" "=&="
    "a=b%2Bc" "a%2Bb=c"
    "%3D=a" "%3D=a&b=%3D"
    "%26=a" "%26=a&b=%26"
    "a=*-._" "*-._=c"
    "a=b%25c" "a%25b=c"
    "a=b%00c" "a%00b=c"
    "a=b%F0%9F%92%A9c" "a%F0%9F%92%A9b=c"
    "query=%2B15555555555"
    "a%0Ab=c%0Dd&e%0A%0Df=g%0D%0Ah"
    "")
  (map params->string
       '((("a" . "b c")) (("a b" . "c"))
         (("a" . "")) (("a" . "") ("a" . "")) (("a" . "") ("a" . "") ("" . "b"))
         (("a" . "") ("a" . "") ("" . "b") ("" . ""))
         (("a" . "") ("a" . "") ("" . "b") ("" . "") ("" . ""))
         (("" . "b")) (("" . "b") ("" . "b")) (("" . "")) (("" . "") ("" . ""))
         (("a" . "b+c")) (("a+b" . "c"))
         (("=" . "a")) (("=" . "a") ("b" . "="))
         (("&" . "a")) (("&" . "a") ("b" . "&"))
         (("a" . "*-._")) (("*-._" . "c"))
         (("a" . "b%c")) (("a%b" . "c"))
         (("a" . "b\x0;c")) (("a\x0;b" . "c"))
         (("a" . "b\x1F4A9;c")) (("a\x1F4A9;b" . "c"))
         (("query" . "+15555555555"))
         (("a\nb" . "c\rd") ("e\n\rf" . "g\r\nh"))
         ())))

(test-equal "WPT's toString rows: a string parsed, then written: empty pieces gone, a lone = kept, a malformed escape's % written %25, a comma escaped"
  '("a=b&c=d&e=" "a+=+b+&a=b&c=d+" "a=&a=b" "id=0&value=%25"
    "b=%252sf*" "b=%252*f*" "b=%25*" "a=b%2Cc")
  (map (lambda (s) (params->string (parse-params (string->utf8 s))))
       '("a=b&c=d&&e&&" "a = b &a=b&c=d%20" "a=&a=b" "id=0&value=%"
         "b=%2sf%2a" "b=%2%2af%2a" "b=%%2a" "a=b,c")))

;; serialized : Char -> String
;; C as §5.2 writes it: an ASCII letter or digit, *, -, . or _ as itself, a
;; space as +, and anything else as its UTF-8, each byte %XX.
(define (serialized c)
  (cond ((or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (memv c '(#\* #\- #\. #\_)))
         (string c))
        ((char=? c #\space) "+")
        (else (apply string-append
                     (map (lambda (b) (string-append "%" (hex2 b)))
                          (bytevector->u8-list (string->utf8 (string c))))))))

(define every-char
  (append (map integer->char (iota 256))
          (map integer->char '(#x100 #x7FF #x800 #xFFFF #x10000 #x10FFFF))))

(test-equal "params->string writes every character from 0 to 255, and six past it, kept, a +, or its UTF-8 escaped, in a name and in a value"
  (map (lambda (c) (string-append (serialized c) "=" (serialized c))) every-char)
  (map (lambda (c) (params->string (list (cons (string c) (string c))))) every-char))

;;; ------------------------------------------------------------------------
;;; param-value and param-values

(define (parsed s) (parse-params (string->utf8 s)))

(test-equal "param-value: WPT's get rows, the first of a name, #f for none, the empty name a name"
  '("b" "d" #f "b" "b" "" "second" "" #f)
  (list (param-value (parsed "a=b&c=d") "a") (param-value (parsed "a=b&c=d") "c")
        (param-value (parsed "a=b&c=d") "e") (param-value (parsed "a=b&c=d&a=e") "a")
        (param-value (parsed "=b&c=d") "") (param-value (parsed "a=&c=d&a=e") "a")
        (param-value (parsed "first=second&third&&") "first")
        (param-value (parsed "first=second&third&&") "third")
        (param-value (parsed "first=second&third&&") "fourth")))

(test-equal "param-values: WPT's getAll rows, every value of a name in order, '() for none"
  '(("b") ("d") () ("b" "e") ("b") ("" "e") ("1" "2" "3" ""))
  (list (param-values (parsed "a=b&c=d") "a") (param-values (parsed "a=b&c=d") "c")
        (param-values (parsed "a=b&c=d") "e") (param-values (parsed "a=b&c=d&a=e") "a")
        (param-values (parsed "=b&c=d") "") (param-values (parsed "a=&c=d&a=e") "a")
        (param-values (parsed "a=1&a=2&a=3&a") "a")))

(test-equal "a name matches in its case: Q is no q, and é no e"
  '(("upper" "lower" #f) (("upper") ("lower") ()))
  (let ((ps '(("Q" . "upper") ("q" . "lower") ("\xE9;" . "acute"))))
    (list (list (param-value ps "Q") (param-value ps "q") (param-value ps "e"))
          (list (param-values ps "Q") (param-values ps "q") (param-values ps "e")))))

(test-equal "param-value, param-values and params->string refuse what is no param list, a param that is no pair of strings, and a name that is no string"
  '((assertion-violation param-value (x))
    (assertion-violation param-value ((("a" . "b") . "c")))
    (assertion-violation param-value (("a" . 1)))
    (assertion-violation param-value ((a . "b")))
    (assertion-violation param-value ("a"))
    (assertion-violation param-value (a))
    (assertion-violation param-values (x))
    (assertion-violation param-values (("a" . 1)))
    (assertion-violation param-values (a))
    (assertion-violation params->string (x))
    (assertion-violation params->string ((("a" . "b") . "c")))
    (assertion-violation params->string (("a" . 1)))
    (assertion-violation params->string ((a . "b")))
    (assertion-violation params->string ("a")))
  (list (raised (lambda () (param-value 'x "a")))
        (raised (lambda () (param-value '(("a" . "b") . "c") "a")))
        (raised (lambda () (param-value '(("z" . "y") ("a" . 1)) "z")))
        (raised (lambda () (param-value '((a . "b")) "a")))
        (raised (lambda () (param-value '("a") "a")))
        (raised (lambda () (param-value '(("a" . "b")) 'a)))
        (raised (lambda () (param-values 'x "a")))
        (raised (lambda () (param-values '(("z" . "y") ("a" . 1)) "z")))
        (raised (lambda () (param-values '(("a" . "b")) 'a)))
        (raised (lambda () (params->string 'x)))
        (raised (lambda () (params->string '(("a" . "b") . "c"))))
        (raised (lambda () (params->string '(("z" . "y") ("a" . 1)))))
        (raised (lambda () (params->string '((a . "b")))))
        (raised (lambda () (params->string '("a"))))))

(test-equal "the refusals' messages"
  '("a param list is a list of (name . value) string pairs"
    "a param is a (name . value) pair of strings"
    "a param name is a string"
    "a param list is a list of (name . value) string pairs"
    "a param is a (name . value) pair of strings")
  (list (raised-message (lambda () (param-value 'x "a")))
        (raised-message (lambda () (param-value '(("a" . 1)) "a")))
        (raised-message (lambda () (param-value '() 'a)))
        (raised-message (lambda () (params->string 'x)))
        (raised-message (lambda () (params->string '(("a" . 1)))))))

(test-equal "parse-params refuses what is no bytevector: a string could be read two ways"
  '((assertion-violation parse-params ("a=b"))
    (assertion-violation parse-params (#f))
    "a body or query to parse is a bytevector: give a string's UTF-8")
  (list (raised (lambda () (parse-params "a=b")))
        (raised (lambda () (parse-params #f)))
        (raised-message (lambda () (parse-params "a=b")))))

(test-equal "each string parse-params answers is fresh: a change to one changes no other read"
  '(("a" . "b") ("a" . "b"))
  (let* ((bv (string->utf8 "a=b&a=b"))
         (first (parse-params bv)))
    (string-set! (caar first) 0 #\z)
    (string-set! (cdar first) 0 #\z)
    (list (cadr first) (car (parse-params bv)))))

;;; ------------------------------------------------------------------------
;;; req-query-params

(test-equal "req-query-params: '() with no query and for an empty one, and the query's pairs, a name given twice kept twice"
  '(() () (("q" . "caf\xE9;") ("q" . "x") ("" . "")))
  (list (req-query-params (make-test-req 'GET "/search"))
        (req-query-params (make-test-req 'GET "/search?"))
        (req-query-params (make-test-req 'GET "/search?q=caf%C3%A9&q=x&="))))

(test-equal "a query's characters are its bytes: raw UTF-8 reads as é, and a Latin-1 é alone, which is no UTF-8, as U+FFFD"
  (list '(("q" . "caf\xE9;")) (list (cons "q" (string-append "caf" replacement))))
  (list (req-query-params (req-with-query (make-test-req 'GET "/") "q=caf\xC3;\xA9;"))
        (req-query-params (req-with-query (make-test-req 'GET "/") "q=caf\xE9;"))))

(test-equal "req-query-params reads each character from 0 to 255 as the byte it names, as parse-params reads that byte"
  (map (lambda (b) (parse-params (bytes "v=" b))) (iota 256))
  (map (lambda (b)
         (req-query-params (req-with-query (make-test-req 'GET "/") (string #\v #\= (integer->char b)))))
       (iota 256)))

(test-equal "req-query-params reads the query each time: a req-with-query is seen, and #f answers '()"
  '((("a" . "1")) (("b" . "2")) ())
  (let ((r (make-test-req 'GET "/?a=1")))
    (list (req-query-params r)
          (req-query-params (req-with-query r "b=2"))
          (req-query-params (req-with-query r #f)))))

(test-equal "req-query-params refuses a query holding a character past 255, which only code could put there, and what is no request"
  '((assertion-violation req-query-params ("q=\x100;"))
    "a query's characters are its bytes, each at most 255"
    (assertion-violation req-query-params (not-a-request)))
  (let ((r (req-with-query (make-test-req 'GET "/") "q=\x100;")))
    (list (raised (lambda () (req-query-params r)))
          (raised-message (lambda () (req-query-params r)))
          (raised (lambda () (req-query-params 'not-a-request))))))

;;; ------------------------------------------------------------------------
;;; wrap-form-params, on test requests

(define (form-req type body)
  (make-test-req 'POST "/form" (list (cons "content-type" type)) body))

(define form-types
  '("application/x-www-form-urlencoded"
    "APPLICATION/X-WWW-FORM-URLENCODED"
    "Application/X-Www-Form-Urlencoded"
    "application/x-www-form-urlencoded; charset=utf-8"
    "application/x-www-form-urlencoded;charset=windows-1252"
    "application/x-www-form-urlencoded ; charset=utf-8"
    "application/x-www-form-urlencoded\t;"))

(test-equal "wrap-form-params reads a body whose media type is the form's, in any case, its parameters ignored, charset among them: the pairs, and the body left at eof"
  (map (lambda (t) (list '(("a" . "1") ("b" . "\xE9;")) 'eof 64)) form-types)
  (map-in-order (lambda (t) (form-seen (list (wrap-form-params 64)) (form-req t "a=1&b=%C3%A9")))
                form-types))

(define other-types
  '("text/plain" "multipart/form-data; boundary=x" "application/json"
    "application/x-www-form-urlencodedx" "application/x-www-form-urlencoded, text/plain"
    "application/x-www-form" "x-www-form-urlencoded" ""))

(test-equal "wrap-form-params passes any other request untouched: req-form-params '(), and the body the handler's to read"
  (append (map (lambda (t) (list '() "a=1" #f)) other-types)
          (list (list '() "a=1" #f) (list '() "a=1" #f)))
  (append (map-in-order (lambda (t) (form-seen (list (wrap-form-params 64)) (form-req t "a=1")))
                        other-types)
          (list (form-seen (list (wrap-form-params 64)) (make-test-req 'POST "/form" '() "a=1"))
                (form-seen (list (wrap-form-params 64))
                           (make-test-req 'POST "/form" (list form-type '("content-type" . "text/plain"))
                                          "a=1")))))

(test-equal "a request with two content-type fields is no form, both the form's included: which one a proxy read is unknown"
  (list '() "a=1" #f)
  (form-seen (list (wrap-form-params 64))
             (make-test-req 'POST "/form" (list form-type form-type) "a=1")))

(test-equal "req-form-params is '() for a request no wrap-form-params read, and for a form with an empty body or none"
  '(() (() eof 64) (() eof 64))
  (list (req-form-params (form-req "application/x-www-form-urlencoded" "a=1"))
        (form-seen (list (wrap-form-params 64)) (form-req "application/x-www-form-urlencoded" ""))
        (form-seen (list (wrap-form-params 64)) (form-req "application/x-www-form-urlencoded" #f))))

(test-equal "the handler sees the cap the body was read under: the smaller of the middleware's and the request's own, a bignum among them"
  (list (list '(("a" . "1")) 'eof 10) (list '(("a" . "1")) 'eof 10) (list '(("a" . "1")) 'eof 64)
        (list '(("a" . "1")) 'eof (expt 2 100)) (list '(("a" . "1")) 'eof 0))
  (let ((seen (lambda middlewares
                (form-seen middlewares (form-req "application/x-www-form-urlencoded" "a=1")))))
    (list (seen (wrap-form-params 64) (wrap-body-cap 10))
          (seen (wrap-form-params 10) (wrap-body-cap 64))
          (seen (wrap-form-params 64) (wrap-body-cap #f))
          (seen (wrap-form-params (expt 2 100)))
          (seen (wrap-form-params (expt 2 100)) (wrap-body-cap 0)))))

(test-equal "a form whose body's port was made outside it is req-with-body-cap's assertion violation, and so is a second wrap-form-params; any other request's passes"
  '((assertion-violation req-with-body-cap (64))
    (assertion-violation req-with-body-cap (64))
    (() eof #f))
  (let ((reading (lambda (h) (lambda (r) (get-bytevector-all (req-body r)) (h r)))))
    (list (raised (lambda () (form-seen (list (wrap-form-params 64) reading)
                                        (form-req "application/x-www-form-urlencoded" "a=1"))))
          (raised (lambda () (form-seen (list (wrap-form-params 64) (wrap-form-params 100))
                                        (form-req "application/x-www-form-urlencoded" "a=1"))))
          (form-seen (list (wrap-form-params 64) reading) (form-req "text/plain" "a=1")))))

(test-equal "a cap inside wrap-form-params comes after the body is read: req-with-body-cap's assertion violation for a form, and the cap as given for any other request"
  (list '(assertion-violation req-with-body-cap (16)) (list '() "a=1" 16))
  (list (raised (lambda () (form-seen (list (wrap-body-cap 16) (wrap-form-params 64))
                                      (form-req "application/x-www-form-urlencoded" "a=1"))))
        (form-seen (list (wrap-body-cap 16) (wrap-form-params 64)) (form-req "text/plain" "a=1"))))

(test-equal "wrap-form-params answers its handler's answer as it is"
  '(#t #t)
  (let ((res (make-res 200 '() "ok")))
    (list (eq? res (((wrap-form-params 64) (lambda (r) res)) (form-req "text/plain" "a=1")))
          (eq? res (((wrap-form-params 64) (lambda (r) res))
                    (form-req "application/x-www-form-urlencoded" "a=1"))))))

(test-equal "wrap-form-params refuses a cap that is no count of bytes, #f among them, when it is called, and a handler that is no procedure when it is applied"
  '((assertion-violation wrap-form-params (-1))
    (assertion-violation wrap-form-params (1.5))
    (assertion-violation wrap-form-params (4.))
    (assertion-violation wrap-form-params ("4"))
    (assertion-violation wrap-form-params (#f))
    (assertion-violation wrap-form-params (not-a-handler))
    "a cap is a count of bytes")
  (append (map (lambda (cap) (raised (lambda () (wrap-form-params cap)))) (list -1 1.5 4. "4" #f))
          (list (raised (lambda () ((wrap-form-params 4) 'not-a-handler)))
                (raised-message (lambda () (wrap-form-params #f))))))

(test-equal "req-form-params refuses what is no request"
  '(assertion-violation req-form-params (not-a-request))
  (raised (lambda () (req-form-params 'not-a-request))))

;;; ------------------------------------------------------------------------
;;; The cap, through the server's test host

(define (b s) (string->utf8 s))

;; text : Bytevector -> String — BV one character a byte.
(define (text bv) (latin1 bv))

(define (unset name) #f)

(define (settings name value) (lambda (n) (and (string=? n name) value)))

(define (wire c)
  (map (lambda (r) (text (test-response-bytes r))) (test-client-responses c)))

(define (logged host)
  (map (lambda (entry) (cons (car entry) (map (lambda (d) (if (condition? d) (describe d) d)) (cdr entry))))
       (test-host-log host)))

;; exchange : Handler String [Env] -> (List (Listof String) Boolean (Listof Any))
;; One client sends REQUEST: what it read, whether the server ended the
;; connection, and what the server logged.
(define exchange
  (case-lambda
    ((app request) (exchange app request unset))
    ((app request env)
     (let* ((host (make-test-host (circuit->handler app env) env))
            (c (test-host-connect! host)))
       (test-client-send! c (b request))
       (list (wire c) (test-client-connection-closed? c) (logged host))))))

(define (response status fields body)
  (string-append "HTTP/1.1 " status "\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\n"
                 (apply string-append (map (lambda (f) (string-append f "\r\n")) fields))
                 "\r\n" body))

(define (length-field n) (string-append "Content-Length: " (number->string n)))

(define form-field "Content-Type: application/x-www-form-urlencoded")

;; form-post : String -> String — a form of BODY, its length declared.
(define (form-post body)
  (string-append "POST /up HTTP/1.1\r\nHost: x\r\n" form-field "\r\nContent-Length: "
                 (number->string (string-length body)) "\r\n\r\n" body))

;; chunked-form-post : String ... -> String — a form of PIECES, chunked.
(define (chunked-form-post . pieces)
  (string-append "POST /up HTTP/1.1\r\nHost: x\r\n" form-field "\r\nTransfer-Encoding: chunked\r\n\r\n"
                 (apply string-append
                        (map (lambda (p) (string-append (number->string (string-length p) 16) "\r\n" p "\r\n"))
                             pieces))
                 "0\r\n\r\n"))

;; How many times form-echo's handler ran since the last reset.
(define ran 0)

;; form-echo : Middleware ... -> Handler
;; An app that answers its form params, written, inside MIDDLEWARES.
(define (form-echo . middlewares)
  (apply wrap
         (lambda (r)
           (set! ran (+ ran 1))
           (make-res 200 '() (params->string (req-form-params r))))
         middlewares))

;; ran-exchange : Handler String [Env] -> (List Exchange Nat)
;; The exchange, and how many times the handler ran in it.
(define (ran-exchange app request . env)
  (set! ran 0)
  (let ((ex (apply exchange app request env)))
    (list ex ran)))

(define (echoed body)
  (list (list (list (response "200 OK" (list (length-field (string-length body))) body)) #f '()) 1))

;; A body past a cap: 413, the connection ended, the server's refusal
;; logged with the test host's "-" for the client's address, and no
;; handler run.
(define too-large
  (list (list (list (response "413 Content Too Large" '("Content-Length: 0" "Connection: close") ""))
              #t
              '((request-refused 413 body-too-large "-")))
        0))

(test-equal "through the server: a form at the cap is read, one byte past it refused 413 before the handler runs, declared or chunked"
  (list (echoed "a=bcd") too-large too-large (echoed "a=bcd"))
  (let ((app (form-echo (wrap-form-params 5))))
    (list (ran-exchange app (form-post "a=bcd"))
          (ran-exchange app (form-post "a=bcde"))
          (ran-exchange app (chunked-form-post "a=bc" "de"))
          (ran-exchange app (chunked-form-post "a=b" "cd")))))

(test-equal "a declared Content-Length past the cap, with Expect: 100-continue, is refused at the first read, with no 100 Continue"
  too-large
  (ran-exchange (form-echo (wrap-form-params 5))
                (string-append "POST /up HTTP/1.1\r\nHost: x\r\n" form-field
                               "\r\nExpect: 100-continue\r\nContent-Length: 6\r\n\r\n")))

(test-equal "the smallest cap wins: the request's own under the middleware's, the middleware's under the request's, the server's under both"
  (list too-large (echoed "a=bc") too-large too-large)
  (list (ran-exchange (form-echo (wrap-form-params 100) (wrap-body-cap 4)) (form-post "a=bcd"))
        (ran-exchange (form-echo (wrap-form-params 100) (wrap-body-cap 4)) (form-post "a=bc"))
        (ran-exchange (form-echo (wrap-form-params 4) (wrap-body-cap 100)) (form-post "a=bcd"))
        (ran-exchange (form-echo (wrap-form-params 100) (wrap-body-cap #f)) (chunked-form-post "a=b" "cd")
                      (settings "CHEZ_HTTP_MAX_BODY_BYTES" "4"))))

(test-equal "a bignum cap reads a form, and a query and a form are read apart"
  (list (echoed "a=bcd")
        (list (list (list (response "200 OK" (list (length-field 7)) "a=1|a=2")) #f '()) 1))
  (list (ran-exchange (form-echo (wrap-form-params (expt 2 100))) (form-post "a=bcd"))
        (ran-exchange (wrap (lambda (r)
                              (set! ran (+ ran 1))
                              (make-res 200 '() (string-append (params->string (req-query-params r)) "|"
                                                               (params->string (req-form-params r)))))
                            (wrap-form-params 64))
                      (string-append "POST /up?a=1 HTTP/1.1\r\nHost: x\r\n" form-field
                                     "\r\nContent-Length: 3\r\n\r\na=2"))))

(test-equal "through the server, a cap inside wrap-form-params makes every form a 500, the handler never run"
  (list (list (list (response "500 Internal Server Error" '("Content-Length: 0" "Connection: close") ""))
              #t
              '((handler-failed "Exception in req-with-body-cap: the body's port is made, and its cap with it: give the cap before anything reads the body with irritant 16")))
        0)
  (ran-exchange (form-echo (wrap-body-cap 16) (wrap-form-params 64)) (form-post "a=b")))

;; stalled : Handler Nat -> (List (Listof String) (Listof String) Nat)
;; A form whose head and first three bytes arrive, then nothing for MS
;; milliseconds, then the rest: what the client read before the rest came,
;; after it, and how many times the handler ran.
(define (stalled app ms)
  (set! ran 0)
  (let* ((host (make-test-host (circuit->handler app unset) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (string-append "POST /up HTTP/1.1\r\nHost: x\r\n" form-field
                                           "\r\nContent-Length: 5\r\n\r\na=b")))
    (test-host-advance! host ms)
    (let ((before (wire c)))
      (test-client-send! c (b "cd"))
      (list before (wire c) ran))))

(test-equal "a form that arrives in two pieces is read whole: nothing is answered until the last byte is in"
  (list '() (list (response "200 OK" (list (length-field 5)) "a=bcd")) 1)
  (stalled (form-echo (wrap-form-params 64)) 50))

(test-equal "wrap-timeout outside it covers a client that stalls mid-form: 504 at the deadline, the handler never run"
  (list (list (response "504 Gateway Timeout" '("Content-Length: 0" "Connection: close") ""))
        (list (response "504 Gateway Timeout" '("Content-Length: 0" "Connection: close") ""))
        0)
  (stalled (form-echo (wrap-form-params 64) (wrap-timeout 100)) 100))

(exit (suite-exit-status runner))
