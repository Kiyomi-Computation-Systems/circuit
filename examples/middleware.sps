#!r6rs
;;; Middleware that knows the server's waits, from (circuit middleware
;;; waits): a catch, a timeout and a log, composed as
;;; (wrap app wrap-catch (wrap-timeout 1000) wrap-log). The last is
;;; outermost, so the log sees what the timeout and the catch answer.
;;;
;;;   /            hello
;;;   /slow?ms=N   waits N ms, then answers "waited N ms"; past the
;;;                timeout's 1000 ms, an empty 504
;;;   /boom        raises; the catch answers an empty 500
;;;   anything else  404, with a hint
;;;
;;; Once a response is done, the log writes a line on standard output: the
;;; method, the path, the status, how the response ended and how many ms it
;;; took. For /boom the catch writes first the line the server would have:
;;;
;;;   request GET / 200 written 0
;;;   handler-failed Exception in app: boom
;;;   request GET /boom 500 written 1
;;;   request GET /slow 504 written 1001
;;;
;;;   make run PROGRAM=examples/middleware.sps
;;;   curl -i 'http://127.0.0.1:8080/slow?ms=1500'
(import (rnrs) (circuit) (circuit http-server) (circuit middleware waits))

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

;; text : Nat String -> Res
(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

;; slow : Nat -> Res — waits MS milliseconds, then says so.
(define (slow ms)
  (sleep-ms ms)
  (text 200 (string-append "waited " (number->string ms) " ms\n")))

;; app : Req -> Res
(define (app req)
  (let ((path (req-path req)))
    (cond ((string=? path "/") (text 200 "hello\n"))
          ((string=? path "/slow") (slow (query-number req "ms" 0 60000)))
          ((string=? path "/boom") (error 'app "boom"))
          (else (text 404 "try /, /slow?ms=1500 or /boom\n")))))

(run-server (wrap app wrap-catch (wrap-timeout 1000) wrap-log))
