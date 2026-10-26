#!r6rs
;;; (circuit headers): helpers over a header list, as requests and responses
;;; carry one.
;;;
;;; A header list is a list of (name . value) pairs of strings, in the order
;;; they go on the wire, duplicates kept (set-cookie). A lookup matches a
;;; name in any ASCII case, as the server's do: names are tokens, ASCII by
;;; RFC 9110, so A-Z fold to a-z and nothing else does. The helpers that
;;; write a name write it in that lower case. None changes the list it is
;;; given: each answers a new one, sharing what it can of the old. Each
;;; checks its whole list first, and refuses what is not a header list with
;;; an assertion violation.
(library (circuit headers)
  (export header-value header-values header-set header-add header-remove
          header-names-downcase)
  (import (rnrs) (rnrs mutable-strings))

  ;; Headers = (Listof (Pair String String))

  ;; header-value : Headers String -> (U String #f)
  ;; The value of the first field named NAME, in any case, or #f when none
  ;; is.
  (define (header-value headers name)
    (check-headers 'header-value headers)
    (check-name 'header-value name)
    (let loop ((fields headers))
      (cond ((null? fields) #f)
            ((name=? (caar fields) name) (cdar fields))
            (else (loop (cdr fields))))))

  ;; header-values : Headers String -> (Listof String)
  ;; The value of every field named NAME, in any case, in order; '() when
  ;; none is.
  (define (header-values headers name)
    (check-headers 'header-values headers)
    (check-name 'header-values name)
    (let loop ((fields headers))
      (cond ((null? fields) '())
            ((name=? (caar fields) name) (cons (cdar fields) (loop (cdr fields))))
            (else (loop (cdr fields))))))

  ;; header-set : Headers String String -> Headers
  ;; HEADERS with every field named NAME, in any case, replaced by one field,
  ;; NAME in lower case and VALUE, where the first of them stood; appended
  ;; when there is none.
  (define (header-set headers name value)
    (check-headers 'header-set headers)
    (check-name 'header-set name)
    (check-value 'header-set value)
    (let ((field (cons (downcase name) value)))
      (let loop ((fields headers) (placed? #f))
        (cond ((null? fields) (if placed? '() (list field)))
              ((name=? (caar fields) name)
               (if placed?
                   (loop (cdr fields) #t)
                   (cons field (loop (cdr fields) #t))))
              (else (cons (car fields) (loop (cdr fields) placed?)))))))

  ;; header-add : Headers String String -> Headers
  ;; HEADERS with a field appended: NAME in lower case, and VALUE. The fields
  ;; already named NAME stay.
  (define (header-add headers name value)
    (check-headers 'header-add headers)
    (check-name 'header-add name)
    (check-value 'header-add value)
    (append headers (list (cons (downcase name) value))))

  ;; header-remove : Headers String -> Headers
  ;; HEADERS without the fields named NAME, in any case, the rest in order.
  (define (header-remove headers name)
    (check-headers 'header-remove headers)
    (check-name 'header-remove name)
    (remp (lambda (field) (name=? (car field) name)) headers))

  ;; header-names-downcase : Headers -> Headers
  ;; HEADERS with each name in lower case, in order, duplicates kept. When
  ;; every name is in lower case already it answers HEADERS itself, so a
  ;; list that needs nothing costs nothing.
  (define (header-names-downcase headers)
    (check-headers 'header-names-downcase headers)
    (if (names-lower-case? headers)
        headers
        (map (lambda (field)
               (if (lower-case? (car field))
                   field
                   (cons (downcase (car field)) (cdr field))))
             headers)))

  ;; --- ASCII case -------------------------------------------------------------

  (define (upper? c) (and (char<=? #\A c) (char<=? c #\Z)))

  (define (fold-char c)
    (if (upper? c) (integer->char (+ (char->integer c) 32)) c))

  ;; name=? : String String -> Boolean
  ;; Equal once A-Z are folded to a-z, as the server compares names.
  (define (name=? a b)
    (let ((n (string-length a)))
      (and (= n (string-length b))
           (let loop ((i 0))
             (or (= i n)
                 (and (char=? (fold-char (string-ref a i)) (fold-char (string-ref b i)))
                      (loop (+ i 1))))))))

  (define (names-lower-case? fields)
    (or (null? fields)
        (and (lower-case? (caar fields)) (names-lower-case? (cdr fields)))))

  (define (lower-case? s)
    (let ((n (string-length s)))
      (let loop ((i 0))
        (or (= i n)
            (and (not (upper? (string-ref s i))) (loop (+ i 1)))))))

  ;; downcase : String -> String
  ;; S with A-Z folded to a-z; S itself when it has none.
  (define (downcase s)
    (if (lower-case? s)
        s
        (let* ((n (string-length s))
               (out (string-copy s)))
          (let loop ((i 0))
            (if (= i n)
                out
                (begin
                  (string-set! out i (fold-char (string-ref s i)))
                  (loop (+ i 1))))))))

  ;; --- checks -------------------------------------------------------------------

  ;; A loop, not for-each over a lambda: req-headers runs this on every
  ;; call, and a closure over WHO would allocate.
  (define (check-headers who headers)
    (unless (list? headers)
      (assertion-violation who "a header list is a list of (name . value) string pairs"
                           headers))
    (let loop ((fields headers))
      (unless (null? fields)
        (let ((field (car fields)))
          (unless (and (pair? field) (string? (car field)) (string? (cdr field)))
            (assertion-violation who "a header field is a (name . value) pair of strings"
                                 field)))
        (loop (cdr fields)))))

  (define (check-name who name)
    (unless (string? name)
      (assertion-violation who "a header name is a string" name)))

  (define (check-value who value)
    (unless (string? value)
      (assertion-violation who "a header value is a string" value))))
