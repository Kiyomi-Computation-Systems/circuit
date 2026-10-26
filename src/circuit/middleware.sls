#!r6rs
;;; (circuit middleware): composing middleware.
;;;
;;; A handler is Req -> Res, and middleware is Handler -> Handler. wrap
;;; applies each middleware in turn, so the last is outermost, as Ring's
;;; (-> h a b) is: a request passes the last middleware first, and its
;;; response passes it last.
(library (circuit middleware)
  (export wrap)
  (import (rnrs))

  ;; Handler = Req -> Res
  ;; Middleware = Handler -> Handler

  ;; wrap : Handler Middleware ... -> Handler
  ;; HANDLER inside each middleware in turn: (wrap h a b) is (b (a h)), and
  ;; (wrap h) is h. Each middleware is applied once, here. A handler or a
  ;; middleware that is not a procedure is an assertion violation, checked
  ;; before any is applied, and so is a middleware that answers no
  ;; procedure.
  (define (wrap handler . middlewares)
    (unless (procedure? handler)
      (assertion-violation 'wrap "a handler is a procedure" handler))
    (for-each (lambda (m)
                (unless (procedure? m)
                  (assertion-violation 'wrap "a middleware is a procedure" m)))
              middlewares)
    (fold-left (lambda (inner m)
                 (let ((outer (m inner)))
                   (unless (procedure? outer)
                     (assertion-violation 'wrap "a middleware answered no handler" outer))
                   outer))
               handler
               middlewares)))
