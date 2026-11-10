#!r6rs
;;; A stand-in for (jsonparse tree), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse tree)
  (export make-json-builder)
  (import (rnrs)
          (jsonparse options)
          (jsonparse parser)
          (jsonparse string))
  (define make-json-builder 0))
