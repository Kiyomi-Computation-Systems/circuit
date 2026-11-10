#!r6rs
;;; A stand-in for (jsonparse string), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse string)
  (export make-assembler)
  (import (rnrs)
          (jsonparse options)
          (jsonparse parser))
  (define make-assembler 0))
