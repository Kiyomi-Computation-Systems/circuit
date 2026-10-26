#!r6rs
;;; (circuit test): make-test-req's view, the re-exported test-req-done!,
;;; and res-body->bytevector reading every body kind as the adapter sends
;;; it.
;;;
;;; A value that can be #f or '() is asserted behind a tag, since SRFI-64
;;; turns a raise into #f. Producers that note each call show whether a
;;; read asked past a length.
(import (rnrs)
        (srfi :64)
        (only (chezscheme) port-closed?)
        (circuit-testing)
        (circuit request)
        (prefix (only (circuit request) test-req-done!) request:)
        (circuit response)
        (circuit test))

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

;; answer : (-> Any) -> (List 'answer Any) | (List 'raised String)
(define (answer thunk)
  (guard (e (#t (list 'raised (describe e))))
    (list 'answer (thunk))))

(define the-log '())
(define (note! x) (set! the-log (cons x the-log)))
(define (take-log!)
  (let ((taken (reverse the-log)))
    (set! the-log '())
    taken))

;; snapshot : Req -> (Listof Any)
;; Every accessor's answer but the headers' and the body's.
(define (snapshot r)
  (list (req-method r) (req-scheme r) (req-host r) (req-path r) (req-query r)
        (req-http-version r) (req-remote-address r) (req-remote-port r)
        (req-local-address r) (req-local-port r)))

;; pieces : Symbol String ... -> Producer
;; Each string's bytes in turn, each call noted as (asked NAME); a call past
;; them is noted (asked-past NAME) and answers more bytes.
(define (pieces name . texts)
  (let ((left (map string->utf8 texts)))
    (lambda ()
      (if (null? left)
          (begin (note! (list 'asked-past name)) (string->utf8 "XYZ"))
          (let ((piece (car left)))
            (set! left (cdr left))
            (note! (list 'asked name))
            piece)))))

;; ending-with-eof : Any ... -> Producer
;; Each piece as given, a string as its bytes, then eof forever.
(define (ending-with-eof . given)
  (let ((left given))
    (lambda ()
      (if (null? left)
          (eof-object)
          (let ((piece (car left)))
            (set! left (cdr left))
            (if (string? piece) (string->utf8 piece) piece))))))

;; recording-port : Bytevector -> (Values BinaryInputPort (-> (List (Listof Nat) Nat)))
;; A port over BYTES, and a thunk answering how many bytes each of its reads
;; asked for, in order, and how many it has handed out.
(define (recording-port bytes)
  (let ((pos 0) (asked '()))
    (values
     (make-custom-binary-input-port
      "recording"
      (lambda (bv start count)
        (set! asked (cons count asked))
        (let ((n (min count (- (bytevector-length bytes) pos))))
          (bytevector-copy! bytes pos bv start n)
          (set! pos (+ pos n))
          n))
      #f #f #f)
     (lambda () (list (reverse asked) pos)))))

(define (per-piece g)
  (lambda (producer)
    (lambda ()
      (let ((x (producer)))
        (if (eof-object? x) x (g x))))))

(define (upcase-bytes bv) (string->utf8 (string-upcase (utf8->string bv))))

(define (res-of body) (make-res 200 '() body))
(define (wrapped body f same?) (res-body (res-wrap-body (res-of body) f same?)))
(define (other-wrap body) (wrapped body (lambda (p) p) #f))

(define digits (string->utf8 "0123456789"))
(define e-acute (string (integer->char #xE9)))

(test-begin "test")

;; --- make-test-req ----------------------------------------------------------------

(test-equal "make-test-req: the method, http, the host header's value, the target split at ?, HTTP/1.1, no addresses"
  '(PATCH http "example.test:8080" "/a/b" "x=1&y" (1 . 1) #f #f #f #f)
  (snapshot (make-test-req 'PATCH "/a/b?x=1&y"
                           (list (cons "X-Before" "1") (cons "Host" "example.test:8080")))))

(test-equal "make-test-req splits the target at its first ?, wherever it stands"
  '(("/" "abc") ("/a" "bc") ("/ab" "c") ("/abc" "") ("/abc" (no-query)) ("/a" "b?c"))
  (map (lambda (target)
         (let ((r (make-test-req 'GET target)))
           (list (req-path r) (or (req-query r) '(no-query)))))
       '("/?abc" "/a?bc" "/ab?c" "/abc?" "/abc" "/a?b?c")))

(test-equal "make-test-req refuses a target that does not begin with /: absolute-form and asterisk-form are the server's test host's"
  '((assertion-violation make-test-req ("http://example.test/x?q"))
    (assertion-violation make-test-req ("*"))
    (assertion-violation make-test-req ("example.test:443"))
    (assertion-violation make-test-req (""))
    (assertion-violation make-test-req ("x/y"))
    (assertion-violation make-test-req ("?q=/")))
  (map (lambda (target) (raised (lambda () (make-test-req 'GET target))))
       '("http://example.test/x?q" "*" "example.test:443" "" "x/y" "?q=/")))

;; Latin-1 characters the server keeps in a value, and that Unicode counts
;; as white space: no-break space and next line.
(define nbsp (string (integer->char #xA0)))
(define nel (string (integer->char #x85)))

(test-equal "a header value is read without the SP and HTAB around it, as the server reads it, the host's included"
  (list "host.test" "a  b" '("a  b" "")
        (list (cons "host" "host.test") (cons "x-a" "a  b") (cons "x-a" "")
              (cons "x-n" (string-append nbsp "n" nbsp)) (cons "x-e" (string-append nel "e" nel)))
        (string-append nbsp "n" nbsp))
  (let ((r (make-test-req 'GET "/" (list (cons "Host" " \t host.test \t")
                                         (cons "X-A" "  a  b  ")
                                         (cons "x-a" "\t")
                                         (cons "X-N" (string-append nbsp "n" nbsp))
                                         (cons "X-E" (string-append nel "e" nel))))))
    (list (req-host r) (req-header r "x-a") (req-header-values r "X-A") (req-headers r)
          (req-header r "x-n"))))

(test-equal "the host is the first host field's value, in any case, or \"\" without one"
  '("first.test" "")
  (list (req-host (make-test-req 'GET "/" '(("X" . "1") ("HOST" . "first.test")
                                            ("host" . "second.test"))))
        (req-host (make-test-req 'GET "/" '(("X-Host" . "not.this"))))))

(test-equal "headers: names folded to lower case, in order; lookups in any case"
  '((("accept" . "a/1") ("x-dup" . "1") ("x-dup" . "2") ("x-dup" . "3"))
    "1" ("1" "2" "3") (answer #f) (answer ()))
  (let ((r (make-test-req 'GET "/" '(("Accept" . "a/1") ("X-Dup" . "1") ("x-dup" . "2")
                                     ("X-DUP" . "3")))))
    (list (req-headers r) (req-header r "x-DUP") (req-header-values r "X-Dup")
          (answer (lambda () (req-header r "missing")))
          (answer (lambda () (req-header-values r "missing"))))))

(test-equal "without headers: none, and the host \"\""
  '((answer ()) "")
  (let ((r (make-test-req 'DELETE "/x")))
    (list (answer (lambda () (req-headers r))) (req-host r))))

(test-equal "a bytevector body reads back as given; a string body as its UTF-8"
  (list (string->utf8 "raw bytes") (string->utf8 (string-append "caf" e-acute)))
  (list (get-bytevector-all (req-body (make-test-req 'POST "/" '() (string->utf8 "raw bytes"))))
        (get-bytevector-all (req-body (make-test-req 'POST "/" '() (string-append "caf" e-acute))))))

(test-equal "with no body, and with #f, the body reads eof at once"
  '(#t #t)
  (list (eof-object? (get-u8 (req-body (make-test-req 'GET "/"))))
        (eof-object? (get-u8 (req-body (make-test-req 'GET "/" '() #f))))))

(test-equal "a test request's body is one port for every copy"
  '(#t #t)
  (let* ((r (make-test-req 'POST "/" '() "once"))
         (port (req-body (req-set r (make-req-key 'k) 1))))
    (list (eq? port (req-body r)) (eq? port (req-body (req-with-path r "/other"))))))

(test-equal "a test request keeps its on-done procedures, and test-req-done! calls them newest first"
  '((answer ()) ((second failed) (first failed)))
  (begin
    (take-log!)
    (let ((r (make-test-req 'GET "/")))
      (req-on-done! r (lambda (ending) (note! (list 'first ending))))
      (req-on-done! (req-set r (make-req-key 'k) 1) (lambda (ending) (note! (list 'second ending))))
      (let ((result (answer (lambda () (test-req-done! r 'failed)))))
        (list result (take-log!))))))

(test-equal "(circuit test)'s test-req-done! is (circuit request)'s"
  #t
  (eq? test-req-done! request:test-req-done!))

(test-equal "make-test-req refuses a method that is no symbol, a target that is no string, and headers that are no header list"
  '((assertion-violation make-test-req ("GET"))
    (assertion-violation make-test-req (/x))
    (assertion-violation make-test-req (x))
    (assertion-violation make-test-req (("a" . 1)))
    (assertion-violation make-test-req ((a . "1")))
    (assertion-violation make-test-req ((("a" . "1") . rest))))
  (list (raised (lambda () (make-test-req "GET" "/")))
        (raised (lambda () (make-test-req 'GET '/x)))
        (raised (lambda () (make-test-req 'GET "/" 'x)))
        (raised (lambda () (make-test-req 'GET "/" '(("a" . 1)))))
        (raised (lambda () (make-test-req 'GET "/" '((a . "1")))))
        (raised (lambda () (make-test-req 'GET "/" '(("a" . "1") . rest))))))

(test-equal "make-test-req refuses a body that is neither #f, a bytevector nor a string"
  '((assertion-violation make-test-req (5)) (assertion-violation make-test-req (sym)) #t)
  (let ((text (open-string-input-port "text")))
    (list (raised (lambda () (make-test-req 'POST "/" '() 5)))
          (raised (lambda () (make-test-req 'POST "/" '() 'sym)))
          (equal? (raised (lambda () (make-test-req 'POST "/" '() text)))
                  (list 'assertion-violation 'make-test-req (list text))))))

;; --- res-body->bytevector ------------------------------------------------------------

(test-equal "res-body->bytevector: #f, \"\" and an empty bytevector are no bytes"
  '(#vu8() #vu8() #vu8())
  (map (lambda (body) (res-body->bytevector (res-of body))) (list #f "" #vu8())))

(test-equal "res-body->bytevector: a bytevector as given, a string as its UTF-8"
  (list digits (string->utf8 (string-append "caf" e-acute)))
  (list (res-body->bytevector (res-of digits))
        (res-body->bytevector (res-of (string-append "caf" e-acute)))))

(test-equal "res-body->bytevector: a producer's pieces, to its eof"
  (string->utf8 "abcde")
  (res-body->bytevector (res-of (ending-with-eof "ab" "cd" "e"))))

(test-equal "res-body->bytevector: a bare bytevector port, measured, read to its length and closed"
  (list digits #t)
  (let* ((port (open-bytevector-input-port digits))
         (bytes (res-body->bytevector (res-of port))))
    (list bytes (port-closed? port))))

(test-equal "res-body->bytevector reads a port in pieces of 65,536 bytes"
  '(70000 (65536 4464))
  (begin
    (take-log!)
    (let* ((sizes (lambda (producer)
                    (lambda ()
                      (let ((x (producer)))
                        (unless (eof-object? x) (note! (bytevector-length x)))
                        x))))
           (bytes (res-body->bytevector
                   (res-of (wrapped (open-bytevector-input-port (make-bytevector 70000 7))
                                    sizes #f)))))
      (list (bytevector-length bytes) (take-log!)))))

(test-equal "res-body->bytevector: a sized port to its length, read no further, closed there"
  (list (string->utf8 "01234") '((5) 5) #t)
  (let-values (((port reads) (recording-port digits)))
    (let ((bytes (res-body->bytevector (res-of (make-sized-body 5 port)))))
      (list bytes (reads) (port-closed? port)))))

(test-equal "res-body->bytevector: a sized producer to its length, never asked past it"
  (list (string->utf8 "abcde") '((asked inner) (asked inner)))
  (begin
    (take-log!)
    (let ((bytes (res-body->bytevector (res-of (make-sized-body 5 (pieces 'inner "abc" "de"))))))
      (list bytes (take-log!)))))

(test-equal "res-body->bytevector: a sized body of 0 never calls its producer"
  (list #vu8() '())
  (begin
    (take-log!)
    (let ((bytes (res-body->bytevector (res-of (make-sized-body 0 (pieces 'inner "abc"))))))
      (list bytes (take-log!)))))

(test-equal "res-body->bytevector: a sized body that runs long is refused, naming both counts"
  '(assertion-violation res-body->bytevector (4 5))
  (raised (lambda () (res-body->bytevector (res-of (make-sized-body 4 (ending-with-eof "abc" "de")))))))

(test-equal "res-body->bytevector: a sized body that ends short is refused, naming both counts"
  '(assertion-violation res-body->bytevector (6 5))
  (raised (lambda () (res-body->bytevector (res-of (make-sized-body 6 (ending-with-eof "abc" "de")))))))

(test-equal "res-body->bytevector: a sized port that ends short is refused, naming both counts"
  '(assertion-violation res-body->bytevector (12 10))
  (raised (lambda () (res-body->bytevector
                      (res-of (make-sized-body 12 (open-bytevector-input-port digits)))))))

(test-equal "res-body->bytevector refuses a piece that is no bytevector, and an empty piece"
  '((assertion-violation res-body->bytevector (text))
    (assertion-violation res-body->bytevector (#vu8()))
    (assertion-violation res-body->bytevector (#vu8())))
  (list (raised (lambda () (res-body->bytevector (res-of (ending-with-eof "ab" 'text)))))
        (raised (lambda () (res-body->bytevector (res-of (ending-with-eof "ab" #vu8())))))
        (raised (lambda () (res-body->bytevector (res-of (make-sized-body 3 (ending-with-eof #vu8()))))))))

(test-equal "res-body->bytevector: a wrap that drops a length stops at it, never asking the inner producer again"
  (list (string->utf8 "abcde") '((asked inner) (asked inner)))
  (begin
    (take-log!)
    (let ((bytes (res-body->bytevector
                  (res-of (other-wrap (make-sized-body 5 (pieces 'inner "abc" "de")))))))
      (list bytes (take-log!)))))

(test-equal "res-body->bytevector: a wrap that drops a length raises at a piece past it"
  '(assertion-violation res-body-stream (4 5))
  (raised (lambda () (res-body->bytevector
                      (res-of (other-wrap (make-sized-body 4 (ending-with-eof "abc" "de"))))))))

(test-equal "res-body->bytevector: a wrap that keeps the bytes is read to the length, f's producer never asked past it"
  (list (string->utf8 "ABCDE") '((asked inner) (asked inner)))
  (begin
    (take-log!)
    (let ((bytes (res-body->bytevector
                  (res-of (wrapped (make-sized-body 5 (pieces 'inner "abc" "de"))
                                   (per-piece upcase-bytes) #t)))))
      (list bytes (take-log!)))))

(test-equal "a counter that reports only at eof never reports under a sized body, as in production"
  (list (string->utf8 "abcde") 'unreported)
  (let* ((total 'unreported)
         (counter (lambda (producer)
                    (let ((count 0))
                      (lambda ()
                        (let ((x (producer)))
                          (if (eof-object? x)
                              (begin (set! total count) x)
                              (begin (set! count (+ count (bytevector-length x))) x)))))))
         (bytes (res-body->bytevector
                 (res-of (wrapped (make-sized-body 5 (ending-with-eof "abc" "de")) counter #t)))))
    (list bytes total)))


;; --- res-body->bytevector measures a port as the adapter will -------------------------------

;; counted : Body -> (List String Any)
;; BODY read under a counter that keeps the bytes and reports its total only
;; at eof: the bytes as text, and the total, or unreported.
(define (counted body)
  (let* ((total 'unreported)
         (counter (lambda (producer)
                    (let ((count 0))
                      (lambda ()
                        (let ((x (producer)))
                          (if (eof-object? x)
                              (begin (set! total count) x)
                              (begin (set! count (+ count (bytevector-length x))) x)))))))
         (bytes (res-body->bytevector (res-of (wrapped body counter #t)))))
    (list (utf8->string bytes) total)))

;; positioned-port : Bytevector Boolean Boolean [Bytevector] -> BinaryInputPort
;; A custom port over BYTES, with a get-position procedure when GET?, and a
;; set-position! one when SET?. Given GROWN, the port holds GROWN from its
;; first set-position! on, as a file that grows once it has been measured.
(define (positioned-port bytes get? set? . grown)
  (let ((data bytes) (pos 0))
    (make-custom-binary-input-port
     "positioned"
     (lambda (bv start count)
       (let ((n (min count (- (bytevector-length data) pos))))
         (bytevector-copy! data pos bv start n)
         (set! pos (+ pos n))
         n))
     (and get? (lambda () pos))
     (and set? (lambda (p)
                 (set! pos p)
                 (unless (null? grown) (set! data (car grown)))))
     #f)))

(test-equal "a counter that keeps the bytes over a bytevector port never sees eof, as in production"
  '("0123456789" unreported)
  (counted (open-bytevector-input-port digits)))

(test-equal "a port is measured from its position: after a get-u8, the rest, and no eof asked for"
  '("123456789" unreported)
  (let ((port (open-bytevector-input-port digits)))
    (get-u8 port)
    (counted port)))

(test-equal "a wrap without same? over a bytevector port stops at its length: the port closed with its last byte"
  '(("0123456789" #t) (eof #t))
  (begin
    (take-log!)
    (let* ((port (open-bytevector-input-port digits))
           (watch (lambda (producer)
                    (lambda ()
                      (let ((x (producer)))
                        (note! (list (if (eof-object? x) 'eof (utf8->string x))
                                     (port-closed? port)))
                        x)))))
      (res-body->bytevector (res-of (wrapped port watch #f)))
      (take-log!))))

(test-equal "a custom port is measured only when it has both position procedures; the rest are read to their eof"
  '(("0123456789" 10) ("0123456789" 10) ("0123456789" 10) ("0123456789" unreported))
  (list (counted (positioned-port digits #f #f))
        (counted (positioned-port digits #t #f))
        (counted (positioned-port digits #f #t))
        (counted (positioned-port digits #t #t))))

(test-equal "a port that grows once measured goes out as long as it was"
  (string->utf8 "0123456789")
  (res-body->bytevector
   (res-of (positioned-port digits #t #t (string->utf8 "0123456789ABCDE")))))

;; --- res-body->bytevector refuses its request's own body ---------------------------------------

(test-equal "given its request, res-body->bytevector refuses a body that holds the request's body port, bare, sized or wrapped"
  '(#t #t #t #f "hello")
  (let* ((req (make-test-req 'POST "/echo" '() "hello"))
         (port (req-body req))
         (refused? (lambda (body)
                     (equal? (raised (lambda () (res-body->bytevector (res-of body) req)))
                             (list 'assertion-violation 'res-body->bytevector (list port))))))
    (let* ((sized (refused? (make-sized-body 5 port)))
           (bare (refused? port))
           (wrap (refused? (wrapped (make-sized-body 5 port) (lambda (q) q) #t))))
      (list sized bare wrap (port-closed? port) (utf8->string (get-bytevector-all port))))))

(test-equal "another request's body port is read as any port is"
  (string->utf8 "theirs")
  (let ((mine (make-test-req 'POST "/" '() "mine"))
        (theirs (make-test-req 'POST "/" '() "theirs")))
    (req-body mine)
    (res-body->bytevector (res-of (req-body theirs)) mine)))

(test-equal "without the request, the echo is read as before"
  (string->utf8 "hello")
  (let ((req (make-test-req 'POST "/echo" '() "hello")))
    (res-body->bytevector (res-of (make-sized-body 5 (req-body req))))))

(test-equal "a request whose body port was never made skips the check, and makes none"
  '("plain" (answer #f))
  (let ((req (make-test-req 'POST "/" '() "unread")))
    (list (utf8->string (res-body->bytevector (res-of "plain") req))
          (answer (lambda () (req-body-made req))))))

(test-equal "res-body->bytevector refuses a request that is not one"
  '(assertion-violation res-body->bytevector (not-a-req))
  (raised (lambda () (res-body->bytevector (res-of "x") 'not-a-req))))

(test-equal "res-body->bytevector refuses what is not a response"
  '(assertion-violation res-body->bytevector ("body"))
  (raised (lambda () (res-body->bytevector "body"))))

(test-end "test")

(exit (suite-exit-status runner))
