#!r6rs
(library (circuit request)
  (export)
  (import (rnrs)
          (prefix (generated jsonparse) g:)
          (for (byte-machine private names) run)))
