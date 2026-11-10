#!r6rs
;;; A stand-in for (jsonparse error), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse error)
  (export json-error?)
  (import (rnrs))
  (define json-error? 0))
