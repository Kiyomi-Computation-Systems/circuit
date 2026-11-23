#!r6rs
;;; make check-worker-model: the explorer of tests/test-worker-model.sps in
;;; larger worlds than make test's time allows. The same checks at every
;;; step, every world and every terminal world, the same cycle pass, the
;;; same floors and the same rows; it exits 1 on any failure, after the
;;; report with its shortest trace.
;;;
;;; The configurations follow the suite's reasoning (see its header):
;;;
;;;   - plain, with 4 handlers and 1 to 3 threads, for L1 and the threads'
;;;     terminal check: a cap of 2 now holds two queued jobs on 2 threads;
;;;   - stop, without deadlines, 3 threads with 4 handlers, and 2 threads
;;;     with 4 handlers and two stoppers;
;;;   - stop with deadlines, 2 threads with 3 handlers and two stoppers,
;;;     2 threads with 4 handlers, 3 threads with 3 handlers, 1 thread with
;;;     4 handlers and two stoppers;
;;;   - full, 1 thread with 3 handlers and two stoppers at each cap, and 2
;;;     threads with 2 handlers and two stoppers;
;;;   - calls, 2 threads with 3 handlers and a stopper, at a cap of 0 (a
;;;     call can be full) and of 1 (a job can queue), with every flag a
;;;     handler can meet: the server's stop, tear-downs that raise or
;;;     leave, jobs that leave, deadlines, a job's own stop, and spurious
;;;     wakeups;
;;;   - the double's full worlds with 3 handlers and two stoppers;
;;;   - start, 3 threads with 2 handlers and a stopper.
;;;
;;; The calls worlds leave out a fork or a set-up that raises or leaves,
;;; because neither can meet a handler or a stopper. Both act only once
;;; the maker was answered ready, by K2, in serving; serving is reached
;;; only by U2, when every set-up has returned after F1 made every fork.
;;; Once a fork or a set-up has raised or left, the phase is failing or
;;; failed, which nothing leaves but for failed, so no look answers ready.
;;; So with those flags, a world where a handler or a stopper has acted is
;;; one the configuration reaches without them, and a world after a failed
;;; start holds every handler and stopper idle for good: it is a world of
;;; the same threads with no handlers and no stoppers, which the start
;;; worlds explore, and with spurious wakeups the full worlds of 1 and 2
;;; threads. (The server's stop, a deadline and a job's own stop need a
;;; ready maker, a parked handler and a running job, so none of them
;;; reaches a failed start either.)
;;;
;;; Left out for their size: 3 threads with 4 handlers and two stoppers,
;;; and the calls worlds with two stoppers. The random walks of
;;; tests/test-worker-walks.sps reach both.
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (worker-rows)
        (worker-model)
        (only (chezscheme) real-time maximum-memory-bytes collect
              collect-maximum-generation))

(define runner (test-runner-simple))
(test-runner-current runner)

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

(test-begin "check-worker-model")

(define started (real-time))
(define fired (make-eq-hashtable))

(define stop-flags '(teardown-fail job-left))
(define abandon-flags '(abandon teardown-fail job-left))
(define full-flags '(server-stop setup-fail fork-fail teardown-fail job-left abandon
                     self-stop spurious))
(define call-flags '(server-stop teardown-fail job-left abandon self-stop spurious))

;; Each: (name threads cap handlers stoppers flags floor), the floor 99%
;; of the count the configuration reached, rounded down, as in
;; tests/test-worker-model.sps.
(define configurations
  (list
   (list "plain" 1 0 4 0 '() 413)
   (list "plain" 1 1 4 0 '() 299)
   (list "plain" 1 2 4 0 '() 230)
   (list "plain" 2 0 4 0 '() 4844)
   (list "plain" 2 1 4 0 '() 4281)
   (list "plain" 2 2 4 0 '() 4099)
   (list "plain" 3 0 4 0 '() 20209)
   (list "plain" 3 1 4 0 '() 19820)
   (list "plain" 3 2 4 0 '() 19820)
   (list "start" 3 0 2 1 '(setup-fail fork-fail teardown-fail) 91306)
   (list "stop" 3 0 4 1 stop-flags 5908233)
   (list "stop" 2 1 4 2 stop-flags 1300193)
   (list "stop-abandon" 2 0 3 2 abandon-flags 1316819)
   (list "stop-abandon" 2 1 3 2 abandon-flags 1412781)
   (list "stop-abandon" 2 1 4 1 abandon-flags 3590838)
   (list "stop-abandon" 3 0 3 1 abandon-flags 3750479)
   (list "stop-abandon" 1 2 4 2 abandon-flags 512009)
   (list "full" 1 0 3 2 full-flags 1730113)
   (list "full" 1 1 3 2 full-flags 1853280)
   (list "full" 1 2 3 2 full-flags 1922577)
   (list "full" 2 0 2 2 full-flags 3691024)
   (list "calls" 2 0 3 1 call-flags 10422920)
   (list "calls" 2 1 3 1 call-flags 10837212)
   (list "double-full" 1 0 3 2 (cons 'double full-flags) 1561468)))

(define (list-head l n) (if (= n 0) '() (cons (car l) (list-head (cdr l) (- n 1)))))

(define (name-of spec)
  (let ((p (lambda (x) (number->string x))))
    (string-append (list-ref spec 0) " threads " (p (list-ref spec 1))
                   " cap " (p (list-ref spec 2)) " handlers " (p (list-ref spec 3))
                   " stoppers " (p (list-ref spec 4)))))

;; The verdict of one configuration: pass, or the failed property, after
;; printing the report, with its world count.
(define (explore-spec spec)
  (let* ((c (apply make-config (list-head spec 6)))
         (r (explore c)))
    (for-each (lambda (row) (hashtable-set! fired row #t)) (explored-rows r))
    (display (name-of spec))
    (display ": ")
    (display (explored-worlds r))
    (display " worlds, ")
    (display (explored-terminals r))
    (display " terminal, ")
    (display (explored-seconds r))
    (display " s, peak memory so far ")
    (display (div (maximum-memory-bytes) 1000000))
    (display " MB")
    (newline)
    (when (explored-failure r)
      (print-report (explored-failure r) (current-output-port)))
    (collect (collect-maximum-generation))
    (cons (if (explored-failure r) (report-property (explored-failure r)) 'pass)
          (explored-worlds r))))

(for-each
 (lambda (spec)
   (let ((got (guard (x (#t (display (name-of spec)) (display ": raised ")
                            (display (describe x)) (newline)
                            (cons 'raised 0)))
                (explore-spec spec))))
     (test-equal (string-append (name-of spec) ": every check holds") 'pass (car got))
     (test-assert (string-append (name-of spec) ": at least "
                                 (number->string (list-ref spec 6)) " worlds")
                  (>= (cdr got) (list-ref spec 6)))))
 configurations)

(test-equal "every row of the table fires in some world"
  '()
  (filter (lambda (row) (not (hashtable-ref fired row #f))) row-ids))

(display "check-worker-model: ")
(display (/ (- (real-time) started) 1000.0))
(display " s, peak memory ")
(display (div (maximum-memory-bytes) 1000000))
(display " MB")
(newline)

(test-end "check-worker-model")

(exit (suite-exit-status runner))
