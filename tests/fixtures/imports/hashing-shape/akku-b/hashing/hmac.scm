;; A datum before the library form.
#!r6rs
(define loaded-first 1)
;; -*- mode: scheme; coding: utf-8 -*-
;; A stand-in for (hashing hmac), written for this fixture: the audit
;; reads its imports as data, and nothing runs it.

(library (hashing hmac)
  (export stand-in-hmac)
  (import (rnrs))
  (define stand-in-hmac 0))
