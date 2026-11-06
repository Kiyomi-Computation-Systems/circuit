;; (hashing sha-2) with its import clause before its export clause: no
;; library form.
#!r6rs
(library (hashing sha-2)
  (import (rnrs))
  (export hmac-sha-256)
  (define hmac-sha-256 0))
