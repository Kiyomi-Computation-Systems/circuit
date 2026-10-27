#!r6rs
(library (circuit http-server)
  (export)
  (import (rnrs)
          (only (chezscheme) getenv port-has-port-length? port-length real-time display-condition)
          (only (chezscheme) real-time)
          (prefix (only (chezscheme) display-condition) c:)))
