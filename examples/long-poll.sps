#!r6rs
;;; Waiting: GET /wait holds its answer until someone sends a message with
;;; POST /send, then answers with that message. A wait that hears nothing
;;; for 30 seconds is answered 504, and a client that leaves is forgotten.
;;;
;;;   make run PROGRAM=examples/long-poll.sps
;;;   curl http://127.0.0.1:8080/wait                  # in one terminal
;;;   curl --data hello http://127.0.0.1:8080/send     # in another
;;;   curl http://127.0.0.1:8080/waiting               # how many wait
;;;
;;; Circuit runs every handler on a coroutine, so a handler waits with
;;; await where it is, and other requests go on meanwhile.
(import (rnrs) (circuit) (circuit http-server))

;; The waits in progress: each is the resume its await handed out.
(define waiting '())

;; text : Nat String -> Res
(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

;; wait-for-a-message : -> Res
(define (wait-for-a-message)
  (let ((mine #f))
    (guard (e ((deadline-passed? e)
               (set! waiting (remq mine waiting))
               (text 504 "no message came\n"))
              ((client-closed? e)
               (set! waiting (remq mine waiting))
               (raise e)))
      (with-deadline 30000
        (lambda ()
          (make-res 200 '()
                    (await (lambda (resume)
                             (set! mine resume)
                             (set! waiting (cons resume waiting))))))))))

;; read-all : BinaryInputPort -> Bytevector — what is left of PORT, maybe nothing.
(define (read-all port)
  (let ((bytes (get-bytevector-all port)))
    (if (eof-object? bytes) (make-bytevector 0) bytes)))

;; send! : Bytevector -> Res — wake every wait with MESSAGE.
(define (send! message)
  (let ((woken waiting))
    (set! waiting '())
    (for-each (lambda (resume) (resume message)) woken)
    (text 200 (string-append "woke " (number->string (length woken)) "\n"))))

;; app : Req -> Res
(define (app req)
  (let ((path (req-path req))
        (method (req-method req)))
    (cond ((and (string=? path "/wait") (eq? method 'GET)) (wait-for-a-message))
          ((and (string=? path "/send") (eq? method 'POST)) (send! (read-all (req-body req))))
          ((and (string=? path "/waiting") (eq? method 'GET))
           (text 200 (string-append (number->string (length waiting)) " waiting\n")))
          (else (text 404 "GET /wait or /waiting, or POST /send with a message\n")))))

(run-server app)
