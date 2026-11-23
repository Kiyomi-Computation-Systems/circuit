#!r6rs
;;; (worker-schedule): the real worker, on real threads, under a schedule the
;;; test sets, checked step by step against tests/worker-model.sls's world.
;;; Test-only.
;;;
;;; The worker is made through (circuit worker shell)'s make-shell-worker,
;;; with an observer. A driver, the caller of run-life, draws each event at
;;; random from the model's enabled events, makes it happen for real, then
;;; replays what the observer saw into the model, comparing each step.
;;;
;;; THREADS. The driver never holds the worker's lock. The loop is one
;;; thread start-loop! forks: it alone calls the test host, so it is the
;;; loop's thread, and it runs one host command at a time. The driver
;;; doesn't wait for a command to end, since the double's register blocks a
;;; send until its job is posted. The maker and each stopper run on threads
;;; the driver forks; the worker's threads are the shell's.
;;;
;;; WHAT IS SEEN. Each observation goes, under the harness lock, to a queue
;;; per thread id, so each queue is in its thread's own order: the
;;; observer's points and notes; each gate's arrival (the set-up, each job
;;; and each tear-down block at a gate until the driver gives a command);
;;; the maker's and each stopper's begin and end; and on the loop, each
;;; handler's outcome and the end of each host command.
;;;
;;; HOLDING. The observer blocks a party at a point only where the model's
;;; next event for that party starts there: a thread after a section with
;;; effects or a wait reply, and after each effect but the last of a step
;;; that didn't answer wait; a stopper after its first stop and after
;;; each effect. Anywhere else the party runs on: into a gate, a wait, a
;;; join or its end. The loop's thread is never held.
;;;
;;; THE DRAW. Only events the harness makes happen are drawn: a fork, a
;;; gate's command, a release from a point, a host command, a stopper's
;;; start. The rest happen of themselves and the replay follows them: a
;;; woken party's held step, a register's effects and the double's check
;;; of its mark, deliveries, joins. Two more are left out. No call after
;;; the server's stop: the test host then opens a fresh inbox for the next
;;; outside wait, where the server's stays closed. No deadline for a caller
;;; whose post the inbox holds: every host command hands posts over first,
;;; so the wait would end with its answer.
;;;
;;; THE REPLAY. The real state changes only under the worker's lock, and a
;;; step that changes nothing answers the very machine, so the steps form a
;;; chain: a step's before is eq? to the last one's after. Among the heads
;;; of the queues, the driver takes the party the event released first,
;;; then any other the model allows, a woken party's held step or a
;;; completion, and last a step from a party the model has waiting, which
;;; is a spurious wakeup. Before the released party's changing step goes
;;; everything else ready that changes nothing: a spurious wakeup's no-op
;;; steps at the machine it starts from, and the notes between them.
;;;
;;; SPURIOUS WAKEUPS can't be scheduled, and none has shown on Linux. The
;;; replay follows any number: a party's first is the model's own spurious
;;; event and step; each later one, past the model's budget of one, is held
;;; to the machine's own step on the model's machine, which must answer
;;; wait, make no effects and change nothing, and the double's check must
;;; find its ticket unmarked. So a platform whose waits wake spuriously
;;; more often, as macOS's may, needs nothing more. Each step is
;;; compared whole with world-apply/steps' step, and the machine after it
;;; with the model's, real tickets and results put in the model's terms:
;;; the c-th call's ticket is kc, and an end's result is (value kc) or
;;; (raise kc), from the command its gate was given.
(library (worker-schedule)
  (export start-loop! run-life
          lived? lived-drawn lived-applied lived-failure lived-config
          print-failure)
  (import (rnrs)
          (rnrs mutable-pairs)
          (only (chezscheme) fork-thread thread-join make-mutex mutex-acquire mutex-release
                make-condition condition-wait condition-broadcast get-thread-id make-time
                real-time)
          (circuit worker machine)
          (circuit worker shell)
          (only (http-server) awaiting with-deadline make-response request-path
                deadline-passed? client-closed?)
          (http-server testing)
          (worker-model))

  ;; -------------------------------------------------------------------
  ;; Failures

  (define-record-type harness-failure (fields message irritants))

  (define (hfail message . irritants)
    (raise (make-harness-failure message irritants)))

  ;; -------------------------------------------------------------------
  ;; The loop thread, shared by every life

  (define loop-m (make-mutex))
  (define loop-c (make-condition))
  (define loop-cmd #f)
  (define loop-tid #f)

  ;; start-loop! : -> Void
  ;; Forks the loop thread, once.
  (define (start-loop!)
    (unless loop-tid
      (fork-thread probe-body)
      (fork-thread loop-body)
      (mutex-acquire loop-m)
      (let wait () (unless loop-tid (condition-wait loop-c loop-m) (wait)))
      (mutex-release loop-m)))

  (define (loop-body)
    (mutex-acquire loop-m)
    (set! loop-tid (get-thread-id))
    (condition-broadcast loop-c)
    (let next ()
      (let ((cmd loop-cmd))
        (if cmd
            (begin
              (set! loop-cmd #f)
              (mutex-release loop-m)
              (let* ((L (vector-ref cmd 0)) (tag (vector-ref cmd 1))
                     (r (guard (e (#t (list 'raised e))) ((vector-ref cmd 2)) 'ok)))
                (push-locked! L (get-thread-id) (list 'host-done tag r)))
              (mutex-acquire loop-m)
              (next))
            (begin (condition-wait loop-c loop-m) (next))))))

  ;; -------------------------------------------------------------------
  ;; The live count, read on a thread of its own

  ;; worker-live-count takes the worker's lock, which a shell that broke
  ;; the protocol may never let go. The driver never blocks on it: a
  ;; prober thread reads it, and the driver waits a bounded time.
  (define probe-m (make-mutex))
  (define probe-c (make-condition))
  (define probe-req #f)
  (define probe-ans #f)
  (define probe-seq 0)

  (define (probe-body)
    (mutex-acquire probe-m)
    (let next ()
      (let ((req probe-req))
        (if req
            (begin
              (set! probe-req #f)
              (mutex-release probe-m)
              (let ((n (guard (e (#t (list 'raised e))) (worker-live-count (car req)))))
                (mutex-acquire probe-m)
                (set! probe-ans (cons (cdr req) n))
                (condition-broadcast probe-c)
                (next)))
            (begin (condition-wait probe-c probe-m) (next))))))

  ;; live-count : Worker -> (U Nat #f)
  ;; W's live count, or #f when it isn't read within settle-ms.
  (define (live-count w)
    (mutex-acquire probe-m)
    (set! probe-seq (+ probe-seq 1))
    (let ((n probe-seq) (limit (+ (real-time) settle-ms)))
      (set! probe-req (cons w n))
      (condition-broadcast probe-c)
      (let wait ()
        (cond
         ((and probe-ans (= (car probe-ans) n))
          (let ((v (cdr probe-ans)))
            (mutex-release probe-m)
            (if (fixnum? v) v (hfail "worker-live-count raised" (describe* (cadr v))))))
         ((> (real-time) limit) (mutex-release probe-m) #f)
         (else
          (condition-wait probe-c probe-m (make-time 'time-duration 50000000 0))
          (wait))))))

  ;; The live count, failing the run when the worker's lock is never let go.
  (define (live-count! L)
    (or (live-count (life-worker L))
        (hfail "worker-live-count found the worker's lock held for 2 s"
               (cons 'unsettled (unsettled L)))))

  (define (host! L tag thunk)
    (when (life-loop-busy? L) (hfail "a host command while the loop is busy" tag))
    (life-loop-busy?-set! L tag)
    (mutex-acquire loop-m)
    (set! loop-cmd (vector L tag thunk))
    (condition-broadcast loop-c)
    (mutex-release loop-m))

  ;; -------------------------------------------------------------------
  ;; A life: one worker, from its fork to a world where nothing is drawable

  ;; A worker thread's state, made by its set-up: which thread made it.
  (define-record-type wstate (fields t tid))

  ;; What a job of caller c raises: an object of its own.
  (define-record-type job-raise (fields c))

  (define-record-type life
    (fields config double? n callers stoppers
            hm hc (mutable inbox) held release tracking gates
            (mutable worker)
            dq (mutable world) (mutable machine)
            thread-tid tid-party stopper-tid (mutable maker-tid)
            tickets results
            last-cmd cmd-job job-on ran-on gate-at self-stop-owed
            last-kind last-effect
            raise-objs outcomes abandon-how instants
            (mutable trigger) (mutable sending) (mutable loop-busy?)
            (mutable host) (mutable clients) (mutable final)
            (mutable drawn) (mutable applied) (mutable steps-now) (mutable trace)
            (mutable model-begun) (mutable real-begun) (mutable model-torn) (mutable real-torn)
            (mutable setup-pending) (mutable forked) (mutable done-seen)
            weights prng stats)
    (protocol
     (lambda (new)
       (lambda (config prng weights stats)
         (let ((n (config-threads config)) (callers (config-callers config))
               (stoppers (config-stoppers config)))
           (new config (and (memq 'double (config-flags config)) #t) n callers stoppers
                (make-mutex) (make-condition) '()
                (make-eqv-hashtable) (make-eqv-hashtable) (make-eqv-hashtable)
                (make-eqv-hashtable)
                #f
                (make-eqv-hashtable) (initial-world config) #f
                (make-vector n #f)
                (let ((h (make-eqv-hashtable))) (hashtable-set! h loop-tid '(loop)) h)
                (make-vector (max stoppers 1) #f) #f
                (make-eq-hashtable) (make-eq-hashtable)
                (make-vector n #f) (make-vector n #f) (make-vector n #f)
                (make-vector (max callers 1) #f) (make-vector n #f) (make-vector n #f)
                (make-eqv-hashtable) (make-eqv-hashtable)
                (let ((v (make-vector (max callers 1) #f)))
                  (let loop ((c 1))
                    (when (<= c callers)
                      (vector-set! v (- c 1) (make-job-raise c))
                      (loop (+ c 1))))
                  v)
                (make-vector (max callers 1) #f) (make-vector (max callers 1) #f)
                (make-vector (max callers 1) #f)
                #f #f #f
                #f #f #f
                0 0 '() '()
                '() '() '() '()
                '() '() '()
                weights prng stats))))))

  ;; lived? : Any -> Boolean
  ;; lived-config : Lived -> Config
  ;; lived-drawn : Lived -> Natural                 ; events drawn and made to happen
  ;; lived-applied : Lived -> Natural               ; model events the replay applied
  ;; lived-failure : Lived -> (U #f Sexp)
  (define-record-type lived (fields config drawn applied failure))

  (define (stat! L name)
    (hashtable-update! (life-stats L) name (lambda (n) (+ n 1)) 0))

  ;; -------------------------------------------------------------------
  ;; What the worker's threads, the maker, the stoppers and the loop log

  (define (push! L tid obs)
    (life-inbox-set! L (cons (cons tid obs) (life-inbox L))))

  (define (push-locked! L tid obs)
    (mutex-acquire (life-hm L))
    (push! L tid obs)
    (condition-broadcast (life-hc L))
    (mutex-release (life-hm L)))

  ;; The observer. Blocking points may block; notes never do.
  (define (make-observer L)
    (lambda (kind party tid info)
      (let ((me (get-thread-id)) (hm (life-hm L)) (hc (life-hc L)))
        (mutex-acquire hm)
        (push! L me (list kind party info))
        (unless (eqv? tid me) (push! L me (list 'tid-mismatch kind tid)))
        (let ((block? (and (memq kind '(section effect effected))
                           (decide-block! L me kind party info))))
          (when block? (hashtable-set! (life-held L) me #t))
          (condition-broadcast hc)
          (when block?
            (let wait ()
              (unless (hashtable-ref (life-release L) me #f)
                (condition-wait hc hm)
                (wait)))
            (hashtable-delete! (life-release L) me)
            (hashtable-delete! (life-held L) me)))
        (mutex-release hm))))

  ;; Whether the observer holds party at this point, from the info and
  ;; what it kept of the party's last section: (effects-left . reply), or
  ;; (effects-left . stopper).
  (define (decide-block! L me kind party info)
    (let ((tracking (life-tracking L)))
      (cond
       ((eqv? me loop-tid) #f)
       ((not (and (pair? party) (memq (car party) '(thread stopper)))) #f)
       ((eq? kind 'effect) #f)
       ((eq? kind 'section)
        (let ((ev (car info)) (reply (list-ref info 3)) (effects (list-ref info 4)))
          (if (eq? (car party) 'stopper)
              (and (not (equal? ev '(stop #t)))
                   (begin (hashtable-set! tracking me (cons effects 'stopper)) #t))
              (begin (hashtable-set! tracking me (cons effects reply))
                     (or (pair? effects) (eq? reply 'wait))))))
       (else
        (let ((tr (hashtable-ref tracking me #f)))
          (and tr (pair? (car tr))
               (let ((rest (cdr (car tr))) (r (cdr tr)))
                 (hashtable-set! tracking me (cons rest r))
                 (or (pair? rest) (eq? r 'stopper) (eq? r 'wait)))))))))

  ;; A gate: logs the arrival, then blocks until the driver gives a command.
  (define (gate! L kind c state)
    (let ((me (get-thread-id)) (hm (life-hm L)) (hc (life-hc L)))
      (mutex-acquire hm)
      (push! L me (list 'gate kind c state))
      (hashtable-set! (life-gates L) me (vector kind c state #f))
      (condition-broadcast hc)
      (let wait ()
        (let* ((g (hashtable-ref (life-gates L) me #f)) (cmd (vector-ref g 3)))
          (if cmd
              (begin (hashtable-delete! (life-gates L) me) (mutex-release hm) cmd)
              (begin (condition-wait hc hm) (wait)))))))

  (define (make-set-up L)
    (lambda ()
      (let* ((cmd (gate! L 'setup #f #f)) (t (car cmd)))
        (case (cadr cmd)
          ((returned) (make-wstate t (get-thread-id)))
          ((raised) (raise (list 'boom 'set-up t)))
          (else (exit))))))

  (define (make-tear-down L)
    (lambda (state)
      (let ((t (if (wstate? state) (wstate-t state) 0)))
        (case (gate! L 'teardown t state)
          ((returned) 'torn-down)
          ((raised) (raise (list 'boom 'tear-down t)))
          (else (exit))))))

  (define (make-job L c)
    (lambda (state)
      (let again ()
        (case (gate! L 'job c state)
          ((value) (values (ticket-of c) (if (wstate? state) (wstate-t state) 0)))
          ((raise) (raise (vector-ref (life-raise-objs L) (- c 1))))
          ((self-stop)
           (let ((r (guard (e (#t (list 'raised e)))
                      (worker-stop! (life-worker L))
                      'no-raise)))
             (push-locked! L (get-thread-id) (list 'self-stopped c r))
             (again)))
          (else (exit))))))

  (define (fork-maker! L)
    (let ((c (life-config L)))
      (life-forked-set!
       L (cons (fork-thread
                (lambda ()
                  (push-locked! L (get-thread-id) '(begin maker))
                  (let ((r (guard (e (#t (list 'raised e)))
                             (list 'ready
                                   (make-shell-worker (make-observer L) step (life-double? L)
                                                      (make-set-up L) (config-cap c)
                                                      (config-threads c) (make-tear-down L))))))
                    (when (eq? (car r) 'ready) (life-worker-set! L (cadr r)))
                    (push-locked! L (get-thread-id) (list 'done 'maker r)))))
               (life-forked L)))))

  (define (fork-stopper! L s)
    (life-forked-set!
     L (cons (fork-thread
              (lambda ()
                (push-locked! L (get-thread-id) (list 'begin 'stopper s))
                (let ((r (guard (e (#t (list 'raised e)))
                           (worker-stop! (life-worker L))
                           'returned)))
                  (push-locked! L (get-thread-id) (list 'done 'stopper s r)))))
             (life-forked L))))

  ;; -------------------------------------------------------------------
  ;; The host, on the loop thread

  (define (deadline-ms c) (+ 10 c))

  (define (request-bytes c)
    (string->utf8 (string-append "GET /c" (number->string c) " HTTP/1.1\r\nHost: x\r\n\r\n")))

  (define (path-caller p) (string->number (substring p 2 (string-length p))))

  (define (make-handler L)
    (lambda (req)
      (awaiting
       (lambda ()
         (let* ((c (path-caller (request-path req)))
                (x (guard (e (#t (list 'raised e)))
                     (call-with-values
                       (lambda ()
                         (with-deadline (deadline-ms c)
                           (lambda () (worker-call (life-worker L) (make-job L c)))))
                       (lambda vals (cons 'values vals))))))
           (push-locked! L (get-thread-id) (list 'outcome c x))
           (make-response 200 #f '() (string->utf8 (outcome-text L c x))))))))

  ;; The body a handler answers for what worker-call gave it.
  (define (outcome-text L c x)
    (if (eq? (car x) 'values)
        (call-with-string-output-port (lambda (p) (write (cdr x) p)))
        (let ((e (cadr x)))
          (cond ((eq? e (vector-ref (life-raise-objs L) (- c 1))) "raise")
                ((worker-full? e) "full")
                ((worker-stopped? e) "stopped")
                ((deadline-passed? e) "deadline")
                ((client-closed? e) "closed")
                ((call-error? e left-message) "left")
                ((call-error? e broken-message) "broken")
                (else "other")))))

  ;; A left job's answer and the broken worker's are both an &error from
  ;; worker-call; only their messages tell them apart.
  (define left-message "the job left its thread")
  (define broken-message "the worker is broken")

  (define (call-error? e message)
    (and (error? e) (who-condition? e) (eq? (condition-who e) 'worker-call)
         (not (worker-stopped? e)) (not (worker-full? e))
         (message-condition? e) (equal? (condition-message e) message)))

  (define (new-host! L)
    (let ((host (make-test-host (make-handler L))))
      (life-host-set! L host)
      (life-clients-set!
       L (let loop ((c 1) (acc '()))
           (if (> c (life-callers L))
               (list->vector (reverse acc))
               (loop (+ c 1) (cons (test-host-connect! host) acc)))))))

  (define (client L c) (vector-ref (life-clients L) (- c 1)))

  (define (send-call! L c)
    (test-client-send! (client L c) (request-bytes c))
    (vector-set! (life-instants L) (- c 1)
                 (+ (test-host-now (life-host L)) (deadline-ms c))))

  (define (read-final! L)
    (life-final-set!
     L (list (test-host-log (life-host L))
             (let loop ((c 1) (acc '()))
               (if (> c (life-callers L))
                   (reverse acc)
                   (loop (+ c 1)
                         (cons (map (lambda (r)
                                      (list (test-response-status r)
                                            (utf8->string (test-response-body r))
                                            (test-response-complete? r)))
                                    (test-client-responses (client L c)))
                               acc)))))))

  ;; -------------------------------------------------------------------
  ;; The driver's view: parties, the model, translation

  (define (thread-tid L t) (vector-ref (life-thread-tid L) (- t 1)))
  (define (stopper-tid L s) (vector-ref (life-stopper-tid L) (- s 1)))
  (define (party-of L tid) (hashtable-ref (life-tid-party L) tid #f))
  (define (W L) (life-world L))
  (define (vref v i) (vector-ref v (- i 1)))
  (define (vset! v i x) (vector-set! v (- i 1) x))

  (define (enabled? L ev) (and (member ev (world-enabled (W L))) #t))

  ;; model! : Life Event -> (Listof Step)
  (define (model! L ev)
    (let ((got (guard (x ((model-failure? x)
                          (hfail "the model refused an event" ev
                                 (model-failure-property x) (model-failure-message x)
                                 (model-failure-irritants x))))
                 (call-with-values (lambda () (world-apply/steps (W L) ev)) list))))
      (life-world-set! L (car got))
      (life-applied-set! L (+ 1 (life-applied L)))
      (life-steps-now-set! L (cons ev (life-steps-now L)))
      (for-each (lambda (s)
                  (hashtable-update! (life-stats L) (list 'row (cadddr s)) (lambda (n) (+ n 1)) 0)
                  (let ((reply (cadr s)) (e (car s)))
                    (when (and (pair? reply) (eq? (car reply) 'run))
                      (life-model-begun-set! L (cons (list (cadr reply) (cadr e))
                                                     (life-model-begun L))))
                    (when (eq? (car e) 'torn-down)
                      (life-model-torn-set! L (cons (cadr e) (life-model-torn L))))))
                (cadr got))
      (cadr got)))

  ;; A real datum in the model's terms.
  (define (tr L x)
    (cond
     ((hashtable-ref (life-results L) x #f) => (lambda (r) r))
     ((hashtable-ref (life-tickets L) x #f) => (lambda (c) (ticket-of c)))
     ((pair? x) (cons (tr L (car x)) (tr L (cdr x))))
     ((machine? x) (machine-datum L x))
     (else x)))

  (define (machine-datum L m)
    (list (machine-phase m) (tr L (machine-slots m)) (tr L (machine-queue m))
          (tr L (machine-raises m))))

  (define (model-machine L)
    (let ((m (world-machine (W L))))
      (list (machine-phase m) (machine-slots m) (machine-queue m) (machine-raises m))))

  (define (info-event i) (car i))
  (define (info-before i) (cadr i))
  (define (info-after i) (caddr i))
  (define (info-reply i) (cadddr i))
  (define (info-effects i) (car (cddddr i)))

  (define (chain-ok? L info)
    (or (not (life-machine L)) (eq? (info-before info) (life-machine L))))

  ;; Compares a real step with the model's, then moves the chain on.
  (define (compare-step! L info step)
    (let ((real (list (tr L (info-event info)) (tr L (info-reply info)) (tr L (info-effects info))))
          (model (list (car step) (cadr step) (caddr step))))
      (unless (equal? real model)
        (hfail "a step differs from the model's" (list 'shell real) (list 'model model)
               (list 'row (cadddr step))))
      (life-machine-set! L (info-after info))))

  (define (compare-machine! L info)
    (let ((real (machine-datum L (info-after info))) (model (model-machine L)))
      (unless (equal? real model)
        (hfail "the machine after a step differs from the model's"
               (list 'shell real) (list 'model model)))))

  (define (pop! L tid)
    (hashtable-update! (life-dq L) tid cdr '()))

  (define (place-of L party)
    (case (car party)
      ((thread) (world-thread (W L) (cadr party)))
      ((stopper) (world-stopper (W L) (cadr party)))
      ((caller) (world-caller (W L) (cadr party)))
      ((maker) (world-maker (W L)))
      (else #f)))

  (define (pending-effects place)
    (and (pair? place) (memq (car place) '(effects registering)) (cadr place)))

  ;; The model party of an observation's real party, on thread tid.
  (define (model-party L tid sparty)
    (let ((p (party-of L tid)))
      (cond
       ((not p) #f)
       ((eq? (car p) 'loop)
        (and (pair? sparty) (eq? (car sparty) 'caller)
             (let ((c (hashtable-ref (life-tickets L) (cadr sparty) #f)))
               (and c (list 'caller c)))))
       (else p))))

  ;; -------------------------------------------------------------------
  ;; Interpreting the head of a queue

  ;; interpret : Life Tid Obs -> (U #f (Pair Class Thunk))
  ;; Class is one of trigger, other or spurious; the thunk consumes the
  ;; head, applies its model events, and compares. #f: not now.
  (define (interpret L tid obs)
    (let ((class (if (eqv? tid (life-trigger L)) 'trigger 'other))
          (party (party-of L tid)))
      (define (move thunk) (cons class thunk))
      (case (car obs)
        ((begin)
         (and (not party)
              (move (lambda ()
                      (pop! L tid)
                      (life-trigger-set! L tid)
                      (if (eq? (cadr obs) 'maker)
                          (begin (life-maker-tid-set! L tid)
                                 (hashtable-set! (life-tid-party L) tid '(maker)))
                          (let ((s (caddr obs)))
                            (vset! (life-stopper-tid L) s tid)
                            (hashtable-set! (life-tid-party L) tid (list 'stopper s))))))))
        ((section held) (and party (interpret-step L tid obs party class)))
        ((effect) (and party (interpret-effect L tid obs class)))
        ((effected)
         (move (lambda ()
                 (unless (eq? (caddr obs) (hashtable-ref (life-last-effect L) tid #f))
                   (hfail "an effected point for another effect than the last carried out"
                          tid (tr L (caddr obs))))
                 (pop! L tid)
                 (hashtable-set! (life-last-kind L) tid 'effected))))
        ((wait) (and party (interpret-wait L tid obs party class)))
        ((mark) (and party (interpret-mark L tid obs class)))
        ((gate) (interpret-gate L tid obs party class))
        ((self-stopped)
         (move (lambda ()
                 (let ((t (and party (eq? (car party) 'thread) (cadr party))) (r (caddr obs)))
                   (unless (and t (vref (life-self-stop-owed L) t))
                     (hfail "a job's worker-stop! answered without stepping (stop #t)" tid obs))
                   (vset! (life-self-stop-owed L) t #f)
                   (unless (and (pair? r) (eq? (car r) 'raised) (assertion-violation? (cadr r))
                                (who-condition? (cadr r))
                                (eq? (condition-who (cadr r)) 'worker-stop!))
                     (hfail "worker-stop! on a worker's own thread wasn't refused by an assertion"
                            r))
                   (stat! L 'self-stops)
                   (pop! L tid)))))
        ((done) (and party (interpret-done L tid obs class)))
        ((outcome) (interpret-outcome L tid obs class))
        ((host-done) (interpret-host-done L tid obs class))
        (else (hfail "an observation the harness can't read" tid obs)))))

  ;; A step the model event ev stands for, if it is enabled now.
  (define (step-move L tid obs ev class want-kind)
    (and (enabled? L ev)
         (cons class
               (lambda ()
                 (unless (eq? (car obs) want-kind)
                   (hfail "a step taken as a section where a held step was due, or the other way"
                          ev (car obs)))
                 (pop! L tid)
                 (let ((steps (model! L ev)) (info (caddr obs)))
                   (unless (= (length steps) 1)
                     (hfail "one real step for a model event of another count" ev steps))
                   (compare-step! L info (car steps))
                   (compare-machine! L info)
                   (hashtable-set! (life-last-kind L) tid (car obs)))))))

  ;; A held step from a party the model has waiting: a spurious wakeup.
  ;; The model allows one per party; past that, see past-budget-move.
  (define (spurious-move L tid obs spurious ev)
    (if (enabled? L spurious)
        (cons 'spurious
              (lambda ()
                (stat! L 'spurious)
                (model! L spurious)
                ((cdr (or (step-move L tid obs ev 'other 'held)
                          (hfail "a spurious wakeup the model can't follow" ev))))))
        (past-budget-move L tid obs)))

  ;; A spurious wakeup past the model's budget. From a waiting place the
  ;; woken party's step answers wait, makes no effects and changes nothing,
  ;; and it waits again, so the world is the one the model's spurious event
  ;; and step would leave, but for the spent budget. The real step is held
  ;; to the machine's own step on the model's machine, which must answer
  ;; the same, and change nothing.
  (define (past-budget-move L tid obs)
    (cons 'spurious
          (lambda ()
            (let* ((info (caddr obs)) (m (world-machine (W L))) (ev (tr L (info-event info)))
                   (got (guard (x (#t (list 'raised (describe* x))))
                          (call-with-values (lambda () (step m ev)) list))))
              (unless (and (= (length got) 3) (eq? (car got) m) (eq? (cadr got) 'wait)
                           (null? (caddr got))
                           (eq? (info-before info) (info-after info))
                           (eq? (tr L (info-reply info)) 'wait) (null? (info-effects info)))
                (hfail "a spurious wakeup past the model's budget didn't answer wait and change nothing"
                       (list 'shell ev (tr L (info-reply info)) (tr L (info-effects info)))
                       (list 'machine got)))
              (compare-machine! L info)
              (pop! L tid)
              (stat! L 'spurious-past-budget)
              (hashtable-set! (life-last-kind L) tid 'held)))))

  ;; Whether the model has caller c's ticket marked posted.
  (define (model-marked? L c)
    (let* ((ghost (cdr (assq 'ghost (world->datum (W L)))))
           (flags (cdr (assq (ticket-of c) ghost))))
      (and (memq 'marked flags) #t)))

  (define (interpret-step L tid obs party class)
    (let* ((sparty (cadr obs)) (info (caddr obs)) (ev (info-event info)))
      (and
       (chain-ok? L info)
       (case (car party)
         ((maker)
          (unless (equal? sparty '(maker)) (hfail "the maker's step from another party" sparty))
          (case (car ev)
            ((fork) (maker-fork-move L tid obs class))
            ((look)
             (case (world-maker (W L))
               ((woken) (step-move L tid obs '(maker look) class 'held))
               ((waiting) (spurious-move L tid obs '(spurious maker) '(maker look)))
               (else (hfail "the maker looked where the model has it elsewhere"
                            (world-maker (W L))))))
            (else (hfail "the maker stepped an event of another party" ev))))
         ((thread)
          (let* ((t (cadr party)) (place (world-thread (W L) t)))
            (case (car ev)
              ((next)
               (unless (equal? sparty party) (hfail "a thread's step from another party" sparty party))
               (cond
                ((memq place '(to-next woken))
                 (step-move L tid obs (list 'thread t 'next) class 'held))
                ((eq? place 'waiting)
                 (spurious-move L tid obs (list 'spurious 'thread t) (list 'thread t 'next)))
                (else (hfail "a thread stepped next where the model has it elsewhere" t place
                             (tr L ev)))))
              ((set-up torn-down)
               (unless (equal? sparty party) (hfail "a thread's step from another party" sparty party))
               (let ((cmd (vref (life-last-cmd L) t)))
                 (step-move L tid obs
                            (list 'thread t (car ev) (if (eq? (car ev) 'set-up) (cadr cmd) cmd))
                            class 'section)))
              ((end)
               (unless (equal? sparty party) (hfail "a thread's step from another party" sparty party))
               (let ((cmd (vref (life-last-cmd L) t)) (c (vref (life-cmd-job L) t)))
                 (and (memq cmd '(value raise)) c
                      (let ((m (step-move L tid obs (list 'thread t 'end cmd) class 'section)))
                        (and m
                             (cons (car m)
                                   (lambda ()
                                     (hashtable-set! (life-results L) (caddr ev)
                                                     (list cmd (ticket-of c)))
                                     ((cdr m)))))))))
              ((left)
               (unless (equal? sparty party) (hfail "a thread's step from another party" sparty party))
               (step-move L tid obs (list 'thread t 'left) class 'section))
              ((stop)
               (unless (equal? sparty '(stopper)) (hfail "a self-stop from another party" sparty))
               (let ((m (step-move L tid obs (list 'thread t 'self-stop) class 'section)))
                 (and m (cons (car m)
                              (lambda () ((cdr m)) (vset! (life-self-stop-owed L) t #t))))))
              (else (hfail "a thread stepped an event the harness can't place" t (tr L ev))))))
         ((stopper)
          (unless (equal? sparty '(stopper)) (hfail "a stopper's step from another party" sparty))
          (let* ((s (cadr party)) (place (world-stopper (W L) s)))
            (if (eq? (car obs) 'section)
                (let ((m (step-move L tid obs (list 'stopper s 'start) class 'section)))
                  m)
                (case place
                  ((again) (step-move L tid obs (list 'stopper s 'again) class 'held))
                  ((woken) (step-move L tid obs (list 'stopper s 'look) class 'held))
                  ((waiting) (spurious-move L tid obs (list 'spurious 'stopper s)
                                            (list 'stopper s 'look)))
                  (else (hfail "a stopper stepped where the model has it elsewhere" s place))))))
         ((loop)
          (unless (and (pair? sparty) (eq? (car sparty) 'caller))
            (hfail "a step on the loop from a party that isn't a caller" sparty))
          (case (car ev)
            ((call)
             (let ((c (life-sending L)))
               (and c
                    (let ((m (step-move L tid obs (list 'caller c 'call) class 'section)))
                      (and m (cons (car m)
                                   (lambda ()
                                     (unless (eq? (cadr ev) (cadr sparty))
                                       (hfail "a call's ticket isn't its party's" ev sparty))
                                     (hashtable-set! (life-tickets L) (cadr ev) c)
                                     (life-sending-set! L #f)
                                     ((cdr m)))))))))
            ((abandon)
             (let ((c (hashtable-ref (life-tickets L) (cadr ev) #f)))
               (unless c (hfail "an abandon of a ticket no call made" ev))
               (let ((m (step-move L tid obs (list 'caller c 'deadline) class 'section)))
                 (and m (cons (car m)
                              (lambda ()
                                ((cdr m))
                                (stat! L (vref (life-abandon-how L) c))))))))
            (else (hfail "the loop stepped an event of another party" (tr L ev)))))
         (else #f)))))

  ;; The maker's fork and first look, two held steps, are one model event.
  (define (maker-fork-move L tid obs class)
    (let ((q (hashtable-ref (life-dq L) tid '())))
      (and (pair? (cdr q))
           (enabled? L '(maker fork))
           (cons class
                 (lambda ()
                   (let ((look (cadr q)))
                     (unless (and (eq? (car look) 'held) (equal? (car (info-event (caddr look))) 'look))
                       (hfail "the maker's fork isn't followed by its look" look))
                     (pop! L tid) (pop! L tid)
                     (let ((steps (model! L '(maker fork))))
                       (unless (= (length steps) 2)
                         (hfail "the model's fork took another count of steps" steps))
                       (compare-step! L (caddr obs) (car steps))
                       (unless (eq? (info-before (caddr look)) (info-after (caddr obs)))
                         (hfail "the maker's look isn't at the machine its fork made"))
                       (compare-step! L (caddr look) (cadr steps))
                       (compare-machine! L (caddr look))
                       (hashtable-set! (life-last-kind L) tid 'held))))))))

  (define (interpret-effect L tid obs class)
    (let* ((e (caddr obs)) (mp (model-party L tid (cadr obs))))
      (unless mp (hfail "an effect from a party the harness can't name" tid (cadr obs)))
      (let ((ev (list (car mp) (cadr mp) 'effect)))
        (and (enabled? L ev)
             (cons class
                   (lambda ()
                     (let* ((place (place-of L mp)) (pend (pending-effects place)))
                       (unless (and pend (equal? (car pend) (tr L e)))
                         (hfail "an effect carried out isn't the model's next" mp (tr L e) place))
                       (when (and (eq? (car mp) 'caller) (eq? (car e) 'signal))
                         (let ((tp (world-thread (W L) (cadr e))))
                           (unless (eq? tp 'waiting)
                             (stat! L 'lost-signals)
                             (when (or (eq? tp 'to-next)
                                       (and (pair? tp) (eq? (car tp) 'effects)
                                            (eq? (caddr tp) 'wait)))
                               (stat! L 'lost-wakeup-schedules)))))
                       (pop! L tid)
                       (model! L ev)
                       (when (and (life-double? L) (eq? (car e) 'post))
                         (let ((k (tr L (cadr e))))
                           (let ((p2 (pending-effects (place-of L mp))))
                             (unless (and p2 (equal? (car p2) (list 'mark k)))
                               (hfail "the model's double didn't mark after a post" p2)))
                           (model! L ev)
                           (let ((p3 (pending-effects (place-of L mp))))
                             (unless (and p3 (equal? (car p3) '(wake-waiters)))
                               (hfail "the model's double didn't wake after its mark" p3)))
                           (model! L ev)))
                       (hashtable-set! (life-last-effect L) tid e)
                       (hashtable-set! (life-last-kind L) tid 'effect))))))))

  (define (interpret-wait L tid obs party class)
    (let* ((sparty (cadr obs)) (mp (model-party L tid sparty)) (who (caddr obs)))
      (cons class
            (lambda ()
              (let ((place (place-of L mp)))
                (unless (eq? place (if (eq? (car mp) 'caller) 'dbl-waiting 'waiting))
                  (hfail "a party waits where the model has it elsewhere" mp place))
                (unless (equal? who (if (eq? (car mp) 'thread) mp 'done))
                  (hfail "a party waits on another condition than its own" mp who))
                (pop! L tid)
                (hashtable-set! (life-last-kind L) tid 'wait))))))

  (define (interpret-mark L tid obs class)
    (let* ((sparty (cadr obs)) (mp (model-party L tid sparty)) (info (caddr obs)))
      (unless (and mp (eq? (car mp) 'caller))
        (hfail "a mark note from a party that isn't a caller" sparty))
      (let* ((c (cadr mp)) (place (world-caller (W L) c)) (ev (list 'caller c 'check)))
        (define (check!)
          (unless (eq? (car info) (cadr sparty)) (hfail "a mark note for another ticket" info))
          (pop! L tid)
          (model! L ev)
          (let ((marked (eq? (world-caller (W L) c) 'parked)))
            (unless (eq? (and (cadr info) #t) marked)
              (hfail "the double's mark differs from the model's" (cadr info) marked)))
          (hashtable-set! (life-last-kind L) tid 'mark))
        (case place
          ((dbl-check dbl-woken) (and (enabled? L ev) (cons class check!)))
          ((dbl-waiting)
           (let ((sp (list 'spurious 'caller c)))
             (if (enabled? L sp)
                 (cons 'spurious (lambda () (stat! L 'spurious) (model! L sp) (check!)))
                 ;; Past the model's budget: a woken check of an unmarked
                 ;; ticket finds it unmarked and waits again.
                 (cons 'spurious
                       (lambda ()
                         (unless (eq? (car info) (cadr sparty))
                           (hfail "a mark note for another ticket" info))
                         (when (or (cadr info) (model-marked? L c))
                           (hfail "a spurious wakeup past the model's budget found the mark"
                                  c (cadr info)))
                         (pop! L tid)
                         (stat! L 'spurious-past-budget)
                         (hashtable-set! (life-last-kind L) tid 'mark))))))
          (else (hfail "a mark check where the model has the caller elsewhere" c place))))))

  (define (interpret-gate L tid obs party class)
    (let ((kind (cadr obs)) (c (caddr obs)) (state (cadddr obs)))
      (case kind
        ((setup)
         (and
          (exists (lambda (t) (and (eq? (world-thread (W L) t) 'setting-up) (not (thread-tid L t))))
                  (iota* (life-n L)))
          (cons class
               (lambda ()
                 (pop! L tid)
                 (when party (hfail "a second set-up on one thread" tid))
                 (life-setup-pending-set! L (cons tid (life-setup-pending L)))
                 (let ((unmapped (let loop ((t 1) (acc '()))
                                   (if (> t (life-n L))
                                       (reverse acc)
                                       (loop (+ t 1)
                                             (if (and (eq? (world-thread (W L) t) 'setting-up)
                                                      (not (thread-tid L t)))
                                                 (cons t acc)
                                                 acc))))))
                   (when (= (length unmapped) (length (life-setup-pending L)))
                     ;; Thread ids rise in fork order, and the maker forks
                     ;; thread 1 first: each thread's first section checks it.
                     (for-each (lambda (t tid)
                                 (vset! (life-thread-tid L) t tid)
                                 (hashtable-set! (life-tid-party L) tid (list 'thread t))
                                 (vset! (life-gate-at L) t 'setup)
                                 (hashtable-set! (life-last-kind L) tid 'gate))
                               unmapped
                               (list-sort < (life-setup-pending L)))
                     (life-setup-pending-set! L '())))))))
        ((job teardown)
         (unless (and party (eq? (car party) 'thread))
           (hfail "a gate reached on a thread that isn't a worker's" tid obs))
         (let* ((t (cadr party)) (place (world-thread (W L) t)))
           (cons class
                 (lambda ()
                   (unless (and (wstate? state) (= (wstate-t state) t) (eqv? (wstate-tid state) tid))
                     (hfail "a thread was handed a state another thread made" t
                            (and (wstate? state) (list (wstate-t state) (wstate-tid state)))))
                   (if (eq? kind 'job)
                       (begin
                         (unless (equal? place (list 'running (ticket-of c)))
                           (hfail "a thread entered a job the model doesn't run there"
                                  t (ticket-of c) place))
                         (unless (vref (life-ran-on L) c)
                           (vset! (life-ran-on L) c t)
                           (life-real-begun-set! L (cons (list (ticket-of c) t) (life-real-begun L))))
                         (vset! (life-job-on L) t c))
                       (begin
                         (unless (and (eq? place 'tearing-down) (= c t))
                           (hfail "a thread began its tear-down where the model has it elsewhere"
                                  t place))
                         (life-real-torn-set! L (cons t (life-real-torn L)))))
                   (vset! (life-gate-at L) t kind)
                   (pop! L tid)
                   (hashtable-set! (life-last-kind L) tid 'gate)))))
        (else (hfail "a gate of no known kind" obs)))))

  (define (interpret-done L tid obs class)
    (let ((r (cadddr* obs)))
      (if (eq? (cadr obs) 'maker)
          (let ((place (world-maker (W L))))
            (cond
             ((eq? place 'ready)
              (cons class
                    (lambda ()
                      (unless (eq? (car r) 'ready) (hfail "the model's maker is ready; the real one raised" r))
                      (pop! L tid)
                      (life-done-seen-set! L (cons '(maker) (life-done-seen L))))))
             ((and (pair? place) (eq? (car place) 'joining))
              (and (enabled? L '(maker join))
                   (cons class
                         (lambda ()
                           (pop! L tid)
                           (model! L '(maker join))
                           (check-raised! "make-worker" 'make-worker (cadr place) r)
                           (life-done-seen-set! L (cons '(maker) (life-done-seen L)))))))
             (else #f)))
          (let* ((s (caddr obs)) (place (world-stopper (W L) s)) (ev (list 'stopper s 'join)))
            (and (pair? place) (eq? (car place) 'joining) (enabled? L ev)
                 (cons class
                       (lambda ()
                         (pop! L tid)
                         (model! L ev)
                         (if (cadr place)
                             (check-raised! "worker-stop!" 'worker-stop! (cadr place) r)
                             (unless (eq? r 'returned)
                               (hfail "worker-stop! raised where the model's returned" r)))
                         (life-done-seen-set! L (cons (list 'stopper s) (life-done-seen L))))))))))

  (define (iota* n) (let loop ((i n) (acc '())) (if (= i 0) acc (loop (- i 1) (cons i acc)))))

  (define (cadddr* obs) (if (eq? (cadr obs) 'maker) (caddr obs) (cadddr obs)))

  ;; What a maker or a stopper raised, against the model's kept raise.
  (define (check-raised! what who o r)
    (unless (and (pair? r) (eq? (car r) 'raised))
      (hfail (string-append what " returned where the model's raised") o r))
    (let ((e (cadr r)))
      (if (eq? o 'left)
          (unless (and (error? e) (who-condition? e) (eq? (condition-who e) who))
            (hfail (string-append what " raised another thing than the &error for a left thread") e))
          (unless (equal? e (cadr o))
            (hfail (string-append what " raised another raise than the model's") e o)))))

  (define (interpret-outcome L tid obs class)
    (let* ((c (cadr obs)) (x (caddr obs)) (place (world-caller (W L) c)))
      (define (finish!)
        (vset! (life-outcomes L) c x)
        (pop! L tid)
        (hashtable-set! (life-last-kind L) tid 'outcome))
      (cond
       ((and (pair? place) (eq? (car place) 'done))
        (cons class (lambda () (check-outcome! L c (cadr place) x) (finish!))))
       ((and (eq? place 'parked) (eq? (car x) 'raised)
             (or (deadline-passed? (cadr x)) (client-closed? (cadr x))))
        (hfail "a wait ended by a deadline or a close, with no abandon step" c
               (describe* (cadr x))))
       ((eq? place 'parked)
        (let ((inbox (world-inbox (W L))))
          (and (pair? inbox) (enabled? L '(loop deliver))
               (cons class
                     (lambda ()
                       (unless (eq? (car (car inbox)) (ticket-of c))
                         (hfail "a handler answered out of the inbox's order" c
                                (map car inbox)))
                       (model! L '(loop deliver))
                       (let ((p (world-caller (W L) c)))
                         (unless (and (pair? p) (eq? (car p) 'done))
                           (hfail "the model didn't deliver to the caller answered" c p))
                         (check-outcome! L c (cadr p) x))
                       (stat! L 'delivered)
                       (finish!))))))
       (else #f))))

  ;; A handler's outcome against the model's.
  (define (check-outcome! L c o x)
    (define (raised pred) (and (eq? (car x) 'raised) (pred (cadr x))))
    (define (from-call? e) (and (who-condition? e) (eq? (condition-who e) 'worker-call)))
    (unless
        (cond
         ((equal? o '(refused full)) (raised (lambda (e) (and (worker-full? e) (from-call? e)))))
         ((member o '((refused stopped) (answer stopped)))
          (raised (lambda (e) (and (worker-stopped? e) (not (worker-full? e)) (from-call? e)))))
         ((eq? o 'abandoned)
          (raised (if (eq? (vref (life-abandon-how L) c) 'deadline) deadline-passed? client-closed?)))
         ((equal? o '(answer left)) (raised (lambda (e) (call-error? e left-message))))
         ((and (pair? o) (eq? (car o) 'answer) (pair? (cadr o)))
          (let ((r (cadr o)))
            (case (car r)
              ((value) (equal? x (list 'values (cadr r) (vref (life-ran-on L) c))))
              ((raise) (raised (lambda (e) (eq? e (vref (life-raise-objs L) c)))))
              (else #f))))
         (else #f))
      (hfail "a handler's outcome differs from the model's" c o
             (if (eq? (car x) 'raised) (list 'raised (describe* (cadr x))) x))))

  (define (describe* e)
    (if (condition? e)
        (list (and (who-condition? e) (condition-who e))
              (and (message-condition? e) (condition-message e)))
        e))

  (define (interpret-host-done L tid obs class)
    (let ((tag (cadr obs)) (r (caddr obs)))
      (define (finish!)
        (unless (eq? r 'ok)
          (hfail "a host command raised" tag (describe* (cadr r))))
        (pop! L tid)
        (life-loop-busy?-set! L #f)
        (hashtable-set! (life-last-kind L) tid 'host-done))
      (if (eq? tag 'stop-posts)
          (and (enabled? L '(server stop))
               (cons class (lambda () (model! L '(server stop)) (stat! L 'server-stops) (finish!))))
          (and (not (world-loop (W L)))
               (cons class finish!)))))

  ;; -------------------------------------------------------------------
  ;; Consuming and settling

  (define (drain! L)
    (mutex-acquire (life-hm L))
    (let ((got (life-inbox L)))
      (life-inbox-set! L '())
      (mutex-release (life-hm L))
      (for-each (lambda (p)
                  (hashtable-update! (life-dq L) (car p)
                                     (lambda (q) (append q (list (cdr p)))) '()))
                (reverse got))))

  (define (heads L)
    (let-values (((tids qs) (hashtable-entries (life-dq L))))
      (let loop ((i 0) (acc '()))
        (if (= i (vector-length tids))
            (list-sort (lambda (a b) (< (car a) (car b))) acc)
            (loop (+ i 1)
                  (let ((q (vector-ref qs i)))
                    (if (pair? q) (cons (cons (vector-ref tids i) (car q)) acc) acc)))))))

  (define (changing-step? obs)
    (and (memq (car obs) '(section held))
         (not (eq? (info-before (caddr obs)) (info-after (caddr obs))))))

  ;; consume-one! : Life -> Boolean
  (define (consume-one! L)
    (let* ((hs (heads L))
           (moves (map (lambda (h) (list (car h) (cdr h) (interpret L (car h) (cdr h)))) hs))
           (ready (filter caddr moves))
           (trig (find (lambda (m) (eqv? (car m) (life-trigger L))) ready))
           (spur (find (lambda (m) (eq? (car (caddr m)) 'spurious)) ready))
           (run (lambda (m) ((cdr (caddr m))) #t)))
      (cond
       ;; Before the released party's changing step, everything else ready
       ;; that doesn't change the machine: a spurious wakeup's no-op steps
       ;; at the same machine, and the notes between them. Nothing else can
       ;; have been woken before that step's own effects.
       ((and trig (changing-step? (cadr trig))
             (find (lambda (m) (and (not (eq? m trig)) (not (changing-step? (cadr m))))) ready))
        => run)
       ((and trig (not (eq? (car (caddr trig)) 'spurious))) (run trig))
       ((find (lambda (m) (not (eq? (car (caddr m)) 'spurious))) ready) => run)
       (spur (run spur))
       (else #f))))

  (define (shared-ref L table tid)
    (mutex-acquire (life-hm L))
    (let ((v (hashtable-ref table tid #f)))
      (mutex-release (life-hm L))
      v))

  (define (at-gate? L tid)
    (mutex-acquire (life-hm L))
    (let ((g (hashtable-ref (life-gates L) tid #f)))
      (mutex-release (life-hm L))
      (and g (not (vector-ref g 3)))))

  (define (live-model L)
    (let loop ((t 1) (n 0))
      (if (> t (life-n L))
          n
          (loop (+ t 1)
                (if (memq (world-thread (W L) t) '(returned joined not-forked)) n (+ n 1))))))

  ;; settled? : Life -> (U 'yes 'no 'live)
  (define (settled? L)
    (let ((w (W L)))
      (define (thread-ok? t)
        (let ((p (world-thread w t)) (tid (thread-tid L t)))
          (cond
           ((memq p '(not-forked returned joined)) #t)
           ((eq? p 'woken) #f)
           ((not tid) #f)
           ((eq? p 'setting-up) (and (eq? (vref (life-gate-at L) t) 'setup) (at-gate? L tid)))
           ((eq? p 'tearing-down) (and (eq? (vref (life-gate-at L) t) 'teardown) (at-gate? L tid)))
           ((and (pair? p) (eq? (car p) 'running))
            (and (eq? (vref (life-gate-at L) t) 'job) (at-gate? L tid)))
           ((eq? p 'waiting) (eq? (hashtable-ref (life-last-kind L) tid #f) 'wait))
           (else (shared-ref L (life-held L) tid)))))
      (define (stopper-ok? s)
        (let ((p (world-stopper w s)) (tid (stopper-tid L s)))
          (cond
           ((eq? p 'idle) #t)
           ((not tid) #f)
           ((eq? p 'waiting) (eq? (hashtable-ref (life-last-kind L) tid #f) 'wait))
           ((memq p '(woken)) #f)
           ((pair? p)
            (case (car p)
              ((effects) (shared-ref L (life-held L) tid))
              ((done) (and (member (list 'stopper s) (life-done-seen L)) #t))
              ;; Its join waits for threads the model has live.
              ((joining) (not (enabled? L (list 'stopper s 'join))))
              (else #f)))
           ((eq? p 'again) (shared-ref L (life-held L) tid))
           (else #f))))
      (define (maker-ok?)
        (let ((p (world-maker w)) (tid (life-maker-tid L)))
          (cond
           ((eq? p 'start) #t)
           ((not tid) #f)
           ((eq? p 'waiting) (eq? (hashtable-ref (life-last-kind L) tid #f) 'wait))
           ((or (eq? p 'ready) (and (pair? p) (eq? (car p) 'raised)))
            (and (member '(maker) (life-done-seen L)) #t))
           ((and (pair? p) (eq? (car p) 'joining)) (not (enabled? L '(maker join))))
           (else #f))))
      (define (callers-ok?)
        (let loop ((c 1))
          (or (> c (life-callers L))
              (let ((p (world-caller w c)))
                (and (cond
                      ((memq p '(idle parked)) #t)
                      ((eq? p 'dbl-waiting)
                       (eq? (hashtable-ref (life-last-kind L) loop-tid #f) 'wait))
                      ((and (pair? p) (eq? (car p) 'done)) (and (vref (life-outcomes L) c) #t))
                      (else #f))
                     (loop (+ c 1)))))))
      (cond
       ((pair? (heads L)) 'no)
       ((not (and (let loop ((t 1)) (or (> t (life-n L)) (and (thread-ok? t) (loop (+ t 1)))))
                  (let loop ((s 1)) (or (> s (life-stoppers L)) (and (stopper-ok? s) (loop (+ s 1)))))
                  (maker-ok?)
                  (callers-ok?)
                  (if (world-loop w)
                      (eq? (hashtable-ref (life-last-kind L) loop-tid #f) 'wait)
                      (not (life-loop-busy? L)))))
        'no)
       ((and (life-worker L) (not (= (live-count! L) (live-model L)))) 'live)
       (else
        (mutex-acquire (life-hm L))
        (let ((quiet (null? (life-inbox L))))
          (mutex-release (life-hm L))
          (if quiet 'yes 'no))))))

  ;; The parties not at the place the model names, each with the last
  ;; kind of observation consumed from its thread.
  (define (unsettled L)
    (let ((w (W L)) (lk (lambda (tid) (and tid (hashtable-ref (life-last-kind L) tid #f)))))
      (append
       (let loop ((t 1) (acc '()))
         (if (> t (life-n L))
             (reverse acc)
             (loop (+ t 1)
                   (let ((tid (thread-tid L t)))
                     (cons (list (list 'thread t) (world-thread w t) (lk tid)
                                 (and tid (shared-ref L (life-held L) tid) 'held)
                                 (and tid (at-gate? L tid) 'at-gate))
                           acc)))))
       (list (list '(maker) (world-maker w) (lk (life-maker-tid L))))
       (let loop ((s 1) (acc '()))
         (if (> s (life-stoppers L))
             (reverse acc)
             (loop (+ s 1)
                   (let ((tid (stopper-tid L s)))
                     (cons (list (list 'stopper s) (world-stopper w s) (lk tid)
                                 (and tid (shared-ref L (life-held L) tid) 'held))
                           acc)))))
       (list (list '(loop) (world-loop w) (lk loop-tid) (life-loop-busy? L))))))

  (define settle-ms 2000)

  (define (await-news! L ms)
    (mutex-acquire (life-hm L))
    (when (null? (life-inbox L))
      (condition-wait (life-hc L) (life-hm L)
                      (make-time 'time-duration (* 1000000 (max 1 (min ms 50))) 0)))
    (mutex-release (life-hm L)))

  ;; settle! : Life (U Event #f) -> Void
  ;; Replays until the drawn event ev has happened and every party is at
  ;; the place the model names.
  (define (settle! L ev)
    (let loop ((limit (+ (real-time) settle-ms)))
      (drain! L)
      (if (consume-one! L)
          (loop (+ (real-time) settle-ms))
          (let ((s (if (and ev (not (member ev (life-steps-now L)))) 'no (settled? L))))
            (cond
             ((eq? s 'yes) #t)
             ((> (real-time) limit)
              (hfail (if (eq? s 'live)
                         "the worker's live count never came to the model's"
                         "no progress: the real worker never reached the model's places")
                     (list 'live (and (life-worker L) (or (live-count (life-worker L)) 'unread))
                           'model (live-model L))
                     (cons 'unsettled (unsettled L))))
             ((eq? s 'live) (await-news! L 1) (loop limit))
             (else (await-news! L 50) (loop limit)))))))

  ;; -------------------------------------------------------------------
  ;; Drawing and triggering

  (define (inbox-holds? L c)
    (and (assq (ticket-of c) (world-inbox (W L))) #t))

  (define (drawable? L ev)
    (let ((w (W L)))
      (case (car ev)
        ((spurious) #f)
        ((maker) (equal? ev '(maker fork)))
        ((thread)
         (if (eq? (caddr ev) 'next)
             (eq? (world-thread w (cadr ev)) 'to-next)
             #t))
        ((caller)
         (case (caddr ev)
           ((call) (world-server-open? w))
           ((deadline) (not (inbox-holds? L (cadr ev))))
           (else #f)))
        ((loop server) #t)
        ((stopper) (memq (caddr ev) '(start effect again)))
        (else #f))))

  ;; Enabled but never drawn, at a settled world: only calls after the
  ;; server's stop, and spurious wakeups.
  (define (undrawable-ok? L ev)
    (or (eq? (car ev) 'spurious)
        (and (eq? (car ev) 'caller) (eq? (caddr ev) 'call) (not (world-server-open? (W L))))))

  (define (choose L evs)
    (let* ((weights (map (life-weights L) evs))
           (total (fold-left + 0 weights))
           (r (prng-below! (life-prng L) total)))
      (let loop ((evs evs) (ws weights) (r r))
        (if (< r (car ws)) (car evs) (loop (cdr evs) (cdr ws) (- r (car ws)))))))

  (define (release! L tid)
    (mutex-acquire (life-hm L))
    (unless (hashtable-ref (life-held L) tid #f)
      (mutex-release (life-hm L))
      (hfail "no party is held on that thread" tid))
    (hashtable-delete! (life-held L) tid)
    (hashtable-set! (life-release L) tid #t)
    (condition-broadcast (life-hc L))
    (mutex-release (life-hm L)))

  (define (gate-command! L t cmd)
    (let ((tid (thread-tid L t)))
      (vset! (life-last-cmd L) t cmd)
      (vset! (life-cmd-job L) t (vref (life-job-on L) t))
      (vset! (life-gate-at L) t #f)
      (mutex-acquire (life-hm L))
      (let ((g (hashtable-ref (life-gates L) tid #f)))
        (unless (and g (not (vector-ref g 3)))
          (mutex-release (life-hm L))
          (hfail "no gate waits on thread" t))
        (vector-set! g 3 cmd)
        (condition-broadcast (life-hc L))
        (mutex-release (life-hm L)))))

  (define (lowest-parked L)
    (let loop ((c 1))
      (cond ((> c (life-callers L)) #f)
            ((eq? (world-caller (W L) c) 'parked) c)
            (else (loop (+ c 1))))))

  (define (trigger! L ev)
    (case (car ev)
      ((maker) (life-trigger-set! L 'pending) (fork-maker! L))
      ((thread)
       (let* ((t (cadr ev)) (tid (thread-tid L t)) (what (caddr ev)))
         (life-trigger-set! L tid)
         (case what
           ((set-up) (gate-command! L t (list t (cadddr ev))))
           ((effect next) (release! L tid))
           ((end torn-down) (gate-command! L t (cadddr ev)))
           ((left self-stop) (gate-command! L t what))
           (else (hfail "no action for a thread event" ev)))))
      ((caller)
       (let ((c (cadr ev)) (host (life-host L)))
         (life-trigger-set! L loop-tid)
         (case (caddr ev)
           ((call)
            (life-sending-set! L c)
            (host! L 'call (lambda () (send-call! L c))))
           ((deadline)
            (if (eqv? c (lowest-parked L))
                (begin
                  (vset! (life-abandon-how L) c 'deadline)
                  (host! L 'deadline
                         (lambda ()
                           (test-host-advance! host (- (vref (life-instants L) c)
                                                       (test-host-now host))))))
                (begin
                  (vset! (life-abandon-how L) c 'closed)
                  (host! L 'close (lambda () (test-client-close! (client L c)))))))
           (else (hfail "no action for a caller event" ev)))))
      ((loop)
       (life-trigger-set! L loop-tid)
       (host! L 'deliver (lambda () (test-host-advance! (life-host L) 0))))
      ((server)
       (life-trigger-set! L loop-tid)
       (host! L 'stop-posts (lambda () (test-host-stop-posts! (life-host L)))))
      ((stopper)
       (let ((s (cadr ev)))
         (if (eq? (caddr ev) 'start)
             (begin (life-trigger-set! L 'pending) (fork-stopper! L s))
             (let ((tid (stopper-tid L s)))
               (life-trigger-set! L tid)
               (release! L tid)))))
      (else (hfail "no action for an event" ev))))

  ;; -------------------------------------------------------------------
  ;; A life

  ;; run-life : Config Prng (Event -> Positive-Fixnum) Hashtable -> Lived
  ;; One worker's life under a drawn schedule. Stats gains counts: each
  ;; row fired, as (row R), and lost-signals, lost-wakeup-schedules,
  ;; deadline, closed, delivered, server-stops, self-stops, spurious.
  (define (run-life config prng weights stats)
    (let ((L (make-life config prng weights stats)))
      (guard (x ((harness-failure? x)
                 (make-lived config (life-drawn L) (life-applied L) (failure-report L x)))
                (#t (make-lived config (life-drawn L) (life-applied L)
                                (failure-report L (make-harness-failure
                                                   "the harness raised"
                                                   (list (describe* x)))))))
        (life-trigger-set! L loop-tid)
        (host! L 'new-host (lambda () (new-host! L)))
        (settle! L #f)
        (let loop ()
          (let* ((evs (world-enabled (W L)))
                 (ds (filter (lambda (ev) (drawable? L ev)) evs)))
            (if (null? ds)
                (unless (for-all (lambda (ev) (undrawable-ok? L ev)) evs)
                  (hfail "nothing is drawable, but the model has enabled"
                         (filter (lambda (ev) (not (undrawable-ok? L ev))) evs)))
                (let ((ev (choose L ds)))
                  (life-steps-now-set! L '())
                  (life-trace-set! L (cons (list ev) (life-trace L)))
                  (life-drawn-set! L (+ 1 (life-drawn L)))
                  (trigger! L ev)
                  (settle! L ev)
                  (let ((applied (reverse (life-steps-now L))))
                    (set-car! (life-trace L) (cons ev applied))
                    (unless (member ev applied)
                      (hfail "the event drawn never happened" ev applied)))
                  (loop)))))
        (when (null? (filter (lambda (ev) (not (eq? (car ev) 'spurious))) (world-enabled (W L))))
          (guard (x ((model-failure? x)
                     (hfail "the model's terminal check failed" (model-failure-property x)
                            (model-failure-message x) (model-failure-irritants x))))
            (world-terminal-check (W L))))
        (life-trigger-set! L loop-tid)
        (host! L 'final (lambda () (read-final! L)))
        (settle! L #f)
        (end-checks! L)
        (for-each thread-join (life-forked L))
        (make-lived config (life-drawn L) (life-applied L) #f))))

  (define (end-checks! L)
    (let ((log (car (life-final L))) (responses (cadr (life-final L))))
      (unless (null? log) (hfail "the host logged" log))
      ;; each caller's response
      (let loop ((c 1) (rs responses))
        (when (<= c (life-callers L))
          (let ((p (world-caller (W L) c)) (got (car rs)))
            (let ((want (cond
                         ((and (pair? p) (eq? (car p) 'done))
                          (let ((o (cadr p)))
                            (cond
                             ((and (eq? o 'abandoned) (eq? (vref (life-abandon-how L) c) 'closed))
                              'any)
                             (else (list (list 200 (expected-text L c o) #t))))))
                         (else '()))))
              (unless (or (eq? want 'any) (equal? got want))
                (hfail "a caller's response differs from the model's outcome" c p got want))))
          (loop (+ c 1) (cdr rs))))
      ;; each job begun, on which thread and in what order
      (let ((model (reverse (life-model-begun L))) (real (reverse (life-real-begun L))))
        (define (on t l) (filter (lambda (b) (= (cadr b) t)) l))
        (define (key b) (symbol->string (car b)))
        (unless (equal? (list-sort (lambda (a b) (string<? (key a) (key b))) model)
                        (list-sort (lambda (a b) (string<? (key a) (key b))) real))
          (hfail "the jobs begun differ from the model's" (list 'shell real) (list 'model model)))
        (let loop ((t 1))
          (when (<= t (life-n L))
            (unless (equal? (on t model) (on t real))
              (hfail "the jobs begun on a thread, in order, differ from the model's" t
                     (list 'shell (on t real)) (list 'model (on t model))))
            (loop (+ t 1))))
        (when (= (life-n L) 1)
          (unless (equal? model real)
            (hfail "with one thread, the jobs begun in order differ from the model's"
                   (list 'shell real) (list 'model model)))))
      ;; each tear-down
      (unless (equal? (list-sort < (life-real-torn L)) (list-sort < (life-model-torn L)))
        (hfail "the tear-downs differ from the model's"
               (list 'shell (life-real-torn L)) (list 'model (life-model-torn L))))
      ;; the live count
      (when (life-worker L)
        (let ((n (live-count! L)))
          (unless (= 0 n) (hfail "the worker's live count isn't 0 at the end" n))))
      (unless (null? (heads L)) (hfail "observations left unconsumed" (heads L)))))

  (define (expected-text L c o)
    (cond
     ((equal? o '(refused full)) "full")
     ((member o '((refused stopped) (answer stopped))) "stopped")
     ((eq? o 'abandoned) (symbol->string (vref (life-abandon-how L) c)))
     ((equal? o '(answer left)) "left")
     ((and (pair? o) (eq? (car o) 'answer) (pair? (cadr o)))
      (case (car (cadr o))
        ((value) (call-with-string-output-port
                  (lambda (p) (write (list (ticket-of c) (vref (life-ran-on L) c)) p))))
        (else "raise")))
     (else "?")))

  ;; -------------------------------------------------------------------
  ;; Reports

  (define (failure-report L x)
    (list (list 'message (harness-failure-message x))
          (list 'irritants (harness-failure-irritants x))
          (list 'config (config->datum (life-config L)))
          (list 'drawn (life-drawn L))
          (list 'trace (reverse (life-trace L)))
          (list 'world (guard (e (#t 'unprintable)) (world->datum (W L))))
          (list 'pending
                (guard (e (#t 'unprintable))
                  (drain! L)
                  (map (lambda (h)
                         (list (car h) (party-of L (car h))
                               (map (lambda (o) (tr L (obs-brief o)))
                                    (hashtable-ref (life-dq L) (car h) '()))))
                       (heads L))))))

  (define (obs-brief o)
    (case (car o)
      ((section held)
       (let ((i (caddr o)))
         (list (car o) (cadr o) (info-event i) (info-reply i) (info-effects i))))
      ((gate) (list 'gate (cadr o) (caddr o)))
      (else o)))

  ;; print-failure : Sexp Port -> Void
  (define (print-failure f port)
    (for-each
     (lambda (entry)
       (case (car entry)
         ((trace)
          (put-string port "trace, each drawn event and the model events it took:")
          (newline port)
          (let loop ((evs (cadr entry)) (i 1))
            (unless (null? evs)
              (put-string port "  ")
              (put-string port (number->string i))
              (put-string port ". ")
              (write (car (car evs)) port)
              (unless (or (null? (cdr (car evs))) (equal? (cdr (car evs)) (list (car (car evs)))))
                (put-string port "  -> ")
                (write (cdr (car evs)) port))
              (newline port)
              (loop (cdr evs) (+ i 1)))))
         ((world pending irritants)
          (put-string port (symbol->string (car entry)))
          (put-string port ":")
          (newline port)
          (let ((v (cadr entry)))
            (for-each (lambda (x) (put-string port "  ") (write x port) (newline port))
                      (if (list? v) v (list v)))))
         (else
          (put-string port (symbol->string (car entry)))
          (put-string port ": ")
          (if (string? (cadr entry)) (put-string port (cadr entry)) (write (cadr entry) port))
          (newline port))))
     f)))
