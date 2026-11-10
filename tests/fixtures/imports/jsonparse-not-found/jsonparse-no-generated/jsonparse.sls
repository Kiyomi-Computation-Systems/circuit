#!r6rs
;;; A stand-in for (jsonparse), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse)
  (export jsonparse-machine)
  (import (rnrs))
  (define jsonparse-machine 0))
