#!r6rs
;;; (circuit worker): wrap-busy, and the shell's names it re-exports.
;;;
;;;   - the two refusals of a real worker, through the test host, (http-server
;;;     testing), under (wrap app (wrap-busy 5) wrap-catch): a worker of one
;;;     thread and a cap of 0 that holds a job at a gate refuses the second
;;;     call, and a stopped worker refuses every call; each is a 503 with a
;;;     retry-after of 5 and an empty body, the response whole as its wire
;;;     bytes, the server's log whole, and nothing written to the current
;;;     output port;
;;;   - the same two without wrap-busy: wrap-catch answers 500 and writes its
;;;     line, which is why wrap-busy goes inside it;
;;;   - everything else passed on: an &error from a real job, a continuable
;;;     raise answered where it was raised, &deadline-passed reaching
;;;     wrap-timeout's 504, a raise that is no condition;
;;;   - the arguments: n of 0 and a bignum, and the refusals of any other n
;;;     and of a handler that is no procedure;
;;;   - (circuit worker) re-exports the shell's nine public names, the very
;;;     objects, and no other;
;;;   - every worker the suite makes is stopped, and its live count is 0.
(import (rnrs)
        (rnrs mutable-strings)
        (rnrs sorting)
        (srfi :64)
        (only (chezscheme) parameterize make-mutex mutex-acquire mutex-release
              make-condition condition-wait condition-broadcast real-time make-time sleep
              library-exports)
        (rename (only (chezscheme) current-output-port) (current-output-port chez:current-output-port))
        (circuit-testing)
        (http-server)
        (http-server testing)
        (circuit)
        (circuit http-server)
        (circuit test)
        (circuit middleware waits)
        (prefix (circuit worker) w:)
        (circuit worker)
        (only (circuit worker shell) worker-live-count)
        (prefix (only (circuit worker shell) make-worker worker-call worker-stop! worker?
                      make-test-worker &worker-full worker-full? &worker-stopped worker-stopped?)
                s:))

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
        (newline)))))

;;; ------------------------------------------------------------------------
;;; Helpers

(define (b s) (string->utf8 s))

(define (text bv)
  (let* ((n (bytevector-length bv)) (s (make-string n)))
    (let loop ((i 0))
      (if (= i n)
          s
          (begin (string-set! s i (integer->char (bytevector-u8-ref bv i)))
                 (loop (+ i 1)))))))

(define (wire c)
  (map (lambda (r) (text (test-response-bytes r))) (test-client-responses c)))

(define (get path) (string-append "GET " path " HTTP/1.1\r\nHost: x\r\n\r\n"))

(define (response status fields body)
  (string-append "HTTP/1.1 " status "\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\n"
                 (apply string-append (map (lambda (f) (string-append f "\r\n")) fields))
                 "\r\n" body))

(define (busy-wire n)
  (response "503 Service Unavailable"
            (list (string-append "retry-after: " n) "Content-Length: 0") ""))
(define empty-500 (response "500 Internal Server Error" '("Content-Length: 0") ""))
(define empty-504 (response "504 Gateway Timeout" '("Content-Length: 0") ""))

;; shown : Any -> Any — a log detail: a condition by its kind, who, message, irritants.
(define (shown d)
  (cond ((not (condition? d)) d)
        (else (list (cond ((assertion-violation? d) 'assertion)
                          ((s:worker-full? d) 'worker-full)
                          ((s:worker-stopped? d) 'worker-stopped)
                          ((deadline-passed? d) 'deadline-passed)
                          (else 'condition))
                    (and (who-condition? d) (condition-who d))
                    (and (message-condition? d) (condition-message d))
                    (and (irritants-condition? d) (condition-irritants d))))))

(define (logged host)
  (map (lambda (entry) (cons (car entry) (map shown (cdr entry)))) (test-host-log host)))

;; hosted : (-> Any) -> (List Any String)
;; What THUNK answers, and all it wrote to the current output port.
(define (hosted thunk)
  (let-values (((port extract) (open-string-output-port)))
    (let ((got (parameterize ((chez:current-output-port port)) (thunk))))
      (list got (extract)))))

(define unset (lambda (name) #f))

;; Every worker the suite makes, so a row that dies still has its worker stopped.
(define made '())
(define (track! w) (set! made (cons w made)) w)

;; retire! : Worker -> Nat — stop W, then its live count.
(define (retire! w) (s:worker-stop! w) (worker-live-count w))

;; A gate: a job that says it runs, then waits for the gate to open.
(define-record-type gate (fields mx cv (mutable running?) (mutable open?)))
(define (new-gate) (make-gate (make-mutex) (make-condition) #f #f))
(define (gate-job g)
  (lambda (s)
    (mutex-acquire (gate-mx g))
    (gate-running?-set! g #t)
    (condition-broadcast (gate-cv g))
    (let loop ()
      (unless (gate-open? g) (condition-wait (gate-cv g) (gate-mx g)) (loop)))
    (mutex-release (gate-mx g))
    'done))
(define (await-running g)
  (let ((deadline (+ (real-time) 5000)) (mx (gate-mx g)))
    (mutex-acquire mx)
    (let loop ()
      (cond ((gate-running? g) (mutex-release mx) #t)
            ((> (real-time) deadline) (mutex-release mx) #f)
            (else (condition-wait (gate-cv g) mx (make-time 'time-duration 50000000 0)) (loop))))))
(define (open-gate! g)
  (mutex-acquire (gate-mx g))
  (gate-open?-set! g #t)
  (condition-broadcast (gate-cv g))
  (mutex-release (gate-mx g)))

(define (settle! host)
  (let ((deadline (+ (real-time) 5000)))
    (let loop ()
      (when (and (= 0 (test-host-posted host)) (< (real-time) deadline))
        (sleep (make-time 'time-duration 1000000 0))
        (loop)))
    (test-host-advance! host 0)))

(define (host-of app) (make-test-host (circuit->handler app unset) unset))

(define (calling w job) (lambda (r) (s:worker-call w job) (make-res 200 '() #f)))

;; busy-row : Boolean (Handler -> Handler)... -> (List ...)
;; A worker of 1 thread and a cap of 0 holds a job at a gate; a second client's
;; call is refused. Answers what the second client read, whether its connection
;; ended, the server's log, the output port's text, the first client's
;; responses once the gate opens, and the live count after the stop.
(define (full-row . middlewares)
  (let* ((w (track! (s:make-worker (lambda () 'state) 0 1)))
         (g (new-gate))
         (app (apply wrap (calling w (gate-job g)) middlewares))
         (host (host-of app))
         (seen (hosted
                (lambda ()
                  (let ((c1 (test-host-connect! host)))
                    (test-client-send! c1 (b (get "/one")))
                    (let ((running (await-running g))
                          (c2 (test-host-connect! host)))
                      (test-client-send! c2 (b (get "/two")))
                      (let ((second (list (wire c2) (test-client-connection-closed? c2))))
                        (open-gate! g)
                        (settle! host)
                        (list running second (wire c1)))))))))
    (let ((live (retire! w)))
      (list (car seen) (logged host) (cadr seen) live))))

;; stopped-row : Handler... -> (List ...)
(define (stopped-row . middlewares)
  (let* ((w (track! (s:make-worker (lambda () 'state) 0 1))))
    (s:worker-stop! w)
    (let* ((app (apply wrap (calling w (lambda (s) 'x)) middlewares))
           (host (host-of app))
           (seen (hosted (lambda ()
                           (let ((c (test-host-connect! host)))
                             (test-client-send! c (b (get "/")))
                             (list (wire c) (test-client-connection-closed? c)))))))
      (list (car seen) (logged host) (cadr seen) (worker-live-count w)))))

;; A real &worker-full and &worker-stopped, caught once in a handler and kept.
(define kept-full 'not-kept)
(define kept-stopped 'not-kept)
(guard (e (#t (set! kept-full (list 'kept-failed e)) (set! kept-stopped (list 'kept-failed e))))
 (let* ((w (track! (s:make-worker (lambda () 'state) 0 1)))
       (g (new-gate))
       (catching (lambda (setter)
                   (lambda (r)
                     (guard (e (#t (setter e) (make-res 200 '() #f)))
                       (s:worker-call w (gate-job g))
                       (make-res 200 '() #f)))))
       (host (host-of (catching (lambda (e) (set! kept-full e))))))
  (let ((c1 (test-host-connect! host)))
    (test-client-send! c1 (b (get "/")))
    (await-running g)
    (let ((c2 (test-host-connect! host)))
      (test-client-send! c2 (b (get "/"))))
    (open-gate! g)
    (settle! host)
    (retire! w)
    (let ((host (host-of (catching (lambda (e) (set! kept-stopped e))))))
      (let ((c (test-host-connect! host)))
        (test-client-send! c (b (get "/"))))))))

;; direct : (Req -> Res) Nat -> (List 'returned Any) | (List 'raised Any)
(define (outcome thunk)
  (guard (e (#t (list 'raised e)))
    (list 'returned (thunk))))

(define (refusal thunk)
  (guard (e ((assertion-violation? e)
             (list 'assertion (and (who-condition? e) (condition-who e))))
            (#t (list 'other e)))
    (thunk)
    'no-raise))

(define req (make-test-req 'GET "/"))

;; busy-answer : Nat Any -> (List Status Headers Body)
;; What (wrap-busy N) over an app that raises X answers.
(define (busy-answer n x)
  (let ((r (((wrap-busy n) (lambda (r) (raise x))) req)))
    (list (res-status r) (res-headers r) (res-body r))))

;; busy-answer/continuable : Nat Any -> (List Status Headers Body)
;; The same, X raised continuably, under an outer handler that continues with
;; 200: a wrap-busy that passed X on would answer 200.
(define (busy-answer/continuable n x)
  (let ((r (with-exception-handler
            (lambda (e) 200)
            (lambda ()
              (((wrap-busy n) (lambda (r) (make-res (raise-continuable x) '() #f))) req)))))
    (list (res-status r) (res-headers r) (res-body r))))

(test-begin "worker-busy")

;;; --- the library's names -------------------------------------------------

(test-equal "(circuit worker) exports the shell's nine public names and wrap-busy, and none of the shell's internal ones"
  '(&worker-full &worker-stopped make-test-worker make-worker worker-call worker-full?
    worker-stop! worker-stopped? worker? wrap-busy)
  (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
             (library-exports '(circuit worker))))

(test-equal "the names (circuit worker) re-exports as procedures are the shell's, the very objects"
  '(#t #t #t #t #t #t #t)
  (list (eq? w:make-worker s:make-worker) (eq? w:worker-call s:worker-call)
        (eq? w:worker-stop! s:worker-stop!) (eq? w:worker? s:worker?)
        (eq? w:make-test-worker s:make-test-worker)
        (eq? w:worker-full? s:worker-full?) (eq? w:worker-stopped? s:worker-stopped?)))

;;; --- a real &worker-full and &worker-stopped, inside wrap-catch ------------

(define busy-5 (wrap-busy 5))

(test-equal "a real &worker-full under (wrap app (wrap-busy 5) wrap-catch): 503, retry-after: 5, empty body, nothing printed; the held call finishes 200"
  (list (list #t (list (list (busy-wire "5")) #f)
              (list (response "200 OK" '("Content-Length: 0") "")))
        '() "" 0)
  (full-row busy-5 wrap-catch))

(test-equal "a real &worker-stopped under (wrap app (wrap-busy 5) wrap-catch): the same 503, nothing printed"
  (list (list (list (busy-wire "5")) #f) '() "" 0)
  (stopped-row busy-5 wrap-catch))

;;; --- the same two without wrap-busy ------------------------------------------

(define full-line "")
(define stopped-line "")

(test-equal "a real &worker-full under wrap-catch alone: 500 and wrap-catch's line"
  (list (list #t (list (list empty-500) #f) (list (response "200 OK" '("Content-Length: 0") "")))
        '() 'LINE 0)
  (let ((got (full-row wrap-catch)))
    (set! full-line (caddr got))
    (list (car got) (cadr got) (if (string=? (caddr got) "") "" 'LINE) (cadddr got))))

(test-equal "its line, whole"
  "handler-failed Exception in worker-call: the worker's queue is full\n" full-line)

(test-equal "a real &worker-stopped under wrap-catch alone: 500 and wrap-catch's line, whole"
  (list (list (list empty-500) #f) '()
        "handler-failed Exception in worker-call: the worker has stopped\n" 0)
  (stopped-row wrap-catch))

;;; --- everything else passes on ----------------------------------------------

;; job-row : (State -> Any) Middleware ... -> (List ...)
;; A call of JOB on a test worker, under the middlewares.
(define (job-row job . middlewares)
  (let* ((w (track! (s:make-test-worker (lambda () 'state))))
         (host (host-of (apply wrap (calling w job) middlewares)))
         (seen (hosted (lambda ()
                         (let ((c (test-host-connect! host)))
                           (test-client-send! c (b (get "/")))
                           (wire c))))))
    (list (car seen) (logged host) (cadr seen) (retire! w))))

(test-equal "an &error from a job: wrap-catch makes it a 500 with its line, wrap-busy inside it"
  (list (list empty-500) '()
        "handler-failed Exception in app: refused with irritant 7\n" 0)
  (job-row (lambda (s) (raise (condition (make-error) (make-who-condition 'app)
                                         (make-message-condition "refused")
                                         (make-irritants-condition '(7)))))
           busy-5 wrap-catch))

(test-equal "a continuable raise: the handler that raised it continues with an outer handler's value, as if wrap-busy weren't there"
  '((returned 201) (returned 202))
  (let ((app (lambda (r) (make-res (raise-continuable 'ask) '() #f))))
    (list (outcome (lambda ()
                     (with-exception-handler
                      (lambda (e) 201)
                      (lambda () (res-status ((busy-5 app) req))))))
          (outcome (lambda ()
                     (with-exception-handler
                      (lambda (e) 202)
                      (lambda () (res-status ((busy-5 (lambda (r) (make-res (raise-continuable (condition (make-error))) '() #f))) req)))))))))

(test-equal "a continuable raise of a real &worker-full is answered by wrap-busy, 503, not continued, for each of the two"
  '((503 (("retry-after" . "5")) #f) (503 (("retry-after" . "5")) #f))
  (list (busy-answer/continuable 5 kept-full) (busy-answer/continuable 5 kept-stopped)))

(test-equal "&deadline-passed reaches wrap-timeout's 504, with wrap-busy inside it"
  (list (list empty-504) '() "" )
  (let* ((host (host-of (wrap (lambda (r) (make-res 200 '() (await (lambda (resume) #f))))
                              busy-5 (wrap-timeout 0))))
         (seen (hosted (lambda ()
                         (let ((c (test-host-connect! host)))
                           (test-client-send! c (b (get "/")))
                           (wire c))))))
    (list (car seen) (logged host) (cadr seen))))

(test-equal "a value that is no condition passes on, the very object, and wrap-catch makes it a 500"
  (list '(raised boom) #t)
  (let ((v (list 'boom)))
    (list (let ((got (outcome (lambda () (busy-answer 5 'boom))))) got)
          (let ((got (outcome (lambda () (busy-answer 5 v)))))
            (and (eq? (car got) 'raised) (eq? (cadr got) v))))))

(test-equal "a value that is no condition under wrap-catch: 500, not 503"
  (list (list empty-500) '() "handler-failed boom\n" 0)
  (job-row (lambda (s) (raise 'boom)) busy-5 wrap-catch))

;;; --- the arguments ------------------------------------------------------------

(test-equal "n of 0: retry-after 0"
  '(503 (("retry-after" . "0")) #f)
  (busy-answer 0 kept-stopped))

(test-equal "a bignum n: the header carries its digits"
  (list 503 (list (cons "retry-after" "1000000000000000000000000000000")) #f)
  (busy-answer (expt 10 30) kept-full))

(test-equal "n of -1, 1.5, \"5\", 5/2 and 5.0 is refused at once by wrap-busy"
  '((assertion wrap-busy) (assertion wrap-busy) (assertion wrap-busy) (assertion wrap-busy) (assertion wrap-busy))
  (map (lambda (n) (refusal (lambda () (wrap-busy n)))) (list -1 1.5 "5" 5/2 5.0)))

(test-equal "a handler that isn't a procedure is refused when the middleware is applied, and n alone is not"
  (list '(assertion wrap-busy) '(assertion wrap-busy) 'no-raise)
  (list (refusal (lambda () ((wrap-busy 5) 'app)))
        (refusal (lambda () ((wrap-busy 5) #f)))
        (refusal (lambda () (wrap-busy 5)))))

;;; --- before the stop ----------------------------------------------------------

(test-equal "every worker the suite made is stopped, and its live count is 0"
  (map (lambda (w) 0) made)
  (map (lambda (w) (retire! w) (worker-live-count w)) made))

(test-end "worker-busy")
(exit (suite-exit-status runner))
