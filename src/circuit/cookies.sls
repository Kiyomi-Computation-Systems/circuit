#!r6rs
;;; (circuit cookies): the request's cookies, read as name and value pairs,
;;; and set-cookie fields written on the response (the slice 9 design §6).
;;;
;;;   (import (rnrs) (circuit) (circuit cookies))
;;;   (req-cookie req "__Host-theme")
;;;   (res-add-cookie res "__Host-theme" "dark"
;;;                   (cookie-path "/") (cookie-secure) (cookie-http-only))
;;;
;;; req-cookies reads every cookie field when it is asked, with no
;;; middleware, as RFC 6265bis §4.2.1 lets a server: each split on ;, each
;;; piece at its first =, the name and the value trimmed of spaces and
;;; tabs, and a piece with no = or an empty name skipped. A value's quotes
;;; are kept, as §4.1.1 has them, and no character is checked: a cookie
;;; another system set reads as it was sent, Latin-1 as the server reads
;;; every field.
;;;
;;; res-add-cookie and res-expire-cookie each add one set-cookie field,
;;; keeping the response's own, and take options, each made by a
;;; constructor here and given at most once. Each checks its setting when
;;; given, and they check the cookie and its options together. A name or
;;; value outside §4.1.1's grammar, and a cookie a browser would drop
;;; without a word (§5.6, §5.7) or never send, is an assertion violation
;;; when it is written. A path holds nothing a URL's path escapes, and a
;;; domain nothing a host can't hold (WHATWG URL); a domain isn't held to
;;; the grammar's subdomain, so an _ and an IP address pass, and the host
;;; it must match isn't known here. The attributes go in one order,
;;; whatever the order of the options: Path, Domain, Max-Age or Expires,
;;; Secure, HttpOnly, SameSite. A browser matches the __Secure- and __Host-
;;; prefixes in any case (§5.4), so they do here.
(library (circuit cookies)
  (export req-cookies req-cookie res-add-cookie res-expire-cookie
          cookie-path cookie-domain cookie-max-age cookie-secure cookie-http-only
          cookie-same-site)
  (import (rnrs)
          (only (circuit request) req? req-header-values)
          (only (circuit response) res? res-add-header))

  ;; Cookies = (Listof (Pair String String))
  ;; CookieOption = what a cookie- constructor makes

  ;; --- reading --------------------------------------------------------------------

  ;; req-cookies : Req -> Cookies
  ;; Every cookie of every cookie field, in order, a name given twice kept
  ;; twice. What is no request is an assertion violation.
  (define (req-cookies req)
    (check-req 'req-cookies req)
    (fold-right (lambda (field out) (append (field-cookies field) out))
                '()
                (req-header-values req "cookie")))

  ;; req-cookie : Req String -> (U String #f)
  ;; The value of the first cookie named NAME, exactly, or #f. A browser
  ;; sends two of one name for two paths or domains, in no order a server
  ;; may rely on (§4.2.2): a __Host- name has one of each. What is no
  ;; request, or a name that is no string, is an assertion violation.
  (define (req-cookie req name)
    (check-req 'req-cookie req)
    (unless (string? name)
      (assertion-violation 'req-cookie "a cookie name is a string" name))
    (let ((found (assoc name (req-cookies req))))
      (and found (cdr found))))

  ;; field-cookies : String -> Cookies — the cookies of one cookie field.
  (define (field-cookies field)
    (let ((end (string-length field)))
      (let loop ((start 0) (out '()))
        (if (> start end)
            (reverse out)
            (let* ((semi (index-of field #\; start end))
                   (eq (index-of field #\= start semi)))
              (loop (+ semi 1)
                    (if (= eq semi)
                        out
                        (let ((name (trimmed field start eq)))
                          (if (string=? name "")
                              out
                              (cons (cons name (trimmed field (+ eq 1) semi)) out))))))))))

  ;; index-of : String Char Nat Nat -> Nat
  ;; The index of the first C in S from START, before END, or END.
  (define (index-of s c start end)
    (let loop ((i start))
      (cond ((= i end) end)
            ((char=? (string-ref s i) c) i)
            (else (loop (+ i 1))))))

  ;; trimmed : String Nat Nat -> String
  ;; S from START to END, less the spaces and tabs at either end.
  (define (trimmed s start end)
    (let* ((from (let loop ((i start))
                   (if (and (< i end) (blank? (string-ref s i))) (loop (+ i 1)) i)))
           (to (let loop ((i end))
                 (if (and (> i from) (blank? (string-ref s (- i 1)))) (loop (- i 1)) i))))
      (substring s from to)))

  (define (blank? c) (or (char=? c #\space) (char=? c #\tab)))

  ;; --- the options ------------------------------------------------------------------

  ;; An option: the attribute it sets, the name of the constructor that
  ;; made it, and the attribute's value, written.
  (define-record-type (option make-option option?)
    (fields slot name value)
    (sealed #t)
    (opaque #t))

  ;; cookie-path : String -> CookieOption
  ;; Path: the paths the browser sends the cookie to, as given. A path that
  ;; doesn't start with /, holds anything but ASCII from a space to ~ or a
  ;; ;, holds what a URL's path never does, or is over 1024 bytes, is an
  ;; assertion violation. It is copied, so a change to it after changes
  ;; nothing.
  (define (cookie-path path)
    (unless (string? path)
      (assertion-violation 'cookie-path "a path is a string" path))
    (unless (av-octets? path)
      (assertion-violation 'cookie-path "a path holds ASCII from a space to ~ alone, with no ;" path))
    (when (holds-any? path " \"#<>?^`{}\\")
      (assertion-violation 'cookie-path
                           (string-append "a path holds no space, \", #, <, >, ?, ^, `, {, } or \\:"
                                          " a URL's path never does, so a browser would never send the cookie")
                           path))
    (unless (<= (string-length path) 1024)
      (assertion-violation 'cookie-path "a path is at most 1024 bytes: a browser ignores a longer one" path))
    (unless (and (> (string-length path) 0) (char=? (string-ref path 0) #\/))
      (assertion-violation 'cookie-path "a path starts with /: a browser ignores any other" path))
    (make-option 'path 'cookie-path (string-copy path)))

  ;; cookie-domain : String -> CookieOption
  ;; Domain: the host and its subdomains, as given. A domain that is empty
  ;; or . alone, holds anything but ASCII from a space to ~ or a ;, holds
  ;; what no host does, or is over 1024 bytes, is an assertion violation.
  ;; It is copied.
  (define (cookie-domain domain)
    (unless (string? domain)
      (assertion-violation 'cookie-domain "a domain is a string" domain))
    (when (or (string=? domain "") (string=? domain "."))
      (assertion-violation 'cookie-domain "a domain is not empty, nor . alone: a browser reads either as no Domain"
                           domain))
    (unless (av-octets? domain)
      (assertion-violation 'cookie-domain "a domain holds ASCII from a space to ~ alone, with no ;" domain))
    (when (holds-any? domain " #%/:<>?@[\\]^|")
      (assertion-violation 'cookie-domain
                           (string-append "a domain holds no space, #, %, /, :, <, >, ?, @, [, \\, ], ^ or |:"
                                          " no host does, so a browser ignores the cookie")
                           domain))
    (unless (<= (string-length domain) 1024)
      (assertion-violation 'cookie-domain "a domain is at most 1024 bytes: a browser ignores a longer one"
                           domain))
    (make-option 'domain 'cookie-domain (string-copy domain)))

  ;; holds-any? : String String -> Boolean — whether S holds a character of SET.
  (define (holds-any? s set)
    (let ((n (string-length s)))
      (let loop ((i 0))
        (and (< i n)
             (or (and (memv (string-ref s i) (string->list set)) #t)
                 (loop (+ i 1)))))))

  ;; cookie-max-age : Nat -> CookieOption
  ;; Max-Age: how many seconds the browser keeps the cookie, sent as given;
  ;; a browser keeps it 400 days at most. Less than 1 is an assertion
  ;; violation, as is what is no exact integer: res-expire-cookie expires
  ;; a cookie. So is one of more than 1024 digits, which a browser ignores.
  (define (cookie-max-age seconds)
    (unless (and (integer? seconds) (exact? seconds) (>= seconds 1))
      (assertion-violation 'cookie-max-age
                           "a max-age is a whole number of seconds, at least 1: res-expire-cookie expires a cookie"
                           seconds))
    (let ((digits (number->string seconds)))
      (unless (<= (string-length digits) 1024)
        (assertion-violation 'cookie-max-age "a max-age is at most 1024 digits: a browser ignores a longer one"
                             seconds))
      (make-option 'max-age 'cookie-max-age digits)))

  ;; cookie-secure : -> CookieOption
  ;; Secure: the browser sends the cookie over https alone.
  (define (cookie-secure)
    (make-option 'secure 'cookie-secure #t))

  ;; cookie-http-only : -> CookieOption
  ;; HttpOnly: a page's script can't read the cookie.
  (define (cookie-http-only)
    (make-option 'http-only 'cookie-http-only #t))

  ;; cookie-same-site : Symbol -> CookieOption
  ;; SameSite: strict, lax or none, written Strict, Lax or None. Any other
  ;; is an assertion violation. None needs cookie-secure.
  (define (cookie-same-site mode)
    (make-option 'same-site 'cookie-same-site
                 (case mode
                   ((strict) "Strict")
                   ((lax) "Lax")
                   ((none) "None")
                   (else (assertion-violation 'cookie-same-site "a same-site is strict, lax or none" mode)))))

  ;; constructor-name : Any -> (U Symbol #f)
  ;; The name of the constructor X is, or #f.
  (define (constructor-name x)
    (cond ((eq? x cookie-path) 'cookie-path)
          ((eq? x cookie-domain) 'cookie-domain)
          ((eq? x cookie-max-age) 'cookie-max-age)
          ((eq? x cookie-secure) 'cookie-secure)
          ((eq? x cookie-http-only) 'cookie-http-only)
          ((eq? x cookie-same-site) 'cookie-same-site)
          (else #f)))

  ;; --- writing ----------------------------------------------------------------------

  ;; res-add-cookie : Res String String CookieOption ... -> Res
  ;; RES with one set-cookie field appended: NAME=VALUE and the options'
  ;; attributes. A name that is no token, a value that isn't cookie-octets
  ;; bare or between two quotes, a name and value over 4096 bytes together,
  ;; SameSite=None without Secure, a __Secure- name without Secure, or a
  ;; __Host- name without Secure and Path=/ or with a Domain, each in any
  ;; case, is an assertion violation. So is what is no response, and what
  ;; no constructor made, a constructor given bare, or an option given
  ;; twice.
  (define (res-add-cookie res name value . options)
    (check-res 'res-add-cookie res)
    (check-name 'res-add-cookie name)
    (unless (string? value)
      (assertion-violation 'res-add-cookie "a cookie value is a string" value))
    (unless (cookie-value? value)
      (assertion-violation 'res-add-cookie
                           (string-append "a cookie value is cookie-octets, bare or between two quotes:"
                                          " encode a space, a quote, a comma, a semicolon, a backslash,"
                                          " a control or anything past ASCII first")
                           value))
    (check-size 'res-add-cookie name value)
    (let ((by-slot (settings 'res-add-cookie name options)))
      (res-add-header res "set-cookie"
                      (field name value by-slot
                             (let ((o (assq 'max-age by-slot)))
                               (if o (string-append "; Max-Age=" (option-value (cdr o))) ""))))))

  ;; res-expire-cookie : Res String CookieOption ... -> Res
  ;; RES with one set-cookie field appended that expires the cookie NAME:
  ;; no value, and Expires at the epoch in Max-Age's place, a fixed date
  ;; that needs no clock. A browser removes the cookie only when the path
  ;; and domain match the ones it was set with. It takes the options but
  ;; cookie-max-age, and refuses what res-add-cookie refuses.
  (define (res-expire-cookie res name . options)
    (check-res 'res-expire-cookie res)
    (check-name 'res-expire-cookie name)
    (check-size 'res-expire-cookie name "")
    (let ((by-slot (settings 'res-expire-cookie name options)))
      (res-add-header res "set-cookie"
                      (field name "" by-slot "; Expires=Thu, 01 Jan 1970 00:00:00 GMT"))))

  ;; field : String String (Listof (Pair Symbol Option)) String -> String
  ;; The set-cookie field, LIFETIME in Max-Age's place.
  (define (field name value by-slot lifetime)
    (let ((setting (lambda (slot) (let ((o (assq slot by-slot))) (and o (option-value (cdr o)))))))
      (string-append name "=" value
                     (if (setting 'path) (string-append "; Path=" (setting 'path)) "")
                     (if (setting 'domain) (string-append "; Domain=" (setting 'domain)) "")
                     lifetime
                     (if (setting 'secure) "; Secure" "")
                     (if (setting 'http-only) "; HttpOnly" "")
                     (if (setting 'same-site) (string-append "; SameSite=" (setting 'same-site)) ""))))

  ;; settings : Symbol String (Listof Any) -> (Listof (Pair Symbol Option))
  ;; OPTIONS by the attribute each sets. What no constructor made, a
  ;; constructor given bare, an option given twice, a max-age to
  ;; res-expire-cookie, and the options a browser would drop the cookie
  ;; NAME for, are each an assertion violation.
  (define (settings who name options)
    (for-each (lambda (x)
                (unless (option? x)
                  (let ((constructor (constructor-name x)))
                    (if constructor
                        (assertion-violation who "an option's constructor, given bare: call it" constructor)
                        (assertion-violation who "an option is what a cookie- constructor makes" x)))))
              options)
    (let ((by-slot (fold-left (lambda (by-slot x)
                                (when (assq (option-slot x) by-slot)
                                  (assertion-violation who "each option once" (option-name x)))
                                (cons (cons (option-slot x) x) by-slot))
                              '()
                              options)))
      (when (and (eq? who 'res-expire-cookie) (assq 'max-age by-slot))
        (assertion-violation who "res-expire-cookie takes no max-age: its date in the past expires the cookie"
                             'cookie-max-age))
      (let ((secure? (assq 'secure by-slot))
            (same-site (assq 'same-site by-slot))
            (path (assq 'path by-slot)))
        (when (and same-site (string=? (option-value (cdr same-site)) "None") (not secure?))
          (assertion-violation who "SameSite=None needs cookie-secure: a browser ignores the cookie without it"
                               name))
        (when (and (prefixed? name "__secure-") (not secure?))
          (assertion-violation who "a __Secure- name needs cookie-secure: a browser ignores the cookie without it"
                               name))
        (when (and (prefixed? name "__host-")
                   (not (and secure? path (string=? (option-value (cdr path)) "/")
                             (not (assq 'domain by-slot)))))
          (assertion-violation who
                               (string-append "a __Host- name needs cookie-secure and (cookie-path \"/\"),"
                                              " and no cookie-domain: a browser ignores the cookie otherwise")
                               name)))
      by-slot))

  ;; prefixed? : String String -> Boolean
  ;; Whether NAME, a token, begins with PREFIX, in lower case, in any ASCII
  ;; case.
  (define (prefixed? name prefix)
    (let ((n (string-length prefix)))
      (and (>= (string-length name) n)
           (let loop ((i 0))
             (or (= i n)
                 (and (char=? (ascii-downcase (string-ref name i)) (string-ref prefix i))
                      (loop (+ i 1))))))))

  (define (ascii-downcase c)
    (if (char<=? #\A c #\Z) (integer->char (+ (char->integer c) 32)) c))

  ;; --- checks -------------------------------------------------------------------------

  (define (check-req who req)
    (unless (req? req)
      (assertion-violation who "not a request" req)))

  (define (check-res who res)
    (unless (res? res)
      (assertion-violation who "not a response" res)))

  (define (check-name who name)
    (unless (string? name)
      (assertion-violation who "a cookie name is a string" name))
    (unless (and (> (string-length name) 0) (for-all-chars tchar? name))
      (assertion-violation who "a cookie name is a token: letters, digits and !#$%&'*+-.^_`|~, at least one"
                           name)))

  ;; check-size : Symbol String String -> Void
  ;; NAME and VALUE, ASCII by now, over 4096 bytes together are an
  ;; assertion violation: a browser ignores the cookie (§5.6).
  (define (check-size who name value)
    (let ((size (+ (string-length name) (string-length value))))
      (unless (<= size 4096)
        (assertion-violation who
                             "a cookie's name and value are at most 4096 bytes together: a browser ignores a longer one"
                             size))))

  (define (for-all-chars ok? s)
    (let ((n (string-length s)))
      (let loop ((i 0))
        (or (= i n)
            (and (ok? (char->integer (string-ref s i))) (loop (+ i 1)))))))

  ;; tchar? : Nat -> Boolean — whether C is a token's (RFC 9110 §5.6.2).
  (define (tchar? c)
    (or (<= 48 c 57) (<= 65 c 90) (<= 97 c 122)
        (and (memv c '(33 35 36 37 38 39 42 43 45 46 94 95 96 124 126)) #t)))

  ;; cookie-octet? : Nat -> Boolean — %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E.
  (define (cookie-octet? c)
    (or (= c #x21) (<= #x23 c #x2B) (<= #x2D c #x3A) (<= #x3C c #x5B) (<= #x5D c #x7E)))

  ;; cookie-value? : String -> Boolean
  ;; Whether V is *cookie-octet, or the same between two quotes.
  (define (cookie-value? v)
    (let ((n (string-length v)))
      (or (for-all-chars cookie-octet? v)
          (and (>= n 2)
               (char=? (string-ref v 0) #\")
               (char=? (string-ref v (- n 1)) #\")
               (for-all-chars cookie-octet? (substring v 1 (- n 1)))))))

  ;; av-octets? : String -> Boolean — whether S is *av-octet: %x20-3A / %x3C-7E.
  (define (av-octets? s)
    (for-all-chars (lambda (c) (or (<= #x20 c #x3A) (<= #x3C c #x7E))) s)))
