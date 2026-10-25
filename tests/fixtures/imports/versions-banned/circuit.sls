#!r6rs
(library (circuit)
  (export)
  (import (rnrs)
          (chezscheme (9))
          (http-server (1 0))
          (http-server waits (>= 1))
          (circuit http-server (1))
          (rnrs eval (6))))
