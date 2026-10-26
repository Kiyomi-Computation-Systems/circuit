#!r6rs
(library (circuit middleware waits)
  (export)
  (import (rnrs)
          (only (chezscheme) port-has-port-length?)
          (rename (only (chezscheme) port-length getenv) (port-length length))))
