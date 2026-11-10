#!r6rs
(library (circuit websocket)
  (export)
  (import (rnrs)
          (only (jsonparse tree) make-json-builder)))
