#!r6rs
;;; Streaming a response: the body is a producer, a procedure the server
;;; calls for each next piece until it returns the eof object.
;;;
;;;   /count?n=N        N numbered lines, made as fast as the client reads
;;;   /ticks?n=N&ms=M   N server-sent events, M milliseconds apart: the
;;;                     producer waits between them
;;;
;;;   make run PROGRAM=examples/stream.sps
;;;   curl 'http://127.0.0.1:8080/count?n=5'
;;;   curl -N 'http://127.0.0.1:8080/ticks?n=5&ms=1000'
;;;
;;; A producer may wait, with sleep-ms or any of the server's waits: circuit
;;; runs every request on a coroutine, and each piece on one of its own.
(import (rnrs) (circuit) (circuit http-server))

;; split : String Char -> (Listof String)
(define (split s c)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length s)) (reverse (cons (substring s start i) acc)))
          ((char=? (string-ref s i) c) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
          (else (loop (+ i 1) start acc)))))

;; digits? : String -> Boolean — one or more of #\0 to #\9, nothing else.
(define (digits? s)
  (and (> (string-length s) 0)
       (for-all (lambda (c) (char<=? #\0 c #\9)) (string->list s))))

;; query-number : Req String Nat Nat -> Nat
;; The query's NAME=digits, at most MOST; DEFAULT if it isn't there, or
;; isn't digits alone.
(define (query-number req name default most)
  (let loop ((pairs (split (or (req-query req) "") #\&)))
    (cond ((null? pairs) default)
          ((let ((kv (split (car pairs) #\=)))
             (and (= (length kv) 2) (string=? (car kv) name) (digits? (cadr kv))
                  (string->number (cadr kv) 10)))
           => (lambda (n) (min n most)))
          (else (loop (cdr pairs))))))

;; counting : Nat -> (-> (U Bytevector Eof)) — the lines "1" to "N".
(define (counting n)
  (let ((i 0))
    (lambda ()
      (set! i (+ i 1))
      (if (> i n) (eof-object) (string->utf8 (string-append (number->string i) "\n"))))))

;; ticking : Nat Nat -> (-> (U Bytevector Eof)) — N events, MS apart.
(define (ticking n ms)
  (let ((i 0))
    (lambda ()
      (set! i (+ i 1))
      (cond ((> i n) (eof-object))
            (else (when (> i 1) (sleep-ms ms))
                  (string->utf8 (string-append "data: tick " (number->string i) "\n\n")))))))

;; app : Req -> Res
(define (app req)
  (let ((path (req-path req)))
    (cond ((string=? path "/count")
           (make-res 200 '(("content-type" . "text/plain"))
                     (counting (query-number req "n" 10 1000000))))
          ((string=? path "/ticks")
           (make-res 200 '(("content-type" . "text/event-stream") ("cache-control" . "no-cache"))
                     (ticking (query-number req "n" 10 1000) (query-number req "ms" 1000 60000))))
          (else
           (make-res 404 '(("content-type" . "text/plain"))
                     "try /count?n=5 or /ticks?n=5&ms=1000\n")))))

(run-server app)
