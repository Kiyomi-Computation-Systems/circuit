#!r6rs
;;; (circuit middleware waits): the middleware that knows the server's
;;; waits and conditions (design §6, §7, §15 item 4).
;;;
;;;   (import (rnrs) (circuit) (circuit http-server) (circuit middleware waits))
;;;   (run-server (wrap app wrap-catch (wrap-timeout 5000) wrap-log))
;;;
;;; wrap-catch, the catch helper, turns a raise into a res. &client-closed
;;; and &deadline-passed it raises again, from where they were raised, before
;;; anything unwinds: swallowing the close parks a handler that waits again
;;; for good, and swallowing the deadline turns a 504 into a 500. A
;;; &body-failed it answers with its own status, so middleware outside it
;;; sees the 413 the client gets. Anything else goes to on-raise, called
;;; where the raise happened, before anything unwinds, with the handler
;;; outside the catch current, so a raise from it goes there; its answer is
;;; the escape's. The default writes the line serve writes for a raise that
;;; reaches it, and answers an empty 500.
;;;
;;; wrap-timeout runs its handler inside the server's with-deadline, and
;;; answers 504 when &deadline-passed reaches it. The deadline covers the
;;; waits inside the handler, the body's reads among them, never a
;;; producer, and cuts short nothing that isn't waiting. It goes outside the
;;; catch, which raises the deadline on to it.
;;;
;;; wrap-log writes a line for each request that reaches its handler, once
;;; its response is done, by req-on-done!: the method, the path, the status
;;; the handler answered, how the response ended and how long it took, by a
;;; clock of milliseconds. A request the server refuses before any handler
;;; runs (a 400, a 408, a 413 for a declared length past the cap, a 431, a
;;; 505) registers nothing, so nothing logs it, circuit or the server. The
;;; status is the handler's, so where the server answers in its place, the
;;; line still shows it: 200 failed, say, for a res whose body is the
;;; request's own req-body, which the client gets as the server's 500.
;;;
;;; Both catches escape by call/cc around with-exception-handler, the
;;; cheapest way on a coroutine (S2): guard costs more, and Chez's call/1cc
;;; costs 3.4 KB or more once a wait or Chez's error falls inside it. Each
;;; call/cc is in tail position, and each answer is made inside the
;;; exception handler, before the escape: a frame after the call/cc, to make
;;; the answer once escaped, cost wrap-catch about 100 B a request (G5,
;;; about 485 B against about 380 B). With nothing raised, a catch
;;; allocates nothing beyond its escape; the gate holds wrap-catch's (G5).
;;; What either passes on, it raises again by raise-continuable, so a
;;; continuable raise is answered where it was raised, as if the catch
;;; weren't there.
;;;
;;; This library imports the server, as (circuit http-server) does, and
;;; takes two names from (chezscheme) (ADR-0006): real-time, wrap-log's
;;; default clock, and display-condition, which shows a condition in the
;;; default line as the server's log does.
(library (circuit middleware waits)
  (export wrap-catch wrap-timeout wrap-log)
  (import (rnrs)
          (only (chezscheme) real-time display-condition)
          (only (circuit request) req-method req-path req-on-done!)
          (only (circuit response) make-res res? res-status)
          (only (http-server)
                with-deadline deadline-passed? client-closed? body-failed? body-failed-status))

  ;; Handler = Req -> Res
  ;; Middleware = Handler -> Handler

  ;; wrap-catch : Handler [(Req Any -> Res)] -> Handler
  ;; HANDLER, its raises caught. &client-closed and &deadline-passed are
  ;; raised again, from where they were raised, before anything unwinds. A
  ;; &body-failed is answered (make-res (body-failed-status e) '() #f). Any
  ;; other raise, condition or not, is handed to ON-RAISE with the request
  ;; and what was raised, where it was raised, before anything unwinds; the
  ;; handler outside is current there, as R6RS calls an exception handler,
  ;; so a raise from ON-RAISE goes to it. ON-RAISE's answer is the response,
  ;; escaped with. Each answer is made before the escape, so the call/cc is
  ;; in tail position, and no frame waits after it. The default ON-RAISE
  ;; writes the handler-failed line and answers an empty 500. A HANDLER or
  ;; ON-RAISE that is no procedure is an assertion violation, raised now.
  (define wrap-catch
    (case-lambda
      ((handler) (make-catch handler log-raise))
      ((handler on-raise) (make-catch handler on-raise))))

  (define (make-catch handler on-raise)
    (unless (procedure? handler)
      (assertion-violation 'wrap-catch "a handler is a procedure" handler))
    (unless (procedure? on-raise)
      (assertion-violation 'wrap-catch "on-raise is a procedure of a req and what was raised"
                           on-raise))
    (lambda (req)
      (call/cc
       (lambda (k)
         (with-exception-handler
          (lambda (e)
            (cond ((or (client-closed? e) (deadline-passed? e)) (raise-continuable e))
                  ((body-failed? e) (k (make-res (body-failed-status e) '() #f)))
                  (else (k (on-raise req e)))))
          (lambda () (handler req)))))))

  ;; log-raise : Req Any -> Res
  ;; The default on-raise: one line on the current output port, flushed at
  ;; once, handler-failed and the raise as the server's log writes a detail,
  ;; so it is the line serve writes for the same raise; then an empty 500.
  (define (log-raise req e)
    (write-line (call-with-string-output-port
                 (lambda (p)
                   (put-string p "handler-failed ")
                   (put-detail p e)
                   (put-char p #\newline))))
    (make-res 500 '() #f))

  ;; put-detail : OutputPort Any -> Void
  ;; D as the server's log writes a detail (its private/serve.sls): a
  ;; condition as Chez's display-condition shows it, its line breaks made
  ;; spaces; a string, a symbol, a number, a boolean or a character
  ;; displayed; a record as #< its record type's name >; anything else
  ;; written. An opaque record is no record to R6RS's record?, so it is
  ;; written.
  (define (put-detail out d)
    (cond ((condition? d) (put-string out (one-line (condition-text d))))
          ((or (string? d) (symbol? d) (number? d) (boolean? d) (char? d)) (display d out))
          ((record? d)
           (put-string out "#<")
           (display (record-type-name (record-rtd d)) out)
           (put-string out ">"))
          (else (write d out))))

  ;; condition-text : Condition -> String — as display-condition shows it.
  (define (condition-text c)
    (call-with-string-output-port (lambda (p) (display-condition c p))))

  ;; one-line : String -> String — S, each line feed a space.
  (define (one-line s)
    (list->string (map (lambda (c) (if (char=? c #\newline) #\space c)) (string->list s))))

  ;; write-line : String -> Void
  ;; LINE on the current output port as it is now, flushed at once.
  (define (write-line line)
    (let ((out (current-output-port)))
      (put-string out line)
      (flush-output-port out)))

  ;; wrap-timeout : Nat -> Middleware
  ;; A middleware that runs its handler inside (with-deadline MS ...), and
  ;; answers (make-res 504 '() #f) when &deadline-passed reaches it. Any
  ;; other raise goes on as it was raised. An MS with-deadline would refuse,
  ;; anything but an exact integer of 0 or more, is an assertion violation,
  ;; raised now; so is a handler that is no procedure, when the middleware
  ;; is applied.
  (define (wrap-timeout ms)
    (unless (and (integer? ms) (exact? ms) (>= ms 0))
      (assertion-violation 'wrap-timeout "expected a whole number of milliseconds" ms))
    (lambda (handler)
      (unless (procedure? handler)
        (assertion-violation 'wrap-timeout "a handler is a procedure" handler))
      (lambda (req)
        (call/cc
         (lambda (k)
           (with-exception-handler
            (lambda (e)
              (if (deadline-passed? e)
                  (k (make-res 504 '() #f))
                  (raise-continuable e)))
            (lambda () (with-deadline ms (lambda () (handler req))))))))))

  ;; wrap-log : Handler [(-> Nat)] -> Handler
  ;; HANDLER, each request it is called for logged once its response is
  ;; done. When it is called, it reads CLOCK and registers a req-on-done!
  ;; procedure, then calls HANDLER: registered first, it hears last. It
  ;; catches nothing. As HANDLER returns it notes the status: the res's
  ;; res-status, or - for an answer that is no res; raised, if HANDLER
  ;; raised, the raise going on untouched. When told how the response ended,
  ;; the procedure reads CLOCK again and writes one line on the current
  ;; output port, as it is then, flushed at once:
  ;;   request METHOD PATH STATUS ENDING MS
  ;; each displayed: req-method, req-path with no query, the status, the
  ;; ending (written, client-closed or failed), and the second reading less
  ;; the first. The status is HANDLER's answer's: failed can mean the client
  ;; got the server's own status in its place, such as a 500 for an answer
  ;; the adapter refuses. CLOCK reads milliseconds; Chez's real-time by
  ;; default, which counts from the process's start. A HANDLER or CLOCK that
  ;; is no procedure is an assertion violation, raised now.
  (define wrap-log
    (case-lambda
      ((handler) (make-log handler real-time))
      ((handler clock) (make-log handler clock))))

  (define (make-log handler clock)
    (unless (procedure? handler)
      (assertion-violation 'wrap-log "a handler is a procedure" handler))
    (unless (procedure? clock)
      (assertion-violation 'wrap-log "a clock is a procedure of no arguments that reads milliseconds"
                           clock))
    (lambda (req)
      (let ((start (clock))
            (status 'raised))
        (req-on-done! req
                      (lambda (ending)
                        (let ((end (clock)))
                          (log-request req status ending (- end start)))))
        (let ((answer (handler req)))
          (set! status (if (res? answer) (res-status answer) '-))
          answer))))

  ;; log-request : Req (U Integer Symbol) Symbol Integer -> Void
  ;; The request line on the current output port as it is now: request,
  ;; then each detail displayed after a space, a line feed, and one flush.
  ;; The details are read first, then written straight to the port, with no
  ;; string port between: nothing waits while they are written, so no other
  ;; line comes between them.
  (define (log-request req status ending ms)
    (let ((method (req-method req))
          (path (req-path req))
          (out (current-output-port)))
      (put-string out "request ")
      (display method out)
      (put-char out #\space)
      (display path out)
      (put-char out #\space)
      (display status out)
      (put-char out #\space)
      (display ending out)
      (put-char out #\space)
      (display ms out)
      (put-char out #\newline)
      (flush-output-port out))))
