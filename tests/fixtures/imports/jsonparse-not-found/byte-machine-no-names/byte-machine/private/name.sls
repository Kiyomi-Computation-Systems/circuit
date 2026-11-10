#!r6rs
;;; A stand-in for (byte-machine private name), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (byte-machine private name)
  (export valid-name?)
  (import (rnrs))
  (define valid-name? 0))
