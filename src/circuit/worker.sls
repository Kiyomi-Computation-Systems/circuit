#!r6rs
;;; (circuit worker): run a blocking job on a thread of its own, and answer
;;; 503 when the worker has no room.
;;;
;;;   (import (rnrs) (circuit) (circuit http-server) (circuit worker)
;;;           (circuit middleware waits))
;;;   (define w (make-worker (lambda () (open-db)) 8 2))
;;;   (run-server (wrap app (wrap-busy 5) wrap-catch))
;;;
;;; The worker itself is the shell's: make-worker, worker-call,
;;; worker-stop!, make-test-worker and the two refusals, &worker-full and
;;; &worker-stopped, are re-exported here as the shell defines them.
;;;
;;; wrap-busy turns those two refusals into a 503 with a retry-after header
;;; of the seconds you give it, and an empty body. Put it inside wrap-catch:
;;; wrap-catch would answer them as a 500 and write its line. It is built as
;;; wrap-catch is, by call/cc in tail position around
;;; with-exception-handler, the answer made inside the handler. Anything else
;;; it passes on by raise-continuable, so a continuable raise is answered
;;; where it was raised, as if wrap-busy weren't there.
(library (circuit worker)
  (export make-worker worker-call worker-stop! worker? make-test-worker
          &worker-full worker-full? &worker-stopped worker-stopped?
          wrap-busy)
  (import (rnrs)
          (only (circuit worker shell)
                make-worker worker-call worker-stop! worker? make-test-worker
                &worker-full worker-full? &worker-stopped worker-stopped?)
          (only (circuit response) make-res))

  ;; Handler = Req -> Res
  ;; Middleware = Handler -> Handler

  ;; wrap-busy : Nat -> Middleware
  ;; A middleware that answers (make-res 503 '(("retry-after" . "N")) #f)
  ;; when its handler raises &worker-full or &worker-stopped, N in decimal,
  ;; and passes any other raise on by raise-continuable. An N that isn't an
  ;; exact integer of 0 or more is an assertion violation, raised now; so is
  ;; a handler that is no procedure, when the middleware is applied.
  (define (wrap-busy n)
    (unless (and (integer? n) (exact? n) (>= n 0))
      (assertion-violation 'wrap-busy "expected a whole number of seconds" n))
    (let ((headers (list (cons "retry-after" (number->string n)))))
      (lambda (handler)
        (unless (procedure? handler)
          (assertion-violation 'wrap-busy "a handler is a procedure" handler))
        (lambda (req)
          (call/cc
           (lambda (k)
             (with-exception-handler
              (lambda (e)
                (if (or (worker-full? e) (worker-stopped? e))
                    (k (make-res 503 headers #f))
                    (raise-continuable e)))
              (lambda () (handler req)))))))))
)
