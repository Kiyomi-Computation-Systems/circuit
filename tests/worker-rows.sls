#!r6rs
;;; (worker-rows): the worker machine's rows as data, and `classify`, which
;;; says which row (or which can't-happen cell) a machine and an event fall
;;; in. Test-only. Written from the tables, never from the machine's step.
;;;
;;; An entry is a list:
;;;   (row ID KIND PHASES WHERE NEXT)
;;;   (cell REASON KIND PHASES WHERE)
;;; KIND is the event's tag, PHASES the phases it applies in, WHERE a list of
;;; (FEATURE VALUE ...) constraints, all of which must hold (a feature not
;;; named is free), and NEXT the phase the row moves to, or `same`.
;;;
;;; The features per event kind are in `feature-space`. They are the facts
;;; the guards read; classify computes them from the machine's accessors.
(library (worker-rows)
  (export row-ids rows cells all-phases slot-kinds event-kinds
          feature-space feasible? classify features-of
          entry-matches? entry-row? row-id row-kind row-phases row-where
          row-next cell-reason cell-kind cell-phases cell-where)
  (import (rnrs)
          (circuit worker machine))

  (define all-phases '(starting failing serving stopping stopped failed))

  ;; slot-kinds : (Listof Symbol)
  (define slot-kinds
    '(unborn setting-up idle given running dropping tearing-down ended))

  ;; event-kinds : (Listof Symbol)
  (define event-kinds
    '(fork fork-raised look set-up call abandon next end left stop torn-down))

  (define (but . ps)
    (filter (lambda (p) (not (memq p ps))) all-phases))
  (define (slots-but . ks)
    (filter (lambda (k) (not (memq k ks))) slot-kinds))

  (define (row id kind phases where next) (list 'row id kind phases where next))
  (define (cell reason kind phases where) (list 'cell reason kind phases where))

  ;; entry-row? : Entry -> Boolean
  (define (entry-row? e) (eq? (car e) 'row))
  ;; row-id : Row-Entry -> Symbol
  (define (row-id e) (list-ref e 1))
  ;; row-kind : Row-Entry -> Symbol
  (define (row-kind e) (list-ref e 2))
  ;; row-phases : Row-Entry -> (Listof Symbol)
  (define (row-phases e) (list-ref e 3))
  ;; row-where : Row-Entry -> (Listof (Listof Any))
  (define (row-where e) (list-ref e 4))
  ;; row-next : Row-Entry -> Symbol
  (define (row-next e) (list-ref e 5))
  ;; cell-reason : Cell-Entry -> String
  (define (cell-reason e) (list-ref e 1))
  ;; cell-kind : Cell-Entry -> Symbol
  (define (cell-kind e) (list-ref e 2))
  ;; cell-phases : Cell-Entry -> (Listof Symbol)
  (define (cell-phases e) (list-ref e 3))
  ;; cell-where : Cell-Entry -> (Listof (Listof Any))
  (define (cell-where e) (list-ref e 4))

  (define (entry-kind e) (if (entry-row? e) (row-kind e) (cell-kind e)))
  (define (entry-phases e) (if (entry-row? e) (row-phases e) (cell-phases e)))
  (define (entry-where e) (if (entry-row? e) (row-where e) (cell-where e)))

  ;; entry-matches? : Entry Symbol Symbol (Listof (Pair Symbol Any)) -> Boolean
  ;; the entry's kind, phase and every constraint hold for these features
  (define (entry-matches? e kind phase fv)
    (and (eq? (entry-kind e) kind)
         (and (memq phase (entry-phases e)) #t)
         (for-all
          (lambda (c)
            (let ((p (assq (car c) fv)))
              (and p (and (member (cdr p) (cdr c)) #t))))
          (entry-where e))))

  ;; feature-space : Symbol -> (Listof (Pair Symbol (Listof Any)))
  ;; each feature an event kind's guards read, and its values
  (define (feature-space kind)
    (case kind
      ((fork) '((born #t #f)))
      ((look) '((start-raise #t #f)))
      ((fork-raised) '((born #t #f) (idx low one many high)))
      ((set-up)
       `((slot-t . ,slot-kinds) (other-setting-up #t #f) (other-live #t #f)
         (outcome returned bad)))
      ((call) '((idle #t #f) (at-cap #t #f)))
      ((abandon) '((where queued given running dropping gone)
                   (queue-empty #t #f)))
      ((next left) `((slot-t . ,slot-kinds)))
      ((end) `((slot-t . ,slot-kinds) (queue-empty #t #f)))
      ((stop) '((own #t #f)))
      ((torn-down) `((slot-t . ,slot-kinds) (other-live #t #f)))
      (else (assertion-violation 'feature-space "unknown kind" kind))))

  ;; feasible? : Symbol (Listof (Pair Symbol Any)) -> Boolean
  ;; a feature combination some machine could show: a slot setting-up is live,
  ;; and a queued ticket makes the queue non-empty
  (define (feasible? kind fv)
    (define (f n) (cdr (assq n fv)))
    (case kind
      ((set-up) (or (not (f 'other-setting-up)) (f 'other-live)))
      ((abandon) (or (not (eq? (f 'where) 'queued)) (not (f 'queue-empty))))
      (else #t)))

  ;; ---- the rows, in the design's order --------------------------------

  (define rows
    (list
     ;; Fork
     (row 'F1 'fork '(starting) '((born #f)) 'same)
     (row 'F2 'fork-raised '(starting) '((born #f) (idx many)) 'failing)
     (row 'F3 'fork-raised '(starting) '((born #f) (idx one)) 'failed)
     ;; Look
     (row 'K1 'look '(starting failing) '() 'same)
     (row 'K2 'look '(serving) '() 'same)
     (row 'K3 'look '(failed) '((start-raise #t)) 'same)
     ;; Set-up
     (row 'U1 'set-up '(starting)
          '((slot-t setting-up) (outcome returned) (other-setting-up #t)) 'same)
     (row 'U2 'set-up '(starting)
          '((slot-t setting-up) (outcome returned) (other-setting-up #f))
          'serving)
     (row 'U3 'set-up '(starting)
          '((slot-t setting-up) (outcome bad) (other-live #t)) 'failing)
     (row 'U4 'set-up '(starting)
          '((slot-t setting-up) (outcome bad) (other-live #f)) 'failed)
     (row 'U5 'set-up '(failing)
          '((slot-t setting-up) (outcome returned)) 'same)
     (row 'U6 'set-up '(failing)
          '((slot-t setting-up) (outcome bad) (other-live #t)) 'same)
     (row 'U7 'set-up '(failing)
          '((slot-t setting-up) (outcome bad) (other-live #f)) 'failed)
     ;; Call
     (row 'C1 'call '(serving) '((idle #t)) 'same)
     (row 'C2 'call '(serving) '((idle #f) (at-cap #f)) 'same)
     (row 'C3 'call '(serving) '((idle #f) (at-cap #t)) 'same)
     (row 'C4 'call '(stopping stopped) '() 'same)
     ;; Abandon
     (row 'A1 'abandon '(serving) '((where queued)) 'same)
     (row 'A2 'abandon '(serving) '((where given) (queue-empty #f)) 'same)
     (row 'A3 'abandon '(serving) '((where given) (queue-empty #t)) 'same)
     (row 'A4 'abandon '(serving stopping) '((where running)) 'same)
     (row 'A5 'abandon '(serving stopping stopped) '((where gone)) 'same)
     ;; Next
     (row 'N1 'next '(starting serving) '((slot-t idle)) 'same)
     (row 'N2 'next '(serving) '((slot-t given)) 'same)
     (row 'N3 'next '(failing stopping) '((slot-t tearing-down)) 'same)
     ;; End
     (row 'E1 'end '(serving) '((slot-t running) (queue-empty #f)) 'same)
     (row 'E2 'end '(serving) '((slot-t running) (queue-empty #t)) 'same)
     (row 'E3 'end '(serving) '((slot-t dropping) (queue-empty #f)) 'same)
     (row 'E4 'end '(serving) '((slot-t dropping) (queue-empty #t)) 'same)
     (row 'E5 'end '(stopping) '((slot-t running)) 'same)
     (row 'E6 'end '(stopping) '((slot-t dropping)) 'same)
     ;; Left
     (row 'X1 'left '(serving) '((slot-t running)) 'stopping)
     (row 'X2 'left '(serving) '((slot-t dropping)) 'stopping)
     (row 'X3 'left '(stopping) '((slot-t running)) 'same)
     (row 'X4 'left '(stopping) '((slot-t dropping)) 'same)
     ;; Stop
     (row 'S1 'stop '(serving) '((own #f)) 'stopping)
     (row 'S2 'stop '(stopping) '((own #f)) 'same)
     (row 'S3 'stop '(stopped) '((own #f)) 'same)
     (row 'S4 'stop '(serving stopping stopped) '((own #t)) 'same)
     ;; Torn down
     (row 'T1 'torn-down '(failing) '((slot-t tearing-down) (other-live #t))
          'same)
     (row 'T2 'torn-down '(failing) '((slot-t tearing-down) (other-live #f))
          'failed)
     (row 'T3 'torn-down '(stopping) '((slot-t tearing-down) (other-live #t))
          'same)
     (row 'T4 'torn-down '(stopping) '((slot-t tearing-down) (other-live #f))
          'stopped)))

  ;; row-ids : (Listof Symbol)
  (define row-ids (map row-id rows))

  ;; ---- the can't-happen cells -----------------------------------------

  (define cells
    (list
     (cell "a fork outside starting" 'fork (but 'starting) '())
     (cell "a fork outside starting" 'fork-raised (but 'starting) '())
     (cell "the maker forks once, while every slot is unborn" 'fork
           '(starting) '((born #t)))
     (cell "the maker forks once, while every slot is unborn" 'fork-raised
           '(starting) '((born #t)))
     (cell "fork i is outside 1..n" 'fork-raised '(starting)
           '((born #f) (idx low high)))
     (cell "no one holds the worker before K2: a look in stopping or stopped"
           'look '(stopping stopped) '())
     (cell "failed is reached only through a kept fork or set-up raise" 'look
           '(failed) '((start-raise #f)))
     (cell "a set-up in any phase but starting and failing" 'set-up
           '(serving stopping stopped failed) '())
     (cell "the set-up's thread has a slot that isn't setting-up" 'set-up
           '(starting failing) `((slot-t ,@(slots-but 'setting-up))))
     (cell "no worker has been given out in starting, failing or failed"
           'call '(starting failing failed) '())
     (cell "no abandon in starting, failing or failed" 'abandon
           '(starting failing failed) '())
     (cell "the stop empties the queue and tells every given job" 'abandon
           '(stopping) '((where queued given)))
     (cell "in stopped every slot has ended and the queue is empty" 'abandon
           '(stopped) '((where queued given running dropping)))
     (cell "k is dropping already: a wait raises once" 'abandon
           '(serving stopping) '((where dropping)))
     (cell "a thread steps next only between jobs" 'next
           '(starting failing serving stopping)
           '((slot-t unborn setting-up running dropping ended)))
     (cell "an idle slot is moved to tearing-down by U3, S1 and X1" 'next
           '(failing stopping) '((slot-t idle)))
     (cell "a given slot is moved to tearing-down by S1 and X1" 'next
           '(starting failing stopping) '((slot-t given)))
     (cell "a tearing-down slot only comes from a stop, a failure or a left job"
           'next '(starting serving) '((slot-t tearing-down)))
     (cell "every slot has ended in stopped or failed" 'next
           '(stopped failed) '())
     (cell "a slot runs a job only in serving or stopping" 'end
           '(starting failing stopped failed) '())
     (cell "the thread's slot is neither running nor dropping" 'end
           '(serving stopping)
           `((slot-t ,@(slots-but 'running 'dropping))))
     (cell "a slot runs a job only in serving or stopping" 'left
           '(starting failing stopped failed) '())
     (cell "the thread's slot is neither running nor dropping" 'left
           '(serving stopping)
           `((slot-t ,@(slots-but 'running 'dropping))))
     (cell "a stop in starting, failing or failed" 'stop
           '(starting failing failed) '())
     (cell "every tearing-down slot comes from a stop, a failure or a left job"
           'torn-down '(starting serving stopped failed) '())
     (cell "the thread's slot isn't tearing-down" 'torn-down
           '(failing stopping) `((slot-t ,@(slots-but 'tearing-down))))))

  ;; ---- features -------------------------------------------------------

  (define (exact-int? x) (and (integer? x) (exact? x)))
  (define (slot-kind s) (if (pair? s) (car s) s))
  (define (slot-live? s) (not (eq? (slot-kind s) 'ended)))
  (define (valid-outcome? o)
    (or (eq? o 'returned) (eq? o 'left)
        (and (pair? o) (eq? (car o) 'raised) (pair? (cdr o)) (null? (cddr o)))))
  (define (outcome-class o) (if (eq? o 'returned) 'returned 'bad))

  ;; the slots but t's
  (define (others slots t)
    (let loop ((s slots) (i 1) (acc '()))
      (cond ((null? s) (reverse acc))
            ((= i t) (loop (cdr s) (+ i 1) acc))
            (else (loop (cdr s) (+ i 1) (cons (car s) acc))))))

  ;; features-of : Machine Any -> (U #f (Pair Symbol (Listof (Pair Symbol Any))))
  ;; the event's kind and its features, or #f for a malformed event
  (define (features-of m ev)
    (let* ((slots (machine-slots m))
           (n (length slots))
           (queue (machine-queue m))
           (cap (machine-cap m))
           (born (and (exists (lambda (s) (not (eq? s 'unborn))) slots) #t)))
      (define (valid-t? t) (and (exact-int? t) (<= 1 t n)))
      (define (slot-of t) (slot-kind (list-ref slots (- t 1))))
      (define (arity? k) (and (list? ev) (= (length ev) k)))
      (and (pair? ev) (list? ev) (symbol? (car ev))
           (case (car ev)
             ((fork) (and (arity? 1) (list 'fork (cons 'born born))))
             ((fork-raised)
              (and (arity? 3) (exact-int? (cadr ev))
                   (let ((i (cadr ev)))
                     (list 'fork-raised
                           (cons 'born born)
                           (cons 'idx
                                 (cond ((< i 1) 'low) ((= i 1) 'one)
                                       ((<= i n) 'many) (else 'high)))))))
             ((look)
              (and (arity? 1)
                   (list 'look
                         (cons 'start-raise
                               (and (exists (lambda (r) (memq (car r) '(fork set-up)))
                                            (machine-raises m))
                                    #t)))))
             ((set-up)
              (and (arity? 3) (valid-t? (cadr ev)) (valid-outcome? (caddr ev))
                   (let ((rest (others slots (cadr ev))))
                     (list 'set-up
                           (cons 'slot-t (slot-of (cadr ev)))
                           (cons 'other-setting-up
                                 (and (memq 'setting-up (map slot-kind rest)) #t))
                           (cons 'other-live
                                 (and (exists slot-live? rest) #t))
                           (cons 'outcome (outcome-class (caddr ev)))))))
             ((call)
              (and (arity? 2)
                   (list 'call
                         (cons 'idle
                               (and (memq 'idle (map slot-kind slots)) #t))
                         (cons 'at-cap (>= (length queue) cap)))))
             ((abandon)
              (and (arity? 2)
                   (let* ((k (cadr ev))
                          (w (cond
                              ((memq k queue) 'queued)
                              (else
                               (let loop ((s slots))
                                 (cond
                                  ((null? s) 'gone)
                                  ((and (pair? (car s)) (pair? (cdr (car s)))
                                        (memq (car (car s))
                                              '(given running dropping))
                                        (eq? (cadr (car s)) k))
                                   (car (car s)))
                                  (else (loop (cdr s)))))))))
                     (list 'abandon (cons 'where w)
                           (cons 'queue-empty (null? queue))))))
             ((next)
              (and (arity? 2) (valid-t? (cadr ev))
                   (list 'next (cons 'slot-t (slot-of (cadr ev))))))
             ((end)
              (and (arity? 3) (valid-t? (cadr ev))
                   (list 'end (cons 'slot-t (slot-of (cadr ev)))
                         (cons 'queue-empty (null? queue)))))
             ((left)
              (and (arity? 2) (valid-t? (cadr ev))
                   (list 'left (cons 'slot-t (slot-of (cadr ev))))))
             ((stop)
              (and (arity? 2) (boolean? (cadr ev))
                   (list 'stop (cons 'own (cadr ev)))))
             ((torn-down)
              (and (arity? 3) (valid-t? (cadr ev)) (valid-outcome? (caddr ev))
                   (list 'torn-down
                         (cons 'slot-t (slot-of (cadr ev)))
                         (cons 'other-live
                               (and (exists slot-live? (others slots (cadr ev)))
                                    #t)))))
             (else #f)))))

  ;; classify : Machine Event -> (U Row 'cant-happen)
  ;; the row the table selects for this machine and event, or 'cant-happen for
  ;; a case the table marks so and for any malformed event. A point that no
  ;; entry, or more than one, matches is the table's own fault, and raises.
  (define (classify m ev)
    (let ((kf (features-of m ev)) (phase (machine-phase m)))
      (if kf
          (let ((hits (filter (lambda (e)
                                (entry-matches? e (car kf) phase (cdr kf)))
                              (append rows cells))))
            (cond ((or (null? hits) (pair? (cdr hits)))
                   (assertion-violation 'classify
                                        "not matched by exactly one row or cell"
                                        phase ev (length hits)))
                  ((entry-row? (car hits)) (row-id (car hits)))
                  (else 'cant-happen)))
          'cant-happen))))
