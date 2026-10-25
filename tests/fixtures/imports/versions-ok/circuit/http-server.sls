#!r6rs
(library (circuit http-server (2))
  (export)
  (import (rnrs)
          (chezscheme (9))
          (http-server (>= 1 0))
          (http-server waits (1))))
