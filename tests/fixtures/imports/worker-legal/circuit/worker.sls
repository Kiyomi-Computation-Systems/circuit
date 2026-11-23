#!r6rs
(library (circuit worker)
  (export)
  (import (rnrs)
          (circuit worker shell)
          (only (circuit request) make-req)
          (circuit worker machine)))
