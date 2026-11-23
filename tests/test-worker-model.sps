#!r6rs
;;; The worker's machine, explored with the shell's protocol and the
;;; server's contract around it (tests/worker-model.sls): every world of
;;; each configuration below, breadth first, then a depth-first search
;;; for a cycle over the graph the first pass built.
;;;
;;; At every step: step/row raising, classify raising or answering
;;; cant-happen, or the two naming different rows, fails; and S1, S2, S5,
;;; S6, S8 to S14 as the model checks them. At every world: S3, L3, and the
;;; model's places agreeing with the machine's slots. At every terminal
;;; world: L1, L2, L4, and every thread returned, joined, or waiting with
;;; nothing owed. A failure prints the shortest trace that reaches it, the
;;; property, and the world.
;;;
;;; Which configurations, and why. A flag adds optional events, so a
;;; configuration with a flag reaches every world the one without it
;;; reaches: every check made at every step and every world is made in
;;; the smaller configuration's worlds too. Terminal worlds differ, though:
;;; an optional event enabled in a world keeps it from being terminal, and
;;; some optional events rescue a party a liveness bug left stuck. So each
;;; liveness check runs in configurations without the events that would
;;; hide its failure:
;;;
;;;   - a deadline frees a parked handler, the server's stop excuses it,
;;;     a stop (and a job that leaves, which stops the worker) tells a job
;;;     the thread never saw, and a spurious wakeup finds a missed job. So
;;;     L1 and the threads' terminal check, which see a lost wakeup, run in
;;;     the plain worlds, with none of those: 1 or 2 threads, a cap of 0, 1
;;;     or 2, 0 to 3 handlers;
;;;   - nothing but a spurious wakeup wakes a stopper or the maker waiting
;;;     on done. So L2 and L4 run in worlds without spurious wakeups: the
;;;     stop worlds, with tear-downs that raise or leave and jobs that
;;;     leave, once without deadlines (where L1 is held under a stop too)
;;;     and once with them; and the start worlds, with forks, set-ups and
;;;     tear-downs that raise or leave, up to 3 threads;
;;;   - the full worlds take every flag, spurious wakeups and the server's
;;;     stop among them, for the checks at every step and world, and for
;;;     the stoppers' results at the end;
;;;   - the double's worlds, one thread and a cap of 0, plain and full.
;;;
;;; Two stoppers reach every world one stopper reaches. The second starts
;;; after the first, so its steps are S2 and S3, which change nothing and
;;; wake no one: it can't rescue the first, and two stoppers hold L2 for
;;; one. The larger configurations take one stopper only for their size. With 2 threads
;;; and at most 3 handlers the queue never holds two jobs, so a cap of 2
;;; there behaves as a cap of 1: only the plain worlds run it. The larger
;;; worlds are tests/check-worker-model.sps's: deadlines with 2 threads, 3
;;; handlers and two stoppers; the full worlds with 3 handlers and two
;;; stoppers; 2 threads with 3 handlers and every flag a handler can meet;
;;; and 3 threads with 4 handlers.
;;;
;;; Each configuration's world count is held to a floor: 99% of the count
;;; it reached when the floor was set, rounded down. A change that keeps
;;; nearly every world passes; one that loses more than 1% of a
;;; configuration's worlds, a pruned branch or a lost event, fails it. The
;;; rows fired across all of them are held to the table's: every row fires.
;;;
;;; Oracle: the properties as the model's checks state them, and
;;; (worker-rows)'s classify for the row each step must take.
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

(test-begin "worker-model")

(define started (real-time))
(define fired (make-eq-hashtable))

(define stop-flags '(teardown-fail job-left))
(define full-flags '(server-stop setup-fail fork-fail teardown-fail job-left abandon
                     self-stop spurious))

;; Each: (name threads cap handlers stoppers flags floor), the floor 99%
;; of the count the configuration reached, rounded down.
(define configurations
  (append
   (list
    ;; plain: L1 and the threads' terminal check
    (list "plain" 1 0 0 0 '() 6)
    (list "plain" 1 0 1 0 '() 22)
    (list "plain" 1 0 2 0 '() 63)
    (list "plain" 1 0 3 0 '() 165)
    (list "plain" 1 1 0 0 '() 6)
    (list "plain" 1 1 1 0 '() 22)
    (list "plain" 1 1 2 0 '() 59)
    (list "plain" 1 1 3 0 '() 131)
    (list "plain" 1 2 0 0 '() 6)
    (list "plain" 1 2 1 0 '() 22)
    (list "plain" 1 2 2 0 '() 59)
    (list "plain" 1 2 3 0 '() 120)
    (list "plain" 2 0 0 0 '() 17)
    (list "plain" 2 0 1 0 '() 49)
    (list "plain" 2 0 2 0 '() 227)
    (list "plain" 2 0 3 0 '() 1108)
    (list "plain" 2 1 0 0 '() 17)
    (list "plain" 2 1 1 0 '() 49)
    (list "plain" 2 1 2 0 '() 227)
    (list "plain" 2 1 3 0 '() 1066)
    (list "plain" 2 2 0 0 '() 17)
    (list "plain" 2 2 1 0 '() 49)
    (list "plain" 2 2 2 0 '() 227)
    (list "plain" 2 2 3 0 '() 1066))
   (list
    ;; start: L4, every fork, set-up and tear-down outcome
    (list "start" 1 0 0 1 '(setup-fail fork-fail teardown-fail) 52)
    (list "start" 2 0 0 1 '(setup-fail fork-fail teardown-fail) 421)
    (list "start" 3 0 0 0 '(setup-fail fork-fail teardown-fail) 2511)
    ;; stop: L1 under a stop, and L2
    (list "stop" 1 0 3 2 stop-flags 12157)
    (list "stop" 1 1 3 2 stop-flags 13314)
    (list "stop" 1 2 3 2 stop-flags 14442)
    (list "stop" 2 0 3 2 stop-flags 280890)
    (list "stop" 2 1 3 2 stop-flags 295187)
    ;; stop with deadlines: L2 with dropping jobs
    (list "stop-abandon" 1 0 3 2 (cons 'abandon stop-flags) 71870)
    (list "stop-abandon" 1 1 3 2 (cons 'abandon stop-flags) 85849)
    (list "stop-abandon" 1 2 3 2 (cons 'abandon stop-flags) 94132)
    (list "stop-abandon" 2 0 2 2 (cons 'abandon stop-flags) 144367)
    (list "stop-abandon" 2 0 3 1 (cons 'abandon stop-flags) 398826)
    (list "stop-abandon" 2 1 3 1 (cons 'abandon stop-flags) 429547)
    ;; full: every flag
    (list "full" 1 0 3 1 full-flags 346461)
    (list "full" 1 1 3 1 full-flags 373361)
    (list "full" 1 2 3 1 full-flags 386461)
    (list "full" 1 1 2 2 full-flags 207435)
    (list "full" 2 0 2 1 full-flags 705422)
    ;; the double
    (list "double" 1 0 0 0 '(double) 6)
    (list "double" 1 0 1 0 '(double) 39)
    (list "double" 1 0 2 0 '(double) 118)
    (list "double" 1 0 3 0 '(double) 235)
    (list "double" 1 0 3 1 '(double) 2739)
    (list "double" 1 0 2 2 '(double) 4835)
    (list "double-full" 1 0 3 1 (cons 'double full-flags) 290415)
    (list "double-full" 1 0 2 2 (cons 'double full-flags) 281351))))

(define (name-of spec)
  (let ((p (lambda (x) (number->string x))))
    (string-append (list-ref spec 0) " threads " (p (list-ref spec 1))
                   " cap " (p (list-ref spec 2)) " handlers " (p (list-ref spec 3))
                   " stoppers " (p (list-ref spec 4)))))

;; The verdict of one configuration: pass, or the failed property, after
;; printing the report. Its world count goes to the floor's row.
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
    (display " s")
    (newline)
    (when (explored-failure r)
      (print-report (explored-failure r) (current-output-port)))
    (collect (collect-maximum-generation))
    (cons (if (explored-failure r) (report-property (explored-failure r)) 'pass)
          (explored-worlds r))))

(define (list-head l n) (if (= n 0) '() (cons (car l) (list-head (cdr l) (- n 1)))))

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

(display "worker-model: ")
(display (/ (- (real-time) started) 1000.0))
(display " s, peak memory ")
(display (div (maximum-memory-bytes) 1000000))
(display " MB")
(newline)

(test-end "worker-model")

(exit (suite-exit-status runner))
