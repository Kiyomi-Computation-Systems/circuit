;; -*- mode: scheme; coding: utf-8 -*-
;; A stand-in for (hashing hmac), written for this fixture: the audit
;; reads its imports as data, and nothing runs it.
#!r6rs

(library (hashing hmac)
  (export stand-in-hmac)
  (import (rnrs)
          (hashing fixnums)
          (hashing sha-2)
          (hashing private compat)
          (hashing))
  (define stand-in-hmac 0))
