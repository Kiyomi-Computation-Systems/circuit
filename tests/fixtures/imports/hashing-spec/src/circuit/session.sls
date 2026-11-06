#!r6rs
;;; A stand-in for (circuit session): it imports (hashing sha-2) as rule (k)
;;; lets it, so the audit reads its closure from the --akku named.
(library (circuit session)
  (export)
  (import (rnrs)
          (only (hashing sha-2) hmac-sha-256)))
