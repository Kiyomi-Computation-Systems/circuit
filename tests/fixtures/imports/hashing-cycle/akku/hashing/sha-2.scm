;; -*- mode: scheme; coding: utf-8 -*-
;; A stand-in for (hashing sha-2), written for this fixture: the audit
;; reads its imports as data, and nothing runs it.
#!r6rs

(library (hashing sha-2 (1 4 0))
  (export hmac-sha-256)
  (import (rnrs)
          (hashing hmac)
          (hashing fixnums))
  (define hmac-sha-256 0))
