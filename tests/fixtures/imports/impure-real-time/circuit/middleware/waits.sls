#!r6rs
(library (circuit middleware waits)
  (export)
  (import (rnrs)
          (only (chezscheme) real-time display-condition)
          (rename (only (chezscheme) real-time getenv) (real-time clock))
          (prefix (only (chezscheme) display-condition) c:)))
