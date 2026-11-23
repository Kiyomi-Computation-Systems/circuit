#!r6rs
;;; The worker on real threads, with no observer: (circuit worker shell)'s
;;; make-worker, through the server's test host, each row under a bound so
;;; that a hang fails the row and does not stall the suite.
;;;
;;; The host's loop is the test's own thread. A handler runs the call the
;;; test set before its send, inside the adapter's awaiting, so a worker's
;;; wait is a real await-outside; a worker thread's post waits for the
;;; host's next call that acts, which the suite's driver makes with an
;;; advance of 0 ms, every millisecond, until its clients are answered.
;;; Jobs that must block wait on gates the suite owns, a mutex and a
;;; condition.
;;;
;;; What is bounded: each row's whole body, make-worker, worker-live-count,
;;; every register and every stop included, runs on a thread of its own that
;;; the suite waits for with a limit, 10 s (the stress run 30 s). A row whose
;;; thread hasn't finished then is a failure, 'row-timed-out, and its thread
;;; is left, and once three rows have timed out the rest fail at once as
;;; 'row-skipped-after-3-timeouts, so a hung shell costs 30 s and not a row's
;;; limit each. Each since a waiting thread doesn't keep the process alive. Inside a
;;; row, the gates, the stops, the drivers and the counters wait with a
;;; condition-wait timeout or a poll with a deadline. What a row raises is
;;; a failure too, shown as 'row-raised, never a dead suite. Not bounded: a
;;; thread a failed row leaves blocked, and the rows after it, which use
;;; workers of their own, so it doesn't reach them.
;;;
;;; Rows:
;;;   1.  a slow job doesn't delay another request;
;;;   2.  a full queue is refused at once, the call before it accepted;
;;;   3.  a raise on the worker is raised in the handler, the very object;
;;;   4.  order holds for one thread;
;;;   5.  two workers share no state, and a thread keeps its own;
;;;   6.  a stop leaves no thread behind;
;;;   7.  two stops at once both return;
;;;   8.  a job's own dynamic-wind stays whole across a warning;
;;;   9.  a job that answers no value, or two;
;;;   10. set-ups that raise or leave, and every thread joined;
;;;   11. a job that exits, then a tear-down that exits too;
;;;   12. after a normal stop the worker isn't broken, and nothing was
;;;       printed;
;;;   13. tear-downs: raised by the stop, kept at a failed start;
;;;   14. a stop on a worker's own thread is refused;
;;;   15. a job's parameters and output port are make-worker's;
;;;   16. the stress run, its seed printed;
;;;   17. a plain warning through the catch, a stop from a thread a job
;;;       forks, and a job's raise not continuable.
;;;
;;; A thread's index is read from its id: a thread forked later has the
;;; greater id, which the suite's thread-order row reads for itself first.
;;; The join of every thread after a failed start can't be seen from
;;; outside. Row 10 holds the lowest thread's raise, and that make-worker
;;; answers after the other set-up and its tear-down ended; that the shell
;;; joins is the schedule layer's, which kills a shell that doesn't.
;;;
;;; Not reachable here, so held by the observer's layers alone: a raise in
;;; a call's wait that is neither a deadline nor a client's close, with the
;;; ticket accepted, and two raises through one call, a deadline then a
;;; close. The server's wait makes no other raise once a ticket is accepted,
;;; nothing outside it can raise into a parked coroutine, and its deadline
;;; and close raises aren't continuable: a handler that returns for one gets
;;; a non-continuable violation raised outside the call's own handler, so
;;; the wait is never resumed to raise again (probed in this suite's
;;; development).
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (only (chezscheme) fork-thread thread-join make-mutex mutex-acquire mutex-release
              make-condition condition-wait condition-broadcast sleep make-time real-time
              get-thread-id warning parameterize make-thread-parameter console-error-port
              iota)
        (rename (only (chezscheme) current-output-port current-error-port)
                (current-output-port chez:current-output-port)
                (current-error-port chez:current-error-port))
        (circuit-testing)
        (http-server testing)
        (circuit)
        (only (circuit http-server) circuit->handler with-deadline deadline-passed?)
        (circuit middleware waits)
        (circuit worker shell)
        (only (circuit worker) wrap-busy))

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

(test-begin "worker-threads")

;;; ------------------------------------------------------------------------
;;; Helpers

(define (ms n) (make-time 'time-duration (* n 1000000) 0))

;; A computation on a thread of its own, waited for with a limit, run by
;; computed after the helpers below: (ok . V), or (failed X), for a limit
;; passed or a raise.
(define-syntax row
  (syntax-rules ()
    ((_ name expected body ...)
     (test-equal name expected (from (computed 10000 (lambda () body ...)) (lambda (v) v))))))


(define-record-type cell (fields (mutable v)))

;; A counter: a number a thread bumps, and another waits on with a limit.
(define-record-type counter (fields mx cv (mutable n)))

(define (new-counter) (make-counter (make-mutex) (make-condition) 0))

(define (counter-bump! c)
  (mutex-acquire (counter-mx c))
  (counter-n-set! c (+ 1 (counter-n c)))
  (condition-broadcast (counter-cv c))
  (mutex-release (counter-mx c)))

(define (counter-ref c)
  (mutex-acquire (counter-mx c))
  (let ((n (counter-n c)))
    (mutex-release (counter-mx c))
    n))

;; counter-wait : Counter Nat Nat -> Boolean
;; Whether C reached N within LIMIT milliseconds.
(define (counter-wait c n limit)
  (let ((deadline (+ (real-time) limit)) (mx (counter-mx c)))
    (mutex-acquire mx)
    (let loop ()
      (cond ((>= (counter-n c) n) (mutex-release mx) #t)
            ((> (real-time) deadline) (mutex-release mx) #f)
            (else (condition-wait (counter-cv c) mx (ms 20)) (loop))))))

;; A log a thread appends to, in order.
(define-record-type thelog (fields mx (mutable items)))

(define (new-log) (make-thelog (make-mutex) '()))

(define (log! l x)
  (mutex-acquire (thelog-mx l))
  (thelog-items-set! l (cons x (thelog-items l)))
  (mutex-release (thelog-mx l)))

(define (log-ref l)
  (mutex-acquire (thelog-mx l))
  (let ((items (reverse (thelog-items l))))
    (mutex-release (thelog-mx l))
    items))

;; A gate: jobs that say they run, then wait for it to open.
(define-record-type gate (fields mx cv (mutable started) (mutable open?)))

(define (new-gate) (make-gate (make-mutex) (make-condition) 0 #f))

;; gate-wait! : Gate -> Void — say this thread runs, then wait for the gate
;; to open, for 30 s at most.
(define (gate-wait! g)
  (let ((deadline (+ (real-time) 30000)))
    (mutex-acquire (gate-mx g))
    (gate-started-set! g (+ 1 (gate-started g)))
    (condition-broadcast (gate-cv g))
    (let loop ()
      (unless (or (gate-open? g) (> (real-time) deadline))
        (condition-wait (gate-cv g) (gate-mx g) (ms 50))
        (loop)))
    (mutex-release (gate-mx g))))

;; gated : Gate (State -> Any) -> (State -> Any)
(define (gated g f) (lambda (s) (gate-wait! g) (f s)))

;; await-started : Gate Nat -> Boolean
;; Whether N jobs ran at G within 5 s.
(define (await-started g n)
  (let ((deadline (+ (real-time) 5000)) (mx (gate-mx g)))
    (mutex-acquire mx)
    (let loop ()
      (cond ((>= (gate-started g) n) (mutex-release mx) #t)
            ((> (real-time) deadline) (mutex-release mx) #f)
            (else (condition-wait (gate-cv g) mx (ms 20)) (loop))))))

(define (open-gate! g)
  (mutex-acquire (gate-mx g))
  (gate-open?-set! g #t)
  (condition-broadcast (gate-cv g))
  (mutex-release (gate-mx g)))

;; spawn : (-> Any) -> Handle
;; THUNK on a thread of its own, its answer or raise kept: awaited with a
;; limit by await.
(define-record-type handle (fields mx cv (mutable result)))

(define (spawn thunk)
  (let ((h (make-handle (make-mutex) (make-condition) #f)))
    (fork-thread
     (lambda ()
       (let ((r (guard (e (#t (list 'raised e)))
                  (call-with-values thunk (lambda vs (cons 'returned vs))))))
         (mutex-acquire (handle-mx h))
         (handle-result-set! h r)
         (condition-broadcast (handle-cv h))
         (mutex-release (handle-mx h)))))
    h))

;; done? : Handle -> Boolean
(define (done? h)
  (mutex-acquire (handle-mx h))
  (let ((r (handle-result h)))
    (mutex-release (handle-mx h))
    (and r #t)))

;; await : Handle Nat -> (U 'timed-out (List 'returned Any ...) (List 'raised Any))
(define (await h limit)
  (let ((deadline (+ (real-time) limit)) (mx (handle-mx h)))
    (mutex-acquire mx)
    (let loop ()
      (cond ((handle-result h) => (lambda (r) (mutex-release mx) r))
            ((> (real-time) deadline) (mutex-release mx) 'timed-out)
            (else (condition-wait (handle-cv h) mx (ms 20)) (loop))))))

;; bounded : (-> Any) -> (U 'timed-out ...) — THUNK on a thread, waited for
;; at most 10 s.
(define (bounded thunk) (await (spawn thunk) 10000))

;; stop-outcome : Worker -> Any
;; What a stop did, bounded: 'returned, (raised E) or 'timed-out.
(define timeouts (new-counter))

(define (computed limit thunk)
  (let ((x (if (>= (counter-ref timeouts) 3)
               'skipped
               (await (spawn thunk) limit))))
    (cond ((eq? x 'skipped) '(failed row-skipped-after-3-timeouts))
          ((eq? x 'timed-out) (counter-bump! timeouts) '(failed row-timed-out))
          ((eq? (car x) 'returned) (cons 'ok (cadr x)))
          (else (list 'failed (list 'row-raised (brief (cadr x))))))))

;; from : (U (Pair 'ok Any) (List 'failed Any)) (Any -> Any) -> Any
(define (from c f) (if (eq? (car c) 'ok) (f (cdr c)) c))

(define (stop-outcome w)
  (let ((r (bounded (lambda () (worker-stop! w)))))
    (cond ((eq? r 'timed-out) r)
          ((eq? (car r) 'returned) 'returned)
          (else r))))

;; A bench: a test host whose handler runs the call the test set before a
;; send, inside the adapter's awaiting, then answers an empty 200.
(define-record-type bench (fields host (mutable call)))

(define (new-bench)
  (letrec ((b (make-bench
               (make-test-host
                (circuit->handler
                 (lambda (req) ((bench-call b)) (make-res 200 '() #f))
                 (lambda (name) #f))
                (lambda (name) #f))
               #f)))
    b))

(define get-bytes (string->utf8 "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))

;; send! : Bench (-> Any) -> TestClient
;; A new client sends one request whose handler runs CALL.
(define (send! b call)
  (bench-call-set! b call)
  (let ((c (test-host-connect! (bench-host b))))
    (test-client-send! c get-bytes)
    c))

(define (statuses c) (map test-response-status (test-client-responses c)))

;; answer : (-> Any) -> (U (Listof Any) (List 'raised Any))
;; The values THUNK returned, as a list, or what it raised. A raise is
;; tagged, and a return is the bare list tagged 'returned.
(define (answer thunk)
  (guard (e (#t (list 'raised e)))
    (call-with-values thunk (lambda vs (cons 'returned vs)))))

;; call-kept : Bench (-> Any) -> (Values Cell TestClient)
;; A request whose handler keeps THUNK's answer in the cell.
(define (call-kept b thunk)
  (let* ((kept (make-cell 'unanswered))
         (c (send! b (lambda () (cell-v-set! kept (answer thunk))))))
    (values kept c)))

(define (answered? kept) (not (eq? (cell-v kept) 'unanswered)))

;; drive! : TestHost Nat (-> Boolean) -> Boolean
;; Advance the host by TICK ms every real millisecond until DONE?, for 10 s
;; at most; whether it was.
(define (drive! host tick done?)
  (let ((deadline (+ (real-time) 10000)))
    (let loop ()
      (test-host-advance! host tick)
      (cond ((done?) #t)
            ((> (real-time) deadline) #f)
            (else (sleep (ms 1)) (loop))))))

(define (drive-until-answered! b . kepts)
  (drive! (bench-host b) 0 (lambda () (for-each-answered? kepts))))

(define (for-each-answered? kepts)
  (let loop ((rest kepts))
    (or (null? rest) (and (answered? (car rest)) (loop (cdr rest))))))

;; brief : Any -> List
;; A raise as the rows compare it: a condition's kind, who and message, or
;; the object.
(define (brief e)
  (if (condition? e)
      (list (cond ((worker-full? e) 'full)
                  ((worker-stopped? e) 'stopped)
                  ((assertion-violation? e) 'assertion)
                  ((error? e) 'error)
                  (else 'other))
            (and (who-condition? e) (condition-who e))
            (and (message-condition? e) (condition-message e)))
      (list 'not-a-condition e)))

;; The brief of what a kept answer raised.
(define (raised-brief v)
  (if (and (pair? v) (eq? (car v) 'raised)) (list 'raised (brief (cadr v))) v))

(define-record-type st (fields tid (mutable n)))

(define (new-st) (make-st (get-thread-id) 0))

;; with-console-error : Port (-> Any) -> Any
;; THUNK with the console error port set to PORT for its whole extent, as
;; the port a warning prints to is a global that a thread reads when it
;; prints, not one it inherits.
(define (with-console-error port thunk)
  (let ((before (console-error-port)))
    (dynamic-wind
     (lambda () (console-error-port port))
     thunk
     (lambda () (console-error-port before)))))

(define (thread-order-holds?)
  (let* ((log (new-log))
         (ts (map (lambda (i)
                    (let ((t (fork-thread (lambda () (log! log (cons i (get-thread-id)))))))
                      t))
                  '(0 1 2))))
    (for-each thread-join ts)
    (let ((ids (map cdr (list-sort (lambda (a b) (< (car a) (car b))) (log-ref log)))))
      (and (< (car ids) (cadr ids)) (< (cadr ids) (caddr ids))))))

;;; ------------------------------------------------------------------------
;;; The thread order the rows rely on

(row "a thread forked later has the greater id"
  #t (thread-order-holds?))

;;; ------------------------------------------------------------------------
;;; 1. A slow job doesn't delay another request

(row "1: while a job is held, a request that doesn't use the worker is answered within its own send"
  '((200) () (returned slow) (200))
  (let* ((w (make-worker new-st 1 1))
         (b (new-bench))
         (g (new-gate)))
    (let-values (((slow ca) (call-kept b (lambda () (worker-call w (gated g (lambda (s) 'slow)))))))
      (let ((started (await-started g 1)))
        (let ((cb (send! b (lambda () 'no-worker))))
          (let* ((b-seen (statuses cb))
                 (a-seen (statuses ca)))
            (open-gate! g)
            (let ((drove (drive-until-answered! b slow)))
              (let ((r (list b-seen a-seen (cell-v slow) (and drove started (statuses ca)))))
                (stop-outcome w)
                (list (car r) (cadr r) (caddr r) (if (cadddr r) (cadddr r) 'not-answered))))))))))

;;; ------------------------------------------------------------------------
;;; 2. A full queue is refused at once

(row "2: threads 1, cap 1: the second job is accepted and the third refused at once with worker-full? and who worker-call"
  (list '() '() '(200) '(raised (full worker-call "the worker's queue is full"))
        '(returned a) '(returned b))
  (let* ((w (make-worker new-st 1 1))
         (b (new-bench))
         (g (new-gate)))
    (let-values (((ka ca) (call-kept b (lambda () (worker-call w (gated g (lambda (s) 'a)))))))
      (await-started g 1)
      (let-values (((kb cb) (call-kept b (lambda () (worker-call w (gated g (lambda (s) 'b)))))))
        (let-values (((kc cc) (call-kept b (lambda () (worker-call w (lambda (s) 'c))))))
          (let ((seen (list (statuses ca) (statuses cb) (statuses cc) (raised-brief (cell-v kc)))))
            (open-gate! g)
            (drive-until-answered! b ka kb)
            (stop-outcome w)
            (append seen (list (cell-v ka) (cell-v kb)))))))))

;;; ------------------------------------------------------------------------
;;; 3. A raise on the worker is raised in the handler, the very object

(define-record-type boom (fields n))

(define (raised-very-object obj)
  (let* ((w (make-worker new-st 1 1))
         (b (new-bench)))
    (let-values (((k c) (call-kept b (lambda () (worker-call w (lambda (s) (raise obj)))))))
      (drive-until-answered! b k)
      (stop-outcome w)
      (let ((v (cell-v k)))
        (list (and (pair? v) (car v)) (and (pair? v) (pair? (cdr v)) (eq? (cadr v) obj)))))))

(row "3: a condition, a non-condition and a record, each raised in the handler as the very object"
  '((raised #t) (raised #t) (raised #t))
  (list (raised-very-object (condition (make-error) (make-message-condition "a condition")))
        (raised-very-object (list 'a 'non-condition))
        (raised-very-object (make-boom 1))))

;;; ------------------------------------------------------------------------
;;; 4. Order holds for one thread

(row "4: threads 1, cap 20, 20 jobs queued behind a running one start in call order"
  (list (iota 21) (iota 21))
  (let* ((w (make-worker new-st 20 1))
         (b (new-bench))
         (g (new-gate))
         (log (new-log))
         (keeps '()))
    (let-values (((k0 c0) (call-kept b (lambda () (worker-call w (gated g (lambda (s) (log! log 0) 0)))))))
      (await-started g 1)
      (set! keeps (list k0))
      (let loop ((i 1))
        (when (<= i 20)
          (let-values (((k c) (call-kept b (lambda () (worker-call w (lambda (s) (log! log i) i))))))
            (set! keeps (cons k keeps))
            (loop (+ i 1)))))
      (open-gate! g)
      (apply drive-until-answered! b keeps)
      (stop-outcome w)
      (list (log-ref log)
            (map (lambda (k) (let ((v (cell-v k))) (and (pair? v) (pair? (cdr v)) (cadr v))))
                 (reverse keeps))))))

;;; ------------------------------------------------------------------------
;;; 5. Two workers don't share state

;; calls-through-gate : Worker Nat Nat -> (Listof (List Nat St))
;; N jobs on W, the first THREADS held at a gate until every thread runs
;; one; each answers its thread's id and state.
(define (pairs-of w threads n)
  (let* ((b (new-bench))
         (g (new-gate))
         (job (lambda (s) (list (get-thread-id) s)))
         (keeps '()))
    (let loop ((i 0))
      (when (< i n)
        (let-values (((k c) (call-kept b (lambda ()
                                            (worker-call w (if (< i threads) (gated g job) job))))))
          (set! keeps (cons k keeps))
          (when (= i (- threads 1)) (await-started g threads))
          (loop (+ i 1)))))
    (open-gate! g)
    (apply drive-until-answered! b keeps)
    (map (lambda (k) (let ((v (cell-v k))) (and (pair? v) (pair? (cdr v)) (cadr v)))) keeps)))

(define (distinct-by same? xs)
  (let loop ((rest xs) (out '()))
    (cond ((null? rest) (length out))
          ((let seen ((o out)) (and (pair? o) (or (same? (car o) (car rest)) (seen (cdr o)))))
           (loop (cdr rest) out))
          (else (loop (cdr rest) (cons (car rest) out))))))

(define (mapcar f xs) (let loop ((r xs) (o '())) (if (null? r) (reverse o) (loop (cdr r) (cons (f (car r)) o)))))

(define (tid-of p) (car p))
(define (state-of p) (cadr p))

(define c5
  (computed
   10000
   (lambda ()
     (let* ((wa (make-worker new-st 50 3))
            (wb (make-worker new-st 50 2))
            (pa (pairs-of wa 3 50))
            (pb (pairs-of wb 2 50)))
       (stop-outcome wa)
       (stop-outcome wb)
       (list pa pb)))))

(define (pairs-shape ps)
  (list (length ps)
        (distinct-by eqv? (mapcar tid-of ps))
        (distinct-by eq? (mapcar state-of ps))
        (distinct-by (lambda (x y) (and (eqv? (tid-of x) (tid-of y)) (eq? (state-of x) (state-of y)))) ps)
        (let loop ((r ps)) (or (null? r) (and (eqv? (tid-of (car r)) (st-tid (state-of (car r)))) (loop (cdr r)))))))

(test-equal "5: a worker of 3 threads: 50 jobs answer 3 threads, 3 states, 3 pairs, each state its thread's"
  '(50 3 3 3 #t)
  (from c5 (lambda (v) (pairs-shape (car v)))))

(test-equal "5: a worker of 2 threads: 50 jobs answer 2 threads, 2 states, 2 pairs, each state its thread's"
  '(50 2 2 2 #t)
  (from c5 (lambda (v) (pairs-shape (cadr v)))))

(test-equal "5: no thread and no state is in both workers"
  '(5 5)
  (from c5 (lambda (v)
             (let ((all (append (car v) (cadr v))))
               (list (distinct-by eqv? (mapcar tid-of all)) (distinct-by eq? (mapcar state-of all)))))))

;;; ------------------------------------------------------------------------
;;; 6. A stop leaves no thread behind

(row "6: 3 threads live, then 0 after the stop returns, and a later call raises worker-stopped?"
  (list 3 'returned 0 '(raised (stopped worker-call "the worker has stopped")))
  (let* ((w (make-worker new-st 1 3))
         (b (new-bench))
         (live (worker-live-count w)))
    (let-values (((k c) (call-kept b (lambda () (worker-call w (lambda (s) 'x))))))
      (drive-until-answered! b k))
    (let* ((stopped (stop-outcome w))
           (after (worker-live-count w)))
      (let-values (((k c) (call-kept b (lambda () (worker-call w (lambda (s) 'y))))))
        (drive-until-answered! b k)
        (list live stopped after (raised-brief (cell-v k)))))))

;;; ------------------------------------------------------------------------
;;; 7. Two stops at once both return

(row "7: two stoppers wait on a running job; once it ends both return, within the bound, and the job's caller is answered"
  (list 0 #t '((returned) (returned)) '(returned slow) 0)
  (let* ((w (make-worker new-st 0 1))
         (b (new-bench))
         (g (new-gate))
         (finished (new-counter)))
    (let-values (((k c) (call-kept b (lambda () (worker-call w (gated g (lambda (s) 'slow)))))))
      (await-started g 1)
      (let* ((h1 (spawn (lambda () (worker-stop! w) (counter-bump! finished))))
             (h2 (spawn (lambda () (worker-stop! w) (counter-bump! finished)))))
        (sleep (ms 200))
        (let ((early (counter-ref finished)))
          (open-gate! g)
          (let* ((both (counter-wait finished 2 10000))
                 (r (list (await h1 100) (await h2 100))))
            (drive-until-answered! b k)
            (list early both
                  (map (lambda (x) (if (pair? x) (list (car x)) x)) r)
                  (cell-v k)
                  (worker-live-count w))))))))

;;; ------------------------------------------------------------------------
;;; 8. The two-layer catch keeps a job's own dynamic-wind whole

;; A worker made with the three ports captured, and a bench to call it on.
(define (captured-warning-run job-of)
  (let-values (((eport eextract) (open-string-output-port))
               ((oport oextract) (open-string-output-port)))
    (with-console-error eport (lambda ()
    (let* ((w (parameterize ((chez:current-output-port oport)
                             (chez:current-error-port oport))
                (make-worker new-st 1 1)))
           (b (new-bench))
           (log (new-log))
           (obj (list 'raised-after-warning)))
      (let-values (((k c) (call-kept b (lambda () (worker-call w (job-of log obj))))))
        (drive-until-answered! b k)
        (stop-outcome w)
        (let ((v (cell-v k)))
          (list (if (and (pair? v) (pair? (cdr v)))
                    (list (car v) (if (eq? (cadr v) obj) 'obj (cadr v)))
                    v)
                (log-ref log) (eextract) (oextract)))))))))

(row "8: a warning, then a return: the before and after thunks once each, the job goes on, the value is answered, the warning printed"
  '((returned went-on) (before warned after) "Warning in job: careful.\n" "")
  (captured-warning-run
   (lambda (log obj)
     (lambda (s)
       (dynamic-wind
        (lambda () (log! log 'before))
        (lambda () (warning 'job "careful.") (log! log 'warned) 'went-on)
        (lambda () (log! log 'after)))))))

(row "8: a warning, then a raise: the before and after thunks once each, the call raises the object, the warning printed"
  '((raised obj) (before warned after) "Warning in job: careful.\n" "")
  (captured-warning-run
   (lambda (log obj)
     (lambda (s)
       (dynamic-wind
        (lambda () (log! log 'before))
        (lambda () (warning 'job "careful.") (log! log 'warned) (raise obj))
        (lambda () (log! log 'after)))))))

;;; ------------------------------------------------------------------------
;;; 9. A job that answers no value, or two

(row "9: no value, two values and one value, each received by call-with-values"
  '(() (1 2) (x))
  (let* ((w (make-worker new-st 1 1))
         (b (new-bench))
         (out (make-cell '())))
    (let-values (((k c) (call-kept b (lambda ()
                                       (cell-v-set! out
                                                    (list (call-with-values (lambda () (worker-call w (lambda (s) (values)))) list)
                                                          (call-with-values (lambda () (worker-call w (lambda (s) (values 1 2)))) list)
                                                          (call-with-values (lambda () (worker-call w (lambda (s) 'x))) list)))
                                       'done))))
      (drive-until-answered! b k)
      (stop-outcome w)
      (cell-v out))))

;;; ------------------------------------------------------------------------
;;; 10. Set-ups that fail

;; The brief of what a bounded make-worker did.
(define (made-brief r)
  (cond ((eq? r 'timed-out) r)
        ((eq? (car r) 'returned) 'returned)
        (else (list 'raised (brief (cadr r))))))

(row "10: a set-up that raises: make-worker raises that very object"
  '(#t)
  (let* ((obj (list 'set-up-raise))
         (r (bounded (lambda () (make-worker (lambda () (raise obj)) 1 1)))))
    (list (and (pair? r) (eq? (car r) 'raised) (eq? (cadr r) obj)))))

;; A start of 2 threads in which the first set-up to run does FIRST and the
;; second waits at a gate: the outcome of make-worker as it stands while the
;; gate holds, then once the gate opens, and what the second thread had done
;; by then.
(define (failed-start first)
  (let* ((entered (new-counter))
         (g (new-gate))
         (log (new-log))
         (h (spawn
             (lambda ()
               (make-worker
                (lambda ()
                  (counter-bump! entered)
                  (if (= 1 (counter-ref entered))
                      (first)
                      (begin (gate-wait! g) (log! log 'second-set-up-ended) 'state)))
                1 2
                (lambda (s) (log! log 'second-tore-down)))))))
    (counter-wait entered 2 5000)
    (sleep (ms 200))
    (let ((held (done? h)))
      (open-gate! g)
      (let ((r (await h 10000)))
        (list held (made-brief r) (log-ref log) r)))))

(define c10a (computed 10000 (lambda () (failed-start (lambda () (raise 'first-raise))))))

(test-equal "10: a set-up raises while another is held: make-worker waits for it, then raises the object, its tear-down run"
  '(#f (raised (not-a-condition first-raise)) (second-set-up-ended second-tore-down))
  (from c10a (lambda (r) (list (car r) (cadr r) (caddr r)))))

(define c10b (computed 10000 (lambda () (failed-start (lambda () (exit 1))))))

(test-equal "10: a set-up that exits while another is held: make-worker waits for it, then raises an &error saying it left"
  '(#f (raised (error make-worker "a set-up left its thread")) (second-set-up-ended second-tore-down))
  (from c10b (lambda (r) (list (car r) (cadr r) (caddr r)))))

(row "10: a set-up that exits, alone: make-worker raises an &error saying it left"
  '(raised (error make-worker "a set-up left its thread"))
  (made-brief (bounded (lambda () (make-worker (lambda () (exit 1)) 1 1)))))

(row "10: threads 2, both set-ups raise: the lowest thread's raise is raised, though the higher thread raised first"
  '(#t #f #t)
  (let* ((entered (new-counter))
         (ids (new-log))
         (high-raised (new-counter))
         (low-obj (list 'low))
         (high-obj (list 'high))
         (r (bounded
             (lambda ()
               (make-worker
                (lambda ()
                  (log! ids (get-thread-id))
                  (counter-bump! entered)
                  (counter-wait entered 2 5000)
                  (let ((mine (get-thread-id)) (all (log-ref ids)))
                    (if (= mine (apply min all))
                        (begin (counter-wait high-raised 1 5000) (raise low-obj))
                        (begin (counter-bump! high-raised) (raise high-obj)))))
                1 2)))))
    (list (and (pair? r) (eq? (car r) 'raised) (eq? (cadr r) low-obj))
          (and (pair? r) (eq? (car r) 'raised) (eq? (cadr r) high-obj))
          (= 1 (counter-ref high-raised)))))

;;; ------------------------------------------------------------------------
;;; 11. A job that exits, then a tear-down that exits too

(row "11: the job's caller is told it left its thread, the stop returns its tear-down's &error, later calls raise worker-stopped?, and no thread is left"
  (list '(raised (error worker-call "the job left its thread"))
        '(raised (error worker-stop! "a tear-down left its thread"))
        '(raised (stopped worker-call "the worker has stopped"))
        0)
  (let* ((w (make-worker new-st 1 1 (lambda (s) (exit 1))))
         (b (new-bench)))
    (let-values (((k c) (call-kept b (lambda () (worker-call w (lambda (s) (exit 1)))))))
      (drive-until-answered! b k)
      (let* ((stopped (stop-outcome w))
             (live (worker-live-count w)))
        (let-values (((k2 c2) (call-kept b (lambda () (worker-call w (lambda (s) 'z))))))
          (drive-until-answered! b k2)
          (list (raised-brief (cell-v k))
                (made-brief stopped)
                (raised-brief (cell-v k2))
                live))))))

;;; ------------------------------------------------------------------------
;;; 12. After a normal stop the worker isn't broken

(row "12: a stop of a worker that ran jobs: a later call raises worker-stopped?, and nothing was written to the output or error ports"
  (list '(returned ok) 'returned '(raised (stopped worker-call "the worker has stopped")) "" "" "")
  (let-values (((eport eextract) (open-string-output-port))
               ((oport oextract) (open-string-output-port))
               ((rport rextract) (open-string-output-port)))
    (with-console-error eport (lambda ()
    (let* ((w (parameterize ((chez:current-output-port oport)
                             (chez:current-error-port rport))
                (make-worker new-st 1 2 (lambda (s) 'torn))))
           (b (new-bench)))
      (let-values (((k c) (call-kept b (lambda () (worker-call w (lambda (s) 'ok))))))
        (drive-until-answered! b k)
        (let ((stopped (stop-outcome w)))
          (let-values (((k2 c2) (call-kept b (lambda () (worker-call w (lambda (s) 'z))))))
            (drive-until-answered! b k2)
            (list (cell-v k) stopped (raised-brief (cell-v k2)) (eextract) (oextract) (rextract))))))))))

;;; ------------------------------------------------------------------------
;;; 13. Tear-downs

(row "13: two tear-downs raise: the stop raises the lowest thread's, and a second stop raises the same object"
  '(#t #f #t)
  (let* ((states (new-log))
         (w (make-worker (lambda ()
                           (let ((s (list (get-thread-id) (list 'td-raise))))
                             (log! states s)
                             s))
                         0 2
                         (lambda (s) (raise (cadr s)))))
         (low (let ((all (log-ref states)))
                (let loop ((r (cdr all)) (best (car all)))
                  (cond ((null? r) best) ((< (car (car r)) (car best)) (loop (cdr r) (car r))) (else (loop (cdr r) best))))))
         (high (car (filter (lambda (s) (not (eq? s low))) (log-ref states))))
         (first (bounded (lambda () (worker-stop! w))))
         (second (bounded (lambda () (worker-stop! w)))))
    (list (and (pair? first) (eq? (car first) 'raised) (eq? (cadr first) (cadr low)))
          (and (pair? first) (eq? (car first) 'raised) (eq? (cadr first) (cadr high)))
          (and (pair? second) (eq? (car second) 'raised) (pair? first) (eq? (cadr second) (cadr first))))))

(row "13: at a failed start a tear-down's raise is kept: make-worker raises the set-up's, and the tear-down ran"
  '(#t (td-ran))
  (let* ((entered (new-counter))
         (log (new-log))
         (set-up-raise (list 'set-up-raise))
         (r (bounded (lambda ()
                       (make-worker (lambda ()
                                      (counter-bump! entered)
                                      (if (= 1 (counter-ref entered))
                                          (raise set-up-raise)
                                          'state))
                                    1 2
                                    (lambda (s) (log! log 'td-ran) (raise (list 'td-raise))))))))
    (list (and (pair? r) (eq? (car r) 'raised) (eq? (cadr r) set-up-raise))
          (log-ref log))))

;;; ------------------------------------------------------------------------
;;; 14. A stop on a worker's own thread is refused

(define (stop-try w)
  (guard (e (#t (list (assertion-violation? e) (and (who-condition? e) (condition-who e)))))
    (worker-stop! w)
    'no-raise))

(row "14: a job of A stopping A, and stopping B, is refused with who worker-stop!; both workers then serve"
  '((returned ((#t worker-stop!) (#t worker-stop!))) (returned after-a) (returned after-b) returned returned)
  (let* ((wa (make-worker new-st 1 1))
         (wb (make-worker new-st 1 1))
         (b (new-bench)))
    (let-values (((k1 c1) (call-kept b (lambda () (worker-call wa (lambda (s) (list (stop-try wa) (stop-try wb))))))))
      (drive-until-answered! b k1)
      (let-values (((k3 c3) (call-kept b (lambda () (worker-call wa (lambda (s) 'after-a)))))
                   ((k4 c4) (call-kept b (lambda () (worker-call wb (lambda (s) 'after-b))))))
        (drive-until-answered! b k3 k4)
        (let* ((sa (stop-outcome wa)) (sb (stop-outcome wb)))
          (list (cell-v k1) (cell-v k3) (cell-v k4) sa sb))))))

;;; ------------------------------------------------------------------------
;;; 15. A job's parameters and output port are make-worker's

(define p15 (make-thread-parameter 'outside))

(row "15: a job sees the thread parameter and the output port make-worker ran with, not the caller's"
  (list '(returned (inside #t)) "job-wrote" 'outside)
  (let-values (((oport oextract) (open-string-output-port)))
    (let* ((w (parameterize ((p15 'inside) (chez:current-output-port oport))
                (make-worker new-st 1 1)))
           (b (new-bench)))
      (let-values (((k c) (call-kept b (lambda ()
                                         (worker-call w (lambda (s)
                                                          (let ((port (chez:current-output-port)))
                                                            (put-string port "job-wrote")
                                                            (list (p15) (eq? port oport)))))))))
        (drive-until-answered! b k)
        (stop-outcome w)
        (list (cell-v k) (oextract) (p15))))))

;;; ------------------------------------------------------------------------
;;; 16. The stress run

(define seed 20261123)

(display "worker-threads stress seed: ") (display seed) (newline)

;; A generator of numbers below N from a fixed seed.
(define (make-rng seed)
  (let ((x seed))
    (lambda (n)
      (set! x (mod (+ (* x 1103515245) 12345) 2147483648))
      (mod (div x 65536) n))))

(define stress-states (new-log))
(define stress-ran (new-counter))
(define stress-mismatches (new-counter))

(define (stress-set-up)
  (let ((s (new-st)))
    (log! stress-states s)
    s))

;; spec: (worker kind length deadline n)
(define current-spec (make-cell #f))

(define (quiet req e) (make-res 500 '() #f))

(define (stress-job kind len n)
  (lambda (s)
    (unless (eqv? (st-tid s) (get-thread-id)) (counter-bump! stress-mismatches))
    (st-n-set! s (+ 1 (st-n s)))
    (counter-bump! stress-ran)
    (when (> len 0) (sleep (ms len)))
    (if (eq? kind 'raise) (raise (list 'boom n)) n)))

(define (stress-app req)
  (let* ((spec (cell-v current-spec))
         (w (vector-ref spec 0)) (kind (vector-ref spec 1)) (len (vector-ref spec 2))
         (dl (vector-ref spec 3)) (n (vector-ref spec 4))
         (inner (lambda (req)
                  (make-res 200 '() (number->string (worker-call w (stress-job kind len n)))))))
    (((wrap-catch-with quiet) ((wrap-timeout dl) ((wrap-busy 1) inner))) req)))

(define (text bv)
  (let* ((n (bytevector-length bv)) (s (make-string n)))
    (let loop ((i 0))
      (if (= i n) s (begin (string-set! s i (integer->char (bytevector-u8-ref bv i))) (loop (+ i 1)))))))

(define (stress-run)
  (let* ((rng (make-rng seed))
         (readers (make-worker stress-set-up 8 4))
         (writer (make-worker stress-set-up 4 1))
         (host (make-test-host (circuit->handler stress-app (lambda (name) #f)) (lambda (name) #f)))
         (violations '())
         (tally (list (cons 200 (make-cell 0)) (cons 500 (make-cell 0)) (cons 503 (make-cell 0)) (cons 504 (make-cell 0))))
         (total 0)
         (deadlines (vector 2 4 8 50 100000)))
    (define (tally! s)
      (let ((e (assv s tally))) (if e (cell-v-set! (cdr e) (+ 1 (cell-v (cdr e)))) (set! violations (cons (list 'status s) violations)))))
    (let batch ((made 0))
      (when (< made 2000)
        (let* ((size (min 40 (- 2000 made)))
               (reqs
                (map (lambda (i)
                       (let* ((n (+ made i))
                              (w (if (< (rng 100) 85) readers writer))
                              (r (rng 100))
                              (kind (if (< r 15) 'raise 'ok))
                              (len (cond ((< r 15) (rng 3)) ((< r 30) (+ 15 (rng 10))) (else (rng 4))))
                              (dl (vector-ref deadlines (rng 5)))
                              (spec (vector w kind len dl n)))
                         (cell-v-set! current-spec spec)
                         (let ((c (test-host-connect! host)))
                           (test-client-send! c get-bytes)
                           (cons c spec))))
                     (iota size))))
          (unless (drive! host 1 (lambda () (all-of (lambda (x) (pair? (test-client-responses (car x)))) reqs)))
            (set! violations (cons (list 'unanswered batch) violations)))
          (for-each
           (lambda (x)
             (let ((rs (test-client-responses (car x))) (spec (cdr x)))
               (if (not (= 1 (length rs)))
                   (set! violations (cons (list 'responses (vector-ref spec 4) (length rs)) violations))
                   (let ((status (test-response-status (car rs)))
                         (body (text (test-response-body (car rs))))
                         (kind (vector-ref spec 1)) (n (vector-ref spec 4)))
                     (set! total (+ total 1))
                     (tally! status)
                     (unless (case status
                               ((200) (and (eq? kind 'ok) (string=? body (number->string n))))
                               ((500) (and (eq? kind 'raise) (string=? body "")))
                               ((503 504) (string=? body ""))
                               (else #f))
                       (set! violations (cons (list 'bad status kind n body) violations)))))))
           reqs)
          (batch (+ made size)))))
    (let* ((s1 (stop-outcome readers))
           (s2 (stop-outcome writer)))
      (test-host-advance! host 0)
      (test-host-advance! host 0)
      (let* ((log (test-host-log host))
             (late (filter (lambda (e) (eq? (car e) 'late-resume)) log))
             (states (log-ref stress-states))
             (sum (apply + (map st-n states))))
        (list 'violations (reverse violations)
              'total total
              'tally (map (lambda (e) (cons (car e) (cell-v (cdr e)))) tally)
              'stops (list s1 s2)
              'live (list (worker-live-count readers) (worker-live-count writer))
              'late-resume (length late)
              'log-kinds (map car log)
              'states (length states)
              'distinct-threads (distinct-by eqv? (map st-tid states))
              'distinct-states (distinct-by eq? states)
              'ran-matches (= sum (counter-ref stress-ran))
              'mismatches (counter-ref stress-mismatches))))))

(define (all-of f xs) (or (null? xs) (and (f (car xs)) (all-of f (cdr xs)))))

(define c16 (computed 30000 stress-run))

(define (stress-get key) (from c16 (lambda (r) (cadr (memq key r)))))

(from c16 (lambda (r)
            (display "worker-threads stress tally: ") (write (stress-get 'tally)) (newline)))

(test-equal "16: every response is one its job allows, none missing"
  '(() 2000) (from c16 (lambda (r) (list (stress-get 'violations) (stress-get 'total)))))
(test-equal "16: each of 200, 500, 503 and 504 was seen"
  '(#t #t #t #t)
  (from c16 (lambda (r) (map (lambda (s) (> (cdr (assv s (stress-get 'tally))) 0)) '(200 500 503 504)))))
(test-equal "16: both stops return, and no thread is live"
  '((returned returned) (0 0)) (from c16 (lambda (r) (list (stress-get 'stops) (stress-get 'live)))))
(test-equal "16: the host's log holds no late-resume"
  0 (from c16 (lambda (r) (stress-get 'late-resume))))
(test-equal "16: five states on five threads, each used by its own thread, every job counted once"
  '(5 5 5 #t 0)
  (from c16 (lambda (r) (list (stress-get 'states) (stress-get 'distinct-threads) (stress-get 'distinct-states)
                              (stress-get 'ran-matches) (stress-get 'mismatches)))))

;;; ------------------------------------------------------------------------
;;; 17. The catch's layers, a forked stop, a raise not continuable, two raises

(row "17: a warning raised plainly: the call raises a non-continuable violation, the worker isn't stopped, a later call answers"
  '(raised #t (returned alive) returned)
  (let-values (((eport eextract) (open-string-output-port)))
    (with-console-error eport
      (lambda ()
        (let* ((w (make-worker new-st 1 1))
               (b (new-bench)))
          (let-values (((k c) (call-kept b (lambda ()
                                             (worker-call w (lambda (s)
                                                              (raise (condition (make-warning)
                                                                                (make-message-condition "plain")))))))))
            (drive-until-answered! b k)
            (let-values (((k2 c2) (call-kept b (lambda () (worker-call w (lambda (s) 'alive))))))
              (drive-until-answered! b k2)
              (let ((v (cell-v k)))
                (list (and (pair? v) (car v))
                      (and (pair? v) (pair? (cdr v)) (non-continuable-violation? (cadr v)))
                      (cell-v k2)
                      (stop-outcome w))))))))))

(row "17: a stop from a thread a job forks isn't refused: it stops the other worker, which has no thread left"
  '((returned stopped-b) 0)
  (let* ((wa (make-worker new-st 1 1))
         (wb (make-worker new-st 1 1))
         (b (new-bench)))
    (let-values (((k c) (call-kept b (lambda ()
                                       (worker-call
                                        wa
                                        (lambda (s)
                                          (let* ((out 'unset)
                                                 (t (fork-thread
                                                     (lambda ()
                                                       (set! out (guard (e (#t (list 'refused (and (who-condition? e) (condition-who e)))))
                                                                   (worker-stop! wb)
                                                                   'stopped-b))))))
                                            (thread-join t)
                                            out)))))))
      (drive-until-answered! b k)
      (let ((live (worker-live-count wb)))
        (stop-outcome wa)
        (list (cell-v k) live)))))

(row "17: a job's raise isn't continuable: an outer handler that returns doesn't make the call return"
  '(raised #t)
  (let* ((w (make-worker new-st 1 1))
         (b (new-bench)))
    (let-values (((k c) (call-kept b (lambda ()
                                       (with-exception-handler
                                        (lambda (e) 'handler-value)
                                        (lambda () (worker-call w (lambda (s) (raise (list 'job-raise))))))))))
      (drive-until-answered! b k)
      (stop-outcome w)
      (let ((v (cell-v k)))
        (list (car v) (and (pair? (cdr v)) (non-continuable-violation? (cadr v))))))))

;;; ------------------------------------------------------------------------

(test-end "worker-threads")

(exit (suite-exit-status runner))
