#!r6rs
(library (circuit http-server)
  (export)
  (import (rnrs)
          (only (jsonparse easy) read-json)))
