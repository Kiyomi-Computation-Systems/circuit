#!r6rs
;;; (worker-model): the worker's machine inside a world that holds what runs
;;; around it, explored exhaustively in small configurations and walked at
;;; random in large ones. Test-only.
;;;
;;; A world holds:
;;;
;;;   - the machine's state, stepped only through step/row;
;;;   - each worker thread's place in the shell's loop: not forked, setting
;;;     up, carrying out effects (with the reply to act on after), owing a
;;;     next step, waiting on its condition, woken, running a job, tearing
;;;     down, returned, joined;
;;;   - each handler's place: not called, in register with effects pending,
;;;     in the double's register wait, parked, done with what it got;
;;;   - the loop: free, or busy with one handler, since a register and an
;;;     abandon run whole on the one loop thread;
;;;   - the server's half: open or stopped, and its inbox of posts, oldest
;;;     first;
;;;   - the maker, and up to two stoppers, each at its place in its protocol;
;;;   - each ticket's mark, set by whoever carries out its post, which the
;;;     double's register waits on;
;;;   - the spurious-wakeup budget: one per waiting party;
;;;   - ghost state per ticket: accepted, refused, post emitted, resume
;;;     called, run started, abandon stepped, own stop called.
;;;
;;; An event is one atomic action. A section (take the lock, step, release)
;;; is one event; each effect is carried out alone, outside the lock, in the
;;; order the step gave. A thread's next step that answers wait and the
;;; condition-wait after it are one event (R3). A thread told wait by any
;;; other step carries out its effects, then steps next before it waits
;;; (R4). The maker's fork, its first look and the wait after it are one
;;; event, since the maker holds the lock throughout. A deadline or a close
;;; ending a parked wait, and the abandon its handler then steps, are one
;;; event: both run on the loop thread, which nothing else uses between
;;; them.
;;;
;;; Tickets are the symbols k1, k2, ...: the n-th handler to call holds kn.
;;; Handlers are alike until they call, so the next one in line is the only
;;; one that may call; the same holds for stoppers. A job's result is
;;; (value k) or (raise k), so a post that carries another job's answer is
;;; seen.
;;;
;;; Every check that fails raises a model-failure naming the property. The
;;; explorer and the walks catch it and report the trace that reached it.
;;;
;;; Places, as plain data (k a ticket, O an outcome):
;;;   thread   not-forked | setting-up | (effects EFFECTS REPLY) | to-next
;;;            | waiting | woken | (running k) | tearing-down | returned
;;;            | joined
;;;   handler  idle | (registering EFFECTS) | dbl-check | dbl-waiting
;;;            | dbl-woken | parked | (done OUTCOME), where OUTCOME is
;;;            (answer r), (refused full), (refused stopped) or abandoned
;;;   maker    start | waiting | woken | (joining O) | ready | (raised O)
;;;   stopper  idle | (effects EFFECTS) | again | waiting | woken
;;;            | (joining O-or-#f) | (done O-or-#f)
;;; to-next is a thread that has carried out its effects after a wait reply
;;; and owes a next step; dbl-check is the double's register about to check
;;; its ticket's mark; again is a stopper owing its second stop.
;;;
;;; Events, as plain data (W is returned, raised or left):
;;;   (maker fork) (maker fork-raised i) (maker look) (maker join)
;;;   (thread t set-up W) (thread t effect) (thread t next)
;;;   (thread t end value) (thread t end raise) (thread t left)
;;;   (thread t self-stop) (thread t torn-down W)
;;;   (caller c call) (caller c effect) (caller c check) (caller c deadline)
;;;   (loop deliver) (server stop)
;;;   (stopper s start) (stopper s effect) (stopper s again) (stopper s look)
;;;   (stopper s join)
;;;   (spurious maker) (spurious thread t) (spurious stopper s)
;;;   (spurious caller c)
(library (worker-model)
  (export
   ;; configurations
   make-config config? config-name config-threads config-cap config-callers
   config-stoppers config-flags config->datum known-flags
   ;; worlds
   initial-world world? world-config world-machine world-thread world-caller
   world-stopper world-maker world-loop world-inbox world-server-open?
   world-enabled world-apply world-apply/steps world-check
   world-terminal-check world-key world->datum ticket-of
   ;; failures
   model-failure? model-failure-property model-failure-message
   model-failure-irritants
   ;; the explorer
   explore explored? explored-config explored-worlds explored-terminals
   explored-edges explored-depth explored-rows explored-failure
   explored-seconds
   report? report-property report-message report-irritants report-trace
   report-world report-cycle report-before? print-report
   ;; random walks
   make-prng prng-below! walk walked? walked-steps walked-failure
   walked-terminal)
  (import (rnrs)
          (rnrs mutable-pairs)
          (only (chezscheme) vector-copy real-time)
          (circuit-testing)
          (circuit worker machine)
          (worker-rows))

  ;; -------------------------------------------------------------------
  ;; Failures

  ;; model-failure? : Any -> Boolean
  ;; model-failure-property : Model-Failure -> Symbol
  ;; model-failure-message : Model-Failure -> String
  ;; model-failure-irritants : Model-Failure -> (Listof Any)
  (define-record-type model-failure
    (fields property message irritants))

  (define (fail property message . irritants)
    (raise (make-model-failure property message irritants)))

  ;; -------------------------------------------------------------------
  ;; Configurations

  ;; known-flags : (Listof Symbol)
  ;; Each one enables optional events:
  ;;   server-stop    the server stops, closing its inbox
  ;;   setup-fail     a set-up raises or leaves
  ;;   fork-fail      fork i raises, for each i
  ;;   teardown-fail  a tear-down raises or leaves
  ;;   job-left       a job leaves its thread
  ;;   abandon        a deadline or a close ends a parked wait
  ;;   self-stop      a running job calls worker-stop! on its own worker, once
  ;;   spurious       each waiting party may wake once without a signal
  ;;   double         the double: one thread, a cap of 0, and register waits
  ;;                  for its ticket's mark
  (define known-flags
    '(server-stop setup-fail fork-fail teardown-fail job-left abandon
      self-stop spurious double))

  ;; config? : Any -> Boolean
  ;; config-name : Config -> String
  ;; config-threads : Config -> Positive-Fixnum
  ;; config-cap : Config -> Natural
  ;; config-callers : Config -> Natural            ; the handlers, each calling once
  ;; config-stoppers : Config -> (U 0 1 2)
  ;; config-flags : Config -> (Listof Symbol)
  (define-record-type (config %make-config config?)
    (fields name threads cap callers stoppers flags
            server-stop? setup-fail? fork-fail? teardown-fail? job-left?
            abandon? self-stop? spurious? double?))

  ;; make-config : String Positive-Fixnum Natural Natural (U 0 1 2)
  ;;               (Listof Symbol) -> Config
  (define (make-config name threads cap callers stoppers flags)
    (unless (and (fixnum? threads) (>= threads 1))
      (assertion-violation 'make-config "threads must be at least 1" threads))
    (unless (and (integer? cap) (exact? cap) (>= cap 0))
      (assertion-violation 'make-config "cap must be a natural" cap))
    (unless (and (fixnum? callers) (<= 0 callers max-tickets))
      (assertion-violation 'make-config "callers out of range" callers))
    (unless (and (fixnum? stoppers) (<= 0 stoppers 2))
      (assertion-violation 'make-config "stoppers must be 0, 1 or 2" stoppers))
    (for-each (lambda (f)
                (unless (memq f known-flags)
                  (assertion-violation 'make-config "unknown flag" f)))
              flags)
    (let ((has (lambda (f) (and (memq f flags) #t))))
      (when (and (has 'double) (not (and (= threads 1) (eqv? cap 0))))
        (assertion-violation 'make-config "the double has one thread and a cap of 0"
                             threads cap))
      (%make-config name threads cap callers stoppers flags
                    (has 'server-stop) (has 'setup-fail) (has 'fork-fail)
                    (has 'teardown-fail) (has 'job-left) (has 'abandon)
                    (has 'self-stop) (has 'spurious) (has 'double))))

  ;; config->datum : Config -> Sexp
  (define (config->datum c)
    (list (config-name c) 'threads (config-threads c) 'cap (config-cap c)
          'callers (config-callers c) 'stoppers (config-stoppers c)
          (config-flags c)))

  ;; -------------------------------------------------------------------
  ;; Tickets

  (define max-tickets 64)

  (define tickets
    (let ((v (make-vector (+ max-tickets 1) #f)))
      (let loop ((i 1))
        (when (<= i max-tickets)
          (vector-set! v i (string->symbol (string-append "k" (number->string i))))
          (loop (+ i 1))))
      v))

  (define ticket-indices
    (let ((h (make-eq-hashtable)))
      (let loop ((i 1))
        (when (<= i max-tickets)
          (hashtable-set! h (vector-ref tickets i) i)
          (loop (+ i 1))))
      h))

  ;; ticket-of : Positive-Fixnum -> Symbol
  (define (ticket-of i) (vector-ref tickets i))

  ;; The index of ticket k in world w, or #f when k is no ticket of w's.
  (define (ticket-index w k)
    (let ((i (and (symbol? k) (hashtable-ref ticket-indices k #f))))
      (and i (<= i (config-callers (world-config w))) i)))

  (define (index-of w k)
    (or (ticket-index w k) (fail 'canonical "not a ticket of this world" k)))

  ;; The errors the model raises: one per thread and kind, so the raise a
  ;; maker or a stopper passes on names the thread it came from.
  (define (boom kind t) (list 'boom kind t))

  ;; -------------------------------------------------------------------
  ;; Ghost bits, per ticket

  (define G-ACCEPTED 1)
  (define G-REFUSED 2)
  (define G-EMITTED 4)
  (define G-RESUMED 8)
  (define G-STARTED 16)
  (define G-ABANDONED 32)
  (define G-SELF-STOPPED 64)
  (define G-MARKED 128)

  (define (bit? bits b) (not (fx=? (fxand bits b) 0)))

  (define (ghost-flags bits)
    (let ((names '((1 . accepted) (2 . refused) (4 . emitted) (8 . resumed)
                   (16 . started) (32 . abandoned) (64 . self-stopped)
                   (128 . marked))))
      (let loop ((ns names))
        (cond ((null? ns) '())
              ((bit? bits (caar ns)) (cons (cdar ns) (loop (cdr ns))))
              (else (loop (cdr ns)))))))

  ;; -------------------------------------------------------------------
  ;; Worlds: a vector, copied on every change

  (define W-CONFIG 0)
  (define W-MACHINE 1)
  (define W-THREADS 2)       ; vector of thread places, thread 1 first
  (define W-CALLERS 3)       ; vector of handler places, k1's first
  (define W-LOOP 4)          ; #f, or the index of the handler it is busy with
  (define W-INBOX 5)         ; list of (k . r), oldest first
  (define W-SERVER 6)        ; #t while the server serves
  (define W-MAKER 7)
  (define W-STOPPERS 8)      ; vector of stopper places
  (define W-SPURIOUS 9)      ; bitmask of the parties whose budget is spent
  (define W-GHOST 10)        ; vector of ghost bits, k1's first
  (define W-LAST-START 11)   ; the highest ticket index begun so far
  (define W-STOP-BEGUN 12)   ; a step stopped the worker (S1, X1, X2)
  (define W-FORKED 13)       ; how many threads the maker forked
  (define W-NEXT-CALLER 14)
  (define W-NEXT-STOPPER 15)
  (define W-KEPT 16)         ; the raises the model made, (kind t O), by thread
  (define W-SIZE 17)

  (define world-tag 'worker-model-world)

  ;; world? : Any -> Boolean
  (define (world? x)
    (and (vector? x) (= (vector-length x) (+ W-SIZE 1))
         (eq? (vector-ref x W-SIZE) world-tag)))

  (define (wref w i) (vector-ref w i))
  ;; world-config : World -> Config
  (define (world-config w) (wref w W-CONFIG))
  ;; world-machine : World -> Machine
  (define (world-machine w) (wref w W-MACHINE))
  ;; world-loop : World -> (U #f Positive-Fixnum)  ; the handler it is busy with
  (define (world-loop w) (wref w W-LOOP))
  ;; world-inbox : World -> (Listof (Pair Ticket Any))  ; oldest first
  (define (world-inbox w) (wref w W-INBOX))
  ;; world-server-open? : World -> Boolean
  (define (world-server-open? w) (wref w W-SERVER))
  ;; world-maker : World -> Place
  (define (world-maker w) (wref w W-MAKER))
  ;; world-thread : World Positive-Fixnum -> Place
  (define (world-thread w t) (vector-ref (wref w W-THREADS) (- t 1)))
  ;; world-caller : World Positive-Fixnum -> Place  ; the handler holding k<c>
  (define (world-caller w c) (vector-ref (wref w W-CALLERS) (- c 1)))
  ;; world-stopper : World Positive-Fixnum -> Place
  (define (world-stopper w s) (vector-ref (wref w W-STOPPERS) (- s 1)))
  (define (ghost w i) (vector-ref (wref w W-GHOST) (- i 1)))

  ;; A copy of w with each (index value) pair set.
  (define (with w . pairs)
    (let ((v (vector-copy w)))
      (let loop ((p pairs))
        (unless (null? p)
          (vector-set! v (car p) (cadr p))
          (loop (cddr p))))
      v))

  (define (vector-with v i x)
    (let ((c (vector-copy v)))
      (vector-set! c i x)
      c))

  (define (set-thread w t place)
    (with w W-THREADS (vector-with (wref w W-THREADS) (- t 1) place)))
  (define (set-caller w c place)
    (with w W-CALLERS (vector-with (wref w W-CALLERS) (- c 1) place)))
  (define (set-stopper w s place)
    (with w W-STOPPERS (vector-with (wref w W-STOPPERS) (- s 1) place)))
  (define (set-maker w place) (with w W-MAKER place))
  (define (set-ghost w i bits)
    (with w W-GHOST (vector-with (wref w W-GHOST) (- i 1) bits)))
  (define (add-ghost w i b) (set-ghost w i (fxior (ghost w i) b)))

  (define (threads-of w) (config-threads (world-config w)))

  ;; initial-world : Config -> World
  (define (initial-world c)
    (let ((v (make-vector (+ W-SIZE 1) #f)))
      (vector-set! v W-CONFIG c)
      (vector-set! v W-MACHINE (initial-machine (config-threads c) (config-cap c)))
      (vector-set! v W-THREADS (make-vector (config-threads c) 'not-forked))
      (vector-set! v W-CALLERS (make-vector (config-callers c) 'idle))
      (vector-set! v W-LOOP #f)
      (vector-set! v W-INBOX '())
      (vector-set! v W-SERVER #t)
      (vector-set! v W-MAKER 'start)
      (vector-set! v W-STOPPERS (make-vector (config-stoppers c) 'idle))
      (vector-set! v W-SPURIOUS 0)
      (vector-set! v W-GHOST (make-vector (config-callers c) 0))
      (vector-set! v W-LAST-START 0)
      (vector-set! v W-STOP-BEGUN #f)
      (vector-set! v W-FORKED 0)
      (vector-set! v W-NEXT-CALLER 1)
      (vector-set! v W-NEXT-STOPPER 1)
      (vector-set! v W-KEPT '())
      (vector-set! v W-SIZE world-tag)
      v))

  ;; Spurious-wakeup budget bits: the maker, then each thread, each
  ;; stopper, and each handler's register in the double.
  (define (spurious-bit w party i)
    (let ((c (world-config w)))
      (bitwise-arithmetic-shift-left
       1 (case party
           ((maker) 0)
           ((thread) i)
           ((stopper) (+ (config-threads c) i))
           ((caller) (+ (config-threads c) (config-stoppers c) i))))))

  (define (spurious-left? w party i)
    (and (config-spurious? (world-config w))
         (zero? (bitwise-and (wref w W-SPURIOUS) (spurious-bit w party i)))))

  (define (spend-spurious w party i)
    (with w W-SPURIOUS (bitwise-ior (wref w W-SPURIOUS) (spurious-bit w party i))))

  ;; -------------------------------------------------------------------
  ;; The machine's data, checked

  (define (machine-datum m)
    (list (machine-phase m) (machine-slots m) (machine-queue m)
          (machine-raises m)))

  (define (slot-ok? w s)
    (or (and (memq s '(unborn setting-up idle tearing-down ended)) #t)
        (and (pair? s) (memq (car s) '(given running dropping))
             (pair? (cdr s)) (null? (cddr s)) (ticket-index w (cadr s)) #t)))

  (define (model-raise? kind t e)
    (equal? e (boom kind t)))

  (define (kept-ok? w kind t o)
    (or (eq? o 'left)
        (and (pair? o) (eq? (car o) 'raised) (pair? (cdr o)) (null? (cddr o))
             (model-raise? kind t (cadr o)))))

  (define (raise-ok? w r)
    (and (list? r) (= (length r) 3) (fixnum? (cadr r))
         (<= 1 (cadr r) (threads-of w))
         (case (car r)
           ((fork) (let ((o (caddr r)))
                     (and (pair? o) (eq? (car o) 'raised) (pair? (cdr o))
                          (null? (cddr o)) (model-raise? 'fork (cadr r) (cadr o)))))
           ((set-up) (kept-ok? w 'set-up (cadr r) (caddr r)))
           ((tear-down) (kept-ok? w 'tear-down (cadr r) (caddr r)))
           (else #f))))

  ;; The machine as data, every part of it one the world can name.
  (define (machine-key w)
    (let* ((m (world-machine w))
           (phase (machine-phase m))
           (slots (machine-slots m))
           (queue (machine-queue m))
           (raises (machine-raises m)))
      (unless (memq phase '(starting failing serving stopping stopped failed))
        (fail 'canonical "the machine's phase is no phase" phase))
      (unless (and (= (length slots) (threads-of w))
                   (for-all (lambda (s) (slot-ok? w s)) slots))
        (fail 'canonical "a slot the world can't name" slots))
      (unless (for-all (lambda (k) (ticket-index w k)) queue)
        (fail 'canonical "a queued ticket the world can't name" queue))
      (unless (for-all (lambda (r) (raise-ok? w r)) raises)
        (fail 'canonical "a kept raise the world can't name" raises))
      (list phase slots queue raises)))

  ;; world-key : World -> Sexp
  ;; The world as plain data, compared with equal?: two worlds with equal
  ;; keys have the same future under every check. Left out, since no later
  ;; check reads them: what a done handler got; the result a post carries,
  ;; which is checked against its job when the step emits it; and the
  ;; spent budget of a party that can never wait again. Raises a
  ;; model-failure 'canonical for a world holding something it can't name.
  (define (world-key w)
    (list (machine-key w)
          (vector-map key-thread (wref w W-THREADS))
          (vector-map key-caller (wref w W-CALLERS))
          (wref w W-LOOP)
          (map car (wref w W-INBOX))
          (wref w W-SERVER) (wref w W-MAKER)
          (vector-map key-stopper (wref w W-STOPPERS))
          (key-spurious w) (wref w W-GHOST)
          (wref w W-LAST-START) (wref w W-STOP-BEGUN) (wref w W-FORKED)
          (wref w W-NEXT-CALLER) (wref w W-NEXT-STOPPER) (wref w W-KEPT)))

  (define (key-effects effs)
    (map (lambda (e) (if (eq? (car e) 'post) (list 'post (cadr e)) e)) effs))

  (define (key-thread p)
    (if (and (pair? p) (eq? (car p) 'effects))
        (list 'effects (key-effects (cadr p)) (caddr p))
        p))

  (define (key-caller p)
    (cond ((and (pair? p) (eq? (car p) 'done)) 'done)
          ((and (pair? p) (eq? (car p) 'registering))
           (list 'registering (key-effects (cadr p))))
          (else p)))

  (define (key-stopper p)
    (if (and (pair? p) (eq? (car p) 'effects))
        (list 'effects (key-effects (cadr p)))
        p))

  ;; The spent budget of the parties that may still wait.
  (define (key-spurious w)
    (let ((spent (wref w W-SPURIOUS)))
      (if (eqv? spent 0)
          0
          (let* ((c (world-config w))
                 (live (lambda (party i place)
                         (if (case party
                               ((maker) (memq place '(start waiting woken)))
                               ((thread) (not (memq place '(returned joined not-forked))))
                               ((stopper) (or (memq place '(idle again waiting woken))
                                              (eq? (car place) 'effects)))
                               ((caller) (not (or (eq? place 'parked)
                                                  (and (pair? place) (eq? (car place) 'done))))))
                             (spurious-bit w party i)
                             0)))
                 (mask (bitwise-ior
                        (live 'maker 0 (world-maker w))
                        (let loop ((t 1) (acc 0))
                          (if (> t (config-threads c))
                              acc
                              (loop (+ t 1) (bitwise-ior acc (live 'thread t (world-thread w t))))))
                        (let loop ((s 1) (acc 0))
                          (if (> s (config-stoppers c))
                              acc
                              (loop (+ s 1) (bitwise-ior acc (live 'stopper s (world-stopper w s))))))
                        (let loop ((i 1) (acc 0))
                          (if (> i (config-callers c))
                              acc
                              (loop (+ i 1) (bitwise-ior acc (live 'caller i (world-caller w i)))))))))
            (bitwise-and spent mask)))))

  ;; world->datum : World -> Sexp
  (define (world->datum w)
    (let ((m (world-machine w)))
      (list
       (list 'machine (machine-phase m) (machine-slots m) (machine-queue m)
             (machine-raises m))
       (cons 'threads (vector->list (wref w W-THREADS)))
       (cons 'handlers (vector->list (wref w W-CALLERS)))
       (list 'loop (or (wref w W-LOOP) 'free))
       (cons 'inbox (wref w W-INBOX))
       (list 'server (if (wref w W-SERVER) 'serving 'stopped))
       (list 'maker (wref w W-MAKER))
       (cons 'stoppers (vector->list (wref w W-STOPPERS)))
       (list 'spurious-spent (wref w W-SPURIOUS))
       (cons 'ghost
             (let loop ((i 1))
               (if (> i (config-callers (world-config w)))
                   '()
                   (cons (cons (ticket-of i) (ghost-flags (ghost w i)))
                         (loop (+ i 1))))))
       (list 'stop-begun (wref w W-STOP-BEGUN))
       (list 'kept (wref w W-KEPT)))))

  ;; -------------------------------------------------------------------
  ;; Stepping the machine, and the checks every step answers to

  ;; Called with each step taken: (sink event reply effects row).
  (define step-sink #f)

  (define (outcome-ok? o)
    (or (eq? o 'left)
        (and (pair? o) (eq? (car o) 'raised) (pair? (cdr o)) (null? (cddr o)))))

  (define (job-result? w r)
    (and (pair? r) (memq (car r) '(value raise)) (pair? (cdr r))
         (null? (cddr r)) (ticket-index w (cadr r)) #t))

  (define (effect-ok? w e)
    (and (pair? e) (list? e)
         (case (car e)
           ((post) (and (= (length e) 3) (ticket-index w (cadr e))
                        (let ((r (caddr e)))
                          (or (eq? r 'stopped) (eq? r 'left) (job-result? w r)))))
           ((signal) (and (= (length e) 2) (fixnum? (cadr e))
                          (<= 1 (cadr e) (threads-of w))))
           ((wake-waiters) (null? (cdr e)))
           (else #f))))

  (define (reply-ok? w ev reply)
    (case (car ev)
      ((fork fork-raised look)
       (or (eq? reply 'wait) (eq? reply 'ready)
           (and (pair? reply) (eq? (car reply) 'failed) (pair? (cdr reply))
                (null? (cddr reply)) (outcome-ok? (cadr reply)))))
      ((set-up next end left torn-down)
       (or (memq reply '(wait tear-down end))
           (and (pair? reply) (eq? (car reply) 'run) (pair? (cdr reply))
                (null? (cddr reply)) (ticket-index w (cadr reply)) #t)))
      ((call) (memq reply '(accepted full stopped)))
      ((abandon) (eq? reply 'ok))
      ((stop)
       (if (cadr ev)
           (eq? reply 'refused)
           (or (eq? reply 'wait)
               (and (pair? reply) (eq? (car reply) 'stopped) (pair? (cdr reply))
                    (null? (cddr reply))
                    (or (not (cadr reply)) (outcome-ok? (cadr reply)))))))
      (else #f)))

  (define (describe-raise x)
    (if (condition? x) (describe x) x))

  ;; classify, then step/row, on machine m and event ev. Answers the four
  ;; values of step/row, or raises a model-failure: classify raised, the
  ;; case can't happen, step/row raised, or the two name different rows.
  (define (step-checked m ev)
    (let* ((expected (guard (x (#t (list 'raised (describe-raise x))))
                       (classify m ev)))
           (result (guard (x (#t (list 'raised (describe-raise x))))
                     (call-with-values (lambda () (step/row m ev))
                       (lambda (m2 reply effects row)
                         (list 'stepped m2 reply effects row))))))
      (cond
       ((pair? expected)
        (fail 'classify-raised "classify raised" ev (cadr expected)))
       ((eq? expected 'cant-happen)
        (fail 'cant-happen "a can't-happen case was reached" ev
              (if (eq? (car result) 'raised)
                  (list 'step/row-raised (cadr result))
                  (list 'step/row-answered (list-ref result 4)))))
       ((eq? (car result) 'raised)
        (fail 'step-raised "step/row raised on a row" ev expected (cadr result)))
       ((not (eq? (list-ref result 4) expected))
        (fail 'row "step/row's row differs from classify's" ev
              (list 'step/row (list-ref result 4)) (list 'classify expected)))
       (else (apply values (cdr result))))))

  ;; The thread t is running, by its place in w, or #f.
  (define (thread-job w t)
    (let ((p (world-thread w t)))
      (and (pair? p) (eq? (car p) 'running) (cadr p))))

  ;; mstep : World Event -> (values World Reply (Listof Effect) Row)
  ;; One step of the machine, with every per-step check, and the ghost
  ;; updated. The world answered holds the new machine; the caller sets
  ;; the stepping party's place.
  (define (mstep w ev)
    (let ((m (world-machine w)))
      (let-values (((m2 reply effects row) (step-checked m ev)))
        (unless (reply-ok? w ev reply)
          (fail 'reply "a reply the stepping party can't act on" ev reply))
        (unless (and (list? effects) (for-all (lambda (e) (effect-ok? w e)) effects))
          (fail 'canonical "an effect the world can't name" ev effects))
        (when step-sink (step-sink ev reply effects row))
        (let* ((w1 (with w W-MACHINE m2))
               (w2 (check-refusals w1 m ev m2 reply effects))
               (w3 (check-posts w2 w ev effects))
               (w4 (check-start w3 w ev reply))
               (w5 (if (memq row '(S1 X1 X2)) (with w4 W-STOP-BEGUN #t) w4)))
          (check-raise-is-a-value w m ev m2 reply effects row)
          (values w5 reply effects row)))))

  ;; S6, S9 and S13: a refusal changes nothing, and full only when no slot
  ;; is idle and the queue holds cap. The double is never full.
  (define (check-refusals w1 m ev m2 reply effects)
    (case (car ev)
      ((call)
       (when (memq reply '(full stopped))
         (unless (and (eq? m2 m) (null? effects))
           (fail 'S6 "a refused call changed the machine or made effects"
                 ev reply effects)))
       (when (eq? reply 'full)
         (when (memq 'idle (machine-slots m))
           (fail 'S9 "full while a slot is idle" ev (machine-slots m)))
         (unless (= (length (machine-queue m)) (machine-cap m))
           (fail 'S9 "full while the queue is below cap" ev (machine-queue m)))
         (when (config-double? (world-config w1))
           (fail 'double "the double answered full" ev)))
       w1)
      ((stop)
       (when (eq? reply 'refused)
         (unless (and (eq? m2 m) (null? effects))
           (fail 'S13 "a refused stop changed the machine or made effects"
                 ev effects)))
       w1)
      (else w1)))

  ;; S1, S12 and S14 on each post a step emits.
  (define (check-posts w1 w ev effects)
    (let loop ((es effects) (w1 w1))
      (cond
       ((null? es) w1)
       ((not (eq? (car (car es)) 'post)) (loop (cdr es) w1))
       (else
        (let* ((e (car es)) (k (cadr e)) (r (caddr e)) (i (index-of w k))
               (bits (ghost w1 i)))
          (unless (bit? bits G-ACCEPTED)
            (fail 'S14 "a post for a ticket never accepted" ev e))
          (when (bit? bits G-EMITTED)
            (fail 'S1 "a second post emitted for one ticket" ev e))
          (when (bit? bits G-ABANDONED)
            (fail 'S12 "a post emitted after its ticket's abandon step" ev e))
          (cond
           ((job-result? w r)
            (unless (and (eq? (car ev) 'end) (equal? (caddr ev) r)
                         (eq? (thread-job w (cadr ev)) k))
              (fail 'S14 "a post of an answer its job didn't give" ev e)))
           ((eq? r 'stopped)
            (unless (or (equal? ev '(stop #f)) (eq? (car ev) 'left))
              (fail 'S14 "stopped posted by a step that stops nothing" ev e))
            (when (bit? bits G-STARTED)
              (fail 'S14 "stopped posted to a job that began" ev e)))
           ((eq? r 'left)
            (unless (and (eq? (car ev) 'left) (eq? (thread-job w (cadr ev)) k))
              (fail 'S14 "left posted to a job that didn't leave" ev e))))
          (loop (cdr es) (set-ghost w1 i (fxior bits G-EMITTED))))))))

  ;; S2, S5, S10, S11 and S14 on each job begun: a reply (run k).
  (define (check-start w1 w ev reply)
    (if (and (pair? reply) (eq? (car reply) 'run))
        (let* ((k (cadr reply)) (i (index-of w k)) (bits (ghost w1 i)))
          (unless (memq (car ev) '(next end))
            (fail 'reply "run answered to a step that begins no job" ev reply))
          (unless (bit? bits G-ACCEPTED)
            (fail 'S14 "a job began before its call was accepted" ev reply))
          (when (bit? bits G-REFUSED)
            (fail 'S2 "a refused job began" ev reply))
          (when (bit? bits G-STARTED)
            (fail 'S2 "a job began twice" ev reply (ghost-flags bits)))
          (when (bit? bits G-ABANDONED)
            (fail 'S10 "a job began after its abandon step" ev reply))
          (when (wref w W-STOP-BEGUN)
            (fail 'S11 "a job began after a stop began" ev reply))
          (when (and (= (threads-of w) 1) (<= i (wref w W-LAST-START)))
            (fail 'S5 "with one thread, a job began before one called ahead of it"
                  ev reply (list 'last-begun (ticket-of (wref w W-LAST-START)))))
          (with (set-ghost w1 i (fxior bits G-STARTED))
                W-LAST-START (if (= (threads-of w) 1) i 0)))
        w1))

  (define (substitute-result effects from to)
    (map (lambda (e)
           (if (and (eq? (car e) 'post) (equal? (caddr e) from))
               (list 'post (cadr e) to)
               e))
         effects))

  ;; S8: a job that raises is treated as one that returned a value, and an
  ;; end in serving leaves the worker serving.
  (define (check-raise-is-a-value w m ev m2 reply effects row)
    (when (and (eq? (car ev) 'end) (eq? (car (caddr ev)) 'raise))
      (let* ((r (caddr ev))
             (v (list 'value (cadr r)))
             (alt (guard (x (#t (list 'raised (describe-raise x))))
                    (call-with-values (lambda () (step/row m (list 'end (cadr ev) v)))
                      list))))
        (unless (and (= (length alt) 4)
                     (equal? (machine-datum (car alt)) (machine-datum m2))
                     (equal? (cadr alt) reply)
                     (equal? (substitute-result (caddr alt) v r) effects)
                     (eq? (cadddr alt) row))
          (fail 'S8 "a job's raise is not treated as a value" ev
                (list 'raise-gave (machine-datum m2) reply effects row)
                (list 'value-gave alt))))
      (when (and (eq? (machine-phase m) 'serving)
                 (not (eq? (machine-phase m2) 'serving)))
        (fail 'S8 "a job's raise ended the worker" ev (machine-phase m2)))))

  ;; -------------------------------------------------------------------
  ;; Places after a step

  ;; A thread acts on its reply once its effects are carried out.
  (define (thread-act reply)
    (cond ((eq? reply 'wait) 'to-next)
          ((eq? reply 'tear-down) 'tearing-down)
          ((eq? reply 'end) 'returned)
          (else (list 'running (cadr reply)))))

  (define (thread-after effects reply)
    (if (null? effects) (thread-act reply) (list 'effects effects reply)))

  ;; The maker acts on a look's reply: wait waits on done.
  (define (maker-after-look reply)
    (cond ((eq? reply 'wait) 'waiting)
          ((eq? reply 'ready) 'ready)
          (else (list 'joining (cadr reply)))))

  ;; A woken maker loops while its look answers wait.
  (define (maker-after-wake reply) (maker-after-look reply))

  (define (stopper-after-look reply)
    (cond ((eq? reply 'wait) 'waiting)
          (else (list 'joining (cadr reply)))))

  ;; A woken stopper loops while its stop answers wait.
  (define (stopper-after-wake reply) (stopper-after-look reply))

  ;; A handler whose register's effects are all carried out: parked, or in
  ;; the double, about to check its ticket's mark.
  (define (register-done w c)
    (if (config-double? (world-config w))
        (set-caller w c 'dbl-check)
        (with (set-caller w c 'parked) W-LOOP #f)))

  (define (all-joinable? w upto)
    (let loop ((t 1))
      (or (> t upto)
          (and (memq (world-thread w t) '(returned joined))
               (loop (+ t 1))))))

  (define (join-threads w upto)
    (let loop ((t 1) (w w))
      (if (> t upto) w (loop (+ t 1) (set-thread w t 'joined)))))

  (define (insert-kept kept entry)
    (cond ((null? kept) (list entry))
          ((< (cadr entry) (cadr (car kept))) (cons entry kept))
          (else (cons (car kept) (insert-kept (cdr kept) entry)))))

  (define (keep w kind t o)
    (if (eq? o 'returned)
        w
        (with w W-KEPT (insert-kept (wref w W-KEPT) (list kind t o)))))

  (define (outcome-of kind t which)
    (case which
      ((returned) 'returned)
      ((raised) (list 'raised (boom kind t)))
      ((left) 'left)))

  ;; -------------------------------------------------------------------
  ;; Effects

  ;; Carries out effect e. Answers the world and any effects it adds in
  ;; front of the party's rest: in the double, a post marks its ticket in a
  ;; section, then broadcasts done.
  (define (carry-out w e)
    (case (car e)
      ((post) (post w (cadr e) (caddr e)))
      ((mark)
       (values (add-ghost w (index-of w (cadr e)) G-MARKED) '()))
      ((signal)
       (let ((t (cadr e)))
         (values (if (eq? (world-thread w t) 'waiting)
                     (set-thread w t 'woken)
                     w)
                 '())))
      ((wake-waiters) (values (wake-waiters w) '()))
      (else (fail 'canonical "an effect the world can't carry out" e))))

  ;; Broadcasts done: every party waiting on it wakes.
  (define (wake-waiters w)
    (let* ((w (if (eq? (world-maker w) 'waiting) (set-maker w 'woken) w))
           (w (let loop ((s 1) (w w))
                (if (> s (config-stoppers (world-config w)))
                    w
                    (loop (+ s 1)
                          (if (eq? (world-stopper w s) 'waiting)
                              (set-stopper w s 'woken)
                              w))))))
      (let loop ((c 1) (w w))
        (if (> c (config-callers (world-config w)))
            w
            (loop (+ c 1)
                  (if (eq? (world-caller w c) 'dbl-waiting)
                      (set-caller w c 'dbl-woken)
                      w))))))

  ;; k's resume, called with r. While the server serves and k's wait
  ;; hasn't ended, the post joins the inbox; to an ended wait, or once the
  ;; server has stopped, it is dropped. S1: resume is called at most once.
  (define (post w k r)
    (let* ((i (index-of w k)) (bits (ghost w i)))
      (when (bit? bits G-RESUMED)
        (fail 'S1 "a job's resume called twice" k r))
      (let* ((w (set-ghost w i (fxior bits G-RESUMED)))
             (place (world-caller w i))
             (live (or (memq place '(parked dbl-check dbl-waiting dbl-woken))
                       (and (pair? place) (eq? (car place) 'registering))))
             (w (if (and (world-server-open? w) live)
                    (with w W-INBOX (append (world-inbox w) (list (cons k r))))
                    w)))
        (values w
                (if (config-double? (world-config w))
                    (list (list 'mark k) '(wake-waiters))
                    '())))))

  ;; The next effect of a party that has some pending.
  (define (pending-of place)
    (case (car place)
      ((effects registering) (cadr place))
      (else '())))

  (define (do-effect w party i)
    (let* ((place (case party
                    ((thread) (world-thread w i))
                    ((caller) (world-caller w i))
                    ((stopper) (world-stopper w i))))
           (effs (pending-of place)))
      (let-values (((w added) (carry-out w (car effs))))
        (let ((rest (append added (cdr effs))))
          (case party
            ((thread)
             (set-thread w i (thread-after rest (caddr place))))
            ((caller)
             (if (null? rest)
                 (register-done w i)
                 (set-caller w i (list 'registering rest))))
            ((stopper)
             (set-stopper w i (if (null? rest) 'again (list 'effects rest)))))))))

  ;; -------------------------------------------------------------------
  ;; Enabled events

  ;; world-enabled : World -> (Listof Event)
  ;; Every event that may happen next, as plain data, in a fixed order.
  (define (world-enabled w)
    (let* ((c (world-config w))
           (n (config-threads c))
           (acc '())
           (add! (lambda (ev) (set! acc (cons ev acc))))
           (maker (world-maker w))
           (ready (eq? maker 'ready))
           (loop-free (not (world-loop w)))
           (open (world-server-open? w)))
      ;; the maker
      (cond
       ((eq? maker 'start)
        (add! '(maker fork))
        (when (config-fork-fail? c)
          (let loop ((i 1))
            (when (<= i n)
              (add! (list 'maker 'fork-raised i))
              (loop (+ i 1))))))
       ((eq? maker 'woken) (add! '(maker look)))
       ((eq? maker 'waiting)
        (when (spurious-left? w 'maker 0) (add! '(spurious maker))))
       ((and (pair? maker) (eq? (car maker) 'joining))
        (when (all-joinable? w (wref w W-FORKED)) (add! '(maker join)))))
      ;; the threads
      (let loop ((t 1))
        (when (<= t n)
          (let ((p (world-thread w t)))
            (cond
             ((eq? p 'setting-up)
              (add! (list 'thread t 'set-up 'returned))
              (when (config-setup-fail? c)
                (add! (list 'thread t 'set-up 'raised))
                (add! (list 'thread t 'set-up 'left))))
             ((eq? p 'to-next) (add! (list 'thread t 'next)))
             ((eq? p 'woken) (add! (list 'thread t 'next)))
             ((eq? p 'waiting)
              (when (spurious-left? w 'thread t)
                (add! (list 'spurious 'thread t))))
             ((eq? p 'tearing-down)
              (add! (list 'thread t 'torn-down 'returned))
              (when (config-teardown-fail? c)
                (add! (list 'thread t 'torn-down 'raised))
                (add! (list 'thread t 'torn-down 'left))))
             ((pair? p)
              (case (car p)
                ((effects) (add! (list 'thread t 'effect)))
                ((running)
                 (add! (list 'thread t 'end 'value))
                 (add! (list 'thread t 'end 'raise))
                 (when (config-job-left? c) (add! (list 'thread t 'left)))
                 (when (and (config-self-stop? c)
                            (not (bit? (ghost w (index-of w (cadr p)))
                                       G-SELF-STOPPED)))
                   (add! (list 'thread t 'self-stop)))))))
            (loop (+ t 1)))))
      ;; the handlers
      (let ((next (wref w W-NEXT-CALLER)))
        (when (and ready loop-free (<= next (config-callers c)))
          (add! (list 'caller next 'call))))
      (let loop ((i 1))
        (when (<= i (config-callers c))
          (let ((p (world-caller w i)))
            (cond
             ((and (pair? p) (eq? (car p) 'registering))
              (add! (list 'caller i 'effect)))
             ((memq p '(dbl-check dbl-woken)) (add! (list 'caller i 'check)))
             ((eq? p 'dbl-waiting)
              (when (spurious-left? w 'caller i)
                (add! (list 'spurious 'caller i))))
             ((eq? p 'parked)
              (when (and (config-abandon? c) open loop-free)
                (add! (list 'caller i 'deadline))))))
          (loop (+ i 1))))
      ;; the loop and the server
      (when (and loop-free open (pair? (world-inbox w)))
        (add! '(loop deliver)))
      (when (and (config-server-stop? c) open loop-free ready)
        (add! '(server stop)))
      ;; the stoppers
      (let ((next (wref w W-NEXT-STOPPER)))
        (when (and ready (<= next (config-stoppers c)))
          (add! (list 'stopper next 'start))))
      (let loop ((s 1))
        (when (<= s (config-stoppers c))
          (let ((p (world-stopper w s)))
            (cond
             ((eq? p 'again) (add! (list 'stopper s 'again)))
             ((eq? p 'woken) (add! (list 'stopper s 'look)))
             ((eq? p 'waiting)
              (when (spurious-left? w 'stopper s)
                (add! (list 'spurious 'stopper s))))
             ((pair? p)
              (case (car p)
                ((effects) (add! (list 'stopper s 'effect)))
                ((joining)
                 (when (all-joinable? w n) (add! (list 'stopper s 'join))))))))
          (loop (+ s 1))))
      (reverse acc)))

  ;; -------------------------------------------------------------------
  ;; Applying an event

  (define (expect-place got wanted ev)
    (unless (if (procedure? wanted) (wanted got) (memq got wanted))
      (fail 'model "an event applied where it isn't enabled" ev got)))

  ;; The fork, then the look and the wait that follow it under the lock.
  (define (after-fork w reply)
    (if (eq? reply 'wait)
        (let-values (((w reply effs row) (mstep w '(look))))
          (set-maker w (maker-after-look reply)))
        (set-maker w (list 'joining (cadr reply)))))

  (define (apply-maker w ev)
    (case (cadr ev)
      ((fork)
       (expect-place (world-maker w) '(start) ev)
       (let-values (((w reply effs row) (mstep w '(fork))))
         (let* ((n (threads-of w))
                (w (with w W-FORKED n
                         W-THREADS (make-vector n 'setting-up))))
           (after-fork w reply))))
      ((fork-raised)
       (expect-place (world-maker w) '(start) ev)
       (let* ((i (caddr ev)) (e (boom 'fork i)))
         (let-values (((w reply effs row) (mstep w (list 'fork-raised i e))))
           (let ((threads (make-vector (threads-of w) 'not-forked)))
             (let loop ((t 1))
               (when (< t i)
                 (vector-set! threads (- t 1) 'setting-up)
                 (loop (+ t 1))))
             (after-fork (with w W-FORKED (- i 1) W-THREADS threads
                               W-KEPT (insert-kept (wref w W-KEPT)
                                                   (list 'fork i (list 'raised e))))
                         reply)))))
      ((look)
       (expect-place (world-maker w) '(woken) ev)
       (let-values (((w reply effs row) (mstep w '(look))))
         (set-maker w (maker-after-wake reply))))
      ((join)
       (let ((p (world-maker w)))
         (expect-place p (lambda (p) (and (pair? p) (eq? (car p) 'joining))) ev)
         (set-maker (join-threads w (wref w W-FORKED)) (list 'raised (cadr p)))))
      (else (fail 'model "no such maker event" ev))))

  (define (apply-thread w ev)
    (let ((t (cadr ev)) (what (caddr ev)))
      (case what
        ((set-up)
         (expect-place (world-thread w t) '(setting-up) ev)
         (let ((o (outcome-of 'set-up t (cadddr ev))))
           (let-values (((w reply effs row) (mstep w (list 'set-up t o))))
             (set-thread (keep w 'set-up t o) t (thread-after effs reply)))))
        ((effect)
         (expect-place (world-thread w t)
                       (lambda (p) (and (pair? p) (eq? (car p) 'effects))) ev)
         (do-effect w 'thread t))
        ((next)
         (expect-place (world-thread w t) '(to-next woken) ev)
         (let-values (((w reply effs row) (mstep w (list 'next t))))
           ;; R3: told wait, the thread condition-waits without releasing
           ;; the lock in between.
           (set-thread w t (if (and (eq? reply 'wait) (null? effs))
                               'waiting
                               (thread-after effs reply)))))
        ((end)
         (let ((k (thread-job w t)))
           (unless k (fail 'model "an end from a thread running nothing" ev))
           (let ((r (list (cadddr ev) k)))
             (let-values (((w reply effs row) (mstep w (list 'end t r))))
               (set-thread w t (thread-after effs reply))))))
        ((left)
         (unless (thread-job w t) (fail 'model "left from a thread running nothing" ev))
         (let-values (((w reply effs row) (mstep w (list 'left t))))
           (set-thread w t (thread-after effs reply))))
        ((self-stop)
         (let ((k (thread-job w t)))
           (unless k (fail 'model "a self-stop from a thread running nothing" ev))
           (let-values (((w2 reply effs row) (mstep w '(stop #t))))
             (add-ghost w2 (index-of w k) G-SELF-STOPPED))))
        ((torn-down)
         (expect-place (world-thread w t) '(tearing-down) ev)
         (let ((o (outcome-of 'tear-down t (cadddr ev))))
           (let-values (((w reply effs row) (mstep w (list 'torn-down t o))))
             (set-thread (keep w 'tear-down t o) t (thread-after effs reply)))))
        (else (fail 'model "no such thread event" ev)))))

  ;; The double's register, holding the lock, checks its ticket's mark: a
  ;; marked ticket returns, and the handler parks; otherwise it waits on
  ;; done.
  (define (double-check w c)
    (if (bit? (ghost w c) G-MARKED)
        (double-returns w c)
        (set-caller w c 'dbl-waiting)))

  ;; A woken register loops while its ticket isn't marked.
  (define (double-check-after-wake w c) (double-check w c))

  (define (double-returns w c)
    (unless (bit? (ghost w c) G-RESUMED)
      (fail 'double "the double's register returned before its ticket's post"
            (ticket-of c)))
    (with (set-caller w c 'parked) W-LOOP #f))

  (define (apply-caller w ev)
    (let* ((c (cadr ev)) (k (ticket-of c)))
      (case (caddr ev)
        ((call)
         (unless (and (= c (wref w W-NEXT-CALLER)) (not (world-loop w))
                      (eq? (world-maker w) 'ready))
           (fail 'model "a call that isn't enabled" ev))
         (let-values (((w reply effs row) (mstep w (list 'call k))))
           (let ((w (with w W-NEXT-CALLER (+ c 1))))
             (if (eq? reply 'accepted)
                 (let ((w (with (add-ghost w c G-ACCEPTED) W-LOOP c)))
                   (if (null? effs)
                       (register-done w c)
                       (set-caller w c (list 'registering effs))))
                 (set-caller (add-ghost w c G-REFUSED) c (list 'done (list 'refused reply)))))))
        ((effect)
         (expect-place (world-caller w c)
                       (lambda (p) (and (pair? p) (eq? (car p) 'registering))) ev)
         (do-effect w 'caller c))
        ((check)
         (case (world-caller w c)
           ((dbl-check) (double-check w c))
           ((dbl-woken) (double-check-after-wake w c))
           (else (fail 'model "a check that isn't enabled" ev))))
        ((deadline)
         ;; The wait raises, and its handler steps the abandon in a section,
         ;; all on the loop thread. A post to the ended wait is dropped:
         ;; one already in the inbox goes now, since its delivery would
         ;; drop it.
         (expect-place (world-caller w c) '(parked) ev)
         (unless (and (world-server-open? w) (not (world-loop w)))
           (fail 'model "a deadline that isn't enabled" ev))
         (let-values (((w reply effs row) (mstep w (list 'abandon k))))
           (with (set-caller (add-ghost w c G-ABANDONED) c '(done abandoned))
                 W-INBOX (filter (lambda (p) (not (eq? (car p) k))) (world-inbox w)))))
        (else (fail 'model "no such handler event" ev)))))

  ;; The loop delivers the oldest post: to a parked wait it is the answer;
  ;; a wait that ended drops it.
  (define (deliver w)
    (let* ((post (car (world-inbox w)))
           (c (index-of w (car post)))
           (w (with w W-INBOX (cdr (world-inbox w)))))
      (if (eq? (world-caller w c) 'parked)
          (set-caller w c (list 'done (list 'answer (cdr post))))
          w)))

  (define (apply-stopper w ev)
    (let ((s (cadr ev)))
      (case (caddr ev)
        ((start)
         (unless (and (= s (wref w W-NEXT-STOPPER)) (eq? (world-maker w) 'ready))
           (fail 'model "a stop that isn't enabled" ev))
         (let-values (((w reply effs row) (mstep w '(stop #f))))
           (set-stopper (with w W-NEXT-STOPPER (+ s 1)) s
                        (if (null? effs) 'again (list 'effects effs)))))
        ((effect)
         (expect-place (world-stopper w s)
                       (lambda (p) (and (pair? p) (eq? (car p) 'effects))) ev)
         (do-effect w 'stopper s))
        ((again)
         (expect-place (world-stopper w s) '(again) ev)
         (let-values (((w reply effs row) (mstep w '(stop #f))))
           (set-stopper w s (stopper-after-look reply))))
        ((look)
         (expect-place (world-stopper w s) '(woken) ev)
         (let-values (((w reply effs row) (mstep w '(stop #f))))
           (set-stopper w s (stopper-after-wake reply))))
        ((join)
         (let ((p (world-stopper w s)) (n (threads-of w)))
           (expect-place p (lambda (p) (and (pair? p) (eq? (car p) 'joining))) ev)
           (set-stopper (join-threads w n) s (list 'done (cadr p)))))
        (else (fail 'model "no such stopper event" ev)))))

  (define (apply-spurious w ev)
    (case (cadr ev)
      ((maker)
       (expect-place (world-maker w) '(waiting) ev)
       (set-maker (spend-spurious w 'maker 0) 'woken))
      ((thread)
       (expect-place (world-thread w (caddr ev)) '(waiting) ev)
       (set-thread (spend-spurious w 'thread (caddr ev)) (caddr ev) 'woken))
      ((stopper)
       (expect-place (world-stopper w (caddr ev)) '(waiting) ev)
       (set-stopper (spend-spurious w 'stopper (caddr ev)) (caddr ev) 'woken))
      ((caller)
       (expect-place (world-caller w (caddr ev)) '(dbl-waiting) ev)
       (set-caller (spend-spurious w 'caller (caddr ev)) (caddr ev) 'dbl-woken))
      (else (fail 'model "no such spurious wakeup" ev))))

  (define (apply-event w ev)
    (let ((w2 (case (car ev)
                ((maker) (apply-maker w ev))
                ((thread) (apply-thread w ev))
                ((caller) (apply-caller w ev))
                ((loop) (deliver w))
                ((server) (with w W-SERVER #f W-INBOX '()))
                ((stopper) (apply-stopper w ev))
                ((spurious) (apply-spurious w ev))
                (else (fail 'model "no such event" ev)))))
      (world-check w2)
      w2))

  ;; world-apply : World Event -> World
  ;; The world after ev, which must be enabled. Raises a model-failure
  ;; when a check fails.
  (define (world-apply w ev)
    (unless (member ev (world-enabled w))
      (fail 'model "an event that isn't enabled" ev))
    (apply-event w ev))

  ;; world-apply/steps : World Event -> (values World (Listof Step))
  ;; As world-apply, and each machine step the event took, in order, as
  ;; (event reply effects row).
  (define (world-apply/steps w ev)
    (let ((steps '()) (saved step-sink))
      (dynamic-wind
        (lambda ()
          (set! step-sink (lambda (e r fx row)
                            (set! steps (cons (list e r fx row) steps)))))
        (lambda ()
          (let ((w2 (world-apply w ev)))
            (values w2 (reverse steps))))
        (lambda () (set! step-sink saved)))))

  ;; -------------------------------------------------------------------
  ;; Invariants, at every world

  (define (all-joined? w upto)
    (let loop ((t 1))
      (or (> t upto)
          (and (eq? (world-thread w t) 'joined) (loop (+ t 1))))))

  ;; world-check : World -> Void
  ;; S3, L3, S7, and the model's places agreeing with the machine's slots.
  (define (world-check w)
    (let* ((m (world-machine w))
           (slots (machine-slots m))
           (queue (machine-queue m))
           (c (world-config w)))
      ;; S7: worker-stop! returns only once every thread has been joined,
      ;; and make-worker raises only once every forked thread has been.
      (let loop ((s 1))
        (when (<= s (config-stoppers c))
          (let ((p (world-stopper w s)))
            (when (and (pair? p) (eq? (car p) 'done)
                       (not (all-joined? w (config-threads c))))
              (fail 'S7 "worker-stop! returned before every thread was joined"
                    s (vector->list (wref w W-THREADS)))))
          (loop (+ s 1))))
      (let ((p (world-maker w)))
        (when (and (pair? p) (eq? (car p) 'raised)
                   (not (all-joined? w (wref w W-FORKED))))
          (fail 'S7 "make-worker raised before every forked thread was joined"
                (wref w W-FORKED) (vector->list (wref w W-THREADS)))))
      (when (> (length queue) (machine-cap m))
        (fail 'S3 "the queue holds more than its cap" queue))
      (when (and (pair? queue) (memq 'idle slots))
        (fail 'L3 "a thread is idle while the queue holds a job" slots queue))
      (let loop ((t 1) (ss slots))
        (unless (null? ss)
          (let ((k (thread-job w t)))
            (when (and k (not (or (equal? (car ss) (list 'running k))
                                  (equal? (car ss) (list 'dropping k)))))
              (fail 'agree "a thread runs a job its slot doesn't hold"
                    t (world-thread w t) (car ss))))
          (when (and (memq (world-thread w t) '(returned joined))
                     (not (eq? (car ss) 'ended)))
            (fail 'agree "a thread returned while its slot hasn't ended"
                  t (world-thread w t) (car ss)))
          (loop (+ t 1) (cdr ss))))))

  ;; -------------------------------------------------------------------
  ;; Terminal checks

  ;; The lowest thread's kept raise of the given kinds, as its outcome.
  (define (lowest-kept w kinds)
    (let loop ((ks (wref w W-KEPT)))
      (cond ((null? ks) #f)
            ((memq (car (car ks)) kinds) (caddr (car ks)))
            (else (loop (cdr ks))))))

  ;; world-terminal-check : World -> Void
  ;; In a world where nothing can happen: L4, L1, L2, and every thread
  ;; returned, joined or never forked with its slot ended, or waiting with
  ;; nothing owed. (S7, that a returned stopper or a raised maker joined
  ;; every thread first, is checked at every world.)
  (define (world-terminal-check w)
    (let* ((c (world-config w))
           (m (world-machine w))
           (maker (world-maker w)))
      ;; L4
      (cond
       ((eq? maker 'ready) #t)
       ((and (pair? maker) (eq? (car maker) 'raised))
        (let ((want (lowest-kept w '(fork set-up))))
          (unless (equal? (cadr maker) want)
            (fail 'L4 "make-worker raised another raise than the lowest thread's"
                  (cadr maker) want))))
       (else (fail 'L4 "make-worker never returned or raised" maker)))
      ;; L1
      (let loop ((i 1))
        (when (<= i (config-callers c))
          (let ((p (world-caller w i)))
            (cond
             ((eq? p 'idle) #t)
             ((and (pair? p) (eq? (car p) 'done)) #t)
             ((eq? p 'parked)
              (when (world-server-open? w)
                (fail 'L1 "a handler waits for ever while the server serves"
                      (ticket-of i) (ghost-flags (ghost w i)))))
             (else (fail 'L1 "a handler is stuck on the loop" (ticket-of i) p))))
          (loop (+ i 1))))
      ;; L2
      (let loop ((s 1))
        (when (<= s (config-stoppers c))
          (let ((p (world-stopper w s)))
            (cond
             ((eq? p 'idle) #t)
             ((and (pair? p) (eq? (car p) 'done))
              (let ((want (lowest-kept w '(tear-down))))
                (unless (equal? (cadr p) want)
                  (fail 'L2 "worker-stop! returned another raise than the lowest tear-down's"
                        s (cadr p) want))))
             (else (fail 'L2 "worker-stop! never returned" s p))))
          (loop (+ s 1))))
      ;; every thread settled
      (let loop ((t 1) (slots (machine-slots m)))
        (unless (null? slots)
          (let ((p (world-thread w t)))
            (cond
             ((memq p '(returned joined not-forked))
              (unless (eq? (car slots) 'ended)
                (fail 'settled "a thread is gone while its slot hasn't ended"
                      t p (car slots))))
             ((eq? p 'waiting)
              (unless (and (eq? (car slots) 'idle) (null? (machine-queue m)))
                (fail 'settled "a thread waits for ever with work owed"
                      t (car slots) (machine-queue m))))
             (else (fail 'settled "a thread is stuck" t p))))
          (loop (+ t 1) (cdr slots))))))

  ;; -------------------------------------------------------------------
  ;; Reports

  ;; A failure, the trace of events from the initial world that reaches
  ;; it, and a world: the one the trace reaches, or for a failure in the
  ;; trace's last event, the one before it (before? is #t).
  ;; report? : Any -> Boolean
  ;; report-property : Report -> Symbol
  ;; report-message : Report -> String
  ;; report-irritants : Report -> (Listof Any)
  ;; report-trace : Report -> (Listof Event)
  ;; report-world : Report -> Sexp
  ;; report-cycle : Report -> (U #f (Listof Event))  ; around the cycle, for 'cycle
  ;; report-before? : Report -> Boolean
  (define-record-type report
    (fields property message irritants trace world cycle before?))

  (define (failure->report f trace world cycle)
    (make-report (model-failure-property f) (model-failure-message f)
                 (model-failure-irritants f) trace world cycle #f))

  (define (event-failure->report f trace world)
    (make-report (model-failure-property f) (model-failure-message f)
                 (model-failure-irritants f) trace world #f #t))

  ;; print-report : Report Port -> Void
  (define (print-report r port)
    (put-string port "FAILED: ")
    (write (report-property r) port)
    (put-string port " -- ")
    (put-string port (report-message r))
    (newline port)
    (for-each (lambda (x) (put-string port "  ") (write x port) (newline port))
              (report-irritants r))
    (put-string port "trace (")
    (put-string port (number->string (length (report-trace r))))
    (put-string port " events):")
    (newline port)
    (let loop ((evs (report-trace r)) (i 1))
      (unless (null? evs)
        (put-string port "  ")
        (put-string port (number->string i))
        (put-string port ". ")
        (write (car evs) port)
        (newline port)
        (loop (cdr evs) (+ i 1))))
    (when (report-cycle r)
      (put-string port "cycle, back to the world after that trace:")
      (newline port)
      (for-each (lambda (e) (put-string port "  ") (write e port) (newline port))
                (report-cycle r)))
    (put-string port (if (report-before? r) "world before the last event:" "world:"))
    (newline port)
    (for-each (lambda (x) (put-string port "  ") (write x port) (newline port))
              (report-world r)))

  ;; -------------------------------------------------------------------
  ;; The explorer

  ;; explored? : Any -> Boolean
  ;; explored-config : Explored -> Config
  ;; explored-worlds : Explored -> Natural
  ;; explored-terminals : Explored -> Natural
  ;; explored-edges : Explored -> Natural
  ;; explored-depth : Explored -> Natural
  ;; explored-rows : Explored -> (Listof Row)      ; every row a step took
  ;; explored-failure : Explored -> (U #f Report)
  ;; explored-seconds : Explored -> Real
  (define-record-type explored
    (fields config worlds terminals edges depth rows failure seconds))

  ;; A growable vector.
  (define (grow v n)
    (if (< n (vector-length v))
        v
        (let ((g (make-vector (* 2 (vector-length v)) #f)))
          (let loop ((i 0))
            (when (< i (vector-length v))
              (vector-set! g i (vector-ref v i))
              (loop (+ i 1))))
          g)))

  ;; Any raise while a world is applied, keyed or checked, as a failure:
  ;; one that isn't a model-failure is a fault in the model or in a
  ;; library it calls, reported with its trace like any other.
  (define (as-failure x)
    (if (model-failure? x)
        x
        (make-model-failure 'error "the model raised" (list (describe-raise x)))))

  ;; explore : Config -> Explored
  ;; Breadth first from the initial world, with a visited set over world
  ;; keys: every check at every step and world, the terminal checks at
  ;; every terminal world, and the first failure reported with the
  ;; shortest trace that reaches it. Then, over the graph it built, a
  ;; depth-first search for a cycle. The rows are those of every step
  ;; taken.
  (define (explore c)
    (let ((start (real-time))
          (seen (make-hashtable equal-hash equal?))
          (parts (make-hashtable equal-hash equal?))
          (parents (make-vector 4096 #f))
          (events (make-vector 4096 #f))
          (succs (make-vector 4096 #f))
          (count 0)
          (terminals 0)
          (edges 0)
          (depth 0)
          (rows (make-eq-hashtable))
          (saved step-sink))
      ;; A world's key as a vector of small numbers, one per part of the
      ;; key, each part numbered the first time it is seen: the visited
      ;; set then holds no structure the collector has to trace.
      (define (compact key)
        (let ((v (make-vector (length key))))
          (let loop ((ps key) (i 0))
            (unless (null? ps)
              (vector-set! v i (or (hashtable-ref parts (car ps) #f)
                                   (let ((n (hashtable-size parts)))
                                     (hashtable-set! parts (car ps) n)
                                     n)))
              (loop (cdr ps) (+ i 1))))
          v))
      (define (trace-to id)
        (let loop ((id id) (acc '()))
          (let ((p (vector-ref parents id)))
            (if p (loop p (cons (vector-ref events id) acc)) acc))))
      (define (world-at trace)
        (fold-left apply-event (initial-world c) trace))
      (define (add-world! key parent ev)
        (set! parents (grow parents count))
        (set! events (grow events count))
        (set! succs (grow succs count))
        (vector-set! parents count parent)
        (vector-set! events count ev)
        (hashtable-set! seen key count)
        (set! count (+ count 1))
        (- count 1))
      (define (finish failure)
        (make-explored c count terminals edges depth
                       (list-sort (lambda (a b)
                                    (string<? (symbol->string a) (symbol->string b)))
                                  (vector->list (hashtable-keys rows)))
                       failure
                       (/ (- (real-time) start) 1000.0)))
      ;; The enabled event of w that leads to the world numbered id.
      (define (event-between w id)
        (let loop ((evs (world-enabled w)))
          (cond ((null? evs) '(no-event-found))
                ((eqv? (hashtable-ref seen (compact (world-key (apply-event w (car evs)))) #f) id)
                 (car evs))
                (else (loop (cdr evs))))))
      (define (cycle-report cycle)
        (let* ((trace (trace-to (car cycle)))
               (w0 (world-at trace)))
          (let loop ((w w0) (nodes (cdr cycle)) (evs '()))
            (if (null? nodes)
                (make-report 'cycle "the world graph has a cycle" '() trace
                             (world->datum w0) (reverse evs) #f)
                (let ((ev (event-between w (car nodes))))
                  (loop (if (equal? ev '(no-event-found)) w (apply-event w ev))
                        (cdr nodes) (cons ev evs)))))))
      (define (search return)
        (define (failed x trace w)
          (return (finish (failure->report (as-failure x) trace (world->datum w) #f))))
        (define (event-failed x trace w)
          (return (finish (event-failure->report (as-failure x) trace (world->datum w)))))
        (let ((w0 (initial-world c)))
          (guard (x (#t (failed x '() w0)))
            (add-world! (compact (world-key w0)) #f #f))
          (let bfs ((frontier (list (cons 0 w0))))
            (unless (null? frontier)
              (let level ((fs frontier) (next '()))
                (if (null? fs)
                    (begin
                      (unless (null? next) (set! depth (+ depth 1)))
                      (bfs (reverse next)))
                    (let* ((id (car (car fs)))
                           (w (cdr (car fs)))
                           (evs (guard (x (#t (failed x (trace-to id) w)))
                                  (world-enabled w))))
                      (when (null? evs)
                        (set! terminals (+ terminals 1))
                        (guard (x (#t (failed x (trace-to id) w)))
                          (world-terminal-check w)))
                      (let each ((evs evs) (next next) (out '()))
                        (if (null? evs)
                            (begin
                              (vector-set! succs id (list->vector out))
                              (level (cdr fs) next))
                            (let* ((ev (car evs))
                                   (got (guard (x (#t (event-failed x (append (trace-to id) (list ev)) w)))
                                          (let ((w2 (apply-event w ev)))
                                            (cons w2 (compact (world-key w2))))))
                                   (old (hashtable-ref seen (cdr got) #f)))
                              (set! edges (+ edges 1))
                              (if old
                                  (each (cdr evs) next (cons old out))
                                  (let ((id2 (add-world! (cdr got) id ev)))
                                    (each (cdr evs) (cons (cons id2 (car got)) next)
                                          (cons id2 out))))))))))))
          (let ((cycle (find-cycle succs count)))
            (finish (and cycle (cycle-report cycle))))))
      (dynamic-wind
        (lambda ()
          (set! step-sink (lambda (e r fx row) (hashtable-set! rows row #t))))
        (lambda () (call/cc search))
        (lambda () (set! step-sink saved)))))

  ;; A depth-first search for a cycle over succs, whose entry i is a
  ;; vector of the worlds world i leads to. Answers #f, or the worlds
  ;; around a cycle, (n0 n1 ... n0).
  (define (find-cycle succs count)
    (let ((color (make-bytevector count 0)))
      (call/cc
       (lambda (return)
         (let roots ((root 0))
           (when (< root count)
             (when (= 0 (bytevector-u8-ref color root))
               (bytevector-u8-set! color root 1)
               (let dfs ((stack (list (vector root 0))))
                 (unless (null? stack)
                   (let* ((top (car stack))
                          (node (vector-ref top 0))
                          (i (vector-ref top 1))
                          (out (vector-ref succs node)))
                     (if (= i (vector-length out))
                         (begin
                           (bytevector-u8-set! color node 2)
                           (dfs (cdr stack)))
                         (let ((to (vector-ref out i)))
                           (vector-set! top 1 (+ i 1))
                           (case (bytevector-u8-ref color to)
                             ((0)
                              (bytevector-u8-set! color to 1)
                              (dfs (cons (vector to 0) stack)))
                             ((1)
                              (return
                               (let collect ((s stack) (acc (list to)))
                                 (let ((acc (cons (vector-ref (car s) 0) acc)))
                                   (if (= (vector-ref (car s) 0) to)
                                       acc
                                       (collect (cdr s) acc))))))
                             (else (dfs stack)))))))))
             (roots (+ root 1))))
         #f))))

  ;; -------------------------------------------------------------------
  ;; Random walks

  ;; A linear congruential generator over exact integers modulo 2^64
  ;; (Knuth's MMIX constants), so a seed gives the same draws everywhere.
  ;; make-prng : Natural -> Prng
  (define (make-prng seed) (vector (mod seed 18446744073709551616)))

  ;; prng-below! : Prng Positive-Integer -> Natural
  ;; A draw in [0, n), from the generator's high 32 bits.
  (define (prng-below! p n)
    (let ((x (mod (+ (* (vector-ref p 0) 6364136223846793005) 1442695040888963407)
                  18446744073709551616)))
      (vector-set! p 0 x)
      (mod (bitwise-arithmetic-shift-right x 32) n)))

  ;; walked? : Any -> Boolean
  ;; walked-steps : Walked -> Natural
  ;; walked-failure : Walked -> (U #f Report)
  ;; walked-terminal : Walked -> World             ; where the walk ended
  (define-record-type walked
    (fields steps failure terminal))

  ;; A walk longer than this has found a cycle: every event spends
  ;; something a world holds only finitely much of.
  (define walk-step-bound 100000)

  ;; walk : Config Prng (Event -> Positive-Fixnum) (Symbol -> Any) -> Walked
  ;; One walk from the initial world, each event drawn with the weight
  ;; weight-of gives it, to a terminal world, with every check at every
  ;; step and the terminal checks at the end. note-row is told each row
  ;; fired. A failure is reported with the walk's whole trace; a walk past
  ;; walk-step-bound steps fails as a cycle, with its last 50 events.
  (define (walk c prng weight-of note-row)
    (let ((saved step-sink))
      (dynamic-wind
        (lambda () (set! step-sink (lambda (e r fx row) (note-row row))))
        (lambda ()
          (let loop ((w (initial-world c)) (trace '()) (steps 0))
            (let ((evs (world-enabled w)))
              (cond
               ((> steps walk-step-bound)
                (make-walked steps
                             (make-report 'cycle "a walk didn't end" (list steps)
                                          (reverse (list-head trace 50)) (world->datum w) #f #f)
                             w))
               ((null? evs)
                  (guard (x (#t
                             (make-walked steps
                                          (failure->report (as-failure x) (reverse trace)
                                                           (world->datum w) #f)
                                          w)))
                    (world-terminal-check w)
                    (make-walked steps #f w)))
               (else
                  (let* ((ev (choose prng evs weight-of))
                         (w2 (guard (x (#t
                                        (make-walked steps
                                                     (event-failure->report (as-failure x)
                                                                            (reverse (cons ev trace))
                                                                            (world->datum w))
                                                     w)))
                               (apply-event w ev))))
                    (if (walked? w2)
                        w2
                        (loop w2 (cons ev trace) (+ steps 1)))))))))
        (lambda () (set! step-sink saved)))))

  (define (list-head l n)
    (if (or (null? l) (= n 0)) '() (cons (car l) (list-head (cdr l) (- n 1)))))

  (define (choose prng evs weight-of)
    (let* ((weights (map weight-of evs))
           (total (fold-left + 0 weights))
           (r (prng-below! prng total)))
      (let loop ((evs evs) (ws weights) (r r))
        (if (< r (car ws))
            (car evs)
            (loop (cdr evs) (cdr ws) (- r (car ws))))))))
