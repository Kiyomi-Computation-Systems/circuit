#!r6rs
;;; (circuit worker shell): the worker's threads, its lock, and the
;;; protocol that carries out what the machine's `step` decides.
;;;
;;; A worker is one mutex, `m`, one condition per thread, and one `done`
;;; condition, which the maker, the stoppers and the double's callers wait
;;; on. The machine (circuit worker machine) holds every decision. The
;;; shell reads it, steps it and writes it back under `m`, then does what
;;; the step said: the reply is for the party that stepped, and the effects
;;; are for everyone else.
;;;
;;; A SECTION takes `m`, disables interrupts, steps, releases `m`, and only
;;; then enables interrupts again, so an interrupt deferred inside it, such
;;; as a collect request, runs once `m` is free. A HELD STEP is the same
;;; step under an `m` its party already holds, as it leads into a
;;; `condition-wait`: interrupts are enabled again with `m` still held,
;;; since the wait needs it. The held steps are the maker's fork and look,
;;; a thread's next in its wait loop, and a stopper's second stop; the
;;; double's check of its mark is held too. A party told to wait by a held
;;; step waits without letting go of `m` between, and a thread told to
;;; wait by any other step steps next before it waits, since a call may
;;; have given it a job meanwhile. So no signal is lost.
;;;
;;; EFFECTS are carried out after `m` is released, in the order the step
;;; gave them: a post calls the ticket's `resume`, a signal wakes one
;;; thread, and a wake broadcasts `done`. A party keeps them from its step
;;; until each is done: interrupts come back on under the handler that
;;; carries them out, so a raise anywhere between the step and its last
;;; effect breaks the worker with the rest still to carry out. A thread
;;; keeps them in its frame too, so one that leaves by `exit` mid-way, past
;;; that handler, carries them out from its after-thunk. `m` is never
;;; held around a job, a set-up, a tear-down, a `resume`, an observer's
;;; blocking point or a wait on the server.
;;;
;;; A THREAD runs its set-up, a section, then its replies: a job, a
;;; tear-down, a wait for its next step, or its end. Each set-up, job and
;;; tear-down runs under a catch of two nested exception handlers, which
;;; escapes by a continuation for anything but a continuable warning. That
;;; it passes on, so the thread's default handler prints it and the job goes
;;; on. A job's values are taken inside the catch. The whole body runs
;;; inside one `dynamic-wind`, whose after-thunk acts on where the thread
;;; was when it left: nothing if it returned; for a job that left by a
;;; non-local exit such as `exit`, the step that says so, then a tear-down
;;; in a `dynamic-wind` of its own, so a tear-down that leaves too is
;;; stepped; for a set-up or a tear-down that left, the step that says so;
;;; and for the protocol, the broken path below, with the effects the
;;; thread still had to carry out. Each step the after-thunk takes has a
;;; `dynamic-wind` of its own, so a thread that leaves again while it
;;; carries out that step's effects takes the broken path with those still
;;; to do. An outermost `dynamic-wind`
;;; counts the thread out of the live count, however it ends.
;;;
;;; A CALL is `worker-call`'s `register`, on the loop's thread: a section,
;;; its effects, then a return, or the refusal raised. It never waits on the
;;; server. `worker-call` sees a deadline or a client's close through a
;;; pass-through exception handler around `await-outside`: for an accepted
;;; ticket it steps the abandon, then passes the same object on with
;;; `raise-continuable`. A job's own raise is raised after `await-outside`
;;; returns, outside that handler.
;;;
;;; A STOP steps once and carries out its effects, then, unless refused,
;;; steps again under `m`, waiting on `done` while told to wait, and joins
;;; every thread once told the worker has stopped.
;;;
;;; THE DOUBLE is a worker of one thread and no queue whose `register` waits
;;; on `done`, after its call's effects, until its ticket is marked posted.
;;; Whoever carries out a post marks the ticket, so a stop's post or a
;;; broken worker's ends the wait as the thread's does. Its job runs on its
;;; own thread, so a wait inside a job is refused as off the loop's thread.
;;;
;;; THE BROKEN WORKER. A raise inside a section or a held step is a bug in
;;; the machine, the shell or the observer, or a call from an interrupt
;;; handler, which the docs forbid. The section's own exception handler, the
;;; innermost, marks the worker broken, releases `m`, restores the
;;; interrupt count and passes the raise on with `raise`, so no outer
;;; handler runs under `m` and none can return into the section. Then,
;;; outside `m`, the first party to break it posts the broken worker's
;;; `&error` to every ticket the machine holds; each breaking party carries
;;; out its own effects still pending, their posts made that `&error`, and
;;; signals every thread and broadcasts `done`. Once broken, no section or
;;; held step steps (the double's mark and its check go on): each thread
;;; tears down and ends, a running job's end posts nothing, a later call
;;; raises the `&error`, an abandon passes its raise on unchanged, a maker
;;; joins every thread and raises the `&error`, and `worker-stop!` joins
;;; every thread and returns, or, on a worker's own thread, is refused. A
;;; raise from the maker's own steps leaves `make-worker` once every forked
;;; thread is joined.
;;;
;;; THE OBSERVER, for the suites alone, is told of BLOCKING POINTS, called
;;; with `m` free and interrupts enabled: `section` after a section that
;;; stepped, and `effect` and `effected` around each effect. Before each,
;;; the shell checks its thread doesn't hold `m`, by an owner field it sets
;;; after every acquire and every return from `condition-wait`, and clears
;;; before every release and every `condition-wait`. NOTES are called with
;;; `m` held, and must neither block nor take it: `held` for a held step,
;;; `mark` for the double's check of its ticket, and `wait` before each
;;; `condition-wait`. With no observer, nothing is built and nothing called.
;;;
;;; One thread parameter, shared by every worker, holds on each worker
;;; thread that thread's own id: a thread a job forks inherits the value
;;; but not the id, so "on a worker's own thread" is a comparison of ids.
(library (circuit worker shell)
  (export make-worker worker-call worker-stop! worker? make-test-worker
          &worker-full worker-full? &worker-stopped worker-stopped?
          make-shell-worker worker-live-count worker-lock-free?)
  (import (rnrs)
          (circuit worker machine)
          (only (http-server) await-outside deadline-passed? client-closed?)
          (only (chezscheme) fork-thread thread-join make-mutex mutex-acquire mutex-release
                make-condition condition-wait condition-signal condition-broadcast
                disable-interrupts enable-interrupts make-thread-parameter get-thread-id))

  ;; State = Any, a set-up's value
  ;; Observer = Symbol Party Fixnum Any -> Any
  ;; Party = (maker) | (thread Positive-Fixnum) | (stopper) | (caller Ticket)

  ;; &worker-full : ConditionType
  ;; worker-full? : Any -> Boolean
  ;; A call refused because no thread is idle and the queue holds its cap.
  (define-condition-type &worker-full &error make-worker-full worker-full?)

  ;; &worker-stopped : ConditionType
  ;; worker-stopped? : Any -> Boolean
  ;; A call refused, or a job told, once a stop has begun.
  (define-condition-type &worker-stopped &error make-worker-stopped worker-stopped?)

  ;; worker? : Any -> Boolean
  ;; The lock, the conditions and the machine; the broken worker's &error,
  ;; or #f; the thread holding the lock, as an id, or #f; what the worker
  ;; was made with; its forked threads, #f where none was forked; and how
  ;; many of those have not yet ended.
  (define-record-type (worker %make-worker worker?)
    (fields (immutable m w-m)
            (immutable done w-done)
            (immutable conds w-conds)
            (mutable machine w-machine w-machine-set!)
            (mutable broken w-broken w-broken-set!)
            (mutable owner w-owner w-owner-set!)
            (immutable observer w-observer)
            (immutable step w-step)
            (immutable double? w-double?)
            (immutable set-up w-set-up)
            (immutable tear-down w-tear-down)
            (immutable threads w-threads)
            (mutable live w-live w-live-set!))
    (sealed #t)
    (opaque #t))

  ;; A call's ticket: its job, its wait's resume, whether the machine took
  ;; it, and whether its answer has been posted, which only the double reads.
  (define-record-type ticket
    (fields (immutable job ticket-job)
            (mutable resume ticket-resume ticket-resume-set!)
            (mutable accepted? ticket-accepted? ticket-accepted?-set!)
            (mutable posted? ticket-posted? ticket-posted?-set!))
    (sealed #t)
    (opaque #t))

  ;; A job's raise, as its result is packed; its values are packed as their
  ;; list. Neither is a symbol, so neither is taken for stopped or left.
  (define-record-type raised
    (fields (immutable e raised-e))
    (sealed #t)
    (opaque #t))

  ;; On each worker thread, that thread's id.
  (define worker-thread (make-thread-parameter #f))

  (define (own-thread?) (eqv? (worker-thread) (get-thread-id)))

  ;; --- arguments --------------------------------------------------------

  (define (nat? x) (and (integer? x) (exact? x) (>= x 0)))
  (define (thread-count? x) (and (fixnum? x) (fx>=? x 1)))

  (define (check-common who set-up cap threads)
    (unless (procedure? set-up)
      (assertion-violation who "the set-up is a procedure of no arguments" set-up))
    (unless (nat? cap)
      (assertion-violation who "the cap is an exact integer, 0 or more" cap))
    (unless (thread-count? threads)
      (assertion-violation who "the threads are a fixnum, 1 or more" threads)))

  (define (check-tear-down who tear-down)
    (unless (procedure? tear-down)
      (assertion-violation who "the tear-down is a procedure of one argument, the state" tear-down)))

  ;; make-worker : (-> State) Nat [Positive-Fixnum] [(State -> Any)] -> Worker
  ;; A worker of THREADS threads, 1 by default, each with the state its run
  ;; of SET-UP answered, and a queue of at most CAP jobs. It returns once
  ;; every set-up has returned; otherwise, once every forked thread has
  ;; been joined, it raises the lowest thread's fork or set-up raise. Each
  ;; thread runs TEAR-DOWN, if given, with its state after its last job.
  (define make-worker
    (case-lambda
      ((set-up cap)
       (check-common 'make-worker set-up cap 1)
       (start! #f step #f set-up cap 1 #f))
      ((set-up cap threads)
       (check-common 'make-worker set-up cap threads)
       (start! #f step #f set-up cap threads #f))
      ((set-up cap threads tear-down)
       (check-common 'make-worker set-up cap threads)
       (check-tear-down 'make-worker tear-down)
       (start! #f step #f set-up cap threads tear-down))))

  ;; make-test-worker : (-> State) [(State -> Any)] -> Worker
  ;; The double: one thread and no queue, whose calls each wait until
  ;; their job's answer is posted. Its jobs run on its own thread.
  (define make-test-worker
    (case-lambda
      ((set-up)
       (check-common 'make-test-worker set-up 0 1)
       (start! #f step #t set-up 0 1 #f))
      ((set-up tear-down)
       (check-common 'make-test-worker set-up 0 1)
       (check-tear-down 'make-test-worker tear-down)
       (start! #f step #t set-up 0 1 tear-down))))

  ;; make-shell-worker : (U Observer #f) Step Boolean (-> State) Nat Positive-Fixnum
  ;;                     (U (State -> Any) #f) -> Worker
  ;; A worker told to OBSERVER, if any, stepping by STEP in the machine's
  ;; place, the double if DOUBLE?, which then takes a CAP of 0 and 1
  ;; thread. Each argument is checked before anything is forked.
  (define (make-shell-worker observer step double? set-up cap threads tear-down)
    (define who 'make-shell-worker)
    (unless (or (not observer) (procedure? observer))
      (assertion-violation who "the observer is #f or a procedure" observer))
    (unless (procedure? step)
      (assertion-violation who "the step is a procedure of a machine and an event" step))
    (unless (boolean? double?)
      (assertion-violation who "double? is a boolean" double?))
    (check-common who set-up cap threads)
    (when tear-down (check-tear-down who tear-down))
    (when (and double? (not (and (eqv? cap 0) (eqv? threads 1))))
      (assertion-violation who "the double takes a cap of 0 and 1 thread" cap threads))
    (start! observer step double? set-up cap threads tear-down))

  ;; --- the lock ---------------------------------------------------------

  (define (hold! w)
    (mutex-acquire (w-m w))
    (w-owner-set! w (get-thread-id)))

  (define (unhold! w)
    (w-owner-set! w #f)
    (mutex-release (w-m w)))

  ;; A wait that raises has not let go of m, so the owner is set again.
  (define (cond-wait! w c)
    (w-owner-set! w #f)
    (with-exception-handler
     (lambda (e) (w-owner-set! w (get-thread-id)) (raise e))
     (lambda () (condition-wait c (w-m w))))
    (w-owner-set! w (get-thread-id)))

  ;; worker-lock-free? : Worker -> Boolean
  ;; Whether another thread could take W's lock now: a thread forked to try
  ;; it, without waiting, and joined.
  (define (worker-lock-free? w)
    (let* ((m (w-m w))
           (free #f)
           (t (fork-thread (lambda () (when (mutex-acquire m #f) (set! free #t) (mutex-release m))))))
      (thread-join t)
      free))

  ;; worker-live-count : Worker -> Nat
  ;; How many of W's threads have been forked and haven't yet ended, read
  ;; under its lock.
  (define (worker-live-count w)
    (unless (worker? w) (assertion-violation 'worker-live-count "not a worker" w))
    (hold! w)
    (let ((n (w-live w)))
      (unhold! w)
      n))

  (define (live-down! w)
    (hold! w)
    (w-live-set! w (- (w-live w) 1))
    (unhold! w))

  ;; --- the observer -----------------------------------------------------

  ;; A blocking point: the lock must be free on this thread. INFO and
  ;; PARTY are evaluated only with an observer.
  (define-syntax at-point
    (syntax-rules ()
      ((_ w party kind info)
       (let ((obs (w-observer w)))
         (when obs (point! w obs party kind info))))))

  (define (point! w obs party kind info)
    (when (eqv? (w-owner w) (get-thread-id))
      (assertion-violation 'worker "a blocking point reached holding the worker's lock" kind party))
    (obs kind party (get-thread-id) info))

  ;; A note, under the lock.
  (define-syntax at-note
    (syntax-rules ()
      ((_ w party kind info)
       (let ((obs (w-observer w)))
         (when obs (obs kind party (get-thread-id) info))))))

  ;; --- steps ------------------------------------------------------------

  ;; The machine before and after EV, the reply and the effects, or, on a
  ;; broken worker, the machine twice, a reply of #f and no effects. Called
  ;; with the lock held and interrupts disabled.
  (define (stepped w ev)
    (let ((before (w-machine w)))
      (if (w-broken w)
          (values before before #f '())
          (let-values (((after reply effects) ((w-step w) before ev)))
            (w-machine-set! w after)
            (values before after reply effects)))))

  ;; step! : Worker Party Event (U ((Listof Effect) -> Any) #f) -> Reply
  ;; A section, its point, and its effects carried out, each change in
  ;; those still to do told to KEEP!, if any. #f on a broken worker, which
  ;; steps nothing and has no point. m is released before
  ;; interrupts are enabled, so an interrupt deferred in the section runs
  ;; with m free; and they are enabled under the handler that carries out
  ;; the effects, so one that raises there, between the step and its
  ;; effects, breaks the worker with those effects still to carry out.
  (define (step! w party ev keep!)
    (hold! w)
    (disable-interrupts)
    (let-values (((before after reply effects)
                  (with-exception-handler
                   (lambda (e) (break! w #t '()) (raise e))
                   (lambda () (stepped w ev)))))
      (unhold! w)
      (if (and reply (or (w-observer w) (pair? effects)))
          (carry-out! w party effects ev before after reply keep!)
          (enable-interrupts))
      reply))

  ;; held-step! : Worker Party Event -> Reply
  ;; The same step under a lock already held, which stays held. #f on a
  ;; broken worker.
  (define (held-step! w party ev)
    (disable-interrupts)
    (let-values (((before after reply effects)
                  (with-exception-handler
                   (lambda (e) (break! w #t '()) (raise e))
                   (lambda () (stepped w ev)))))
      (enable-interrupts)
      (when reply (at-note w party 'held (list ev before after reply effects)))
      reply))

  ;; Run THUNK with the lock held by this thread: a raise there, from a
  ;; note or a wait, breaks the worker and lets go of the lock.
  (define (with-held w thunk)
    (with-exception-handler
     (lambda (e) (break! w #f '()) (raise e))
     thunk))

  ;; --- effects ----------------------------------------------------------

  ;; Interrupts enabled, which the section left disabled, the section's
  ;; point, then each effect in order, with a point before and after it.
  ;; A raise breaks the worker, and the effects not yet done are carried
  ;; out on the broken path. KEEP!, a thread's, is told what is still to
  ;; do, so that an exit, which passes this handler, leaves it to the
  ;; thread's after-thunk; it is cleared once a raise has taken it over.
  (define (carry-out! w party effects ev before after reply keep!)
    (let ((rest effects))
      (when keep! (keep! rest))
      (with-exception-handler
       (lambda (e) (when keep! (keep! '())) (break! w #f rest) (raise e))
       (lambda ()
         (enable-interrupts)
         (at-point w party 'section (list ev before after reply effects))
         (let loop ()
           (unless (null? rest)
             (let ((eff (car rest)))
               (at-point w party 'effect eff)
               (effect! w eff)
               (set! rest (cdr rest))
               (when keep! (keep! rest))
               (at-point w party 'effected eff)
               (loop))))))))

  (define (effect! w eff)
    (case (car eff)
      ((post) (post! w (cadr eff) (caddr eff)))
      ((signal) (condition-signal (vector-ref (w-conds w) (- (cadr eff) 1))))
      ((wake-waiters) (condition-broadcast (w-done w)))
      (else (assertion-violation 'worker "an effect the shell doesn't know" eff))))

  ;; A post calls the ticket's resume; in the double, it then marks the
  ;; ticket in a section of its own, which a broken worker doesn't stop,
  ;; and wakes the caller waiting for the mark.
  (define (post! w k outcome)
    ((ticket-resume k) outcome)
    (when (w-double? w)
      (hold! w)
      (disable-interrupts)
      (ticket-posted?-set! k #t)
      (unhold! w)
      (enable-interrupts)
      (condition-broadcast (w-done w))))

  ;; --- the broken worker ------------------------------------------------

  (define (broken-error)
    (condition (make-error) (make-who-condition 'worker-call)
               (make-message-condition "the worker is broken")))

  ;; The tickets the machine holds: given or running, by thread, then
  ;; queued, oldest first.
  (define (held-tickets mach)
    (let loop ((slots (machine-slots mach)) (acc '()))
      (if (null? slots)
          (append (reverse acc) (machine-queue mach))
          (let ((s (car slots)))
            (loop (cdr slots)
                  (if (and (pair? s) (memq (car s) '(given running)))
                      (cons (cadr s) acc)
                      acc))))))

  ;; break! : Worker Boolean (Listof Effect) -> Void
  ;; Mark W broken under its lock, taken unless this thread holds it, then
  ;; let it go, and enable interrupts if DISABLED?. Outside the lock: the
  ;; first to break it posts the &error to every ticket the machine held;
  ;; PENDING, this party's effects not yet done, are carried out, their
  ;; posts made the &error; every thread is signalled and done broadcast.
  (define (break! w disabled? pending)
    (unless (eqv? (w-owner w) (get-thread-id)) (hold! w))
    (let* ((first? (not (w-broken w)))
           (tickets (if first?
                        (begin (w-broken-set! w (broken-error)) (held-tickets (w-machine w)))
                        '()))
           (out (make-raised (w-broken w))))
      (unhold! w)
      (when disabled? (enable-interrupts))
      (for-each (lambda (k) (post! w k out)) tickets)
      (for-each (lambda (eff)
                  (if (eq? (car eff) 'post)
                      (post! w (cadr eff) out)
                      (effect! w eff)))
                pending)
      (vector-for-each condition-signal (w-conds w))
      (condition-broadcast (w-done w))))

  ;; --- the catch --------------------------------------------------------

  ;; THUNK's answer, or its raise as a raised: two nested handlers, each
  ;; escaping by the continuation for anything but a warning, which each
  ;; passes on continuably. A warning raised plainly comes back from the
  ;; outer handler as &non-continuable, which the inner layer's own handler,
  ;; the outer one, catches.
  (define (caught thunk)
    (call/cc
     (lambda (k)
       (let ((pass (lambda (e) (if (warning? e) (raise-continuable e) (k (make-raised e))))))
         (with-exception-handler
          pass
          (lambda () (with-exception-handler pass thunk)))))))

  ;; The machine's outcome of a set-up or a tear-down's catch.
  (define (outcome r) (if (raised? r) (list 'raised (raised-e r)) 'returned))

  (define (tear-down-outcome w state)
    (let ((td (w-tear-down w)))
      (if td
          (outcome (caught (lambda () (td state) '())))
          'returned)))

  ;; A kept raise, raised: what was raised, or for one that left its
  ;; thread, an &error saying so.
  (define (kept-raise o who what)
    (if (pair? o)
        (cadr o)
        (condition (make-error) (make-who-condition who) (make-message-condition what))))

  ;; --- the maker --------------------------------------------------------

  (define (start! observer step double? set-up cap threads tear-down)
    (let ((w (%make-worker (make-mutex) (make-condition)
                           (let ((v (make-vector threads)))
                             (let loop ((i 0))
                               (when (fx<? i threads)
                                 (vector-set! v i (make-condition))
                                 (loop (fx+ i 1))))
                             v)
                           (initial-machine threads cap) #f #f
                           observer step double? set-up tear-down
                           (make-vector threads #f) 0)))
      (hold! w)
      (let ((reply (with-exception-handler
                    (lambda (e) (join-all w) (raise e))
                    (lambda () (with-held w (lambda () (await-start w (fork-all! w threads))))))))
        (unhold! w)
        (cond ((eq? reply 'ready) w)
              ((not reply) (join-all w) (raise (w-broken w)))
              (else (join-all w) (raise (kept-raise (cadr reply) 'make-worker "a set-up left its thread")))))))

  ;; Fork threads 1 to N, the lock held, counting each one live. The event
  ;; to step: every fork made, or the first that raised.
  (define (fork-all! w n)
    (let loop ((i 1))
      (if (fx>? i n)
          '(fork)
          (let ((r (guard (e (#t (make-raised e))) (fork-thread (thread-body w i)))))
            (if (raised? r)
                (list 'fork-raised i (raised-e r))
                (begin
                  (vector-set! (w-threads w) (fx- i 1) r)
                  (w-live-set! w (+ (w-live w) 1))
                  (loop (fx+ i 1))))))))

  ;; The fork step, then looks until ready or failed, waiting on done
  ;; between, all under the lock. #f once the worker is broken.
  (define (await-start w fork-ev)
    (let ((r (held-step! w '(maker) fork-ev)))
      (if (eq? r 'wait)
          (let look ()
            (let ((r (held-step! w '(maker) '(look))))
              (if (eq? r 'wait)
                  (begin
                    (at-note w '(maker) 'wait 'done)
                    (cond-wait! w (w-done w))
                    (look))
                  r)))
          r)))

  (define (join-all w)
    (vector-for-each (lambda (t) (when t (thread-join t))) (w-threads w)))

  ;; --- a thread ---------------------------------------------------------

  ;; Thread T's procedure. Its state, and where it is, live in its frame:
  ;; set-up, job, tear-down, protocol or returned.
  (define (thread-body w t)
    (lambda ()
      (worker-thread (get-thread-id))
      (let ((party (and (w-observer w) (list 'thread t)))
            (c (vector-ref (w-conds w) (fx- t 1)))
            (where 'set-up)
            (state #f)
            (has-state? #f)
            (torn? #f)
            (pending '()))
        (define (keep! effects) (set! pending effects))
        (define (act reply)
          (cond ((eq? reply 'wait) (act (next!)))
                ((eq? reply 'tear-down) (act (tear-down!)))
                ((eq? reply 'end) (set! where 'returned))
                (else (act (run! (cadr reply))))))
        ;; Step next until the reply isn't wait, waiting on t's condition
        ;; between, with no release of the lock between a step and its wait.
        (define (next!)
          (hold! w)
          (let ((r (with-held w
                              (lambda ()
                                (let loop ()
                                  (let ((r (held-step! w party (list 'next t))))
                                    (if (eq? r 'wait)
                                        (begin
                                          (at-note w party 'wait party)
                                          (cond-wait! w c)
                                          (loop))
                                        r)))))))
            (unhold! w)
            (or r 'tear-down)))
        (define (run! k)
          (set! where 'job)
          (let ((r (caught (lambda () (call-with-values (lambda () ((ticket-job k) state)) list)))))
            (set! where 'protocol)
            (or (step! w party (list 'end t r) keep!) 'tear-down)))
        (define (tear-down!)
          (set! where 'tear-down)
          (set! torn? #t)
          (let ((o (tear-down-outcome w state)))
            (set! where 'protocol)
            (or (step! w party (list 'torn-down t o) keep!) 'end)))
        (define (body)
          (let ((r (caught (lambda () (list ((w-set-up w)))))))
            (set! where 'protocol)
            (if (raised? r)
                (act (or (step! w party (list 'set-up t (outcome r)) keep!) 'end))
                (begin
                  (set! state (car r))
                  (set! has-state? #t)
                  (act (or (step! w party (list 'set-up t 'returned) keep!) 'tear-down))))))
        ;; The broken path for a thread that has left the protocol: the effects
        ;; it still had to carry out, then its tear-down, if it has a state
        ;; and none has begun.
        (define (protocol-left!)
          (let ((left pending))
            (set! pending '())
            (break! w #f left))
          (when (and has-state? (not torn?))
            (set! torn? #t)
            (tear-down-after)))
        ;; A step from the after-thunk, in a dynamic-wind of its own: if the
        ;; thread leaves again while it carries out the step's effects, those
        ;; still to do go to the broken path, and none is done twice.
        (define (after-step! ev)
          (let ((done? #f))
            (dynamic-wind
             (lambda () #f)
             (lambda () (step! w party ev keep!) (set! done? #t))
             (lambda () (unless done? (protocol-left!))))))
        ;; A tear-down from the after-thunk, in a dynamic-wind of its own so
        ;; that one that leaves is stepped too. On a broken worker nothing
        ;; steps.
        (define (tear-down-after)
          (let ((tore? #f))
            (dynamic-wind
             (lambda () #f)
             (lambda ()
               (let ((o (tear-down-outcome w state)))
                 (set! tore? #t)
                 (after-step! (list 'torn-down t o))))
             (lambda () (unless tore? (after-step! (list 'torn-down t 'left)))))))
        (define (after)
          (let ((was where))
            (set! where 'returned)
            (case was
              ((job)
               (after-step! (list 'left t))
               (set! torn? #t)
               (tear-down-after))
              ((set-up) (after-step! (list 'set-up t 'left)))
              ((tear-down) (after-step! (list 'torn-down t 'left)))
              ((protocol) (protocol-left!))
              (else #f))))
        (dynamic-wind
         (lambda () #f)
         (lambda () (dynamic-wind (lambda () #f) body after))
         (lambda () (live-down! w))))))

  ;; --- a call -----------------------------------------------------------

  ;; worker-call : Worker (State -> Any) -> Any
  ;; JOB's values, run with a thread's state on one of W's threads, waited
  ;; for with await-outside; its raise, raised again. Raises &worker-full,
  ;; &worker-stopped, the wait's &deadline-passed or &client-closed
  ;; unchanged, an &error for a job that left its thread, or the broken
  ;; worker's &error.
  (define (worker-call w job)
    (unless (worker? w) (assertion-violation 'worker-call "not a worker" w))
    (unless (procedure? job)
      (assertion-violation 'worker-call "the job is a procedure of one argument, the state" job))
    (let* ((k (make-ticket job #f #f #f))
           (r (with-exception-handler
               (lambda (e)
                 (when (and (ticket-accepted? k) (or (deadline-passed? e) (client-closed? e)))
                   (ticket-accepted?-set! k #f)
                   (step! w (and (w-observer w) (list 'caller k)) (list 'abandon k) #f))
                 (raise-continuable e))
               (lambda () (await-outside (lambda (resume) (register! w k resume)))))))
      (cond ((or (pair? r) (null? r)) (apply values r))
            ((raised? r) (raise (raised-e r)))
            ((eq? r 'stopped) (raise (refusal (make-worker-stopped) "the worker has stopped")))
            ((eq? r 'left)
             (raise (condition (make-error) (make-who-condition 'worker-call)
                               (make-message-condition "the job left its thread"))))
            (else (assertion-violation 'worker-call "an outcome the shell doesn't know" r)))))

  (define (refusal c message)
    (condition c (make-who-condition 'worker-call) (make-message-condition message)))

  ;; The call's section and effects; the double then waits for its mark.
  (define (register! w k resume)
    (ticket-resume-set! k resume)
    (let* ((party (and (w-observer w) (list 'caller k)))
           (reply (step! w party (list 'call k) #f)))
      (cond ((eq? reply 'accepted)
             (ticket-accepted?-set! k #t)
             (when (w-double? w) (await-mark! w k party)))
            ((eq? reply 'full) (raise (refusal (make-worker-full) "the worker's queue is full")))
            ((eq? reply 'stopped) (raise (refusal (make-worker-stopped) "the worker has stopped")))
            ((not reply) (raise (w-broken w)))
            (else (assertion-violation 'worker-call "a reply the shell doesn't know" reply)))))

  ;; Wait on done until K is marked posted, rechecking under the lock.
  (define (await-mark! w k party)
    (hold! w)
    (with-held w
               (lambda ()
                 (let loop ()
                   (let ((marked (ticket-posted? k)))
                     (at-note w party 'mark (list k marked))
                     (unless marked
                       (at-note w party 'wait 'done)
                       (cond-wait! w (w-done w))
                       (loop))))))
    (unhold! w))

  ;; --- a stop -----------------------------------------------------------

  ;; worker-stop! : Worker -> Void
  ;; Refuse W's jobs not yet begun, wait for the running ones, tear every
  ;; thread down and join it; then raise the lowest thread's tear-down
  ;; raise, if any. Any thread but a worker's may call it, again too. On a
  ;; worker's own thread it is an assertion violation.
  (define (worker-stop! w)
    (unless (worker? w) (assertion-violation 'worker-stop! "not a worker" w))
    (let* ((own? (own-thread?))
           (reply (step! w '(stopper) (if own? '(stop #t) '(stop #f)) #f)))
      (cond ((eq? reply 'refused) (refuse-own))
            ((not reply)
             (when own? (refuse-own))
             (stopped! w #f))
            (else
             ;; The second stop comes whatever the first answered, and waits
             ;; on done, the lock held from each step into its wait.
             (hold! w)
             (let ((r (with-held w
                                 (lambda ()
                                   (let loop ()
                                     (let ((r (held-step! w '(stopper) '(stop #f))))
                                       (if (eq? r 'wait)
                                           (begin
                                             (at-note w '(stopper) 'wait 'done)
                                             (cond-wait! w (w-done w))
                                             (loop))
                                           r)))))))
               (unhold! w)
               (stopped! w r))))))

  (define (refuse-own)
    (assertion-violation 'worker-stop! "called on a worker's own thread"))

  ;; Join every thread; then raise the kept tear-down raise, if any. R is
  ;; (stopped O-or-#f), or #f on a broken worker.
  (define (stopped! w r)
    (join-all w)
    (when (and r (cadr r))
      (raise (kept-raise (cadr r) 'worker-stop! "a tear-down left its thread"))))
)
