;; -*- mode: scheme; coding: utf-8 -*-
;; A stand-in for (hashing hmac extra), written for this fixture: the audit
;; reads its imports as data, and nothing runs it.
#!r6rs

(library (hashing hmac extra)
  (export extra)
  (import (rnrs))
  (define extra 0))
