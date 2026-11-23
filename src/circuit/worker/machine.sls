#!r6rs
;;; (circuit worker machine): a worker's decisions as one pure function.
;;;
;;; A worker runs jobs on a fixed number of threads, with a bounded queue
;;; of jobs waiting for a thread. Everything it decides about jobs,
;;; threads and the queue is `step`: given a machine and an event, it
;;; answers the next machine, a reply for the party that stepped, and the
;;; effects for everyone else. The worker's shell calls it under its lock
;;; and does what it says. It does no I/O, keeps no state, and never
;;; changes a machine it was given.
;;;
;;; The data are symbols and lists, so a whole result compares with
;;; `equal?`. Threads are numbered from 1.
;;;
;;;   Phase   = starting | failing | serving | stopping | stopped | failed
;;;   Ticket  = any value, compared by eq?
;;;   Slot    = unborn | setting-up | idle | (given k) | (running k)
;;;           | (dropping k) | tearing-down | ended
;;;   Outcome = returned | left | (raised e)
;;;   Raise   = (fork t (raised e)) | (set-up t O) | (tear-down t O)
;;;             where O is left or (raised e)
;;;   Event   = (fork) | (fork-raised i e) | (look) | (set-up t Outcome)
;;;           | (call k) | (abandon k) | (next t) | (end t r) | (left t)
;;;           | (stop own?) | (torn-down t Outcome)
;;;   Reply   = wait | accepted | full | stopped | ok | ready | tear-down
;;;           | end | refused | (run k) | (failed O) | (stopped O-or-#f)
;;;   Effect  = (post k r) | (post k stopped) | (post k left)
;;;           | (signal t) | (wake-waiters)
;;;   Row     = F1 F2 F3 K1 K2 K3 U1-U7 C1-C4 A1-A5 N1-N3 E1-E6 X1-X4
;;;             S1-S4 T1-T4
;;;
;;; A machine holds its phase, one slot per thread, the queue (at most
;;; cap tickets, oldest first), the cap, and the raises kept: at most
;;; one per thread, in ascending thread order. A ticket is in the queue,
;;; in one slot, or gone. `r` in an `end` event is whatever the shell
;;; packed a job's result in; it is posted unchanged.
;;;
;;; A case that cannot happen, and any malformed event, raises an
;;; assertion violation naming the case. A row that changes nothing
;;; answers the very machine it was given.
(library (circuit worker machine)
  (export initial-machine make-machine machine? machine-phase
          machine-slots machine-queue machine-cap machine-raises
          step step/row)
  (import (rnrs))

  ;; The queue is two lists: the front, oldest first, and the back,
  ;; newest first, so an enqueue does not copy. qn is their length.
  ;; machine? : Any -> Boolean
  (define-record-type (machine %make-machine machine?)
    (fields (immutable ph m-phase)
            (immutable sv m-slots)
            (immutable qf m-qf)
            (immutable qb m-qb)
            (immutable qn m-qn)
            (immutable cap m-cap)
            (immutable rs m-raises)))

  (define (nat? x) (and (integer? x) (exact? x) (>= x 0)))

  ;; machine-phase : Machine -> Phase
  (define (machine-phase m) (m-phase m))

  ;; machine-slots : Machine -> (Listof Slot)
  (define (machine-slots m) (vector->list (m-slots m)))

  ;; machine-queue : Machine -> (Listof Ticket)
  (define (machine-queue m) (queue->list m))

  ;; machine-cap : Machine -> Natural
  (define (machine-cap m) (m-cap m))

  ;; machine-raises : Machine -> (Listof Raise)
  (define (machine-raises m) (m-raises m))

  (define (queue->list m)
    (if (null? (m-qb m))
        (list-copy (m-qf m))
        (append (m-qf m) (reverse (m-qb m)))))

  (define (list-copy l)
    (if (null? l) '() (cons (car l) (list-copy (cdr l)))))

  ;; initial-machine : Positive-Fixnum Natural -> Machine
  (define (initial-machine threads cap)
    (if (and (fixnum? threads) (>= threads 1) (nat? cap))
        (%make-machine 'starting (make-vector threads 'unborn)
                       '() '() 0 cap '())
        (assertion-violation 'initial-machine
                             "threads must be a fixnum >= 1 and cap a natural"
                             threads cap)))

  ;; Shapes -----------------------------------------------------------

  (define (outcome? o)
    (or (eq? o 'returned) (eq? o 'left)
        (and (pair? o) (eq? (car o) 'raised)
             (pair? (cdr o)) (null? (cddr o)))))

  (define (kept-outcome? o) (and (outcome? o) (not (eq? o 'returned))))

  (define (slot? s)
    (or (and (symbol? s)
             (memq s '(unborn setting-up idle tearing-down ended)) #t)
        (and (pair? s) (memq (car s) '(given running dropping))
             (pair? (cdr s)) (null? (cddr s)))))

  (define (raise-entry? x n)
    (and (list? x) (= (length x) 3)
         (memq (car x) '(fork set-up tear-down))
         (fixnum? (cadr x)) (<= 1 (cadr x) n)
         (if (eq? (car x) 'fork)
             (let ((o (caddr x)))
               (and (pair? o) (eq? (car o) 'raised)
                    (pair? (cdr o)) (null? (cddr o))))
             (kept-outcome? (caddr x)))
         #t))

  (define (slot-ticket s) (cadr s))
  (define (ticketed? s) (pair? s))

  (define (all-tickets slots queue)
    (let loop ((i (- (vector-length slots) 1)) (acc queue))
      (if (< i 0)
          acc
          (let ((s (vector-ref slots i)))
            (loop (- i 1) (if (ticketed? s) (cons (slot-ticket s) acc) acc))))))

  (define (distinct-eq? l)
    (or (null? l)
        (and (not (memq (car l) (cdr l))) (distinct-eq? (cdr l)))))

  (define (ascending? rs)
    (or (null? rs) (null? (cdr rs))
        (and (< (cadr (car rs)) (cadr (cadr rs))) (ascending? (cdr rs)))))

  ;; make-machine : Phase (Listof Slot) (Listof Ticket) Natural
  ;;                (Listof Raise) -> Machine
  (define (make-machine phase slots queue cap raises)
    (define (bad what)
      (assertion-violation 'make-machine what phase slots queue cap raises))
    (unless (memq phase '(starting failing serving stopping stopped failed))
      (bad "not a phase"))
    (unless (and (list? slots) (pair? slots) (for-all slot? slots))
      (bad "slots must be a non-empty list of slots"))
    (unless (nat? cap) (bad "cap must be a natural"))
    (unless (list? queue) (bad "queue must be a list"))
    (unless (<= (length queue) cap) (bad "queue holds more than cap"))
    (let ((sv (list->vector slots)))
      (unless (distinct-eq? (all-tickets sv queue))
        (bad "a ticket appears twice"))
      (unless (and (list? raises)
                   (for-all (lambda (x) (raise-entry? x (vector-length sv)))
                            raises)
                   (ascending? raises))
        (bad "raises must be ascending, one per thread, each in range"))
      (%make-machine phase sv (list-copy queue) '() (length queue) cap
                     raises)))

  ;; Helpers ----------------------------------------------------------

  (define (cant what ev) (assertion-violation 'step what ev))

  ;; Arity of an event: a proper list of exactly that many elements.
  (define (arity1? ev) (null? (cdr ev)))
  (define (arity2? ev) (and (pair? (cdr ev)) (null? (cddr ev))))
  (define (arity3? ev)
    (and (pair? (cdr ev)) (pair? (cddr ev)) (null? (cdddr ev))))

  (define (thread-ok? t n) (and (fixnum? t) (<= 1 t n)))

  (define (vector-copy v)
    (let* ((n (vector-length v)) (c (make-vector n)))
      (let loop ((i 0))
        (when (< i n)
          (vector-set! c i (vector-ref v i))
          (loop (+ i 1))))
      c))

  (define (slot-at slots t) (vector-ref slots (- t 1)))

  ;; A copy of the slots with thread t set to s.
  (define (with-slot slots t s)
    (let ((v (vector-copy slots)))
      (vector-set! v (- t 1) s)
      v))

  (define (given? s) (and (pair? s) (eq? (car s) 'given)))
  (define (running? s) (and (pair? s) (eq? (car s) 'running)))
  (define (dropping? s) (and (pair? s) (eq? (car s) 'dropping)))

  ;; Does some slot other than t satisfy pred?
  (define (other? slots t pred)
    (let ((n (vector-length slots)))
      (let loop ((i 1))
        (cond ((> i n) #f)
              ((and (not (= i t)) (pred (vector-ref slots (- i 1)))) #t)
              (else (loop (+ i 1)))))))

  (define (live? s) (not (eq? s 'ended)))
  (define (setting-up? s) (eq? s 'setting-up))
  (define (idle? s) (eq? s 'idle))
  (define (given-or-idle? s) (or (idle? s) (given? s)))

  ;; The lowest thread whose slot is idle, or #f.
  (define (lowest-idle slots)
    (let ((n (vector-length slots)))
      (let loop ((i 1))
        (cond ((> i n) #f)
              ((eq? (vector-ref slots (- i 1)) 'idle) i)
              (else (loop (+ i 1)))))))

  (define (all-slots? slots s)
    (let ((n (vector-length slots)))
      (let loop ((i 0))
        (or (= i n)
            (and (eq? (vector-ref slots i) s) (loop (+ i 1)))))))

  ;; The slots with every slot satisfying pred set to s.
  (define (retag slots pred s)
    (let* ((v (vector-copy slots)) (n (vector-length v)))
      (let loop ((i 0))
        (when (< i n)
          (when (pred (vector-ref v i)) (vector-set! v i s))
          (loop (+ i 1))))
      v))

  ;; (signal t) for each thread whose slot satisfies pred, in thread
  ;; order, in front of tail.
  (define (signals slots pred tail)
    (let loop ((i (vector-length slots)) (acc tail))
      (if (= i 0)
          acc
          (loop (- i 1)
                (if (pred (vector-ref slots (- i 1)))
                    (cons (list 'signal i) acc)
                    acc)))))

  ;; Insert a kept raise (its thread is its second element).
  (define (insert-raise rs r)
    (cond ((null? rs) (list r))
          ((< (cadr r) (cadr (car rs))) (cons r rs))
          (else (cons (car rs) (insert-raise (cdr rs) r)))))

  (define (rebuild m phase slots qf qb qn raises)
    (%make-machine phase slots qf qb qn (m-cap m) raises))

  (define (with-phase-slots m phase slots)
    (%make-machine phase slots (m-qf m) (m-qb m) (m-qn m) (m-cap m)
                   (m-raises m)))

  (define (with-slots m slots)
    (%make-machine (m-phase m) slots (m-qf m) (m-qb m) (m-qn m) (m-cap m)
                   (m-raises m)))

  ;; Take the oldest ticket off the queue. The queue must not be empty.
  ;; Answers the ticket, the new front and the new back.
  (define (dequeue m)
    (let ((f (m-qf m)))
      (if (pair? f)
          (values (car f) (cdr f) (m-qb m))
          (let ((r (reverse (m-qb m))))
            (values (car r) (cdr r) '())))))

  ;; With a queue taking a job: the machine moves to its next slot for t
  ;; and the queue's front; row answers E1 or E3.
  (define (queue-empty? m) (= (m-qn m) 0))

  ;; Stop's shared part -------------------------------------------------

  ;; S1's effects: post stopped to each given ticket in thread order,
  ;; then each queued ticket oldest first, then signal each given or idle
  ;; slot in thread order.
  (define (stop-effects m slots)
    (let* ((sigs (signals slots given-or-idle? '()))
           (qposts
            (let loop ((q (reverse (queue->list m))) (acc sigs))
              (if (null? q)
                  acc
                  (loop (cdr q) (cons (list 'post (car q) 'stopped) acc))))))
      (let loop ((i (vector-length slots)) (acc qposts))
        (if (= i 0)
            acc
            (let ((s (vector-ref slots (- i 1))))
              (loop (- i 1)
                    (if (given? s)
                        (cons (list 'post (slot-ticket s) 'stopped) acc)
                        acc)))))))

  ;; The machine after S1's changes, with thread t (if any) set to s.
  (define (stopped-machine m slots t s)
    (let ((v (retag slots given-or-idle? 'tearing-down)))
      (when t (vector-set! v (- t 1) s))
      (rebuild m 'stopping v '() '() 0 (m-raises m))))

  ;; step -------------------------------------------------------------

  ;; step : Machine Event -> (values Machine Reply (Listof Effect))
  (define (step m ev)
    (let-values (((m2 reply effects row) (step/row m ev)))
      (values m2 reply effects)))

  ;; step/row : Machine Event -> (values Machine Reply (Listof Effect) Row)
  (define (step/row m ev)
    (unless (machine? m)
      (assertion-violation 'step "not a machine" m ev))
    (unless (and (pair? ev) (symbol? (car ev)) (list? ev))
      (cant "malformed event" ev))
    (case (car ev)
      ((call) (if (arity2? ev) (do-call m ev) (cant "malformed call" ev)))
      ((next) (if (arity2? ev) (do-next m ev) (cant "malformed next" ev)))
      ((end) (if (arity3? ev) (do-end m ev) (cant "malformed end" ev)))
      ((abandon)
       (if (arity2? ev) (do-abandon m ev) (cant "malformed abandon" ev)))
      ((set-up)
       (if (arity3? ev) (do-set-up m ev) (cant "malformed set-up" ev)))
      ((torn-down)
       (if (arity3? ev) (do-torn-down m ev) (cant "malformed torn-down" ev)))
      ((left) (if (arity2? ev) (do-left m ev) (cant "malformed left" ev)))
      ((stop) (if (arity2? ev) (do-stop m ev) (cant "malformed stop" ev)))
      ((fork) (if (arity1? ev) (do-fork m ev) (cant "malformed fork" ev)))
      ((fork-raised)
       (if (arity3? ev) (do-fork-raised m ev) (cant "malformed fork-raised" ev)))
      ((look) (if (arity1? ev) (do-look m ev) (cant "malformed look" ev)))
      (else (cant "unknown event" ev))))

  ;; Fork: F1-F3 ------------------------------------------------------

  (define (do-fork m ev)
    (let ((slots (m-slots m)))
      (unless (and (eq? (m-phase m) 'starting) (all-slots? slots 'unborn))
        (cant "fork outside starting, or with a slot born" ev))
      (values (with-slots m (make-vector (vector-length slots) 'setting-up))
              'wait '() 'F1)))

  (define (do-fork-raised m ev)
    (let* ((slots (m-slots m)) (n (vector-length slots)) (i (cadr ev))
           (e (caddr ev)))
      (unless (and (eq? (m-phase m) 'starting) (all-slots? slots 'unborn))
        (cant "fork raised outside starting, or with a slot born" ev))
      (unless (thread-ok? i n)
        (cant "fork raised for a thread out of range" ev))
      (let ((o (list 'raised e))
            (v (make-vector n 'ended)))
        (if (> i 1)
            (begin
              (let loop ((j 0))
                (when (< j (- i 1))
                  (vector-set! v j 'setting-up)
                  (loop (+ j 1))))
              (values (rebuild m 'failing v (m-qf m) (m-qb m) (m-qn m)
                               (insert-raise (m-raises m) (list 'fork i o)))
                      'wait '() 'F2))
            (values (rebuild m 'failed v (m-qf m) (m-qb m) (m-qn m)
                             (insert-raise (m-raises m) (list 'fork i o)))
                    (list 'failed o) '() 'F3)))))

  ;; Look: K1-K3 ------------------------------------------------------

  (define (do-look m ev)
    (case (m-phase m)
      ((starting failing) (values m 'wait '() 'K1))
      ((serving) (values m 'ready '() 'K2))
      ((failed)
       (let loop ((rs (m-raises m)))
         (cond ((null? rs)
                (cant "look in failed with no fork or set-up raise" ev))
               ((memq (car (car rs)) '(fork set-up))
                (values m (list 'failed (caddr (car rs))) '() 'K3))
               (else (loop (cdr rs))))))
      (else (cant "look in stopping or stopped" ev))))

  ;; Set-up: U1-U7 ----------------------------------------------------

  (define (do-set-up m ev)
    (let* ((slots (m-slots m)) (n (vector-length slots)) (t (cadr ev))
           (o (caddr ev)) (phase (m-phase m)))
      (unless (thread-ok? t n) (cant "set-up for a thread out of range" ev))
      (unless (outcome? o) (cant "malformed outcome" ev))
      (unless (and (memq phase '(starting failing))
                   (setting-up? (slot-at slots t)))
        (cant "set-up outside starting or failing, or not setting up" ev))
      (cond
       ((eq? o 'returned)
        (if (eq? phase 'starting)
            (let ((v (with-slot slots t 'idle)))
              (if (other? slots t setting-up?)
                  (values (with-slots m v) 'wait '() 'U1)
                  (values (with-phase-slots m 'serving v) 'wait
                          '((wake-waiters)) 'U2)))
            (values (with-slots m (with-slot slots t 'tearing-down))
                    'tear-down '() 'U5)))
       (else
        (let ((raises (insert-raise (m-raises m) (list 'set-up t o)))
              (live (other? slots t live?)))
          (if (eq? phase 'starting)
              (if live
                  (let ((v (retag slots idle? 'tearing-down)))
                    (vector-set! v (- t 1) 'ended)
                    (values (rebuild m 'failing v (m-qf m) (m-qb m) (m-qn m)
                                     raises)
                            'end (signals slots idle? '()) 'U3))
                  (values (rebuild m 'failed (with-slot slots t 'ended)
                                   (m-qf m) (m-qb m) (m-qn m) raises)
                          'end '((wake-waiters)) 'U4))
              (if live
                  (values (rebuild m 'failing (with-slot slots t 'ended)
                                   (m-qf m) (m-qb m) (m-qn m) raises)
                          'end '() 'U6)
                  (values (rebuild m 'failed (with-slot slots t 'ended)
                                   (m-qf m) (m-qb m) (m-qn m) raises)
                          'end '((wake-waiters)) 'U7))))))))

  ;; Call: C1-C4 ------------------------------------------------------

  (define (do-call m ev)
    (let ((k (cadr ev)))
      (case (m-phase m)
        ((serving)
         (let* ((slots (m-slots m)) (t (lowest-idle slots)))
           (cond
            (t (values (with-slots m (with-slot slots t (list 'given k)))
                       'accepted (list (list 'signal t)) 'C1))
            ((< (m-qn m) (m-cap m))
             (values (rebuild m 'serving slots (m-qf m)
                              (cons k (m-qb m)) (+ (m-qn m) 1)
                              (m-raises m))
                     'accepted '() 'C2))
            (else (values m 'full '() 'C3)))))
        ((stopping stopped) (values m 'stopped '() 'C4))
        (else (cant "call before a worker is given out" ev)))))

  ;; Abandon: A1-A5 ---------------------------------------------------

  ;; The thread whose slot is (kind k) for some kind, with that slot, as
  ;; a pair (t . slot), or #f.
  (define (find-ticket slots k)
    (let ((n (vector-length slots)))
      (let loop ((i 1))
        (cond ((> i n) #f)
              ((let ((s (vector-ref slots (- i 1))))
                 (and (ticketed? s) (eq? (slot-ticket s) k)))
               (cons i (vector-ref slots (- i 1))))
              (else (loop (+ i 1)))))))

  (define (remove-first k l)
    (cond ((null? l) '())
          ((eq? (car l) k) (cdr l))
          (else (cons (car l) (remove-first k (cdr l))))))

  (define (do-abandon m ev)
    (let* ((k (cadr ev)) (slots (m-slots m)) (phase (m-phase m)))
      (case phase
        ((serving stopping stopped)
         (let ((queued (memq k (queue->list m)))
               (found (find-ticket slots k)))
           (cond
            (queued
             (if (eq? phase 'serving)
                 (values (rebuild m 'serving slots
                                  (remove-first k (queue->list m)) '()
                                  (- (m-qn m) 1) (m-raises m))
                         'ok '() 'A1)
                 (cant "abandon of a queued job after a stop" ev)))
            (found
             (let ((t (car found)) (s (cdr found)))
               (cond
                ((and (given? s) (eq? phase 'serving))
                 (if (queue-empty? m)
                     (values (with-slots m (with-slot slots t 'idle))
                             'ok '() 'A3)
                     (let-values (((j f b) (dequeue m)))
                       (values (rebuild m 'serving
                                        (with-slot slots t (list 'given j))
                                        f b (- (m-qn m) 1) (m-raises m))
                               'ok '() 'A2))))
                ((and (running? s) (not (eq? phase 'stopped)))
                 (values (with-slots m (with-slot slots t (list 'dropping k)))
                         'ok '() 'A4))
                (else (cant "abandon of a job in a slot that cannot hold it"
                            ev)))))
            (else (values m 'ok '() 'A5)))))
        (else (cant "abandon outside serving, stopping or stopped" ev)))))

  ;; Next: N1-N3 ------------------------------------------------------

  (define (do-next m ev)
    (let* ((slots (m-slots m)) (t (cadr ev)))
      (unless (thread-ok? t (vector-length slots))
        (cant "next for a thread out of range" ev))
      (let ((s (slot-at slots t)) (phase (m-phase m)))
        (cond
         ((and (idle? s) (or (eq? phase 'starting) (eq? phase 'serving)))
          (values m 'wait '() 'N1))
         ((and (given? s) (eq? phase 'serving))
          (let ((k (slot-ticket s)))
            (values (with-slots m (with-slot slots t (list 'running k)))
                    (list 'run k) '() 'N2)))
         ((and (eq? s 'tearing-down) (or (eq? phase 'failing)
                                         (eq? phase 'stopping)))
          (values m 'tear-down '() 'N3))
         (else (cant "next from a slot or phase that cannot step next" ev))))))

  ;; End: E1-E6 -------------------------------------------------------

  (define (do-end m ev)
    (let* ((slots (m-slots m)) (n (vector-length slots)) (t (cadr ev))
           (r (caddr ev)))
      (unless (thread-ok? t n) (cant "end for a thread out of range" ev))
      (let ((s (slot-at slots t)) (phase (m-phase m)))
        (unless (or (running? s) (dropping? s))
          (cant "end from a slot that runs no job" ev))
        (let ((k (slot-ticket s)) (run? (running? s)))
          (case phase
            ((serving)
             (if (queue-empty? m)
                 (values (with-slots m (with-slot slots t 'idle)) 'wait
                         (if run? (list (list 'post k r)) '())
                         (if run? 'E2 'E4))
                 (let-values (((j f b) (dequeue m)))
                   (values (rebuild m 'serving
                                    (with-slot slots t (list 'running j))
                                    f b (- (m-qn m) 1) (m-raises m))
                           (list 'run j)
                           (if run? (list (list 'post k r)) '())
                           (if run? 'E1 'E3)))))
            ((stopping)
             (values (with-slots m (with-slot slots t 'tearing-down))
                     'tear-down
                     (if run? (list (list 'post k r)) '())
                     (if run? 'E5 'E6)))
            (else (cant "end outside serving or stopping" ev)))))))

  ;; Left: X1-X4 ------------------------------------------------------

  (define (do-left m ev)
    (let* ((slots (m-slots m)) (t (cadr ev)))
      (unless (thread-ok? t (vector-length slots))
        (cant "left for a thread out of range" ev))
      (let ((s (slot-at slots t)) (phase (m-phase m)))
        (unless (or (running? s) (dropping? s))
          (cant "left from a slot that runs no job" ev))
        (let ((k (slot-ticket s)) (run? (running? s)))
          (case phase
            ((serving)
             (let ((fx (stop-effects m slots)))
               (values (stopped-machine m slots t 'tearing-down)
                       'tear-down
                       (if run? (cons (list 'post k 'left) fx) fx)
                       (if run? 'X1 'X2))))
            ((stopping)
             (values (with-slots m (with-slot slots t 'tearing-down))
                     'tear-down
                     (if run? (list (list 'post k 'left)) '())
                     (if run? 'X3 'X4)))
            (else (cant "left outside serving or stopping" ev)))))))

  ;; Stop: S1-S4 ------------------------------------------------------

  (define (do-stop m ev)
    (let ((own? (cadr ev)) (phase (m-phase m)) (slots (m-slots m)))
      (unless (boolean? own?) (cant "malformed stop" ev))
      (case phase
        ((serving stopping stopped)
         (cond
          (own? (values m 'refused '() 'S4))
          ((eq? phase 'serving)
           (values (stopped-machine m slots #f #f) 'wait
                   (stop-effects m slots) 'S1))
          ((eq? phase 'stopping) (values m 'wait '() 'S2))
          (else
           (let loop ((rs (m-raises m)))
             (cond ((null? rs) (values m (list 'stopped #f) '() 'S3))
                   ((eq? (car (car rs)) 'tear-down)
                    (values m (list 'stopped (caddr (car rs))) '() 'S3))
                   (else (loop (cdr rs))))))))
        (else (cant "stop in starting, failing or failed" ev)))))

  ;; Torn down: T1-T4 -------------------------------------------------

  (define (do-torn-down m ev)
    (let* ((slots (m-slots m)) (n (vector-length slots)) (t (cadr ev))
           (o (caddr ev)) (phase (m-phase m)))
      (unless (thread-ok? t n) (cant "torn-down for a thread out of range" ev))
      (unless (outcome? o) (cant "malformed outcome" ev))
      (unless (and (memq phase '(failing stopping))
                   (eq? (slot-at slots t) 'tearing-down))
        (cant "torn-down outside failing or stopping, or not tearing down" ev))
      (let ((raises (if (eq? o 'returned)
                        (m-raises m)
                        (insert-raise (m-raises m) (list 'tear-down t o))))
            (v (with-slot slots t 'ended))
            (live (other? slots t live?)))
        (if (eq? phase 'failing)
            (if live
                (values (rebuild m 'failing v (m-qf m) (m-qb m) (m-qn m)
                                 raises)
                        'end '() 'T1)
                (values (rebuild m 'failed v (m-qf m) (m-qb m) (m-qn m)
                                 raises)
                        'end '((wake-waiters)) 'T2))
            (if live
                (values (rebuild m 'stopping v (m-qf m) (m-qb m) (m-qn m)
                                 raises)
                        'end '() 'T3)
                (values (rebuild m 'stopped v (m-qf m) (m-qb m) (m-qn m)
                                 raises)
                        'end '((wake-waiters)) 'T4))))))
)
