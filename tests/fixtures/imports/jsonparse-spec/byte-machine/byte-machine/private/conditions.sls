#!r6rs
;;; A stand-in for (byte-machine private conditions), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (byte-machine private conditions)
  (export contract-violation)
  (import (rnrs))
  (define contract-violation 0))
