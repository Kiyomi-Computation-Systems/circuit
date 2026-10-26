#!r6rs
;;; (circuit response): make-res and its refusals, the header helpers,
;;; res-with-status, res-with-body's closing, the sized and wrapped bodies,
;;; res-body-length, res-body-port, and res-body-stream for every body kind.
;;;
;;; A producer is drained a fixed number of calls, each answer shown as its
;;; text or eof, so a body that ends early, runs on, or answers an empty
;;; piece shows it. Ports that count bytes are custom ports that log how
;;; much each read asked for and how much they handed out. Whether a port
;;; is closed is Chez's port-closed?.
(import (rnrs)
        (srfi :64)
        (only (chezscheme) port-closed?)
        (circuit-testing)
        (circuit response))

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

;; The log, for calls whose count or order matters.
(define the-log '())
(define (note! x) (set! the-log (cons x the-log)))
(define (take-log!)
  (let ((taken (reverse the-log)))
    (set! the-log '())
    taken))

;; shown : Any -> Any
;; A piece as its text, eof as the symbol eof, anything else tagged.
(define (shown x)
  (cond ((eof-object? x) 'eof)
        ((bytevector? x) (utf8->string x))
        (else (list 'not-a-piece x))))

;; drain : Producer Nat -> (Listof Any)
;; PRODUCER's first CALLS answers, in order, each shown.
(define (drain producer calls)
  (let loop ((i 0) (acc '()))
    (if (= i calls)
        (reverse acc)
        (let ((x (producer)))
          (loop (+ i 1) (cons (shown x) acc))))))

;; drain-watching : Producer Port Nat -> (Listof (List Any Boolean))
;; As drain, with whether PORT is closed after each call.
(define (drain-watching producer port calls)
  (let loop ((i 0) (acc '()))
    (if (= i calls)
        (reverse acc)
        (let ((x (producer)))
          (loop (+ i 1) (cons (list (shown x) (port-closed? port)) acc))))))

;; body-stream : Body (Port -> (U Nat #f)) Nat -> (Values Producer (U Nat #f))
;; res-body-stream with an on-port that does nothing.
(define (body-stream body measure size)
  (res-body-stream body measure ignore-port size))

(define (ignore-port port) #f)

;; streamed : Body (Port -> (U Nat #f)) Nat Nat -> (List (Listof Any) (U Nat #f))
;; res-body-stream's producer, drained CALLS times, and its length.
(define (streamed body measure size calls)
  (let-values (((producer length) (body-stream body measure size)))
    (list (drain producer calls) length)))

(define no-length (lambda (port) #f))

(define digits (string->utf8 "0123456789"))
(define (digits-port) (open-bytevector-input-port digits))

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

;; pieces : String ... -> Producer
;; A producer answering each string's bytes in turn, then eof. A call past
;; its eof is noted as (asked-past NAME) and answers more bytes, so a
;; caller that asks again shows it.
(define (pieces name . texts)
  (let ((left (map string->utf8 texts)))
    (lambda ()
      (if (null? left)
          (begin (note! (list 'asked-past name)) (string->utf8 "XYZ"))
          (let ((piece (car left)))
            (set! left (cdr left))
            (note! (list 'asked name))
            piece)))))

;; ending-with-eof : String ... -> Producer
;; A producer answering each string's bytes in turn, then eof forever.
(define (ending-with-eof . texts)
  (let ((left (map string->utf8 texts)))
    (lambda ()
      (if (null? left)
          (eof-object)
          (let ((piece (car left)))
            (set! left (cdr left))
            piece)))))

;; per-piece : (Bytevector -> Bytevector) -> (Producer -> Producer)
;; A wrap's f that maps each piece, eof passed through.
(define (per-piece g)
  (lambda (producer)
    (lambda ()
      (let ((x (producer)))
        (if (eof-object? x) x (g x))))))

(define (upcase-bytes bv) (string->utf8 (string-upcase (utf8->string bv))))
(define (reverse-bytes bv) (u8-list->bytevector (reverse (bytevector->u8-list bv))))
(define (double-bytes bv)
  (u8-list->bytevector (apply append (map (lambda (b) (list b b)) (bytevector->u8-list bv)))))

(define (wrapped body f same?)
  (res-body (res-wrap-body (make-res 200 '() body) f same?)))

(define (sample-res)
  (make-res 202
            (list (cons "Content-Type" "text/html") (cons "Set-Cookie" "a=1")
                  (cons "set-cookie" "b=2"))
            "sample"))

(test-begin "response")

;; --- make-res ---------------------------------------------------------------------

(test-equal "make-res keeps the status, the headers and the body as given"
  '(201 (("X-Mixed" . "Case") ("x-mixed" . "dup")) "body" #t)
  (let ((r (make-res 201 (list (cons "X-Mixed" "Case") (cons "x-mixed" "dup")) "body")))
    (list (res-status r) (res-headers r) (res-body r) (res? r))))

(test-equal "make-res takes every body kind, and keeps it"
  '(#t #t #t #t #t #t #t)
  (let ((producer (ending-with-eof "p")))
    (map (lambda (body) (eq? body (res-body (make-res 200 '() body))))
         (list #f (string->utf8 "bv") "text" producer (digits-port)
               (make-sized-body 3 producer) (wrapped "w" (lambda (p) p) #f)))))

(test-equal "make-res takes any exact integer status"
  '(101 999 204)
  (map (lambda (s) (res-status (make-res s '() #f))) '(101 999 204)))

(test-equal "make-res refuses a status that is not an exact integer"
  '((assertion-violation make-res (200.))
    (assertion-violation make-res ("200"))
    (assertion-violation make-res (#f))
    (assertion-violation make-res (3/2)))
  (map (lambda (s) (raised (lambda () (make-res s '() #f)))) (list 200. "200" #f 3/2)))

(test-equal "make-res refuses headers that are not a list"
  '((assertion-violation make-res (x))
    (assertion-violation make-res ((("a" . "b") . "c")))
    (assertion-violation make-res (#f)))
  (map (lambda (h) (raised (lambda () (make-res 200 h #f)))) (list 'x '(("a" . "b") . "c") #f)))

(test-equal "make-res refuses what is no body kind"
  '((assertion-violation make-res (5))
    (assertion-violation make-res (sym))
    (assertion-violation make-res ((1 2)))
    (assertion-violation make-res (#t))
    (assertion-violation make-res (#\a))
    #t #t)
  (let ((text (open-string-input-port "text"))
        (out (let-values (((port extract) (open-bytevector-output-port))) port)))
    (append (map (lambda (b) (raised (lambda () (make-res 200 '() b))))
                 (list 5 'sym '(1 2) #t #\a))
            (map (lambda (port)
                   (equal? (raised (lambda () (make-res 200 '() port)))
                           (list 'assertion-violation 'make-res (list port))))
                 (list text out)))))

(test-equal "res? answers for a response, and for nothing else"
  '(#t #f #f)
  (list (res? (sample-res)) (res? "sample") (res? (make-sized-body 1 (ending-with-eof "x")))))

(test-equal "the accessors refuse what is not a response"
  '((assertion-violation res-status (x)) (assertion-violation res-headers (x))
    (assertion-violation res-body (x)))
  (let ((first-two (lambda (v) (list (car v) (cadr v) (list (car (caddr v)))))))
    (list (first-two (raised (lambda () (res-status 'x))))
          (first-two (raised (lambda () (res-headers 'x))))
          (first-two (raised (lambda () (res-body 'x)))))))

;; --- the header helpers ---------------------------------------------------------------

(test-equal "res-header: the first field of the name, in any case"
  '("a=1" (answer #f))
  (let ((r (sample-res)))
    (list (res-header r "SET-COOKIE") (answer (lambda () (res-header r "accept"))))))

(test-equal "res-set-header: a new response, the name's fields replaced by one, in lower case"
  '((202 (("Content-Type" . "text/html") ("set-cookie" . "z=9")) "sample")
    (202 (("Content-Type" . "text/html") ("Set-Cookie" . "a=1") ("set-cookie" . "b=2"))
         "sample"))
  (let* ((r (sample-res))
         (r2 (res-set-header r "Set-COOKIE" "z=9")))
    (list (list (res-status r2) (res-headers r2) (res-body r2))
          (list (res-status r) (res-headers r) (res-body r)))))

(test-equal "res-add-header: a new response, the field appended in lower case"
  '(202 (("Content-Type" . "text/html") ("Set-Cookie" . "a=1") ("set-cookie" . "b=2")
         ("server" . "circuit"))
    "sample")
  (let ((r (res-add-header (sample-res) "Server" "circuit")))
    (list (res-status r) (res-headers r) (res-body r))))

;; --- res-with-status --------------------------------------------------------------------

(test-equal "res-with-status: a new response with the status, headers and body kept"
  '(404 #t #t 202)
  (let* ((r (sample-res))
         (r2 (res-with-status r 404)))
    (list (res-status r2) (eq? (res-headers r) (res-headers r2)) (eq? (res-body r) (res-body r2))
          (res-status r))))

(test-equal "res-with-status refuses a 1xx status, from 100 to 199, and takes 99 and 200"
  '(99 (assertion-violation res-with-status (100)) (assertion-violation res-with-status (101))
    (assertion-violation res-with-status (150)) (assertion-violation res-with-status (199)) 200)
  (map (lambda (s)
         (guard (e ((assertion-violation? e)
                    (list 'assertion-violation (condition-who e) (condition-irritants e))))
           (res-status (res-with-status (sample-res) s))))
       '(99 100 101 150 199 200)))

(test-equal "res-with-status refuses a status that is not an exact integer, and a non-response"
  '((assertion-violation res-with-status (404.)) (assertion-violation res-with-status ("404"))
    (assertion-violation res-with-status (x)))
  (list (raised (lambda () (res-with-status (sample-res) 404.)))
        (raised (lambda () (res-with-status (sample-res) "404")))
        (raised (lambda () (res-with-status 'x 404)))))

;; --- res-with-body ----------------------------------------------------------------------

(test-equal "res-with-body: a new response with the body, status and headers kept"
  '(202 #t "replaced" "sample")
  (let* ((r (sample-res))
         (r2 (res-with-body r "replaced")))
    (list (res-status r2) (eq? (res-headers r) (res-headers r2)) (res-body r2) (res-body r))))

;; closing-case : (Port -> Body) (Port Port -> Body) -> (List Boolean Boolean)
;; res-with-body from OLD over port p to NEW over p and a second port q:
;; whether p, then q, is closed after.
(define (closing-case old new)
  (let ((p (digits-port)) (q (digits-port)))
    (res-with-body (make-res 200 '() (old p)) (new p q))
    (list (port-closed? p) (port-closed? q))))

(define (same-wrap body) (wrapped body (lambda (x) x) #t))
(define (other-wrap body) (wrapped body (lambda (x) x) #f))

(test-equal "res-with-body closes the port the old body holds, at any depth"
  '((#t #f) (#t #f) (#t #f) (#t #f) (#t #f))
  (list (closing-case (lambda (p) p) (lambda (p q) (string->utf8 "bv")))
        (closing-case (lambda (p) (make-sized-body 4 p)) (lambda (p q) "s"))
        (closing-case (lambda (p) (other-wrap (same-wrap (make-sized-body 4 p))))
                      (lambda (p q) #f))
        (closing-case (lambda (p) (other-wrap p)) (lambda (p q) (ending-with-eof "x")))
        (closing-case (lambda (p) p) (lambda (p q) q))))

(test-equal "res-with-body leaves the port open when the new body holds it, at any depth"
  '((#f #f) (#f #f) (#f #f) (#f #f) (#f #f))
  (list (closing-case (lambda (p) p) (lambda (p q) (make-sized-body 4 p)))
        (closing-case (lambda (p) p)
                      (lambda (p q) (other-wrap (same-wrap (make-sized-body 4 p)))))
        (closing-case (lambda (p) (make-sized-body 4 p)) (lambda (p q) p))
        (closing-case (lambda (p) (same-wrap p)) (lambda (p q) (other-wrap (make-sized-body 2 p))))
        (closing-case (lambda (p) (other-wrap (other-wrap p))) (lambda (p q) (same-wrap p)))))

(test-equal "res-with-body closes nothing when the old body holds no port"
  '((#f #f) (#f #f) (#f #f))
  (list (closing-case (lambda (p) (string->utf8 "bv")) (lambda (p q) q))
        (closing-case (lambda (p) (ending-with-eof "x")) (lambda (p q) #f))
        (closing-case (lambda (p) (make-sized-body 1 (ending-with-eof "x")))
                      (lambda (p q) (other-wrap q)))))

(test-equal "res-with-body refuses what is no body kind, and then closes nothing"
  '((assertion-violation res-with-body (5)) #f)
  (let* ((p (digits-port))
         (refusal (raised (lambda () (res-with-body (make-res 200 '() p) 5)))))
    (list refusal (port-closed? p))))

;; --- make-sized-body ----------------------------------------------------------------------

(test-equal "make-sized-body: its length and inner body, for a producer and a port"
  '(#t 0 #t #t 12 #t)
  (let* ((producer (ending-with-eof "x"))
         (port (digits-port))
         (a (make-sized-body 0 producer))
         (b (make-sized-body 12 port)))
    (list (res-sized-body? a) (res-sized-body-length a) (eq? producer (res-sized-body-inner a))
          (res-sized-body? b) (res-sized-body-length b) (eq? port (res-sized-body-inner b)))))

(test-equal "make-sized-body refuses a length that is not an exact count of bytes"
  '((assertion-violation make-sized-body (-1)) (assertion-violation make-sized-body (1.5))
    (assertion-violation make-sized-body (3/2)) (assertion-violation make-sized-body ("3"))
    (assertion-violation make-sized-body (#f)) (assertion-violation make-sized-body (4.)))
  (map (lambda (n) (raised (lambda () (make-sized-body n (ending-with-eof "x")))))
       (list -1 1.5 3/2 "3" #f 4.)))

(test-equal "make-sized-body refuses a body that is neither a producer nor a binary input port"
  '((assertion-violation make-sized-body (#f)) (assertion-violation make-sized-body ("s"))
    #t #t #t #t)
  (let* ((text (open-string-input-port "text"))
         (bv (string->utf8 "bv"))
         (sized (make-sized-body 1 (ending-with-eof "x")))
         (wrap (other-wrap "w"))
         (refused? (lambda (body)
                     (equal? (raised (lambda () (make-sized-body 2 body)))
                             (list 'assertion-violation 'make-sized-body (list body))))))
    (append (list (raised (lambda () (make-sized-body 2 #f)))
                  (raised (lambda () (make-sized-body 2 "s"))))
            (map refused? (list bv text sized wrap)))))

;; --- res-wrap-body ----------------------------------------------------------------------

(test-equal "res-wrap-body: a new response whose body wraps the old one; same? is #f unless given"
  '(202 #t #t #t #t #f #t "sample")
  (let* ((r (sample-res))
         (f (lambda (p) p))
         (r2 (res-wrap-body r f))
         (b (res-body r2)))
    (list (res-status r2) (eq? (res-headers r) (res-headers r2)) (res-wrapped-body? b)
          (eq? (res-body r) (res-wrapped-body-inner b)) (eq? f (res-wrapped-body-proc b))
          (res-wrapped-body-same? b) (res-wrapped-body-same? (res-body (res-wrap-body r f #t)))
          (res-body r))))

(test-equal "res-wrap-body nests: the outer wrap's inner body is the inner wrap"
  '(#t #t #t)
  (let* ((r1 (res-wrap-body (sample-res) (lambda (p) p) #t))
         (r2 (res-wrap-body r1 (lambda (p) p))))
    (list (eq? (res-body r1) (res-wrapped-body-inner (res-body r2)))
          (res-wrapped-body-same? (res-body r1))
          (equal? "sample" (res-wrapped-body-inner (res-body r1))))))

(test-equal "res-wrap-body closes nothing, and calls nothing"
  '(#f ())
  (let ((p (digits-port)))
    (take-log!)
    (res-wrap-body (res-wrap-body (make-res 200 '() p) (lambda (x) (note! 'called) x))
                   (lambda (x) (note! 'called) x) #t)
    (list (port-closed? p) (take-log!))))

(test-equal "res-wrap-body refuses a non-procedure, a same? that is not a boolean, and a non-response"
  '((assertion-violation res-wrap-body (not-a-proc))
    (assertion-violation res-wrap-body (yes))
    (assertion-violation res-wrap-body (x)))
  (list (raised (lambda () (res-wrap-body (sample-res) 'not-a-proc)))
        (raised (lambda () (res-wrap-body (sample-res) (lambda (p) p) 'yes)))
        (raised (lambda () (res-wrap-body 'x (lambda (p) p))))))

(test-equal "res-sized-body? and res-wrapped-body? each answer for their own kind alone"
  '((#f #f) (#f #f) (#f #f) (#f #f) (#f #f) (#t #f) (#f #t))
  (map (lambda (b) (list (res-sized-body? b) (res-wrapped-body? b)))
       (list #f (string->utf8 "bv") "s" (ending-with-eof "x") (digits-port)
             (make-sized-body 1 (ending-with-eof "x")) (other-wrap "w"))))

;; --- res-body-length ----------------------------------------------------------------------

(test-equal "res-body-length for every kind of body"
  ;;  #f  ""  bv  #vu8()  utf-8  sized  producer  port
  '(0 0 7 0 10 13 #f #f
    ;; same? over: bv, utf-8, sized, port, producer, same? over string, other over bv
    7 10 13 #f #f 5 #f
    ;; other over: bv, sized, same? over bv
    #f #f #f)
  (let ((bv (string->utf8 "seven!!"))
        ;; a, e acute, the euro sign and a grinning face: 1, 2, 3 and 4 bytes
        (utf8 (string #\a (integer->char #xE9) (integer->char #x20AC) (integer->char #x1F600)))
        (sized (lambda () (make-sized-body 13 (ending-with-eof "x")))))
    (map (lambda (body) (res-body-length (make-res 200 '() body)))
         (list #f "" bv #vu8() utf8 (sized) (ending-with-eof "x") (digits-port)
               (same-wrap bv) (same-wrap utf8) (same-wrap (sized)) (same-wrap (digits-port))
               (same-wrap (ending-with-eof "x")) (same-wrap (same-wrap "fives"))
               (same-wrap (other-wrap bv))
               (other-wrap bv) (other-wrap (sized)) (other-wrap (same-wrap bv))))))

(test-equal "res-body-length refuses what is not a response"
  '(assertion-violation res-body-length (x))
  (raised (lambda () (res-body-length 'x))))

;; --- res-body-port ----------------------------------------------------------------------

(test-equal "res-body-port: the port a body holds, at any depth, or #f"
  '(#t #t #t #t #t (answer (#f #f #f #f #f #f)))
  (let ((p (digits-port)))
    (list (eq? p (res-body-port p))
          (eq? p (res-body-port (make-sized-body 3 p)))
          (eq? p (res-body-port (same-wrap p)))
          (eq? p (res-body-port (other-wrap (same-wrap (make-sized-body 3 p)))))
          (eq? p (res-body-port (other-wrap (other-wrap p))))
          (answer (lambda ()
                    (map res-body-port
                         (list #f (string->utf8 "bv") "s" (ending-with-eof "x")
                               (make-sized-body 1 (ending-with-eof "x"))
                               (same-wrap (other-wrap "w")))))))))

(test-equal "res-body-port refuses what is no body kind"
  '(assertion-violation res-body-port (5))
  (raised (lambda () (res-body-port 5))))

;; --- res-body-stream: bodies with no port --------------------------------------------------

(test-equal "res-body-stream: #f, an empty bytevector and an empty string answer eof at once, length 0"
  '(((eof eof) 0) ((eof eof) 0) ((eof eof) 0))
  (map (lambda (body) (streamed body no-length 4 2)) (list #f #vu8() "")))

(test-equal "res-body-stream: a bytevector is one piece, whatever the piece size, then eof"
  '(("0123456789" eof eof) 10)
  (streamed digits no-length 4 3))

(test-equal "res-body-stream: a string is one piece of its UTF-8, its length its bytes'"
  (list (list (string #\h (integer->char #xE9) #\l #\l #\o) 'eof) 6)
  (streamed (string #\h (integer->char #xE9) #\l #\l #\o) no-length 4 2))

(test-equal "res-body-stream: a producer is itself, with no length"
  '(#t #f)
  (let ((producer (ending-with-eof "x")))
    (let-values (((p n) (body-stream producer no-length 4)))
      (list (eq? p producer) n))))

(test-equal "res-body-stream: a sized producer is itself, with its length"
  '(#t 7)
  (let ((producer (ending-with-eof "x")))
    (let-values (((p n) (body-stream (make-sized-body 7 producer) no-length 4)))
      (list (eq? p producer) n))))

;; --- res-body-stream: ports ------------------------------------------------------------------

(test-equal "a port with no length: pieces of the piece size, then eof, the port closed at its eof"
  '((("0123" #f) ("4567" #f) ("89" #f) (eof #t) (eof #t)) #f)
  (let ((port (digits-port)))
    (let-values (((p n) (body-stream port no-length 4)))
      (list (drain-watching p port 5) n))))

(test-equal "a bare port is measured once, then handed to on-port once, each with itself"
  '(((measure #t) (on-port #t)) #f)
  (let ((port (digits-port)))
    (take-log!)
    (res-body-stream port
                     (lambda (q) (note! (list 'measure (eq? q port))) #f)
                     (lambda (q) (note! (list 'on-port (eq? q port))))
                     4)
    (list (take-log!) (port-closed? port))))

(test-equal "a sized port is not measured, but is handed to on-port"
  '(((on-port #t)) 4)
  (let ((port (digits-port)))
    (take-log!)
    (let-values (((p n) (res-body-stream (make-sized-body 4 port)
                                         (lambda (q) (note! 'measure) #f)
                                         (lambda (q) (note! (list 'on-port (eq? q port))))
                                         4)))
      (list (take-log!) n))))

(test-equal "a body that holds no port calls neither measure nor on-port"
  '()
  (begin
    (take-log!)
    (for-each (lambda (body)
                (res-body-stream body (lambda (q) (note! 'measure) #f)
                                 (lambda (q) (note! 'on-port)) 4))
              (list #f (string->utf8 "bv") "s" (ending-with-eof "x")
                    (make-sized-body 1 (ending-with-eof "x"))
                    (same-wrap (other-wrap (ending-with-eof "x")))))
    (take-log!)))

(test-equal "a port the measure gives a length: read no further than it, and closed at it"
  '(((("0123" #f) ("45" #t) (eof #t) (eof #t)) 6) ((4 2) 6))
  (let-values (((port reads) (recording-port digits)))
    (let-values (((p n) (body-stream port (lambda (q) 6) 4)))
      (let ((answers (drain-watching p port 4)))
        (list (list answers n) (reads))))))

(test-equal "a sized port: read no further than its length, and closed at it"
  '(((("0123" #f) ("45" #t) (eof #t) (eof #t)) 6) ((4 2) 6))
  (let-values (((port reads) (recording-port digits)))
    (let-values (((p n) (body-stream (make-sized-body 6 port) no-length 4)))
      (let ((answers (drain-watching p port 4)))
        (list (list answers n) (reads))))))

(test-equal "a sized port whose length is a whole number of pieces: no read after its last byte"
  '(((("0123" #f) ("4567" #t) (eof #t)) 8) ((4 4) 8))
  (let-values (((port reads) (recording-port digits)))
    (let-values (((p n) (body-stream (make-sized-body 8 port) no-length 4)))
      (let ((answers (drain-watching p port 3)))
        (list (list answers n) (reads))))))

(test-equal "a sized port of length 0: eof at once, never a read of 0 bytes, the port closed"
  '((((eof #t) (eof #t)) 0) (() 0))
  (let-values (((port reads) (recording-port digits)))
    (let-values (((p n) (body-stream (make-sized-body 0 port) no-length 4)))
      (let ((answers (drain-watching p port 2)))
        (list (list answers n) (reads))))))

(test-equal "a port that ends short of its length ends at its eof, closed"
  '((("0123" #f) ("4567" #f) ("89" #f) (eof #t)) 12)
  (let ((port (digits-port)))
    (let-values (((p n) (body-stream (make-sized-body 12 port) no-length 4)))
      (list (drain-watching p port 4) n))))

(test-equal "a port read in pieces bigger than it: one piece, then eof"
  '(("0123456789" eof) #f)
  (streamed (digits-port) no-length 65536 2))

(test-equal "a measure that answers no count of bytes is refused, the port closed and on-port not called"
  '(((assertion-violation res-body-stream (-1)) #t) ((assertion-violation res-body-stream ("6")) #t)
    ((assertion-violation res-body-stream (6.)) #t) ())
  (begin
    (take-log!)
    (let ((results
           (map (lambda (n)
                  (let* ((port (digits-port))
                         (refusal (raised (lambda ()
                                            (res-body-stream port (lambda (q) n)
                                                             (lambda (q) (note! 'on-port)) 4)))))
                    (list refusal (port-closed? port))))
                (list -1 "6" 6.))))
      (append results (list (take-log!))))))

;; --- res-body-stream: wraps ---------------------------------------------------------------------

(test-equal "a wrap that keeps the bytes: f's producer, and the inner body's length"
  '(("SEVEN!!" eof) 7)
  (streamed (wrapped (string->utf8 "seven!!") (per-piece upcase-bytes) #t) no-length 4 2))

(test-equal "a wrap that keeps the bytes over a sized port: its length, the port read to it"
  '((("0123" #f) ("45" #t) (eof #t)) 6 ((4 2) 6))
  (let-values (((port reads) (recording-port digits)))
    (let-values (((p n) (body-stream (same-wrap (make-sized-body 6 port)) no-length 4)))
      (let ((answers (drain-watching p port 3)))
        (list answers n (reads))))))

(test-equal "a wrap that drops a length stops at it, never asking the inner producer again"
  '((("abc" "de" eof eof) #f) ((asked inner) (asked inner)))
  (begin
    (take-log!)
    (let ((result (streamed (other-wrap (make-sized-body 5 (pieces 'inner "abc" "de")))
                            no-length 4 4)))
      (list result (take-log!)))))

(test-equal "a wrap that drops a length raises at a piece that would take it past the length"
  '("abc" (assertion-violation res-body-stream (4 5)))
  (let-values (((p n) (body-stream (other-wrap (make-sized-body 4 (ending-with-eof "abc" "de")))
                                       no-length 4)))
    (let* ((first (shown (p)))
           (second (raised p)))
      (list first second))))

(test-equal "a wrap that drops a length: a body that ends short just ends"
  '(("abc" eof eof) #f)
  (streamed (other-wrap (make-sized-body 9 (ending-with-eof "abc"))) no-length 4 3))

(test-equal "a wrap that drops a length over a port the measure sizes stops at that length"
  '(("0123" "45" eof eof) #f ((4 2) 6))
  (let-values (((port reads) (recording-port digits)))
    (let-values (((p n) (body-stream (other-wrap port) (lambda (q) 6) 4)))
      (let ((answers (drain p 4)))
        (list answers n (reads))))))

(test-equal "a wrap that keeps the bytes hands f the inner producer itself, a sized one's included"
  '(#t 5)
  (let* ((producer (ending-with-eof "abcde"))
         (handed #f))
    (let-values (((p n) (body-stream (wrapped (make-sized-body 5 producer)
                                                  (lambda (q) (set! handed q) q) #t)
                                         no-length 4)))
      (list (eq? handed producer) n))))

(test-equal "a wrap over a body with no length hands f the inner producer itself"
  '(#t #f)
  (let* ((producer (ending-with-eof "x"))
         (handed #f))
    (let-values (((p n) (body-stream (wrapped producer (lambda (q) (set! handed q) q) #f)
                                         no-length 4)))
      (list (eq? handed producer) n))))

(test-equal "a wrap over a port with no length reads it to its eof, and closes it there"
  '((("0123" #f) ("4567" #f) ("89" #f) (eof #t)) #f)
  (let ((port (digits-port)))
    (let-values (((p n) (body-stream (other-wrap port) no-length 4)))
      (list (drain-watching p port 4) n))))

(test-equal "an empty body reaches f as eof, with or without same?"
  '(eof eof eof eof eof eof eof)
  (let ((first-answer
         (lambda (body same?)
           (let ((seen 'never-asked))
             (body-stream (wrapped body
                                       (lambda (q) (set! seen (shown (q))) (lambda () (eof-object)))
                                       same?)
                              no-length 4)
             seen))))
    (list (first-answer #f #f) (first-answer #f #t) (first-answer #vu8() #f)
          (first-answer "" #f) (first-answer "" #t)
          (first-answer (make-sized-body 0 (pieces 'empty)) #f)
          (first-answer (make-sized-body 0 (digits-port)) #t))))

(test-equal "a wrap that drops a length of 0 never asks the inner producer"
  '((eof eof) ())
  (begin
    (take-log!)
    (let ((answers (car (streamed (other-wrap (make-sized-body 0 (pieces 'inner "x")))
                                  no-length 4 2))))
      (list answers (take-log!)))))

(test-equal "nested wraps: the inner streamed first; a length kept only while every wrap keeps it"
  '((f2 f1) ("oolllleehh" eof) #f)
  (begin
    (take-log!)
    (let* ((f2 (lambda (q) (note! 'f2) ((per-piece double-bytes) q)))
           (f1 (lambda (q) (note! 'f1) ((per-piece reverse-bytes) q)))
           (result (streamed (wrapped (wrapped "hello" f2 #f) f1 #t) no-length 4 2)))
      (cons (take-log!) result))))

(test-equal "nested wraps that keep the bytes keep a sized port's length"
  '(("0123" "45" eof) 6)
  (streamed (same-wrap (same-wrap (make-sized-body 6 (digits-port)))) no-length 4 3))

(test-equal "nested wraps: each that drops a length hands on no length"
  '((("HELLO" eof) #f) (("olleh" eof) #f) (("OLLEH" eof) #f))
  (list (streamed (wrapped (wrapped "hello" (per-piece upcase-bytes) #f) (lambda (q) q) #f)
                  no-length 4 2)
        (streamed (wrapped (other-wrap (string->utf8 "hello")) (per-piece reverse-bytes) #t)
                  no-length 4 2)
        (streamed (wrapped (wrapped "hello" (per-piece upcase-bytes) #t) (per-piece reverse-bytes) #f)
                  no-length 4 2)))

;; --- res-body-stream: the port is the caller's before any f runs ---------------------------
;; The adapter registers a port's close in on-port: measure first, then
;; on-port, then the wraps' f, innermost first (design §9).

;; ordered : Body -> (List (Listof Symbol) Any Boolean)
;; res-body-stream over BODY with a measure, an on-port and wraps that note
;; their calls: the order of the calls, what it raised or answered, and
;; whether the port PORT is closed after.
(define (ordered body port measure-answer)
  (take-log!)
  (let ((outcome (raised (lambda ()
                           (res-body-stream body
                                            (lambda (q) (note! 'measure) (measure-answer))
                                            (lambda (q) (note! 'on-port))
                                            4)))))
    (list (take-log!) outcome (port-closed? port))))

(define (noting-wrap body name same?)
  (wrapped body (lambda (q) (note! name) q) same?))

(define (raising-wrap body name)
  (wrapped body (lambda (q) (note! name) (raise name)) #f))

(test-equal "a wrapped port: measured, then handed to on-port, then f"
  '((measure on-port f) no-raise #f)
  (let ((port (digits-port)))
    (ordered (noting-wrap port 'f #f) port (lambda () 10))))

(test-equal "a sized port under a wrap: on-port, then f, and no measure"
  '((on-port f) no-raise #f)
  (let ((port (digits-port)))
    (ordered (noting-wrap (make-sized-body 10 port) 'f #t) port (lambda () 10))))

(test-equal "nested wraps over a port: on-port before the inner f, the inner f before the outer"
  '((measure on-port inner-f outer-f) no-raise #f)
  (let ((port (digits-port)))
    (ordered (noting-wrap (noting-wrap port 'inner-f #t) 'outer-f #f) port (lambda () 10))))

(test-equal "a raise from measure closes the port, and neither on-port nor any f runs"
  '((measure) (other-raise measure-failed) #t)
  (let ((port (digits-port)))
    (ordered (noting-wrap (same-wrap port) 'f #t) port (lambda () (raise 'measure-failed)))))

(test-equal "a raise from on-port closes the port, and no f runs"
  '((measure on-port) (other-raise on-port-failed) #t)
  (let ((port (digits-port)))
    (take-log!)
    (let ((outcome (raised (lambda ()
                             (res-body-stream (noting-wrap port 'f #f)
                                              (lambda (q) (note! 'measure) 10)
                                              (lambda (q) (note! 'on-port) (raise 'on-port-failed))
                                              4)))))
      (list (take-log!) outcome (port-closed? port)))))

(test-equal "a raise from on-port under a sized body closes the port too"
  '((on-port) (other-raise on-port-failed) #t)
  (let ((port (digits-port)))
    (take-log!)
    (let ((outcome (raised (lambda ()
                             (res-body-stream (make-sized-body 4 port)
                                              (lambda (q) (note! 'measure) 10)
                                              (lambda (q) (note! 'on-port) (raise 'on-port-failed))
                                              4)))))
      (list (take-log!) outcome (port-closed? port)))))

(test-equal "a raise from f, after on-port, closes nothing: the port is the caller's"
  '((measure on-port inner-f) (other-raise inner-f) #f)
  (let ((port (digits-port)))
    (ordered (noting-wrap (raising-wrap port 'inner-f) 'outer-f #t) port (lambda () 10))))

(test-equal "f answering no producer, after on-port, closes nothing"
  '((measure on-port) (assertion-violation res-body-stream (not-a-producer)) #f)
  (let ((port (digits-port)))
    (ordered (wrapped port (lambda (q) 'not-a-producer) #f) port (lambda () 10))))

(test-equal "a wrap whose f answers no producer is refused"
  '(assertion-violation res-body-stream (not-a-producer))
  (raised (lambda () (body-stream (wrapped "x" (lambda (q) 'not-a-producer) #f) no-length 4))))

(test-equal "res-body-stream calls f, once a stream; nothing else does"
  '(() (called))
  (let* ((f (lambda (q) (note! 'called) q))
         (r (res-wrap-body (make-res 200 '() "body") f)))
    (take-log!)
    (res-body-length r)
    (res-body-port (res-body r))
    (res-with-body r (res-body r))
    (make-res 200 '() (res-body r))
    (let ((before (take-log!)))
      (body-stream (res-body r) no-length 4)
      (list before (take-log!)))))

(test-equal "res-body-stream refuses what is no body kind, a measure or on-port that is no procedure, and a piece size that is no positive count"
  '((assertion-violation res-body-stream (5)) (assertion-violation res-body-stream (6))
    (assertion-violation res-body-stream (7))
    (assertion-violation res-body-stream (0)) (assertion-violation res-body-stream (-1))
    (assertion-violation res-body-stream (1.5)))
  (list (raised (lambda () (body-stream 5 no-length 4)))
        (raised (lambda () (body-stream "x" 6 4)))
        (raised (lambda () (res-body-stream "x" no-length 7 4)))
        (raised (lambda () (body-stream "x" no-length 0)))
        (raised (lambda () (body-stream "x" no-length -1)))
        (raised (lambda () (body-stream "x" no-length 1.5)))))

(test-end "response")

(exit (suite-exit-status runner))
