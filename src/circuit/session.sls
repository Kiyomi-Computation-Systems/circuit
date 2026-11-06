#!r6rs
;;; (circuit session): a session kept in a signed cookie (the sessions
;;; design §5).
;;;
;;;   (import (rnrs) (circuit) (circuit session))
;;;   (wrap app (wrap-session (list secret) clock 1209600))
;;;   (req-session req)
;;;   (res-with-session res (list (cons "user" "ada")))
;;;
;;; The cookie is the store. Its value is the session's pairs by
;;; params->string, the clock's time when it was written, and an
;;; HMAC-SHA-256 of the cookie's name, the pairs and the time, from
;;; hashing's (hashing sha-2), each after a dot. The mac is made under a key
;;; of the first secret's own. Whoever holds the cookie can read the
;;; session but not change it, and can send it back while it lives: its
;;; time and the max age bound that.
;;;
;;; Before the handler, the first cookie of the name that verifies, under
;;; any secret, is the session. A value sets none, with no error and no log
;;; line, when it holds anything but cookie-octets, when it doesn't split
;;; from its right into the pairs, a time of digits and a mac of 64
;;; lower-case hex digits, when no secret's key makes its mac, or when its
;;; time is past the max age or more than 60 seconds ahead of the clock.
;;; The mac is checked before the time, by hashing's sha-256-hash=?, which
;;; compares every word: the clock is called only for a cookie whose mac
;;; holds.
;;;
;;; After the handler, a session handed back with res-with-session is
;;; written whole, signed with the first secret; '() expires the cookie;
;;; and a response with none leaves the cookie the browser holds. A
;;; response that sets or expires it gets cache-control: private, unless it
;;; holds a cache-control field, and every response gets vary: cookie,
;;; unless a vary field lists cookie or *. Once written, the response's key
;;; holds a mark, so an outer wrap-session leaves it alone: nested, the
;;; innermost reads and writes.
(library (circuit session)
  (export wrap-session req-session res-with-session
          session-name session-path session-domain session-same-site session-insecure)
  (import (rnrs)
          (only (circuit request) req? make-req-key req-ref req-set)
          (only (circuit response) make-res res? res-headers make-res-key res-ref res-set res-add-header)
          (only (circuit headers) header-values)
          (only (circuit cookies) req-cookies res-add-cookie res-expire-cookie cookie-path cookie-domain
                cookie-max-age cookie-secure cookie-http-only cookie-same-site)
          (only (circuit params) parse-params params->string)
          (only (hashing sha-2) hmac-sha-256 sha-256->bytevector sha-256->string sha-256-hash=?))

  ;; Session = (Listof (Pair String String))
  ;; SessionOption = what a session- constructor makes

  ;; The keys a session goes under: the one read, on the request, and the
  ;; one handed back, on the response.
  (define req-key (make-req-key 'session))
  (define res-key (make-res-key 'session))

  ;; What res-ref answers for a response with no session, and the mark a
  ;; written one holds: each a pair of its own, which no session is.
  (define none (list 'no-session))
  (define written (list 'session-written))

  ;; --- the options ------------------------------------------------------------------

  ;; An option: the setting it makes, the name of the constructor that made
  ;; it, and the setting: the name, a cookie option, or #t.
  (define-record-type (option make-option option?)
    (fields slot name value)
    (sealed #t)
    (opaque #t))

  ;; session-name : String -> SessionOption
  ;; The cookie's name, __Host-session unless given. What is no string is
  ;; an assertion violation; wrap-session tries the rest, as res-add-cookie
  ;; checks a name. It is copied.
  (define (session-name name)
    (unless (string? name)
      (assertion-violation 'session-name "a cookie name is a string" name))
    (make-option 'name 'session-name (string-copy name)))

  ;; session-path : String -> SessionOption
  ;; The cookie's Path, / unless given. A path cookie-path refuses is an
  ;; assertion violation, with its words.
  (define (session-path path)
    (make-option 'path 'session-path (renamed 'session-path (lambda () (cookie-path path)))))

  ;; session-domain : String -> SessionOption
  ;; The cookie's Domain, none unless given. A domain cookie-domain
  ;; refuses is an assertion violation, with its words.
  (define (session-domain domain)
    (make-option 'domain 'session-domain (renamed 'session-domain (lambda () (cookie-domain domain)))))

  ;; session-same-site : Symbol -> SessionOption
  ;; The cookie's SameSite, strict, lax or none, lax unless given. Any other
  ;; is an assertion violation, with cookie-same-site's words.
  (define (session-same-site mode)
    (make-option 'same-site 'session-same-site
                 (renamed 'session-same-site (lambda () (cookie-same-site mode)))))

  ;; session-insecure : -> SessionOption
  ;; No Secure, so the browser sends the cookie over plain http: for
  ;; development alone.
  (define (session-insecure)
    (make-option 'insecure 'session-insecure #t))

  ;; constructor-name : Any -> (U Symbol #f)
  ;; The name of the constructor X is, or #f.
  (define (constructor-name x)
    (cond ((eq? x session-name) 'session-name)
          ((eq? x session-path) 'session-path)
          ((eq? x session-domain) 'session-domain)
          ((eq? x session-same-site) 'session-same-site)
          ((eq? x session-insecure) 'session-insecure)
          (else #f)))

  ;; renamed : Symbol (-> Any) -> Any
  ;; THUNK's answer. An assertion violation it raises is raised again,
  ;; naming WHO, with its message and irritants.
  (define (renamed who thunk)
    (guard (e ((and (assertion-violation? e) (message-condition? e))
               (apply assertion-violation who (condition-message e)
                      (if (irritants-condition? e) (condition-irritants e) '()))))
      (thunk)))

  ;; --- the middleware -------------------------------------------------------------

  ;; wrap-session : (Listof String) (-> Integer) Nat SessionOption ... -> Middleware
  ;; Middleware that reads the session from its cookie before the handler,
  ;; for req-session, and writes the one the handler hands back with
  ;; res-with-session after it. SECRETS are strings of at least 32 bytes as
  ;; UTF-8, at least one: the first signs, and each verifies, in order.
  ;; CLOCK answers the seconds since the Unix epoch, an exact integer, 0 or
  ;; more: it is called now, for a cookie whose mac holds, and for a session
  ;; written. MAX-AGE, from 1 to 34560000 seconds, the 400 days a browser
  ;; keeps a cookie at most, is the cookie's Max-Age, and the most its time
  ;; may lag the clock. The cookie is __Host-session, with Path=/, Secure,
  ;; HttpOnly and SameSite=Lax, but as the options set it; HttpOnly always.
  ;; A bad setting is an assertion violation, raised now, the cookie's name
  ;; and attributes among them, tried with res-add-cookie and
  ;; res-expire-cookie and refused with their words. So is a clock's answer
  ;; that is no such integer, now or at a request, and a handler that is no
  ;; procedure, when the middleware is applied.
  (define (wrap-session secrets clock max-age . options)
    (check-secrets secrets)
    (unless (procedure? clock)
      (assertion-violation 'wrap-session
                           "a clock is a procedure of no arguments that answers the seconds since the Unix epoch"
                           (unnamed clock)))
    (unless (and (integer? max-age) (exact? max-age) (<= 1 max-age 34560000))
      (assertion-violation 'wrap-session
                           "a max age is a whole number of seconds from 1 to 34560000, the 400 days a browser keeps a cookie at most"
                           (unnamed max-age)))
    (let* ((by-slot (settings options))
           (name (let ((o (assq 'name by-slot))) (if o (option-value (cdr o)) "__Host-session")))
           (attributes (cookie-attributes by-slot))
           (lifetime (cookie-max-age max-age))
           (keys (map signing-key secrets)))
      (try-cookie name attributes lifetime (now clock))
      (lambda (handler)
        (unless (procedure? handler)
          (assertion-violation 'wrap-session "a handler is a procedure" handler))
        (lambda (req)
          (let ((answer (handler (req-set req req-key (read-session req name keys max-age clock)))))
            (if (res? answer)
                (write-session answer name (car keys) clock attributes lifetime)
                answer))))))

  ;; unnamed : Any -> Any
  ;; What a refusal names for X, a setting that is no secret's place: a
  ;; string by its kind alone, 'string, as it may be a secret given in the
  ;; wrong place, which a log would then show.
  (define (unnamed x) (if (string? x) 'string x))

  ;; check-secrets : Any -> Unspecified
  ;; No condition names a secret, which a log would then show.
  (define (check-secrets secrets)
    (unless (and (list? secrets) (pair? secrets) (for-all string? secrets))
      (assertion-violation 'wrap-session "secrets are a list of strings, at least one: the first signs, and each verifies"))
    (for-each (lambda (secret)
                (let ((size (bytevector-length (string->utf8 secret))))
                  (unless (>= size 32)
                    (assertion-violation 'wrap-session
                                         "a secret is at least 32 bytes as UTF-8: openssl rand -base64 32 makes one"
                                         size))))
              secrets))

  ;; settings : (Listof Any) -> (Listof (Pair Symbol Option))
  ;; OPTIONS by the setting each makes. What no constructor made, a
  ;; constructor given bare, and an option given twice, are each an
  ;; assertion violation.
  (define (settings options)
    (for-each (lambda (x)
                (unless (option? x)
                  (let ((constructor (constructor-name x)))
                    (if constructor
                        (assertion-violation 'wrap-session "an option's constructor, given bare: call it" constructor)
                        (assertion-violation 'wrap-session "an option is what a session- constructor makes"
                                             (unnamed x))))))
              options)
    (fold-left (lambda (by-slot x)
                 (when (assq (option-slot x) by-slot)
                   (assertion-violation 'wrap-session "each option once" (option-name x)))
                 (cons (cons (option-slot x) x) by-slot))
               '()
               options))

  ;; cookie-attributes : (Listof (Pair Symbol Option)) -> (Listof CookieOption)
  ;; The cookie's attributes but Max-Age: Path, / unless given; Domain when
  ;; given; Secure, but with session-insecure; HttpOnly; SameSite, Lax unless
  ;; given.
  (define (cookie-attributes by-slot)
    (let ((given (lambda (slot) (let ((o (assq slot by-slot))) (and o (option-value (cdr o)))))))
      (append (list (or (given 'path) (cookie-path "/")))
              (if (given 'domain) (list (given 'domain)) '())
              (if (given 'insecure) '() (list (cookie-secure)))
              (list (cookie-http-only) (or (given 'same-site) (cookie-same-site 'lax))))))

  ;; try-cookie : String (Listof CookieOption) CookieOption Nat -> Unspecified
  ;; NAME, set with ATTRIBUTES and LIFETIME, with the value of a session of
  ;; one empty pair written at TIME, the shortest one, and expired with
  ;; ATTRIBUTES, each on a response of its own. What the cookies refuse is
  ;; an assertion violation naming wrap-session, with their words.
  (define (try-cookie name attributes lifetime time)
    (renamed 'wrap-session
             (lambda ()
               (apply res-add-cookie (make-res 200 '() "") name
                      (string-append "=." (number->string time) "." (make-string 64 #\0))
                      lifetime attributes)
               (apply res-expire-cookie (make-res 200 '() "") name attributes))))

  ;; signing-key : String -> Bytevector
  ;; The key SECRET signs a session under: HMAC-SHA-256 of "circuit
  ;; session" under its UTF-8, so a key made from it for another use never
  ;; signs for this one.
  (define (signing-key secret)
    (sha-256->bytevector (hmac-sha-256 (string->utf8 secret) (string->utf8 "circuit session"))))

  ;; now : (-> Integer) -> Nat
  ;; CLOCK's answer, which is an exact integer, 0 or more, or an assertion
  ;; violation.
  (define (now clock)
    (let ((time (clock)))
      (unless (and (integer? time) (exact? time) (>= time 0))
        (assertion-violation 'wrap-session
                             "a clock answers the seconds since the Unix epoch, an exact integer, 0 or more"
                             time))
      time))

  ;; --- reading --------------------------------------------------------------------

  ;; read-session : Req String (Listof Bytevector) Nat (-> Integer) -> Session
  ;; The session of the first cookie of NAME that verifies, or '().
  (define (read-session req name keys max-age clock)
    (let loop ((cookies (req-cookies req)))
      (cond ((null? cookies) '())
            ((and (string=? (caar cookies) name) (verified name (cdar cookies) keys max-age clock)))
            (else (loop (cdr cookies))))))

  ;; verified : String String (Listof Bytevector) Nat (-> Integer) -> (U Session #f)
  ;; The session VALUE holds, or #f: its octets, then its split from the
  ;; right, then its mac, then its time, by one call of CLOCK.
  (define (verified name value keys max-age clock)
    (let* ((n (string-length value))
           (mac-dot (and (for-all-chars cookie-octet? value) (last-dot value n))))
      (and mac-dot
           (= (- n mac-dot 1) 64)
           (for-all-chars lower-hex? (substring value (+ mac-dot 1) n))
           (let ((time-dot (last-dot value mac-dot)))
             (and time-dot
                  (< (+ time-dot 1) mac-dot)
                  (for-all-chars digit? (substring value (+ time-dot 1) mac-dot))
                  (let ((mac (hex->bytevector value (+ mac-dot 1)))
                        (signed (string->utf8 (string-append name "=" (substring value 0 mac-dot)))))
                    (and (exists (lambda (key) (sha-256-hash=? (hmac-sha-256 key signed) mac)) keys)
                         (let ((time (string->number (substring value (+ time-dot 1) mac-dot) 10))
                               (clock-time (now clock)))
                           (and (> (+ time max-age) clock-time)
                                (<= time (+ clock-time 60))
                                (parse-params (string->utf8 (substring value 0 time-dot))))))))))))

  ;; last-dot : String Nat -> (U Nat #f)
  ;; The index of the last . in S before END, or #f.
  (define (last-dot s end)
    (let loop ((i (- end 1)))
      (cond ((< i 0) #f)
            ((char=? (string-ref s i) #\.) i)
            (else (loop (- i 1))))))

  ;; hex->bytevector : String Nat -> Bytevector
  ;; The 32 bytes of the 64 lower-case hex digits of S from START.
  (define (hex->bytevector s start)
    (let ((out (make-bytevector 32)))
      (let loop ((i 0))
        (if (= i 32)
            out
            (begin
              (bytevector-u8-set! out i (+ (* 16 (hex-value (string-ref s (+ start (* 2 i)))))
                                           (hex-value (string-ref s (+ start (* 2 i) 1)))))
              (loop (+ i 1)))))))

  (define (hex-value c)
    (let ((n (char->integer c)))
      (if (<= 48 n 57) (- n 48) (- n 87))))

  (define (for-all-chars ok? s)
    (let ((n (string-length s)))
      (let loop ((i 0))
        (or (= i n)
            (and (ok? (char->integer (string-ref s i))) (loop (+ i 1)))))))

  ;; cookie-octet? : Nat -> Boolean — %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E.
  (define (cookie-octet? c)
    (or (= c #x21) (<= #x23 c #x2B) (<= #x2D c #x3A) (<= #x3C c #x5B) (<= #x5D c #x7E)))

  (define (digit? c) (<= 48 c 57))

  (define (lower-hex? c) (or (<= 48 c 57) (<= 97 c 102)))

  ;; req-session : Req -> Session
  ;; The session wrap-session read from REQ's cookie: '() when none
  ;; verified, and on a request no wrap-session saw. What is no request is
  ;; an assertion violation.
  (define (req-session req)
    (unless (req? req)
      (assertion-violation 'req-session "not a request" req))
    (req-ref req req-key '()))

  ;; --- writing --------------------------------------------------------------------

  ;; res-with-session : Res Session -> Res
  ;; RES with SESSION handed back, for the wrap-session around the handler
  ;; to write: whole, or, for '(), as the cookie's expiry. On a response no
  ;; wrap-session sees, it sets a key nothing reads. What is no response,
  ;; and a session that is no list of pairs of strings, is an assertion
  ;; violation.
  (define (res-with-session res session)
    (unless (res? res)
      (assertion-violation 'res-with-session "not a response" res))
    (unless (and (list? session)
                 (for-all (lambda (p) (and (pair? p) (string? (car p)) (string? (cdr p)))) session))
      (assertion-violation 'res-with-session "a session is a list of (name . value) pairs of strings" session))
    (res-set res res-key session))

  ;; write-session : Res String Bytevector (-> Integer) (Listof CookieOption) CookieOption -> Res
  ;; RES as wrap-session hands it on: untouched once written; with vary
  ;; alone when it hands back no session; and otherwise with the cookie
  ;; set, or expired for '(), cache-control and vary, and the mark.
  (define (write-session res name key clock attributes lifetime)
    (let ((session (res-ref res res-key none)))
      (cond ((eq? session written) res)
            ((eq? session none) (varied res))
            (else
             (res-set (varied (private (if (null? session)
                                           (apply res-expire-cookie res name attributes)
                                           (apply res-add-cookie res name (signed name session key (now clock))
                                                  lifetime attributes))))
                      res-key written)))))

  ;; signed : String Session Bytevector Nat -> String
  ;; The cookie's value: SESSION's pairs, TIME and the mac of NAME=, the
  ;; pairs and TIME under KEY, each after a dot.
  (define (signed name session key time)
    (let ((text (string-append (params->string session) "." (number->string time))))
      (string-append text "." (sha-256->string (hmac-sha-256 key (string->utf8 (string-append name "=" text)))))))

  ;; private : Res -> Res
  ;; RES with cache-control: private, unless it holds a cache-control
  ;; field.
  (define (private res)
    (if (null? (header-values (res-headers res) "cache-control"))
        (res-add-header res "cache-control" "private")
        res))

  ;; varied : Res -> Res
  ;; RES with vary: cookie, unless one of its vary fields lists cookie, in
  ;; any case, or *.
  (define (varied res)
    (if (exists (lambda (value)
                  (exists (lambda (element)
                            (let ((e (trimmed element)))
                              (or (string=? e "*") (ascii-ci=? e "cookie"))))
                          (comma-split value)))
                (header-values (res-headers res) "vary"))
        res
        (res-add-header res "vary" "cookie")))

  ;; comma-split : String -> (Listof String) — S's pieces between commas.
  (define (comma-split s)
    (let ((n (string-length s)))
      (let loop ((start 0) (i 0) (out '()))
        (cond ((= i n) (reverse (cons (substring s start n) out)))
              ((char=? (string-ref s i) #\,) (loop (+ i 1) (+ i 1) (cons (substring s start i) out)))
              (else (loop start (+ i 1) out))))))

  ;; trimmed : String -> String — S less the spaces and tabs at either end.
  (define (trimmed s)
    (let* ((n (string-length s))
           (from (let loop ((i 0)) (if (and (< i n) (blank? (string-ref s i))) (loop (+ i 1)) i)))
           (to (let loop ((i n)) (if (and (> i from) (blank? (string-ref s (- i 1)))) (loop (- i 1)) i))))
      (substring s from to)))

  (define (blank? c) (or (char=? c #\space) (char=? c #\tab)))

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
    (if (char<=? #\A c #\Z) (integer->char (+ (char->integer c) 32)) c)))
