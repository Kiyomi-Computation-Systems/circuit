#!r6rs
;;; (circuit middleware): composing middleware, and capping the body.
;;;
;;; A handler is Req -> Res, and middleware is Handler -> Handler. wrap
;;; applies each middleware in turn, so the last is outermost, as Ring's
;;; (-> h a b) is: a request passes the last middleware first, and its
;;; response passes it last.
;;;
;;; wrap-body-cap gives each request a cap on its body, which the server
;;; enforces under its own CHEZ_HTTP_MAX_BODY_BYTES. The innermost wins, so
;;; a router's group can lift or lower the app's cap for its own routes.
(library (circuit middleware)
  (export wrap wrap-body-cap)
  (import (rnrs) (only (circuit request) req-with-body-cap))

  ;; Handler = Req -> Res
  ;; Middleware = Handler -> Handler

  ;; wrap-body-cap : (U Nat #f) -> Middleware
  ;; Middleware that hands its handler each request with its body capped at
  ;; CAP bytes, or, for #f, with no cap of its own: the server's alone. A
  ;; cap inside it replaces this one. A body past the cap raises the
  ;; server's &body-failed, 413, at the read that passes it, or at the first
  ;; read for a declared length past it. A cap neither #f nor a count of
  ;; bytes is an assertion violation, raised now, and so is a handler that
  ;; is no procedure, when the middleware is applied. A request whose body's
  ;; port was made outside it is req-with-body-cap's assertion violation.
  (define (wrap-body-cap cap)
    (unless (or (not cap) (and (integer? cap) (exact? cap) (>= cap 0)))
      (assertion-violation 'wrap-body-cap "a cap is #f or a count of bytes" cap))
    (lambda (handler)
      (unless (procedure? handler)
        (assertion-violation 'wrap-body-cap "a handler is a procedure" handler))
      (lambda (req) (handler (req-with-body-cap req cap)))))

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
