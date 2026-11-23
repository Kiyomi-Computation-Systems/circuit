#!r6rs
;;; The worker machine's tables, held two ways.
;;;
;;; Layer 1, the tables as data (tests/worker-rows.sls): every (phase, event
;;; kind, feature combination) of the enumerated cross falls in exactly one
;;; row or one can't-happen cell; every phase is reachable from starting along
;;; the rows' moves, and stopped or failed from every phase; every cell has a
;;; reason; the row ids are the 43 rows, each once.
;;;
;;; Layer 2, the machine driven against the tables: each row from a synthetic
;;; state, the whole result compared with a hand-written one; each row whose
;;; changes are none answers the machine it was given; classify names the same
;;; row; every point of the cross is built as a machine and an event, and step
;;; answers its row, or raises an assertion for a can't-happen cell; the
;;; constructors' refusals, each limit held from both sides.
;;;
;;; Oracle: the tables written out by hand below and in worker-rows.sls.
(import (rnrs)
        (srfi :64)
        (only (chezscheme) statistics sstats-bytes)
        (circuit-testing)
        (circuit worker machine)
        (worker-rows))

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

(test-begin "worker-table")

;; ---------------------------------------------------------------------
;; Layer 1
;; ---------------------------------------------------------------------

(define design-row-ids
  '(F1 F2 F3 K1 K2 K3 U1 U2 U3 U4 U5 U6 U7 C1 C2 C3 C4 A1 A2 A3 A4 A5
    N1 N2 N3 E1 E2 E3 E4 E5 E6 X1 X2 X3 X4 S1 S2 S3 S4 T1 T2 T3 T4))

(test-equal "43 design rows" 43 (length design-row-ids))
(test-equal "row-ids are the design's rows, in order" design-row-ids row-ids)
(test-equal "the rows' own ids are row-ids" row-ids (map row-id rows))

;; product : (Listof (Pair Symbol (Listof Any))) -> (Listof Alist)
(define (product space)
  (if (null? space)
      '(())
      (let ((rest (product (cdr space))))
        (apply append
               (map (lambda (v)
                      (map (lambda (r) (cons (cons (car (car space)) v) r))
                           rest))
                    (cdr (car space)))))))

;; cross : -> (Listof (List Symbol Symbol Alist))   (kind phase features)
(define cross
  (apply append
         (map (lambda (kind)
                (apply append
                       (map (lambda (phase)
                              (map (lambda (fv) (list kind phase fv))
                                   (filter (lambda (fv) (feasible? kind fv))
                                           (product (feature-space kind)))))
                            all-phases)))
              event-kinds)))

(define all-entries (append rows cells))

;; hits : Symbol Symbol Alist -> (Listof Entry)
(define (hits kind phase fv)
  (filter (lambda (e) (entry-matches? e kind phase fv)) all-entries))

(define (entry-name e) (if (entry-row? e) (row-id e) (list 'cant (cell-reason e))))

;; Each point not matched exactly once, as (kind phase features names).
(define cross-failures
  (filter values
          (map (lambda (pt)
                 (let ((h (hits (car pt) (cadr pt) (caddr pt))))
                   (and (not (= (length h) 1))
                        (list (car pt) (cadr pt) (caddr pt) (map entry-name h)))))
               cross)))

(for-each (lambda (f) (display "  cross: ") (write f) (newline)) cross-failures)
(display "  the cross has ") (display (length cross)) (display " points")
(newline)

(test-equal "every point of the cross is matched by exactly one row or cell"
  '() cross-failures)

(test-assert "the cross is not trivially small" (> (length cross) 500))

(let ((missing (filter (lambda (id) (not (memq id design-row-ids))) row-ids)))
  (test-equal "no row but the design's" '() missing))

;; Every row matches some point of the cross (no dead row).
(test-equal "every row is the answer of some point of the cross"
  '()
  (filter (lambda (id)
            (not (exists (lambda (pt)
                           (let ((h (hits (car pt) (cadr pt) (caddr pt))))
                             (and (pair? h) (entry-row? (car h))
                                  (eq? (row-id (car h)) id))))
                         cross)))
          row-ids))

;; Phase moves.
(define (next-phase e phase)
  (if (eq? (row-next e) 'same) phase (row-next e)))

(define (reachable-from start)
  (let loop ((seen (list start)) (todo (list start)))
    (if (null? todo)
        seen
        (let* ((p (car todo))
               (nexts (apply append
                             (map (lambda (e)
                                    (if (memq p (row-phases e))
                                        (list (next-phase e p))
                                        '()))
                                  rows)))
               (new (filter (lambda (q) (not (memq q seen))) nexts))
               (new (let dedupe ((l new) (acc '()))
                      (cond ((null? l) (reverse acc))
                            ((memq (car l) acc) (dedupe (cdr l) acc))
                            (else (dedupe (cdr l) (cons (car l) acc)))))))
          (loop (append seen new) (append (cdr todo) new))))))

(define (sort-phases l)
  (filter (lambda (p) (memq p l)) all-phases))

(test-equal "every phase is reachable from starting"
  all-phases (sort-phases (reachable-from 'starting)))

(for-each
 (lambda (p)
   (let ((r (reachable-from p)))
     (test-equal (string-append "stopped or failed is reachable from "
                                (symbol->string p))
       #t (and (or (memq 'stopped r) (memq 'failed r)) #t))))
 all-phases)

(test-equal "stopped and failed move nowhere"
  '((stopped) (failed))
  (list (sort-phases (reachable-from 'stopped))
        (sort-phases (reachable-from 'failed))))

(test-equal "every can't-happen cell carries a reason" '()
  (filter (lambda (c) (not (and (string? (cell-reason c))
                                (> (string-length (cell-reason c)) 0))))
          cells))

;; ---------------------------------------------------------------------
;; Layer 2: helpers
;; ---------------------------------------------------------------------

(define (M phase slots queue cap raises)
  (make-machine phase slots queue cap raises))

;; snap : Machine Reply Effects Row -> List
(define (snap m reply effects row)
  (list (machine-phase m) (machine-slots m) (machine-queue m) (machine-cap m)
        (machine-raises m) reply effects row))

;; The outcome of a thunk: what it raised (an assertion, with its who), or
;; the sentinel no-raise.
(define (outcome thunk)
  (guard (c ((and (assertion-violation? c) (who-condition? c))
             (list 'assertion (condition-who c)))
            (#t (list 'other (describe c))))
    (thunk)
    'no-raise))

(define (step-of m ev)
  (call-with-values (lambda () (step/row m ev)) list))

;; tickets: distinct strings, never eq? to each other
(define ta (string-copy "ticket-alpha"))
(define tb (string-copy "ticket-bravo"))
(define tc (string-copy "ticket-charlie"))
(define td (string-copy "ticket-delta"))
(define te (string-copy "ticket-echo"))
(define tf (string-copy "ticket-foxtrot"))
(define tg (string-copy "ticket-golf"))
(define th (string-copy "ticket-hotel"))
(define rv (list 'ok "result-value" 7))
(define big (expt 2 100))

;; unchanged : Machine Reply Effects Row -> List
(define (unchanged m reply effects row) (snap m reply effects row))

(define-syntax row-case
  (syntax-rules ()
    ((_ label id machine event expected same?)
     (list label 'id (lambda () (cons machine 'event)) (lambda () expected)
           same?))))
(define-syntax row-case/ev
  (syntax-rules ()
    ((_ label id machine event expected same?)
     (list label 'id (lambda () (cons machine event)) (lambda () expected)
           same?))))

;; Each case: label, row id, (-> (Pair Machine Event)), (-> Expected), same?
(define cases
  (list
   ;; F
   (row-case "F1" F1 (M 'starting '(unborn unborn unborn) '() big '())
             (fork)
             `(starting (setting-up setting-up setting-up) () ,big () wait () F1)
             #f)
   (row-case "F2 i=2" F2 (M 'starting '(unborn unborn unborn) '() 5 '())
             (fork-raised 2 "boom2")
             '(failing (setting-up ended ended) () 5
                       ((fork 2 (raised "boom2"))) wait () F2)
             #f)
   (row-case "F2 i=3 (n)" F2 (M 'starting '(unborn unborn unborn) '() 5 '())
             (fork-raised 3 "boom3")
             '(failing (setting-up setting-up ended) () 5
                       ((fork 3 (raised "boom3"))) wait () F2)
             #f)
   (row-case "F3" F3 (M 'starting '(unborn unborn unborn) '() 5 '())
             (fork-raised 1 "boom1")
             '(failed (ended ended ended) () 5 ((fork 1 (raised "boom1")))
                      (failed (raised "boom1")) () F3)
             #f)
   (row-case "F3 one thread" F3 (M 'starting '(unborn) '() 0 '())
             (fork-raised 1 "boom1")
             '(failed (ended) () 0 ((fork 1 (raised "boom1")))
                      (failed (raised "boom1")) () F3)
             #f)
   ;; K
   (let ((m (M 'starting '(setting-up idle setting-up) '() 2 '())))
     (row-case/ev "K1 starting" K1 m '(look) (unchanged m 'wait '() 'K1) #t))
   (let ((m (M 'failing '(tearing-down setting-up ended) '() 2
               '((set-up 3 (raised "x"))))))
     (row-case/ev "K1 failing" K1 m '(look) (unchanged m 'wait '() 'K1) #t))
   (let ((m (M 'serving '(idle (running "r") idle) '() 2 '())))
     (row-case/ev "K2" K2 m '(look) (unchanged m 'ready '() 'K2) #t))
   (let ((m (M 'failed '(ended ended ended) '() 2
               '((set-up 2 (raised "low")) (set-up 3 (raised "high"))))))
     (row-case/ev "K3 lowest thread's raise" K3 m '(look)
                  (unchanged m '(failed (raised "low")) '() 'K3) #t))
   (let ((m (M 'failed '(ended ended ended) '() 2
               '((fork 2 (raised "forked")) (set-up 3 left)))))
     (row-case/ev "K3 fork raise on the lowest" K3 m '(look)
                  (unchanged m '(failed (raised "forked")) '() 'K3) #t))
   (let ((m (M 'failed '(ended ended ended) '() 2
               '((set-up 1 left) (set-up 2 (raised "z"))))))
     (row-case/ev "K3 left on the lowest" K3 m '(look)
                  (unchanged m '(failed left) '() 'K3) #t))
   (let ((m (M 'failed '(ended ended ended) '() 2
               '((tear-down 1 (raised "td")) (set-up 2 (raised "su"))))))
     (row-case/ev "K3 skips tear-down raises" K3 m '(look)
                  (unchanged m '(failed (raised "su")) '() 'K3) #t))
   (let ((m (M 'failed '(ended ended ended) '() 2
               '((set-up 1 (raised "one")) (set-up 2 (raised "two"))
                 (set-up 3 (raised "three"))))))
     (row-case/ev "K3 three raises" K3 m '(look)
                  (unchanged m '(failed (raised "one")) '() 'K3) #t))
   ;; U
   (row-case "U1" U1 (M 'starting '(setting-up setting-up idle) '() 4 '())
             (set-up 2 returned)
             '(starting (setting-up idle idle) () 4 () wait () U1) #f)
   (row-case "U1 other setting-up is thread 3" U1
             (M 'starting '(idle setting-up setting-up) '() 4 '())
             (set-up 2 returned)
             '(starting (idle idle setting-up) () 4 () wait () U1) #f)
   (row-case "U2" U2 (M 'starting '(idle setting-up idle) '() 4 '())
             (set-up 2 returned)
             '(serving (idle idle idle) () 4 () wait ((wake-waiters)) U2) #f)
   (row-case "U3 raised" U3 (M 'starting '(idle setting-up idle) '() 4 '())
             (set-up 2 (raised "su2"))
             '(failing (tearing-down ended tearing-down) () 4
                       ((set-up 2 (raised "su2"))) end ((signal 1) (signal 3))
                       U3)
             #f)
   (row-case "U3 left, a setting-up slot stays" U3
             (M 'starting '(setting-up setting-up idle) '() 4 '())
             (set-up 2 left)
             '(failing (setting-up ended tearing-down) () 4 ((set-up 2 left))
                       end ((signal 3)) U3)
             #f)
   (row-case "U4 raised" U4 (M 'starting '(ended setting-up ended) '() 4 '())
             (set-up 2 (raised "su2"))
             '(failed (ended ended ended) () 4 ((set-up 2 (raised "su2"))) end
                      ((wake-waiters)) U4)
             #f)
   (row-case "U4 left, one thread" U4 (M 'starting '(setting-up) '() 4 '())
             (set-up 1 left)
             '(failed (ended) () 4 ((set-up 1 left)) end ((wake-waiters)) U4)
             #f)
   (row-case "U5" U5 (M 'failing '(setting-up setting-up ended) '() 4
                        '((fork 3 (raised "f3"))))
             (set-up 1 returned)
             '(failing (tearing-down setting-up ended) () 4
                       ((fork 3 (raised "f3"))) tear-down () U5)
             #f)
   (row-case "U6 left" U6 (M 'failing '(tearing-down setting-up ended) '() 4 '())
             (set-up 2 left)
             '(failing (tearing-down ended ended) () 4 ((set-up 2 left)) end ()
                       U6)
             #f)
   (row-case "U6 raise kept in thread order" U6
             (M 'failing '(tearing-down setting-up ended) '() 4
                '((set-up 3 (raised "p3"))))
             (set-up 2 (raised "su2"))
             '(failing (tearing-down ended ended) () 4
                       ((set-up 2 (raised "su2")) (set-up 3 (raised "p3")))
                       end () U6)
             #f)
   (row-case "U7" U7 (M 'failing '(ended ended setting-up) '() 4
                        '((set-up 1 (raised "s1"))))
             (set-up 3 (raised "s3"))
             '(failed (ended ended ended) () 4
                      ((set-up 1 (raised "s1")) (set-up 3 (raised "s3")))
                      end ((wake-waiters)) U7)
             #f)
   ;; C
   (row-case/ev "C1" C1
                (M 'serving `((running ,tc) idle idle) '() 2 '())
                `(call ,ta)
                `(serving ((running ,tc) (given ,ta) idle) () 2 () accepted
                          ((signal 2)) C1)
                #f)
   (row-case/ev "C1 lowest idle is the last" C1
                (M 'serving `((dropping ,td) (running ,tc) idle) '() 2 '())
                `(call ,ta)
                `(serving ((dropping ,td) (running ,tc) (given ,ta)) () 2 ()
                          accepted ((signal 3)) C1)
                #f)
   (row-case/ev "C1 idle slots, a queue already" C1
                (M 'serving `(idle idle) (list tb) 2 '())
                `(call ,ta)
                `(serving ((given ,ta) idle) (,tb) 2 () accepted ((signal 1))
                          C1)
                #f)
   (row-case/ev "C2" C2
                (M 'serving `((running ,tc) (running ,td) (dropping ,te))
                   (list tb) 3 '())
                `(call ,ta)
                `(serving ((running ,tc) (running ,td) (dropping ,te))
                          (,tb ,ta) 3 () accepted () C2)
                #f)
   (row-case/ev "C2 bignum cap" C2
                (M 'serving `((running ,tc)) (list tb) big '())
                `(call ,ta)
                `(serving ((running ,tc)) (,tb ,ta) ,big () accepted () C2)
                #f)
   (let ((m (M 'serving `((running ,tc) (running ,td)) (list tb) 1 '())))
     (row-case/ev "C3 queue at cap" C3 m `(call ,ta)
                  (unchanged m 'full '() 'C3) #t))
   (let ((m (M 'serving `((running ,tc)) '() 0 '())))
     (row-case/ev "C3 cap 0" C3 m `(call ,ta) (unchanged m 'full '() 'C3) #t))
   (let ((m (M 'stopping `(tearing-down (running ,tc) ended) '() 2 '())))
     (row-case/ev "C4 stopping" C4 m `(call ,ta)
                  (unchanged m 'stopped '() 'C4) #t))
   (let ((m (M 'stopped '(ended ended ended) '() 2
               '((tear-down 2 (raised "t"))))))
     (row-case/ev "C4 stopped" C4 m `(call ,ta)
                  (unchanged m 'stopped '() 'C4) #t))
   ;; A
   (row-case/ev "A1 middle" A1
                (M 'serving `((running ,tc) (running ,td) (running ,te))
                   (list ta tb tf) 5 '())
                `(abandon ,tb)
                `(serving ((running ,tc) (running ,td) (running ,te)) (,ta ,tf)
                          5 () ok () A1)
                #f)
   (row-case/ev "A1 oldest" A1
                (M 'serving `((running ,tc) (running ,td) (running ,te))
                   (list ta tb tf) 5 '())
                `(abandon ,ta)
                `(serving ((running ,tc) (running ,td) (running ,te)) (,tb ,tf)
                          5 () ok () A1)
                #f)
   (row-case/ev "A1 newest" A1
                (M 'serving `((running ,tc) (running ,td) (running ,te))
                   (list ta tb tf) 5 '())
                `(abandon ,tf)
                `(serving ((running ,tc) (running ,td) (running ,te)) (,ta ,tb)
                          5 () ok () A1)
                #f)
   (row-case/ev "A2" A2
                (M 'serving `((running ,tc) (given ,ta) (running ,te))
                   (list tb tf) 5 '())
                `(abandon ,ta)
                `(serving ((running ,tc) (given ,tb) (running ,te)) (,tf) 5 ()
                          ok () A2)
                #f)
   (row-case/ev "A3" A3
                (M 'serving `((running ,tc) (given ,ta) (running ,te))
                   '() 5 '())
                `(abandon ,ta)
                `(serving ((running ,tc) idle (running ,te)) () 5 () ok () A3)
                #f)
   (row-case/ev "A4 serving" A4
                (M 'serving `(idle (running ,ta) (running ,te)) '() 5 '())
                `(abandon ,ta)
                `(serving (idle (dropping ,ta) (running ,te)) () 5 () ok () A4)
                #f)
   (row-case/ev "A4 stopping" A4
                (M 'stopping `(tearing-down (running ,ta) (dropping ,tc))
                   '() 5 '())
                `(abandon ,ta)
                `(stopping (tearing-down (dropping ,ta) (dropping ,tc)) () 5 ()
                           ok () A4)
                #f)
   (let ((m (M 'serving `((running ,tc) (running ,td) (running ,te))
               (list ta) 5 '())))
     (row-case/ev "A5 equal but not eq? to a queued ticket" A5 m
                  `(abandon ,(string-copy ta)) (unchanged m 'ok '() 'A5) #t))
   (let ((m (M 'serving `((given ,ta) (running ,td) (running ,te)) '() 5 '())))
     (row-case/ev "A5 equal but not eq? to a given ticket" A5 m
                  `(abandon ,(string-copy ta)) (unchanged m 'ok '() 'A5) #t))
   (let ((m (M 'serving `((running ,tc) idle (running ,te)) (list ta) 5 '())))
     (row-case/ev "A5 gone, serving" A5 m `(abandon ,tg)
                  (unchanged m 'ok '() 'A5) #t))
   (let ((m (M 'stopping `(tearing-down (running ,tc) ended) '() 5 '())))
     (row-case/ev "A5 gone, stopping" A5 m `(abandon ,tg)
                  (unchanged m 'ok '() 'A5) #t))
   (let ((m (M 'stopped '(ended ended ended) '() 5 '())))
     (row-case/ev "A5 gone, stopped" A5 m `(abandon ,tg)
                  (unchanged m 'ok '() 'A5) #t))
   ;; N
   (let ((m (M 'starting '(idle setting-up setting-up) '() 2 '())))
     (row-case/ev "N1 starting" N1 m '(next 1) (unchanged m 'wait '() 'N1) #t))
   (let ((m (M 'serving `((running ,tc) idle (dropping ,td)) '() 2 '())))
     (row-case/ev "N1 serving" N1 m '(next 2) (unchanged m 'wait '() 'N1) #t))
   (row-case/ev "N2" N2
                (M 'serving `(idle (given ,ta) idle) (list tb) 2 '())
                '(next 2)
                `(serving (idle (running ,ta) idle) (,tb) 2 () (run ,ta) () N2)
                #f)
   (row-case/ev "N2 last thread" N2
                (M 'serving `(idle idle (given ,ta)) '() 2 '())
                '(next 3)
                `(serving (idle idle (running ,ta)) () 2 () (run ,ta) () N2)
                #f)
   (let ((m (M 'failing '(tearing-down setting-up ended) '() 2 '())))
     (row-case/ev "N3 failing" N3 m '(next 1)
                  (unchanged m 'tear-down '() 'N3) #t))
   (let ((m (M 'stopping `((running ,tc) ended tearing-down) '() 2 '())))
     (row-case/ev "N3 stopping" N3 m '(next 3)
                  (unchanged m 'tear-down '() 'N3) #t))
   ;; E
   (row-case/ev "E1" E1
                (M 'serving `(idle (running ,ta) idle) (list tb tc) 4 '())
                `(end 2 ,rv)
                `(serving (idle (running ,tb) idle) (,tc) 4 () (run ,tb)
                          ((post ,ta ,rv)) E1)
                #f)
   (row-case/ev "E2" E2
                (M 'serving `(idle (running ,ta) idle) '() 4 '())
                `(end 2 ,rv)
                `(serving (idle idle idle) () 4 () wait ((post ,ta ,rv)) E2)
                #f)
   (row-case/ev "E3" E3
                (M 'serving `(idle (dropping ,ta) idle) (list tb tc) 4 '())
                `(end 2 ,rv)
                `(serving (idle (running ,tb) idle) (,tc) 4 () (run ,tb) () E3)
                #f)
   (row-case/ev "E4" E4
                (M 'serving `(idle (dropping ,ta) idle) '() 4 '())
                `(end 2 ,rv)
                `(serving (idle idle idle) () 4 () wait () E4)
                #f)
   (row-case/ev "E5" E5
                (M 'stopping `(tearing-down (running ,ta) ended) '() 4 '())
                `(end 2 ,rv)
                `(stopping (tearing-down tearing-down ended) () 4 () tear-down
                           ((post ,ta ,rv)) E5)
                #f)
   (row-case/ev "E6" E6
                (M 'stopping `(tearing-down (dropping ,ta) ended) '() 4 '())
                `(end 2 ,rv)
                `(stopping (tearing-down tearing-down ended) () 4 () tear-down
                           () E6)
                #f)
   ;; X: seven threads, a mix of every slot kind, a queue of two
   (row-case/ev "X1" X1
                (M 'serving `((given ,tb) idle (running ,ta) (dropping ,td)
                              (given ,te) (running ,tf) idle)
                   (list tg th) 6 '())
                '(left 3)
                `(stopping (tearing-down tearing-down tearing-down (dropping ,td)
                                         tearing-down (running ,tf)
                                         tearing-down)
                           () 6 () tear-down
                           ((post ,ta left) (post ,tb stopped) (post ,te stopped)
                            (post ,tg stopped) (post ,th stopped)
                            (signal 1) (signal 2) (signal 5) (signal 7))
                           X1)
                #f)
   (row-case/ev "X2" X2
                (M 'serving `((given ,tb) idle (dropping ,ta) (running ,td)
                              (given ,te) (running ,tf) idle)
                   (list tg th) 6 '())
                '(left 3)
                `(stopping (tearing-down tearing-down tearing-down (running ,td)
                                         tearing-down (running ,tf)
                                         tearing-down)
                           () 6 () tear-down
                           ((post ,tb stopped) (post ,te stopped)
                            (post ,tg stopped) (post ,th stopped)
                            (signal 1) (signal 2) (signal 5) (signal 7))
                           X2)
                #f)
   (row-case/ev "X3" X3
                (M 'stopping `(tearing-down (running ,ta) (dropping ,td)) '() 6
                   '())
                '(left 2)
                `(stopping (tearing-down tearing-down (dropping ,td)) () 6 ()
                           tear-down ((post ,ta left)) X3)
                #f)
   (row-case/ev "X4" X4
                (M 'stopping `(tearing-down (dropping ,ta) (running ,td)) '() 6
                   '())
                '(left 2)
                `(stopping (tearing-down tearing-down (running ,td)) () 6 ()
                           tear-down () X4)
                #f)
   ;; S
   (row-case/ev "S1" S1
                (M 'serving `((given ,ta) idle (running ,tb) (dropping ,tc)
                              (given ,td))
                   (list te tf) 4 '())
                '(stop #f)
                `(stopping (tearing-down tearing-down (running ,tb)
                                         (dropping ,tc) tearing-down)
                           () 4 () wait
                           ((post ,ta stopped) (post ,td stopped)
                            (post ,te stopped) (post ,tf stopped)
                            (signal 1) (signal 2) (signal 5))
                           S1)
                #f)
   (row-case/ev "S1 idle first, one given" S1
                (M 'serving `(idle (given ,ta) idle) '() 4 '())
                '(stop #f)
                `(stopping (tearing-down tearing-down tearing-down) () 4 ()
                           wait ((post ,ta stopped) (signal 1) (signal 2)
                                 (signal 3))
                           S1)
                #f)
   (row-case/ev "S1 only running jobs and a queue" S1
                (M 'serving `((running ,ta) (running ,tb)) (list tc td) 4 '())
                '(stop #f)
                `(stopping ((running ,ta) (running ,tb)) () 4 () wait
                           ((post ,tc stopped) (post ,td stopped)) S1)
                #f)
   (let ((m (M 'stopping `(tearing-down (running ,ta)) '() 4 '())))
     (row-case/ev "S2" S2 m '(stop #f) (unchanged m 'wait '() 'S2) #t))
   (let ((m (M 'stopped '(ended ended ended) '() 4
               '((tear-down 2 (raised "t2")) (tear-down 3 left)))))
     (row-case/ev "S3 lowest thread's raise" S3 m '(stop #f)
                  (unchanged m '(stopped (raised "t2")) '() 'S3) #t))
   (let ((m (M 'stopped '(ended ended ended) '() 4
               '((tear-down 1 left) (tear-down 3 (raised "t3"))))))
     (row-case/ev "S3 left on the lowest" S3 m '(stop #f)
                  (unchanged m '(stopped left) '() 'S3) #t))
   (let ((m (M 'stopped '(ended ended ended) '() 4
               '((set-up 1 (raised "su")) (tear-down 2 (raised "td"))))))
     (row-case/ev "S3 only tear-down raises" S3 m '(stop #f)
                  (unchanged m '(stopped (raised "td")) '() 'S3) #t))
   (let ((m (M 'stopped '(ended ended ended) '() 4 '())))
     (row-case/ev "S3 none" S3 m '(stop #f)
                  (unchanged m '(stopped #f) '() 'S3) #t))
   (let ((m (M 'serving `((running ,ta) idle) '() 4 '())))
     (row-case/ev "S4 serving" S4 m '(stop #t)
                  (unchanged m 'refused '() 'S4) #t))
   (let ((m (M 'stopping `(tearing-down (running ,ta)) '() 4 '())))
     (row-case/ev "S4 stopping" S4 m '(stop #t)
                  (unchanged m 'refused '() 'S4) #t))
   (let ((m (M 'stopped '(ended ended) '() 4 '())))
     (row-case/ev "S4 stopped" S4 m '(stop #t)
                  (unchanged m 'refused '() 'S4) #t))
   ;; T
   (row-case/ev "T1 raised" T1
                (M 'failing '(tearing-down tearing-down ended) '() 4 '())
                '(torn-down 2 (raised "td2"))
                '(failing (tearing-down ended ended) () 4
                          ((tear-down 2 (raised "td2"))) end () T1)
                #f)
   (row-case/ev "T1 returned keeps no raise" T1
                (M 'failing '(ended tearing-down tearing-down) '() 4
                   '((set-up 1 (raised "s1"))))
                '(torn-down 2 returned)
                '(failing (ended ended tearing-down) () 4
                          ((set-up 1 (raised "s1"))) end () T1)
                #f)
   (row-case/ev "T1 left" T1
                (M 'failing '(tearing-down tearing-down ended) '() 4 '())
                '(torn-down 1 left)
                '(failing (ended tearing-down ended) () 4
                          ((tear-down 1 left)) end () T1)
                #f)
   (row-case/ev "T2" T2
                (M 'failing '(ended tearing-down ended) '() 4
                   '((set-up 1 (raised "s1"))))
                '(torn-down 2 (raised "td2"))
                '(failed (ended ended ended) () 4
                         ((set-up 1 (raised "s1")) (tear-down 2 (raised "td2")))
                         end ((wake-waiters)) T2)
                #f)
   (row-case/ev "T3" T3
                (M 'stopping `(tearing-down tearing-down (running ,ta)) '() 4
                   '())
                '(torn-down 1 (raised "td1"))
                `(stopping (ended tearing-down (running ,ta)) () 4
                           ((tear-down 1 (raised "td1"))) end () T3)
                #f)
   (row-case/ev "T4" T4
                (M 'stopping '(ended tearing-down ended) '() 4
                   '((tear-down 3 (raised "t3"))))
                '(torn-down 2 (raised "td2"))
                '(stopped (ended ended ended) () 4
                          ((tear-down 2 (raised "td2"))
                           (tear-down 3 (raised "t3")))
                          end ((wake-waiters)) T4)
                #f)
   (row-case/ev "T4 returned" T4
                (M 'stopping '(ended tearing-down) '() 4 '())
                '(torn-down 2 returned)
                '(stopped (ended ended) () 4 () end ((wake-waiters)) T4)
                #f)))

;; Every row is driven at least once.
(test-equal "every one of the 43 rows has a driven case" '()
  (filter (lambda (id) (not (exists (lambda (c) (eq? (cadr c) id)) cases)))
          row-ids))

(for-each
 (lambda (c)
   (let ((label (string-append "row " (car c)))
         (id (cadr c)))
     ;; the whole result
     (test-equal label
       (guard (e (#t (list 'expected-raised (describe e)))) ((cadddr c)))
       (guard (e (#t (list 'raised (describe e))))
         (let* ((me ((caddr c)))
                (r (step-of (car me) (cdr me))))
           (snap (car r) (cadr r) (caddr r) (cadddr r)))))
     ;; step is step/row without the row
     (test-equal (string-append label ": step agrees")
       (guard (e (#t (list 'raised (describe e))))
         (let* ((me ((caddr c)))
                (r (step-of (car me) (cdr me))))
           (snap (car r) (cadr r) (caddr r) id)))
       (guard (e (#t (list 'raised (describe e))))
         (let* ((me ((caddr c))))
           (call-with-values (lambda () (step (car me) (cdr me)))
             (lambda (m2 reply effects) (snap m2 reply effects id))))))
     ;; same machine when the row changes nothing
     (when (list-ref c 4)
       (test-equal (string-append label ": the machine given is answered")
         #t
         (guard (e (#t (describe e)))
           (let* ((me ((caddr c)))
                  (r (step-of (car me) (cdr me))))
             (eq? (car me) (car r))))))
     ;; classify
     (test-equal (string-append label ": classify")
       id
       (guard (e (#t (list 'raised (describe e))))
         (let ((me ((caddr c)))) (classify (car me) (cdr me)))))))
 cases)

;; ---------------------------------------------------------------------
;; Layer 2: the whole cross, built as machines
;; ---------------------------------------------------------------------

;; build : Symbol Symbol Alist -> (Pair Machine Event)
(define (build kind phase fv)
  (define (f n) (cdr (assq n fv)))
  (define (slot-for k tk)
    (if (memq k '(given running dropping)) (list k tk) k))
  (define (mk slots queue cap) (M phase slots queue cap '()))
  (case kind
    ((fork) (cons (mk (if (f 'born) '(unborn setting-up unborn) '(unborn unborn unborn))
                      '() 3)
                  '(fork)))
    ((fork-raised)
     (cons (mk (if (f 'born) '(unborn setting-up unborn) '(unborn unborn unborn))
               '() 3)
           (list 'fork-raised
                 (case (f 'idx) ((low) 0) ((one) 1) ((many) 2) (else 4))
                 "boom")))
    ((look) (cons (M phase '(setting-up idle ended) '() 3
                     (if (f 'start-raise) '((set-up 3 (raised "x"))) '((tear-down 2 left))))
                  '(look)))
    ((set-up)
     (let* ((s1 (cond ((f 'other-setting-up) 'setting-up)
                      ((f 'other-live) 'idle)
                      (else 'ended)))
            (s3 (if (and (f 'other-live) (not (f 'other-setting-up)))
                    'ended
                    'ended)))
       (cons (mk (list s1 (slot-for (f 'slot-t) ta) s3) '() 3)
             (list 'set-up 2 (if (eq? (f 'outcome) 'returned)
                                 'returned
                                 '(raised "su"))))))
    ((call)
     (cons (if (f 'at-cap)
               (mk (list `(running ,tb) (if (f 'idle) 'idle `(running ,tc))
                         `(running ,td))
                   (list te) 1)
               (mk (list `(running ,tb) (if (f 'idle) 'idle `(running ,tc))
                         `(running ,td))
                   (list te) 3))
           (list 'call ta)))
    ((abandon)
     (let* ((w (f 'where))
            (qe (f 'queue-empty))
            (queue (cond ((eq? w 'queued) (list tb ta tc))
                         (qe '())
                         (else (list tb))))
            (slot (case w
                    ((given running dropping) (list w ta))
                    (else 'idle))))
       (cons (mk (list `(running ,td) slot `(running ,te)) queue 5)
             (list 'abandon ta))))
    ((next) (cons (mk (list `(running ,tb) (slot-for (f 'slot-t) ta)
                            `(dropping ,tc))
                      '() 3)
                  '(next 2)))
    ((end)
     (cons (mk (list `(running ,tb) (slot-for (f 'slot-t) ta) `(dropping ,tc))
               (if (f 'queue-empty) '() (list td))
               3)
           (list 'end 2 rv)))
    ((left)
     (cons (mk (list `(running ,tb) (slot-for (f 'slot-t) ta) `(dropping ,tc))
               '() 3)
           '(left 2)))
    ((stop)
     (cons (mk (list 'idle `(given ,ta) `(running ,tb)) '() 3)
           (list 'stop (f 'own))))
    ((torn-down)
     (cons (mk (if (f 'other-live)
                   (list `(running ,tb) (slot-for (f 'slot-t) ta) 'ended)
                   (list 'ended (slot-for (f 'slot-t) ta) 'ended))
               '() 3)
           '(torn-down 2 (raised "td"))))
    (else (assertion-violation 'build "kind" kind))))

;; Per kind: the points where the machine or classify disagreed with the table.
(define (drive-point pt)
  (guard (x (#t (list (car pt) (cadr pt) (caddr pt) 'drive-raised (describe x))))
   (drive-point* pt)))

(define (drive-point* pt)
  (let* ((kind (car pt)) (phase (cadr pt)) (fv (caddr pt))
         (h (hits kind phase fv)))
    (and (= (length h) 1)
         (let* ((e (car h))
                (want (if (entry-row? e) (row-id e) 'cant-happen))
                (me (guard (x (#t (list 'build-raised (describe x))))
                      (build kind phase fv))))
           (if (and (pair? me) (machine? (car me)))
               (let ((got-class (guard (x (#t (list 'classify-raised (describe x))))
                                 (classify (car me) (cdr me))))
                     (got-step
                      (guard (x ((and (assertion-violation? x) (who-condition? x))
                                 (list 'assertion (condition-who x)))
                                (#t (list 'other (describe x))))
                        (let ((r (step-of (car me) (cdr me))))
                          (list 'row (cadddr r))))))
                 (and (not (and (eq? got-class want)
                                (equal? got-step
                                        (if (entry-row? e)
                                            (list 'row want)
                                            '(assertion step)))))
                      (list kind phase fv 'want want 'classify got-class
                            'step got-step)))
               (list kind phase fv 'build me))))))

(for-each
 (lambda (kind)
   (let ((bad (filter values
                      (map drive-point
                           (filter (lambda (pt) (eq? (car pt) kind)) cross)))))
     (for-each (lambda (f) (display "  point: ") (write f) (newline)) bad)
     (test-equal (string-append "cross driven: " (symbol->string kind))
       '() bad)))
 event-kinds)

;; ---------------------------------------------------------------------
;; Layer 2: machines made by stepping, so the queue spans both its lists
;; ---------------------------------------------------------------------

(define q1 (string-copy "queued-one"))
(define q2 (string-copy "queued-two"))
(define q3 (string-copy "queued-three"))
(define q4 (string-copy "queued-four"))
(define q5 (string-copy "queued-five"))
(define q6 (string-copy "queued-six"))
(define ra (string-copy "running-a"))
(define rb (string-copy "running-b"))
(define rc (string-copy "running-c"))
(define gk (string-copy "given-k"))

;; chain : Machine (Listof Event) -> (Listof Any)
;; each step's (reply effects queue-after), then (phase slots) at the end
(define (chain m evs)
  (let loop ((m m) (evs evs) (acc '()))
    (if (null? evs)
        (reverse (cons (list (machine-phase m) (machine-slots m)) acc))
        (let ((r (step-of m (car evs))))
          (loop (car r) (cdr evs)
                (cons (list (cadr r) (caddr r) (machine-queue (car r))) acc))))))

(define (chain-case label m-thunk evs expected)
  (test-equal label expected
    (guard (e (#t (list 'raised (describe e))))
      (chain (m-thunk) evs))))

;; enqueues, dequeues by E1, and an abandon of a queued ticket from the back
(chain-case "queue order across the front and back lists"
  (lambda () (M 'serving `((running ,ra) (running ,rb) (running ,rc)) (list q1)
                8 '()))
  `((call ,q2) (call ,q3) (end 1 ,rv) (call ,q4) (end 2 ,rv) (call ,q5)
    (call ,q6) (end 3 ,rv) (abandon ,q5) (end 1 ,rv))
  `((accepted () (,q1 ,q2))
    (accepted () (,q1 ,q2 ,q3))
    ((run ,q1) ((post ,ra ,rv)) (,q2 ,q3))
    (accepted () (,q2 ,q3 ,q4))
    ((run ,q2) ((post ,rb ,rv)) (,q3 ,q4))
    (accepted () (,q3 ,q4 ,q5))
    (accepted () (,q3 ,q4 ,q5 ,q6))
    ((run ,q3) ((post ,rc ,rv)) (,q4 ,q5 ,q6))
    (ok () (,q4 ,q6))
    ((run ,q4) ((post ,q1 ,rv)) (,q6))
    (serving ((running ,q4) (running ,q2) (running ,q3)))))

;; A2 on a queue held in both lists, then a queued abandon from the back
(chain-case "A2 and A1 on a queue in both lists"
  (lambda () (M 'serving `((running ,ra) idle (running ,rb)) (list q1 q2) 8 '()))
  `((call ,gk) (call ,q3) (call ,q4) (abandon ,gk) (next 2) (abandon ,q4)
    (abandon ,q2))
  `((accepted ((signal 2)) (,q1 ,q2))
    (accepted () (,q1 ,q2 ,q3))
    (accepted () (,q1 ,q2 ,q3 ,q4))
    (ok () (,q2 ,q3 ,q4))
    ((run ,q1) () (,q2 ,q3 ,q4))
    (ok () (,q2 ,q3))
    (ok () (,q3))
    (serving ((running ,ra) (running ,q1) (running ,rb)))))

;; S1 posts stopped to the given job, then the queue oldest first
(chain-case "S1 on a queue in both lists"
  (lambda () (M 'serving `((running ,ra) idle (running ,rb) (running ,rc))
                (list q1 q2) 8 '()))
  `((call ,gk) (call ,q3) (call ,q4) (call ,q5) (stop #f))
  `((accepted ((signal 2)) (,q1 ,q2))
    (accepted () (,q1 ,q2 ,q3))
    (accepted () (,q1 ,q2 ,q3 ,q4))
    (accepted () (,q1 ,q2 ,q3 ,q4 ,q5))
    (wait ((post ,gk stopped) (post ,q1 stopped) (post ,q2 stopped)
           (post ,q3 stopped) (post ,q4 stopped) (post ,q5 stopped)
           (signal 2))
          ())
    (stopping ((running ,ra) tearing-down (running ,rb) (running ,rc)))))

;; X1 likewise, after the job that left
(chain-case "X1 on a queue in both lists"
  (lambda () (M 'serving `((running ,ra) idle (running ,rb) (running ,rc))
                (list q1 q2) 8 '()))
  `((call ,gk) (call ,q3) (call ,q4) (call ,q5) (left 3))
  `((accepted ((signal 2)) (,q1 ,q2))
    (accepted () (,q1 ,q2 ,q3))
    (accepted () (,q1 ,q2 ,q3 ,q4))
    (accepted () (,q1 ,q2 ,q3 ,q4 ,q5))
    (tear-down ((post ,rb left) (post ,gk stopped) (post ,q1 stopped)
                (post ,q2 stopped) (post ,q3 stopped) (post ,q4 stopped)
                (post ,q5 stopped) (signal 2))
               ())
    (stopping ((running ,ra) tearing-down tearing-down (running ,rc)))))

;; queue only in the back list (made empty, then filled by calls), then E1
(chain-case "a queue only in the back list, then dequeued"
  (lambda () (M 'serving `((running ,ra) (running ,rb)) '() 3 '()))
  `((call ,q1) (call ,q2) (call ,q3) (end 1 ,rv) (call ,q4) (call ,q5)
    (end 2 ,rv) (end 1 ,rv))
  `((accepted () (,q1))
    (accepted () (,q1 ,q2))
    (accepted () (,q1 ,q2 ,q3))
    ((run ,q1) ((post ,ra ,rv)) (,q2 ,q3))
    (accepted () (,q2 ,q3 ,q4))
    (full () (,q2 ,q3 ,q4))
    ((run ,q2) ((post ,rb ,rv)) (,q3 ,q4))
    ((run ,q3) ((post ,q1 ,rv)) (,q4))
    (serving ((running ,q3) (running ,q2)))))

;; ---------------------------------------------------------------------
;; Layer 2: C2 and C3 at the cap, from both sides
;; ---------------------------------------------------------------------

(for-each
 (lambda (c)
   (let* ((cap (car c)) (below (cadr c)) (after (caddr c))
          (m (M 'serving `((running ,ra) (running ,rb)) below cap '()))
          (r (guard (e (#t (list 'raised (describe e)))) (step-of m `(call ,ta))))
          (m2 (and (pair? r) (machine? (car r)) (car r))))
     (test-equal (string-append "C2 one below cap " (number->string cap))
       `(accepted () ,after C2 ,cap)
       (and m2 (list (cadr r) (caddr r) (machine-queue m2) (cadddr r)
                     (machine-cap m2))))
     (test-equal (string-append "C3 at cap " (number->string cap))
       '(full () C3 #t)
       (guard (e (#t (list 'raised (describe e))))
         (let ((r2 (step-of m2 `(call ,tb))))
           (list (cadr r2) (caddr r2) (cadddr r2) (eq? m2 (car r2))))))))
 (list (list 1 '() (list ta))
       (list 2 (list tb) (list tb ta))
       (list 3 (list tb tc) (list tb tc ta))))

;; ---------------------------------------------------------------------
;; Layer 2: an enqueue costs the same on a long queue as on a short one
;; ---------------------------------------------------------------------

(define (bytes-per-step m ev reps)
  (let ((before (sstats-bytes (statistics))))
    (do ((i 0 (+ i 1))) ((= i reps))
      (step m ev))
    (/ (- (sstats-bytes (statistics)) before) reps)))

(define (n-tickets n)
  (let loop ((i 0) (acc '()))
    (if (= i n) acc (loop (+ i 1) (cons (string-append "t-" (number->string i)) acc)))))

(let* ((short (M 'serving `((running ,ra)) (n-tickets 1) 5000 '()))
       (long (M 'serving `((running ,ra)) (n-tickets 1000) 5000 '()))
       (ev `(call ,ta))
       (a (begin (bytes-per-step short ev 50) (bytes-per-step short ev 2000)))
       (b (bytes-per-step long ev 2000)))
  (test-assert "an enqueue allocates something, so the comparison means something"
    (> a 0))
  (test-equal "a C2 step onto 1000 tickets allocates no more than onto 1" #t
    (<= b (* 5/4 a))))

;; ---------------------------------------------------------------------
;; Layer 2: malformed events
;; ---------------------------------------------------------------------

(let ((m (M 'serving `(idle (running ,ta) idle) (list tb) 4 '())))
  (for-each
   (lambda (ev)
     (test-equal (string-append "malformed, classify: " (describe ev))
       'cant-happen (classify m ev))
     (test-equal (string-append "malformed, step: " (describe ev))
       '(assertion step)
       (outcome (lambda () (step m ev))))
     (test-equal (string-append "malformed, step/row: " (describe ev))
       '(assertion step)
       (outcome (lambda () (step/row m ev)))))
   (list 5 '() 'next '(bogus) '(bogus 1) '(next) '(next 1 2) '(next 0)
         '(next 4) '(next 1.5) '(next x) '(left 0) '(left 4) '(end 0 r)
         '(end 4 r) '(end 2) '(fork 1) '(look 1) '(call) '(call 1 2)
         '(abandon) '(stop) '(stop 1) '(stop #t #f) '(set-up 0 returned)
         '(set-up 4 returned) '(set-up 2) '(set-up 2 wat) '(set-up 2 (raised))
         '(torn-down 4 returned) '(torn-down 2 wat) '(fork-raised 1)
         '(fork-raised x e) '(fork-raised 1.5 e))))

;; The maker forks once, while every slot is unborn, and failed is reached
;; only through a kept fork or set-up raise: each of these is a cell, in
;; classify and in step alike.
(for-each
 (lambda (c)
   (let ((m (car c)) (ev (cadr c)))
     (test-equal (string-append "a cell, classify and step: " (caddr c))
       '(cant-happen (assertion step))
       (list (classify m ev) (outcome (lambda () (step/row m ev)))))))
 (list (list (M 'starting '(setting-up setting-up) '() 2 '()) '(fork)
             "a second fork")
       (list (M 'starting '(unborn idle) '() 2 '()) '(fork)
             "a fork with one slot born")
       (list (M 'starting '(setting-up setting-up) '() 2 '())
             (list 'fork-raised 2 "late") "a fork raise after the forks")
       (list (M 'failed '(ended ended) '() 2 '((tear-down 1 left))) '(look)
             "a look in failed with no fork or set-up raise")))

;; thread 1 and n are in range
(let ((m (M 'starting '(idle idle idle) '() 2 '())))
  (test-equal "next 1 and next n are rows" '(N1 N1)
    (list (classify m '(next 1)) (classify m '(next 3)))))

;; ---------------------------------------------------------------------
;; Layer 2: the constructors
;; ---------------------------------------------------------------------

(test-equal "initial-machine: the machine it makes"
  '(starting (unborn unborn) () 5 ())
  (let ((m (initial-machine 2 5)))
    (list (machine-phase m) (machine-slots m) (machine-queue m)
          (machine-cap m) (machine-raises m))))
(test-equal "initial-machine: one thread, cap 0 accepted" 'no-raise
  (outcome (lambda () (initial-machine 1 0))))
(test-equal "initial-machine: cap 2^100 accepted, kept"
  big (guard (e (#t 'raised)) (machine-cap (initial-machine 3 big))))
(test-equal "initial-machine: threads 0" '(assertion initial-machine)
  (outcome (lambda () (initial-machine 0 1))))
(test-equal "initial-machine: threads -1" '(assertion initial-machine)
  (outcome (lambda () (initial-machine -1 1))))
(test-equal "initial-machine: threads 1.5" '(assertion initial-machine)
  (outcome (lambda () (initial-machine 1.5 1))))
(test-equal "initial-machine: threads 2.0" '(assertion initial-machine)
  (outcome (lambda () (initial-machine 2.0 1))))
(test-equal "initial-machine: threads a symbol" '(assertion initial-machine)
  (outcome (lambda () (initial-machine 'two 1))))
(test-equal "initial-machine: cap -1" '(assertion initial-machine)
  (outcome (lambda () (initial-machine 1 -1))))
(test-equal "initial-machine: cap -2^100" '(assertion initial-machine)
  (outcome (lambda () (initial-machine 1 (- big)))))
(test-equal "initial-machine: cap 1.5" '(assertion initial-machine)
  (outcome (lambda () (initial-machine 1 1.5))))
(test-equal "initial-machine: cap 1.0" '(assertion initial-machine)
  (outcome (lambda () (initial-machine 1 1.0))))
(test-equal "initial-machine: cap a string" '(assertion initial-machine)
  (outcome (lambda () (initial-machine 1 "3"))))

(test-equal "make-machine: queue at the cap accepted" 'no-raise
  (outcome (lambda () (M 'serving '(idle) (list ta tb) 2 '()))))
(test-equal "make-machine: queue one past the cap" '(assertion make-machine)
  (outcome (lambda () (M 'serving '(idle) (list ta tb tc) 2 '()))))
(test-equal "make-machine: a queue and cap 0" '(assertion make-machine)
  (outcome (lambda () (M 'serving '(idle) (list ta) 0 '()))))
(test-equal "make-machine: bignum cap, queue below it" 'no-raise
  (outcome (lambda () (M 'serving '(idle) (list ta) big '()))))
(test-equal "make-machine: negative cap" '(assertion make-machine)
  (outcome (lambda () (M 'serving '(idle) '() -1 '()))))
(test-equal "make-machine: fractional cap" '(assertion make-machine)
  (outcome (lambda () (M 'serving '(idle) '() 1.5 '()))))
(test-equal "make-machine: a ticket twice in the queue" '(assertion make-machine)
  (outcome (lambda () (M 'serving '(idle) (list ta tb ta) 5 '()))))
(test-equal "make-machine: a ticket in the queue and a slot"
  '(assertion make-machine)
  (outcome (lambda () (M 'serving `((running ,ta)) (list ta) 5 '()))))
(test-equal "make-machine: a ticket in two slots" '(assertion make-machine)
  (outcome (lambda () (M 'serving `((running ,ta) (given ,ta)) '() 5 '()))))
(test-equal "make-machine: equal tickets that aren't eq? are two tickets"
  'no-raise
  (outcome (lambda ()
             (M 'serving `((running ,ta)) (list (string-copy ta)) 5 '()))))
(test-equal "make-machine: a bad phase" '(assertion make-machine)
  (outcome (lambda () (M 'waiting '(idle) '() 5 '()))))
(test-equal "make-machine: a bad slot" '(assertion make-machine)
  (outcome (lambda () (M 'serving '(napping) '() 5 '()))))
(test-equal "make-machine: raises in ascending thread order accepted" 'no-raise
  (outcome (lambda ()
             (M 'failed '(ended ended ended) '() 5
                '((set-up 1 left) (tear-down 3 left))))))
(test-equal "make-machine: raises out of order" '(assertion make-machine)
  (outcome (lambda ()
             (M 'failed '(ended ended ended) '() 5
                '((set-up 3 left) (set-up 1 left))))))
(test-equal "make-machine: two raises on one thread" '(assertion make-machine)
  (outcome (lambda ()
             (M 'failed '(ended ended ended) '() 5
                '((set-up 2 left) (tear-down 2 left))))))
(test-equal "make-machine: a raise on thread n accepted" 'no-raise
  (outcome (lambda ()
             (M 'failed '(ended ended ended) '() 5 '((set-up 3 left))))))
(test-equal "make-machine: a raise on thread n+1" '(assertion make-machine)
  (outcome (lambda ()
             (M 'failed '(ended ended ended) '() 5 '((set-up 4 left))))))
(test-equal "make-machine: a raise on thread 0" '(assertion make-machine)
  (outcome (lambda ()
             (M 'failed '(ended ended ended) '() 5 '((set-up 0 left))))))
(test-equal "make-machine: the fields needn't agree (serving, an unborn slot)"
  'no-raise
  (outcome (lambda () (M 'serving '(unborn) '() 5 '()))))

(test-equal "machine-slots and machine-queue answer fresh lists" '(#t #t)
  (let ((m (M 'serving `(idle (running ,ta)) (list tb) 5 '())))
    (list (not (eq? (machine-slots m) (machine-slots m)))
          (not (eq? (machine-queue m) (machine-queue m))))))

(test-end "worker-table")

(exit (suite-exit-status runner))
