#!r6rs
(library (circuit sessions)
  (export)
  (import (rnrs)
          (only (hashing sha-2 (1 4)) hmac-sha-256)))
