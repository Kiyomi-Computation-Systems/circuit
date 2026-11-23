#!r6rs
;;; A worker: GET /slow?ms=N blocks a thread for N ms, and the server's loop
;;; stays free. Circuit runs handlers on one thread, so a blocking call in a
;;; handler would stall every request. A worker runs the job on a thread of
;;; its own, and the handler waits for the answer where it is.
;;;
;;;   /            fast, at once
;;;   /slow?ms=N   sleeps N ms (200 if none) on the worker, then answers
;;;                "slept N ms"
;;;   /waiting     how many /slow requests wait on the worker now
;;;   anything else  404, with a hint
;;;
;;; The worker has one thread and room for one job in its queue. A /slow that
;;; finds the thread busy and the queue full is answered an empty 503 with
;;; retry-after: 1, by wrap-busy.
;;;
;;;   make run PROGRAM=examples/worker.sps
;;;   curl 'http://127.0.0.1:8080/slow?ms=3000'      # in one terminal
;;;   curl http://127.0.0.1:8080/                    # in another: still fast
;;;   curl http://127.0.0.1:8080/waiting             # 1 waiting
;;;
;;; run-server returns on Ctrl-C, and only then is the worker stopped.
(import (rnrs) (only (chezscheme) sleep make-time) (circuit) (circuit http-server)
        (circuit worker) (circuit middleware waits))

;; One thread, a queue of one. The set-up runs on the thread as it starts: a
;; real app would open its database there, and each job would get it.
(define w (make-worker (lambda () 'ready) 1))

;; The /slow requests now in worker-call, running or queued. Only the loop's
;; thread reads or writes it.
(define waiting 0)

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

;; query-number : Req String Nat -> Nat
;; The query's NAME=digits; DEFAULT if it isn't there, or isn't digits
;; alone.
(define (query-number req name default)
  (let loop ((pairs (split (or (req-query req) "") #\&)))
    (cond ((null? pairs) default)
          ((let ((kv (split (car pairs) #\=)))
             (and (= (length kv) 2) (string=? (car kv) name) (digits? (cadr kv))
                  (string->number (cadr kv) 10))))
          (else (loop (cdr pairs))))))

;; text : Nat String -> Res
(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

;; slow : Nat -> Res — sleeps MS milliseconds on the worker, then says so.
(define (slow ms)
  (set! waiting (+ waiting 1))
  (guard (e (#t (set! waiting (- waiting 1)) (raise e)))
    (let ((answer (worker-call w
                    (lambda (state)
                      (sleep (make-time 'time-duration (* (mod ms 1000) 1000000) (div ms 1000)))
                      (string-append "slept " (number->string ms) " ms\n")))))
      (set! waiting (- waiting 1))
      (text 200 answer))))

;; routes : Req -> Res
(define (routes req)
  (let ((path (req-path req)))
    (cond ((string=? path "/") (text 200 "fast\n"))
          ((string=? path "/slow") (slow (query-number req "ms" 200)))
          ((string=? path "/waiting")
           (text 200 (string-append (number->string waiting) " waiting\n")))
          (else (text 404 "try /, /slow?ms=3000 or /waiting\n")))))

(define app (wrap routes (wrap-busy 1) wrap-catch))

(run-server app)
(worker-stop! w)
