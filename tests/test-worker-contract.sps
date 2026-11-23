#!r6rs
;;; The HTTP server's waiting contract, the part a worker relies on.
;;;
;;; A worker hands a job to its own thread, and the handler waits in
;;; await-outside until that thread's resume posts the answer. It then relies
;;; on how the server treats resume, the value it posts and the wait it
;;; posts to. There is no worker here: plain Chez threads play the other
;;; thread, and the suite holds the server alone, through its test host. A
;;; server release that changes one of these clauses turns its rows red, and
;;; the worker is then to be reconsidered before it follows the release.
;;;
;;; The clauses, each held by the rows named for it:
;;;
;;;   1. a raise in register leaves await-outside, and no wait began;
;;;   2. resume may be called from another thread: its first call, its inbox
;;;      open, answers #t, and the host's next call hands the value over;
;;;   3. a value posted to a wait that a deadline, or the client's close,
;;;      ended answers #t, is dropped, and nothing is logged;
;;;   4. a second call of a resume, its inbox open, answers #f, and the log
;;;      gets (late-resume await-outside) once the host delivers;
;;;   5. once the posts stop, resume answers #f and the parked wait is not
;;;      woken; and the host's next outside wait opens a fresh inbox, which
;;;      the server's own stopped loop does not (its inbox stays closed);
;;;   6. a wait inside a deadline that has passed raises before its register
;;;      runs;
;;;   7. a value register posts itself, or another thread posts while
;;;      register blocks for it, reaches the handler within the same call of
;;;      the host;
;;;   8. the values one thread posts arrive in the order it posted them;
;;;   9. a wait begun on a thread other than the loop's raises there, and
;;;      register never runs;
;;;  10. resume never raises, whoever calls it, whenever, and whatever it is
;;;      given.
;;;
;;; What a row asserts: the responses whole, as status and body; resume's
;;; exact answer, #t or #f; the server's log whole; test-host-posted; and, for
;;; a raise, what the handler's own code caught. A row through a thread
;;; asserts the thread's answer, or what it raised, with a sentinel for the
;;; case that nothing was raised.
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (only (chezscheme) fork-thread thread-join make-mutex mutex-acquire mutex-release
              make-condition condition-wait condition-broadcast)
        (circuit-testing)
        (http-server testing)
        (circuit)
        (circuit http-server))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner names a failing test but not its values. Print both.
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

(test-begin "worker-contract")

;;; ------------------------------------------------------------------------
;;; Helpers

(define (b s) (string->utf8 s))

;; text : Bytevector -> String — one character a byte.
(define (text bv)
  (let* ((n (bytevector-length bv)) (s (make-string n)))
    (let loop ((i 0))
      (if (= i n)
          s
          (begin (string-set! s i (integer->char (bytevector-u8-ref bv i)))
                 (loop (+ i 1)))))))

(define (get path) (b (string-append "GET " path " HTTP/1.1\r\nHost: x\r\n\r\n")))

;; host-of : (Req -> Res) -> TestHost
(define (host-of app) (make-test-host (circuit->handler app (lambda (name) #f))))

;; answers : TestClient -> (Listof (List Nat String))
;; Each response the client read, as its status and body.
(define (answers c)
  (map (lambda (r) (list (test-response-status r) (text (test-response-body r))))
       (test-client-responses c)))

;; logged : TestHost -> (Listof Any)
;; What the server logged, whole, in order.
(define (logged host) (test-host-log host))

;; shown : Any -> String — a datum as it is written.
(define (shown x)
  (let-values (((port extract) (open-string-output-port)))
    (write x port)
    (extract)))

;; connect-all : TestHost Nat -> (Listof TestClient)
;; N clients, one after the other, each having sent a request.
(define (connect-all host n)
  (let loop ((i 0) (made '()))
    (if (= i n)
        (reverse made)
        (let ((c (test-host-connect! host)))
          (test-client-send! c (get "/"))
          (loop (+ i 1) (cons c made))))))

(define-record-type strange (fields))

;; A keeper: the resumes a handler's waits were given, in the order given.
(define (make-keeper)
  (let ((kept '()))
    (lambda (m . args)
      (case m
        ((keep!) (set! kept (append kept (list (car args)))))
        ((ref) (list-ref kept (car args)))
        ((count) (length kept))))))

;; on-thread : (-> Any) -> Any
;; THUNK run on another thread, and its answer, or what it raised, given
;; back as (returned V) or (raised E), once the thread has ended.
(define (on-thread thunk)
  (let ((m (make-mutex)) (cv (make-condition)) (result #f))
    (let ((t (fork-thread
              (lambda ()
                (let ((r (guard (e (#t (list 'raised e)))
                           (list 'returned (thunk)))))
                  (mutex-acquire m)
                  (set! result r)
                  (condition-broadcast cv)
                  (mutex-release m))))))
      (mutex-acquire m)
      (let loop ()
        (unless result
          (condition-wait cv m)
          (loop)))
      (mutex-release m)
      (thread-join t)
      result)))

;; threaded-resume : Resume Any -> (List 'returned Boolean)
;; RESUME called with V on another thread.
(define (threaded-resume resume v)
  (on-thread (lambda () (resume v))))

;; on-thread-list : (Nat Any -> Any) (Listof Any) -> (Listof Any)
;; F called on each element and its index, in order.
(define (on-thread-list f items)
  (let loop ((i 0) (rest items) (out '()))
    (if (null? rest)
        (reverse out)
        (let ((r (f i (car rest))))
          (loop (+ i 1) (cdr rest) (cons r out))))))

;; An app whose every request waits once, in await-outside, and keeps the
;; resume; it answers 200 with the value it was given, written.
(define (waiting-app keeper)
  (lambda (req)
    (make-res 200 '() (shown (await-outside (lambda (resume) (keeper 'keep! resume)))))))

;; The same wait under a deadline of MS, answered 504 "deadline" when it passes.
(define (deadline-app keeper ms)
  (lambda (req)
    (guard (e ((deadline-passed? e) (make-res 504 '() "deadline")))
      (with-deadline ms
        (lambda ()
          (make-res 200 '() (shown (await-outside (lambda (resume) (keeper 'keep! resume))))))))))

;;; ------------------------------------------------------------------------
;;; Clause 1: a raise in register leaves await-outside, and no wait began

(test-equal "1: a raise in register leaves await-outside; no wait began, a second wait after it answers, nothing is left parked or logged"
  (list (list '(200 "((raised boom) \"second\")")) #f 0 '())
  (let* ((host (host-of (lambda (req)
                          (let* ((first (guard (e ((symbol? e) (list 'raised e)))
                                          (await-outside (lambda (resume) (raise 'boom)))))
                                 (second (await-outside (lambda (resume) (resume "second")))))
                            (make-res 200 '() (shown (list first second)))))))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (list (answers c) (test-client-waiting? c) (test-host-posted host) (logged host))))

;;; ------------------------------------------------------------------------
;;; Clause 2: another thread's first resume answers #t; the next call of the
;;; host hands the value over

(test-equal "2: another thread's first resume answers #t, waits counted until the host's next call, which hands it over"
  (list '() #t '(returned #t) 1 '() '((200 "\"from-thread\"")) 0 '())
  (let* ((keeper (make-keeper))
         (host (host-of (waiting-app keeper)))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (let* ((parked (answers c))
           (waiting (test-client-waiting? c))
           (answer (threaded-resume (keeper 'ref 0) "from-thread"))
           (counted (test-host-posted host))
           (before (answers c)))
      (test-host-advance! host 0)
      (list parked waiting answer counted before (answers c) (test-host-posted host) (logged host)))))

;;; ------------------------------------------------------------------------
;;; Clause 3: a value posted to a wait a deadline or a close ended

(test-equal "3: after a deadline, another thread's value answers #t, the 504 stays, the value is dropped and nothing is logged"
  (list '((504 "deadline")) '(returned #t) '((504 "deadline")) 0 '())
  (let* ((keeper (make-keeper))
         (host (host-of (deadline-app keeper 100)))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (test-host-advance! host 100)
    (let* ((ended (answers c))
           (answer (threaded-resume (keeper 'ref 0) "late")))
      (test-host-advance! host 0)
      (list ended answer (answers c) (test-host-posted host) (logged host)))))

(test-equal "3: after the client's close, another thread's value answers #t, is dropped, and nothing is logged; the handler saw the close"
  (list '(client-closed) '(returned #t) 0 '())
  (let* ((keeper (make-keeper))
         (saw '())
         (host (host-of (lambda (req)
                          (guard (e ((client-closed? e) (set! saw (cons 'client-closed saw)) (make-res 200 '() "gone")))
                            (make-res 200 '() (shown (await-outside (lambda (resume) (keeper 'keep! resume)))))))))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (test-client-close! c)
    (let ((answer (threaded-resume (keeper 'ref 0) "late")))
      (test-host-advance! host 0)
      (list saw answer (test-host-posted host) (logged host)))))

;;; ------------------------------------------------------------------------
;;; Clause 4: a second call, its inbox open, answers #f and is logged

(test-equal "4: a second call before the host delivers answers #f, the value of the first arrives, and one late-resume await-outside is logged at the delivery"
  (list '(returned #t) '(returned #f) 1 '() '() '((200 "\"first\"")) '((late-resume await-outside)))
  (let* ((keeper (make-keeper))
         (host (host-of (waiting-app keeper)))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (let* ((one (threaded-resume (keeper 'ref 0) "first"))
           (two (threaded-resume (keeper 'ref 0) "second"))
           (counted (test-host-posted host))
           (log-before (logged host))
           (before (answers c)))
      (test-host-advance! host 0)
      (list one two counted log-before before (answers c) (logged host)))))

(test-equal "4: a second call after the value was handed over, the inbox still open, answers #f, and is logged once at the next delivery"
  (list '((200 "\"first\"")) '(returned #f) '() '((late-resume await-outside)))
  (let* ((keeper (make-keeper))
         (host (host-of (waiting-app keeper)))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (threaded-resume (keeper 'ref 0) "first")
    (test-host-advance! host 0)
    (let* ((delivered (answers c))
           (again (threaded-resume (keeper 'ref 0) "again"))
           (log-before (logged host)))
      (test-host-advance! host 0)
      (list delivered again log-before (logged host)))))

;;; ------------------------------------------------------------------------
;;; Clause 5: after the posts stop

(test-equal "5: after the posts stop, resume answers #f and the parked wait is not woken, now or after an advance; nothing is logged"
  (list '(returned #f) '() #t 0 '() '() #t '())
  (let* ((keeper (make-keeper))
         (host (host-of (waiting-app keeper)))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (test-host-stop-posts! host)
    (let* ((answer (threaded-resume (keeper 'ref 0) "after"))
           (now-answers (answers c))
           (now-waiting (test-client-waiting? c))
           (counted (test-host-posted host)))
      (test-host-advance! host 0)
      (list answer now-answers now-waiting counted (logged host) (answers c) (test-client-waiting? c) (logged host)))))

(test-equal "5: what was posted before the posts stopped is handed over, and its resume then answers #f"
  (list '(returned #t) '((200 "\"before\"")) '(returned #f) '())
  (let* ((keeper (make-keeper))
         (host (host-of (waiting-app keeper)))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (let ((posted (threaded-resume (keeper 'ref 0) "before")))
      (test-host-stop-posts! host)
      (let* ((handed (answers c))
             (again (threaded-resume (keeper 'ref 0) "after")))
        (test-host-advance! host 0)
        (list posted handed again (logged host))))))

(test-equal "5: after the posts stop, the host's next outside wait opens a fresh inbox: its resume answers #t and its value is handed over, while the old resume still answers #f"
  (list '(returned #f) '(returned #t) 1 '((200 "\"fresh\"")) '(returned #f) '())
  (let* ((keeper (make-keeper))
         (host (host-of (waiting-app keeper)))
         (c1 (test-host-connect! host)))
    (test-client-send! c1 (get "/one"))
    (test-host-stop-posts! host)
    (let* ((c2 (test-host-connect! host))
           (_ (test-client-send! c2 (get "/two")))
           (old (threaded-resume (keeper 'ref 0) "old"))
           (new (threaded-resume (keeper 'ref 1) "fresh"))
           (counted (test-host-posted host)))
      (test-host-advance! host 0)
      (list old new counted (answers c2) (threaded-resume (keeper 'ref 0) "old again") (answers c1)))))

;;; ------------------------------------------------------------------------
;;; Clause 6: a passed deadline, or a close, refuses a wait before register

(test-equal "6: a second wait inside a deadline that ended the first raises &deadline-passed before its register runs"
  '((first-ended #t) (second-refused #f))
  (let* ((keeper (make-keeper))
         (seen '())
         (host (host-of (lambda (req)
                          (let ((ran #f))
                            (guard (e ((deadline-passed? e) #f))
                              (with-deadline 50
                                (lambda ()
                                  (guard (e ((deadline-passed? e) (set! seen (cons (list 'first-ended #t) seen))))
                                    (await-outside (lambda (resume) (keeper 'keep! resume))))
                                  (guard (e ((deadline-passed? e) (set! seen (cons (list 'second-refused ran) seen))))
                                    (await-outside (lambda (resume) (set! ran #t) #f))))))
                            (make-res 200 '() "")))))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (test-host-advance! host 50)
    (reverse seen)))

;;; ------------------------------------------------------------------------
;;; Clause 7: a value posted while the host runs is handed over in the same call

(test-equal "7: a value register posts itself, on the loop's thread, answers #t and is handed over within the same send; nothing is left counted"
  (list '((200 "\"inline\"")) 0 '())
  (let* ((host (host-of (lambda (req)
                          (make-res 200 '() (shown (await-outside (lambda (resume) (resume "inline"))))))))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (list (answers c) (test-host-posted host) (logged host))))

(test-equal "7: a value another thread posts while register blocks for that thread is handed over within the same send"
  (list '((200 "\"threaded\"")) 0 '())
  (let* ((host (host-of (lambda (req)
                          (make-res 200 '()
                                    (shown (await-outside
                                            (lambda (resume)
                                              (thread-join (fork-thread (lambda () (resume "threaded")))))))))))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (list (answers c) (test-host-posted host) (logged host))))

(test-equal "7: the answer resume gave inside register is the one the posting thread sees, #t"
  (list '((200 "#t")) 0)
  (let* ((host (host-of (lambda (req)
                          (let ((answer #f))
                            (await-outside (lambda (resume) (set! answer (resume "x"))))
                            (make-res 200 '() (shown answer))))))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (list (answers c) (test-host-posted host))))

;;; ------------------------------------------------------------------------
;;; Clause 8: one thread's values arrive in the order it posted them

(test-equal "8: five waits, posted from one thread in the order 2 0 3 4 1, are handed over in that order"
  '(2 0 3 4 1)
  (let* ((keeper (make-keeper))
         (order '())
         (host (host-of (lambda (req)
                          (let ((v (await-outside (lambda (resume) (keeper 'keep! resume)))))
                            (set! order (cons v order))
                            (make-res 200 '() "")))))
         (clients (connect-all host 5)))
    (on-thread (lambda ()
                 (for-each (lambda (i) ((keeper 'ref i) i)) '(2 0 3 4 1))))
    (test-host-advance! host 0)
    (reverse order)))

(test-equal "8: values posted to one wait's neighbours after it keep their order across two deliveries"
  '(1 0 3 2)
  (let* ((keeper (make-keeper))
         (order '())
         (host (host-of (lambda (req)
                          (let ((v (await-outside (lambda (resume) (keeper 'keep! resume)))))
                            (set! order (cons v order))
                            (make-res 200 '() "")))))
         (clients (connect-all host 4)))
    (on-thread (lambda () (for-each (lambda (i) ((keeper 'ref i) i)) '(1 0))))
    (test-host-advance! host 0)
    (on-thread (lambda () (for-each (lambda (i) ((keeper 'ref i) i)) '(3 2))))
    (test-host-advance! host 0)
    (reverse order)))

;;; ------------------------------------------------------------------------
;;; Clause 9: a wait off the loop's thread raises, and register never runs

;; refused : Symbol -> (List ...)
;; A handler that makes a wait of kind KIND on another thread: what that
;; thread raised, as its predicate answers, who and message, and whether
;; the wait's register ran.
(define (off-loop kind)
  (let* ((ran #f)
         (outcome #f)
         (host (host-of (lambda (req)
                          (set! outcome
                                (on-thread
                                 (lambda ()
                                   (case kind
                                     ((await-outside) (await-outside (lambda (resume) (set! ran #t) #f)))
                                     ((await) (await (lambda (resume) (set! ran #t) #f)))
                                     ((sleep-ms) (sleep-ms 1))
                                     ((with-deadline) (with-deadline 10 (lambda () 'ran)))))))
                          (make-res 200 '() ""))))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (list (answers c)
          (if (eq? (car outcome) 'raised)
              (let ((e (cadr outcome)))
                (list 'raised (condition? e) (assertion-violation? e)
                      (and (who-condition? e) (condition-who e))
                      (and (message-condition? e) (condition-message e))))
              outcome)
          ran)))

(test-equal "9: await-outside begun on another thread raises an assertion naming await-outside and the loop's thread, and register never runs"
  '(((200 "")) (raised #t #t await-outside "a wait off the loop's thread") #f)
  (off-loop 'await-outside))

(test-equal "9: await begun on another thread raises an assertion naming await, and register never runs"
  '(((200 "")) (raised #t #t await "a wait off the loop's thread") #f)
  (off-loop 'await))

(test-equal "9: sleep-ms begun on another thread raises an assertion naming sleep-ms"
  '(((200 "")) (raised #t #t sleep-ms "a wait off the loop's thread") #f)
  (off-loop 'sleep-ms))

(test-equal "9: with-deadline begun on another thread raises an assertion naming with-deadline"
  '(((200 "")) (raised #t #t with-deadline "a wait off the loop's thread") #f)
  (off-loop 'with-deadline))

;;; ------------------------------------------------------------------------
;;; Clause 10: resume never raises

(test-equal "10: from another thread, twice, then after the deadline ended the wait, then after the posts stopped: each answers, none raises"
  (list '(returned #t) '(returned #f) '(returned #t) '(returned #f) '(returned #f) '(returned #f))
  (let* ((keeper (make-keeper))
         (host (host-of (waiting-app keeper)))
         (dhost (host-of (deadline-app keeper 10)))
         (c (test-host-connect! host)))
    (test-client-send! c (get "/"))
    (let* ((first (threaded-resume (keeper 'ref 0) 'a))
           (second (threaded-resume (keeper 'ref 0) 'b))
           (dc (test-host-connect! dhost)))
      (test-host-advance! host 0)
      (test-client-send! dc (get "/"))
      (test-host-advance! dhost 10)
      (let* ((after-deadline (threaded-resume (keeper 'ref 1) 'c))
             (after-deadline-twice (threaded-resume (keeper 'ref 1) 'd))
             (sc (test-host-connect! host)))
        (test-client-send! sc (get "/"))
        (test-host-stop-posts! host)
        (list first second after-deadline after-deadline-twice
              (threaded-resume (keeper 'ref 2) 'e)
              (threaded-resume (keeper 'ref 2) 'f))))))

(test-equal "10: given a record, a condition, a procedure and #f, resume answers #t and the very object reaches the handler"
  (list '((returned #t) (returned #t) (returned #t) (returned #t)) '(#t #t #t #t) '())
  (let* ((keeper (make-keeper))
         (got '())
         (host (host-of (lambda (req)
                          (set! got (append got (list (await-outside (lambda (resume) (keeper 'keep! resume))))))
                          (make-res 200 '() ""))))
         (record (make-strange))
         (condition-value (make-message-condition "odd"))
         (procedure-value (lambda (x) x))
         (values-posted (list record condition-value procedure-value #f))
         (clients (connect-all host 4))
         (answers-given (on-thread-list (lambda (i v) (threaded-resume (keeper 'ref i) v))
                                        values-posted)))
    (test-host-advance! host 0)
    (list answers-given
          (map eq? got values-posted)
          (logged host))))

;;; ------------------------------------------------------------------------

(test-end "worker-contract")

(exit (suite-exit-status runner))
