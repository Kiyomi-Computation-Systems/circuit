#!r6rs
;;; (circuit worker shell): the shell's own rows, on real threads.
;;;
;;;   1. The argument checks of make-worker, make-test-worker,
;;;      make-shell-worker, worker-call and worker-stop!: each refusal's
;;;      kind and who, a refused maker calling no set-up, and the values on
;;;      each side of the cap's and the threads' limits accepted.
;;;   2. A few plain calls to a real worker through the server's test host:
;;;      one value, two, none, and a raise of a non-condition.
;;;   3. The broken worker, on a real worker, by a step that raises,
;;;      injected through make-shell-worker: an outer handler shaped like
;;;      wrap-catch runs with the lock free and interrupts enabled; every
;;;      ticket the machine held is told the broken &error; a later call
;;;      raises it; an abandon passes its deadline on; worker-stop! joins
;;;      every thread; the same with a continuable raise and an outer handler
;;;      that returns; and a maker on a broken start.
;;;   4. A step that allocates until a collect request is deferred, whose
;;;      collect-request handler raises once the section enables
;;;      interrupts: the lock is free there; and with effects still to
;;;      carry out, the raise breaks the worker.
;;;   5. Every other place a break can start: the maker's own look; a
;;;      worker's own stop once broken; a thread's held next after a wait; a
;;;      stopper's second stop, and the observer's raise at its held note,
;;;      its wait note, its section's point and its first post's point; a
;;;      job given and not yet running; an idle thread woken; the lock read
;;;      from a note; and a step's interrupt depth.
;;;   6. The observer's raise, or exit, at a thread's blocking points: after
;;;      a set-up's step, a job's end step, a torn-down step, a failed
;;;      set-up's step, and a set-up that fails once the worker is broken;
;;;      and an exit while the after-thunk carries out a left job's posts, or
;;;      at its torn-down step's point, once it has torn down.
;;;   7. The double: a value, a raise, a wait inside a job, refused off the
;;;      loop's thread, a stop during a call while the job is still given,
;;;      and a stop while it runs.
;;;   8. The double again: broken while its job runs, and a job that leaves
;;;      its thread.
;;;
;;; Each row runs a scenario and compares what it gathered whole.
;;;
;;; What is bounded: every row's scenario runs on a thread of its own, which
;;; the suite waits for at most 6 s (a refusal or an accepted maker in row
;;; 1, at most 4 s or 6 s). A scenario that hasn't answered by then is the
;;; row's answer timed-out, and its thread is left behind, so a shell that
;;; hangs fails that row and the suite goes on. The host is called only from
;;; the row's thread. Inside a scenario, each wait for a helper or a worker
;;; thread to reach a point (a job at its gate, a logged note, a post, a
;;; live count) is bounded at 3 s.
;;;
;;; One hang reaches past its row: a call that never returns from inside a
;;; host call, as the double's register can. The server's scheduler keeps
;;; the coroutine it runs in its library's own state, so every later host
;;; call, on any thread, is refused as a drain from a coroutine, and each
;;; later row through a host fails at once. The double's rows come last for
;;; that reason; the suite still ends.
;;;
;;; The observer rows use one test observer (a watch): it logs every point
;;; and note, can hold one thread at the first blocking point a predicate
;;; matches, makes a caller's wait raise once no correct shell would wait
;;; (the machine seen stopped, or the row saying so), and calls a row's hook
;;; at each, which may raise or exit there.
;;;
;;; A raise that escapes a worker thread prints a line: row 3's broken start
;;; ("injected at thread 2's set-up step"), row 5's held next ("injected at
;;; thread 2's held next"), and row 6's raises ("injected at ..."), but for
;;; the torn-down row's, which it catches.
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (circuit worker shell)
        (only (circuit worker machine) step machine-phase)
        (http-server)
        (http-server testing)
        (only (chezscheme) fork-thread thread-join make-mutex mutex-acquire mutex-release
              make-condition condition-wait condition-broadcast sleep make-time real-time
              disable-interrupts enable-interrupts
              collect-request-handler collect collect-trip-bytes bytes-allocated
              console-error-port))

(define runner (test-runner-simple))
(test-runner-current runner)

(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (flush-output-port (current-output-port))
      (when (memq (test-result-kind r) '(fail xpass))
        (display "  expected: ")
        (write (test-result-ref r 'expected-value))
        (newline)
        (display "  actual:   ")
        (write (test-result-ref r 'actual-value))
        (newline)
        (flush-output-port (current-output-port))))))

(test-begin "worker-shell")

;;; --- helpers -------------------------------------------------------------

(define no-raise (list 'no-raise))

;; A duration of N ms, at least 1.
(define (ms n)
  (let ((n (max n 1)))
    (make-time 'time-duration (* (mod n 1000) 1000000) (div n 1000))))

(define-record-type cell (fields (mutable v)))

;; THUNK's value, run on a thread of its own, or timed-out when it hasn't
;; answered within BOUND ms: a hang fails its row, and its thread is left
;; behind. A raise in THUNK is raised again here. Threads left behind can
;; use up those the process may fork; then the answer is could-not-fork.
(define (within bound thunk)
  (let* ((mx (make-mutex)) (cv (make-condition)) (out #f)
         (forked (guard (e (#t #f))
                   (fork-thread
                    (lambda ()
                      (let ((r (guard (e (#t (cons 'raised e))) (cons 'value (thunk)))))
                        (mutex-acquire mx)
                        (set! out r)
                        (condition-broadcast cv)
                        (mutex-release mx)))))))
    (if (not forked)
        'could-not-fork
        (let ((deadline (+ (real-time) bound)))
          (mutex-acquire mx)
          (let loop ()
            (cond (out
                   (mutex-release mx)
                   (if (eq? (car out) 'raised) (raise (cdr out)) (cdr out)))
                  ((>= (real-time) deadline) (mutex-release mx) 'timed-out)
                  (else (condition-wait cv mx (ms (- deadline (real-time)))) (loop))))))))

;; A row's scenario: run within 6 s, on a thread of its own; a raise from
;; it is the row's answer, as (row-raised shape).
(define-syntax bounded
  (syntax-rules ()
    ((_ body ...)
     (within 6000 (lambda () (guard (e (#t (list 'row-raised (shape e)))) body ...))))))

;; A refusal's kind and who, or the no-raise sentinel, or timed-out.
(define (refusal thunk)
  (let ((e (within 4000 (lambda () (guard (e (#t e)) (thunk) no-raise)))))
    (cond ((eq? e no-raise) no-raise)
          ((eq? e 'timed-out) 'timed-out)
          (else (list (assertion-violation? e) (and (who-condition? e) (condition-who e)))))))

;; A raised object, as a row compares it: a condition's kinds, who and
;; message, or the object itself.
(define (shape e)
  (if (condition? e)
      (list (worker-full? e) (worker-stopped? e) (error? e) (assertion-violation? e)
            (and (who-condition? e) (condition-who e))
            (and (message-condition? e) (condition-message e)))
      (list 'not-a-condition e)))

(define stopped-shape '(#f #t #t #f worker-call "the worker has stopped"))
(define broken-shape '(#f #f #t #f worker-call "the worker is broken"))
(define left-shape '(#f #f #t #f worker-call "the job left its thread"))

;; What a call answered: the list of its values, or (raised e).
(define (answer thunk)
  (guard (e (#t (list 'raised e))) (call-with-values thunk list)))

(define (answer-shape a)
  (if (and (pair? a) (eq? (car a) 'raised)) (list 'raised (shape (cadr a))) a))

;; worker-stop!'s outcome: returned, or its raise's shape.
(define (stop-outcome w)
  (guard (e (#t (list 'raised (shape e)))) (worker-stop! w) 'returned))

;; The interrupt depth, read by disabling once, then every level enabled
;; again, so a shell that leaked a disable leaves this thread enabled.
(define (interrupt-depth!)
  (let ((n (disable-interrupts)))
    (let loop ((i n))
      (when (> i 0) (enable-interrupts) (loop (- i 1))))
    n))

;; A gate: a job that says it runs, then waits for the gate to open.
(define-record-type gate (fields mx cv (mutable running?) (mutable open?)))

(define (new-gate) (make-gate (make-mutex) (make-condition) #f #f))

(define (gate-job g v)
  (lambda (s)
    (mutex-acquire (gate-mx g))
    (gate-running?-set! g #t)
    (condition-broadcast (gate-cv g))
    (let loop ()
      (unless (gate-open? g) (condition-wait (gate-cv g) (gate-mx g)) (loop)))
    (mutex-release (gate-mx g))
    (list v s)))

;; Wait at most 3 s for G's job to run; whether it did.
(define (await-running g)
  (let ((deadline (+ (real-time) 3000)) (mx (gate-mx g)))
    (mutex-acquire mx)
    (let loop ()
      (cond ((gate-running? g) (mutex-release mx) #t)
            ((> (real-time) deadline) (mutex-release mx) #f)
            (else (condition-wait (gate-cv g) mx (ms 50)) (loop))))))

(define (open-gate! g)
  (mutex-acquire (gate-mx g))
  (gate-open?-set! g #t)
  (condition-broadcast (gate-cv g))
  (mutex-release (gate-mx g)))

;; A bench: a test host whose handler, inside awaiting, runs the call the
;; test set before the send, then answers an empty 200.
(define-record-type bench (fields host (mutable call)))

(define (new-bench)
  (letrec ((b (make-bench
               (make-test-host
                (lambda (req)
                  (let ((call (bench-call b)))
                    (awaiting (lambda () (call) (make-response 200 #f '() #f))))))
               #f)))
    b))

(define get-bytes (string->utf8 "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))

;; Send one request whose handler runs CALL; the client.
(define (send! b call)
  (bench-call-set! b call)
  (let ((c (test-host-connect! (bench-host b))))
    (test-client-send! c get-bytes)
    c))

(define (statuses c) (map test-response-status (test-client-responses c)))

;; A call whose answer is kept in a cell: (values cell client).
(define (call-kept b thunk)
  (let* ((kept (make-cell 'unanswered))
         (c (send! b (lambda () (cell-v-set! kept (answer thunk))))))
    (values kept c)))

;; Wait at most 3 s for a post to the host, then hand it over.
(define (settle! b)
  (let ((host (bench-host b)) (deadline (+ (real-time) 3000)))
    (let loop ()
      (when (and (= 0 (test-host-posted host)) (< (real-time) deadline))
        (sleep (ms 1))
        (loop)))
    (test-host-advance! host 0)))

;; A watch: the test observer. Its hook, if set, is called with each
;; point's or note's kind, party and info, after the watch has logged it,
;; on the thread that reached it: a row's hook may raise there, or exit.
(define-record-type watch
  (fields mx cv (mutable log) hold? (mutable held?) (mutable released?) (mutable doomed?)
          (mutable hook)))

;; HOLD? : Symbol Party Info -> Boolean, asked at blocking points until it
;; first answers true.
(define (new-watch hold?) (make-watch (make-mutex) (make-condition) '() hold? #f #f #f #f))

(define (watch-observer wa)
  (lambda (kind party tid info)
    (let ((mx (watch-mx wa)))
      (mutex-acquire mx)
      (watch-log-set! wa (cons (list kind party info) (watch-log wa)))
      (when (and (memq kind '(section held)) (eq? (machine-phase (caddr info)) 'stopped))
        (watch-doomed?-set! wa #t))
      (condition-broadcast (watch-cv wa))
      (let* ((refuse? (and (eq? kind 'wait) (eq? (car party) 'caller) (watch-doomed? wa)))
             (hold? (and (memq kind '(section effect effected))
                         (not (watch-held? wa))
                         ((watch-hold? wa) kind party info))))
        (when hold?
          (watch-held?-set! wa #t)
          (let loop ()
            (unless (watch-released? wa) (condition-wait (watch-cv wa) mx) (loop))))
        (mutex-release mx)
        (let ((hook (watch-hook wa))) (when hook (hook kind party info)))
        (when refuse? (raise 'a-caller-waited-with-nothing-to-wait-for))))))

(define (watch-set! wa set)
  (mutex-acquire (watch-mx wa))
  (set wa #t)
  (condition-broadcast (watch-cv wa))
  (mutex-release (watch-mx wa)))

(define (release! wa) (watch-set! wa watch-released?-set!))
(define (doom! wa) (watch-set! wa watch-doomed?-set!))

;; Wait at most 3 s for a logged (kind party info) that PRED takes; it, or #f.
(define (watch-wait-for wa pred)
  (let ((deadline (+ (real-time) 3000)) (mx (watch-mx wa)))
    (mutex-acquire mx)
    (let loop ()
      (let ((hit (find pred (watch-log wa))))
        (cond (hit (mutex-release mx) hit)
              ((> (real-time) deadline) (mutex-release mx) #f)
              (else (condition-wait (watch-cv wa) mx (ms 50)) (loop)))))))

(define (stopper-held? x) (and (eq? (car x) 'held) (equal? (cadr x) '(stopper))))

(define (thread-2-waits? x) (and (eq? (car x) 'wait) (equal? (cadr x) '(thread 2))))

(define (caller-waits? x) (and (eq? (car x) 'wait) (eq? (car (cadr x)) 'caller)))

(define (unmarked-check? x)
  (and (eq? (car x) 'mark) (eq? (car (cadr x)) 'caller) (not (cadr (caddr x)))))

;; worker-stop! on a thread of its own: the thread, and a cell for its outcome.
(define (fork-stopper w)
  (let* ((out (make-cell 'unset))
         (t (fork-thread (lambda () (cell-v-set! out (stop-outcome w))))))
    (values t out)))

;; A step that raises whenever ARMED holds, by RAISE.
(define (raising-step armed raise-it)
  (lambda (m ev) (if (cell-v armed) (raise-it) (step m ev))))

;; A catch shaped like wrap-catch: its handler runs where the raise
;; happened, reads the interrupt depth and whether W's lock is free, keeps
;; them in SEEN, newest first, and escapes, or answers RESUME? 's value
;; for a raise it takes.
(define (outer-catch w seen resume? thunk)
  (call/cc
   (lambda (k)
     (with-exception-handler
      (lambda (e)
        (let* ((n (interrupt-depth!))
               (free (worker-lock-free? w)))
          (cell-v-set! seen (cons (list e free n) (cell-v seen)))
          (if (resume? e) 'resumed (k (list 'raised e)))))
      thunk))))

(define (never e) #f)

;; A tear-down that counts its runs, under a mutex of its own.
(define (counting-tear-down)
  (counting-tear-down-after 0))

;; The same, each run taking PAUSE ms first.
(define (counting-tear-down-after pause)
  (let ((n (make-cell 0)) (mx (make-mutex)))
    (values (lambda (s)
              (when (> pause 0) (sleep (ms pause)))
              (mutex-acquire mx)
              (cell-v-set! n (+ (cell-v n) 1))
              (mutex-release mx))
            n)))

;; A tear-down that keeps the interrupt depth its thread shows, each run's
;; newest first.
(define (depth-tear-down)
  (let ((seen (make-cell '())) (mx (make-mutex)))
    (values (lambda (s)
              (let ((n (interrupt-depth!)))
                (mutex-acquire mx)
                (cell-v-set! seen (cons n (cell-v seen)))
                (mutex-release mx)))
            seen)))

;; Wait at most 3 s for W's live count to fall to N; whether it did.
(define (live-falls-to w n)
  (let ((deadline (+ (real-time) 3000)))
    (let loop ()
      (cond ((= n (worker-live-count w)) #t)
            ((> (real-time) deadline) #f)
            (else (sleep (ms 1)) (loop))))))

;; Whether a row answered a list of N, not timed-out or a raise.
(define (whole? r n) (and (list? r) (= (length r) n) (not (eq? (car r) 'row-raised))))

;; Whether every answer is (raised e), with one and the same e.
(define (same-raise? answers)
  (and (pair? answers)
       (for-all (lambda (a) (and (pair? a) (eq? (car a) 'raised) (pair? (cdr a)))) answers)
       (let ((e (cadr (car answers))))
         (for-all (lambda (a) (eq? (cadr a) e)) answers))))

;;; --- 1. argument checks --------------------------------------------------

(define refused-set-ups (make-cell 0))
(define (refused-set-up) (cell-v-set! refused-set-ups (+ 1 (cell-v refused-set-ups))) 'refused)
(define (plain-set-up) 'plain)
(define big-threads (+ (greatest-fixnum) 1))

(test-equal "make-worker refuses a set-up that isn't a procedure"
  '(#t make-worker) (refusal (lambda () (make-worker 'not-a-procedure 0))))
(test-equal "make-worker refuses a cap of -1"
  '(#t make-worker) (refusal (lambda () (make-worker refused-set-up -1))))
(test-equal "make-worker refuses a cap of 1.5"
  '(#t make-worker) (refusal (lambda () (make-worker refused-set-up 1.5))))
(test-equal "make-worker refuses a cap of 2.0"
  '(#t make-worker) (refusal (lambda () (make-worker refused-set-up 2.0))))
(test-equal "make-worker refuses a cap of 3/2"
  '(#t make-worker) (refusal (lambda () (make-worker refused-set-up 3/2))))
(test-equal "make-worker refuses 0 threads"
  '(#t make-worker) (refusal (lambda () (make-worker refused-set-up 0 0))))
(test-equal "make-worker refuses a bignum of threads"
  '(#t make-worker) (refusal (lambda () (make-worker refused-set-up 0 big-threads))))
(test-equal "make-worker refuses a tear-down that isn't a procedure"
  '(#t make-worker) (refusal (lambda () (make-worker refused-set-up 0 1 #f))))
(test-equal "make-worker with a tear-down refuses a set-up that isn't a procedure"
  '(#t make-worker) (refusal (lambda () (make-worker 'not-a-procedure 0 1 (lambda (s) s)))))
(test-equal "make-worker with a tear-down refuses a cap of -1"
  '(#t make-worker) (refusal (lambda () (make-worker refused-set-up -1 1 (lambda (s) s)))))
(test-equal "make-worker with a tear-down refuses 0 threads"
  '(#t make-worker) (refusal (lambda () (make-worker refused-set-up 0 0 (lambda (s) s)))))
(test-equal "make-test-worker refuses a set-up that isn't a procedure"
  '(#t make-test-worker) (refusal (lambda () (make-test-worker 'not-a-procedure))))
(test-equal "make-test-worker refuses a tear-down that isn't a procedure"
  '(#t make-test-worker) (refusal (lambda () (make-test-worker refused-set-up 'no))))
(test-equal "make-test-worker with a tear-down refuses a set-up that isn't a procedure"
  '(#t make-test-worker) (refusal (lambda () (make-test-worker 'not-a-procedure (lambda (s) s)))))

(define (shell-refusal observer stepper double? set-up cap threads tear-down)
  (refusal (lambda () (make-shell-worker observer stepper double? set-up cap threads tear-down))))

(test-equal "make-shell-worker refuses an observer that isn't #f or a procedure"
  '(#t make-shell-worker) (shell-refusal 'no step #f refused-set-up 0 1 #f))
(test-equal "make-shell-worker refuses a step that isn't a procedure"
  '(#t make-shell-worker) (shell-refusal #f 'no #f refused-set-up 0 1 #f))
(test-equal "make-shell-worker refuses a double? that isn't a boolean"
  '(#t make-shell-worker) (shell-refusal #f step 'yes refused-set-up 0 1 #f))
(test-equal "make-shell-worker refuses a set-up that isn't a procedure"
  '(#t make-shell-worker) (shell-refusal #f step #f 'no 0 1 #f))
(test-equal "make-shell-worker refuses a cap of -1"
  '(#t make-shell-worker) (shell-refusal #f step #f refused-set-up -1 1 #f))
(test-equal "make-shell-worker refuses 0 threads"
  '(#t make-shell-worker) (shell-refusal #f step #f refused-set-up 0 0 #f))
(test-equal "make-shell-worker refuses a tear-down that isn't #f or a procedure"
  '(#t make-shell-worker) (shell-refusal #f step #f refused-set-up 0 1 'no))
(test-equal "make-shell-worker refuses a double with a cap of 1"
  '(#t make-shell-worker) (shell-refusal #f step #t refused-set-up 1 1 #f))
(test-equal "make-shell-worker refuses a double with 2 threads"
  '(#t make-shell-worker) (shell-refusal #f step #t refused-set-up 0 2 #f))

(test-equal "a refused maker calls no set-up" 0 (cell-v refused-set-ups))

;; A maker's worker, its kind, and its live count once stopped, within 6 s.
(define (accepts make)
  (within 6000
          (lambda ()
            (guard (e (#t (list 'raised (shape e))))
              (let* ((w (make)) (kind (worker? w)) (stop (stop-outcome w)))
                (list kind stop (worker-live-count w)))))))

(test-equal "make-worker takes a cap of 0"
  '(#t returned 0) (accepts (lambda () (make-worker plain-set-up 0))))
(test-equal "make-worker takes a bignum cap"
  '(#t returned 0) (accepts (lambda () (make-worker plain-set-up (expt 2 100)))))
(test-equal "make-worker takes 1 thread"
  '(#t returned 0) (accepts (lambda () (make-worker plain-set-up 0 1))))
(test-equal "make-worker takes a tear-down"
  '(#t returned 0) (accepts (lambda () (make-worker plain-set-up 0 2 (lambda (s) s)))))
(test-equal "make-test-worker takes a set-up, and a tear-down"
  '((#t returned 0) (#t returned 0))
  (let* ((one (accepts (lambda () (make-test-worker plain-set-up))))
         (two (accepts (lambda () (make-test-worker plain-set-up (lambda (s) s))))))
    (list one two)))
(test-equal "make-shell-worker takes an observer, a double and a tear-down"
  '((#t returned 0) (#t returned 0))
  (let* ((one (accepts (lambda () (make-shell-worker (lambda args #f) step #f plain-set-up 3 2
                                                     (lambda (s) s)))))
         (two (accepts (lambda () (make-shell-worker #f step #t plain-set-up 0 1 #f)))))
    (list one two)))

(test-equal "worker-call refuses a value that isn't a worker"
  '(#t worker-call) (refusal (lambda () (worker-call 'not-a-worker (lambda (s) s)))))
;; Off any host, so a check after await-outside's own would name await-outside.
(test-equal "worker-call refuses a job that isn't a procedure, before it waits"
  '((#t worker-call) returned)
  (bounded
    (let* ((w (make-worker plain-set-up 0))
           (r (refusal (lambda () (worker-call w 'not-a-job))))
           (stop (stop-outcome w)))
      (list r stop))))
(test-equal "worker-stop! refuses a value that isn't a worker"
  '(#t worker-stop!) (refusal (lambda () (worker-stop! 'not-a-worker))))

;;; --- 2. plain calls ------------------------------------------------------

(define thrown (list 'thrown))

(define plain-rows
  (bounded
    (let* ((w (make-worker (lambda () 'plain-state) 0))
           (b (new-bench))
           (call (lambda (job)
                   (let-values (((kept c) (call-kept b (lambda () (worker-call w job)))))
                     (settle! b)
                     (list (cell-v kept) (statuses c)))))
           (one (call (lambda (s) (list 'one s))))
           (two (call (lambda (s) (values 'two s))))
           (none (call (lambda (s) (values))))
           (raised (call (lambda (s) (raise thrown))))
           (stop (stop-outcome w)))
      (list one two none raised
            (and (pair? (car raised)) (pair? (cdar raised)) (eq? (cadar raised) thrown))
            stop (worker-live-count w)))))

(define (plain-part . is) (if (whole? plain-rows 7) (map (lambda (i) (list-ref plain-rows i)) is) plain-rows))

(test-equal "a real worker answers a job's one value"
  '((((one plain-state)) (200))) (plain-part 0))
(test-equal "a real worker answers a job's two values"
  '(((two plain-state) (200))) (plain-part 1))
(test-equal "a real worker answers a job's no values"
  '((() (200))) (plain-part 2))
(test-equal "a real worker raises a job's raise of a non-condition, the same object"
  (list (list (list 'raised thrown) '(200)) #t) (plain-part 3 4))
(test-equal "a real worker's stop leaves no thread live"
  '(returned 0) (plain-part 5 6))

;;; --- 3. the broken worker -------------------------------------------------

;; One thread, a cap of 2. A runs at a gate, B and C queue; then the step
;; raises at D's call. D's outer handler reads the lock and the interrupts.
;; The tear-down takes 50 ms, so a stop that returned before its joins
;; would find the thread live.
(define broken-rows
  (bounded
    (let-values (((tear-down torn) (counting-tear-down-after 50)))
      (let* ((inj (make-message-condition "injected at D's call"))
             (armed (make-cell #f))
             (w (make-shell-worker #f (raising-step armed (lambda () (raise inj))) #f
                                   (lambda () 'broken-state) 2 1 tear-down))
             (b (new-bench))
             (g (new-gate)))
        (let*-values (((a ca) (call-kept b (lambda () (worker-call w (gate-job g 'ran)))))
                      ((running) (await-running g))
                      ((bb cb) (call-kept b (lambda () (worker-call w (lambda (s) 'never)))))
                      ((cc cc-client) (call-kept b (lambda () (worker-call w (lambda (s) 'never))))))
          (cell-v-set! armed #t)
          (let* ((seen (make-cell '()))
                 (d (make-cell 'unanswered))
                 (dc (send! b (lambda () (cell-v-set! d (outer-catch w seen never
                                                                      (lambda () (worker-call w (lambda (s) 'd)))))))))
            (test-host-advance! (bench-host b) 0)
            (let* ((told (map cell-v (list a bb cc)))
                   (e (and (pair? (car told)) (pair? (cdar told)) (cadar told)))
                   (later (let-values (((k2 c2) (call-kept b (lambda () (worker-call w (lambda (s) s))))))
                            (cell-v k2)))
                   (seen-d (map (lambda (x) (list (eq? (car x) inj) (cadr x) (caddr x)))
                                (reverse (cell-v seen))))
                   (free? (and (pair? seen-d) (cadr (car seen-d)))))
              (open-gate! g)
              (let* ((stop (if free? (stop-outcome w) 'not-stopped-with-the-lock-held))
                     (live (if free? (worker-live-count w) 'not-counted))
                     (tore (cell-v torn)))
                (list running
                      seen-d
                      (map answer-shape told)
                      (and e (for-all (lambda (t) (and (pair? t) (pair? (cdr t)) (eq? (cadr t) e))) told))
                      (answer-shape later)
                      (and e (pair? later) (pair? (cdr later)) (eq? (cadr later) e))
                      stop live tore)))))))))

(test-equal "broken: the outer handler runs with the lock free and interrupts enabled"
  '(#t ((#t #t 1))) (if (whole? broken-rows 9) (list (list-ref broken-rows 0) (list-ref broken-rows 1)) broken-rows))
(test-equal "broken: every ticket the machine held is told the same broken &error"
  (list (list (list 'raised broken-shape) (list 'raised broken-shape) (list 'raised broken-shape)) #t)
  (if (whole? broken-rows 9) (list (list-ref broken-rows 2) (list-ref broken-rows 3)) broken-rows))
(test-equal "broken: a later call raises the same &error"
  (list (list 'raised broken-shape) #t)
  (if (whole? broken-rows 9) (list (list-ref broken-rows 4) (list-ref broken-rows 5)) broken-rows))
(test-equal "broken: worker-stop! joins every thread, which tore down, and returns"
  '(returned 0 1)
  (if (whole? broken-rows 9) (list-tail broken-rows 6) broken-rows))

;; The broken &error's posts are refused once the host's inbox is
;; stopped, so B's deadline comes first: its abandon finds the worker
;; broken and steps nothing (the step raises on every event once armed).
(define broken-abandon
  (bounded
    (let* ((inj (make-message-condition "injected at C's call"))
           (armed (make-cell #f))
           (w (make-shell-worker #f (raising-step armed (lambda () (raise inj))) #f
                                 (lambda () 'abandon-state) 1 1 #f))
           (b (new-bench))
           (host (bench-host b))
           (g (new-gate)))
      (let*-values (((a ca) (call-kept b (lambda () (worker-call w (gate-job g 'ran)))))
                    ((running) (await-running g)))
        (let* ((seen-b (make-cell '()))
               (bb (make-cell 'unanswered))
               (bc (send! b (lambda ()
                              (cell-v-set! bb (outer-catch w seen-b never
                                                           (lambda ()
                                                             (with-deadline 100
                                                               (lambda () (worker-call w (lambda (s) 'never)))))))))))
          (test-host-stop-posts! host)
          (cell-v-set! armed #t)
          (let* ((seen-c (make-cell '()))
                 (cv (make-cell 'unanswered))
                 (cc (send! b (lambda ()
                                (cell-v-set! cv (outer-catch w seen-c never
                                                             (lambda () (worker-call w (lambda (s) 'c)))))))))
            (test-host-advance! host 100)
            (let ((b-seen (map (lambda (x) (list (deadline-passed? (car x)) (cadr x) (caddr x)))
                               (reverse (cell-v seen-b))))
                  (c-seen (map (lambda (x) (eq? (car x) inj)) (reverse (cell-v seen-c)))))
              (open-gate! g)
              (let* ((waiting (test-client-waiting? ca))
                     (stop (if (and (pair? b-seen) (cadr (car b-seen))) (stop-outcome w) 'not-stopped))
                     (live (worker-live-count w)))
                (list running c-seen b-seen waiting stop live)))))))))

(test-equal "broken: an abandon passes its deadline on unchanged"
  '(#t (#t) ((#t #t 1)) #t returned 0)
  broken-abandon)

;; As broken-rows, with a continuable raise and an outer handler that
;; returns for it: the section's handler passes it on with raise, so the
;; return comes back as &non-continuable, to the same outer handler.
(define broken-continuable
  (bounded
    (let-values (((tear-down torn) (counting-tear-down)))
      (let* ((inj (make-message-condition "injected at C's call, continuably"))
             (armed (make-cell #f))
             (w (make-shell-worker #f (raising-step armed (lambda () (raise-continuable inj) (raise inj)))
                                   #f (lambda () 'continuable-state) 1 1 tear-down))
             (b (new-bench))
             (g (new-gate)))
        (let*-values (((a ca) (call-kept b (lambda () (worker-call w (gate-job g 'ran)))))
                      ((running) (await-running g))
                      ((bb cb) (call-kept b (lambda () (worker-call w (lambda (s) 'never))))))
          (cell-v-set! armed #t)
          (let* ((seen (make-cell '()))
                 (cv (make-cell 'unanswered))
                 (cc (send! b (lambda ()
                                (cell-v-set! cv (outer-catch w seen (lambda (e) (eq? e inj))
                                                             (lambda () (worker-call w (lambda (s) 'c)))))))))
            (test-host-advance! (bench-host b) 0)
            (let* ((seen-c (map (lambda (x)
                                  (list (eq? (car x) inj) (non-continuable-violation? (car x))
                                        (cadr x) (caddr x)))
                                (reverse (cell-v seen))))
                   (free? (and (pair? seen-c) (for-all caddr seen-c)))
                   (told (map cell-v (list a bb)))
                   (later (let-values (((k2 c2) (call-kept b (lambda () (worker-call w (lambda (s) s))))))
                            (cell-v k2))))
              (open-gate! g)
              (let* ((stop (if free? (stop-outcome w) 'not-stopped-with-the-lock-held))
                     (live (if free? (worker-live-count w) 'not-counted))
                     (tore (cell-v torn)))
                (list running seen-c (map answer-shape told) (answer-shape later) stop live tore)))))))))

(test-equal "broken, continuably: the outer handler's return comes back as &non-continuable"
  (list #t '((#t #f #t 1) (#f #t #t 1))
        (list (list 'raised broken-shape) (list 'raised broken-shape))
        (list 'raised broken-shape) 'returned 0 1)
  broken-continuable)

;; Thread 2's set-up step raises, on its own thread. Each tear-down takes
;; 50 ms, so a maker that raised before joining would find one missing.
(define broken-start
  (bounded
    (let* ((inj (make-message-condition "injected at thread 2's set-up step, for the broken start row"))
           (torn (make-cell 0))
           (mx (make-mutex))
           (tear-down (lambda (s)
                        (sleep (ms 50))
                        (mutex-acquire mx)
                        (cell-v-set! torn (+ 1 (cell-v torn)))
                        (mutex-release mx)))
           (r (guard (e (#t (list 'raised e)))
                (make-shell-worker #f
                                   (lambda (m ev)
                                     (if (and (eq? (car ev) 'set-up) (eqv? (cadr ev) 2))
                                         (raise inj)
                                         (step m ev)))
                                   #f (lambda () 'start-state) 0 2 tear-down)
                'returned))
           (n (begin (mutex-acquire mx) (let ((n (cell-v torn))) (mutex-release mx) n))))
      (list (answer-shape r) n))))

(test-equal "broken: a maker on a broken start joins every thread, then raises the &error"
  (list (list 'raised broken-shape) 2)
  broken-start)

;;; --- 4. a collect request deferred in a section ---------------------------

;; Allocate twice the collect trip with interrupts disabled, inside the
;; step, so a collect request is deferred to the section's end.
(define sink (make-cell #f))
(define (allocate-past-trip!)
  (let ((goal (+ (bytes-allocated) (* 2 (collect-trip-bytes)))))
    (let loop ()
      (when (< (bytes-allocated) goal)
        (cell-v-set! sink (make-vector 1024))
        (loop)))))

;; One thread, no queue: A runs at a gate, so B's call is refused full,
;; with no effect and no ticket kept. The collect-request handler raises a
;; token, once; the catch escapes first, then reads the lock: a handler
;; running under Chez's thread mutex can't fork the thread the read needs.
(define collect-row
  (bounded
    (let* ((armed (make-cell #f))
           (fire (make-cell #f))
           (token (list 'collect-request))
           (w (make-shell-worker #f
                                 (lambda (m ev)
                                   (when (cell-v armed)
                                     (cell-v-set! armed #f)
                                     (cell-v-set! fire #t)
                                     (allocate-past-trip!))
                                   (step m ev))
                                 #f (lambda () 'gc-state) 0 1 #f))
           (b (new-bench))
           (g (new-gate))
           (old (collect-request-handler)))
      (let*-values (((a ca) (call-kept b (lambda () (worker-call w (gate-job g 'ran)))))
                    ((running) (await-running g)))
        (let ((kept (make-cell 'unanswered)))
          (collect-request-handler
           (lambda ()
             (if (cell-v fire)
                 (begin (cell-v-set! fire #f) (raise token))
                 (collect))))
          (cell-v-set! armed #t)
          (send! b (lambda ()
                     (let ((r (call/cc
                               (lambda (k)
                                 (with-exception-handler
                                  (lambda (e) (k (list 'raised e)))
                                  (lambda () (worker-call w (lambda (s) 'b))))))))
                       (let* ((n (interrupt-depth!)) (free (worker-lock-free? w)))
                         (cell-v-set! kept (list (and (pair? r) (eq? (cadr r) token)) free n))))))
          (collect-request-handler old)
          (open-gate! g)
          (let ((r (cell-v kept)))
            (list running r
                  (if (and (pair? r) (cadr r)) (stop-outcome w) 'not-stopped-with-the-lock-held))))))))

(test-equal "a collect request deferred in a section runs once the lock is free"
  '(#t (#t #t 1) returned)
  collect-row)

;; The same raise at a section's end, now with effects still to carry out:
;; the thread is idle, so the call is given it, with a signal to send. The
;; raise comes between the step and its effects, so it breaks the worker,
;; and the effects are carried out on the broken path. Otherwise the
;; signal would be lost, the slot given for good, and a later call
;; refused full. The broken path wakes the thread, which takes the lock to
;; tear down, so the lock is read only once the thread has ended.
(define collect-effects-row
  (bounded
    (let* ((armed (make-cell #f))
           (fire (make-cell #f))
           (token (list 'collect-request))
           (w (make-shell-worker #f
                                 (lambda (m ev)
                                   (when (cell-v armed)
                                     (cell-v-set! armed #f)
                                     (cell-v-set! fire #t)
                                     (allocate-past-trip!))
                                   (step m ev))
                                 #f (lambda () 'gc-effects-state) 0 1 #f))
           (b (new-bench))
           (old (collect-request-handler))
           (kept (make-cell 'unanswered)))
      (collect-request-handler
       (lambda ()
         (if (cell-v fire)
             (begin (cell-v-set! fire #f) (raise token))
             (collect))))
      (cell-v-set! armed #t)
      (send! b (lambda ()
                 (let ((r (call/cc
                           (lambda (k)
                             (with-exception-handler
                              (lambda (e) (k (list 'raised e)))
                              (lambda () (worker-call w (lambda (s) 'b))))))))
                   (let ((n (interrupt-depth!)))
                     (cell-v-set! kept (list (and (pair? r) (eq? (cadr r) token)) n))))))
      (collect-request-handler old)
      (let* ((r (cell-v kept))
             (later (let-values (((k2 c2) (call-kept b (lambda () (worker-call w (lambda (s) s))))))
                      (cell-v k2)))
             (ended (live-falls-to w 0))
             (free (worker-lock-free? w))
             (stop (if free (stop-outcome w) 'not-stopped-with-the-lock-held)))
        (list r (answer-shape later) ended free stop)))))

(test-equal "a raise at a section's end, before its effects, breaks the worker"
  (list '(#t 1) (list 'raised broken-shape) #t #t 'returned)
  collect-effects-row)

;;; --- 5. every other place a break can start ------------------------------

;; The maker's own look raises: make-worker raises it only once every
;; forked thread is joined, so each slow tear-down is done by then.
(define maker-look-raise
  (bounded
    (let-values (((tear-down torn) (counting-tear-down-after 100)))
      (let* ((inj (make-message-condition "injected at the maker's look"))
             (r (guard (e (#t (list 'raised e)))
                  (make-shell-worker #f (lambda (m ev) (if (equal? ev '(look)) (raise inj) (step m ev)))
                                     #f (lambda () 'look-state) 0 3 tear-down)
                  'returned)))
        (list (and (pair? r) (eq? (cadr r) inj)) (cell-v torn))))))

(test-equal "the maker's own raise leaves make-worker once every thread is joined"
  '(#t 3) maker-look-raise)

;; A job stops its own worker once the worker is broken: refused, as on a
;; worker's thread at any time. Let through, its join would wait for the
;; job's own thread.
(define broken-own-stop
  (bounded
    (let* ((armed (make-cell #f))
           (w (make-shell-worker #f (raising-step armed (lambda () (raise 'injected-for-the-own-stop)))
                                 #f (lambda () 'own-state) 1 1 #f))
           (b (new-bench))
           (g (new-gate))
           (mx (make-mutex))
           (seen (make-cell 'unset))
           (job (lambda (s)
                  ((gate-job g 'ran) s)
                  (let ((r (guard (e (#t (if (condition? e)
                                             (list (assertion-violation? e)
                                                   (and (who-condition? e) (condition-who e)))
                                             (list 'raised e))))
                             (worker-stop! w)
                             no-raise)))
                    (mutex-acquire mx)
                    (cell-v-set! seen r)
                    (mutex-release mx)
                    r)))
           (read-seen (lambda () (mutex-acquire mx) (let ((v (cell-v seen))) (mutex-release mx) v))))
      (let*-values (((a ca) (call-kept b (lambda () (worker-call w job))))
                    ((running) (await-running g)))
        (cell-v-set! armed #t)
        (let-values (((bk bc) (call-kept b (lambda () (worker-call w (lambda (s) 'b))))))
          (open-gate! g)
          (let* ((r (let ((deadline (+ (real-time) 3000)))
                      (let loop ()
                        (let ((v (read-seen)))
                          (if (and (eq? v 'unset) (< (real-time) deadline))
                              (begin (sleep (ms 1)) (loop))
                              v)))))
                 (stop (stop-outcome w))
                 (live (worker-live-count w)))
            (list running (answer-shape (cell-v bk)) r stop live)))))))

(test-equal "broken: worker-stop! from the worker's own thread is refused"
  (list #t '(raised (not-a-condition injected-for-the-own-stop)) '(#t worker-stop!) 'returned 0)
  broken-own-stop)

;; Two threads, no queue: thread 1 runs A at a gate, thread 2 waits. Then
;; the step raises at thread 2's next, the held step C's call wakes it to,
;; after a wait. The broken path tells A and C; thread 2's raise escapes
;; it; its tear-down sees interrupts enabled; and once it has ended, the
;; lock is free.
(define held-next-raise
  (bounded
    (let-values (((tear-down depths) (depth-tear-down)))
      (let* ((inj (make-message-condition "injected at thread 2's held next"))
             (armed (make-cell #f))
             (wa (new-watch (lambda (kind party info) #f)))
             (w (make-shell-worker (watch-observer wa)
                                   (lambda (m ev)
                                     (if (and (cell-v armed) (equal? ev '(next 2))) (raise inj) (step m ev)))
                                   #f (lambda () 'next-state) 0 2 tear-down))
             (b (new-bench))
             (g (new-gate)))
        (let*-values (((a ca) (call-kept b (lambda () (worker-call w (gate-job g 'ran)))))
                      ((running) (await-running g))
                      ((idle) (and (watch-wait-for wa thread-2-waits?) #t)))
          (cell-v-set! armed #t)
          (let-values (((c cc) (call-kept b (lambda () (worker-call w (lambda (s) 'c))))))
            (let* ((ended (live-falls-to w 1))
                   (free (worker-lock-free? w)))
              (settle! b)
              (open-gate! g)
              (let* ((stop (stop-outcome w))
                     (live (worker-live-count w))
                     (told (list (cell-v a) (cell-v c))))
                (list running idle ended free (map answer-shape told) (same-raise? told)
                      stop live (cell-v depths))))))))))

(test-equal "broken: a raise in a thread's held next, after a wait, breaks the worker"
  (list #t #t #t #t (list (list 'raised broken-shape) (list 'raised broken-shape)) #t 'returned 0 '(1 1))
  held-next-raise)

;; One thread runs A at a gate, QUEUED calls behind it. The row's thread
;; stops the worker inside an outer catch, while the step raises at the
;; STEP-AT-th (stop #f), if a number, or the observer raises at the first
;; point or note TRAP? takes, if any, CONTINUABLY or not. The outer catch
;; answers its own continuable raise by returning; the shell's raise, which
;; isn't continuable, then raises &non-continuable where the outer handler
;; was called, past the catch, so the row catches what escapes it. The
;; answer: what the outer catch saw, how the stop left it, each call's
;; answer, A's first, the host's log, a stop again, and the live count.
(define (stopper-row queued step-at trap? continuably)
  (let* ((inj (make-message-condition "injected into the stopper"))
         (do-raise (lambda () (if continuably (raise-continuable inj) (raise inj))))
         (stops (make-cell 0))
         (fired (make-cell #f))
         (wa (new-watch (lambda (kind party info) #f)))
         (w (make-shell-worker (watch-observer wa)
                               (lambda (m ev)
                                 (when (equal? ev '(stop #f))
                                   (cell-v-set! stops (+ 1 (cell-v stops)))
                                   (when (eqv? (cell-v stops) step-at) (do-raise)))
                                 (step m ev))
                               #f (lambda () 'stopper-state) queued 1 #f))
         (b (new-bench))
         (g (new-gate)))
    (watch-hook-set! wa (lambda (kind party info)
                          (when (and trap? (not (cell-v fired)) (trap? kind party info))
                            (cell-v-set! fired #t)
                            (do-raise))))
    (let*-values (((a ca) (call-kept b (lambda () (worker-call w (gate-job g 'ran)))))
                  ((running) (await-running g)))
      (let* ((behind (let loop ((i 0) (acc '()))
                       (if (= i queued)
                           (reverse acc)
                           (let-values (((k c) (call-kept b (lambda () (worker-call w (lambda (s) 'never))))))
                             (loop (+ i 1) (cons k acc))))))
             (seen (make-cell '()))
             (r (guard (e (#t (list 'escaped e)))
                  (outer-catch w seen (lambda (e) (and continuably (eq? e inj)))
                               (lambda () (worker-stop! w) 'returned)))))
        (settle! b)
        (open-gate! g)
        (let* ((stop (stop-outcome w))
               (live (worker-live-count w))
               (seen-shape (map (lambda (x)
                                  (list (eq? (car x) inj) (non-continuable-violation? (car x))
                                        (cadr x) (caddr x)))
                                (reverse (cell-v seen)))))
          (list running seen-shape
                (cond ((and (pair? r) (eq? (car r) 'raised)) (list 'caught (eq? (cadr r) inj)))
                      ((and (pair? r) (eq? (car r) 'escaped))
                       (list 'escaped (non-continuable-violation? (cadr r))))
                      (else r))
                (map (lambda (k) (answer-shape (cell-v k))) (cons a behind))
                (test-host-log (bench-host b)) stop live))))))

(define (stopper-trap kind-wanted)
  (lambda (kind party info) (and (eq? kind kind-wanted) (equal? party '(stopper)))))

(define (first-post-trap kind party info)
  (and (eq? kind 'effect) (equal? party '(stopper)) (eq? (car info) 'post)))

(define one-break '((#t #f #t 1)))
(define a-broken-b-stopped (list (list 'raised broken-shape) (list 'raised stopped-shape)))

(test-equal "broken: a raise in a stopper's second stop, its held step"
  (list #t one-break '(caught #t) a-broken-b-stopped '() 'returned 0)
  (bounded (stopper-row 1 2 #f #f)))
(test-equal "broken: an observer's raise at a stopper's held note"
  (list #t one-break '(caught #t) a-broken-b-stopped '() 'returned 0)
  (bounded (stopper-row 1 #f (stopper-trap 'held) #f)))
(test-equal "broken: an observer's raise at a stopper's wait note"
  (list #t one-break '(caught #t) a-broken-b-stopped '() 'returned 0)
  (bounded (stopper-row 1 #f (stopper-trap 'wait) #f)))
(test-equal "broken: a continuable raise at a held note isn't returned into"
  (list #t one-break '(escaped #t) a-broken-b-stopped '() 'returned 0)
  (bounded (stopper-row 1 #f (stopper-trap 'held) #t)))
;; The stop's own section point, before its effects: B's post of stopped
;; is still to carry out, so B is told the broken &error.
(test-equal "broken: a continuable raise at a section's point isn't returned into"
  (list #t one-break '(escaped #t) (list (list 'raised broken-shape) (list 'raised broken-shape)) '() 'returned 0)
  (bounded (stopper-row 1 #f (stopper-trap 'section) #t)))
;; The stop took B and C off the queue; the raise comes before either
;; post, so each pending post is the broken &error.
(test-equal "broken: a raise at an effect point makes each pending post the broken &error"
  (list #t one-break '(caught #t)
        (list (list 'raised broken-shape) (list 'raised broken-shape) (list 'raised broken-shape))
        '() 'returned 0)
  (bounded (stopper-row 2 #f first-post-trap #f)))

;; The thread is held after its set-up's wake, so A's call gives it A and
;; the signal finds no one waiting. Then B's call breaks the worker, with
;; A given and not yet running: A is told.
(define broken-while-given
  (bounded
    (let* ((wa (new-watch (lambda (kind party info)
                            (and (eq? kind 'effected) (equal? party '(thread 1))
                                 (equal? info '(wake-waiters))))))
           (armed (make-cell #f))
           (w (make-shell-worker (watch-observer wa)
                                 (raising-step armed (lambda () (raise 'injected-while-given)))
                                 #f (lambda () 'given-state) 0 1 #f))
           (b (new-bench)))
      (let-values (((a ca) (call-kept b (lambda () (worker-call w (lambda (s) 'a))))))
        (cell-v-set! armed #t)
        (let-values (((bk bc) (call-kept b (lambda () (worker-call w (lambda (s) 'b))))))
          (test-host-advance! (bench-host b) 0)
          (release! wa)
          (let* ((stop (stop-outcome w))
                 (live (worker-live-count w)))
            (list (answer-shape (cell-v a)) (answer-shape (cell-v bk)) stop live)))))))

(test-equal "broken: a job given and not yet running is told"
  (list (list 'raised broken-shape) '(raised (not-a-condition injected-while-given)) 'returned 0)
  broken-while-given)

;; Two threads: thread 1 runs A at a gate, thread 2 waits idle, when B's
;; call breaks the worker. The break must wake thread 2 to tear down, or
;; the stop's join waits for it for ever; each thread runs its tear-down
;; once.
(define broken-idle-thread
  (bounded
    (let*-values (((td tds) (counting-tear-down)))
     (let* ((wa (new-watch (lambda (kind party info) #f)))
           (armed (make-cell #f))
           (w (make-shell-worker (watch-observer wa)
                                 (raising-step armed (lambda () (raise 'injected-with-a-thread-idle)))
                                 #f (lambda () 'idle-state) 0 2 td))
           (b (new-bench))
           (g (new-gate)))
      (let*-values (((a ca) (call-kept b (lambda () (worker-call w (gate-job g 'ran)))))
                    ((running) (await-running g))
                    ((idle) (and (watch-wait-for wa thread-2-waits?) #t)))
        (cell-v-set! armed #t)
        (let-values (((bk bc) (call-kept b (lambda () (worker-call w (lambda (s) 'b))))))
          (open-gate! g)
          (let* ((stop (within 3000 (lambda () (stop-outcome w))))
                 (live (if (eq? stop 'timed-out) 'not-counted (worker-live-count w))))
            (list running idle (answer-shape (cell-v bk)) stop live (cell-v tds)))))))))

(test-equal "broken: an idle thread is woken to tear down"
  (list #t #t '(raised (not-a-condition injected-with-a-thread-idle)) 'returned 0 2)
  broken-idle-thread)

;; worker-lock-free? asked by the observer on the stopper's thread: at its
;; section's point the lock is free, and at its held note this thread
;; holds it.
(define lock-free-in-a-note
  (bounded
    (let* ((wa (new-watch (lambda (kind party info) #f)))
           (wc (make-cell #f))
           (reads (make-cell '()))
           (w (make-shell-worker (watch-observer wa) step #f (lambda () 'note-state) 0 1 #f))
           (b (new-bench))
           (g (new-gate)))
      (cell-v-set! wc w)
      (let*-values (((a ca) (call-kept b (lambda () (worker-call w (gate-job g 'ran)))))
                    ((running) (await-running g)))
        (watch-hook-set! wa (lambda (kind party info)
                              (when (and (equal? party '(stopper)) (memq kind '(section held)))
                                (cell-v-set! reads (cons (list kind (worker-lock-free? (cell-v wc)))
                                                         (cell-v reads))))))
        (let* ((opener (fork-thread (lambda () (watch-wait-for wa stopper-held?) (open-gate! g))))
               (stop (stop-outcome w))
               (joined (within 3000 (lambda () (thread-join opener) 'joined)))
               (r (reverse (cell-v reads))))
          (list running (if (and (pair? r) (pair? (cdr r))) (list (car r) (cadr r)) r)
                stop joined (worker-live-count w)))))))

(test-equal "worker-lock-free? answers #f while this thread holds the lock"
  '(#t ((section #t) (held #f)) returned joined 0)
  lock-free-in-a-note)

;; A step that reads the interrupt depth: 2 in a section and in a held
;; step, the shell's disable and its own.
(define step-depths
  (bounded
    (let* ((depths (make-cell '()))
           (mx (make-mutex))
           (w (make-shell-worker #f
                                 (lambda (m ev)
                                   (let ((n (disable-interrupts)))
                                     (enable-interrupts)
                                     (mutex-acquire mx)
                                     (cell-v-set! depths (cons (cons (car ev) n) (cell-v depths)))
                                     (mutex-release mx))
                                   (step m ev))
                                 #f (lambda () 'depth-state) 0 1 #f))
           (b (new-bench)))
      (let-values (((k c) (call-kept b (lambda () (worker-call w (lambda (s) 'd))))))
        (settle! b)
        (let* ((stop (stop-outcome w))
               (pairs (begin (mutex-acquire mx) (let ((p (cell-v depths))) (mutex-release mx) p)))
               (seen (lambda (kinds)
                       (let loop ((ps pairs) (acc '()))
                         (cond ((null? ps) (list-sort < acc))
                               ((and (memq (car (car ps)) kinds) (not (memv (cdr (car ps)) acc)))
                                (loop (cdr ps) (cons (cdr (car ps)) acc)))
                               (else (loop (cdr ps) acc)))))))
          (list (cell-v k) stop (seen '(set-up call end torn-down)) (seen '(fork look next stop))))))))

(test-equal "a step runs with interrupts disabled, in a section and in a held step"
  '((d) returned (2) (2))
  step-depths)

;;; --- 6. the observer's raise, or exit, at a thread's blocking point ----------

;; The observer raises at the point after thread 1's set-up step: the
;; thread breaks the worker, tears down once and ends, and the maker
;; raises the broken &error.
(define set-up-point-raise
  (bounded
    (let-values (((tear-down torn) (counting-tear-down)))
      (let ((wa (new-watch (lambda (kind party info) #f)))
            (inj (make-message-condition "injected at a set-up's point")))
        (watch-hook-set! wa (lambda (kind party info)
                              (when (and (eq? kind 'section) (equal? party '(thread 1))
                                         (equal? (car info) '(set-up 1 returned)))
                                (raise inj))))
        (let ((r (guard (e (#t (list 'raised e)))
                   (make-shell-worker (watch-observer wa) step #f (lambda () 'point-state) 0 1 tear-down)
                   'returned)))
          (list (answer-shape r) (cell-v torn)))))))

(test-equal "protocol: a raise at the point after a set-up's step breaks the worker"
  (list (list 'raised broken-shape) 1)
  set-up-point-raise)

;; One thread, a cap of 1: A runs at a gate, B queues. As A ends, the
;; observer raises, or exits the thread, at the end step's point, with A's
;; post still to carry out. A raise breaks the worker there, and then again
;; as the thread leaves; an exit passes every handler, so the thread's
;; after-thunk breaks it. Either way A and B are told one &error, a later
;; call raises it, nothing is posted twice, and the thread tears down once.
(define (end-point-row how)
  (let-values (((tear-down torn) (counting-tear-down)))
    (let ((wa (new-watch (lambda (kind party info) #f)))
          (inj (make-message-condition "injected at a job's end point"))
          (fired (make-cell #f)))
      (watch-hook-set! wa (lambda (kind party info)
                            (when (and (eq? kind 'section) (equal? party '(thread 1))
                                       (eq? (car (car info)) 'end) (not (cell-v fired)))
                              (cell-v-set! fired #t)
                              (if (eq? how 'exit) (exit 1) (raise inj)))))
      (let* ((w (make-shell-worker (watch-observer wa) step #f (lambda () 'end-state) 1 1 tear-down))
             (b (new-bench))
             (g (new-gate)))
        (let*-values (((a ca) (call-kept b (lambda () (worker-call w (gate-job g 'ran)))))
                      ((running) (await-running g))
                      ((bb cb) (call-kept b (lambda () (worker-call w (lambda (s) 'b))))))
          (open-gate! g)
          (let* ((ended (live-falls-to w 0))
                 (settled (begin (settle! b) #t))
                 (later (let-values (((k c) (call-kept b (lambda () (worker-call w (lambda (s) s))))))
                          (cell-v k)))
                 (told (list (cell-v a) (cell-v bb)))
                 (stop (stop-outcome w)))
            (list running ended (map answer-shape told) (answer-shape later)
                  (same-raise? (append told (list later)))
                  (test-host-log (bench-host b)) stop (worker-live-count w) (cell-v torn))))))))

(define end-point-answer
  (list #t #t (list (list 'raised broken-shape) (list 'raised broken-shape)) (list 'raised broken-shape)
        #t '() 'returned 0 1))

(test-equal "protocol: a raise at a job's end point breaks the worker once, with one &error"
  end-point-answer (bounded (end-point-row 'raise)))
(test-equal "protocol: an exit at a job's end point breaks the worker, its post still told"
  end-point-answer (bounded (end-point-row 'exit)))

;; A's job leaves its thread with B queued behind it, so the thread's
;; after-thunk steps (left 1), with two posts to carry out: A's left, then
;; B's stopped. The observer exits the thread again while it carries them
;; out: at the point after A's post (AT is effected), or at the step's
;; point, before either (AT is section). The after-thunk keeps what is
;; still to do: on the broken path, each post not yet carried out is the
;; broken &error, and none is carried out twice. The thread tears down
;; once, and the stop returns.
(define (left-exit-row at)
  (let-values (((tear-down torn) (counting-tear-down)))
    (let ((wa (new-watch (lambda (kind party info) #f)))
          (fired (make-cell #f)))
      (watch-hook-set! wa (lambda (kind party info)
                            (when (and (equal? party '(thread 1)) (not (cell-v fired))
                                       (if (eq? at 'section)
                                           (and (eq? kind 'section) (equal? (car info) '(left 1)))
                                           (and (eq? kind 'effected) (eq? (car info) 'post)
                                                (eq? (caddr info) 'left))))
                              (cell-v-set! fired #t)
                              (exit 1))))
      (let* ((w (make-shell-worker (watch-observer wa) step #f (lambda () 'left-state) 1 1 tear-down))
             (b (new-bench))
             (g (new-gate)))
        (let*-values (((a ca) (call-kept b (lambda () (worker-call w (lambda (s) ((gate-job g 'ran) s) (exit 1))))))
                      ((running) (await-running g))
                      ((bb cb) (call-kept b (lambda () (worker-call w (lambda (s) 'b))))))
          (open-gate! g)
          (let* ((ended (live-falls-to w 0))
                 (settled (begin (settle! b) #t))
                 (stop (within 2000 (lambda () (stop-outcome w))))
                 (log (test-host-log (bench-host b))))
            (list running (cell-v fired) ended (answer-shape (cell-v a)) (answer-shape (cell-v bb))
                  log stop (cell-v torn))))))))

(test-equal "protocol: an exit after a left job's first post carries out the rest, once"
  (list #t #t #t (list 'raised left-shape) (list 'raised broken-shape) '() 'returned 1)
  (bounded (left-exit-row 'effected)))
(test-equal "protocol: an exit before a left job's posts carries out every one, once"
  (list #t #t #t (list 'raised broken-shape) (list 'raised broken-shape) '() 'returned 1)
  (bounded (left-exit-row 'section)))

;; A's job leaves its thread with B queued: the after-thunk steps (left 1),
;; which tells A left and B stopped, tears the thread down, and steps
;; torn-down. The observer exits the thread again at that step's point (AT
;; is section), or after its wake (AT is effected): the broken path wakes
;; the stopper, and finds the tear-down done already, so it runs once.
(define (left-torn-down-exit-row at)
  (let-values (((tear-down torn) (counting-tear-down)))
    (let ((wa (new-watch (lambda (kind party info) #f)))
          (fired (make-cell #f)))
      (watch-hook-set! wa (lambda (kind party info)
                            (when (and (equal? party '(thread 1)) (not (cell-v fired))
                                       (if (eq? at 'section)
                                           (and (eq? kind 'section) (eq? (car (car info)) 'torn-down))
                                           (and (eq? kind 'effected) (equal? info '(wake-waiters))
                                                (= 1 (cell-v torn)))))
                              (cell-v-set! fired #t)
                              (exit 1))))
      (let* ((w (make-shell-worker (watch-observer wa) step #f (lambda () 'left-torn-state) 1 1 tear-down))
             (b (new-bench))
             (g (new-gate)))
        (let*-values (((a ca) (call-kept b (lambda () (worker-call w (lambda (s) ((gate-job g 'ran) s) (exit 1))))))
                      ((running) (await-running g))
                      ((bb cb) (call-kept b (lambda () (worker-call w (lambda (s) 'b))))))
          (open-gate! g)
          (let* ((ended (live-falls-to w 0))
                 (settled (begin (settle! b) #t))
                 (stop (within 2000 (lambda () (stop-outcome w))))
                 (later (let-values (((k c) (call-kept b (lambda () (worker-call w (lambda (s) s))))))
                          (cell-v k)))
                 (log (test-host-log (bench-host b))))
            (list running (cell-v fired) ended (answer-shape (cell-v a)) (answer-shape (cell-v bb))
                  (answer-shape later) log stop (cell-v torn))))))))

(test-equal "protocol: an exit at a left job's torn-down point tears down no more"
  (list #t #t #t (list 'raised left-shape) (list 'raised stopped-shape) (list 'raised broken-shape)
        '() 'returned 1)
  (bounded (left-torn-down-exit-row 'section)))
(test-equal "protocol: an exit after a left job's torn-down wake tears down no more"
  (list #t #t #t (list 'raised left-shape) (list 'raised stopped-shape) (list 'raised broken-shape)
        '() 'returned 1)
  (bounded (left-torn-down-exit-row 'effected)))

;; The stop tears the thread down; the observer raises, or exits the
;; thread, at the point after its torn-down step. The thread has torn down
;; already, so it doesn't again, and the stop returns. What Chez prints for
;; a raise that escapes a worker thread is caught from the console's error
;; port: the raise's line alone, and for an exit, nothing.
(define (torn-down-point-row how)
  (let-values (((tear-down torn) (counting-tear-down))
               ((port printed) (open-string-output-port)))
    (let ((wa (new-watch (lambda (kind party info) #f)))
          (inj (make-message-condition "injected at a torn-down point"))
          (fired (make-cell #f))
          (console (console-error-port)))
      (watch-hook-set! wa (lambda (kind party info)
                            (when (and (eq? kind 'section) (equal? party '(thread 1))
                                       (eq? (car (car info)) 'torn-down) (not (cell-v fired)))
                              (cell-v-set! fired #t)
                              (if (eq? how 'exit) (exit 1) (raise inj)))))
      (console-error-port port)
      (let* ((w (make-shell-worker (watch-observer wa) step #f (lambda () 'torn-state) 0 1 tear-down))
             (b (new-bench))
             (stop (stop-outcome w))
             (text (begin (console-error-port console) (printed)))
             (later (let-values (((k c) (call-kept b (lambda () (worker-call w (lambda (s) s))))))
                      (cell-v k)))
             (live (worker-live-count w)))
        (list stop (answer-shape later) live (cell-v torn) text)))))

(test-equal "protocol: a raise at the point after a torn-down step tears down no more"
  (list 'returned (list 'raised broken-shape) 0 1 "Exception: injected at a torn-down point\n")
  (bounded (torn-down-point-row 'raise)))
(test-equal "protocol: an exit at the point after a torn-down step breaks the worker, printing nothing"
  (list 'returned (list 'raised broken-shape) 0 1 "")
  (bounded (torn-down-point-row 'exit)))

;; The set-up raises, and the observer raises at the point after that
;; step: the thread has no state, so it doesn't tear down.
(define failed-set-up-point-raise
  (bounded
    (let-values (((tear-down torn) (counting-tear-down)))
      (let ((wa (new-watch (lambda (kind party info) #f)))
            (inj (make-message-condition "injected at a failed set-up's point")))
        (watch-hook-set! wa (lambda (kind party info)
                              (when (and (eq? kind 'section) (equal? party '(thread 1))
                                         (eq? (car (car info)) 'set-up))
                                (raise inj))))
        (let ((r (guard (e (#t (list 'raised e)))
                   (make-shell-worker (watch-observer wa) step #f (lambda () (raise 'set-up-failed))
                                      0 1 tear-down)
                   'returned)))
          (list (answer-shape r) (cell-v torn)))))))

(test-equal "protocol: a raise after a failed set-up tears nothing down"
  (list (list 'raised broken-shape) 0)
  failed-set-up-point-raise)

;; Two threads. The first set-up returns, and the observer raises at the
;; point after its step; the second set-up raises once the first thread's
;; tear-down has begun, so its step finds the worker broken. That thread
;; has no state: it ends without a tear-down.
(define late-failed-set-up
  (bounded
    (let* ((mx (make-mutex))
           (cv (make-condition))
           (count (make-cell 0))
           (begun (make-cell #f))
           (torn (make-cell 0))
           (set-up (lambda ()
                     (mutex-acquire mx)
                     (cell-v-set! count (+ 1 (cell-v count)))
                     (if (= 1 (cell-v count))
                         (begin (mutex-release mx) 'first-state)
                         (let ((deadline (+ (real-time) 3000)))
                           (let loop ()
                             (if (or (cell-v begun) (> (real-time) deadline))
                                 (begin (mutex-release mx) (raise 'late-set-up))
                                 (begin (condition-wait cv mx (ms 50)) (loop))))))))
           (tear-down (lambda (s)
                        (mutex-acquire mx)
                        (cell-v-set! begun #t)
                        (cell-v-set! torn (+ 1 (cell-v torn)))
                        (condition-broadcast cv)
                        (mutex-release mx)))
           (inj (make-message-condition "injected at the first set-up's point"))
           (fired (make-cell #f))
           (wa (new-watch (lambda (kind party info) #f))))
      (watch-hook-set! wa (lambda (kind party info)
                            (when (and (eq? kind 'section) (eq? (car party) 'thread)
                                       (eq? (car (car info)) 'set-up)
                                       (eq? (caddr (car info)) 'returned)
                                       (not (cell-v fired)))
                              (cell-v-set! fired #t)
                              (raise inj))))
      (let* ((r (guard (e (#t (list 'raised e)))
                  (make-shell-worker (watch-observer wa) step #f set-up 0 2 tear-down)
                  'returned))
             (n (begin (mutex-acquire mx) (let ((n (cell-v torn))) (mutex-release mx) n))))
        (list (answer-shape r) n)))))

(test-equal "protocol: a set-up that fails once the worker is broken tears nothing down"
  (list (list 'raised broken-shape) 1)
  late-failed-set-up)

;;; --- 7. the double -------------------------------------------------------

(define double-plain
  (bounded
    (let* ((d (make-test-worker (lambda () 'double-state)))
           (b (new-bench))
           (value (let-values (((kept c) (call-kept b (lambda () (worker-call d (lambda (s) (list 'v s)))))))
                    (list (cell-v kept) (statuses c))))
           (raised (let-values (((kept c) (call-kept b (lambda () (worker-call d (lambda (s) (raise thrown)))))))
                     (list (cell-v kept) (statuses c))))
           (stop (stop-outcome d)))
      (list value raised stop (worker-live-count d)))))

(define (double-part . is) (if (whole? double-plain 4) (map (lambda (i) (list-ref double-plain i)) is) double-plain))

(test-equal "the double answers a job's value within the send"
  '((((v double-state)) (200))) (double-part 0))
(test-equal "the double raises a job's raise within the send, the same object"
  (list (list (list 'raised thrown) '(200))) (double-part 1))
(test-equal "the double's stop leaves no thread live"
  '(returned 0) (double-part 2 3))

(define double-wait
  (bounded
    (let* ((d (make-test-worker (lambda () 'wait-state)))
           (b (new-bench))
           (a (let-values (((kept c) (call-kept b (lambda ()
                                                    (worker-call d (lambda (s) (await-outside (lambda (resume) (resume 'x)))))))))
                (cell-v kept)))
           (stop (stop-outcome d)))
      (list (if (and (pair? a) (eq? (car a) 'raised))
                (let ((e (cadr a)))
                  (list (assertion-violation? e)
                        (and (message-condition? e) (condition-message e))
                        (and (who-condition? e) (condition-who e))))
                a)
            stop (worker-live-count d)))))

(test-equal "the double: a wait inside a job is refused, off the loop's thread"
  '((#t "a wait off the loop's thread" await-outside) returned 0)
  double-wait)

;; The double's thread is held at the blocking point after the wake its
;; set-up step gives, once the worker serves, so the maker returns and the
;; call's signal finds no one waiting. A helper, seeing the call's unmarked check, forks a stopper,
;; whose first stop posts stopped while the job is still given, and lets
;; the thread go once the stopper's second stop is noted.
(define stop-while-given
  (bounded
    (let* ((wa (new-watch (lambda (kind party info)
                            (and (eq? kind 'effected) (equal? party '(thread 1))
                                 (equal? info '(wake-waiters))))))
           (ran (make-cell #f))
           (d (make-shell-worker (watch-observer wa) step #t (lambda () 'given-state) 0 1 #f))
           (b (new-bench))
           (stopper-out (make-cell 'no-stopper))
           (helper
            (fork-thread
             (lambda ()
               (let ((checked (watch-wait-for wa unmarked-check?)))
                 (if checked
                     (let-values (((t out) (fork-stopper d)))
                       (cell-v-set! stopper-out out)
                       (watch-wait-for wa stopper-held?)
                       (release! wa)
                       (thread-join t))
                     (begin (release! wa) (doom! wa))))))))
      (let-values (((kept c) (call-kept b (lambda () (worker-call d (lambda (s) (cell-v-set! ran #t) s))))))
        (thread-join helper)
        (let ((out (cell-v stopper-out)))
          (list (answer-shape (cell-v kept)) (statuses c) (cell-v ran)
                (if (cell? out) (cell-v out) out)
                (worker-live-count d)))))))

(test-equal "the double: a stop while the job is still given ends the call's wait, stopped"
  (list (list 'raised stopped-shape) '(200) #f 'returned 0)
  stop-while-given)

;; The job runs and waits at a gate; a stopper is forked, and the gate
;; opens once its second stop is noted.
(define stop-while-running
  (bounded
    (let* ((wa (new-watch (lambda (kind party info) #f)))
           (g (new-gate))
           (d (make-shell-worker (watch-observer wa) step #t (lambda () 'run-state) 0 1 #f))
           (b (new-bench))
           (stopper-out (make-cell 'no-stopper))
           (helper
            (fork-thread
             (lambda ()
               (if (await-running g)
                   (let-values (((t out) (fork-stopper d)))
                     (cell-v-set! stopper-out out)
                     (watch-wait-for wa stopper-held?)
                     (open-gate! g)
                     (thread-join t))
                   (begin (doom! wa) (open-gate! g)))))))
      (let-values (((kept c) (call-kept b (lambda () (worker-call d (gate-job g 'ran))))))
        (thread-join helper)
        (let ((out (cell-v stopper-out)))
          (list (cell-v kept) (statuses c) (if (cell? out) (cell-v out) out)
                (worker-live-count d)))))))

(test-equal "the double: a stop while the job runs answers the job's value"
  '(((ran run-state)) (200) returned 0)
  stop-while-running)

;;; --- 8. the double, broken, and a job that leaves --------------------------

;; The step raises at a stop. A helper stops the double while its job
;; runs, once the call waits for its mark: the stop's section breaks the
;; worker, whose broken path posts to, and marks, the running job's
;; ticket, so the call's wait ends. The call's wait is doomed first: a
;; correct shell marks before it wakes the call, so it never waits again.
(define double-broken
  (bounded
    (let-values (((tear-down torn) (counting-tear-down)))
          (let* ((boom (make-message-condition "injected at the stop"))
                 (g (new-gate))
                 (wa (new-watch (lambda (kind party info) #f)))
                 (d (make-shell-worker (watch-observer wa)
                                       (lambda (m ev) (if (eq? (car ev) 'stop) (raise boom) (step m ev)))
                                       #t (lambda () 'broken-state) 0 1 tear-down))
                 (b (new-bench))
                 (helper-saw (make-cell 'unset))
                 (helper (fork-thread
                          (lambda ()
                            (when (and (await-running g) (watch-wait-for wa caller-waits?))
                              (doom! wa)
                              (cell-v-set! helper-saw (guard (e (#t e)) (worker-stop! d) no-raise)))
                            (doom! wa)
                            (open-gate! g)))))
            (let-values (((kept c) (call-kept b (lambda () (worker-call d (gate-job g 'ran))))))
              (thread-join helper)
              (let* ((first (cell-v kept))
                     (later (let-values (((k2 c2) (call-kept b (lambda () (worker-call d (lambda (s) s))))))
                              (cell-v k2)))
                     (stop (stop-outcome d)))
                (list (answer-shape first) (statuses c) (eq? (cell-v helper-saw) boom)
                      (answer-shape later)
                      (and (pair? first) (pair? later) (eq? (cadr first) (cadr later)))
                      stop (worker-live-count d) (cell-v torn))))))))

(test-equal "the double: a break while the job runs ends the call's wait with the broken &error"
  (list (list 'raised broken-shape) '(200) #t (list 'raised broken-shape) #t 'returned 0 1)
  double-broken)

;; Last: a double that ran its job on the caller's thread would exit here.
(define double-left
  (bounded
    (let-values (((tear-down torn) (counting-tear-down)))
      (let* ((wa (new-watch (lambda (kind party info) #f)))
             (d (make-shell-worker (watch-observer wa) step #t (lambda () 'left-state) 0 1 tear-down))
             (b (new-bench))
             (first (let-values (((kept c) (call-kept b (lambda () (worker-call d (lambda (s) (exit 1)))))))
                      (cell-v kept)))
             (later (let-values (((kept c) (call-kept b (lambda () (worker-call d (lambda (s) s))))))
                      (cell-v kept)))
             (stop (stop-outcome d)))
        (list (answer-shape first) (answer-shape later) stop (worker-live-count d) (cell-v torn))))))

(test-equal "the double: a job that leaves its thread is answered so, and stops the worker"
  (list (list 'raised left-shape) (list 'raised stopped-shape) 'returned 0 1)
  double-left)

(test-end "worker-shell")

(exit (suite-exit-status runner))
