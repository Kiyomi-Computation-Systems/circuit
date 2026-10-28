#!r6rs
;;; Reading a request: every request is told its method, path and query, on
;;; one line, and then given its body back.
;;;
;;;   make run PROGRAM=examples/echo.sps
;;;   curl 'http://127.0.0.1:8080/some/path?x=1'
;;;   curl --data hi 'http://127.0.0.1:8080/a?b=1'
;;;
;;; It reads the body whole, so it caps the body at 1 MiB with wrap-body-cap,
;;; as any app that reads one whole should: the server caps no body by
;;; default. A body past the cap gets 413.
(import (rnrs) (circuit) (circuit http-server))

;; first-line : Req -> String — "METHOD PATH[?QUERY]" and a newline.
(define (first-line req)
  (let ((query (req-query req)))
    (string-append (symbol->string (req-method req)) " " (req-path req)
                   (if query (string-append "?" query) "")
                   "\n")))

;; read-all : BinaryInputPort -> Bytevector — what is left of PORT, maybe nothing.
(define (read-all port)
  (let ((bytes (get-bytevector-all port)))
    (if (eof-object? bytes) (make-bytevector 0) bytes)))

;; app : Req -> Res
;; The body is read here, inside the handler, where a read may wait for the
;; client. The response gets the bytes, not req-body's port: the adapter
;; refuses that port as a body, since nothing could read it once the
;; handler has answered.
(define (app req)
  (let ((body (read-all (req-body req))))
    (make-res 200 '(("content-type" . "text/plain"))
              (call-with-bytevector-output-port
               (lambda (out)
                 (put-bytevector out (string->utf8 (first-line req)))
                 (put-bytevector out body))))))

(run-server (wrap app (wrap-body-cap 1048576)))
