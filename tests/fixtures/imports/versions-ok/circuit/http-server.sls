#!r6rs
(library (circuit http-server (2))
  (export)
  (import (rnrs)
          (only (chezscheme (9)) call/1cc)
          (http-server (>= 1 0))
          (http-server waits (1))))
