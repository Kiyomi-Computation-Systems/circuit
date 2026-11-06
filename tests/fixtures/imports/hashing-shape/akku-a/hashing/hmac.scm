;; -*- mode: scheme; coding: utf-8 -*-
;; A stand-in for (hashing hmac), written for this fixture: the audit
;; reads its imports as data, and nothing runs it.
#!r6rs

(library (hashing hmac)
  (export stand-in-hmac)
  (import (rnrs))
  (define stand-in-hmac 0))
;; -*- mode: scheme; coding: utf-8 -*-
;; A second library in the file.

(library (hashing hmac2)
  (export stand-in-hmac2)
  (import (chezscheme))
  (define stand-in-hmac2 0))
