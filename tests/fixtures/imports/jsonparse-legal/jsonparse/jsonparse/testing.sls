#!r6rs
;;; A stand-in for (jsonparse testing), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse testing)
  (export check)
  (import (rnrs)
          (chezscheme))
  (define check 0))
