#!r6rs
;;; The real worker on real threads, under a schedule this suite draws from
;;; the model's enabled events, checked step by step against the model
;;; (tests/worker-schedule.sls says how).
;;;
;;; Each sequence draws from its own generator, seeded from the seed, fixed
;;; and printed, and its index, so a failing sequence can be run again.
;;; A sequence is lives, one worker each, run until it has drawn at least
;;; 40 events: a life that ends sooner, at a failed start or an early stop,
;;; is followed by another in the same sequence.
;;;
;;; Each life draws its configuration. The double, one life in five: one
;;; thread, a cap of 0, 8 callers. Otherwise 1 to 3 threads, a cap of 0 to
;;; 2, 10 callers: enough calls to fill the queue and be refused, and a
;;; call may find a thread idle in the machine before that thread, told
;;; wait, has stepped next, which is where a lost wakeup would show. Each
;;; has 1 or 2 stoppers, so every life ends stopped or failed, and its live
;;; count can fall to 0; with 2, the second may start before or after the
;;; first ends. Flags, each at its own odds: abandon, job-left, self-stop
;;; and teardown-fail at one in two; setup-fail and server-stop at one in
;;; four. Never fork-fail: a fork can't be made to fail on real threads.
;;; Always spurious, whose events are never drawn: the replay follows a
;;; real spurious wakeup by the model's event, and any past the model's
;;; budget by the machine's own step (tests/worker-schedule.sls). The server's stop is held to the model
;;; by drawing no call after it (tests/worker-schedule.sls). In the double
;;; no deadline is ever drawable: its register returns only once the post
;;; is made, and the same host command hands it over.
;;;
;;; Each step draws one drawable event, weighted: failures, deadlines,
;;; stops and the server's stop are rare, so most lives call most of their
;;; callers first. How rare a stop, a deadline and a job that leaves are,
;;; and how long jobs run, is drawn for each life.
;;;
;;; Oracle: tests/worker-model.sls's world, its steps, its checks at every
;;; event and its terminal check; and the outcomes, responses, jobs begun,
;;; tear-downs and live count it implies.
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (worker-rows)
        (worker-model)
        (worker-schedule)
        (only (chezscheme) real-time maximum-memory-bytes))

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

(test-begin "worker-schedule")

(define seed 20261124)
(define sequences 1000)
(define events-per-sequence 40)

(display "worker-schedule: seed ")
(display seed)
(display ", ")
(display sequences)
(display " sequences of at least ")
(display events-per-sequence)
(display " events")
(newline)

;; draw-config : Prng -> Config
;; Every draw has a let* binding or a loop step of its own, so the order of
;; the draws is the text's.
(define (draw-config p)
  (let* ((double (= 0 (prng-below! p 5)))
         (threads (if double 1 (+ 1 (prng-below! p 3))))
         (cap (if double 0 (prng-below! p 3)))
         (stoppers (+ 1 (prng-below! p 2)))
         (chosen (let loop ((fs '((abandon . 2) (job-left . 2) (self-stop . 2)
                                  (teardown-fail . 2) (setup-fail . 4) (server-stop . 4)))
                            (acc '()))
                   (if (null? fs)
                       (reverse acc)
                       (let ((on (= 0 (prng-below! p (cdar fs)))))
                         (loop (cdr fs) (if on (cons (caar fs) acc) acc)))))))
    (make-config (if double "double" "pool") threads cap (if double 8 10) stoppers
                 (append (if double '(double) '()) '(spurious) chosen))))

;; draw-weights : Prng -> (Event -> Positive-Fixnum)
;; A life's weights. Most events weigh 100; the rare ones weigh what this
;; life draws, so some lives stop early, with jobs queued and running, and
;; some see many deadlines and many jobs that leave.
(define (draw-weights p)
  (let* ((stop (vector-ref '#(3 30) (prng-below! p 2)))
         (deadline (vector-ref '#(10 60) (prng-below! p 2)))
         (left (vector-ref '#(3 60) (prng-below! p 2)))
         (end (vector-ref '#(100 15) (prng-below! p 2))))
    (lambda (ev)
      (case (car ev)
        ((thread)
         (case (caddr ev)
           ((set-up) (if (eq? (cadddr ev) 'returned) 100 5))
           ((torn-down) (if (eq? (cadddr ev) 'returned) 100 20))
           ((end) end)
           ((left) left)
           ((self-stop) 5)
           (else 100)))
        ((caller) (if (eq? (caddr ev) 'deadline) deadline 100))
        ((server) 2)
        ((stopper) (if (eq? (caddr ev) 'start) stop 100))
        (else 100)))))

(define stats (make-hashtable equal-hash equal?))
(define (stat name) (hashtable-ref stats name 0))

(start-loop!)

(define started (real-time))

;; run-sequences : -> (List Natural Natural Natural Natural (U #f List))
;; Sequences run, their fewest events drawn, events drawn, lives, and the
;; first failure: (sequence seeded lived).
(define (run-sequences)
  (let loop ((i 0) (fewest #f) (drawn 0) (applied 0) (lives 0))
    (if (= i sequences)
        (list i (or fewest 0) drawn applied lives #f)
        (let* ((seeded (+ (* seed 1000003) i))
               (p (make-prng seeded)))
          (let life ((n 0) (applied applied) (lives lives))
            (if (>= n events-per-sequence)
                (loop (+ i 1) (if fewest (min fewest n) n) (+ drawn n) applied lives)
                (let* ((c (draw-config p))
                       (weights (draw-weights p))
                       (l (run-life c p weights stats)))
                  (hashtable-update! stats (config-name (lived-config l)) (lambda (k) (+ k 1)) 0)
                  (if (lived-failure l)
                      (list i (or fewest 0) (+ drawn n (lived-drawn l)) (+ applied (lived-applied l))
                            (+ lives 1) (list i seeded l))
                      (life (+ n (lived-drawn l)) (+ applied (lived-applied l)) (+ lives 1))))))))))

(define result
  (guard (x (#t (display "worker-schedule: raised ") (display (describe x)) (newline)
                (list 0 0 0 0 0 (list 'raised))))
    (run-sequences)))

(define failure (list-ref result 5))

(when (and failure (not (eq? (car failure) 'raised)))
  (display "FAILED: sequence ")
  (display (car failure))
  (display ", seeded ")
  (display (cadr failure))
  (newline)
  (print-failure (lived-failure (caddr failure)) (current-output-port)))

(define rows-fired
  (map (lambda (row) (cons row (stat (list 'row row)))) row-ids))

(display "worker-schedule: ")
(display (car result))
(display " sequences, ")
(display (list-ref result 4))
(display " lives (")
(display (stat "pool"))
(display " pool, ")
(display (stat "double"))
(display " double), ")
(display (list-ref result 2))
(display " events drawn, the fewest in a sequence ")
(display (cadr result))
(display ", ")
(display (list-ref result 3))
(display " model events, ")
(display (/ (- (real-time) started) 1000.0))
(display " s, peak memory ")
(display (div (maximum-memory-bytes) 1000000))
(display " MB")
(newline)
(display "counts: ")
(write (map (lambda (k) (cons k (stat k)))
            '(lost-signals lost-wakeup-schedules deadline closed delivered server-stops
              self-stops spurious spurious-past-budget)))
(newline)
(display "rows fired: ")
(write rows-fired)
(newline)

(test-assert "every sequence holds every check" (not failure))

(test-assert "at least 200 sequences, each of at least 40 events"
  (and (>= (car result) 200) (>= (cadr result) events-per-sequence)))

;; 99% of the count when it was set, so the sequences can't pass by doing
;; nothing.
(test-assert "the sequences drew at least 56,851 events" (>= (list-ref result 2) 56851))

;; A fork can't be made to fail on real threads, so F2 and F3 never fire.
(test-equal "every row of the table fires, but the fork failures'"
  '()
  (filter (lambda (row) (and (not (memq row '(F2 F3))) (= 0 (stat (list 'row row)))))
          row-ids))

;; The lost wakeup's schedule: a call's signal to a thread that hasn't
;; waited yet, after a step that told it wait.
(test-assert "the schedules reach a thread told wait, its signal sent before it waits"
  (>= (stat 'lost-wakeup-schedules) 100))

(test-assert "the schedules reach deadlines, closes, deliveries, the server's stop and self-stops"
  (for-all (lambda (k) (> (stat k) 0))
           '(deadline closed delivered server-stops self-stops)))

(test-assert "the schedules reach the double's worlds" (>= (stat "double") 20))

(test-end "worker-schedule")

(exit (suite-exit-status runner))
