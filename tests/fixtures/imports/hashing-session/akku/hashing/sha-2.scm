;; -*- mode: scheme; coding: utf-8 -*-
;; A stand-in for (hashing sha-2), written for this fixture: the audit
;; reads its imports as data, and nothing runs it.
#!r6rs

(library (hashing sha-2)
  (export hmac-sha-256)
  (import (rnrs arithmetic bitwise)
          (rnrs base)
          (rnrs bytevectors)
          (rnrs control)
          (rnrs mutable-strings)
          (rnrs records syntactic)
          (rnrs syntax-case)
          (hashing fixnums)
          (hashing hmac))
  (define hmac-sha-256 0))
