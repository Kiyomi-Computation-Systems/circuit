#!r6rs
;;; A stand-in for (byte-machine private conditions), written for this
;;; fixture, with a datum before its library form.
(define stand-in 0)
(library (byte-machine private conditions)
  (export contract-violation)
  (import (rnrs))
  (define contract-violation 0))
