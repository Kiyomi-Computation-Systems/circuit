#!r6rs
;;; A stand-in for (jsonparse tree) that cannot be read as data: its
;;; library form is never closed.
(library (jsonparse tree)
  (export make-json-builder)
  (import (rnrs) (jsonparse parser))
  (define make-json-builder 0)
