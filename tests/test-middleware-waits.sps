#!r6rs
;;; (circuit middleware waits): the catch helper, wrap-timeout and request
;;; logging (design §6, §7, §10).
;;;
;;;   - wrap-catch, called directly on make-test-req requests, with no host:
;;;     the two conditions raised again, the very ones, from where they were
;;;     raised, before anything unwinds, and a continuable raise of either
;;;     answered where it was raised; a &body-failed answered with its
;;;     status; any other raise handed to on-raise where it was raised,
;;;     before anything unwinds, its answer the answer, a res or not, a
;;;     raise from it reaching the caller; the default on-raise's line, rule
;;;     by rule, flushed, and its 500; the app's own answer returned; the
;;;     refusals;
;;;   - wrap-catch through the server's test host, (http-server testing): a
;;;     body that fails past the cap answered with its status and the
;;;     connection closed, a raise after a park, a client's close;
;;;   - the default line agrees with the server's own: for the same raise,
;;;     the text is what the server's log-line writes, the procedure serve
;;;     writes every log line with, imported from (http-server private
;;;     serve), which a suite may import and a library may not (ADR-0006).
;;;     Directly, for a raise of each kind, and through the test host, for
;;;     the entry the server logs when the same raise reaches it;
;;;   - wrap-timeout through the test host: the 504 at the deadline's
;;;     instant and not before, the res whole as middleware outside sees it,
;;;     0 ms a deadline already passed, a stalled body read, a producer
;;;     outside it, an answer that doesn't wait, everything else passed
;;;     through, the very object, before anything unwinds, a continuable
;;;     raise answered where it was raised; and the ms it refuses, against
;;;     the server's own rule;
;;;   - wrap-log directly, with a fake clock and test-req-done!: each status
;;;     and each ending, when the clock is read, newest first, nothing
;;;     caught, the port as it is then, flushed; through the test host, on
;;;     the host's clock; the default clock, Chez's real time across a real
;;;     sleep, bounded by the suite's own readings; the refusals;
;;;   - composed, (wrap app wrap-catch (wrap-timeout ms) wrap-log): the 504
;;;     and the 500 logged as written;
;;;   - around an upgrade, through the test host: wrap-catch passing one
;;;     through, wrap-timeout's deadline over the handler and not the
;;;     take-over, and wrap-log's line, 101 written, or 101 failed for a
;;;     switch the server refuses.
;;;
;;; What a row asserts:
;;;   - a row through the test host asserts the response whole, as its wire
;;;     bytes, one character a byte, with whether the connection ended, the
;;;     server's log, whole, each condition in it shown by its kind, who,
;;;     message and irritants, and all that was written to the current
;;;     output port; a row about the endings asserts them too; an upgrade
;;;     row asserts every byte the client read, the 101 and the taker's;
;;;   - a direct row asserts what the call answered or raised, the very
;;;     object where it says so, and the whole text written;
;;;   - a refusal row asserts the condition's kind, who, message and
;;;     irritants.
;;; Not held here: which escape each catch uses. One by call/1cc or guard
;;; answers the same, but for the unwinding rows, which take guard; the
;;; cost gate holds wrap-catch's by its bytes (G5).
;;; The test host's clock stays under a second, so a Date field reads
;;; Thu, 01 Jan 1970 00:00:00 GMT. The current output port is captured with
;;; Chez's parameterize over Chez's own current-output-port, which the
;;; (rnrs) one reads: the suite may use Chez, but never around a test.
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (only (chezscheme) parameterize real-time sleep make-time)
        ;; (rnrs)'s current-output-port is no parameter; it reads Chez's.
        (rename (only (chezscheme) current-output-port) (current-output-port chez:current-output-port))
        (circuit-testing)
        (http-server)
        (http-server testing)
        (only (http-server awaiting)
              make-deadline-passed make-client-closed make-body-failed make-resolve-error)
        (only (http-server private serve) log-line)
        (circuit)
        (circuit http-server)
        (circuit test)
        (circuit middleware waits))

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

;;; ------------------------------------------------------------------------
;;; Helpers

(define (b s) (string->utf8 s))

;; text : Bytevector -> String
;; BV one character a byte, so any bytes read back as they were sent.
(define (text bv)
  (let* ((n (bytevector-length bv)) (s (make-string n)))
    (let loop ((i 0))
      (if (= i n)
          s
          (begin (string-set! s i (integer->char (bytevector-u8-ref bv i)))
                 (loop (+ i 1)))))))

;; outcome : (-> Any) -> (U (List 'returned Any) (List 'raised Any))
;; What THUNK returned, or what it raised.
(define (outcome thunk)
  (guard (e (#t (list 'raised e)))
    (list 'returned (thunk))))

;; refusal : (-> Any) -> Any
;; What THUNK raised: (assertion WHO MESSAGE IRRITANTS) for an assertion
;; violation, (other TEXT) for anything else, and no-raise if it returned.
(define (refusal thunk)
  (guard (e ((assertion-violation? e)
             (list 'assertion
                   (and (who-condition? e) (condition-who e))
                   (and (message-condition? e) (condition-message e))
                   (and (irritants-condition? e) (condition-irritants e))))
            (#t (list 'other (describe e))))
    (thunk)
    'no-raise))

;; captured : (-> Any) -> (List (U (List 'returned Any) (List 'raised Any)) String)
;; THUNK's outcome, and all it wrote to the current output port, which is a
;; string port of the call's own while it runs.
(define (captured thunk)
  (let-values (((port extract) (open-string-output-port)))
    (let ((got (parameterize ((chez:current-output-port port)) (outcome thunk))))
      (list got (extract)))))

;; output : (-> Any) -> String — all THUNK wrote to the current output port.
(define (output thunk) (cadr (captured thunk)))

;; parts : Any -> Any — a res as its status, headers and body; else itself.
(define (parts r) (if (res? r) (list (res-status r) (res-headers r) (res-body r)) r))

;; settings : String ... -> (String -> (U String #f))
;; An environment procedure from NAME VALUE pairs; any other name is unset.
(define (settings . pairs)
  (let loop ((rest pairs) (alist '()))
    (if (null? rest)
        (lambda (name) (let ((hit (assoc name alist))) (and hit (cdr hit))))
        (loop (cddr rest) (cons (cons (car rest) (cadr rest)) alist)))))

(define unset (settings))

;; host-of : (Req -> Res) (String -> (U String #f)) -> TestHost
;; A test host for the adapter over APP, both reading ENV.
(define (host-of app env)
  (make-test-host (circuit->handler app env) env))

;; wire : TestClient -> (Listof String)
;; Each response the client read, as its bytes on the wire.
(define (wire c)
  (map (lambda (r) (text (test-response-bytes r))) (test-client-responses c)))

;; received : TestClient -> String — every byte the client read.
(define (received c) (text (test-client-received c)))

;; shown : Any -> Any
;; A detail of a log entry: a condition by its kind, who, message and
;; irritants; anything else as it is.
(define (shown d)
  (cond ((not (condition? d)) d)
        ((body-failed? d) (list 'body-failed (body-failed-status d) (body-failed-reason d)))
        (else (list (if (assertion-violation? d) 'assertion 'condition)
                    (and (who-condition? d) (condition-who d))
                    (and (message-condition? d) (condition-message d))
                    (and (irritants-condition? d) (condition-irritants d))))))

;; logged : TestHost -> (Listof Any) — what the server logged, in order.
(define (logged host)
  (map (lambda (entry) (cons (car entry) (map shown (cdr entry)))) (test-host-log host)))

;; hosted : (-> Any) -> (List Any String)
;; What THUNK, which drives a test host, answers, and all that was written
;; to the current output port while it ran: a host runs what it hosts
;; inside the test's calls, so its on-done procedures write there too.
(define (hosted thunk)
  (let-values (((port extract) (open-string-output-port)))
    (let ((got (parameterize ((chez:current-output-port port)) (thunk))))
      (list got (extract)))))

;; exchange : (Req -> Res) String [(String -> (U String #f))]
;;            -> (List (Listof String) Boolean (Listof Any) String)
;; One client sends REQUEST: what it read, whether the server ended the
;; connection, what the server logged, and what was written to the current
;; output port.
(define exchange
  (case-lambda
    ((app request) (exchange app request unset))
    ((app request env)
     (let ((seen (hosted (lambda ()
                           (let* ((host (host-of app env))
                                  (c (test-host-connect! host)))
                             (test-client-send! c (b request))
                             (list (wire c) (test-client-connection-closed? c) (logged host)))))))
       (append (car seen) (list (cadr seen)))))))

(define (get path) (string-append "GET " path " HTTP/1.1\r\nHost: x\r\n\r\n"))

;; response : String (Listof String) String -> String
;; A response as the server writes it in its first second: STATUS, Date,
;; FIELDS, BODY.
(define (response status fields body)
  (string-append "HTTP/1.1 " status "\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\n"
                 (apply string-append (map (lambda (f) (string-append f "\r\n")) fields))
                 "\r\n" body))

;; chunks : String ... -> String — each piece a chunk, then the last chunk.
(define (chunks . pieces)
  (string-append (apply string-append
                        (map (lambda (p)
                               (string-append (number->string (string-length p) 16) "\r\n" p "\r\n"))
                             pieces))
                 "0\r\n\r\n"))

(define chunked "Transfer-Encoding: chunked")
(define (length-field n) (string-append "Content-Length: " (number->string n)))
(define empty-500 (response "500 Internal Server Error" '("Content-Length: 0") ""))
(define empty-504 (response "504 Gateway Timeout" '("Content-Length: 0") ""))

;; producer : Nat String ... -> Producer
;; Each text's bytes in turn, each after a sleep of MS, then eof at once.
(define (producer ms . texts)
  (let ((left (map b texts)))
    (lambda ()
      (if (null? left)
          (eof-object)
          (begin
            (sleep-ms ms)
            (let ((piece (car left)))
              (set! left (cdr left))
              piece))))))

;; forever : Req -> Res — an app that awaits a resume nothing calls.
(define (forever r)
  (make-res 200 '() (await (lambda (resume) #f))))

;; make-clock : -> (Values (-> Nat) (Nat -> Void) (-> Nat))
;; A fake clock that reads the time a test sets, its setter, and how many
;; times it has been read.
(define (make-clock)
  (let ((now 0) (reads 0))
    (values (lambda () (set! reads (+ reads 1)) now)
            (lambda (t) (set! now t))
            (lambda () reads))))

;; recording-port : -> (Values TextualOutputPort (-> String))
;; A port, and the text that has reached it through its buffer: Chez
;; buffers a custom port, so text written and never flushed is not there.
(define (recording-port)
  (let ((got '()))
    (values (make-custom-textual-output-port
             "recording"
             (lambda (s start n) (set! got (cons (substring s start (+ start n)) got)) n)
             #f #f #f)
            (lambda () (apply string-append (reverse got))))))

;; A record type of the suite's own, and an opaque one, which R6RS's
;; record? doesn't see, so it is written: Chez writes it #<secret>.
(define-record-type point (fields x y))
(define-record-type (secret make-secret secret?) (fields x) (opaque #t))

;; The server's conditions as its waits raise them: the kind, a who and a
;; message.
(define (server-deadline)
  (condition (make-deadline-passed) (make-who-condition 'sleep-ms)
             (make-message-condition "the deadline has passed")))
(define (server-close)
  (condition (make-client-closed) (make-who-condition 'await)
             (make-message-condition "the client has closed")))

;; an-error : -> Condition — an &error with a who, a message and irritants.
(define (an-error)
  (condition (make-error) (make-who-condition 'app) (make-message-condition "refused")
             (make-irritants-condition '(7))))

;; no-on-raise : Req Any -> Any — an on-raise a row expects never called.
(define (no-on-raise req e) (list 'on-raise-called e))

;; default-line : Any -> (List Any String)
;; X raised by an app under wrap-catch with the default on-raise: the answer
;; as its parts, and the text written to the current output port.
(define (default-line x)
  (let ((seen (captured (lambda () ((wrap-catch (lambda (r) (raise x))) (make-test-req 'GET "/"))))))
    (list (let ((got (car seen))) (if (eq? (car got) 'returned) (parts (cadr got)) got))
          (cadr seen))))

;; server-line : Symbol (Listof Any) -> String
;; The line the server's log-line writes for WHAT and DETAILS: serve's log.
;; A raise is the text "raised", never an escape out of an expected value.
(define (server-line what details)
  (guard (e (#t "raised"))
    (output (lambda () (log-line what details)))))

(test-begin "middleware-waits")

;;; --- wrap-catch, called directly ---------------------------------------------

;; re-raised : (-> Condition) -> (List Boolean (Listof Any))
;; A condition MAKE builds, raised by the app under wrap-catch: whether the
;; caller's guard got the very one, and what on-raise saw.
(define (re-raised make)
  (let* ((c (make))
         (seen '())
         (wrapped (wrap-catch (lambda (r) (raise c))
                              (lambda (r e) (set! seen (cons e seen)) (make-res 500 '() #f))))
         (got (outcome (lambda () (wrapped (make-test-req 'GET "/catch"))))))
    (list (and (eq? (car got) 'raised) (eq? (cadr got) c)) seen)))

(test-equal "wrap-catch raises &deadline-passed again, the very condition, bare and as the server's waits raise it, on-raise never called"
  '((#t ()) (#t ()))
  (map re-raised (list make-deadline-passed server-deadline)))

(test-equal "wrap-catch raises &client-closed again, the very condition, bare and as the server's waits raise it, on-raise never called"
  '((#t ()) (#t ()))
  (map re-raised (list make-client-closed server-close)))

;; before-unwinding : (-> Condition) -> (Listof Any)
;; The app raises a condition MAKE builds inside a dynamic-wind, under
;; wrap-catch; the handler outside notes what it got and escapes. The
;; notes, in order: the handler's before the after thunk's means the
;; condition reached it from where it was raised, nothing unwound.
(define (before-unwinding make)
  (let* ((c (make))
         (notes '())
         (note! (lambda (x) (set! notes (cons x notes))))
         (wrapped (wrap-catch (lambda (r)
                                (dynamic-wind
                                  (lambda () (note! 'in))
                                  (lambda () (raise c))
                                  (lambda () (note! 'unwound))))
                              no-on-raise)))
    (call/cc
     (lambda (k)
       (with-exception-handler
        (lambda (e) (note! (list 'outside-got (eq? e c))) (k 'escaped))
        (lambda () (wrapped (make-test-req 'GET "/catch"))))))
    (reverse notes)))

(test-equal "wrap-catch raises both again from where they were raised: the handler outside has them before anything unwinds"
  '((in (outside-got #t) unwound) (in (outside-got #t) unwound))
  (map before-unwinding (list server-deadline server-close)))

;; continued : (-> Condition) -> Any
;; The app raises a condition MAKE builds continuably, for its status; the
;; handler outside wrap-catch answers 199 for it, and the app goes on.
(define (continued make)
  (let ((wrapped (wrap-catch (lambda (r) (make-res (+ 1 (raise-continuable (make))) '() #f))
                             no-on-raise)))
    (parts (with-exception-handler
            (lambda (e) (if (or (deadline-passed? e) (client-closed? e)) 199 'other))
            (lambda () (wrapped (make-test-req 'GET "/catch")))))))

(test-equal "wrap-catch raises both again as they were raised: a continuable raise the handler outside answers goes on where it was raised"
  '((200 () #f) (200 () #f))
  (map (lambda (make) (let ((got (outcome (lambda () (continued make)))))
                        (if (eq? (car got) 'returned) (cadr got) (list 'raised (describe (cadr got))))))
       (list make-deadline-passed make-client-closed)))

(test-equal "wrap-catch answers a &body-failed with its status, each one, and calls no on-raise"
  '(((400 () #f) ()) ((408 () #f) ()) ((413 () #f) ()) ((431 () #f) ()))
  (map (lambda (status)
         (let* ((seen '())
                (wrapped (wrap-catch (lambda (r) (raise (make-body-failed 'body-too-large status)))
                                     (lambda (r e) (set! seen (cons e seen)) (make-res 500 '() #f))))
                (got (outcome (lambda () (wrapped (make-test-req 'POST "/up"))))))
           (list (if (eq? (car got) 'returned) (parts (cadr got)) got) seen)))
       '(400 408 413 431)))

;; handed : Any -> (List Any Any Boolean)
;; X raised by the app under wrap-catch, with an on-raise that answers a res
;; of its own: whether on-raise saw the very request and the very X, and
;; whether its res is the answer.
(define (handed x)
  (let* ((req (make-test-req 'GET "/catch"))
         (mine (make-res 503 '(("x-mine" . "1")) "mine"))
         (seen '(on-raise-not-called on-raise-not-called))
         (wrapped (wrap-catch (lambda (r) (raise x))
                              (lambda (r e) (set! seen (list (eq? r req) (eq? e x))) mine)))
         (got (outcome (lambda () (wrapped req)))))
    (append seen (list (and (eq? (car got) 'returned) (eq? (cadr got) mine))))))

(test-equal "wrap-catch hands any other raise, condition or not, to on-raise with the request, and answers what it answers"
  '((#t #t #t) (#t #t #t) (#t #t #t) (#t #t #t) (#t #t #t) (#t #t #t) (#t #t #t))
  (map handed
       (list (an-error)
             (condition (make-assertion-violation) (make-who-condition 'car))
             (make-resolve-error 'EAI_NONAME)
             (make-warning)
             'a-symbol
             "a string"
             (make-point 1 2))))

;; handed-continuably : -> (List Boolean Boolean Boolean)
;; As handed, the app raising a warning continuably.
(define (handed-continuably)
  (let* ((req (make-test-req 'GET "/catch"))
         (w (make-warning))
         (mine (make-res 503 '() #f))
         (seen '(on-raise-not-called on-raise-not-called))
         (wrapped (wrap-catch (lambda (r) (make-res (raise-continuable w) '() #f))
                              (lambda (r e) (set! seen (list (eq? r req) (eq? e w))) mine)))
         (got (outcome (lambda () (wrapped req)))))
    (append seen (list (and (eq? (car got) 'returned) (eq? (cadr got) mine))))))

(test-equal "wrap-catch hands a continuable raise to on-raise too, which answers in its place"
  '(#t #t #t)
  (handed-continuably))

(test-equal "wrap-catch answers whatever on-raise answers, the very object, a res or not"
  '(#t #t)
  (map (lambda (answer)
         (let ((got (outcome (lambda () ((wrap-catch (lambda (r) (raise (an-error))) (lambda (r e) answer))
                                         (make-test-req 'GET "/catch"))))))
           (and (eq? (car got) 'returned) (eq? (cadr got) answer))))
       (list (list 'not 'a 'res) 'also-not-a-res)))

(test-equal "wrap-catch calls on-raise where the raise happened: before the app's dynamic extent unwinds"
  '(in (on-raise #t) unwound)
  (let* ((notes '())
         (note! (lambda (x) (set! notes (cons x notes))))
         (x (an-error))
         (wrapped (wrap-catch (lambda (r)
                                (dynamic-wind
                                  (lambda () (note! 'in))
                                  (lambda () (raise x))
                                  (lambda () (note! 'unwound))))
                              (lambda (r e) (note! (list 'on-raise (eq? e x))) (make-res 500 '() #f)))))
    (wrapped (make-test-req 'GET "/catch"))
    (reverse notes)))

(test-equal "wrap-catch lets a raise from on-raise reach its caller, the very object, called once"
  '(#t 1)
  (let* ((calls 0)
         (mine (make-message-condition "on-raise refused"))
         (wrapped (wrap-catch (lambda (r) (raise 'first))
                              (lambda (r e) (set! calls (+ calls 1)) (raise mine))))
         (got (outcome (lambda () (wrapped (make-test-req 'GET "/catch"))))))
    (list (and (eq? (car got) 'raised) (eq? (cadr got) mine)) calls)))

(test-equal "wrap-catch lets a raise of either condition from on-raise reach its caller, untaken"
  '(#t #t)
  (map (lambda (make)
         (let* ((c (make))
                (wrapped (wrap-catch (lambda (r) (raise 'first)) (lambda (r e) (raise c))))
                (got (outcome (lambda () (wrapped (make-test-req 'GET "/catch"))))))
           (and (eq? (car got) 'raised) (eq? (cadr got) c))))
       (list make-deadline-passed make-client-closed)))

(test-equal "wrap-catch with nothing raised answers the app's own answer, the very object, a res or not, on-raise never called"
  '(#t #t #t)
  (map (lambda (answer)
         (let ((got (outcome (lambda () ((wrap-catch (lambda (r) answer) no-on-raise)
                                         (make-test-req 'GET "/"))))))
           (and (eq? (car got) 'returned) (eq? (cadr got) answer))))
       (list (make-res 201 '(("x-own" . "yes")) "own") 'not-a-res (list "a" "list"))))

(test-equal "wrap-catch hands the app the very request"
  #t
  (let* ((req (make-test-req 'GET "/catch"))
         (seen #f))
    ((wrap-catch (lambda (r) (set! seen (eq? r req)) (make-res 200 '() #f))) req)
    seen))

;;; --- the default on-raise: its line and its 500 --------------------------------

(test-equal "the default on-raise answers an empty 500"
  '(500 () #f)
  (car (default-line 'oops)))

(test-equal "the default line: a condition as Chez's display-condition shows it"
  (list "handler-failed Exception in app: refused with irritant 7\n"
        "handler-failed Exception in app: refused with irritants (7 \"x\")\n"
        "handler-failed Exception in car: 5 is not a pair\n"
        "handler-failed Exception occurred with condition components:   0. &warning\n")
  (map (lambda (x) (cadr (default-line x)))
       (list (an-error)
             (condition (make-error) (make-who-condition 'app) (make-message-condition "refused")
                        (make-irritants-condition '(7 "x")))
             (guard (e (#t e)) (car (car (list 5))))
             (make-warning))))

(test-equal "the default line: a condition's line breaks made spaces, and nothing else changed"
  (list "handler-failed Exception in app: two lines\n"
        "handler-failed Exception in app: one\r two with irritant \"x\\ny\"\n")
  (map (lambda (x) (cadr (default-line x)))
       (list (condition (make-who-condition 'app) (make-message-condition "two\nlines"))
             (condition (make-who-condition 'app) (make-message-condition "one\r\ntwo")
                        (make-irritants-condition '("x\ny"))))))

(test-equal "the default line: a string, a symbol, a number, a boolean and a character displayed"
  (list "handler-failed a \"quoted\" string\n"
        "handler-failed oops\n"
        "handler-failed two words\n"
        "handler-failed 42\n"
        "handler-failed 3/4\n"
        "handler-failed 1.5\n"
        "handler-failed #f\n"
        "handler-failed x\n")
  (map (lambda (x) (cadr (default-line x)))
       (list "a \"quoted\" string" 'oops (string->symbol "two words") 42 3/4 1.5 #f #\x)))

(test-equal "the default line: a record as #< its record type's name >, an opaque one written"
  (list "handler-failed #<point>\n" "handler-failed #<secret>\n")
  (map (lambda (x) (cadr (default-line x)))
       (list (make-point 1 "two") (make-secret 3))))

(test-equal "the default line: anything else written"
  (list "handler-failed (1 \"a\" #\\b)\n"
        "handler-failed #(1 \"a\")\n"
        "handler-failed #vu8(104 105)\n")
  (map (lambda (x) (cadr (default-line x)))
       (list (list 1 "a" #\b) (vector 1 "a") (b "hi"))))

(test-equal "the default line is flushed at once: it has left the port's buffer when on-raise returns"
  "handler-failed oops\n"
  (let-values (((port got) (recording-port)))
    (parameterize ((chez:current-output-port port))
      ((wrap-catch (lambda (r) (raise 'oops))) (make-test-req 'GET "/")))
    (got)))

(test-equal "the default line goes to the current output port as it is when on-raise runs"
  '("" "handler-failed oops\n")
  (let-values (((early take-early) (open-string-output-port))
               ((late take-late) (open-string-output-port)))
    (let ((wrapped (parameterize ((chez:current-output-port early))
                     (wrap-catch (lambda (r) (raise 'oops))))))
      (parameterize ((chez:current-output-port late))
        (wrapped (make-test-req 'GET "/")))
      (list (take-early) (take-late)))))

;;; --- wrap-catch's refusals -------------------------------------------------------

(test-equal "wrap-catch refuses a handler that is no procedure, when it is called"
  '((assertion wrap-catch "a handler is a procedure" (not-a-handler))
    (assertion wrap-catch "a handler is a procedure" (#f)))
  (list (refusal (lambda () (wrap-catch 'not-a-handler)))
        (refusal (lambda () (wrap-catch #f no-on-raise)))))

(test-equal "wrap-catch refuses an on-raise that is no procedure, when it is called"
  '(assertion wrap-catch "on-raise is a procedure of a req and what was raised" ("not-on-raise"))
  (refusal (lambda () (wrap-catch (lambda (r) (make-res 200 '() #f)) "not-on-raise"))))

;;; --- wrap-catch through the test host --------------------------------------------

(test-equal "through the host, a body that fails while the app reads it, past the cap, is answered with its status; the connection then closes, and the response ends written"
  (list (list (response "413 Content Too Large" '("Content-Length: 0" "Connection: close") ""))
        #t '() "" '(written))
  (let* ((endings '())
         (app (wrap-catch (lambda (r)
                            (req-on-done! r (lambda (ending) (set! endings (cons ending endings))))
                            (make-res 200 '() (get-bytevector-all (req-body r))))))
         (result (exchange app
                           "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n123456789\r\n0\r\n\r\n"
                           (settings "CHEZ_HTTP_MAX_BODY_BYTES" "4"))))
    (append result (list endings))))

(test-equal "through the host, a raise after a park is answered 500, its line written"
  (list '() (list empty-500) #f '() "handler-failed Exception in app: boom\n")
  (let ((seen (hosted (lambda ()
                        (let* ((host (host-of (wrap-catch (lambda (r) (sleep-ms 10) (error 'app "boom")))
                                              unset))
                               (c (test-host-connect! host)))
                          (test-client-send! c (b (get "/boom")))
                          (let ((before (wire c)))
                            (test-host-advance! host 10)
                            (list before (wire c) (test-client-connection-closed? c) (logged host))))))))
    (append (car seen) (list (cadr seen)))))

(test-equal "through the host, a client's close is raised again: nothing answered, nothing logged, no line, the response ended client-closed"
  (list '() #t '() "" '(client-closed))
  (let* ((endings '())
         (seen (hosted (lambda ()
                         (let* ((host (host-of (wrap-catch (lambda (r)
                                                             (req-on-done! r (lambda (ending) (set! endings (cons ending endings))))
                                                             (sleep-ms 10)
                                                             (make-res 200 '() "late")))
                                               unset))
                                (c (test-host-connect! host)))
                           (test-client-send! c (b (get "/wait")))
                           (test-client-close! c)
                           (test-host-advance! host 10)
                           (list (wire c) (test-client-connection-closed? c) (logged host)))))))
    (append (car seen) (list (cadr seen) endings))))

;;; --- the default line agrees with the server's own ------------------------------

;; Raises of every kind put-detail tells apart, and its edges: conditions
;; with line breaks in their text, and with the other breaks Unicode names
;; (a vertical tab, a form feed, NEL, LINE SEPARATOR), which stay as they
;; are, only a line feed made a space; Chez's own records (an rtd, a
;; hashtable), an opaque record, a procedure, the eof object; a string and a
;; character holding a line feed, which the server displays as it is, so
;; its line is two, and the other break characters, displayed too. Not the
;; three conditions wrap-catch hands no on-raise.
(define raises
  (list (an-error)
        (condition (make-who-condition 'app) (make-message-condition "one\r\ntwo\nthree")
                   (make-irritants-condition '("x\ny" #\z)))
        (guard (e (#t e)) (car (car (list 5))))
        (guard (e (#t e)) (error 'app "with\nbreaks" 1 "two"))
        (condition (make-who-condition 'app)
                   (make-message-condition "vt\x0B;ff\x0C;nel\x85;ls\x2028;end"))
        (make-resolve-error 'EAI_NONAME)
        (make-warning) (condition)
        "a \"quoted\"\nstring" 'oops (string->symbol "two words") 42 -7 3/4 1.5 +inf.0
        #t #f #\x #\newline #\x0B #\x85 #\x2028
        (make-point 1 "two") (make-secret 3) (record-type-descriptor point)
        (make-eq-hashtable)
        (list 1 "a" #\b) (vector 1 "a") (b "hi") (eof-object) car (lambda () 1) '()))

(test-equal "the default line is the line the server's log-line writes for the same raise, for a raise of each kind"
  (map (lambda (x) (server-line 'handler-failed (list x))) raises)
  (map (lambda (x) (cadr (default-line x))) raises))

;; Through the host: a raise that reaches the server, unwrapped, is logged
;; (handler-failed X); serve writes that entry with log-line. The same raise
;; under wrap-catch writes the default line.
(define hosted-raises
  (list (an-error) 'oops "a string" (make-point 1 2) (list 1 "a")
        (condition (make-who-condition 'app) (make-message-condition "two\nlines"))))

;; server-logged : Any -> (List Boolean String)
;; X raised by an unwrapped app through the host: whether the host logged
;; it alone, as (handler-failed X) with the very X, and the line log-line
;; writes for that entry.
(define (server-logged x)
  (let* ((host (host-of (lambda (r) (raise x)) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (get "/")))
    (let ((log (test-host-log host)))
      (list (and (= (length log) 1) (eq? (caar log) 'handler-failed)
                 (= (length (cdar log)) 1) (eq? (cadar log) x))
            (server-line (caar log) (cdar log))))))

;; circuit-logged : Any -> String
;; X raised by the app under wrap-catch through the host: the line written.
(define (circuit-logged x)
  (cadr (hosted (lambda ()
                  (let* ((host (host-of (wrap-catch (lambda (r) (raise x))) unset))
                         (c (test-host-connect! host)))
                    (test-client-send! c (b (get "/")))
                    (wire c))))))

(test-equal "through the host, the default line is the line serve writes for the entry the server logs when the same raise reaches it"
  (map (lambda (x) (guard (e (#t (list 'raised (describe e)))) (server-logged x))) hosted-raises)
  (map (lambda (x) (list #t (circuit-logged x))) hosted-raises))

;;; --- wrap-timeout through the test host ------------------------------------------

(test-equal "wrap-timeout answers 504 when the app awaits past the deadline, at the instant the clock passes it, and not before"
  (list '(() #t) (list empty-504) #f '() "")
  (let ((seen (hosted (lambda ()
                        (let* ((host (host-of ((wrap-timeout 100) forever) unset))
                               (c (test-host-connect! host)))
                          (test-client-send! c (b (get "/slow")))
                          (test-host-advance! host 99)
                          (let ((before (list (wire c) (test-client-waiting? c))))
                            (test-host-advance! host 1)
                            (list before (wire c) (test-client-connection-closed? c) (logged host))))))))
    (append (car seen) (list (cadr seen)))))

(test-equal "wrap-timeout's 504 is (make-res 504 '() #f): middleware outside it sees the res whole, no headers and no body"
  (list '(504 () #f) (list empty-504))
  (let* ((seen 'not-reached)
         (inner ((wrap-timeout 100) forever))
         (host (host-of (lambda (r) (let ((answer (inner r))) (set! seen (parts answer)) answer)) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (get "/slow")))
    (test-host-advance! host 100)
    (list seen (wire c))))

(test-equal "wrap-timeout's deadline covers a body read that stalls: 504 at the deadline, the connection then closed"
  (list '() (list (response "504 Gateway Timeout" '("Content-Length: 0" "Connection: close") "")) #t '())
  (let* ((host (host-of ((wrap-timeout 100)
                         (lambda (r) (make-res 200 '() (get-bytevector-all (req-body r)))))
                        unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhe"))
    (test-host-advance! host 99)
    (let ((before (wire c)))
      (test-host-advance! host 1)
      (list before (wire c) (test-client-connection-closed? c) (logged host)))))

(test-equal "wrap-timeout 0 is a deadline already passed: 504 at the first wait, with no advance"
  (list (list empty-504) #f '())
  (let* ((host (host-of ((wrap-timeout 0) forever) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (get "/now")))
    (list (wire c) (test-client-connection-closed? c) (logged host))))

(test-equal "wrap-timeout 0 leaves a handler that doesn't wait untouched: the very res"
  (list (list (response "201 Created" (list "x-own: yes" (length-field 4)) "mine")) #f '() "" #t)
  (let* ((own (make-res 201 '(("x-own" . "yes")) "mine"))
         (seen #f)
         (inner ((wrap-timeout 0) (lambda (r) own)))
         (result (exchange (lambda (r) (let ((answer (inner r))) (set! seen (eq? answer own)) answer))
                           (get "/"))))
    (append result (list seen))))

(test-equal "wrap-timeout never covers a producer: one that sleeps past the deadline before each piece still streams whole"
  (let ((top (response "200 OK" (list chunked) "")))
    (list top (string-append top "3\r\nabc\r\n")
          (list (response "200 OK" (list chunked) (chunks "abc" "de")))
          #f '()))
  (let* ((host (host-of ((wrap-timeout 100) (lambda (r) (make-res 200 '() (producer 150 "abc" "de"))))
                        unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (get "/stream")))
    (let* ((at-0 (received c))
           (at-150 (begin (test-host-advance! host 150) (received c))))
      (test-host-advance! host 150)
      (list at-0 at-150 (wire c) (test-client-connection-closed? c) (logged host)))))

(test-equal "wrap-timeout leaves an answer given without waiting untouched: the very res"
  (list (list (response "201 Created" (list "x-own: yes" (length-field 4)) "mine")) #f '() "" #t)
  (let* ((own (make-res 201 '(("x-own" . "yes")) "mine"))
         (seen #f)
         (inner ((wrap-timeout 100) (lambda (r) own)))
         (result (exchange (lambda (r) (let ((answer (inner r))) (set! seen (eq? answer own)) answer))
                           (get "/"))))
    (append result (list seen))))

(test-equal "wrap-timeout passes everything else through untouched: the handler outside it has the very object"
  '(#t #t #t #t #t)
  (map (lambda (x)
         (let* ((seen 'not-reached)
                (inner ((wrap-timeout 100) (lambda (r) (raise x))))
                (app (lambda (r)
                       (guard (e (#t (set! seen (eq? e x)) (make-res 200 '() #f)))
                         (inner r)))))
           (exchange app (get "/"))
           seen))
       (list (make-client-closed) (make-body-failed 'body-too-large 413) (an-error) 'a-symbol
             (make-point 1 2))))

(test-equal "wrap-timeout passes everything else through from where it was raised: the handler outside has it before anything unwinds"
  '(in (outside-got #t) unwound)
  (let* ((x (an-error))
         (notes '())
         (note! (lambda (n) (set! notes (cons n notes))))
         (inner ((wrap-timeout 100)
                 (lambda (r) (dynamic-wind (lambda () (note! 'in)) (lambda () (raise x)) (lambda () (note! 'unwound))))))
         (app (lambda (r)
                (call/cc
                 (lambda (k)
                   (with-exception-handler
                    (lambda (e) (note! (list 'outside-got (eq? e x))) (k (make-res 200 '() #f)))
                    (lambda () (inner r))))))))
    (exchange app (get "/"))
    (reverse notes)))

(test-equal "wrap-timeout passes a continuable raise through as it was raised: the handler outside answers it where it was raised"
  (list (list (response "200 OK" (list (length-field 2)) "ok")) #f '() "")
  (let ((inner ((wrap-timeout 100)
                (lambda (r) (make-res (+ 1 (raise-continuable 'which-status?)) '() "ok")))))
    (exchange (lambda (r) (with-exception-handler (lambda (e) 199) (lambda () (inner r))))
              (get "/"))))

(test-equal "wrap-timeout passes a client's close through: nothing answered, nothing logged"
  (list '() #t '() "")
  (let ((seen (hosted (lambda ()
                        (let* ((host (host-of ((wrap-timeout 100)
                                               (lambda (r) (sleep-ms 50) (make-res 200 '() "late")))
                                              unset))
                               (c (test-host-connect! host)))
                          (test-client-send! c (b (get "/wait")))
                          (test-client-close! c)
                          (test-host-advance! host 100)
                          (list (wire c) (test-client-connection-closed? c) (logged host)))))))
    (append (car seen) (list (cadr seen)))))

(test-equal "wrap-timeout called off a coroutine lets with-deadline's own refusal through"
  'with-deadline
  (let ((got (refusal (lambda () (((wrap-timeout 100) (lambda (r) (make-res 200 '() #f)))
                                  (make-test-req 'GET "/"))))))
    (if (and (pair? got) (eq? (car got) 'assertion)) (cadr got) got)))

;;; --- wrap-timeout's refusals ------------------------------------------------------

;; Every ms below: the whole numbers with-deadline takes, and the values it
;; refuses beside them.
(define taken-ms (list 0 1 100 (expt 2 70)))
(define refused-ms (list -1 1.0 0.0 -0.0 3/2 +inf.0 +nan.0 (- (expt 2 70)) 'ms "5" #f 1+2i))

;; with-deadline-refuses? : Any -> Boolean
;; Whether the server's with-deadline refuses MS for itself: off a
;; coroutine it refuses every call, but with another message for an ms it
;; takes.
(define (with-deadline-refuses? ms)
  (equal? (refusal (lambda () (with-deadline ms (lambda () #f))))
          (list 'assertion 'with-deadline "expected a whole number of milliseconds" (list ms))))

;; wrap-timeout-refuses? : Any -> Boolean
(define (wrap-timeout-refuses? ms)
  (equal? (refusal (lambda () (wrap-timeout ms)))
          (list 'assertion 'wrap-timeout "expected a whole number of milliseconds" (list ms))))

(test-equal "wrap-timeout refuses, when it is called, every ms with-deadline would refuse, and takes the rest"
  (map with-deadline-refuses? (append taken-ms refused-ms))
  (map wrap-timeout-refuses? (append taken-ms refused-ms)))

(test-equal "wrap-timeout takes a whole number of milliseconds, 0 and past a fixnum included, and refuses any other"
  (append (map (lambda (ms) #f) taken-ms) (map (lambda (ms) #t) refused-ms))
  (map wrap-timeout-refuses? (append taken-ms refused-ms)))

(test-equal "wrap-timeout's middleware refuses a handler that is no procedure, when it is applied"
  '(assertion wrap-timeout "a handler is a procedure" (not-a-handler))
  (refusal (lambda () ((wrap-timeout 100) 'not-a-handler))))

;;; --- wrap-log, called directly ------------------------------------------------------

;; log-direct : Symbol String (Req -> Any) Symbol
;;              -> (List (U (List 'returned Any) (List 'raised Any)) String (Listof Any) Nat)
;; A request for METHOD and TARGET through (wrap-log APP clock), on a fake
;; clock at 1000 when it is called and at 1002 once APP runs; then its
;; response ended with ENDING at 1007: what the call gave, the text written
;; then, what test-req-done! answered, and how many times the clock was
;; read.
(define (log-direct method target app ending)
  (let-values (((clock set-now! reads) (make-clock)))
    (let* ((r (make-test-req method target))
           (wrapped (wrap-log (lambda (r) (set-now! 1002) (app r)) clock)))
      (set-now! 1000)
      (let ((got (outcome (lambda () (wrapped r)))))
        (set-now! 1007)
        (let ((done (captured (lambda () (test-req-done! r ending)))))
          (list got (cadr done) (car done) (reads)))))))

(define own-res (make-res 200 '(("x-own" . "yes")) "own"))

(test-equal "wrap-log, a res: its status, for each ending, the path without its query, the clock read at the call and at the end"
  (list (list '(returned own) "request GET /users/7 200 written 7\n" '(returned ()) 2)
        (list '(returned own) "request GET /users/7 200 client-closed 7\n" '(returned ()) 2)
        (list '(returned own) "request GET /users/7 200 failed 7\n" '(returned ()) 2))
  (map (lambda (ending)
         (let ((seen (log-direct 'GET "/users/7?x=1&y=2" (lambda (r) own-res) ending)))
           (cons (if (equal? (car seen) (list 'returned own-res)) '(returned own) (car seen))
                 (cdr seen))))
       '(written client-closed failed)))

(test-equal "wrap-log, a raise: raised, the raise gone on untouched, the very object"
  (list '(raised own) "request POST /up raised failed 7\n" '(returned ()) 2)
  (let* ((x (an-error))
         (seen (log-direct 'POST "/up" (lambda (r) (raise x)) 'failed)))
    (cons (if (equal? (car seen) (list 'raised x)) '(raised own) (car seen)) (cdr seen))))

(test-equal "wrap-log catches nothing: a raise reaches the handler outside before anything unwinds, and a continuable one is answered where it was raised"
  '((in (outside-got #t) unwound) (200 () #f))
  (let-values (((clock set-now! reads) (make-clock)))
    (let* ((x (an-error))
           (notes '())
           (note! (lambda (n) (set! notes (cons n notes))))
           (raising (wrap-log (lambda (r) (dynamic-wind (lambda () (note! 'in))
                                                        (lambda () (raise x))
                                                        (lambda () (note! 'unwound))))
                              clock))
           (asking (wrap-log (lambda (r) (make-res (+ 1 (raise-continuable 'which-status?)) '() #f)) clock)))
      (call/cc
       (lambda (k)
         (with-exception-handler
          (lambda (e) (note! (list 'outside-got (eq? e x))) (k 'escaped))
          (lambda () (raising (make-test-req 'GET "/"))))))
      (list (reverse notes)
            (let ((got (outcome (lambda ()
                                  (with-exception-handler (lambda (e) 199)
                                                          (lambda () (asking (make-test-req 'GET "/"))))))))
              (if (eq? (car got) 'returned) (parts (cadr got)) (list 'raised (describe (cadr got)))))))))

(test-equal "wrap-log, an answer that is no res: -, the answer returned as it is"
  (list '(returned own) "request DELETE /thing - written 7\n" '(returned ()) 2)
  (let* ((answer (list 'not 'a 'res))
         (seen (log-direct 'DELETE "/thing" (lambda (r) answer) 'written)))
    (cons (if (and (eq? (caar seen) 'returned) (eq? (cadar seen) answer)) '(returned own) (car seen))
          (cdr seen))))

(test-equal "wrap-log, an answer that is no res but looks like a status, a number or a symbol: -"
  '("request GET /n - written 7\n" "request GET /n - written 7\n" "request GET /n - written 7\n")
  (map (lambda (answer) (cadr (log-direct 'GET "/n" (lambda (r) answer) 'written)))
       (list 200 404.0 'raised)))

(test-equal "wrap-log, a status other than 200, read from the res"
  "request PUT /a 418 written 7\n"
  (cadr (log-direct 'PUT "/a" (lambda (r) (make-res 418 '() #f)) 'written)))

(test-equal "wrap-log hands the app the very request, and writes nothing until the response ends"
  '(#t "")
  (let-values (((clock set-now! reads) (make-clock)))
    (let* ((req (make-test-req 'GET "/"))
           (seen #f)
           (wrapped (wrap-log (lambda (r) (set! seen (eq? r req)) own-res) clock))
           (written (output (lambda () (wrapped req)))))
      (list seen written))))

(test-equal "wrap-log registers first, so it hears last: after a procedure registered inside it, before one registered outside"
  "inner\nrequest GET /order 204 written 0\nouter\n"
  (let-values (((clock set-now! reads) (make-clock)))
    (let* ((r (make-test-req 'GET "/order"))
           (say (lambda (s) (lambda (ending) (put-string (current-output-port) s))))
           (wrapped (wrap-log (lambda (r) (req-on-done! r (say "inner\n")) (make-res 204 '() #f)) clock)))
      (req-on-done! r (say "outer\n"))
      (wrapped r)
      (output (lambda () (test-req-done! r 'written))))))

(test-equal "wrap-log registers before calling the app: a raising app's response is still logged"
  "request GET /raise raised failed 0\n"
  (let-values (((clock set-now! reads) (make-clock)))
    (let* ((r (make-test-req 'GET "/raise"))
           (wrapped (wrap-log (lambda (r) (raise 'boom)) clock)))
      (outcome (lambda () (wrapped r)))
      (output (lambda () (test-req-done! r 'failed))))))

(test-equal "wrap-log writes to the current output port as it is when the response ends"
  '("" "" "request GET / 200 written 0\n")
  (let-values (((clock set-now! reads) (make-clock))
               ((at-wrap take-wrap) (open-string-output-port))
               ((at-call take-call) (open-string-output-port))
               ((at-end take-end) (open-string-output-port)))
    (let* ((r (make-test-req 'GET "/"))
           (wrapped (parameterize ((chez:current-output-port at-wrap)) (wrap-log (lambda (r) own-res) clock))))
      (parameterize ((chez:current-output-port at-call)) (wrapped r))
      (parameterize ((chez:current-output-port at-end)) (test-req-done! r 'written))
      (list (take-wrap) (take-call) (take-end)))))

(test-equal "wrap-log's line is flushed at once, for each ending: it has left the port's buffer when the procedure returns"
  '("request GET / 200 written 0\n" "request GET / 200 client-closed 0\n" "request GET / 200 failed 0\n")
  (map (lambda (ending)
         (let-values (((clock set-now! reads) (make-clock))
                      ((port got) (recording-port)))
           (let* ((r (make-test-req 'GET "/"))
                  (wrapped (wrap-log (lambda (r) own-res) clock)))
             (wrapped r)
             (parameterize ((chez:current-output-port port)) (test-req-done! r ending))
             (got))))
       '(written client-closed failed)))

(test-equal "wrap-log's default clock gives a line whose MS is a whole number of milliseconds"
  '("request GET /clock 200 written" #t)
  (let* ((r (make-test-req 'GET "/clock"))
         (wrapped (wrap-log (lambda (r) own-res))))
    (wrapped r)
    (let* ((line (output (lambda () (test-req-done! r 'written))))
           (n (string-length line))
           (space (let loop ((i (- n 1))) (cond ((< i 0) #f) ((char=? (string-ref line i) #\space) i) (else (loop (- i 1)))))))
      (if (and space (> n 0) (char=? (string-ref line (- n 1)) #\newline))
          (let ((ms (string->number (substring line (+ space 1) (- n 1)) 10)))
            (list (substring line 0 space) (and ms (integer? ms) (exact? ms) (>= ms 0))))
          (list 'not-a-line line)))))

;; real-timed : Nat -> (List Integer Integer Integer)
;; A request through (wrap-log app) on the default clock, its response ended
;; after a real sleep of SLEEP ms: the line's MS, and the least and most it
;; can be on Chez's real-time. The suite reads real-time just before and
;; after each of wrap-log's readings, so on the same clock, whose readings
;; never go back, the first lies in [before, called] and the second in
;; [slept, after]: MS lies in [slept - called, after - before]. Nothing
;; slow runs between a pair, so the span is a ms or two wide. #f for MS
;; when the line is no request line.
(define (real-timed sleep-for)
  (let* ((r (make-test-req 'GET "/clock"))
         (wrapped (wrap-log (lambda (r) own-res)))
         (before (real-time))
         (answer (wrapped r))
         (called (real-time)))
    (sleep (make-time 'time-duration (* sleep-for 1000000) 0))
    (let-values (((port extract) (open-string-output-port)))
      (let* ((slept (real-time))
             (done (parameterize ((chez:current-output-port port)) (test-req-done! r 'written)))
             (after (real-time))
             (line (extract))
             (n (string-length line))
             (prefix "request GET /clock 200 written ")
             (m (string-length prefix))
             (ms (and (> n m) (string=? (substring line 0 m) prefix)
                      (char=? (string-ref line (- n 1)) #\newline)
                      (string->number (substring line m (- n 1)) 10))))
        (list ms (- slept called) (- after before))))))

;; A clock coarser than real-time gives an MS that is a multiple of its
;; step. Two sleeps, neither near a multiple of 10 ms, put a 10 ms clock
;; outside the span unless a loaded machine widens both spans past one.
(test-equal "wrap-log's default clock is Chez's real time: across a real sleep, MS lies between the suite's own real-time readings around wrap-log's two"
  '((#t #t) (#t #t))
  (map (lambda (sleep-for)
         (let* ((seen (real-timed sleep-for))
                (ms (car seen)) (least (cadr seen)) (most (caddr seen)))
           (if ms
               (list (<= least ms most) (>= least (- sleep-for 1)))
               (list 'not-a-line seen))))
       '(23 37)))

(test-equal "wrap-log refuses a handler or a clock that is no procedure, when it is called"
  '((assertion wrap-log "a handler is a procedure" (not-a-handler))
    (assertion wrap-log "a handler is a procedure" (#f))
    (assertion wrap-log "a clock is a procedure of no arguments that reads milliseconds" (1000)))
  (list (refusal (lambda () (wrap-log 'not-a-handler)))
        (refusal (lambda () (wrap-log #f (lambda () 0))))
        (refusal (lambda () (wrap-log (lambda (r) own-res) 1000)))))

;;; --- wrap-log through the test host --------------------------------------------------

;; logged-through : (Req -> Res) (TestHost TestClient -> Any) -> (List String Boolean (Listof Any) String)
;; APP under wrap-log on the host's own clock, a client sending a GET for
;; /logged, then STEPS acting on the host and its client: what the client
;; read, whether the connection ended and the log, then the text written.
(define (logged-through app steps)
  (logged-through-sending app (get "/logged?q=1") steps))

;; logged-through-sending : (Req -> Res) String (TestHost TestClient -> Any)
;;                          -> (List String Boolean (Listof Any) String)
;; As logged-through, the client sending REQUEST.
(define (logged-through-sending app request steps)
  (let* ((host #f)
         (seen (hosted (lambda ()
                         (set! host (host-of (wrap-log app (lambda () (test-host-now host))) unset))
                         (let ((c (test-host-connect! host)))
                           (test-client-send! c (b request))
                           (steps host c)
                           (list (received c) (test-client-connection-closed? c) (logged host)))))))
    (append (car seen) (list (cadr seen)))))

(test-equal "through the host, wrap-log writes a written response's line, MS the host's advance"
  (list (response "200 OK" (list (length-field 2)) "ok") #f '() "request GET /logged 200 written 30\n")
  (logged-through (lambda (r) (sleep-ms 30) (make-res 200 '() "ok"))
                  (lambda (host c) (test-host-advance! host 30))))

(test-equal "through the host, a client that closes mid-stream: client-closed"
  (list (string-append (response "200 OK" (list chunked) "") "4\r\nabcd\r\n") #t '()
        "request GET /logged 200 client-closed 10\n")
  (logged-through (lambda (r) (make-res 200 '() (producer 10 "abcd" "efgh")))
                  (lambda (host c) (test-host-advance! host 10) (test-client-close! c))))

(test-equal "through the host, a producer that raises after the head: failed, the raise logged by the server"
  (list (response "200 OK" (list chunked) "") #t
        '((handler-failed (assertion producer "refused" (7))))
        "request GET /logged 200 failed 20\n")
  (logged-through (lambda (r) (make-res 200 '() (lambda () (sleep-ms 20) (assertion-violation 'producer "refused" 7))))
                  (lambda (host c) (test-host-advance! host 20))))

(test-equal "through the host, an app that raises: raised, the server's 500 failed"
  (list (response "500 Internal Server Error" '("Content-Length: 0" "Connection: close") "") #t
        '((handler-failed (assertion app "refused" (7))))
        "request GET /logged raised failed 5\n")
  (logged-through (lambda (r) (sleep-ms 5) (assertion-violation 'app "refused" 7))
                  (lambda (host c) (test-host-advance! host 5))))

;;; --- composed ------------------------------------------------------------------------

;; composed : (Req -> Res) ((Req -> Res) -> (Req -> Res)) String Nat -> (List Any String)
;; APP as (wrap app wrap-catch (wrap-timeout 100) LOG), LOG made from the
;; host by MAKE-LOG, a client asking for PATH, the host advanced by MS: what
;; the client read, whether the connection ended and the log, then the text
;; written.
(define (composed app make-log path ms)
  (let* ((host #f)
         (seen (hosted (lambda ()
                         (set! host (host-of (wrap app wrap-catch (wrap-timeout 100) (make-log (lambda () host)))
                                             unset))
                         (let ((c (test-host-connect! host)))
                           (test-client-send! c (b (get path)))
                           (test-host-advance! host ms)
                           (list (wire c) (test-client-connection-closed? c) (logged host)))))))
    (append (car seen) (list (cadr seen)))))

;; on-host-clock : (-> TestHost) -> Middleware — wrap-log on the host's clock.
(define (on-host-clock host)
  (lambda (h) (wrap-log h (lambda () (test-host-now (host))))))

(test-equal "composed, an app that awaits past the timeout: the deadline passes the catch, the timeout answers 504, logged written"
  (list (list empty-504) #f '() "request GET /slow 504 written 100\n")
  (composed forever on-host-clock "/slow" 100))

(test-equal "composed, an app that raises after a park: the catch answers 500, its line, then the log's"
  (list (list empty-500) #f '() "handler-failed Exception in app: boom\nrequest GET /boom 500 written 10\n")
  (composed (lambda (r) (sleep-ms 10) (error 'app "boom")) on-host-clock "/boom" 10))

;; ms-blanked : String -> String
;; TEXT with each request line's MS, its last field, as N when it is a whole
;; number, so a line on the default clock is asserted whole but for it.
(define (ms-blanked text)
  (let loop ((lines (split-lines text)) (out ""))
    (if (null? lines)
        out
        (loop (cdr lines) (string-append out (blank-ms (car lines)) "\n")))))

(define (split-lines text)
  (let loop ((i 0) (start 0) (found '()))
    (cond ((= i (string-length text))
           (reverse (if (< start i) (cons (substring text start i) found) found)))
          ((char=? (string-ref text i) #\newline)
           (loop (+ i 1) (+ i 1) (cons (substring text start i) found)))
          (else (loop (+ i 1) start found)))))

(define (blank-ms line)
  (let loop ((i (- (string-length line) 1)))
    (cond ((< i 0) line)
          ((char=? (string-ref line i) #\space)
           (let ((ms (string->number (substring line (+ i 1) (string-length line)) 10)))
             (if (and ms (exact? ms) (integer? ms) (>= ms 0)
                      (>= (string-length line) 8) (string=? (substring line 0 8) "request "))
                 (string-append (substring line 0 i) " N")
                 line)))
          (else (loop (- i 1))))))

;; list-head* : (Listof Any) Nat -> (Listof Any) — the first N of L.
(define (list-head* l n) (if (= n 0) '() (cons (car l) (list-head* (cdr l) (- n 1)))))

(test-equal "composed as the design writes it, (wrap app wrap-catch (wrap-timeout ms) wrap-log), on the default clock: 504 and 500, each logged written"
  (list (list (list empty-504) #f '() "request GET /slow 504 written N\n")
        (list (list empty-500) #f '() "handler-failed Exception in app: boom\nrequest GET /boom 500 written N\n"))
  (map (lambda (seen) (append (list-head* seen 3) (list (ms-blanked (list-ref seen 3)))))
       (list (composed forever (lambda (host) wrap-log) "/slow" 100)
             (composed (lambda (r) (sleep-ms 10) (error 'app "boom")) (lambda (host) wrap-log) "/boom" 10))))

;;; --- around an upgrade -----------------------------------------------------------------

(define upgrade-request "GET /chat HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: echo\r\n\r\n")

;; switching : (Listof String) -> String
;; The 101 as the server writes it: FIELDS, then its own Connection:
;; upgrade. A 1xx carries no Date.
(define (switching fields)
  (string-append "HTTP/1.1 101 Switching Protocols\r\n"
                 (apply string-append (map (lambda (f) (string-append f "\r\n")) fields))
                 "Connection: upgrade\r\n\r\n"))

;; greeter : Transport Bytevector -> Any — a take-over that writes hello.
(define (greeter t retained) (transport-write! t (b "hello")))

;; upgrading : Req -> Res — an app that answers an upgrade, greeter taking over.
(define (upgrading r) (make-upgrade-res '(("Upgrade" . "echo")) greeter))

;; switched : (Req -> Res) String Nat -> (List String Boolean (Listof Any) String)
;; APP on the host, a client sending REQUEST, the host advanced by MS: every
;; byte the client read, whether the connection ended and the log, then
;; the text written.
(define (switched app request ms)
  (let ((seen (hosted (lambda ()
                        (let* ((host (host-of app unset))
                               (c (test-host-connect! host)))
                          (test-client-send! c (b request))
                          (test-host-advance! host ms)
                          (list (received c) (test-client-connection-closed? c) (logged host)))))))
    (append (car seen) (list (cadr seen)))))

(test-equal "wrap-catch passes an upgrade through: called directly, the very res; through the host, the 101 and the taker's bytes"
  (list #t (list (string-append (switching '("Upgrade: echo")) "hello") #f '() ""))
  (let ((up (upgrading (make-test-req 'GET "/chat"))))
    (list (eq? up ((wrap-catch (lambda (r) up) no-on-raise) (make-test-req 'GET "/chat")))
          (switched (wrap-catch upgrading no-on-raise) upgrade-request 0))))

;; The handler waits 60 ms of the 100, so the deadline is armed while it
;; runs; the taker then waits to 210 ms, past it, and past a deadline of
;; 100 armed as the take-over starts, so no tie between a deadline and the
;; sleep decides the row.
(test-equal "wrap-timeout's deadline covers the handler, not the take-over: a taker that waits past it still writes, and nothing answers 504"
  (list (string-append (switching '("Upgrade: echo")) "after the deadline") #f '() "")
  (switched ((wrap-timeout 100)
             (lambda (r)
               (sleep-ms 60)
               (make-upgrade-res '(("Upgrade" . "echo"))
                                 (lambda (t retained)
                                   (awaiting (lambda ()
                                               (sleep-ms 150)
                                               (transport-write! t (b "after the deadline"))))))))
            upgrade-request 210))

(test-equal "wrap-log's line for an upgrade: 101 written, told once the 101 is written"
  (list (string-append (switching '("Upgrade: echo")) "hello") #f '() "request GET /chat 101 written 30\n")
  (logged-through-sending (lambda (r) (sleep-ms 30) (upgrading r)) upgrade-request
                          (lambda (host c) (test-host-advance! host 30))))

(test-equal "wrap-log's line for a switch the server refuses, to a request that asked for no upgrade: 101 failed, the client's 500"
  (list (response "500 Internal Server Error" '("Content-Length: 0" "Connection: close") "") #t
        '((invalid-response not-an-upgrade))
        "request GET /chat 101 failed 5\n")
  (logged-through-sending (lambda (r) (sleep-ms 5) (upgrading r)) (get "/chat")
                          (lambda (host c) (test-host-advance! host 5))))

(test-end "middleware-waits")

(exit (suite-exit-status runner))
