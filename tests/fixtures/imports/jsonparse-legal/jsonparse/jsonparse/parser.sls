#!r6rs
;;; A stand-in for (jsonparse parser), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse parser)
  (export make-json-parser)
  (import (rnrs)
          (byte-machine runtime)
          (generated jsonparse)
          (jsonparse options))
  (define make-json-parser 0))
