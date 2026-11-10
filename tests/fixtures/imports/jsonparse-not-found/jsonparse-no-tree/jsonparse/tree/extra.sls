#!r6rs
;;; A stand-in for (jsonparse tree extra), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse tree extra)
  (export make-json-builder)
  (import (rnrs))
  (define make-json-builder 0))
