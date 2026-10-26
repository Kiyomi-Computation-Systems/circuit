#!r6rs
(library (circuit http-server)
  (export)
  (import (rnrs)
          (only (chezscheme) getenv port-has-port-length? port-length)
          (only (chezscheme) port-length)
          (prefix (only (chezscheme) port-has-port-length? port-length) c:)))
