#!r6rs
;;; A stand-in for (byte-machine runtime), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (byte-machine runtime)
  (export make-parser)
  (import (rnrs)
          (rnrs eval)
          (byte-machine private conditions)
          (byte-machine private names))
  (define make-parser 0))
