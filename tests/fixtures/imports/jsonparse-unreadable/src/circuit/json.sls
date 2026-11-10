#!r6rs
;;; A stand-in for (circuit json): it imports (jsonparse easy) as rule (n)
;;; lets it, so the audit reads its closure from the --jsonparse and
;;; --byte-machine named.
(library (circuit json)
  (export)
  (import (rnrs)
          (only (jsonparse easy) read-json json->bytevector)))
