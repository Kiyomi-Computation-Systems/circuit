#!r6rs
;;; (circuit request): the request, `req`, read through a view.
;;;
;;; A view is a record of procedures the host supplies, one for each field
;;; it can give, each taking the host's own request: the adapter's wraps the
;;; server's accessors, a test request's reads a list. So a request that
;;; reads only its path pays only for its path. Four procedures are required,
;;; method, host, path and http-version; the rest may be #f, and then the
;;; accessor answers #f, or '() for a list.
;;;
;;; A request is the view, the host's request, its keys and one cell. The
;;; keys are an alist, newest first, that req-set conses onto a copy of the
;;; record. The cell is made with the request and shared by every copy
;;; (req-set and the req-with- helpers copy the record, not the cell). It
;;; holds the body's one port once req-body has made it, so every copy
;;; answers the same port, and the on-done state: the procedures kept when
;;; the view has no on-done, and the ending once test-req-done! has given
;;; one.
;;;
;;; Also exported for the adapter and the tests, and left out of the
;;; (circuit) facade: make-req-view, make-req, req-body-made and
;;; test-req-done!.
(library (circuit request)
  (export make-req-view make-req req? req-method req-scheme req-host req-path req-query
          req-http-version req-header req-header-values req-headers req-body
          req-remote-address req-remote-port req-local-address req-local-port
          req-on-done! req-body-made
          make-req-key req-key? req-ref req-set
          req-with-method req-with-scheme req-with-host req-with-path req-with-query
          req-with-remote-address req-with-remote-port
          test-req-done!)
  (import (rnrs) (only (circuit headers) header-names-downcase))

  ;; H = the host's request, whatever the host makes it

  ;; The view. Its first field, scheme, is the req-with-scheme helper's: a
  ;; host gives no scheme, and a request without one answers http.
  (define-record-type (req-view %make-req-view req-view?)
    (fields scheme method host path query http-version header header-values headers body
            remote-address remote-port local-address local-port on-done)
    (sealed #t)
    (opaque #t))

  ;; req? : Any -> Boolean
  ;; At most five fields: one req-set copies the record and conses two pairs,
  ;; which the gate holds (design §15.6, G4).
  (define-record-type (req %make-req req?)
    (fields (immutable view req-view-of)
            (immutable source req-source)
            (immutable keys req-keys)
            (immutable cell req-cell))
    (sealed #t)
    (opaque #t))

  (define-record-type (cell make-cell cell?)
    (fields (mutable port cell-port cell-port-set!)
            (mutable kept cell-kept cell-kept-set!)
            (mutable ending cell-ending cell-ending-set!))
    (sealed #t))

  ;; make-req-view :
  ;;   (H -> Symbol) (H -> String) (H -> String) (U (H -> (U String #f)) #f)
  ;;   (H -> (Pair Nat Nat)) (U (H String -> (U String #f)) #f)
  ;;   (U (H String -> (Listof String)) #f)
  ;;   (U (H -> (Listof (Pair String String))) #f) (U (H -> BinaryInputPort) #f)
  ;;   (U (H -> (U String #f)) #f) (U (H -> (U Nat #f)) #f)
  ;;   (U (H -> (U String #f)) #f) (U (H -> (U Nat #f)) #f)
  ;;   (U (H (Symbol -> Any) -> Any) #f)
  ;;   -> View
  ;; A view from its fourteen procedures, in this order. method, host, path
  ;; and http-version must be procedures; each of the rest a procedure or
  ;; #f. Anything else is an assertion violation naming the field.
  (define (make-req-view method host path query http-version header header-values headers
                         body remote-address remote-port local-address local-port on-done)
    (required 'method method)
    (required 'host host)
    (required 'path path)
    (optional 'query query)
    (required 'http-version http-version)
    (optional 'header header)
    (optional 'header-values header-values)
    (optional 'headers headers)
    (optional 'body body)
    (optional 'remote-address remote-address)
    (optional 'remote-port remote-port)
    (optional 'local-address local-address)
    (optional 'local-port local-port)
    (optional 'on-done on-done)
    (%make-req-view #f method host path query http-version header header-values headers body
                    remote-address remote-port local-address local-port on-done))

  (define (required field proc)
    (unless (procedure? proc)
      (assertion-violation 'make-req-view "a required view procedure is not a procedure"
                           field proc)))

  (define (optional field proc)
    (unless (or (not proc) (procedure? proc))
      (assertion-violation 'make-req-view "a view procedure is neither a procedure nor #f"
                           field proc)))

  ;; make-req : View Any -> Req
  ;; A request read through VIEW from SOURCE, the host's request, with no
  ;; keys and a fresh cell: the record and the cell, nothing else.
  (define (make-req view source)
    (unless (req-view? view)
      (assertion-violation 'make-req "not a request view" view))
    (%make-req view source '() (make-cell #f '() #f)))

  ;; view-of : Symbol Any -> View
  ;; R's view, once R is a request; otherwise an assertion violation from WHO.
  (define (view-of who r)
    (unless (req? r)
      (assertion-violation who "not a request" r))
    (req-view-of r))

  ;; --- the accessors ----------------------------------------------------------

  ;; req-method : Req -> Symbol
  ;; The method, as the symbol the host names it by: GET, POST.
  (define (req-method r)
    (let ((view (view-of 'req-method r)))
      ((req-view-method view) (req-source r))))

  ;; req-scheme : Req -> Symbol
  ;; http, unless req-with-scheme gave the request another.
  (define (req-scheme r)
    (let ((proc (req-view-scheme (view-of 'req-scheme r))))
      (if proc (proc (req-source r)) 'http)))

  ;; req-host : Req -> String
  ;; The host the request names, "" when it names none.
  (define (req-host r)
    (let ((view (view-of 'req-host r)))
      ((req-view-host view) (req-source r))))

  ;; req-path : Req -> String
  ;; The path as it came, undecoded.
  (define (req-path r)
    (let ((view (view-of 'req-path r)))
      ((req-view-path view) (req-source r))))

  ;; req-query : Req -> (U String #f)
  ;; What follows the target's first ?, or #f.
  (define (req-query r)
    (let ((proc (req-view-query (view-of 'req-query r))))
      (and proc (proc (req-source r)))))

  ;; req-http-version : Req -> (Pair Nat Nat)
  ;; The major and minor numbers the request named.
  (define (req-http-version r)
    (let ((view (view-of 'req-http-version r)))
      ((req-view-http-version view) (req-source r))))

  ;; req-header : Req String -> (U String #f)
  ;; The first field named NAME, in any case, as the view reads it.
  (define (req-header r name)
    (let ((proc (req-view-header (view-of 'req-header r))))
      (check-name 'req-header name)
      (and proc (proc (req-source r) name))))

  ;; req-header-values : Req String -> (Listof String)
  ;; Every field named NAME, in order.
  (define (req-header-values r name)
    (let ((proc (req-view-header-values (view-of 'req-header-values r))))
      (check-name 'req-header-values name)
      (if proc (proc (req-source r) name) '())))

  ;; req-headers : Req -> (Listof (Pair String String))
  ;; Every field, in order, duplicates kept, each name folded to lower case
  ;; whatever case the view gives it in.
  (define (req-headers r)
    (let ((proc (req-view-headers (view-of 'req-headers r))))
      (if proc (header-names-downcase (proc (req-source r))) '())))

  ;; req-body : Req -> BinaryInputPort
  ;; The body's one port, the same for every copy of the request. The first
  ;; call makes it, from the view's body, or as an empty port that reads eof
  ;; at once when the view has none, and keeps it in the cell. A view body
  ;; that answers anything but a binary input port is an assertion
  ;; violation, and nothing is kept.
  (define (req-body r)
    (let* ((view (view-of 'req-body r))
           (cell (req-cell r)))
      (or (cell-port cell)
          (let* ((proc (req-view-body view))
                 (port (if proc (proc (req-source r)) (open-bytevector-input-port #vu8()))))
            (unless (and (port? port) (input-port? port) (binary-port? port))
              (assertion-violation 'req-body "the view's body is not a binary input port" port))
            (cell-port-set! cell port)
            port))))

  ;; req-body-made : Req -> (U BinaryInputPort #f)
  ;; The port req-body has made, through any copy, or #f. It makes none.
  (define (req-body-made r)
    (view-of 'req-body-made r)
    (cell-port (req-cell r)))

  ;; req-remote-address : Req -> (U String #f)
  ;; req-remote-port : Req -> (U Nat #f)
  ;; req-local-address : Req -> (U String #f)
  ;; req-local-port : Req -> (U Nat #f)
  ;; The connection's two ends, as the host read them, or #f where it can't
  ;; say: a test request has none.
  (define (req-remote-address r)
    (let ((proc (req-view-remote-address (view-of 'req-remote-address r))))
      (and proc (proc (req-source r)))))

  (define (req-remote-port r)
    (let ((proc (req-view-remote-port (view-of 'req-remote-port r))))
      (and proc (proc (req-source r)))))

  (define (req-local-address r)
    (let ((proc (req-view-local-address (view-of 'req-local-address r))))
      (and proc (proc (req-source r)))))

  (define (req-local-port r)
    (let ((proc (req-view-local-port (view-of 'req-local-port r))))
      (and proc (proc (req-source r)))))

  (define (check-name who name)
    (unless (string? name)
      (assertion-violation who "a header name is a string" name)))

  ;; --- keys -------------------------------------------------------------------

  ;; make-req-key : Any -> Key
  ;; A key no other call makes, whatever NAME is: NAME is for a reader.
  ;; req-key? : Any -> Boolean
  (define-record-type (req-key make-req-key req-key?)
    (fields name)
    (sealed #t))

  ;; req-ref : Req Key [Any] -> Any
  ;; The newest value KEY was set to, or DEFAULT, #f unless given.
  (define req-ref
    (case-lambda
      ((r key) (key-ref 'req-ref r key #f))
      ((r key default) (key-ref 'req-ref r key default))))

  (define (key-ref who r key default)
    (view-of who r)
    (check-key who key)
    (let ((hit (assq key (req-keys r))))
      (if hit (cdr hit) default)))

  ;; req-set : Req Key Any -> Req
  ;; A copy of R with KEY set to VALUE, sharing R's cell: one record and
  ;; two pairs.
  (define (req-set r key value)
    (let ((view (view-of 'req-set r)))
      (check-key 'req-set key)
      (%make-req view (req-source r) (cons (cons key value) (req-keys r)) (req-cell r))))

  (define (check-key who key)
    (unless (req-key? key)
      (assertion-violation who "not a request key from make-req-key" key)))

  ;; --- the req-with- helpers ----------------------------------------------------

  ;; req-with-method : Req Symbol -> Req
  ;; req-with-scheme : Req Symbol -> Req
  ;; req-with-host : Req String -> Req
  ;; req-with-path : Req String -> Req
  ;; req-with-query : Req (U String #f) -> Req
  ;; req-with-remote-address : Req (U String #f) -> Req
  ;; req-with-remote-port : Req (U Nat #f) -> Req
  ;; Each a copy of R, sharing its keys and its cell, whose view answers
  ;; VALUE for that field. A value of another type is an assertion
  ;; violation.
  (define (req-with-method r value)
    (with-field 'req-with-method r 'method value symbol?))
  (define (req-with-scheme r value)
    (with-field 'req-with-scheme r 'scheme value symbol?))
  (define (req-with-host r value)
    (with-field 'req-with-host r 'host value string?))
  (define (req-with-path r value)
    (with-field 'req-with-path r 'path value string?))
  (define (req-with-query r value)
    (with-field 'req-with-query r 'query value string-or-false?))
  (define (req-with-remote-address r value)
    (with-field 'req-with-remote-address r 'remote-address value string-or-false?))
  (define (req-with-remote-port r value)
    (with-field 'req-with-remote-port r 'remote-port value port-number-or-false?))

  (define (string-or-false? x) (or (not x) (string? x)))
  (define (port-number-or-false? x) (or (not x) (and (integer? x) (exact? x) (>= x 0))))

  (define (with-field who r field value ok?)
    (let ((view (view-of who r)))
      (unless (ok? value)
        (assertion-violation who "not a value for this field" value))
      (%make-req (view-with view field (lambda (source) value))
                 (req-source r) (req-keys r) (req-cell r))))

  ;; view-with : View Symbol Procedure -> View
  ;; VIEW with FIELD's procedure replaced by PROC.
  (define (view-with view field proc)
    (define (pick name get) (if (eq? field name) proc (get view)))
    (%make-req-view (pick 'scheme req-view-scheme)
                    (pick 'method req-view-method)
                    (pick 'host req-view-host)
                    (pick 'path req-view-path)
                    (pick 'query req-view-query)
                    (req-view-http-version view)
                    (req-view-header view)
                    (req-view-header-values view)
                    (req-view-headers view)
                    (req-view-body view)
                    (pick 'remote-address req-view-remote-address)
                    (pick 'remote-port req-view-remote-port)
                    (req-view-local-address view)
                    (req-view-local-port view)
                    (req-view-on-done view)))

  ;; --- when the response is done ------------------------------------------------

  ;; req-on-done! : Req (Symbol -> Any) -> Void
  ;; Registers PROC to be called once, with how the response ended. With the
  ;; view's on-done it is handed to that, with the host's request. Without,
  ;; the request keeps it in its cell for test-req-done!, or, once that has
  ;; given an ending, calls it at once with that ending, its raise the
  ;; caller's. A non-procedure is an assertion violation.
  (define (req-on-done! r proc)
    (let ((view (view-of 'req-on-done! r)))
      (unless (procedure? proc)
        (assertion-violation 'req-on-done! "not a procedure" proc))
      (let ((on-done (req-view-on-done view))
            (cell (req-cell r)))
        (cond (on-done (on-done (req-source r) proc))
              ((cell-ending cell) (proc (cell-ending cell)))
              (else (cell-kept-set! cell (cons proc (cell-kept cell))))))
      (if #f #f)))

  (define endings '(written client-closed failed))

  ;; test-req-done! : Req Symbol -> (Listof Any)
  ;; Ends R's response with ENDING for a request whose view has no on-done,
  ;; by the server's rules. An ending other than written, client-closed or
  ;; failed is an assertion violation, checked first; so is a request whose
  ;; view has on-done, since its host calls those. It calls the kept
  ;; procedures newest first, each once, with ENDING. A raise stops none of
  ;; the rest: it answers what was raised, oldest raise first, '() when
  ;; nothing was. The first ending holds: a later call calls nothing and
  ;; answers '(), and a procedure kept later runs at once with it.
  (define (test-req-done! r ending)
    (unless (memq ending endings)
      (assertion-violation 'test-req-done! "an ending is written, client-closed or failed" ending))
    (let* ((view (view-of 'test-req-done! r))
           (cell (req-cell r)))
      (when (req-view-on-done view)
        (assertion-violation 'test-req-done! "the request's host calls its on-done procedures" r))
      (if (cell-ending cell)
          '()
          (let ((kept (cell-kept cell)))
            (cell-ending-set! cell ending)
            (cell-kept-set! cell '())
            (let loop ((procs kept) (raised '()))
              (if (null? procs)
                  (reverse raised)
                  (loop (cdr procs)
                        (guard (e (#t (cons e raised)))
                          ((car procs) ending)
                          raised)))))))))
