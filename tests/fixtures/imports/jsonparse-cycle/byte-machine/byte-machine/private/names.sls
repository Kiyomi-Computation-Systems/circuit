#!r6rs
;;; A stand-in for (byte-machine private names (1)), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (byte-machine private names (1))
  (export valid-name?)
  (import (rnrs)
          (byte-machine private conditions (1)))
  (define valid-name? 0))
