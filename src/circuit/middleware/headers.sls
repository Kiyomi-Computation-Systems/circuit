#!r6rs
;;; (circuit middleware headers): fields every response should carry, and
;;; HSTS (the slice 9 design §4).
;;;
;;;   (import (rnrs) (circuit) (circuit middleware headers))
;;;   (wrap app (wrap-default-headers security-headers) (wrap-hsts 31536000))
;;;
;;; wrap-default-headers adds each field of its list that the handler's
;;; response lacks, by name in any case, after the handler's own: a handler
;;; that sets its own keeps it. The list is checked when it is given, each
;;; name a token and each value one the server can write, and copied, so a
;;; change to it after changes nothing. Content-Length, Transfer-Encoding
;;; and Connection are the server's to write, and it refuses a response
;;; that sets the first two, or any Connection but close, so the list may
;;; hold none of them.
;;;
;;; wrap-hsts sets Strict-Transport-Security on a response to an https
;;; request alone: RFC 6797 §7.2 says a host MUST NOT send it over plain
;;; HTTP. It reads req-scheme, so behind a proxy that ends TLS, a middleware
;;; outside it must believe the proxy first. preload is left out: the
;;; preload list has rules of its own, and joining it is hard to undo.
(library (circuit middleware headers)
  (export wrap-default-headers security-headers wrap-hsts hsts-include-subdomains)
  (import (rnrs)
          (only (circuit request) req-scheme)
          (only (circuit response) res? res-headers res-set-header res-add-header)
          (only (circuit headers) header-value))

  ;; HstsOption = what hsts-include-subdomains makes

  ;; security-headers : Headers
  ;; nosniff, so a browser takes the declared type, never a sniffed one;
  ;; SAMEORIGIN, so no other site frames the page; and
  ;; strict-origin-when-cross-origin, so another site sees the origin, never
  ;; the path.
  (define security-headers
    '(("x-content-type-options" . "nosniff")
      ("x-frame-options" . "SAMEORIGIN")
      ("referrer-policy" . "strict-origin-when-cross-origin")))

  ;; wrap-default-headers : Headers -> Middleware
  ;; Middleware that adds each field of DEFAULTS the handler's response
  ;; lacks, matched by name in any case, after the response's own, in the
  ;; list's order, each name in lower case. What is no header list, a name
  ;; that is no token or is one the server writes, content-length,
  ;; transfer-encoding or connection, or a value holding a control
  ;; character other than HTAB or a character past 255, is an assertion
  ;; violation, raised now, and so is a handler that is no procedure, when
  ;; the middleware is applied. An answer that is no response passes as it
  ;; is.
  (define (wrap-default-headers defaults)
    (let ((fields (checked-fields defaults)))
      (lambda (handler)
        (check-handler 'wrap-default-headers handler)
        (lambda (req)
          (let ((answer (handler req)))
            (if (res? answer)
                (let ((own (res-headers answer)))
                  (fold-left (lambda (res field)
                               (if (header-value own (car field))
                                   res
                                   (res-add-header res (car field) (cdr field))))
                             answer
                             fields))
                answer))))))

  ;; checked-fields : Any -> Headers
  ;; A copy of DEFAULTS, every pair and string fresh, once each field is
  ;; checked.
  (define (checked-fields defaults)
    (unless (list? defaults)
      (assertion-violation 'wrap-default-headers "a header list is a list of (name . value) string pairs"
                           defaults))
    (map (lambda (field)
           (unless (and (pair? field) (string? (car field)) (string? (cdr field)))
             (assertion-violation 'wrap-default-headers "a header field is a (name . value) pair of strings"
                                  field))
           (unless (token? (car field))
             (assertion-violation 'wrap-default-headers "a header name is a token" field))
           (when (exists (lambda (name) (string-ci=? name (car field)))
                         '("content-length" "transfer-encoding" "connection"))
             (assertion-violation 'wrap-default-headers
                                  "content-length, transfer-encoding and connection are the server's to write"
                                  field))
           (unless (field-text? (cdr field))
             (assertion-violation 'wrap-default-headers
                                  "a header value holds no control character but HTAB, and no character past 255"
                                  field))
           (cons (string-copy (car field)) (string-copy (cdr field))))
         defaults))

  ;; An option of wrap-hsts's, by the name of the constructor that made it.
  (define-record-type (hsts-option make-hsts-option hsts-option?)
    (fields name)
    (sealed #t)
    (opaque #t))

  ;; hsts-include-subdomains : -> HstsOption
  ;; includeSubDomains: every subdomain of the host is https only too.
  (define (hsts-include-subdomains)
    (make-hsts-option 'hsts-include-subdomains))

  ;; wrap-hsts : Nat HstsOption ... -> Middleware
  ;; Middleware that sets strict-transport-security, max-age=MAX-AGE, with
  ;; ; includeSubDomains for hsts-include-subdomains, on the response to an
  ;; https request, replacing the handler's; a response to any other passes
  ;; as it is. A max-age that is no count of seconds, an option that
  ;; hsts-include-subdomains didn't make, the constructor given bare, or an
  ;; option given twice, is an assertion violation, raised now, and so is a
  ;; handler that is no procedure, when the middleware is applied. An answer
  ;; that is no response passes as it is.
  (define (wrap-hsts max-age . options)
    (unless (and (integer? max-age) (exact? max-age) (>= max-age 0))
      (assertion-violation 'wrap-hsts "a max-age is a count of seconds" max-age))
    (for-each (lambda (x)
                (unless (hsts-option? x)
                  (if (eq? x hsts-include-subdomains)
                      (assertion-violation 'wrap-hsts "an option's constructor, given bare: call it"
                                           'hsts-include-subdomains)
                      (assertion-violation 'wrap-hsts "an option is what hsts-include-subdomains makes"
                                           x))))
              options)
    (when (and (pair? options) (pair? (cdr options)))
      (assertion-violation 'wrap-hsts "each option once" (hsts-option-name (cadr options))))
    (let ((value (string-append "max-age=" (number->string max-age)
                                (if (null? options) "" "; includeSubDomains"))))
      (lambda (handler)
        (check-handler 'wrap-hsts handler)
        (lambda (req)
          (let* ((https? (eq? (req-scheme req) 'https))
                 (answer (handler req)))
            (if (and https? (res? answer))
                (res-set-header answer "strict-transport-security" value)
                answer))))))

  (define (check-handler who handler)
    (unless (procedure? handler)
      (assertion-violation who "a handler is a procedure" handler)))

  ;; token? : String -> Boolean
  ;; 1*tchar (RFC 9110 §5.6.2).
  (define (token? s)
    (let ((n (string-length s)))
      (and (> n 0)
           (let loop ((i 0))
             (or (= i n)
                 (and (tchar? (string-ref s i)) (loop (+ i 1))))))))

  (define (tchar? c)
    (or (and (char<=? #\a c) (char<=? c #\z))
        (and (char<=? #\A c) (char<=? c #\Z))
        (and (char<=? #\0 c) (char<=? c #\9))
        (memv c '(#\! #\# #\$ #\% #\& #\' #\* #\+ #\- #\. #\^ #\_ #\` #\| #\~))))

  ;; field-text? : String -> Boolean
  ;; HTAB, SP, VCHAR and obs-text alone, as the server's serializer takes a
  ;; value, each character one byte as the adapter writes it.
  (define (field-text? s)
    (let ((n (string-length s)))
      (let loop ((i 0))
        (or (= i n)
            (let ((c (char->integer (string-ref s i))))
              (and (or (= c 9) (and (>= c 32) (<= c 255) (not (= c 127))))
                   (loop (+ i 1)))))))))
