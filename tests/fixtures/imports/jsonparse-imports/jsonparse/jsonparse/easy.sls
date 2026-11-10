#!r6rs
;;; A stand-in for (jsonparse easy), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse easy)
  (export read-json)
  (import (rnrs)
          (jsonparse parser)
          (rnrs eval)
          (prefix (rnrs eval (6)) e:)
          (jsonparse tree)
          (jsonparse easy)
          (jsonparse)
          (jsonparse private x)
          (jsonparse-extras)
          (jsonparse tree))
  (define read-json 0))
