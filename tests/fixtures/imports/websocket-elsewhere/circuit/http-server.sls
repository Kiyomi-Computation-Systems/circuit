#!r6rs
(library (circuit http-server)
  (export)
  (import (rnrs)
          (http-server)
          (only (websocket) websocket-accept)))
