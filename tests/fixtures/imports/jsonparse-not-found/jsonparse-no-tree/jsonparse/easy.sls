#!r6rs
;;; A stand-in for (jsonparse easy), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse easy)
  (export read-json)
  (import (rnrs)
          (jsonparse parser)
          (jsonparse tree))
  (define read-json 0))
