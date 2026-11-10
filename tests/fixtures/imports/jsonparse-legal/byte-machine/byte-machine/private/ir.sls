#!r6rs
;;; A stand-in for (byte-machine private ir), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (byte-machine private ir)
  (export make-machine)
  (import (chezscheme))
  (define make-machine 0))
