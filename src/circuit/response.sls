#!r6rs
;;; (circuit response): the response, `res`, and its bodies.
;;;
;;; (make-res status headers body), in Ring's order. The constructor checks
;;; the kinds and rewrites nothing. A body is one of these:
;;;
;;;   #f                  no body
;;;   Bytevector
;;;   String              sent as UTF-8
;;;   Producer            (-> (U Bytevector Eof)), called for each piece
;;;   BinaryInputPort     streamed, and closed once read
;;;   SizedBody           (make-sized-body n body): a producer or a port of
;;;                       n bytes, sent with that length
;;;   WrappedBody         (res-wrap-body res f [same?]): another body, its
;;;                       producer passed through f when it is sent
;;;
;;; A body holds at most one port: bare, under a sized body, or under wraps.
;;; res-with-body closes it when it replaces the body; res-wrap-body closes
;;; nothing, since the wrap is lazy: res-body-stream, which the adapter and
;;; the tests send a body through, is the one place f is called.
;;;
;;; res-wrap-body's shape is provisional (design §15.11, §16.4).
;;;
;;; Also exported for the adapter and the tests, and left out of the
;;; (circuit) facade: the res-sized-body- and res-wrapped-body- accessors,
;;; res-body-port and res-body-stream.
(library (circuit response)
  (export make-res res? res-status res-headers res-body
          res-header res-set-header res-add-header res-with-status res-with-body
          make-sized-body res-sized-body? res-sized-body-length res-sized-body-inner
          res-wrap-body res-wrapped-body? res-wrapped-body-inner res-wrapped-body-proc
          res-wrapped-body-same?
          res-body-length res-body-port res-body-stream)
  (import (rnrs) (only (circuit headers) header-value header-set header-add))

  ;; Producer = (-> (U Bytevector Eof))
  ;; Body = (U #f Bytevector String Producer BinaryInputPort SizedBody WrappedBody)

  ;; res? : Any -> Boolean
  ;; res-status : Res -> Integer
  ;; res-headers : Res -> (Listof (Pair String String))
  ;; res-body : Res -> Body
  (define-record-type (res %make-res res?)
    (fields (immutable status res-status)
            (immutable headers res-headers)
            (immutable body res-body))
    (sealed #t)
    (opaque #t))

  ;; res-sized-body? : Any -> Boolean
  ;; res-sized-body-length : SizedBody -> Nat
  ;; res-sized-body-inner : SizedBody -> (U Producer BinaryInputPort)
  (define-record-type (sized %make-sized res-sized-body?)
    (fields (immutable length res-sized-body-length)
            (immutable inner res-sized-body-inner))
    (sealed #t))

  ;; res-wrapped-body? : Any -> Boolean
  ;; res-wrapped-body-inner : WrappedBody -> Body
  ;; res-wrapped-body-proc : WrappedBody -> (Producer -> Producer)
  ;; res-wrapped-body-same? : WrappedBody -> Boolean
  (define-record-type (wrapping %make-wrap res-wrapped-body?)
    (fields (immutable inner res-wrapped-body-inner)
            (immutable proc res-wrapped-body-proc)
            (immutable same? res-wrapped-body-same?))
    (sealed #t))

  ;; make-res : Integer Headers Body -> Res
  ;; A response. STATUS must be an exact integer, HEADERS a list, and BODY
  ;; a body kind, or it is an assertion violation. Nothing is rewritten.
  (define (make-res status headers body)
    (check-status 'make-res status)
    (unless (list? headers)
      (assertion-violation 'make-res "headers are a list of (name . value) string pairs" headers))
    (check-body 'make-res body)
    (%make-res status headers body))

  (define (check-status who status)
    (unless (and (integer? status) (exact? status))
      (assertion-violation who "a status is an exact integer" status)))

  (define (check-res who r)
    (unless (res? r)
      (assertion-violation who "not a response" r)))

  (define (binary-input-port? x)
    (and (port? x) (input-port? x) (binary-port? x)))

  (define (body? x)
    (or (not x) (bytevector? x) (string? x) (procedure? x) (binary-input-port? x)
        (res-sized-body? x) (res-wrapped-body? x)))

  (define (check-body who body)
    (unless (body? body)
      (assertion-violation who "not a body: #f, a bytevector, a string, a producer, a binary input port, a sized body or a wrapped body"
                           body)))

  (define (count? n) (and (integer? n) (exact? n) (>= n 0)))

  ;; --- helpers ------------------------------------------------------------------

  ;; res-header : Res String -> (U String #f)
  ;; The value of R's first field named NAME, in any case.
  (define (res-header r name)
    (check-res 'res-header r)
    (header-value (res-headers r) name))

  ;; res-set-header : Res String String -> Res
  ;; R with every field named NAME replaced by one, the name in lower case.
  (define (res-set-header r name value)
    (check-res 'res-set-header r)
    (%make-res (res-status r) (header-set (res-headers r) name value) (res-body r)))

  ;; res-add-header : Res String String -> Res
  ;; R with a field appended, the name in lower case.
  (define (res-add-header r name value)
    (check-res 'res-add-header r)
    (%make-res (res-status r) (header-add (res-headers r) name value) (res-body r)))

  ;; res-with-status : Res Integer -> Res
  ;; R with STATUS. A 1xx status is an assertion violation: the server sends
  ;; those itself, and refuses one from a handler.
  (define (res-with-status r status)
    (check-res 'res-with-status r)
    (check-status 'res-with-status status)
    (when (and (>= status 100) (<= status 199))
      (assertion-violation 'res-with-status "a 1xx status is the server's to send" status))
    (%make-res status (res-headers r) (res-body r)))

  ;; res-with-body : Res Body -> Res
  ;; R with BODY, checked as make-res checks it. The body is replaced
  ;; outright, so the port the old body holds, at any depth, is closed,
  ;; unless BODY holds that same port: (res-with-body r (make-sized-body n
  ;; (res-body r))) keeps it open.
  (define (res-with-body r body)
    (check-res 'res-with-body r)
    (check-body 'res-with-body body)
    (let ((old (body-port (res-body r))))
      (when (and old (not (eq? old (body-port body))))
        (close-port old)))
    (%make-res (res-status r) (res-headers r) body))

  ;; make-sized-body : Nat (U Producer BinaryInputPort) -> SizedBody
  ;; BODY, a producer or a port, declared to hold N bytes, sent with that
  ;; length. Anything else is an assertion violation.
  (define (make-sized-body n body)
    (unless (count? n)
      (assertion-violation 'make-sized-body "a length is an exact count of bytes" n))
    (unless (or (procedure? body) (binary-input-port? body))
      (assertion-violation 'make-sized-body "a sized body is a producer or a binary input port"
                           body))
    (%make-sized n body))

  ;; res-wrap-body : Res (Producer -> Producer) [Boolean] -> Res
  ;; R with its body wrapped: when the body is sent, F is handed the old
  ;; body as a producer, and the producer F gives back is sent. SAME?, #f
  ;; unless given, says F gives back as many bytes as it is handed, so the
  ;; body keeps the old one's length. Wraps nest. It closes nothing and
  ;; calls nothing. Provisional (design §16.4).
  (define res-wrap-body
    (case-lambda
      ((r f) (wrap-body r f #f))
      ((r f same?) (wrap-body r f same?))))

  (define (wrap-body r f same?)
    (check-res 'res-wrap-body r)
    (unless (procedure? f)
      (assertion-violation 'res-wrap-body "a wrap's f is a procedure from producer to producer" f))
    (unless (boolean? same?)
      (assertion-violation 'res-wrap-body "same? is #t or #f" same?))
    (%make-res (res-status r) (res-headers r) (%make-wrap (res-body r) f same?)))

  ;; --- what a body holds ---------------------------------------------------------

  ;; res-body-length : Res -> (U Nat #f)
  ;; The length of R's body where the core can tell it: #f 0, a bytevector
  ;; its length, a string its UTF-8 length, a sized body its n, and a wrap
  ;; that keeps the bytes the length of the body under it. Otherwise #f: a
  ;; producer, a wrap that drops the length, and a port, whose length is
  ;; Chez's for the adapter to read.
  (define (res-body-length r)
    (check-res 'res-body-length r)
    (body-length (res-body r)))

  (define (body-length body)
    (cond ((not body) 0)
          ((bytevector? body) (bytevector-length body))
          ((string? body) (utf8-length body))
          ((res-sized-body? body) (res-sized-body-length body))
          ((res-wrapped-body? body)
           (and (res-wrapped-body-same? body) (body-length (res-wrapped-body-inner body))))
          (else #f)))

  ;; utf8-length : String -> Nat
  ;; How many bytes string->utf8 would answer, counted without making them.
  (define (utf8-length s)
    (let ((n (string-length s)))
      (let loop ((i 0) (total 0))
        (if (= i n)
            total
            (let ((c (char->integer (string-ref s i))))
              (loop (+ i 1)
                    (+ total (cond ((< c #x80) 1) ((< c #x800) 2) ((< c #x10000) 3) (else 4)))))))))

  ;; res-body-port : Body -> (U BinaryInputPort #f)
  ;; The port BODY holds, bare, under a sized body or under wraps, or #f.
  ;; What is no body kind is an assertion violation.
  (define (res-body-port body)
    (check-body 'res-body-port body)
    (body-port body))

  (define (body-port body)
    (cond ((binary-input-port? body) body)
          ((res-sized-body? body) (body-port (res-sized-body-inner body)))
          ((res-wrapped-body? body) (body-port (res-wrapped-body-inner body)))
          (else #f)))

  ;; --- sending a body ---------------------------------------------------------------

  ;; res-body-stream : Body (BinaryInputPort -> (U Nat #f)) (BinaryInputPort -> Any) Nat
  ;;                   -> (Values Producer (U Nat #f))
  ;; The producer that sends BODY, and its length, or #f for none. SIZE is
  ;; the most a port's piece holds. No producer answers an empty piece.
  ;;
  ;; A body that holds a port is first made the caller's, before any wrap's
  ;; f runs: MEASURE is called once with the port, unless a sized body says
  ;; its length, and answers that length or #f; then ON-PORT is called once
  ;; with the port, where the adapter registers its close (design §9). If
  ;; MEASURE or ON-PORT raises, or MEASURE answers no count, the port is
  ;; closed, the raise goes on, and no f runs. After ON-PORT the port is the
  ;; caller's to close: a raise from f closes nothing. A body that holds no
  ;; port calls neither.
  ;;
  ;; #f, a bytevector or a string is one piece, its UTF-8 for a string, or
  ;; eof at once when it is empty; its length its bytes'. A producer is
  ;; itself, with no length. A port is read in pieces of at most SIZE, and
  ;; never past the length MEASURE gives: it answers eof, the port closed,
  ;; at the port's eof, and is closed as its last byte is read. A sized
  ;; body is its inner body's producer, a port's read as far as its n, with
  ;; length n. A wrap streams the body under it first, then calls its f: with
  ;; same?, on that producer, keeping that length; without, on a producer
  ;; that stops at the length the body under it had, if any, raising at a
  ;; piece that would pass it, and with no length. F's answer must be a
  ;; procedure.
  (define (res-body-stream body measure on-port size)
    (check-body 'res-body-stream body)
    (unless (procedure? measure)
      (assertion-violation 'res-body-stream "the measure is a procedure from port to length" measure))
    (unless (procedure? on-port)
      (assertion-violation 'res-body-stream "on-port is a procedure of the port" on-port))
    (unless (and (count? size) (> size 0))
      (assertion-violation 'res-body-stream "a piece size is a positive count of bytes" size))
    (let-values (((port sized?) (port-place body)))
      (let ((n (and port (not sized?)
                    (closing-on-raise port (lambda () (measured port measure))))))
        (when port
          (closing-on-raise port (lambda () (on-port port))))
        (stream body n size))))

  ;; port-place : Body -> (Values (U BinaryInputPort #f) Boolean)
  ;; The port BODY holds, or #f, and whether a sized body holds it.
  (define (port-place body)
    (cond ((binary-input-port? body) (values body #f))
          ((res-sized-body? body)
           (let ((inner (res-sized-body-inner body)))
             (if (procedure? inner) (values #f #f) (values inner #t))))
          ((res-wrapped-body? body) (port-place (res-wrapped-body-inner body)))
          (else (values #f #f))))

  (define (measured port measure)
    (let ((n (measure port)))
      (unless (or (not n) (count? n))
        (assertion-violation 'res-body-stream "a port's measure answered no count of bytes" n))
      n))

  ;; closing-on-raise : BinaryInputPort (-> Any) -> Any
  ;; THUNK's answer; if it raises, PORT is closed and the raise goes on.
  (define (closing-on-raise port thunk)
    (guard (e (#t (close-port port) (raise e)))
      (thunk)))

  ;; stream : Body (U Nat #f) Nat -> (Values Producer (U Nat #f))
  ;; As res-body-stream, the port measured already: N is a bare port's
  ;; length, or #f.
  (define (stream body n size)
    (cond
      ((not body) (bytes-stream #vu8()))
      ((bytevector? body) (bytes-stream body))
      ((string? body) (bytes-stream (string->utf8 body)))
      ((procedure? body) (values body #f))
      ((binary-input-port? body) (values (port-producer body n size) n))
      ((res-sized-body? body)
       (let ((length (res-sized-body-length body))
             (inner (res-sized-body-inner body)))
         (values (if (procedure? inner) inner (port-producer inner length size)) length)))
      (else
       (let-values (((inner length) (stream (res-wrapped-body-inner body) n size)))
         (let* ((same? (res-wrapped-body-same? body))
                (handed (if (or same? (not length)) inner (counting-producer inner length)))
                (out ((res-wrapped-body-proc body) handed)))
           (unless (procedure? out)
             (assertion-violation 'res-body-stream "a wrap's f answered no producer" out))
           (values out (and same? length)))))))

  ;; bytes-stream : Bytevector -> (Values Producer Nat)
  ;; BYTES as one piece, then eof; eof at once when BYTES is empty.
  (define (bytes-stream bytes)
    (values (if (= (bytevector-length bytes) 0)
                (lambda () (eof-object))
                (let ((sent? #f))
                  (lambda ()
                    (if sent?
                        (eof-object)
                        (begin (set! sent? #t) bytes)))))
            (bytevector-length bytes)))

  ;; port-producer : BinaryInputPort (U Nat #f) Nat -> Producer
  ;; PORT in pieces of at most SIZE, and at most what is left of N. It
  ;; never asks for 0 bytes: Chez's get-bytevector-n of 0 answers an empty
  ;; bytevector, even on a closed port. It closes the port at its eof, or
  ;; as the Nth byte is read, and answers eof from then on.
  (define (port-producer port n size)
    (let ((left n) (done? #f))
      (define (finish)
        (set! done? #t)
        (close-port port))
      (lambda ()
        (cond
          (done? (eof-object))
          ((eqv? left 0) (finish) (eof-object))
          (else
           (let ((piece (get-bytevector-n port (if left (min size left) size))))
             (cond
               ((eof-object? piece) (finish) piece)
               (else
                (when left
                  (set! left (- left (bytevector-length piece)))
                  (when (= left 0) (finish)))
                piece))))))))

  ;; counting-producer : Producer Nat -> Producer
  ;; INNER until N bytes have passed, then eof, never asking INNER again. A
  ;; piece that would take the count past N is an assertion violation
  ;; naming N and that count. An eof before N just ends.
  (define (counting-producer inner n)
    (let ((count 0))
      (lambda ()
        (if (= count n)
            (eof-object)
            (let ((piece (inner)))
              (cond
                ((eof-object? piece) piece)
                ((not (bytevector? piece))
                 (assertion-violation 'res-body-stream "a piece is not a bytevector" piece))
                (else
                 (let ((next (+ count (bytevector-length piece))))
                   (when (> next n)
                     (assertion-violation 'res-body-stream
                                          "a piece takes the body past the length it had" n next))
                   (set! count next)
                   piece)))))))))
