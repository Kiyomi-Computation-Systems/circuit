#!r6rs
(library (circuit http-server)
  (export)
  (import (rnrs)
          (only (chezscheme) getenv)
          (only (chezscheme) fork-thread)))
