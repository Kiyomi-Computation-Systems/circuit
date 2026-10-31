#!r6rs
;;; The names suite: circuit's libraries and the server's, imported together
;;; with no only, except, prefix or rename, as an app may import them
;;; (design §10, ADR-0005). An export of circuit's that names a binding the
;;; server's libraries export is a clash, and Chez refuses this program
;;; before any test runs, so the suite fails. The adapter, (circuit
;;; http-server), re-exports the server's waits, conditions, transport
;;; procedures and awaiting, which the import takes from both libraries at
;;; once only because each is the server's own binding. chez-websocket's
;;; facade, (websocket), is imported beside (circuit websocket), as an app
;;; that takes a WebSocket imports both: a name of either that another
;;; library here exports is a clash too.
;;;
;;; Its tests hold what the import cannot: that each library exports exactly
;;; its list, so the (circuit) facade keeps the adapter's, the tests' and the
;;; router's names out, that the adapter's re-exports are the server's own bindings,
;;; compared through a prefixed import of each, and that the like-named
;;; bindings of the two make different things.
(import (rnrs)
        (srfi :64)
        (only (chezscheme) library-exports)
        (circuit-testing)
        (http-server)
        (http-server testing)
        (http-server headers)
        (http-server response)
        (circuit)
        (circuit request)
        (circuit response)
        (circuit headers)
        (circuit middleware)
        (circuit middleware waits)
        (circuit router)
        (circuit test)
        (circuit http-server)
        (circuit websocket)
        (websocket)
        (prefix (http-server) server:)
        (prefix (circuit http-server) adapter:))

(define runner (test-runner-simple))
(test-runner-current runner)

;; sorted-exports : (Listof Symbol) -> (Listof Symbol)
;; LIBRARY's exports, sorted by name.
(define (sorted-exports library)
  (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
             (library-exports library)))

(define (sorted names)
  (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) names))

(define request-names
  '(make-req-view make-req req? req-method req-scheme req-host req-path req-query
    req-http-version req-header req-header-values req-headers req-body
    req-remote-address req-remote-port req-local-address req-local-port
    req-on-done! req-body-made make-req-key req-key? req-ref req-set
    req-with-method req-with-scheme req-with-host req-with-path req-with-query
    req-with-remote-address req-with-remote-port req-body-cap req-with-body-cap
    test-req-done!))

(define response-names
  '(make-res res? res-status res-headers res-body res-header res-set-header res-add-header
    res-remove-header res-with-status res-with-body make-sized-body res-sized-body? res-sized-body-length
    res-sized-body-inner res-wrap-body res-wrapped-body? res-wrapped-body-inner
    res-wrapped-body-proc res-tap-body res-tapped-body? res-tapped-body-inner
    res-tapped-body-proc make-upgrade-res res-upgrade-body?
    res-upgrade-body-take-over res-body-length res-body-port res-body-stream))

(define header-names
  '(header-value header-values header-set header-add header-remove header-names-downcase))

;; The router's: an app imports (circuit router) beside (circuit), which
;; leaves them out.
(define router-names
  '(make-router on-not-found on-bad-request on-method-not-allowed
    route GET POST PUT PATCH DELETE OPTIONS ANY METHOD group mount
    req-path-param req-path-params req-route req-mount-path))

;; What an app uses: the request's accessors, keys and req-with- helpers,
;; req-on-done!, the body's cap; the response's constructors, accessors and
;; helpers, the upgrade's predicate and its take-over among them; the header
;; helpers; wrap and wrap-body-cap.
(define facade-names
  '(req? req-method req-scheme req-host req-path req-query req-http-version req-header
    req-header-values req-headers req-body req-remote-address req-remote-port
    req-local-address req-local-port req-on-done!
    make-req-key req-key? req-ref req-set
    req-with-method req-with-scheme req-with-host req-with-path req-with-query
    req-with-remote-address req-with-remote-port req-body-cap req-with-body-cap
    make-res res? res-status res-headers res-body res-header res-set-header res-add-header
    res-remove-header res-with-status res-with-body make-sized-body res-wrap-body res-tap-body
    res-body-length
    make-upgrade-res res-upgrade-body? res-upgrade-body-take-over
    header-value header-values header-set header-add header-remove header-names-downcase
    wrap wrap-body-cap))

;; The server's waits, conditions, transport procedures and awaiting, which
;; (circuit http-server) re-exports.
(define server-reexports
  '(awaiting await sleep-ms with-deadline resolve
    &deadline-passed deadline-passed? &client-closed client-closed?
    &resolve-error resolve-error? resolve-error-reason
    &body-failed body-failed? body-failed-reason body-failed-status
    transport? transport-write! transport-read-start! transport-read-stop!
    transport-close! transport-abort! transport-deadline! transport-on-drain!
    transport-on-close!))

;; What the adapter and the tests need, which an app does not.
(define kept-out-of-the-facade
  '(make-req-view make-req req-body-made test-req-done!
    res-sized-body? res-sized-body-length res-sized-body-inner
    res-wrapped-body? res-wrapped-body-inner res-wrapped-body-proc
    res-tapped-body? res-tapped-body-inner res-tapped-body-proc
    res-body-port res-body-stream))

(test-begin "names")

(test-equal "the server's libraries, chez-websocket's facade and circuit's are all loaded, side by side"
  '(#t #t #t #t #t #t #t #t #t #t #t)
  (map procedure? (list serve make-test-host headers-ref make-res make-test-req wrap circuit->handler
                        wrap-catch make-router websocket-res websocket-handshake)))

(test-equal "(circuit request) exports its list exactly"
  (sorted request-names)
  (sorted-exports '(circuit request)))

(test-equal "(circuit response) exports its list exactly"
  (sorted response-names)
  (sorted-exports '(circuit response)))

(test-equal "(circuit headers) exports its list exactly"
  (sorted header-names)
  (sorted-exports '(circuit headers)))

(test-equal "(circuit middleware) exports wrap and wrap-body-cap"
  '(wrap wrap-body-cap)
  (sorted-exports '(circuit middleware)))

(test-equal "(circuit middleware waits) exports its three exactly"
  '(wrap-catch wrap-log wrap-timeout)
  (sorted-exports '(circuit middleware waits)))

(test-equal "(circuit router) exports its list exactly"
  (sorted router-names)
  (sorted-exports '(circuit router)))

(test-equal "(circuit websocket) exports websocket-res alone: an app takes the rest from (websocket)"
  '(websocket-res)
  (sorted-exports '(circuit websocket)))

(test-equal "(circuit test) exports its three"
  '(make-test-req res-body->bytevector test-req-done!)
  (sorted-exports '(circuit test)))

(test-equal "(circuit http-server) exports its two and the server's waits, conditions, transport procedures and awaiting, exactly"
  (sorted (append '(circuit->handler run-server) server-reexports))
  (sorted-exports '(circuit http-server)))

(test-equal "(circuit http-server) leaves out the server's pull and its port: req-body is the body's one port"
  '()
  (filter (lambda (name) (memq name (library-exports '(circuit http-server))))
          '(next-body-piece body-input-port)))

(test-equal "(circuit http-server) leaves out make-transport: a test of a taker imports it from (http-server)"
  '()
  (filter (lambda (name) (memq name (library-exports '(circuit http-server)))) '(make-transport)))

(test-equal "(circuit http-server)'s re-exported procedures are the server's own"
  '(#t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t)
  (map (lambda (pair) (eq? (car pair) (cdr pair)))
       (list (cons adapter:awaiting server:awaiting) (cons adapter:await server:await) (cons adapter:sleep-ms server:sleep-ms)
             (cons adapter:with-deadline server:with-deadline) (cons adapter:resolve server:resolve)
             (cons adapter:deadline-passed? server:deadline-passed?)
             (cons adapter:client-closed? server:client-closed?)
             (cons adapter:resolve-error? server:resolve-error?)
             (cons adapter:resolve-error-reason server:resolve-error-reason)
             (cons adapter:body-failed? server:body-failed?)
             (cons adapter:body-failed-reason server:body-failed-reason)
             (cons adapter:body-failed-status server:body-failed-status)
             (cons adapter:transport? server:transport?)
             (cons adapter:transport-write! server:transport-write!)
             (cons adapter:transport-read-start! server:transport-read-start!)
             (cons adapter:transport-read-stop! server:transport-read-stop!)
             (cons adapter:transport-close! server:transport-close!)
             (cons adapter:transport-abort! server:transport-abort!)
             (cons adapter:transport-deadline! server:transport-deadline!)
             (cons adapter:transport-on-drain! server:transport-on-drain!)
             (cons adapter:transport-on-close! server:transport-on-close!))))

(test-equal "(circuit http-server)'s re-exported condition types are the server's own"
  '(#t #t #t #t)
  (map (lambda (pair) (eq? (car pair) (cdr pair)))
       (list (cons (record-type-descriptor adapter:&deadline-passed)
                   (record-type-descriptor server:&deadline-passed))
             (cons (record-type-descriptor adapter:&client-closed)
                   (record-type-descriptor server:&client-closed))
             (cons (record-type-descriptor adapter:&resolve-error)
                   (record-type-descriptor server:&resolve-error))
             (cons (record-type-descriptor adapter:&body-failed)
                   (record-type-descriptor server:&body-failed)))))

(test-equal "(circuit) exports what an app uses, exactly"
  (sorted facade-names)
  (sorted-exports '(circuit)))

(test-equal "(circuit) exports none of the adapter's and the tests' names"
  '()
  (filter (lambda (name) (memq name (library-exports '(circuit)))) kept-out-of-the-facade))

(test-equal "a circuit response is no server response, and a server response no circuit one"
  '(#t #f #f #t)
  (let ((ours (make-res 200 '() #f))
        (theirs (make-response 200 #f '() #f)))
    (list (res? ours) (response? ours) (res? theirs) (response? theirs))))

(test-equal "a circuit sized body is no server sized body, and the other way round"
  '(#t #f #f #t)
  (let* ((producer (lambda () (eof-object)))
         (ours (make-sized-body 1 producer))
         (theirs (sized-body 1 producer)))
    (list (res-sized-body? ours) (sized-body? ours) (res-sized-body? theirs) (sized-body? theirs))))

(test-equal "a circuit test request is no server request"
  '(#t #f)
  (let ((r (make-test-req 'GET "/")))
    (list (req? r) (request? r))))

(test-equal "the like-named bindings are distinct"
  '(#f #f #f #f #f #f #f #f)
  (map (lambda (pair) (eq? (car pair) (cdr pair)))
       (list (cons make-res make-response) (cons res? response?)
             (cons make-sized-body sized-body) (cons res-sized-body? sized-body?)
             (cons req-header request-header) (cons req-header-values request-header-values)
             (cons req-on-done! request-on-done!) (cons header-values headers-ref-all))))

(test-end "names")

(exit (suite-exit-status runner))
