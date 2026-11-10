#!r6rs
;;; A stand-in for (jsonparse parser), written for this fixture:
;;; the audit reads its imports as data, and nothing runs it.
(library (jsonparse parser)
  (export make-json-parser)
  (import (rnrs)
          (only (chezscheme) getenv)
          (generated jsonparse)
          (generated httparse-message)
          (generated)
          (byte-machine runtime)
          (only (hashing sha-2) hmac-sha-256)
          (circuit json))
  (define make-json-parser 0))
