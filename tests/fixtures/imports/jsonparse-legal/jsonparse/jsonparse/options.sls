#!r6rs
;;; A stand-in for (jsonparse options), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse options)
  (export make-json-options)
  (import (rnrs (6)))
  (define make-json-options 0))
