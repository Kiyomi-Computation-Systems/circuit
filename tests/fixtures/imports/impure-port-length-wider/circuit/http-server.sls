#!r6rs
(library (circuit http-server)
  (export)
  (import (rnrs)
          (only (chezscheme) getenv port-has-port-length? port-length file-length)
          (only (chezscheme) port-length set-port-length!)
          (only (chezscheme) port-has-port-length? eval)
          (only (chezscheme) port-has-set-port-length!?)))
