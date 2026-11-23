#!r6rs
(library (circuit middleware waits)
  (export)
  (import (rnrs)
          (only (circuit worker shell) make-worker)))
