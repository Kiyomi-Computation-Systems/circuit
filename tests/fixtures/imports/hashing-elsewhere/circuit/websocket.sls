#!r6rs
(library (circuit websocket)
  (export)
  (import (rnrs)
          (only (hashing hmac) make-hmac)))
