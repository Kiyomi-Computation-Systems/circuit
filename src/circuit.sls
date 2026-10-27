#!r6rs
;;; (circuit): the facade, what an app imports.
;;;
;;;   (import (rnrs) (circuit) (circuit http-server))
;;;
;;; The request's accessors, its keys and req-with- helpers, and
;;; req-on-done!; the response's constructor, accessors and helpers, the
;;; sized body, the wrap, and the upgrade, with res-upgrade-body? so
;;; middleware can pass one by, and res-upgrade-body-take-over so it can
;;; make one around a wrapped take-over; the header helpers; wrap. Each is the
;;; binding its home library exports, so a program that imports that
;;; library too doesn't clash.
;;;
;;; Left out, for the adapter and the tests: make-req-view, make-req,
;;; req-body-made and test-req-done! from (circuit request); the
;;; res-sized-body- and res-wrapped-body- accessors, res-body-port and
;;; res-body-stream from (circuit response); and (circuit test).
(library (circuit)
  (export
    ;; the request
    req? req-method req-scheme req-host req-path req-query req-http-version req-header
    req-header-values req-headers req-body req-remote-address req-remote-port
    req-local-address req-local-port req-on-done!
    ;; middleware's data on it
    make-req-key req-key? req-ref req-set
    ;; middleware's rewrites of it
    req-with-method req-with-scheme req-with-host req-with-path req-with-query
    req-with-remote-address req-with-remote-port
    ;; the response
    make-res res? res-status res-headers res-body res-header res-set-header res-add-header
    res-remove-header
    res-with-status res-with-body make-sized-body res-wrap-body res-body-length
    make-upgrade-res res-upgrade-body? res-upgrade-body-take-over
    ;; header lists
    header-value header-values header-set header-add header-remove header-names-downcase
    ;; composing middleware
    wrap)
  (import (circuit request) (circuit response) (circuit headers) (circuit middleware)))
