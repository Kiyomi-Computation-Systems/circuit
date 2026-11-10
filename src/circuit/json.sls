#!r6rs
;;; (circuit json): a request's JSON body, read as a value, and a JSON
;;; response.
;;;
;;;   (import (rnrs) (circuit) (circuit json))
;;;   (wrap app (wrap-json-body 65536))
;;;   (if (req-json? req) (req-json req) ...)
;;;   (make-json-res 200 '(("ok" . #t)))
;;;
;;; jsonparse's read-json reads the body 16 KiB at a time, and parses each
;;; 16 KiB, or the body's last bytes, once they are in: a read that waits
;;; parks the request's coroutine alone, and a body that is no JSON is
;;; refused once the 16 KiB holding its first bad byte is in. The value is
;;; what jsonparse builds: an object an alist, every
;;; duplicate kept, an array a vector, true and false #t and #f, and null
;;; the symbol null, unless the options say otherwise.
;;;
;;; wrap-json-body reads the body of a request whose one content-type field
;;; is application/json or application/<name>+json, in any case, its
;;; parameters ignored, before the handler, and keeps its value under a key
;;; of its own, which req-json reads. It reads under the smaller of its cap
;;; and the request's own, so it lifts no cap set outside it, and the
;;; server's cap holds under both. Any other request passes untouched, its
;;; body unread. An empty body is no JSON: the handler runs, and req-json?
;;; is #f. A body that is no JSON document is answered 400, text/plain,
;;; with jsonparse's reason and the byte it stopped at, and the handler never
;;; runs. The guard covers the parse alone, so a &json-error the handler
;;; raises, json-ref's among them, goes on as it was raised. A body past the
;;; cap raises the server's &body-failed at the read, 413, which it lets
;;; pass. The body is read once: it goes inside every cap, as
;;; wrap-form-params does.
;;;
;;; This library imports jsonparse's (jsonparse easy), through only, and no
;;; other library imports a (jsonparse ...) one: make check-imports holds it.
(library (circuit json)
  (export wrap-json-body req-json? req-json make-json-res)
  (import (rnrs)
          (only (circuit request) req? req-header-values req-body req-body-cap req-with-body-cap
                make-req-key req-ref req-set)
          (only (circuit response) make-res)
          (only (jsonparse easy) read-json json->bytevector json-error? json-error-reason
                json-error-offset json-options? make-json-options))

  ;; The key wrap-json-body keeps a body's value under, and what req-ref
  ;; answers when none is there: a pair no JSON value is.
  (define json-key (make-req-key 'json))
  (define none (list 'none))

  (define default-options (make-json-options))

  ;; wrap-json-body : Nat [json-options] -> Middleware
  ;; Middleware that reads a JSON request's body before the handler, under
  ;; the smaller of CAP and the request's own cap, by read-json under
  ;; OPTIONS, and hands the handler the request with its value, which
  ;; req-json reads, and that cap. A JSON request is one with one
  ;; content-type field, whose media type, in any case, is application/json
  ;; or application/<name>+json; its parameters are ignored. Any other
  ;; request passes untouched. An empty body passes with no value. A body
  ;; that is no JSON document is answered 400, text/plain, "REASON at byte
  ;; N", with no handler run. A body past the cap raises the server's
  ;; &body-failed, 413, before the handler runs. A JSON request whose body's
  ;; port was made outside it, or that meets a cap inside it, is
  ;; req-with-body-cap's assertion violation. A cap that is no count of
  ;; bytes, and options that are no json-options or that read-json refuses,
  ;; are an assertion violation, raised now, and so is a handler that is no
  ;; procedure, when the middleware is applied.
  (define wrap-json-body
    (case-lambda
      ((cap) (wrap-json-body cap default-options))
      ((cap options)
       (unless (and (integer? cap) (exact? cap) (>= cap 0))
         (assertion-violation 'wrap-json-body "a cap is a count of bytes" cap))
       (unless (json-options? options)
         (assertion-violation 'wrap-json-body "options are a record make-json-options made" options))
       (check-options options)
       (lambda (handler)
         (unless (procedure? handler)
           (assertion-violation 'wrap-json-body "a handler is a procedure" handler))
         (lambda (req)
           (if (json? req)
               (let* ((own (req-body-cap req))
                      (capped (req-with-body-cap req (if (and own (< own cap)) own cap)))
                      (port (req-body capped)))
                 (if (eof-object? (lookahead-u8 port))
                     (handler capped)
                     (let ((parsed (guard (e ((json-error? e) e))
                                     (list (read-json port options)))))
                       (if (pair? parsed)
                           (handler (req-set capped json-key (car parsed)))
                           (refuse parsed)))))
               (handler req)))))))

  ;; check-options : json-options -> Unit
  ;; Whatever read-json refuses OPTIONS for, a stream of many values among
  ;; it, refused now, as wrap-json-body's, not at the first request: read-json
  ;; is asked to read a 0 under them.
  (define (check-options options)
    (guard (e ((and (assertion-violation? e) (message-condition? e))
               (assertion-violation 'wrap-json-body
                                    (string-append "read-json refuses these options: " (condition-message e))
                                    options)))
      (read-json (open-bytevector-input-port (string->utf8 "0")) options)))

  ;; refuse : &json-error -> Res — the 400 for a body read-json refused.
  (define (refuse e)
    (make-res 400 '(("content-type" . "text/plain"))
              (string-append (symbol->string (json-error-reason e)) " at byte "
                             (number->string (json-error-offset e)) "\n")))

  ;; req-json? : Req -> Boolean
  ;; Whether wrap-json-body read a JSON value from REQ's body. What is no
  ;; request is an assertion violation.
  (define (req-json? req)
    (check-req 'req-json? req)
    (not (eq? (req-ref req json-key none) none)))

  ;; req-json : Req -> Any
  ;; The value wrap-json-body read from REQ's body: false is #f. A request
  ;; it read none from, and what is no request, are an assertion violation.
  (define (req-json req)
    (check-req 'req-json req)
    (let ((value (req-ref req json-key none)))
      (when (eq? value none)
        (assertion-violation 'req-json "no JSON was read from the request's body" req))
      value))

  ;; make-json-res : Integer Any [json-options] -> Res
  ;; A response of STATUS whose body is VALUE as JSON, by json->bytevector
  ;; under OPTIONS, with content-type application/json. A value JSON can't
  ;; express raises jsonparse's &json-error, here. Options that are no
  ;; json-options are an assertion violation, and so is what make-res
  ;; refuses.
  (define make-json-res
    (case-lambda
      ((status value) (make-json-res status value default-options))
      ((status value options)
       (unless (json-options? options)
         (assertion-violation 'make-json-res "options are a record make-json-options made" options))
       (make-res status '(("content-type" . "application/json")) (json->bytevector value options)))))

  ;; json? : Req -> Boolean
  (define (json? req)
    (let ((fields (req-header-values req "content-type")))
      (and (pair? fields)
           (null? (cdr fields))
           (json-media-type? (media-type (car fields))))))

  ;; json-media-type? : String -> Boolean
  ;; application/json, or application/NAME+json, NAME a restricted-name
  ;; (RFC 6838 §4.2), in any case.
  (define (json-media-type? type)
    (let ((n (string-length type))
          (prefix (string-length "application/")))
      (and (> n prefix)
           (ascii-ci=? (substring type 0 prefix) "application/")
           (let* ((subtype (substring type prefix n))
                  (m (string-length subtype)))
             (or (ascii-ci=? subtype "json")
                 (and (> m 5)
                      (ascii-ci=? (substring subtype (- m 5) m) "+json")
                      (restricted-name? (substring subtype 0 (- m 5)))))))))

  ;; restricted-name? : String -> Boolean
  ;; A letter or digit, then letters, digits and !#$&-^_.+ (RFC 6838 §4.2).
  (define (restricted-name? s)
    (let ((n (string-length s)))
      (and (> n 0)
           (alnum? (string-ref s 0))
           (let loop ((i 1))
             (or (= i n)
                 (and (let ((c (string-ref s i))) (or (alnum? c) (memv c '(#\! #\# #\$ #\& #\- #\^ #\_ #\. #\+))))
                      (loop (+ i 1))))))))

  (define (alnum? c)
    (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9)))

  ;; media-type : String -> String
  ;; VALUE up to its first ;, without the SP and HTAB before it. A field's
  ;; value has none at its start: the server and make-test-req trim them.
  (define (media-type value)
    (let* ((n (string-length value))
           (end (let loop ((i 0)) (if (or (= i n) (char=? (string-ref value i) #\;)) i (loop (+ i 1))))))
      (let trim ((end end))
        (if (and (> end 0) (ows? (string-ref value (- end 1))))
            (trim (- end 1))
            (substring value 0 end)))))

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

  (define (check-req who req)
    (unless (req? req)
      (assertion-violation who "not a request" req))))
