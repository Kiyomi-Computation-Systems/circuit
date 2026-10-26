#!r6rs
;; #! once here,
(library (circuit several)
  (export a b)
  (import (rnrs))
  (define a "#!") (define b "#!#!"))
;; and #! again.
