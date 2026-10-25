#!r6rs
;;; (circuit-testing): what every suite shares.
;;;
;;;   suite-exit-form    the last datum of every tests/test-*.sps
;;;   suite-exit-status  the verdict that form exits with
;;;   describe           a raised object as text, for evidence
;;;
;;; Test-only: it lives in tests/, which make test puts on Chez's library
;;; path, not in src/. Its own suite is tests/test-circuit-testing.sps.
(library (circuit-testing)
  (export suite-exit-form suite-exit-status describe)
  (import (rnrs)
          (srfi :64)
          (only (chezscheme) display-condition))

  ;; suite-exit-form : Sexp
  ;; The last datum of every tests/test-*.sps, exactly: make check-suites
  ;; reads each suite as data and compares its last datum with this one.
  ;; `runner` is the suite's own binding for the runner it makes current. A
  ;; suite that never makes it current leaves it with no test, and fails.
  (define suite-exit-form '(exit (suite-exit-status runner)))

  ;; suite-exit-status : Test-Runner -> (U 0 1)
  ;; 0 when RUNNER saw a pass, and no failure and no unexpected pass.
  ;; Otherwise 1, after a line on the error port with the runner's counts.
  ;; Expected failures and skips count neither way. SRFI-64 sets no exit
  ;; status of its own. The answer is 0 or 1, never a count: exit statuses
  ;; wrap at 256, so 256 failures would exit 0.
  (define (suite-exit-status runner)
    (unless (test-runner? runner)
      (assertion-violation 'suite-exit-status "not a SRFI-64 test runner" runner))
    (let ((pass (test-runner-pass-count runner))
          (fail (test-runner-fail-count runner))
          (xpass (test-runner-xpass-count runner)))
      (if (and (> pass 0) (= fail 0) (= xpass 0))
          0
          (let ((err (current-error-port)))
            ;; The runner's own summary, on stdout, comes first.
            (flush-output-port (current-output-port))
            (put-string err
              (string-append "suite-exit-status: exit 1 (pass " (number->string pass)
                             ", fail " (number->string fail)
                             ", xpass " (number->string xpass)
                             "): a suite needs a pass, and no fail or xpass\n"))
            (flush-output-port err)
            1))))

  ;; describe : Any -> String
  ;; A condition as Chez displays it, anything else as `write` writes it.
  ;; Evidence for a test's expected value, never raising itself.
  (define (describe obj)
    (guard (e (#t "<the raised object could not be printed>"))
      (call-with-string-output-port
       (lambda (p)
         (if (condition? obj) (display-condition obj p) (write obj p)))))))
