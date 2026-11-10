#!r6rs
;;; (circuit json): wrap-json-body, req-json? and req-json, and
;;; make-json-res (design §15.36, ADR-0009).
;;;
;;; jsonparse is the oracle for what a document is. The values and the
;;; refusals' reasons and byte offsets below are its, from its docs and a
;;; probe of v0.1.0 on circuit's path; the rows hold what circuit makes of
;;; them.
;;;
;;; The rows:
;;;   - which requests it reads: one content-type field, whose media type,
;;;     in any case, is application/json or application/<name>+json, its
;;;     parameters ignored, the name an RFC 6838 restricted-name, every ASCII
;;;     character and four past it tried at its first and its middle place.
;;;     Any other request passes untouched, its body unread, two content-type
;;;     fields among them;
;;;   - the values: every kind JSON has, false and null among them, a
;;;     duplicate key kept, a bignum exact; under options, the number, object
;;;     and null modes;
;;;   - no JSON: an empty body or none runs the handler, req-json? #f;
;;;   - a body that is no JSON: 400, text/plain, its reason and byte offset,
;;;     the handler never run, whitespace alone among them; the depth and
;;;     digit limits from both sides, the defaults' and ones given;
;;;   - the guard covers the parse alone: a &json-error the handler raises,
;;;     json-ref's not-found among them, goes on as it was raised;
;;;   - the cap: the handler sees the smaller of the middleware's and the
;;;     request's own; a cap of 0 from both sides; a body's port made
;;;     outside it, or a cap inside it, is req-with-body-cap's assertion
;;;     violation; through the server's test
;;;     host, a body at the cap read, one past it 413 with no handler run,
;;;     declared or chunked; the server's cap under both; a bignum cap;
;;;   - the read waits as the body does: a document in pieces split inside
;;;     its tokens, and one past read-json's 16 KiB step, read whole; nothing
;;;     answered before the last byte, nor a refusal before the 16 KiB that
;;;     hold its bad byte; a stall under wrap-timeout a 504;
;;;   - make-json-res: the status, application/json and the value's bytes,
;;;     the options' indent obeyed; a value JSON can't express is
;;;     jsonparse's &json-error, raised at the call;
;;;   - the refusals: a cap that is no count of bytes, options that are no
;;;     record or that read-json refuses, a handler that is no procedure,
;;;     what is no request.
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (circuit-testing)
        (http-server testing)
        (circuit)
        (circuit http-server)
        (circuit middleware waits)
        (circuit test)
        (circuit json)
        (only (jsonparse easy) json-ref json-error? json-error-reason json-error-offset
              make-json-options))

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
;; violation, (json-error REASON OFFSET WHO) for a &json-error, (other-raise
;; X) for anything else, and no-raise if it returned.
(define (raised thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (irritants-condition? e))
             (list 'assertion-violation (condition-who e) (condition-irritants e)))
            ((json-error? e)
             (list 'json-error (json-error-reason e) (json-error-offset e)
                   (and (who-condition? e) (condition-who e))))
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

(define (b s) (string->utf8 s))

;; nested : Nat -> String — N arrays, each inside the last, the innermost empty.
(define (nested n) (string-append (make-string n #\[) (make-string n #\])))

;; depth : Any -> Nat — how many vectors V is inside, through the first element of each.
(define (depth v)
  (if (vector? v) (+ 1 (if (= (vector-length v) 0) 0 (depth (vector-ref v 0)))) 0))

;; --- on test requests ------------------------------------------------------------

;; json-req : String (U String Bytevector #f) -> Req — a POST of BODY, of TYPE.
(define (json-req type body)
  (make-test-req 'POST "/j" (list (cons "content-type" type)) body))

;; rest-of : Req -> (U String Symbol)
;; What is left of R's body, as UTF-8, or eof.
(define (rest-of r)
  (let ((bv (get-bytevector-all (req-body r))))
    (if (eof-object? bv) 'eof (utf8->string bv))))

;; shown : Any -> Any
;; A response as its status, headers and body's text; anything else as it is.
(define (shown x)
  (if (res? x)
      (list (res-status x) (res-headers x) (utf8->string (res-body->bytevector x)))
      x))

;; How many times seen's handler ran since the last reset.
(define ran 0)

;; seen : (Listof Middleware) Req -> Any
;; What a handler inside MIDDLEWARES sees of REQ: whether JSON was read, its
;; value or none, the rest of its body, and its cap. Or the response shown,
;; when something outside the handler answered.
(define (seen middlewares req)
  (shown ((apply wrap
                 (lambda (r)
                   (set! ran (+ ran 1))
                   (let* ((json? (req-json? r))
                          (value (if json? (req-json r) 'none))
                          (rest (rest-of r)))
                     (list json? value rest (req-body-cap r))))
                 middlewares)
          req)))

;; seen-ran : (Listof Middleware) Req -> (List Any Nat)
;; What seen answers, and how many times its handler ran.
(define (seen-ran middlewares req)
  (set! ran 0)
  (let ((answer (seen middlewares req)))
    (list answer ran)))

(define body "{\"a\": [1, 2.5, true, null], \"b\": \"\xE9;\"}")
(define value '(("a" . #(1 2.5 #t null)) ("b" . "\xE9;")))

(define json-types
  '("application/json" "APPLICATION/JSON" "Application/Json"
    "application/json; charset=utf-8" "application/json;charset=latin1"
    "application/json ; x=y" "application/json\t;" "application/json  ;" "application/json \t ; x=y"
    "application/problem+json" "application/merge-patch+json" "application/vnd.api+json"
    "APPLICATION/LD+JSON" "application/x+JSON" "application/a+b+json"
    "application/Z9!#$&-^_.+json"))

(test-equal "wrap-json-body reads a body whose media type is application/json or application/<name>+json, in any case, its parameters ignored: the value, and the body left at eof"
  (map (lambda (t) (list #t value 'eof 64)) json-types)
  (map-in-order (lambda (t) (seen (list (wrap-json-body 64)) (json-req t body))) json-types))

(define other-types
  '("text/plain" "application/x-www-form-urlencoded" "multipart/form-data; boundary=x"
    "text/json" "text/x+json" "application/jsonx" "application/json5" "application/jsonp"
    "application/+json" "application/json+" "application/x+jsonx" "image/svg+xml"
    "application/-x+json" "application/.x+json" "application/x,y+json" "application/x y+json"
    "application/x/y+json" "application/x\"+json" "audio/example+json" "text/x+json+json"
    "application/json foo" "application/json\tfoo" "Application/j\x17F;on" "application/x+j\x17F;on"
    "application/json, text/plain" "application /json" "application/ json"
    "json" "application" "application/" "/json" ""))

(test-equal "wrap-json-body passes any other request untouched: req-json? #f, and the body the handler's to read"
  (append (map (lambda (t) (list #f 'none "[1]" #f)) other-types)
          (list (list #f 'none "[1]" #f) (list #f 'none "[1]" #f)))
  (append (map-in-order (lambda (t) (seen (list (wrap-json-body 64)) (json-req t "[1]"))) other-types)
          (list (seen (list (wrap-json-body 64)) (make-test-req 'POST "/j" '() "[1]"))
                (seen (list (wrap-json-body 64))
                      (make-test-req 'POST "/j" '(("content-type" . "application/json")
                                                  ("content-type" . "application/json"))
                                     "[1]")))))

(define name-characters
  (append (map integer->char (iota 128)) (map integer->char '(#x80 #xFF #x17F #x212A))))

;; read-as-json : String -> String
;; The characters C of name-characters for which the media type made of
;; BEFORE, C and AFTER is read as JSON.
(define (read-as-json before after)
  (list->string
   (filter (lambda (c)
             (car (seen (list (wrap-json-body 64))
                        (json-req (string-append before (string c) after) "[1]"))))
           name-characters)))

(test-equal "the name before +json is a restricted-name (RFC 6838): within it, a letter, a digit or one of !#$&-^_.+, and no other ASCII character nor any past it"
  "!#$&+-.0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ^_abcdefghijklmnopqrstuvwxyz"
  (read-as-json "application/x" "y+json"))

(test-equal "the name begins with a letter or a digit"
  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  (read-as-json "application/" "x+json"))

(test-equal "an empty body, or none, is no JSON: the handler runs, req-json? #f, under the cap"
  '((#f none eof 64) (#f none eof 64))
  (list (seen (list (wrap-json-body 64)) (json-req "application/json" ""))
        (seen (list (wrap-json-body 64)) (json-req "application/json" #f))))

(test-equal "req-json? is #f for a request no wrap-json-body read, and req-json an assertion violation naming it"
  '(#f (req-json "no JSON was read from the request's body" #t))
  (let ((r (json-req "application/json" "[1]")))
    (list (req-json? r)
          (guard (e ((assertion-violation? e)
                     (list (condition-who e) (condition-message e)
                           (equal? (condition-irritants e) (list r))))
                    (#t (list 'other-raise (describe e))))
            (req-json r)
            'no-raise))))

(define documents
  (list (cons "0" 0) (cons "-1.5e3" -1500.0) (cons "\"s\"" "s") (cons "true" #t) (cons "false" #f)
        (cons "null" 'null) (cons "[]" '#()) (cons "{}" '())
        (cons "{\"a\":1,\"a\":2}" '(("a" . 1) ("a" . 2)))
        (cons "1267650600228229401496703205376" (expt 2 100))
        (cons " \t\n[1]\r\n " '#(1))))

(test-equal "every kind of value reaches the handler as jsonparse builds it: false as #f and req-json? #t, null as null, a duplicate key kept, a bignum exact, whitespace around it"
  (map (lambda (d) (list #t (cdr d) 'eof 64)) documents)
  (map-in-order (lambda (d) (seen (list (wrap-json-body 64)) (json-req "application/json" (car d))))
                documents))

(test-equal "the options are read-json's: exact numbers, a null of one's own, objects as hashtables"
  '((#t 3/2 eof 64) (#t #(nil) eof 64) (#t (1 . 1) eof 64))
  (list (seen (list (wrap-json-body 64 (make-json-options 'number-mode 'exact)))
              (json-req "application/json" "1.5"))
        (seen (list (wrap-json-body 64 (make-json-options 'null 'nil)))
              (json-req "application/json" "[null]"))
        (let ((table (seen (list (wrap-json-body 64 (make-json-options 'object-mode 'hashtable)))
                           (json-req "application/json" "{\"a\":1}"))))
          (list (car table)
                (let ((v (cadr table)))
                  (if (hashtable? v) (cons (hashtable-size v) (hashtable-ref v "a" #f)) v))
                (caddr table)
                (cadddr table)))))

;; refused : String -> (List (List 400 Headers String) 0)
;; The 400 for a body refused for REASON, and no handler run.
(define (refused text)
  (list (list 400 '(("content-type" . "text/plain")) text) 0))

(define malformed
  (list (list "{" "unexpected-eof at byte 1\n")
        (list "{\"a\": tru}" "unexpected-byte at byte 9\n")
        (list "{\"a\":1,}" "unexpected-byte at byte 7\n")
        (list "[1] x" "trailing-garbage at byte 4\n")
        (list "[01]" "invalid-number at byte 2\n")
        (list "\"\\u12\"" "invalid-escape at byte 5\n")
        (list (u8-list->bytevector '(34 255 34)) "invalid-utf8 at byte 1\n")
        (list (u8-list->bytevector '(34 9 34)) "control-character at byte 1\n")
        (list "\"\\uD800\"" "invalid-surrogate at byte 7\n")
        (list "  \n " "unexpected-eof at byte 4\n")
        (list (u8-list->bytevector '(#xEF #xBB #xBF 49)) "unexpected-byte at byte 0\n")))

(test-equal "a body that is no JSON is a 400, text/plain, its reason and byte offset, and the handler never runs; whitespace alone among them, and a byte order mark"
  (map (lambda (m) (refused (cadr m))) malformed)
  (map-in-order (lambda (m) (seen-ran (list (wrap-json-body 64)) (json-req "application/json" (car m))))
                malformed))

(test-equal "the depth limit, from both sides: 512 by default, and one given"
  (list (list (list #t 512 'eof 1100) 1) (refused "nesting-too-deep at byte 513\n")
        (list (list #t '#(#(1)) 'eof 64) 1) (refused "nesting-too-deep at byte 3\n"))
  (list (let ((answer (seen-ran (list (wrap-json-body 1100)) (json-req "application/json" (nested 512)))))
          (if (pair? (car answer))
              (list (list (car (car answer)) (depth (cadr (car answer))) (caddr (car answer))
                          (cadddr (car answer)))
                    (cadr answer))
              answer))
        (seen-ran (list (wrap-json-body 1100)) (json-req "application/json" (nested 513)))
        (seen-ran (list (wrap-json-body 64 (make-json-options 'depth-limit 2)))
                  (json-req "application/json" "[[1]]"))
        (seen-ran (list (wrap-json-body 64 (make-json-options 'depth-limit 2)))
                  (json-req "application/json" "[[[1]]]"))))

(test-equal "a depth limit of 0 takes a top-level scalar alone, so the options' check reads a scalar"
  (list (list (list #t 7 'eof 64) 1) (refused "nesting-too-deep at byte 1\n"))
  (let ((flat (wrap-json-body 64 (make-json-options 'depth-limit 0))))
    (list (seen-ran (list flat) (json-req "application/json" "7"))
          (seen-ran (list flat) (json-req "application/json" "[]")))))

(test-equal "the digit limit, from both sides: 1000 by default"
  (list (list (list #t (- (expt 10 1000) 1) 'eof 2000) 1) (refused "number-too-long at byte 1001\n"))
  (list (seen-ran (list (wrap-json-body 2000)) (json-req "application/json" (make-string 1000 #\9)))
        (seen-ran (list (wrap-json-body 2000)) (json-req "application/json" (make-string 1001 #\9)))))

(test-equal "the digit limit, from both sides: one given"
  (list (list (list #t 123 'eof 64) 1) (refused "number-too-long at byte 4\n"))
  (let ((wrap3 (wrap-json-body 64 (make-json-options 'digit-limit 3))))
    (list (seen-ran (list wrap3) (json-req "application/json" "123"))
          (seen-ran (list wrap3) (json-req "application/json" "1234")))))

(test-equal "the guard covers the parse alone: json-ref's not-found in the handler goes on as it was raised, and so does any &json-error the handler raises"
  '((json-error not-found #f json-ref) (json-error unwritable-number #f json->bytevector))
  (let ((app (lambda (handler) ((wrap-json-body 64) handler))))
    (list (raised (lambda () ((app (lambda (r) (json-ref (req-json r) "b")))
                              (json-req "application/json" "{\"a\":1}"))))
          (raised (lambda () ((app (lambda (r) (make-json-res 200 +nan.0)))
                              (json-req "application/json" "{\"a\":1}")))))))

(test-equal "wrap-json-body answers its handler's answer as it is"
  '(#t #t #t)
  (let ((res (make-res 200 '() "ok")))
    (list (eq? res (((wrap-json-body 64) (lambda (r) res)) (json-req "text/plain" "[1]")))
          (eq? res (((wrap-json-body 64) (lambda (r) res)) (json-req "application/json" "[1]")))
          (eq? res (((wrap-json-body 64) (lambda (r) res)) (json-req "application/json" ""))))))

(test-equal "the handler sees the cap the body was read under: the smaller of the middleware's and the request's own, a bignum among them"
  (list '(#t #(1) eof 10) '(#t #(1) eof 10) '(#t #(1) eof 64) (list #t '#(1) 'eof (expt 2 100))
        '(#t #(1) eof 3))
  (let ((at (lambda middlewares (seen middlewares (json-req "application/json" "[1]")))))
    (list (at (wrap-json-body 64) (wrap-body-cap 10))
          (at (wrap-json-body 10) (wrap-body-cap 64))
          (at (wrap-json-body 64) (wrap-body-cap #f))
          (at (wrap-json-body (expt 2 100)))
          (at (wrap-json-body (expt 2 100)) (wrap-body-cap 3)))))

(test-equal "a JSON request whose body's port was made outside it is req-with-body-cap's assertion violation, and so is a second wrap-json-body; any other request's passes"
  '((assertion-violation req-with-body-cap (64))
    (assertion-violation req-with-body-cap (64))
    (#f none eof #f))
  (let ((reading (lambda (h) (lambda (r) (get-bytevector-all (req-body r)) (h r)))))
    (list (raised (lambda () (seen (list (wrap-json-body 64) reading) (json-req "application/json" "[1]"))))
          (raised (lambda () (seen (list (wrap-json-body 64) (wrap-json-body 100))
                                   (json-req "application/json" "[1]"))))
          (seen (list (wrap-json-body 64) reading) (json-req "text/plain" "[1]")))))

(test-equal "a cap inside wrap-json-body comes after the body is read: req-with-body-cap's assertion violation for JSON, and the cap as given for any other request"
  (list '(assertion-violation req-with-body-cap (16)) '(#f none "[1]" 16))
  (list (raised (lambda () (seen (list (wrap-body-cap 16) (wrap-json-body 64)) (json-req "application/json" "[1]"))))
        (seen (list (wrap-body-cap 16) (wrap-json-body 64)) (json-req "text/plain" "[1]"))))

;;; ------------------------------------------------------------------------
;;; make-json-res

;; res-shown : Res -> (List Integer Headers String)
(define (res-shown res) (shown res))

(test-equal "make-json-res: the status, application/json alone, and the value's UTF-8, compact"
  '((200 (("content-type" . "application/json")) "{\"a\":[1,2.5,true,null],\"b\":\"\xE9;\"}")
    (201 (("content-type" . "application/json")) "false")
    (404 (("content-type" . "application/json")) "null")
    (200 (("content-type" . "application/json")) "[]"))
  (list (res-shown (make-json-res 200 value))
        (res-shown (make-json-res 201 #f))
        (res-shown (make-json-res 404 'null))
        (res-shown (make-json-res 200 '#()))))

(test-equal "make-json-res writes under the options given: an indent, a null of one's own"
  '((200 (("content-type" . "application/json")) "{\n  \"a\": [\n    1\n  ]\n}")
    (200 (("content-type" . "application/json")) "[null]"))
  (list (res-shown (make-json-res 200 '(("a" . #(1))) (make-json-options 'indent 2)))
        (res-shown (make-json-res 200 '#(nil) (make-json-options 'null 'nil)))))

(test-equal "a value JSON can't express is jsonparse's &json-error, raised at the call"
  '((json-error unwritable-number #f json->bytevector)
    (json-error unwritable-value #f json->bytevector))
  (list (raised (lambda () (make-json-res 200 +nan.0)))
        (raised (lambda () (make-json-res 200 (list 'x))))))

;;; ------------------------------------------------------------------------
;;; The refusals

(test-equal "wrap-json-body refuses a cap that is no count of bytes, #f among them, and options that are no record, when it is called, and a handler that is no procedure when it is applied"
  '((assertion-violation wrap-json-body (-1))
    (assertion-violation wrap-json-body (1.5))
    (assertion-violation wrap-json-body (4.))
    (assertion-violation wrap-json-body (3/2))
    (assertion-violation wrap-json-body ("4"))
    (assertion-violation wrap-json-body (#f))
    (assertion-violation wrap-json-body (not-options))
    (assertion-violation wrap-json-body (not-a-handler))
    "a cap is a count of bytes"
    "options are a record make-json-options made")
  (append (map (lambda (cap) (raised (lambda () (wrap-json-body cap)))) (list -1 1.5 4. 3/2 "4" #f))
          (list (raised (lambda () (wrap-json-body 4 'not-options)))
                (raised (lambda () ((wrap-json-body 4) 'not-a-handler)))
                (raised-message (lambda () (wrap-json-body #f)))
                (raised-message (lambda () (wrap-json-body 4 'not-options))))))

(test-equal "wrap-json-body refuses, when it is called, options read-json refuses, a stream of many values: its own who and words, then read-json's, and the options"
  '(wrap-json-body "read-json refuses these options: " #t #t)
  (let ((options (make-json-options 'stream 'values))
        (prefix "read-json refuses these options: "))
    (guard (e ((assertion-violation? e)
               (let ((message (condition-message e)))
                 (list (condition-who e)
                       (substring message 0 (min (string-length prefix) (string-length message)))
                       (> (string-length message) (string-length prefix))
                       (equal? (condition-irritants e) (list options)))))
              (#t (list 'other-raise (describe e))))
      (wrap-json-body 4 options)
      'no-raise)))

(test-equal "req-json? and req-json refuse what is no request"
  '((assertion-violation req-json? (not-a-request))
    (assertion-violation req-json (not-a-request)))
  (list (raised (lambda () (req-json? 'not-a-request)))
        (raised (lambda () (req-json 'not-a-request)))))

(test-equal "make-json-res refuses options that are no record, and make-res a status that is no integer"
  '((assertion-violation make-json-res (not-options))
    (assertion-violation make-res ("200")))
  (list (raised (lambda () (make-json-res 200 '#() 'not-options)))
        (raised (lambda () (make-json-res "200" '#())))))

;;; ------------------------------------------------------------------------
;;; Through the server's test host

;; text : Bytevector -> String — BV one character a byte.
(define (text bv)
  (let* ((n (bytevector-length bv)) (s (make-string n)))
    (for-each (lambda (i) (string-set! s i (integer->char (bytevector-u8-ref bv i)))) (iota n))
    s))

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

(define json-field "Content-Type: application/json")

;; json-post : String -> String — a POST of BODY, its length declared.
(define (json-post body)
  (string-append "POST /up HTTP/1.1\r\nHost: x\r\n" json-field "\r\nContent-Length: "
                 (number->string (string-length body)) "\r\n\r\n" body))

;; chunked-json-post : String ... -> String — a POST of PIECES, chunked.
(define (chunked-json-post . pieces)
  (string-append "POST /up HTTP/1.1\r\nHost: x\r\n" json-field "\r\nTransfer-Encoding: chunked\r\n\r\n"
                 (apply string-append
                        (map (lambda (p) (string-append (number->string (string-length p) 16) "\r\n" p "\r\n"))
                             pieces))
                 "0\r\n\r\n"))

;; json-echo : Middleware ... -> Handler
;; An app that answers the value it was handed, written, inside
;; MIDDLEWARES, or 204 when it was handed none.
(define (json-echo . middlewares)
  (apply wrap
         (lambda (r)
           (set! ran (+ ran 1))
           (if (req-json? r) (make-json-res 200 (req-json r)) (make-res 204 '() #f)))
         middlewares))

;; ran-exchange : Handler String [Env] -> (List Exchange Nat)
;; The exchange, and how many times the handler ran in it.
(define (ran-exchange app request . env)
  (set! ran 0)
  (let ((ex (apply exchange app request env)))
    (list ex ran)))

(define (echoed body)
  (list (list (list (response "200 OK" (list "content-type: application/json" (length-field (string-length body)))
                              body))
              #f '())
        1))

;; A body past a cap: 413, the connection ended, the server's refusal
;; logged with the test host's "-" for the client's address, and no
;; handler run.
(define too-large
  (list (list (list (response "413 Content Too Large" '("Content-Length: 0" "Connection: close") ""))
              #t
              '((request-refused 413 body-too-large "-")))
        0))

(test-equal "through the server: a JSON body is read and answered, and a body that is no JSON a 400 with its reason, no handler run"
  (list (echoed "{\"a\":[1,2]}")
        (list (list (list (response "400 Bad Request" (list "content-type: text/plain" (length-field 26))
                                    "unexpected-byte at byte 9\n"))
                    #f '())
              0))
  (list (ran-exchange (json-echo (wrap-json-body 64)) (json-post "{\"a\": [1, 2]}"))
        (ran-exchange (json-echo (wrap-json-body 64)) (json-post "{\"a\": tru}"))))

(define bad-long (json-post (string-append "[x" (make-string 20000 #\space) "]")))

(define bad-400
  (response "400 Bad Request" (list "content-type: text/plain" (length-field 26)) "unexpected-byte at byte 1\n"))

;; split-exchange : Handler String Nat String -> (List (Listof String) Boolean (Listof String) Boolean Nat)
;; One client sends the first CUT characters of REQUEST, then the rest and
;; NEXT: what it read and whether the connection had ended, after each, and
;; how many times the handler ran.
(define (split-exchange app request cut next)
  (set! ran 0)
  (let* ((host (make-test-host (circuit->handler app unset) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (substring request 0 cut)))
    (let* ((before (wire c))
           (closed (test-client-connection-closed? c)))
      (test-client-send! c (b (string-append (substring request cut (string-length request)) next)))
      (list before closed (wire c) (test-client-connection-closed? c) ran))))

(test-equal "through the server: a body that is no JSON in its first 16 KiB is a 400 once those 16 KiB are in, not before. With the rest already in when the request is read, the server reads past it and answers the next request; when the rest comes after, it ends the connection"
  (list (list (list bad-400) #f (list bad-400 (response "200 OK" (list "content-type: application/json" (length-field 3)) "[1]"))
              #f 1)
        (list (list (response "400 Bad Request"
                              (list "content-type: text/plain" (length-field 26) "Connection: close")
                              "unexpected-byte at byte 1\n"))
              #t
              (list (response "400 Bad Request"
                              (list "content-type: text/plain" (length-field 26) "Connection: close")
                              "unexpected-byte at byte 1\n"))
              #t 0)
        (list '() #f
              (list (response "400 Bad Request"
                              (list "content-type: text/plain" (length-field 26) "Connection: close")
                              "unexpected-byte at byte 1\n"))
              #t 0))
  (let ((app (json-echo (wrap-json-body 65536))))
    (list (split-exchange app bad-long (string-length bad-long) (json-post "[1]"))
          (split-exchange app bad-long (- (string-length bad-long) 3000) (json-post "[1]"))
          (split-exchange app bad-long 100 (json-post "[1]")))))

(test-equal "through the server: a body at the cap is read, one byte past it refused 413 before the handler runs, declared or chunked"
  (list (echoed "[123]") too-large too-large (echoed "[123]"))
  (let ((app (json-echo (wrap-json-body 5))))
    (list (ran-exchange app (json-post "[123]"))
          (ran-exchange app (json-post "[1234]"))
          (ran-exchange app (chunked-json-post "[12" "34]"))
          (ran-exchange app (chunked-json-post "[1" "23]")))))

(test-equal "a declared Content-Length past the cap, with Expect: 100-continue, is refused at the first read, with no 100 Continue"
  too-large
  (ran-exchange (json-echo (wrap-json-body 5))
                (string-append "POST /up HTTP/1.1\r\nHost: x\r\n" json-field
                               "\r\nExpect: 100-continue\r\nContent-Length: 6\r\n\r\n")))

(test-equal "the smallest cap wins: the request's own under the middleware's, the middleware's under the request's, the server's under both"
  (list too-large (echoed "[12]") too-large too-large)
  (list (ran-exchange (json-echo (wrap-json-body 100) (wrap-body-cap 4)) (json-post "[123]"))
        (ran-exchange (json-echo (wrap-json-body 100) (wrap-body-cap 4)) (json-post "[12]"))
        (ran-exchange (json-echo (wrap-json-body 4) (wrap-body-cap 100)) (json-post "[123]"))
        (ran-exchange (json-echo (wrap-json-body 100) (wrap-body-cap #f)) (chunked-json-post "[1" "23]")
                      (settings "CHEZ_HTTP_MAX_BODY_BYTES" "4"))))

(test-equal "a cap of 0: an empty body is no JSON, the handler's 204, and one byte is past it, 413"
  (list (list (list (list (response "204 No Content" '() "")) #f '()) 1) too-large)
  (list (ran-exchange (json-echo (wrap-json-body 0)) (json-post ""))
        (ran-exchange (json-echo (wrap-json-body 0)) (json-post "1"))))

(test-equal "a bignum cap reads a body, and an empty one is no JSON: the handler's 204"
  (list (echoed "[123]")
        (list (list (list (response "204 No Content" '() "")) #f '()) 1))
  (list (ran-exchange (json-echo (wrap-json-body (expt 2 100))) (json-post "[123]"))
        (ran-exchange (json-echo (wrap-json-body 64)) (json-post ""))))

(test-equal "through the server, a cap inside wrap-json-body makes every JSON body a 500, the handler never run"
  (list (list (list (response "500 Internal Server Error" '("Content-Length: 0" "Connection: close") ""))
              #t
              '((handler-failed "Exception in req-with-body-cap: the body's port is made, and its cap with it: give the cap before anything reads the body with irritant 16")))
        0)
  (ran-exchange (json-echo (wrap-body-cap 16) (wrap-json-body 64)) (json-post "[1]")))

(test-equal "through the server, json-ref's not-found in the handler is the handler's raise: a 500, not a 400"
  '(("HTTP/1.1 500 Internal Server Error\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    #t (handler-failed) 1)
  (begin
    (set! ran 0)
    (let ((ex (exchange (wrap (lambda (r) (set! ran (+ ran 1)) (make-json-res 200 (json-ref (req-json r) "b")))
                              (wrap-json-body 64))
                        (json-post "{\"a\": 1}"))))
      (list (car ex) (cadr ex) (map car (caddr ex)) ran))))

;; numbers : Nat -> String — the array of 0 to N - 1, compact.
(define (numbers n)
  (call-with-string-output-port
   (lambda (out)
     (put-string out "[")
     (for-each (lambda (i) (when (> i 0) (put-string out ",")) (put-string out (number->string i))) (iota n))
     (put-string out "]"))))

;; pieces-of : String Nat -> (Listof String) — S in pieces of N characters, the last shorter.
(define (pieces-of s n)
  (let loop ((i 0) (out '()))
    (if (>= i (string-length s))
        (reverse out)
        (loop (+ i n) (cons (substring s i (min (string-length s) (+ i n))) out)))))

(define long-array (numbers 5000))

(test-equal "a document in pieces is read whole: pieces split inside a string, a key and a number, and one past read-json's 16 KiB step, chunked and declared"
  (list (echoed "{\"name\":\"Ada\",\"n\":1234}") (echoed long-array) (echoed long-array))
  (list (ran-exchange (json-echo (wrap-json-body 64))
                      (chunked-json-post "{\"na" "me\": \"Ad" "a\", \"n\": 12" "34}"))
        (ran-exchange (json-echo (wrap-json-body 65536)) (apply chunked-json-post (pieces-of long-array 1000)))
        (ran-exchange (json-echo (wrap-json-body 65536)) (json-post long-array))))

(test-equal "long-array is past read-json's 16 KiB step"
  #t
  (> (string-length long-array) 16384))

;; stalled : Handler Nat -> (List (Listof String) (Listof String) Nat)
;; A JSON body whose head and first three bytes arrive, then nothing for MS
;; milliseconds, then the rest: what the client read before the rest came,
;; after it, and how many times the handler ran.
(define (stalled app ms)
  (set! ran 0)
  (let* ((host (make-test-host (circuit->handler app unset) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (string-append "POST /up HTTP/1.1\r\nHost: x\r\n" json-field
                                           "\r\nContent-Length: 5\r\n\r\n[12")))
    (test-host-advance! host ms)
    (let ((before (wire c)))
      (test-client-send! c (b "3]"))
      (list before (wire c) ran))))

(test-equal "a body that arrives in two pieces is read whole: nothing is answered until the last byte is in"
  (list '() (list (response "200 OK" (list "content-type: application/json" (length-field 5)) "[123]")) 1)
  (stalled (json-echo (wrap-json-body 64)) 50))

(test-equal "wrap-timeout outside it covers a client that stalls mid-body: 504 at the deadline, the handler never run"
  (list (list (response "504 Gateway Timeout" '("Content-Length: 0" "Connection: close") ""))
        (list (response "504 Gateway Timeout" '("Content-Length: 0" "Connection: close") ""))
        0)
  (stalled (json-echo (wrap-json-body 64) (wrap-timeout 100)) 100))

(exit (suite-exit-status runner))
