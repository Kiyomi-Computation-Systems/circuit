#!r6rs
(library (circuit middleware waits)
  (export)
  (import (rnrs)
          (only (chezscheme) real-time display-condition print-record parameterize)
          (rename (only (chezscheme) real-time getenv parameterize) (real-time clock))
          (prefix (only (chezscheme) display-condition print-record) c:)))
