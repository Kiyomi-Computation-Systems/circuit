#!r6rs
;;; (circuit middleware): wrap's order, the last middleware outermost, and
;;; its refusals; wrap-body-cap's cap, the innermost winning, and its
;;; refusals.
;;;
;;; wrap-body-cap's rows read the cap a handler sees through (circuit test)'s
;;; requests, which never enforce one: the adapter's suite holds the
;;; server enforcing it.
;;;
;;; Each middleware here notes when it is applied, when a request passes it
;;; on the way in and when the response passes it on the way out, and tags
;;; both, so the log and the answer each show the order.
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (circuit response)
        (only (circuit request) req-body req-body-cap)
        (only (circuit test) make-test-req)
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

;; --- wrap-body-cap ---------------------------------------------------------------

;; cap-seen : Middleware ... -> (List Any Any)
;; What a handler inside MIDDLEWARES answers for a POST, and the cap it saw.
(define (cap-seen . middlewares)
  (let* ((seen 'handler-not-called)
         (app (apply wrap (lambda (req) (set! seen (req-body-cap req)) 'answered) middlewares)))
    (let ((answered (app (make-test-req 'POST "/" '() "body"))))
      (list answered seen))))

(test-equal "wrap-body-cap gives the request it passes on its cap: the innermost given wins, #f lifting one outside it; 0 and a bignum are caps"
  `((answered 4) (answered 10) (answered 4) (answered #f) (answered 0) (answered ,(expt 2 100)))
  (list (cap-seen (wrap-body-cap 4))
        (cap-seen (wrap-body-cap 10) (wrap-body-cap 4))
        (cap-seen (wrap-body-cap 4) (wrap-body-cap 10))
        (cap-seen (wrap-body-cap #f) (wrap-body-cap 4))
        (cap-seen (wrap-body-cap 0))
        (cap-seen (wrap-body-cap (expt 2 100)))))

(test-equal "wrap-body-cap answers its handler's response as it is"
  #t
  (let ((res (make-res 201 '(("x-a" . "1")) "made")))
    (eq? res (((wrap-body-cap 4) (lambda (req) res)) (make-test-req 'GET "/")))))

(test-equal "wrap-body-cap refuses a cap that is neither #f nor a count of bytes when it is called, and a handler that is no procedure when it is applied"
  '((assertion-violation wrap-body-cap (-1))
    (assertion-violation wrap-body-cap (1.5))
    (assertion-violation wrap-body-cap (4.))
    (assertion-violation wrap-body-cap ("4"))
    (assertion-violation wrap-body-cap (not-a-handler)))
  (append (map (lambda (cap) (raised (lambda () (wrap-body-cap cap)))) (list -1 1.5 4. "4"))
          (list (raised (lambda () ((wrap-body-cap 4) 'not-a-handler))))))

(test-equal "wrap-body-cap refuses a request whose body was read outside it: the cap would come too late"
  '(assertion-violation req-with-body-cap (4))
  (let* ((reading (lambda (next)
                    (lambda (req)
                      (get-bytevector-all (req-body req))
                      (next req))))
         (app (wrap (lambda (req) 'answered) (wrap-body-cap 4) reading)))
    (raised (lambda () (app (make-test-req 'POST "/" '() "body"))))))

(test-end "middleware")

(exit (suite-exit-status runner))
