#!r6rs
;;; A stand-in for (generated jsonparse), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (generated jsonparse)
  (export jsonparse-machine)
  (import (rnrs)
          (byte-machine runtime))
  (define jsonparse-machine 0))
