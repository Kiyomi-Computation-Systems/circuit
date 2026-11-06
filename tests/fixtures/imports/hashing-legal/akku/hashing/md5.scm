;; -*- mode: scheme; coding: utf-8 -*-
;; A stand-in for (hashing md5), written for this fixture: the audit
;; reads its imports as data, and nothing runs it.
#!r6rs

(library (hashing md5)
  (export md5)
  (import (rnrs)
          (chezscheme))
  (define md5 0))
