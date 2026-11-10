#!r6rs
;;; A stand-in for (byte-machine compile), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (byte-machine compile)
  (export compile-machine)
  (import (rnrs)
          (chezscheme))
  (define compile-machine 0))
