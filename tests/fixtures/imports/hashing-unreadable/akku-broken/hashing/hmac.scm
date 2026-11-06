;; A stand-in for (hashing hmac) that Chez cannot read: its library form
;; is never closed.
#!r6rs
(library (hashing hmac)
  (export stand-in-hmac)
  (import (rnrs))
  (define stand-in-hmac 0)
