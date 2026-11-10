#!r6rs
;;; A stand-in for (jsonparse sequence), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse sequence)
  (export make-json-reader)
  (import (rnrs)
          (jsonparse options)
          (jsonparse parser)
          (jsonparse tree))
  (define make-json-reader 0))
