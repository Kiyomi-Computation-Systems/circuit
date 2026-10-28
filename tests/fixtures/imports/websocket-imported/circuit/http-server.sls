#!r6rs
(library (circuit http-server)
  (export)
  (import (rnrs)
          (http-server)
          (only (circuit websocket) websocket-res)))
