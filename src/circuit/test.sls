#!r6rs
;;; (circuit test): what a test of a handler needs, with no server.
;;;
;;;   make-test-req          a request from a method, a target, headers and a
;;;                          body, read through a view of its own
;;;   test-req-done!         (circuit request)'s, re-exported: ends a test
;;;                          request's response, calling what it kept
;;;   res-body->bytevector   a response's body, read as the adapter sends it;
;;;                          an upgrade, which has none, refused
;;;
;;; A test request's view reads a record of what it was made with. It has
;;; no addresses, as the server's test host has none, and no on-done, so the
;;; request keeps the procedures req-on-done! is given until test-req-done!.
;;; Its body is read whole whatever the request's cap: the server enforces a
;;; cap, so a test of one runs in the server's test host.
(library (circuit test)
  (export make-test-req test-req-done! res-body->bytevector)
  (import (rnrs)
          (only (circuit headers) header-value header-values)
          (only (circuit request) make-req-view make-req req? req-body-made test-req-done!)
          (only (circuit response) res? res-body res-body-port res-body-stream res-upgrade-body?))

  ;; What a test request was made with: the view's host request.
  (define-record-type (source make-source source?)
    (fields method path query headers body)
    (sealed #t)
    (opaque #t))

  (define (source-host s)
    (or (header-value (source-headers s) "host") (string)))

  (define (source-header s name) (header-value (source-headers s) name))
  (define (source-header-values s name) (header-values (source-headers s) name))
  (define (source-body-port s cap) (open-bytevector-input-port (source-body s)))
  (define (http/1.1 s) (cons 1 1))

  (define (test-view body)
    (make-req-view source-method source-host source-path source-query http/1.1
                   source-header source-header-values source-headers body
                   #f #f #f #f #f))

  ;; Two views serve every test request: one reads the request's bytes, the
  ;; other, for a request made with no body, has no body procedure.
  (define bodied-view (test-view source-body-port))
  (define bodiless-view (test-view #f))

  ;; make-test-req : Symbol String [Headers [(U Bytevector String #f)]] -> Req
  ;; A request for METHOD and TARGET, an origin-form target that begins
  ;; with /, split at its first ? into the path and the query, #f with no ?.
  ;; An absolute-form or asterisk-form target, whose path and host the server
  ;; reads otherwise, is refused: it belongs in the server's test host.
  ;; HEADERS, '() unless given, are read in any case, each value without the
  ;; SP and HTAB at either end, as the server reads a value (its
  ;; field-value); the host is the first host field's value so read, or ""
  ;; without one, as the server's request-host answers. BODY is read
  ;; through req-body: a bytevector as given, a string as its UTF-8, and #f,
  ;; the default, as no body. HTTP/1.1, and no addresses. A value of the
  ;; wrong kind is an assertion violation.
  (define make-test-req
    (case-lambda
      ((method target) (test-req method target '() #f))
      ((method target headers) (test-req method target headers #f))
      ((method target headers body) (test-req method target headers body))))

  (define (test-req method target headers body)
    (unless (symbol? method)
      (assertion-violation 'make-test-req "a method is a symbol" method))
    (unless (string? target)
      (assertion-violation 'make-test-req "a target is a string" target))
    (unless (and (> (string-length target) 0) (char=? (string-ref target 0) #\/))
      (assertion-violation 'make-test-req
                           "a target begins with /: take an absolute-form or asterisk-form target to the server's test host"
                           target))
    (check-headers headers)
    (unless (or (not body) (bytevector? body) (string? body))
      (assertion-violation 'make-test-req "a body is #f, a bytevector or a string" body))
    (let-values (((path query) (split-target target)))
      (make-req (if body bodied-view bodiless-view)
                (make-source method path query (map trimmed headers)
                             (if (string? body) (string->utf8 body) body)))))

  ;; trimmed : (Pair String String) -> (Pair String String)
  ;; FIELD with its value read as the server reads one: without the SP and
  ;; HTAB at either end. Nothing else is trimmed: the server keeps a
  ;; no-break space, as it keeps every other byte.
  (define (trimmed field)
    (let* ((value (cdr field))
           (n (string-length value))
           (start (let loop ((i 0))
                    (if (and (< i n) (ows? (string-ref value i))) (loop (+ i 1)) i)))
           (end (let loop ((i n))
                  (if (and (> i start) (ows? (string-ref value (- i 1)))) (loop (- i 1)) i))))
      (cons (car field) (substring value start end))))

  (define (ows? c) (or (char=? c #\space) (char=? c #\tab)))

  (define (check-headers headers)
    (unless (list? headers)
      (assertion-violation 'make-test-req "headers are a list of (name . value) string pairs"
                           headers))
    (for-each (lambda (field)
                (unless (and (pair? field) (string? (car field)) (string? (cdr field)))
                  (assertion-violation 'make-test-req "a header field is a (name . value) pair of strings"
                                       field)))
              headers))

  ;; split-target : String -> (Values String (U String #f))
  ;; TARGET up to its first ?, and what follows it, or #f with no ?.
  (define (split-target target)
    (let ((n (string-length target)))
      (let loop ((i 0))
        (cond ((= i n) (values (substring target 0 n) #f))
              ((char=? (string-ref target i) #\?)
               (values (substring target 0 i) (substring target (+ i 1) n)))
              (else (loop (+ i 1)))))))

  ;; res-body->bytevector : Res [Req] -> Bytevector
  ;; R's body, read as the adapter sends it: through res-body-stream, in
  ;; pieces of 65,536 bytes, a bare port measured by port-read-ahead-length,
  ;; so one of a piece or less is read whole, and its bytes are the answer.
  ;; A body with a length is read to it, never asking past it, and one that
  ;; runs long or ends short is an assertion violation naming both counts,
  ;; where the server would close the connection. A piece that is no
  ;; bytevector, or an empty one, is an assertion violation, as the
  ;; server's rule is. Given REQ, a body that holds REQ's body port, bare,
  ;; sized, wrapped or tapped, is an assertion violation, as the adapter
  ;; refuses it (design §9), checked before anything is read; a request
  ;; whose port was never made has none to hold. An upgrade response is an
  ;; assertion violation: it has no body to read, and after the 101 the
  ;; stream is the taker's.
  (define res-body->bytevector
    (case-lambda
      ((r) (read-body r #f))
      ((r req) (read-body r req))))

  (define (read-body r req)
    (unless (res? r)
      (assertion-violation 'res-body->bytevector "not a response" r))
    (when (res-upgrade-body? (res-body r))
      (assertion-violation 'res-body->bytevector
                           "an upgrade has no body to read: after the 101, the stream is the taker's" r))
    (when req
      (unless (req? req)
        (assertion-violation 'res-body->bytevector "not a request" req))
      (let ((own (req-body-made req)))
        (when (and own (eq? own (res-body-port (res-body r))))
          (assertion-violation 'res-body->bytevector
                               "the body holds its request's body port, which the adapter refuses"
                               own))))
    (let-values (((sent n) (res-body-stream (res-body r) port-read-ahead-length
                                            (lambda (port) #f) 65536)))
      (if (bytevector? sent) sent (drained sent n))))

  ;; drained : Producer (U Nat #f) -> Bytevector
  ;; PRODUCE's pieces, to N when there is one, else to its eof, each piece
  ;; held to the server's rules.
  (define (drained produce n)
    (let-values (((out extract) (open-bytevector-output-port)))
      (let loop ((count 0))
        (if (and n (= count n))
            (extract)
            (let ((piece (produce)))
              (cond
                ((eof-object? piece)
                 (when (and n (< count n))
                   (assertion-violation 'res-body->bytevector "the body ended short of its length"
                                        n count))
                 (extract))
                ((not (and (bytevector? piece) (> (bytevector-length piece) 0)))
                 (assertion-violation 'res-body->bytevector "a piece is a bytevector of one byte or more"
                                      piece))
                (else
                 (let ((next (+ count (bytevector-length piece))))
                   (when (and n (> next n))
                     (assertion-violation 'res-body->bytevector "the body ran past its length"
                                          n next))
                   (put-bytevector out piece)
                   (loop next)))))))))

  ;; port-read-ahead-length : BinaryInputPort -> (U Nat #f)
  ;; How many bytes PORT holds from its position to its eof, for a port that
  ;; can tell and set its position: read ahead, then set back. Any other
  ;; port answers #f, and is read to its eof. The adapter sizes a port by
  ;; Chez's port length instead, which plain R6RS can't ask. The two agree
  ;; on a bytevector port and a file, but a custom port with position
  ;; procedures is sized here and goes out chunked from the adapter, which
  ;; reads it to its eof. So the two differ only for such a port, which this
  ;; reads to the length it measured, and the adapter to its eof.
  (define (port-read-ahead-length port)
    (and (port-has-port-position? port)
         (port-has-set-port-position!? port)
         (let* ((start (port-position port))
                (bytes (get-bytevector-all port)))
           (set-port-position! port start)
           (if (eof-object? bytes) 0 (bytevector-length bytes))))))
