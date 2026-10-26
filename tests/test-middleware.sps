#!r6rs
;;; (circuit middleware): wrap's order, the last middleware outermost, and
;;; its refusals.
;;;
;;; Each middleware here notes when it is applied, when a request passes it
;;; on the way in and when the response passes it on the way out, and tags
;;; both, so the log and the answer each show the order.
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (circuit response)
        (circuit middleware))

(define runner (test-runner-simple))
(test-runner-current runner)

;; raised : (-> Any) -> Any
;; What THUNK raised: (assertion-violation WHO IRRITANTS) for an assertion
;; violation, (other-raise X) for anything else, and no-raise if it returned.
(define (raised thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (irritants-condition? e))
             (list 'assertion-violation (condition-who e) (condition-irritants e)))
            ((condition? e) (list 'other-raise (describe e)))
            (#t (list 'other-raise e)))
    (thunk)
    'no-raise))

(define the-log '())
(define (note! x) (set! the-log (cons x the-log)))
(define (take-log!)
  (let ((taken (reverse the-log)))
    (set! the-log '())
    taken))

(define (handler req)
  (note! 'handler)
  (list 'answer-to req))

;; tagging : Symbol -> Middleware
;; A middleware that notes NAME when applied, and on the way in and out, and
;; conses NAME onto the request and onto the response.
(define (tagging name)
  (lambda (next)
    (note! (list 'applied name))
    (lambda (req)
      (note! (list 'in name))
      (let ((res (next (cons name req))))
        (note! (list 'out name))
        (cons name res)))))

(test-begin "middleware")

(test-equal "(wrap h a b) is (b (a h)): the last is outermost"
  '(((applied a) (applied b))
    (b a answer-to (a b req))
    ((in b) (in a) handler (out a) (out b)))
  (begin
    (take-log!)
    (let* ((wrapped (wrap handler (tagging 'a) (tagging 'b)))
           (applied (take-log!))
           (answer (wrapped '(req))))
      (list applied answer (take-log!)))))

(test-equal "(wrap h a b) answers as (b (a h)) does"
  '((b a answer-to (a b req)) (b a answer-to (a b req)))
  (let* ((by-wrap ((wrap handler (tagging 'a) (tagging 'b)) '(req)))
         (by-hand (((tagging 'b) ((tagging 'a) handler)) '(req))))
    (list by-wrap by-hand)))

(test-equal "three middlewares: (c (b (a h)))"
  '(c b a answer-to (a b c req))
  ((wrap handler (tagging 'a) (tagging 'b) (tagging 'c)) '(req)))

(test-equal "a header each middleware adds lands in their order: the inner one's first"
  '(("x-inner" . "1") ("x-outer" . "2"))
  (let ((app (lambda (req) (make-res 200 '() "ok")))
        (adding (lambda (name value)
                  (lambda (next) (lambda (req) (res-add-header (next req) name value))))))
    (res-headers ((wrap app (adding "X-Inner" "1") (adding "X-Outer" "2")) 'req))))

(test-equal "with no middleware, wrap answers the handler itself"
  #t
  (eq? handler (wrap handler)))

(test-equal "each middleware is applied once, when wrap is called, not again for each request"
  '(((applied a) (applied b)) ((in b) (in a) handler (out a) (out b) (in b) (in a) handler (out a) (out b)))
  (begin
    (take-log!)
    (let* ((wrapped (wrap handler (tagging 'a) (tagging 'b)))
           (applied (take-log!)))
      (wrapped '(one))
      (wrapped '(two))
      (list applied (take-log!)))))

(test-equal "wrap refuses a handler that is not a procedure"
  '(assertion-violation wrap (not-a-handler))
  (raised (lambda () (wrap 'not-a-handler (tagging 'a)))))

(test-equal "wrap refuses a middleware that is not a procedure, before it applies any"
  '((assertion-violation wrap (not-a-middleware)) ())
  (begin
    (take-log!)
    (let ((refusal (raised (lambda () (wrap handler (tagging 'a) 'not-a-middleware)))))
      (list refusal (take-log!)))))

(test-equal "wrap refuses a middleware that answers no handler"
  '(assertion-violation wrap (not-a-handler))
  (raised (lambda () (wrap handler (lambda (next) 'not-a-handler)))))

(test-end "middleware")

(exit (suite-exit-status runner))
