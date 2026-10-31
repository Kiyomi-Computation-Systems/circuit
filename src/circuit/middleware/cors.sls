#!r6rs
;;; (circuit middleware cors): CORS, for a browser's script on another
;;; origin (the slice 9 design §3).
;;;
;;;   (import (rnrs) (circuit) (circuit middleware cors))
;;;   (wrap router
;;;         wrap-catch
;;;         (wrap-cors (cors-origins "https://app.example")
;;;                    (cors-methods 'PUT 'DELETE)
;;;                    (cors-headers "content-type"))
;;;         wrap-log)
;;;
;;; wrap-cors takes options, each made by a constructor here and given at
;;; most once: exactly one of cors-origins, cors-origin-when and
;;; cors-any-origin, and any of the rest. Each checks its setting, and
;;; wrap-cors checks them together, when it is called, never at a request.
;;;
;;; A request's Origin matches when it is one field that the origin option
;;; allows: one of the listed origins, exactly; one the predicate takes,
;;; asked only about an origin as a browser writes one; or, for
;;; cors-any-origin, any. A preflight is an OPTIONS whose Origin matches,
;;; with one Access-Control-Request-Method field (Fetch §3.3.2). wrap-cors
;;; answers it itself, 204, and never calls the handler. It checks neither
;;; the method nor the headers asked for: the browser does, against the
;;; lists the answer gives. Any other request goes to the handler, and
;;; wrap-cors sets its fields on the response: on a match, or on every
;;; response for cors-any-origin, whose *, the same for every request,
;;; needs no Vary. With an origin list or a predicate, the answer depends on
;;; the Origin, so every response it passes varies on it.
;;;
;;; An origin is what HTML's "serialization of an origin" writes:
;;; scheme://host or scheme://host:port, the scheme and the host in lower
;;; case, with no path, no trailing /, and no port that is the scheme's
;;; default. An IP address is written as URL's serializers write one. null
;;; is never one: any page can make a request from it, and a browser sends
;;; it for a file:, data:, about:, javascript: or blob: page.
;;;
;;; CORS decides which pages may read an answer, not which may send a
;;; request: a GET or a form's POST from any page reaches the handler, with
;;; its cookies. It is no defence against CSRF.
;;;
;;; It goes outside the router, whose group middleware sees only the
;;; requests a route takes, never another's preflight; outside wrap-catch
;;; and wrap-timeout, so their 500 and 504 carry the fields; and inside
;;; wrap-log, which then logs the preflights it answers.
(library (circuit middleware cors)
  (export wrap-cors cors-origins cors-origin-when cors-any-origin cors-methods cors-headers
          cors-any-header cors-expose-headers cors-credentials cors-max-age)
  (import (rnrs)
          (only (circuit request) req-method req-header-values)
          (only (circuit response) make-res res? res-headers res-set-header res-add-header)
          (only (circuit headers) header-values))

  ;; CorsOption = what a cors- constructor makes

  ;; An option: the setting it fills, the name of the constructor that made
  ;; it, and its value.
  (define-record-type (option make-option option?)
    (fields slot name value)
    (sealed #t)
    (opaque #t))

  ;; --- the constructors -------------------------------------------------------------

  ;; cors-origins : String String ... -> CorsOption
  ;; Each origin a request may come from, exactly as a browser writes it:
  ;; scheme://host or scheme://host:port. Anything else, "null" among them,
  ;; is an assertion violation. Each is copied, so a change to it after
  ;; changes nothing.
  (define (cors-origins origin . origins)
    (let ((copies (map (lambda (o)
                         (unless (string? o)
                           (assertion-violation 'cors-origins "an origin is a string" o))
                         (string-copy o))
                       (cons origin origins))))
      (for-each check-origin copies)
      (make-option 'origin 'cors-origins copies)))

  ;; check-origin : String -> Void
  ;; O, unless it is an origin a browser writes, is an assertion violation.
  (define (check-origin o)
    (when (string=? o "null")
      (assertion-violation
       'cors-origins
       (string-append "null is never an origin wrap-cors allows: a sandboxed iframe,"
                      " a file: page and some redirects send it, and any page can make"
                      " one; cors-any-origin allows every origin")
       o))
    (unless (origin-text? o)
      (assertion-violation
       'cors-origins
       (string-append "an origin is scheme://host or scheme://host:port, as a browser"
                      " writes it: in lower case, with no path, no trailing /, and no"
                      " default port")
       o)))

  ;; cors-origin-when : (String -> Any) -> CorsOption
  ;; The origins ALLOWED? answers true for. It is asked only about an
  ;; Origin a browser could send, never null. One that is no procedure is
  ;; an assertion violation.
  (define (cors-origin-when allowed?)
    (unless (procedure? allowed?)
      (assertion-violation 'cors-origin-when "a predicate is a procedure of an origin" allowed?))
    (make-option 'origin 'cors-origin-when allowed?))

  ;; cors-any-origin : -> CorsOption
  ;; Every origin: * on every response.
  (define (cors-any-origin)
    (make-option 'origin 'cors-any-origin #t))

  ;; cors-methods : Symbol Symbol ... -> CorsOption
  ;; The methods a preflight's answer allows, written as given: a method is
  ;; case-sensitive. A method that is no symbol, or whose name is no token,
  ;; is an assertion violation.
  (define (cors-methods method . methods)
    (for-each (lambda (m)
                (unless (and (symbol? m) (token? (symbol->string m)))
                  (assertion-violation 'cors-methods "a method is a symbol whose name is a token" m)))
              (cons method methods))
    (make-option 'methods 'cors-methods (map symbol->string (cons method methods))))

  ;; cors-headers : String String ... -> CorsOption
  ;; The request headers a preflight's answer allows, written in lower case.
  ;; A name that is no token is an assertion violation.
  (define (cors-headers name . names)
    (make-option 'headers 'cors-headers (field-names 'cors-headers (cons name names))))

  ;; cors-any-header : -> CorsOption
  ;; The request headers the preflight asks for, echoed.
  (define (cors-any-header)
    (make-option 'headers 'cors-any-header 'echo))

  ;; cors-expose-headers : String String ... -> CorsOption
  ;; The response headers a script may read beyond the safelisted ones,
  ;; written in lower case. A name that is no token is an assertion
  ;; violation.
  (define (cors-expose-headers name . names)
    (make-option 'expose 'cors-expose-headers (field-names 'cors-expose-headers (cons name names))))

  ;; cors-credentials : -> CorsOption
  ;; Access-Control-Allow-Credentials: true, so a script may read the
  ;; answer to a request sent with cookies, and a preflight's answer lets
  ;; one go. Refused with cors-any-origin, and with a * in a list.
  (define (cors-credentials)
    (make-option 'credentials 'cors-credentials #t))

  ;; cors-max-age : Nat -> CorsOption
  ;; How many seconds a browser may keep a preflight's answer. One that is
  ;; no count is an assertion violation.
  (define (cors-max-age seconds)
    (unless (and (integer? seconds) (exact? seconds) (>= seconds 0))
      (assertion-violation 'cors-max-age "a max-age is a count of seconds" seconds))
    (make-option 'max-age 'cors-max-age (number->string seconds)))

  (define (field-names who names)
    (map (lambda (n)
           (unless (and (string? n) (token? n))
             (assertion-violation who "a header name is a string that is a token" n))
           (downcase n))
         names))

  (define (joined strings)
    (fold-left (lambda (out s) (string-append out ", " s)) (car strings) (cdr strings)))

  ;; constructor-name : Any -> (U Symbol #f)
  ;; The name of the constructor X is, or #f.
  (define (constructor-name x)
    (cond ((eq? x cors-origins) 'cors-origins)
          ((eq? x cors-origin-when) 'cors-origin-when)
          ((eq? x cors-any-origin) 'cors-any-origin)
          ((eq? x cors-methods) 'cors-methods)
          ((eq? x cors-headers) 'cors-headers)
          ((eq? x cors-any-header) 'cors-any-header)
          ((eq? x cors-expose-headers) 'cors-expose-headers)
          ((eq? x cors-credentials) 'cors-credentials)
          ((eq? x cors-max-age) 'cors-max-age)
          (else #f)))

  ;; --- wrap-cors ------------------------------------------------------------------------

  ;; settings : (Listof Any) -> (Listof (Pair Symbol Option))
  ;; OPTIONS by the slot each fills. What no constructor made, a
  ;; constructor given bare, two options for one slot, no origin option,
  ;; or credentials with * as the origin or in a list, is an assertion
  ;; violation: under credentials, Fetch reads a * in a list as a name.
  (define (settings options)
    (for-each (lambda (x)
                (unless (option? x)
                  (let ((name (constructor-name x)))
                    (if name
                        (assertion-violation 'wrap-cors
                                             "an option's constructor, given bare: call it"
                                             name)
                        (assertion-violation 'wrap-cors
                                             "an option is what a cors- constructor makes"
                                             x)))))
              options)
    (let ((by-slot
           (fold-left (lambda (by-slot x)
                        (when (assq (option-slot x) by-slot)
                          (assertion-violation
                           'wrap-cors
                           (case (option-slot x)
                             ((origin) "one origin option: cors-origins, cors-origin-when or cors-any-origin")
                             ((headers) "one of cors-headers and cors-any-header")
                             (else "each option once"))
                           (option-name x)))
                        (cons (cons (option-slot x) x) by-slot))
                      '()
                      options)))
      (unless (assq 'origin by-slot)
        (assertion-violation 'wrap-cors
                             "an origin option: cors-origins, cors-origin-when or cors-any-origin"))
      (when (and (assq 'credentials by-slot)
                 (eq? (option-name (cdr (assq 'origin by-slot))) 'cors-any-origin))
        (assertion-violation 'wrap-cors
                             "a credentialed response is never shared under *: list the origins"
                             'cors-credentials 'cors-any-origin))
      (when (assq 'credentials by-slot)
        (for-each (lambda (slot)
                    (let ((o (assq slot by-slot)))
                      (when (and o (list? (option-value (cdr o))) (member "*" (option-value (cdr o))))
                        (assertion-violation
                         'wrap-cors
                         "under credentials, a browser reads * in a list as a name, not as every one: list them"
                         'cors-credentials (option-name (cdr o))))))
                  '(methods headers expose)))
      by-slot))

  ;; wrap-cors : CorsOption ... -> Middleware
  ;; Middleware that answers a preflight from an allowed origin itself, 204,
  ;; and sets the CORS fields on the handler's response to any other
  ;; request: the origin, or * for cors-any-origin, credentials and the
  ;; expose list, each replacing the handler's of its name, then Vary:
  ;; origin unless the response varies on it already, for an origin list or
  ;; a predicate. Bad options are an assertion violation, raised now, and so
  ;; is a handler that is no procedure, when the middleware is applied. An
  ;; answer that is no response passes as it is.
  (define (wrap-cors . options)
    (let* ((by-slot (settings options))
           (setting (lambda (slot) (let ((o (assq slot by-slot))) (and o (option-value (cdr o))))))
           (origin-option (cdr (assq 'origin by-slot)))
           (any? (eq? (option-name origin-option) 'cors-any-origin))
           (allows? (case (option-name origin-option)
                      ((cors-any-origin) (lambda (o) #t))
                      ((cors-origins)
                       (let ((listed (option-value origin-option)))
                         (lambda (o) (and (member o listed) #t))))
                      (else
                       (let ((allowed? (option-value origin-option)))
                         (lambda (o) (and (origin-text? o) (allowed? o) #t))))))
           (credentials? (setting 'credentials))
           (methods (let ((names (setting 'methods))) (and names (joined names))))
           (headers (let ((names (setting 'headers))) (if (pair? names) (joined names) names)))
           (expose (let ((names (setting 'expose))) (and names (joined names))))
           (max-age (setting 'max-age))
           (vary (cond ((and any? (eq? headers 'echo)) "access-control-request-headers")
                       (any? #f)
                       ((eq? headers 'echo) "origin, access-control-request-headers")
                       (else "origin"))))

      ;; preflight-answer : Req String -> Res
      (define (preflight-answer req origin)
        (let* ((allowed (if (eq? headers 'echo) (echoed req) headers))
               (fields (append
                        (list (cons "access-control-allow-origin" (if any? "*" origin)))
                        (if credentials? (list (cons "access-control-allow-credentials" "true")) '())
                        (if methods (list (cons "access-control-allow-methods" methods)) '())
                        (if allowed (list (cons "access-control-allow-headers" allowed)) '())
                        (if max-age (list (cons "access-control-max-age" max-age)) '())
                        (if vary (list (cons "vary" vary)) '()))))
          (make-res 204 fields #f)))

      ;; with-fields : Res (U String #f) -> Res
      ;; RES with the fields for a request whose matching Origin is ORIGIN,
      ;; #f when none matched.
      (define (with-fields res origin)
        (cond (any?
               (let ((res (res-set-header res "access-control-allow-origin" "*")))
                 (if expose (res-set-header res "access-control-expose-headers" expose) res)))
              (else
               (let* ((res (if origin (res-set-header res "access-control-allow-origin" origin) res))
                      (res (if (and origin credentials?)
                               (res-set-header res "access-control-allow-credentials" "true")
                               res))
                      (res (if (and origin expose)
                               (res-set-header res "access-control-expose-headers" expose)
                               res)))
                 (if (varies-on-origin? (res-headers res))
                     res
                     (res-add-header res "vary" "origin"))))))

      (lambda (handler)
        (unless (procedure? handler)
          (assertion-violation 'wrap-cors "a handler is a procedure" handler))
        (lambda (req)
          (let* ((origin (single-field req "origin"))
                 (match (and origin (allows? origin) origin)))
            (if (and match (preflight? req))
                (preflight-answer req match)
                (let ((answer (handler req)))
                  (if (res? answer) (with-fields answer match) answer))))))))

  ;; single-field : Req String -> (U String #f)
  ;; The value of REQ's field NAME when it has exactly one, else #f.
  (define (single-field req name)
    (let ((values (req-header-values req name)))
      (and (pair? values) (null? (cdr values)) (car values))))

  ;; preflight? : Req -> Boolean
  ;; An OPTIONS with one Access-Control-Request-Method field.
  (define (preflight? req)
    (and (eq? (req-method req) 'OPTIONS)
         (single-field req "access-control-request-method")
         #t))

  ;; echoed : Req -> (U String #f)
  ;; REQ's Access-Control-Request-Headers, when it is one field holding a
  ;; comma-separated list of tokens, else #f.
  (define (echoed req)
    (let ((names (single-field req "access-control-request-headers")))
      (and names
           (for-all token? (map trimmed (comma-split names)))
           names)))

  ;; varies-on-origin? : Headers -> Boolean
  ;; Whether one of HEADERS' vary fields lists origin, in any case, or *.
  (define (varies-on-origin? headers)
    (exists (lambda (value)
              (exists (lambda (element)
                        (let ((e (trimmed element)))
                          (or (string=? e "*") (string=? (downcase e) "origin"))))
                      (comma-split value)))
            (header-values headers "vary")))

  ;; --- text ---------------------------------------------------------------------------

  (define (comma-split s) (split s #\,))

  ;; trimmed : String -> String
  ;; S without the SP and HTAB at either end.
  (define (trimmed s)
    (let* ((n (string-length s))
           (start (let loop ((i 0)) (if (and (< i n) (blank? (string-ref s i))) (loop (+ i 1)) i)))
           (end (let loop ((i n)) (if (and (> i start) (blank? (string-ref s (- i 1)))) (loop (- i 1)) i))))
      (substring s start end)))

  (define (blank? c) (or (char=? c #\space) (char=? c #\tab)))

  ;; token? : String -> Boolean
  ;; 1*tchar (RFC 9110 §5.6.2).
  (define (token? s)
    (let ((n (string-length s)))
      (and (> n 0)
           (let loop ((i 0))
             (or (= i n)
                 (and (tchar? (string-ref s i)) (loop (+ i 1))))))))

  (define (tchar? c)
    (or (lower? c) (upper? c) (digit? c)
        (memv c '(#\! #\# #\$ #\% #\& #\' #\* #\+ #\- #\. #\^ #\_ #\` #\| #\~))))

  (define (lower? c) (and (char<=? #\a c) (char<=? c #\z)))
  (define (upper? c) (and (char<=? #\A c) (char<=? c #\Z)))
  (define (digit? c) (and (char<=? #\0 c) (char<=? c #\9)))
  (define (hex? c) (or (digit? c) (and (char<=? #\a c) (char<=? c #\f))))

  ;; downcase : String -> String
  ;; S with A-Z folded to a-z, and nothing else.
  (define (downcase s)
    (list->string (map (lambda (c) (if (upper? c) (integer->char (+ (char->integer c) 32)) c))
                       (string->list s))))

  ;; --- origins ------------------------------------------------------------------------

  ;; The ports URL's special schemes leave out of an origin.
  (define default-ports '(("http" . 80) ("https" . 443) ("ws" . 80) ("wss" . 443) ("ftp" . 21)))

  ;; The schemes whose pages a browser always sends as null.
  (define opaque-schemes '("file" "data" "about" "javascript" "blob"))

  ;; origin-text? : String -> Boolean
  ;; Whether S is an origin as a browser writes one: a scheme, a lower-case
  ;; letter then lower-case letters, digits, +, - and ., but none of
  ;; opaque-schemes; ://; a host; and perhaps : and a port, 1 to 65535 with
  ;; no leading 0, that isn't the scheme's default. A host is an IPv6
  ;; address in brackets, as URL's IPv6 serializer writes it; an IPv4
  ;; address, as its IPv4 serializer writes it, when its last label is a
  ;; number, as URL's "ends in a number" reads one; or else lower-case
  ;; letters, digits, -, . and _.
  (define (origin-text? s)
    (let* ((n (string-length s))
           (colon (scheme-end s n)))
      (and colon
           (not (member (substring s 0 colon) opaque-schemes))
           (<= (+ colon 3) n)
           (char=? (string-ref s (+ colon 1)) #\/)
           (char=? (string-ref s (+ colon 2)) #\/)
           (let ((end (host-end s (+ colon 3) n)))
             (and end
                  (or (= end n)
                      (and (char=? (string-ref s end) #\:)
                           (port-text? (substring s 0 colon) s (+ end 1) n))))))))

  ;; scheme-end : String Nat -> (U Nat #f)
  ;; Where the scheme at S's start ends, at a :, or #f.
  (define (scheme-end s n)
    (and (> n 0)
         (lower? (string-ref s 0))
         (let loop ((i 1))
           (cond ((= i n) #f)
                 ((char=? (string-ref s i) #\:) i)
                 ((let ((c (string-ref s i))) (or (lower? c) (digit? c) (memv c '(#\+ #\- #\.))))
                  (loop (+ i 1)))
                 (else #f)))))

  ;; host-end : String Nat Nat -> (U Nat #f)
  ;; Where the host from START ends, or #f when there is none there.
  (define (host-end s start n)
    (cond ((= start n) #f)
          ((char=? (string-ref s start) #\[)
           (let loop ((i (+ start 1)))
             (cond ((= i n) #f)
                   ((char=? (string-ref s i) #\])
                    (and (ipv6-text? (substring s (+ start 1) i)) (+ i 1)))
                   (else (loop (+ i 1))))))
          (else
           (let loop ((i start))
             (if (and (< i n)
                      (let ((c (string-ref s i)))
                        (or (lower? c) (digit? c) (memv c '(#\- #\. #\_)))))
                 (loop (+ i 1))
                 (and (> i start)
                      (let ((host (substring s start i)))
                        (or (not (ends-in-number? host)) (ipv4-text? host)))
                      i))))))

  ;; ends-in-number? : String -> Boolean
  ;; Whether HOST's last label, the one before a trailing . when there is
  ;; one, is all digits, or 0x and hex digits: URL then reads HOST as an
  ;; IPv4 address.
  (define (ends-in-number? host)
    (let* ((labels (split host #\.))
           (labels (if (and (pair? (cdr labels)) (string=? (car (last-pair labels)) ""))
                       (reverse (cdr (reverse labels)))
                       labels))
           (last (car (last-pair labels)))
           (n (string-length last)))
      (or (and (> n 0) (for-all digit? (string->list last)))
          (and (>= n 2) (string=? (substring last 0 2) "0x")
               (for-all hex? (string->list (substring last 2 n)))))))

  ;; ipv4-text? : String -> Boolean
  ;; Whether HOST is four numbers 0 to 255 with no leading 0, joined by .,
  ;; as URL's IPv4 serializer writes an address.
  (define (ipv4-text? host)
    (let ((parts (split host #\.)))
      (and (= (length parts) 4)
           (for-all (lambda (p)
                      (let ((k (string-length p)))
                        (and (<= 1 k 3)
                             (for-all digit? (string->list p))
                             (or (= k 1) (not (char=? (string-ref p 0) #\0)))
                             (<= (string->number p) 255))))
                    parts))))

  ;; ipv6-text? : String -> Boolean
  ;; Whether S, between the brackets, is an IPv6 address as URL's IPv6
  ;; serializer writes it: eight pieces of lower-case hex with no leading
  ;; 0, the first longest run of two or more 0 pieces written ::.
  (define (ipv6-text? s)
    (let ((pieces (ipv6-pieces s)))
      (and pieces (string=? s (ipv6-serialized pieces)))))

  ;; ipv6-pieces : String -> (U (Listof Nat) #f)
  ;; The eight pieces S names, colon-separated hex of at most 4 digits with
  ;; at most one ::, or #f.
  (define (ipv6-pieces s)
    (let* ((n (string-length s))
           (gap (let loop ((i 0))
                  (cond ((>= (+ i 1) n) #f)
                        ((and (char=? (string-ref s i) #\:) (char=? (string-ref s (+ i 1)) #\:)) i)
                        (else (loop (+ i 1))))))
           (side (lambda (t)
                   (if (string=? t "")
                       '()
                       (let ((parts (split t #\:)))
                         (and (for-all (lambda (p)
                                         (and (<= 1 (string-length p) 4) (for-all hex? (string->list p))))
                                       parts)
                              (map (lambda (p) (string->number p 16)) parts)))))))
      (if gap
          (let ((left (side (substring s 0 gap)))
                (right (side (substring s (+ gap 2) n))))
            (and left right
                 (<= (+ (length left) (length right)) 7)
                 (append left (make-list (- 8 (length left) (length right)) 0) right)))
          (let ((pieces (side s)))
            (and pieces (= (length pieces) 8) pieces)))))

  ;; ipv6-serialized : (Listof Nat) -> String
  ;; URL's IPv6 serializer, without the brackets.
  (define (ipv6-serialized pieces)
    (let* ((v (list->vector pieces))
           (compress
            (let loop ((i 0) (best #f) (best-length 1))
              (if (= i 8)
                  best
                  (let run ((j i))
                    (if (and (< j 8) (= (vector-ref v j) 0))
                        (run (+ j 1))
                        (if (> (- j i) best-length)
                            (loop (max j (+ i 1)) i (- j i))
                            (loop (max j (+ i 1)) best best-length))))))))
      (let loop ((i 0) (ignore-0? #f) (out '()))
        (cond ((= i 8) (apply string-append (reverse out)))
              ((and ignore-0? (= (vector-ref v i) 0)) (loop (+ i 1) #t out))
              ((eqv? compress i) (loop (+ i 1) #t (cons (if (= i 0) "::" ":") out)))
              (else
               (loop (+ i 1) #f
                     (cons (string-append (downcase (number->string (vector-ref v i) 16))
                                          (if (= i 7) "" ":"))
                           out)))))))

  ;; make-list : Nat Any -> List
  (define (make-list k x) (if (= k 0) '() (cons x (make-list (- k 1) x))))

  ;; last-pair : Pair -> Pair
  (define (last-pair l) (if (pair? (cdr l)) (last-pair (cdr l)) l))

  ;; split : String Char -> (Listof String)
  ;; S's pieces between each C, empty ones kept.
  (define (split s c)
    (let ((n (string-length s)))
      (let loop ((i 0) (start 0) (out '()))
        (cond ((= i n) (reverse (cons (substring s start n) out)))
              ((char=? (string-ref s i) c) (loop (+ i 1) (+ i 1) (cons (substring s start i) out)))
              (else (loop (+ i 1) start out))))))

  ;; port-text? : String String Nat Nat -> Boolean
  ;; Whether S from START to N is a port an origin of SCHEME writes. Not 0,
  ;; which Fetch blocks, so no page has it.
  (define (port-text? scheme s start n)
    (let ((k (- n start)))
      (and (> k 0)
           (let loop ((i start))
             (or (= i n) (and (digit? (string-ref s i)) (loop (+ i 1)))))
           (or (= k 1) (not (char=? (string-ref s start) #\0)))
           (let ((port (string->number (substring s start n)))
                 (default (assoc scheme default-ports)))
             (and (<= 1 port 65535)
                  (not (and default (= port (cdr default))))))))))
