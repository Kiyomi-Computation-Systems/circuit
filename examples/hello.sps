#!r6rs
;;; The smallest server: every request gets "hello", as text. A middleware
;;; adds a `server` field to every response.
;;;
;;;   make run PROGRAM=examples/hello.sps
;;;   curl -i http://127.0.0.1:8080/
(import (rnrs) (circuit) (circuit http-server))

;; app : Req -> Res
(define (app req)
  (make-res 200 '(("content-type" . "text/plain")) "hello\n"))

;; wrap-server-header : (Req -> Res) -> (Req -> Res)
;; A middleware: HANDLER's response, with a server field added.
(define (wrap-server-header handler)
  (lambda (req)
    (res-add-header (handler req) "server" "circuit")))

(run-server (wrap-server-header app))
