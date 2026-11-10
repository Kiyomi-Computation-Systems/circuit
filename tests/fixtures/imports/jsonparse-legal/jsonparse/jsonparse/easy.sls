#!r6rs
;;; A stand-in for (jsonparse easy), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse easy)
  (export read-json)
  (import (rnrs)
          (jsonparse error)
          (jsonparse options)
          (jsonparse parser)
          (jsonparse sequence)
          (jsonparse string)
          (jsonparse tree)
          (jsonparse writer))
  (define read-json 0))
