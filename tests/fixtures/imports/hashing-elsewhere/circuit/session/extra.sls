#!r6rs
(library (circuit session extra)
  (export)
  (import (rnrs)
          (only (hashing sha-2) hmac-sha-256)))
