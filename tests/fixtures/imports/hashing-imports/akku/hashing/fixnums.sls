;; -*- mode: scheme; coding: utf-8 -*-
;; A stand-in for (hashing fixnums), written for this fixture: the audit
;; reads its imports as data, and nothing runs it.
#!r6rs

(library (hashing fixnums)
  (export stand-in-fixnums)
  (import (rnrs (6))
          (circuit session)
          (srfi :1)
          (hashing-extras))
  (define stand-in-fixnums 0))
