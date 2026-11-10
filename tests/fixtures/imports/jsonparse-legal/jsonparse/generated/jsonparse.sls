;;; A stand-in for (generated jsonparse), written for this fixture: the
;;; audit reads its imports as data, and nothing runs it. Its #!r6rs comes
;;; after this comment: rule (h) does not hold the closure's files.
#!r6rs
(library (generated jsonparse)
  (export jsonparse-machine)
  (import (rnrs) (byte-machine runtime))
  (define jsonparse-machine 0))
