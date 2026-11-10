#!r6rs
;;; A stand-in for (jsonparse writer), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse writer)
  (export put-json)
  (import (rnrs)
          (jsonparse error)
          (jsonparse options)
          (jsonparse string))
  (define put-json 0))
