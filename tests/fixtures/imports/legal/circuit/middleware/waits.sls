#!r6rs
(library (circuit middleware waits)
  (export)
  (import (rnrs)
          (only (chezscheme) call/1cc)
          (http-server)
          (circuit response)))
