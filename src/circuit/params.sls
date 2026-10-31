#!r6rs
;;; (circuit params): the query and an urlencoded form, as name and value
;;; pairs (the slice 9 design §5).
;;;
;;;   (import (rnrs) (circuit) (circuit params))
;;;   (param-value (req-query-params req) "q")
;;;   (wrap app (wrap-form-params 65536))
;;;
;;; Both are read by WHATWG URL's urlencoded parser (§5.1), the one a
;;; browser's URLSearchParams uses, which never fails: a % that starts no
;;; escape stays a %, and bytes that are no UTF-8 become U+FFFD, as the
;;; Encoding standard's decoder (§8.1.1) reads them. Chez's utf8->string
;;; reads some of them otherwise, so the decoder is circuit's own. A name is
;;; data, and matches in its case.
;;;
;;; req-query-params parses req-query each time it is asked, so a
;;; req-with-query is seen. A query's characters are its bytes: the server
;;; takes a target of printable ASCII alone, and answers any other 400, so
;;; a character from 128 to 255 reaches a query only through req-with-query
;;; or a test request, and is read as the byte it names.
;;;
;;; wrap-form-params reads the body of a request whose one content-type
;;; field is application/x-www-form-urlencoded, whole, before the handler,
;;; and keeps its pairs under a key of its own, which req-form-params reads.
;;; It reads under the smaller of its cap and the request's own, so it lifts
;;; no cap set outside it, and the server's cap holds under both. The body
;;; is read once: after it, req-body reads eof. So it goes inside every cap:
;;; a wrap-body-cap inside it finds the body's port made, req-with-body-cap's
;;; assertion violation, for every form. In a router, it goes in the group
;;; of the routes that take forms, inside that group's cap.
(library (circuit params)
  (export req-query-params wrap-form-params req-form-params param-value param-values
          parse-params params->string)
  (import (rnrs)
          (only (circuit request) req? req-query req-header-values req-body req-body-cap
                req-with-body-cap make-req-key req-ref req-set))

  ;; Params = (Listof (Pair String String))

  ;; req-query-params : Req -> Params
  ;; The query's pairs, in order, a name given twice kept twice; '() with no
  ;; query. A query holding a character past 255, which only code can put
  ;; there, is an assertion violation, and so is what is no request.
  (define (req-query-params req)
    (check-req 'req-query-params req)
    (let ((query (req-query req)))
      (if query (parse (query-bytes query)) '())))

  ;; query-bytes : String -> Bytevector — each character of QUERY its byte.
  (define (query-bytes query)
    (let* ((n (string-length query))
           (out (make-bytevector n)))
      (let loop ((i 0))
        (if (= i n)
            out
            (let ((c (char->integer (string-ref query i))))
              (unless (< c 256)
                (assertion-violation 'req-query-params
                                     "a query's characters are its bytes, each at most 255" query))
              (bytevector-u8-set! out i c)
              (loop (+ i 1)))))))

  ;; The key wrap-form-params keeps a form's pairs under.
  (define form-key (make-req-key 'form-params))

  ;; wrap-form-params : Nat -> Middleware
  ;; Middleware that reads a form's body before the handler, under the
  ;; smaller of CAP and the request's own cap, and hands the handler the
  ;; request with its pairs, which req-form-params reads, and that cap. A
  ;; form is a request with one content-type field, whose media type, in
  ;; any case, is application/x-www-form-urlencoded; its parameters,
  ;; charset among them, are ignored. Any other request passes untouched.
  ;; A body past the cap raises the server's &body-failed, 413, before the
  ;; handler runs. A form whose body's port was made outside it, or that
  ;; meets a cap inside it, is req-with-body-cap's assertion violation. A
  ;; cap that is no count of bytes is an assertion violation, raised now,
  ;; and so is a handler that is no procedure, when the middleware is
  ;; applied.
  (define (wrap-form-params cap)
    (unless (and (integer? cap) (exact? cap) (>= cap 0))
      (assertion-violation 'wrap-form-params "a cap is a count of bytes" cap))
    (lambda (handler)
      (unless (procedure? handler)
        (assertion-violation 'wrap-form-params "a handler is a procedure" handler))
      (lambda (req)
        (if (form? req)
            (let* ((own (req-body-cap req))
                   (capped (req-with-body-cap req (if (and own (< own cap)) own cap)))
                   (body (get-bytevector-all (req-body capped))))
              (handler (req-set capped form-key
                                (parse (if (eof-object? body) (make-bytevector 0) body)))))
            (handler req)))))

  ;; req-form-params : Req -> Params
  ;; The pairs wrap-form-params read from REQ's body, or '() when none did.
  ;; What is no request is an assertion violation.
  (define (req-form-params req)
    (check-req 'req-form-params req)
    (req-ref req form-key '()))

  ;; form? : Req -> Boolean
  (define (form? req)
    (let ((fields (req-header-values req "content-type")))
      (and (pair? fields)
           (null? (cdr fields))
           (ascii-ci=? (media-type (car fields)) "application/x-www-form-urlencoded"))))

  ;; media-type : String -> String
  ;; VALUE up to its first ;, without the SP and HTAB at either end.
  (define (media-type value)
    (let* ((n (string-length value))
           (end (let loop ((i 0)) (if (or (= i n) (char=? (string-ref value i) #\;)) i (loop (+ i 1))))))
      (let trim ((start 0) (end end))
        (cond ((and (< start end) (ows? (string-ref value start))) (trim (+ start 1) end))
              ((and (< start end) (ows? (string-ref value (- end 1)))) (trim start (- end 1)))
              (else (substring value start end))))))

  (define (ows? c) (or (char=? c #\space) (char=? c #\tab)))

  ;; ascii-ci=? : String String -> Boolean
  ;; Equal, an ASCII letter matching itself in either case.
  (define (ascii-ci=? a b)
    (let ((n (string-length a)))
      (and (= n (string-length b))
           (let loop ((i 0))
             (or (= i n)
                 (and (char=? (ascii-downcase (string-ref a i)) (ascii-downcase (string-ref b i)))
                      (loop (+ i 1))))))))

  (define (ascii-downcase c)
    (if (and (char<=? #\A c) (char<=? c #\Z)) (integer->char (+ (char->integer c) 32)) c))

  ;; param-value : Params String -> (U String #f)
  ;; The value of the first param named NAME, exactly, or #f.
  (define (param-value params name)
    (check-params 'param-value params)
    (check-name 'param-value name)
    (let ((hit (find (lambda (p) (string=? (car p) name)) params)))
      (and hit (cdr hit))))

  ;; param-values : Params String -> (Listof String)
  ;; The value of every param named NAME, exactly, in order; '() for none.
  (define (param-values params name)
    (check-params 'param-values params)
    (check-name 'param-values name)
    (map cdr (filter (lambda (p) (string=? (car p) name)) params)))

  ;; parse-params : Bytevector -> Params
  ;; BYTES by the urlencoded parser: split on &, empty pieces skipped; each
  ;; piece split at its first =, a piece with none a name with an empty
  ;; value; then each + a space, each escape its byte, and the bytes read
  ;; as UTF-8, without BOM, each error U+FFFD. What is no bytevector is an
  ;; assertion violation: a string's UTF-8 is (string->utf8 s).
  (define (parse-params bytes)
    (unless (bytevector? bytes)
      (assertion-violation 'parse-params
                           "a body or query to parse is a bytevector: give a string's UTF-8" bytes))
    (parse bytes))

  (define (parse bytes)
    (let ((n (bytevector-length bytes)))
      (let loop ((start 0) (out '()))
        (if (> start n)
            (reverse out)
            (let ((end (index-of bytes 38 start n)))
              (loop (+ end 1)
                    (if (= start end)
                        out
                        (let ((eq (index-of bytes 61 start end)))
                          (cons (cons (component bytes start eq)
                                      (component bytes (min (+ eq 1) end) end))
                                out)))))))))

  ;; index-of : Bytevector Byte Nat Nat -> Nat
  ;; The index of the first BYTE in [START, END), or END.
  (define (index-of bytes byte start end)
    (let loop ((i start))
      (cond ((= i end) i)
            ((= (bytevector-u8-ref bytes i) byte) i)
            (else (loop (+ i 1))))))

  ;; component : Bytevector Nat Nat -> String
  ;; The bytes in [START, END), each + a space, each escape its byte, read
  ;; as UTF-8.
  (define (component bytes start end)
    (let ((out (make-bytevector (- end start))))
      (let loop ((i start) (j 0))
        (if (= i end)
            (utf8-decode out j)
            (let ((b (bytevector-u8-ref bytes i)))
              (cond ((= b 43)
                     (bytevector-u8-set! out j 32)
                     (loop (+ i 1) (+ j 1)))
                    ((and (= b 37) (<= (+ i 3) end)
                          (hex-value (bytevector-u8-ref bytes (+ i 1)))
                          (hex-value (bytevector-u8-ref bytes (+ i 2))))
                     (bytevector-u8-set! out j (+ (* 16 (hex-value (bytevector-u8-ref bytes (+ i 1))))
                                                  (hex-value (bytevector-u8-ref bytes (+ i 2)))))
                     (loop (+ i 3) (+ j 1)))
                    (else
                     (bytevector-u8-set! out j b)
                     (loop (+ i 1) (+ j 1)))))))))

  ;; hex-value : Byte -> (U Nat #f) — an ASCII hex digit's value, or #f.
  (define (hex-value b)
    (cond ((and (>= b 48) (<= b 57)) (- b 48))
          ((and (>= b 65) (<= b 70)) (- b 55))
          ((and (>= b 97) (<= b 102)) (- b 87))
          (else #f)))

  ;; utf8-decode : Bytevector Nat -> String
  ;; The first N bytes of BYTES by the Encoding standard's UTF-8 decoder
  ;; (§8.1.1): each error U+FFFD, the byte that ends a sequence early read
  ;; again, a truncated sequence at the end one U+FFFD, and a BOM kept.
  (define (utf8-decode bytes n)
    (call-with-string-output-port
     (lambda (out)
       (let loop ((i 0))
         (when (< i n)
           (let* ((b (bytevector-u8-ref bytes i))
                  (needed (cond ((< b #x80) 0)
                                ((and (>= b #xC2) (<= b #xDF)) 1)
                                ((and (>= b #xE0) (<= b #xEF)) 2)
                                ((and (>= b #xF0) (<= b #xF4)) 3)
                                (else #f))))
             (cond ((not needed)
                    (put-char out #\xFFFD)
                    (loop (+ i 1)))
                   ((= needed 0)
                    (put-char out (integer->char b))
                    (loop (+ i 1)))
                   (else
                    (let trail ((j (+ i 1))
                                (seen 0)
                                (point (bitwise-and b (case needed ((1) #x1F) ((2) #x0F) (else #x07))))
                                (lower (case b ((#xE0) #xA0) ((#xF0) #x90) (else #x80)))
                                (upper (case b ((#xED) #x9F) ((#xF4) #x8F) (else #xBF))))
                      (cond ((= seen needed)
                             (put-char out (integer->char point))
                             (loop j))
                            ((= j n)
                             (put-char out #\xFFFD))
                            (else
                             (let ((c (bytevector-u8-ref bytes j)))
                               (if (and (>= c lower) (<= c upper))
                                   (trail (+ j 1) (+ seen 1)
                                          (bitwise-ior (bitwise-arithmetic-shift-left point 6)
                                                       (bitwise-and c #x3F))
                                          #x80 #xBF)
                                   (begin (put-char out #\xFFFD)
                                          (loop j)))))))))))))))

  ;; params->string : Params -> String
  ;; PARAMS by the urlencoded serializer (§5.2): each name and value as its
  ;; UTF-8, an ASCII letter or digit, *, -, . and _ kept, a space as +, and
  ;; every other byte %XX, in upper case; each name = value, joined by &.
  (define (params->string params)
    (check-params 'params->string params)
    (call-with-string-output-port
     (lambda (out)
       (let loop ((ps params) (first? #t))
         (unless (null? ps)
           (unless first? (put-char out #\&))
           (put-serialized out (caar ps))
           (put-char out #\=)
           (put-serialized out (cdar ps))
           (loop (cdr ps) #f))))))

  (define (put-serialized out s)
    (let ((bytes (string->utf8 s)))
      (let loop ((i 0))
        (when (< i (bytevector-length bytes))
          (let ((b (bytevector-u8-ref bytes i)))
            (cond ((or (and (>= b 97) (<= b 122)) (and (>= b 65) (<= b 90)) (and (>= b 48) (<= b 57))
                       (memv b '(42 45 46 95)))
                   (put-char out (integer->char b)))
                  ((= b 32) (put-char out #\+))
                  (else
                   (put-char out #\%)
                   (put-char out (string-ref "0123456789ABCDEF" (div b 16)))
                   (put-char out (string-ref "0123456789ABCDEF" (mod b 16))))))
          (loop (+ i 1))))))

  (define (check-req who req)
    (unless (req? req)
      (assertion-violation who "not a request" req)))

  (define (check-params who params)
    (unless (list? params)
      (assertion-violation who "a param list is a list of (name . value) string pairs" params))
    (for-each (lambda (p)
                (unless (and (pair? p) (string? (car p)) (string? (cdr p)))
                  (assertion-violation who "a param is a (name . value) pair of strings" p)))
              params))

  (define (check-name who name)
    (unless (string? name)
      (assertion-violation who "a param name is a string" name))))
