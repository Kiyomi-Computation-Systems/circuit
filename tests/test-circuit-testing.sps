#!r6rs
;;; (circuit-testing): the shared exit form, the verdict it exits with, and
;;; describe.
;; Chez's current-error-port is a parameter, which (rnrs)'s is not.
(import (except (rnrs) current-error-port)
        (srfi :64)
        (only (chezscheme) parameterize current-error-port)
        (circuit-testing))

(define runner (test-runner-simple))
(test-runner-current runner)

;; runner-after : (-> Any) -> Test-Runner
;; A fresh, silent runner, after `thunk` has run its tests on it.
(define (runner-after thunk)
  (let ((r (test-runner-null)))
    (test-with-runner r (thunk))
    r))

;; verdict : (-> Any) -> (List (U 0 1 Symbol) String)
;; suite-exit-status's answer for a runner `thunk` filled, and what it wrote
;; on the error port. A raise answers the list (raised <description>).
(define (verdict thunk)
  (guard (e (#t (list 'raised (describe e))))
    (let ((r (runner-after thunk)))
      (let-values (((port text) (open-string-output-port)))
        (let ((status (parameterize ((current-error-port port))
                        (suite-exit-status r))))
          (list status (text)))))))

(define (refused-line pass fail xpass)
  (string-append "suite-exit-status: exit 1 (pass " (number->string pass)
                 ", fail " (number->string fail) ", xpass " (number->string xpass)
                 "): a suite needs a pass, and no fail or xpass\n"))

;; Each runner's verdict, computed before the suite begins, under a guard.
(define one-pass
  (verdict (lambda () (test-assert "p" #t))))
(define none
  (verdict (lambda () #t)))
(define pass-and-fail
  (verdict (lambda () (test-assert "p" #t) (test-assert "f" #f))))
(define pass-and-xpass
  (verdict (lambda () (test-assert "p" #t) (test-expect-fail 1) (test-assert "x" #t))))
(define pass-and-xfail
  (verdict (lambda () (test-assert "p" #t) (test-expect-fail 1) (test-assert "x" #f))))
(define pass-and-skip
  (verdict (lambda () (test-assert "p" #t) (test-skip 1) (test-assert "s" #f))))
(define only-fails
  (verdict (lambda () (test-assert "f1" #f) (test-assert "f2" #f))))
(define not-a-runner
  (guard (e ((and (assertion-violation? e) (who-condition? e))
             (list 'assertion-violation (condition-who e) (condition-irritants e)))
            (#t (list 'other (describe e))))
    (suite-exit-status 'not-a-runner)
    'returned))

(test-begin "circuit-testing")

;; Built with list, not quoted: make check-suites reads a quoted exit form
;; as one.
(test-equal "suite-exit-form is the shared exit form"
  (list 'exit (list 'suite-exit-status 'runner))
  suite-exit-form)

(test-equal "one pass: 0, and nothing on the error port"
  '(0 "")
  one-pass)

(test-equal "no test at all: 1, saying so"
  (list 1 (refused-line 0 0 0))
  none)

(test-equal "a pass and a fail: 1, with the counts"
  (list 1 (refused-line 1 1 0))
  pass-and-fail)

(test-equal "a pass and an unexpected pass: 1, with the counts"
  (list 1 (refused-line 1 0 1))
  pass-and-xpass)

(test-equal "a pass and an expected failure: 0"
  '(0 "")
  pass-and-xfail)

(test-equal "a pass and a skip: 0"
  '(0 "")
  pass-and-skip)

(test-equal "two fails: 1, never the count of failures"
  (list 1 (refused-line 0 2 0))
  only-fails)

(test-equal "what is not a runner is refused"
  '(assertion-violation suite-exit-status (not-a-runner))
  not-a-runner)

(test-equal "describe writes a non-condition"
  "(a \"b\" 3)"
  (describe '(a "b" 3)))

(test-equal "describe displays a condition"
  "Exception in who: what with irritant 7"
  (describe (condition (make-who-condition 'who)
                       (make-message-condition "what")
                       (make-irritants-condition '(7)))))

(test-end "circuit-testing")

;; This suite tests suite-exit-status, so its exit cannot rest on it alone:
;; a suite-exit-status that ignored failures would pass this suite, and
;; make test with it. Any failure here exits 1 first.
(when (positive? (test-runner-fail-count runner))
  (exit 1))

(exit (suite-exit-status runner))
