#!r6rs
(library (circuit session)
  (export)
  (import (rnrs)
          (only (hashing sha-2) hmac-sha-256)))
