#!r6rs
;;; A stand-in for (byte-machine runtime), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (byte-machine runtime)
  (export make-parser)
  (import (rnrs)
          (byte-machine private conditions)
          (byte-machine compile)
          (byte-machine interpret)
          (byte-machine private ir)
          (byte-machine verify)
          (byte-machine)
          (srfi :1)
          (byte-machine private names))
  (define make-parser 0))
