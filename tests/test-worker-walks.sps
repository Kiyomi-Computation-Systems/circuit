#!r6rs
;;; The worker's machine in worlds too big to explore: 10,000 random walks
;;; through the same worlds as tests/test-worker-model.sps, each from the
;;; initial world to a terminal one, with every check at every step and the
;;; terminal checks at the end.
;;;
;;; Each walk draws its configuration: 1 to 4 threads, a cap of 0 to 8, 50
;;; handlers, 0 to 2 stoppers, and each flag at even odds, the double at
;;; one in ten. Then each step draws one enabled event, weighted: a
;;; failure (a fork, set-up or tear-down that raises or leaves, a job that
;;; leaves), a deadline, a stop's start, the server's stop and a job's own
;;; stop are rare, so a walk calls most of its handlers before it stops.
;;;
;;; The generator is a linear congruential one over exact integers, so the
;;; seed, fixed and printed, gives the same walks on every platform. Walk i
;;; draws from its own generator, seeded from the seed and i, so a failing
;;; walk can be run again alone.
;;;
;;; The rows fired across the walks are held to the table's, and the steps
;;; taken to a floor, 99% of the count when it was set, so the walks can't
;;; pass by doing nothing.
;;;
;;; Oracle: the properties as tests/worker-model.sls checks them, and
;;; (worker-rows)'s classify for the row each step must take.
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (worker-rows)
        (worker-model)
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

(test-begin "worker-walks")

(define seed 20261123)
(define walks 10000)
(define handlers 50)

(display "worker-walks: seed ")
(display seed)
(display ", ")
(display walks)
(display " walks")
(newline)

(define flags '(server-stop setup-fail fork-fail teardown-fail job-left abandon
                self-stop spurious))

;; draw-config : Prng -> Config
;; Every draw has a let* binding or a loop step of its own, so the order of
;; the draws is the text's, whatever order Chez evaluates a call's
;; arguments in.
(define (draw-config p)
  (let* ((double (= 0 (prng-below! p 10)))
         (threads (if double 1 (+ 1 (prng-below! p 4))))
         (cap (if double 0 (prng-below! p 9)))
         (stoppers (prng-below! p 3))
         (chosen (let loop ((fs flags) (acc '()))
                   (if (null? fs)
                       (reverse acc)
                       (let ((on (= 0 (prng-below! p 2))))
                         (loop (cdr fs) (if on (cons (car fs) acc) acc)))))))
    (make-config "walk" threads cap handlers stoppers
                 (if double (cons 'double chosen) chosen))))

;; draw-weights : Prng -> (Event -> Positive-Fixnum)
;; A walk's weights. Most events weigh 400; the rare ones weigh what this
;; walk draws, so some walks stop early, with jobs queued and running, and
;; some see many deadlines and many jobs that leave.
(define (draw-weights p)
  (let* ((stop (vector-ref '#(1 10 100) (prng-below! p 3)))
         (deadline (vector-ref '#(4 40) (prng-below! p 2)))
         (left (vector-ref '#(2 40) (prng-below! p 2))))
    (lambda (ev)
      (case (car ev)
        ((maker) (if (eq? (cadr ev) 'fork-raised) 10 400))
        ((thread)
         (case (caddr ev)
           ((set-up) (if (eq? (cadddr ev) 'returned) 400 20))
           ((torn-down) (if (eq? (cadddr ev) 'returned) 400 40))
           ((left) left)
           ((self-stop) 4)
           (else 400)))
        ((caller) (if (eq? (caddr ev) 'deadline) deadline 400))
        ((server) stop)
        ((stopper) (if (eq? (caddr ev) 'start) stop 400))
        ((spurious) 40)
        (else 400)))))

(define fired (make-eq-hashtable))
(define (note-row row) (hashtable-update! fired row (lambda (n) (+ n 1)) 0))

(define started (real-time))

;; Runs every walk; answers (failures steps first-failure).
(define (run-walks)
  (let loop ((i 0) (failures 0) (steps 0) (first #f))
    (if (= i walks)
        (list failures steps first)
        (let* ((p (make-prng (+ (* seed 1000003) i)))
               (c (draw-config p))
               (weights (draw-weights p))
               (w (walk c p weights note-row)))
          (loop (+ i 1)
                (if (walked-failure w) (+ failures 1) failures)
                (+ steps (walked-steps w))
                (or first (and (walked-failure w) (list i c (walked-failure w)))))))))

(define result
  (guard (x (#t (display "worker-walks: raised ") (display (describe x)) (newline)
                (list 'raised 0 #f)))
    (run-walks)))

(when (caddr result)
  (let ((f (caddr result)))
    (display "walk ")
    (display (car f))
    (display ", seeded ")
    (display (+ (* seed 1000003) (car f)))
    (display ", ")
    (write (config->datum (cadr f)))
    (newline)
    (print-report (caddr f) (current-output-port))))

(display "worker-walks: ")
(display (cadr result))
(display " steps, ")
(display (/ (- (real-time) started) 1000.0))
(display " s, peak memory ")
(display (div (maximum-memory-bytes) 1000000))
(display " MB")
(newline)
(display "rows fired: ")
(write (map (lambda (row) (cons row (hashtable-ref fired row 0))) row-ids))
(newline)

(test-equal "every walk holds every check" 0 (car result))

(test-assert "the walks took at least 1,690,516 steps" (>= (cadr result) 1690516))

(test-equal "every row of the table fires in some walk"
  '()
  (filter (lambda (row) (= 0 (hashtable-ref fired row 0))) row-ids))

(test-end "worker-walks")

(exit (suite-exit-status runner))
