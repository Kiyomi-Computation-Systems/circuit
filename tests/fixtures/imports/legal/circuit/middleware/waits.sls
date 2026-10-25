#!r6rs
(library (circuit middleware waits)
  (export)
  (import (rnrs)
          (only (chezscheme) getenv)
          (http-server)
          (circuit response)))
