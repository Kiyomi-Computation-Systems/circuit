#!r6rs
;;; A stand-in for (jsonparse parser (0 1)), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse parser (0 1))
  (export make-json-parser)
  (import (rnrs)
          (generated jsonparse)
          (byte-machine runtime)
          (jsonparse tree (0 1)))
  (define make-json-parser 0))
