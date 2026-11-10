#!r6rs
;;; A stand-in for (jsonparse easy), written for this fixture, with its
;;; import clause before its export clause: no library form.
(library (jsonparse easy)
  (import (rnrs) (jsonparse parser) (jsonparse tree))
  (export read-json)
  (define read-json 0))
