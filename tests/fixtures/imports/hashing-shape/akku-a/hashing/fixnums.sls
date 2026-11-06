;; -*- mode: scheme; coding: utf-8 -*-
;; A library of another name where Chez finds (hashing fixnums).
#!r6rs

(library (hashing fixnum)
  (export stand-in-fixnums)
  (import (rnrs))
  (define stand-in-fixnums 0))
