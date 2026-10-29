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
;;;   BinaryInputPort     read whole when its length is one piece or less,
;;;                       streamed otherwise, and closed once read
;;;   SizedBody           (make-sized-body n body): a producer or a port of
;;;                       n bytes, sent with that length
;;;   WrappedBody         (res-wrap-body res f): another body, its producer
;;;                       passed through f when it is sent, with no length
;;;   TappedBody          (res-tap-body res on-piece): another body, each
;;;                       piece handed to on-piece as it is sent, its
;;;                       length kept
;;;
;;; A body holds at most one port: bare, under a sized body, or under wraps
;;; and taps. res-with-body closes it when it replaces the body;
;;; res-wrap-body and res-tap-body close nothing, since both are lazy:
;;; res-body-stream, which the adapter and the tests send a body through, is
;;; the one place f is called, and on-piece is called only from the
;;; producer it makes for a tap, as the server or a wrap's f asks it.
;;;
;;; (make-upgrade-res headers take-over) is a 101 whose body is an upgrade:
;;; no bytes, but the take-over, which the adapter hands the server, and the
;;; server calls with its transport once the 101 is written (design §8). An
;;; upgrade body sits only in a 101 that make-upgrade-res made: make-res and
;;; res-with-body refuse one; res-with-body, res-with-status, res-wrap-body
;;; and res-tap-body refuse an upgrade response; res-set-header,
;;; res-add-header and res-remove-header keep it one. res-body-length and
;;; res-body-port answer #f for it, and res-body-stream refuses it: after
;;; the 101 the stream is the taker's. make-res with 101 and any other body is still a response, which
;;; the server answers 500. What a take-over answers goes to the server, so
;;; a middleware that wraps one answers what it answers (TakeOver, below).
;;;
;;; Also exported for the adapter and the tests, and left out of the
;;; (circuit) facade: the res-sized-body-, res-wrapped-body- and
;;; res-tapped-body- accessors,
;;; res-body-port and res-body-stream. res-upgrade-body-take-over is in the
;;; facade, so middleware can make an upgrade around a wrapped take-over.
(library (circuit response)
  (export make-res res? res-status res-headers res-body
          res-header res-set-header res-add-header res-remove-header res-with-status res-with-body
          make-sized-body res-sized-body? res-sized-body-length res-sized-body-inner
          res-wrap-body res-wrapped-body? res-wrapped-body-inner res-wrapped-body-proc
          res-tap-body res-tapped-body? res-tapped-body-inner res-tapped-body-proc
          make-upgrade-res res-upgrade-body? res-upgrade-body-take-over
          res-body-length res-body-port res-body-stream)
  (import (rnrs) (only (circuit headers) header-value header-set header-add header-remove))

  ;; Producer = (-> (U Bytevector Eof))
  ;; Body = (U #f Bytevector String Producer BinaryInputPort SizedBody WrappedBody
  ;;          TappedBody)
  ;; TakeOver = (Transport Bytevector -> Answer), Transport the server's, and
  ;;   Answer what goes back to the server, which may be awaiting. A
  ;;   middleware that wraps a take-over answers what the wrapped one
  ;;   answers: with that answer dropped, the 101 is written, and a
  ;;   WebSocket's procedure never runs (chez-websocket's ADR-0009)
  ;; UpgradeBody = the body of make-upgrade-res's 101, holding its TakeOver

  ;; res? : Any -> Boolean
  ;; res-status : Res -> Integer
  ;; res-headers : Res -> (Listof (Pair String String))
  ;; res-body : Res -> (U Body UpgradeBody)
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
  (define-record-type (wrapping %make-wrap res-wrapped-body?)
    (fields (immutable inner res-wrapped-body-inner)
            (immutable proc res-wrapped-body-proc))
    (sealed #t))

  ;; res-tapped-body? : Any -> Boolean
  ;; res-tapped-body-inner : TappedBody -> Body
  ;; res-tapped-body-proc : TappedBody -> (Bytevector -> Any)
  (define-record-type (tapping %make-tap res-tapped-body?)
    (fields (immutable inner res-tapped-body-inner)
            (immutable proc res-tapped-body-proc))
    (sealed #t))

  ;; res-upgrade-body? : Any -> Boolean
  ;; res-upgrade-body-take-over : UpgradeBody -> TakeOver
  (define-record-type (upgrade %make-upgrade res-upgrade-body?)
    (fields (immutable take-over res-upgrade-body-take-over))
    (sealed #t))

  ;; make-res : Integer Headers Body -> Res
  ;; A response. STATUS must be an exact integer, HEADERS a list, and BODY
  ;; a body kind, or it is an assertion violation; an upgrade body is
  ;; make-upgrade-res's alone. Nothing is rewritten.
  (define (make-res status headers body)
    (check-status 'make-res status)
    (check-headers 'make-res headers)
    (check-body 'make-res body)
    (%make-res status headers body))

  ;; make-upgrade-res : Headers TakeOver -> Res
  ;; A 101 with HEADERS, checked as make-res checks them, and an upgrade
  ;; body holding TAKE-OVER, which the server calls with its transport and
  ;; the bytes it read past the request once the 101 is written. A
  ;; TAKE-OVER that is no procedure is an assertion violation.
  (define (make-upgrade-res headers take-over)
    (check-headers 'make-upgrade-res headers)
    (unless (procedure? take-over)
      (assertion-violation 'make-upgrade-res
                           "a take-over is a procedure of a transport and the bytes read past the request"
                           take-over))
    (%make-res 101 headers (%make-upgrade take-over)))

  (define (check-headers who headers)
    (unless (list? headers)
      (assertion-violation who "headers are a list of (name . value) string pairs" headers)))

  (define (check-status who status)
    (unless (and (integer? status) (exact? status))
      (assertion-violation who "a status is an exact integer" status)))

  (define (check-res who r)
    (unless (res? r)
      (assertion-violation who "not a response" r)))

  ;; check-not-upgrade : Symbol Res -> Void
  ;; R, when it is an upgrade response, is an assertion violation: its
  ;; status and its body are make-upgrade-res's.
  (define (check-not-upgrade who r)
    (when (res-upgrade-body? (res-body r))
      (assertion-violation who "an upgrade response keeps the 101 and the body make-upgrade-res gave it" r)))

  (define (binary-input-port? x)
    (and (port? x) (input-port? x) (binary-port? x)))

  (define (body? x)
    (or (not x) (bytevector? x) (string? x) (procedure? x) (binary-input-port? x)
        (res-sized-body? x) (res-wrapped-body? x) (res-tapped-body? x)))

  (define (check-body who body)
    (unless (body? body)
      (if (res-upgrade-body? body)
          (assertion-violation who "an upgrade body sits only in the 101 make-upgrade-res makes" body)
          (assertion-violation who "not a body: #f, a bytevector, a string, a producer, a binary input port, a sized body, a wrapped body or a tapped body"
                               body))))

  (define (count? n) (and (integer? n) (exact? n) (>= n 0)))

  ;; --- helpers ------------------------------------------------------------------

  ;; res-header : Res String -> (U String #f)
  ;; The value of R's first field named NAME, in any case.
  (define (res-header r name)
    (check-res 'res-header r)
    (header-value (res-headers r) name))

  ;; res-set-header : Res String String -> Res
  ;; R with every field named NAME replaced by one, the name in lower case.
  ;; An upgrade response stays one, its take-over kept.
  (define (res-set-header r name value)
    (check-res 'res-set-header r)
    (%make-res (res-status r) (header-set (res-headers r) name value) (res-body r)))

  ;; res-add-header : Res String String -> Res
  ;; R with a field appended, the name in lower case. An upgrade response
  ;; stays one, its take-over kept.
  (define (res-add-header r name value)
    (check-res 'res-add-header r)
    (%make-res (res-status r) (header-add (res-headers r) name value) (res-body r)))

  ;; res-remove-header : Res String -> Res
  ;; R without any field named NAME, in any case, the rest in order. The
  ;; body is kept as it is, so it closes nothing, and an upgrade response
  ;; stays one, its take-over kept.
  (define (res-remove-header r name)
    (check-res 'res-remove-header r)
    (%make-res (res-status r) (header-remove (res-headers r) name) (res-body r)))

  ;; res-with-status : Res Integer -> Res
  ;; R with STATUS. A 1xx status is an assertion violation: the server sends
  ;; those itself, and refuses one from a handler. So is an upgrade
  ;; response, whose 101 is make-upgrade-res's.
  (define (res-with-status r status)
    (check-res 'res-with-status r)
    (check-not-upgrade 'res-with-status r)
    (check-status 'res-with-status status)
    (when (and (>= status 100) (<= status 199))
      (assertion-violation 'res-with-status "a 1xx status is the server's to send" status))
    (%make-res status (res-headers r) (res-body r)))

  ;; res-with-body : Res Body -> Res
  ;; R with BODY, checked as make-res checks it, so an upgrade body is an
  ;; assertion violation; so is an upgrade response R. Refused, it closes
  ;; nothing. The body is replaced outright, so the port the old body
  ;; holds, at any depth, is closed, unless BODY holds that same port:
  ;; (res-with-body r (make-sized-body n (res-body r))) keeps it open.
  (define (res-with-body r body)
    (check-res 'res-with-body r)
    (check-not-upgrade 'res-with-body r)
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

  ;; res-wrap-body : Res (Producer -> Producer) -> Res
  ;; R with its body wrapped: when the body is sent, F is handed the old
  ;; body as a producer, and the producer F gives back is sent. F may change
  ;; the bytes, so the body has no length, and goes out chunked. Wraps and
  ;; taps nest. It closes nothing and calls nothing. An upgrade response,
  ;; which has no body to send, is an assertion violation, and so is an F
  ;; that is no procedure.
  (define (res-wrap-body r f)
    (check-res 'res-wrap-body r)
    (check-not-upgrade 'res-wrap-body r)
    (unless (procedure? f)
      (assertion-violation 'res-wrap-body "a wrap's f is a procedure from producer to producer" f))
    (%make-res (res-status r) (res-headers r) (%make-wrap (res-body r) f)))

  ;; res-tap-body : Res (Bytevector -> Any) -> Res
  ;; R with its body tapped: when the body is sent, ON-PIECE is handed each
  ;; piece before it goes out, and the piece goes out as it is, so the body
  ;; keeps the old one's length. ON-PIECE must not change the piece, and
  ;; what it answers is dropped. It runs where the body's producer runs, so
  ;; it may wait. It is handed pieces alone, never the end: under a body
  ;; with a length, the server stops asking at it, so a total is reported
  ;; from req-on-done!. A piece that is no bytevector, an empty one, or one
  ;; past the length is an assertion violation, raised before ON-PIECE sees
  ;; it. A body that sends no bytes, an empty one, or one to a HEAD, a 204
  ;; or a 304, calls it never, unless a wrap over the tap reads the body:
  ;; a wrap's f runs before the head, and what it reads, it reads through
  ;; the tap. Wraps and taps nest. It closes nothing and calls nothing. An
  ;; upgrade response is an assertion violation, and so is an ON-PIECE that
  ;; is no procedure.
  (define (res-tap-body r on-piece)
    (check-res 'res-tap-body r)
    (check-not-upgrade 'res-tap-body r)
    (unless (procedure? on-piece)
      (assertion-violation 'res-tap-body "a tap's on-piece is a procedure of a piece" on-piece))
    (%make-res (res-status r) (res-headers r) (%make-tap (res-body r) on-piece)))

  ;; --- what a body holds ---------------------------------------------------------

  ;; res-body-length : Res -> (U Nat #f)
  ;; The length of R's body where the core can tell it: #f 0, a bytevector
  ;; its length, a string its UTF-8 length, a sized body its n, and a tap
  ;; the length of the body under it. Otherwise #f: a producer, a wrap, a
  ;; port, whose length is
  ;; Chez's for the adapter to read, and an upgrade, since a 101 carries no
  ;; Content-Length.
  (define (res-body-length r)
    (check-res 'res-body-length r)
    (body-length (res-body r)))

  (define (body-length body)
    (cond ((not body) 0)
          ((bytevector? body) (bytevector-length body))
          ((string? body) (utf8-length body))
          ((res-sized-body? body) (res-sized-body-length body))
          ((res-tapped-body? body) (body-length (res-tapped-body-inner body)))
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

  ;; res-body-port : (U Body UpgradeBody) -> (U BinaryInputPort #f)
  ;; The port BODY holds, bare, under a sized body or under wraps and taps,
  ;; or #f; #f
  ;; for an upgrade, which holds none. What is neither a body kind nor an
  ;; upgrade is an assertion violation.
  (define (res-body-port body)
    (unless (res-upgrade-body? body)
      (check-body 'res-body-port body))
    (body-port body))

  (define (body-port body)
    (cond ((binary-input-port? body) body)
          ((res-sized-body? body) (body-port (res-sized-body-inner body)))
          ((res-wrapped-body? body) (body-port (res-wrapped-body-inner body)))
          ((res-tapped-body? body) (body-port (res-tapped-body-inner body)))
          (else #f)))

  ;; --- sending a body ---------------------------------------------------------------

  ;; res-body-stream : Body (BinaryInputPort -> (U Nat #f)) (BinaryInputPort -> Any) Nat
  ;;                   -> (Values (U Bytevector Producer) (U Nat #f))
  ;; What sends BODY, and its length, or #f for none: a bytevector when its
  ;; bytes are whole, otherwise a producer. SIZE is the most a port's piece
  ;; holds. No producer answers an empty piece. An upgrade body is an
  ;; assertion violation: it has no bytes, and after the 101 the stream is
  ;; the taker's.
  ;;
  ;; #f answers #vu8(), a bytevector itself, a string its UTF-8, each with
  ;; its own length. A producer answers itself, with no length.
  ;;
  ;; A body that holds a port is first made the caller's, before any wrap's
  ;; f runs. A bare port, not under a sized body though it may be under
  ;; wraps and taps, is measured: MEASURE is called once with it, and answers its
  ;; length or #f. When that length is no more than SIZE, the port is read
  ;; whole, by one get-bytevector-n of it (none for 0), and closed: its bytes,
  ;; as many as the read gave, fewer when the port held fewer and never more,
  ;; are the body from then on, and ON-PORT is not called, since nothing is
  ;; left open. Otherwise ON-PORT is called once with the port, where the
  ;; adapter registers its close (design §9), and the port streams: in
  ;; pieces of at most SIZE, never past the length MEASURE gave, answering
  ;; eof, the port closed, at its eof, and closed as its last byte is read.
  ;; A port under a sized body is not measured, and always streams: ON-PORT,
  ;; then its producer, read as far as the sized body's n. If MEASURE, the
  ;; read or ON-PORT raises, or MEASURE answers no count, the port is
  ;; closed, the raise goes on, and no f runs. After ON-PORT the port is the
  ;; caller's to close: a raise from f closes nothing. A body that holds no
  ;; port calls neither.
  ;;
  ;; A sized body answers its inner body's producer, with length n. A wrap
  ;; answers f's producer, with no length: f is handed the body under it as
  ;; a producer, whole bytes as one piece, or eof at once when empty, that
  ;; stops at the length the body under it had, if any, raising at a piece
  ;; that would pass it. F's answer must be a procedure. A tap answers the
  ;; body under it as a producer, each piece handed to on-piece as it is
  ;; asked for, with that body's length; a piece that is no bytevector, an
  ;; empty one, or one past that length raises before on-piece sees it.
  (define (res-body-stream body measure on-port size)
    (when (res-upgrade-body? body)
      (assertion-violation 'res-body-stream "an upgrade has no body to send: after the 101, the stream is the taker's"
                           body))
    (check-body 'res-body-stream body)
    (unless (procedure? measure)
      (assertion-violation 'res-body-stream "the measure is a procedure from port to length" measure))
    (unless (procedure? on-port)
      (assertion-violation 'res-body-stream "on-port is a procedure of the port" on-port))
    (unless (and (count? size) (> size 0))
      (assertion-violation 'res-body-stream "a piece size is a positive count of bytes" size))
    (let-values (((port sized?) (port-place body)))
      (let ((got (cond ((not port) #f)
                       (sized? (closing-on-raise port (lambda () (on-port port))) #f)
                       (else (closing-on-raise port (lambda () (taken port measure on-port size)))))))
        (stream body got size))))

  ;; port-place : Body -> (Values (U BinaryInputPort #f) Boolean)
  ;; The port BODY holds, or #f, and whether a sized body holds it.
  (define (port-place body)
    (cond ((binary-input-port? body) (values body #f))
          ((res-sized-body? body)
           (let ((inner (res-sized-body-inner body)))
             (if (procedure? inner) (values #f #f) (values inner #t))))
          ((res-wrapped-body? body) (port-place (res-wrapped-body-inner body)))
          ((res-tapped-body? body) (port-place (res-tapped-body-inner body)))
          (else (values #f #f))))

  ;; taken : BinaryInputPort (BinaryInputPort -> (U Nat #f)) (BinaryInputPort -> Any) Nat
  ;;         -> (U Bytevector Nat #f)
  ;; A bare PORT made the caller's. Measured at SIZE or less, it is read
  ;; whole and closed, and its bytes answered; otherwise it is handed to
  ;; ON-PORT, and its length, or #f, answered.
  (define (taken port measure on-port size)
    (let ((n (measured port measure)))
      (if (and n (<= n size))
          (let ((bytes (if (= n 0) #vu8() (get-bytevector-n port n))))
            (close-port port)
            (if (eof-object? bytes) #vu8() bytes))
          (begin (on-port port) n))))

  (define (measured port measure)
    (let ((n (measure port)))
      (unless (or (not n) (count? n))
        (assertion-violation 'res-body-stream "a port's measure answered no count of bytes" n))
      n))

  ;; closing-on-raise : BinaryInputPort (-> Any) -> Any
  ;; THUNK's answer; if it raises, PORT is closed and the raise goes on. The
  ;; handler closes the port where the raise is, and raises on from there:
  ;; with-exception-handler costs less than guard, which unwinds first.
  (define (closing-on-raise port thunk)
    (with-exception-handler
     (lambda (e) (close-port port) (raise e))
     thunk))

  ;; stream : Body (U Bytevector Nat #f) Nat -> (Values (U Bytevector Producer) (U Nat #f))
  ;; As res-body-stream, a bare port taken already: GOT is its bytes, read
  ;; whole, or its length, or #f.
  (define (stream body got size)
    (cond
      ((not body) (values #vu8() 0))
      ((bytevector? body) (values body (bytevector-length body)))
      ((string? body) (let ((bytes (string->utf8 body))) (values bytes (bytevector-length bytes))))
      ((procedure? body) (values body #f))
      ((binary-input-port? body)
       (if (bytevector? got)
           (values got (bytevector-length got))
           (values (port-producer body got size) got)))
      ((res-sized-body? body)
       (let ((length (res-sized-body-length body))
             (inner (res-sized-body-inner body)))
         (values (if (procedure? inner) inner (port-producer inner length size)) length)))
      ((res-wrapped-body? body)
       (let-values (((inner length) (stream (res-wrapped-body-inner body) got size)))
         (let* ((producer (if (bytevector? inner) (bytes-producer inner) inner))
                (handed (if length (counting-producer producer length) producer))
                (out ((res-wrapped-body-proc body) handed)))
           (unless (procedure? out)
             (assertion-violation 'res-body-stream "a wrap's f answered no producer" out))
           (values out #f))))
      (else
       (let-values (((inner length) (stream (res-tapped-body-inner body) got size)))
         (values (tap-producer (if (bytevector? inner) (bytes-producer inner) inner)
                               (res-tapped-body-proc body)
                               length)
                 length)))))

  ;; bytes-producer : Bytevector -> Producer
  ;; BYTES as one piece, then eof; eof at once when BYTES is empty.
  (define (bytes-producer bytes)
    (if (= (bytevector-length bytes) 0)
        (lambda () (eof-object))
        (let ((sent? #f))
          (lambda ()
            (if sent?
                (eof-object)
                (begin (set! sent? #t) bytes))))))

  ;; tap-producer : Producer (Bytevector -> Any) (U Nat #f) -> Producer
  ;; INNER, each piece handed to ON-PIECE before it is answered. A piece
  ;; that is no bytevector, an empty one, or one that would take the count
  ;; past N, when there is an N, is an assertion violation, raised before
  ;; ON-PIECE sees it, since none of them would go out; the last names N
  ;; and that count. The eof object is answered as it comes, and handed to
  ;; nothing.
  (define (tap-producer inner on-piece n)
    (let ((count 0))
      (lambda ()
        (let ((piece (inner)))
          (unless (eof-object? piece)
            (unless (and (bytevector? piece) (> (bytevector-length piece) 0))
              (assertion-violation 'res-body-stream "a piece is a bytevector of one byte or more" piece))
            (let ((next (+ count (bytevector-length piece))))
              (when (and n (> next n))
                (assertion-violation 'res-body-stream
                                     "a piece takes the body past the length it had" n next))
              (set! count next))
            (on-piece piece))
          piece))))

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
