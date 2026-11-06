#!r6rs
(library (circuit http-server)
  (export)
  (import (rnrs)
          (only (hashing sha-2) sha-256->string)))
