#!r6rs
(library (circuit worker shell)
  (export)
  (import (rnrs)
          (circuit worker machine)
          (only (http-server) await-outside)))
