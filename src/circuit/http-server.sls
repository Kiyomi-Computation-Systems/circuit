#!r6rs
;;; (circuit http-server): circuit's adapter onto chez-http-server.
;;;
;;;   (import (rnrs) (circuit) (circuit http-server))
;;;   (run-server (lambda (req) (make-res 200 '() "hello\n")))
;;;
;;; circuit->handler makes a server handler of an app, a procedure from a
;;; req to a res. It answers every request (awaiting thunk), so the app,
;;; its middleware and its body's reads all run on the thunk's coroutine,
;;; where they may wait. The thunk makes the req, through one view over the
;;; server's accessors made here once, calls the app, and turns the res into
;;; the server's response, or into a switch for an upgrade:
;;;
;;;   1. a value that is no res is an assertion violation;
;;;   2. a body that holds the request's own req-body port, bare, sized or
;;;      wrapped, is one too: a producer can't read it (design §9);
;;;   3. the body: #f and a bytevector as they are, a string as its UTF-8,
;;;      a producer as itself; an upgrade's take-over as it is; any other
;;;      kind through res-body-stream. A port is measured first, from its
;;;      position to Chez's length of it. One of a piece or less,
;;;      CIRCUIT_PORT_PIECE_BYTES, is read whole and closed there, and its
;;;      bytes go out as a bytevector; any other has its close registered
;;;      with the server's request-on-done!, so it is closed however the
;;;      response ends, and streams. Only then does a wrap's f run. What
;;;      streams goes sized when it has a length;
;;;   4. then the headers, each name and value a string, one Latin-1 byte a
;;;      character; anything else is an assertion violation;
;;;   5. the status passes through, and the server writes the reason. An
;;;      upgrade, which make-upgrade-res made, answers (switch-protocols
;;;      headers take-over) instead: the server writes the 101, then calls
;;;      the take-over with its transport and the bytes it read past the
;;;      request. It refuses the switch, a 500, for a request that asked for
;;;      no upgrade (design §8).
;;;
;;; The adapter catches nothing: whatever the thunk raises the server
;;; answers, a 500 before the head, a &body-failed's own status, or nothing
;;; for a client that has gone.
;;;
;;; One setting, read once, when circuit->handler is called, from its env or
;;; else the process's environment: CIRCUIT_PORT_PIECE_BYTES, the most a
;;; piece of a port body holds, 65,536 by default. A number is the server's:
;;; ASCII digits alone, leading zeros allowed, at least 1, no maximum; unset
;;; or empty keeps the default. A malformed one raises a condition for which
;;; the server's http-server-config-error? answers #t, as serve raises its
;;; own, so run-server refuses it before anything listens.
;;;
;;; It re-exports the server's waits, the conditions they and the body
;;; raise, and what a take-over uses, the transport procedures and
;;; awaiting, the same bindings as (http-server)'s, so an app needs only
;;; (circuit) and this library. A handler never answers awaiting: the
;;; adapter answers it for every request. Not
;;; next-body-piece or body-input-port: req-body is the body's one port, and
;;; a second would split it. Not make-transport either: it makes a
;;; transport to test a taker without a server, and a test imports it from
;;; (http-server).
(library (circuit http-server)
  (export circuit->handler run-server
          awaiting await sleep-ms with-deadline resolve
          &deadline-passed deadline-passed? &client-closed client-closed?
          &resolve-error resolve-error? resolve-error-reason
          &body-failed body-failed? body-failed-reason body-failed-status
          transport? transport-write! transport-read-start! transport-read-stop!
          transport-close! transport-abort! transport-deadline! transport-on-drain!
          transport-on-close!)
  (import (rnrs)
          (only (chezscheme) getenv port-has-port-length? port-length)
          (only (circuit request) make-req-view make-req req-body-made)
          (only (circuit response) res? res-status res-headers res-body res-body-port
                res-body-stream res-upgrade-body? res-upgrade-body-take-over)
          (only (http-server)
                serve awaiting make-response sized-body switch-protocols body-input-port
                request-on-done!
                request-method request-host request-path request-query request-http-major
                request-http-minor request-header request-header-values request-header-list
                request-remote-address request-remote-port request-local-address
                request-local-port
                &http-server-config-error
                await sleep-ms with-deadline resolve
                &deadline-passed deadline-passed? &client-closed client-closed?
                &resolve-error resolve-error? resolve-error-reason
                &body-failed body-failed? body-failed-reason body-failed-status
                transport? transport-write! transport-read-start! transport-read-stop!
                transport-close! transport-abort! transport-deadline! transport-on-drain!
                transport-on-close!))

  ;; Request = the server's request
  ;; Env = (String -> (U String #f))

  ;; await : ((Any -> Void) -> Any) -> Any
  ;; sleep-ms : Nat -> Void
  ;; with-deadline : Nat (-> (Values Any ...)) -> (Values Any ...)
  ;; resolve : String -> (Listof String)
  ;; deadline-passed?, client-closed?, resolve-error?, body-failed? : Any -> Boolean
  ;; resolve-error-reason : ResolveError -> Symbol
  ;; body-failed-reason : BodyFailed -> Symbol
  ;; body-failed-status : BodyFailed -> Nat
  ;; &deadline-passed, &client-closed, &resolve-error, &body-failed: condition
  ;;   types, each an &error
  ;; The server's own, re-exported: see its docs/waiting.md.

  ;; awaiting : (-> Any) -> Awaiting
  ;; The server's own, re-exported, for a take-over that waits: it answers
  ;; (awaiting thunk), and the server runs THUNK on a coroutine, where it
  ;; may wait; what THUNK returns is dropped. A handler never answers it:
  ;; the adapter answers awaiting for every request, and an app answers a
  ;; res. See the server's docs/upgrades.md.

  ;; transport? : Any -> Boolean
  ;; transport-write! : Transport Bytevector [Nat Nat] [(U #f ((U #f Symbol) -> Any))] -> Any
  ;; transport-read-start! : Transport (Bytevector Nat Nat -> Any) (Symbol -> Any) -> Any
  ;; transport-read-stop!, transport-close!, transport-abort! : Transport -> Any
  ;; transport-deadline! : Transport (U Nat #f) [(-> Any)] -> Any
  ;; transport-on-drain!, transport-on-close! : Transport (-> Any) -> Any
  ;; The server's own, re-exported: see its docs/upgrades.md.

  ;; A malformed setting: a config error of the server's kind, so
  ;; http-server-config-error? answers #t, as it does for serve's own.
  (define-condition-type &circuit-config-error &http-server-config-error
    make-circuit-config-error circuit-config-error?)

  (define piece-variable "CIRCUIT_PORT_PIECE_BYTES")
  (define default-piece-bytes 65536)

  ;; The view over the server's request, made once: the version as major
  ;; then minor, the body the server's port, read with the request's cap
  ;; under the server's own, or with the server's alone.
  (define (http-version request)
    (cons (request-http-major request) (request-http-minor request)))

  (define (body-port request cap) (if cap (body-input-port cap) (body-input-port)))

  (define view
    (make-req-view request-method request-host request-path request-query http-version
                   request-header request-header-values request-header-list body-port
                   request-remote-address request-remote-port request-local-address
                   request-local-port request-on-done!))

  ;; circuit->handler : (Req -> Res) [Env] -> (Request -> Awaiting)
  ;; A server handler that answers every request (awaiting thunk), the thunk
  ;; calling APP on the request and answering the server's response for the
  ;; res it gives, or its switch for an upgrade. ENV, the process's
  ;; environment by getenv unless given, is read once, now. A non-procedure
  ;; APP or ENV is an assertion violation; a malformed
  ;; CIRCUIT_PORT_PIECE_BYTES is a config error.
  (define circuit->handler
    (case-lambda
      ((app) (make-handler app getenv))
      ((app env) (make-handler app env))))

  (define (make-handler app env)
    (unless (procedure? app)
      (assertion-violation 'circuit->handler "an app is a procedure from a req to a res" app))
    (unless (procedure? env)
      (assertion-violation 'circuit->handler
                           "an environment is a procedure from a variable's name to its value or #f"
                           env))
    (let ((size (piece-bytes env)))
      (lambda (request)
        (awaiting (lambda () (answer app request size))))))

  ;; run-server : (Req -> Res) [Env] -> Void
  ;; serve over (circuit->handler app env), both reading ENV, or the
  ;; process's environment when none is given. It returns when serve does.
  (define run-server
    (case-lambda
      ((app) (serve (circuit->handler app)))
      ((app env) (serve (circuit->handler app env) env))))

  ;; piece-bytes : Env -> Nat
  ;; CIRCUIT_PORT_PIECE_BYTES as ENV gives it: the default when unset or
  ;; empty, else a count of 1 or more in ASCII digits, or a config error.
  ;; There is no maximum, but a count past (greatest-fixnum) is taken as
  ;; it: get-bytevector-n refuses a count that is no fixnum, and no piece
  ;; could hold more.
  (define (piece-bytes env)
    (let ((value (env piece-variable)))
      (cond ((or (not value) (equal? value "")) default-piece-bytes)
            ((and (string? value) (digits? value) (>= (string->number value 10) 1))
             (min (string->number value 10) (greatest-fixnum)))
            (else
             (raise (condition (make-circuit-config-error)
                               (make-who-condition 'circuit->handler)
                               (make-message-condition
                                "expected a whole number of bytes, 1 or more, in ASCII digits")
                               (make-irritants-condition (list piece-variable value))))))))

  ;; digits? : String -> Boolean — one or more of #\0 to #\9, nothing else.
  ;; char-numeric? would take other scripts' digits too.
  (define (digits? s)
    (let ((n (string-length s)))
      (and (> n 0)
           (let loop ((i 0))
             (or (= i n)
                 (and (char<=? #\0 (string-ref s i) #\9) (loop (+ i 1))))))))

  ;; answer : (Req -> Res) Request Nat -> (U Response Switch)
  ;; The thunk's work, in order: the req, the app, the res check, the echo
  ;; refusal, the body, and only then the headers. An upgrade's body is its
  ;; take-over, passed as it is, and its answer the server's switch.
  (define (answer app request size)
    (let* ((req (make-req view request))
           (r (app req)))
      (unless (res? r)
        (assertion-violation 'circuit->handler "the app answered no res" r))
      (let* ((body (res-body r))
             (own (req-body-made req)))
        (when (and own (eq? own (res-body-port body)))
          (assertion-violation 'circuit->handler
                               "the response's body holds its request's req-body port, which no producer can read"
                               own))
        (if (res-upgrade-body? body)
            (let* ((take-over (res-upgrade-body-take-over body))
                   (headers (encoded (res-headers r))))
              (switch-protocols headers take-over))
            (let* ((sent (server-body body request size))
                   (headers (encoded (res-headers r))))
              (make-response (res-status r) #f headers sent))))))

  ;; server-body : Body Request Nat -> (U Bytevector #f Producer SizedBody)
  ;; BODY as the server sends it. #f, a bytevector and a producer go as they
  ;; are, a string as its UTF-8. Every other kind goes through
  ;; res-body-stream, a port in pieces of SIZE: whole bytes go as they are,
  ;; and a producer is sized when it has a length.
  (define (server-body body request size)
    (cond ((or (not body) (bytevector? body) (procedure? body)) body)
          ((string? body) (string->utf8 body))
          (else
           (let-values (((sent length)
                         (res-body-stream body measure
                                          (lambda (port)
                                            (request-on-done! request
                                                              (lambda (ending) (close-port port))))
                                          size)))
             (cond ((bytevector? sent) sent)
                   (length (sized-body length sent))
                   (else sent))))))

  ;; measure : BinaryInputPort -> (U Nat #f)
  ;; For a port with a length and a position, a file or a bytevector port,
  ;; the bytes from its position to its length, or 0 past it; #f for any
  ;; other, which goes out chunked. A raise, a FIFO's port-position's,
  ;; goes on: res-body-stream closes the port.
  (define (measure port)
    (and (port-has-port-length? port)
         (port-has-port-position? port)
         (let* ((length (port-length port))
                (position (port-position port)))
           (max 0 (- length position)))))

  ;; encoded : (Listof (Pair String String)) -> (Listof (Pair Bytevector Bytevector))
  ;; Each field's name and value, in order, one Latin-1 byte a character.
  ;; A field that is no pair of strings, or a character above 255, is an
  ;; assertion violation.
  (define (encoded headers)
    (if (null? headers)
        '()
        (let ((field (car headers)))
          (unless (and (pair? field) (string? (car field)) (string? (cdr field)))
            (assertion-violation 'circuit->handler "a header is a (name . value) pair of strings"
                                 field))
          (let* ((name (latin-1 (car field)))
                 (value (latin-1 (cdr field))))
            (cons (cons name value) (encoded (cdr headers)))))))

  ;; latin-1 : String -> Bytevector
  ;; S one byte a character; a character above 255 is an assertion violation.
  (define (latin-1 s)
    (let* ((n (string-length s))
           (bytes (make-bytevector n)))
      (let loop ((i 0))
        (if (= i n)
            bytes
            (let ((c (char->integer (string-ref s i))))
              (unless (< c 256)
                (assertion-violation 'circuit->handler
                                     "a header character above 255 cannot be sent: headers are Latin-1"
                                     s))
              (bytevector-u8-set! bytes i c)
              (loop (+ i 1))))))))
