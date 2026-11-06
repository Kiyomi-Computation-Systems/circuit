;; -*- mode: scheme; coding: utf-8 -*-
;; A stand-in for (hashing private compat), written for this fixture: the audit
;; reads its imports as data, and nothing runs it.
#!r6rs

(library (hashing private compat)
  (export compat)
  (import (chezscheme))
  (define compat 0))
