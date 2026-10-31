#!r6rs
;;; (circuit cookies), by property: cookies, options and cookie fields
;;; generated from a fixed seed (the slice 9 design §6).
;;;
;;; Oracles, written here apart from the library: a browser's model of a
;;; set-cookie field, from RFC 6265bis (draft-ietf-httpbis-rfc6265bis-22)
;;; §5.6's parsing and §5.7's storage steps, the request taken as https from
;;; the cookie's own domain; the design's refusals, as rules over what a
;;; case drew; and the design's reading of a cookie field, over lists of
;;; characters.
;;;
;;; The rows:
;;;   - P1 a cookie res-add-cookie takes, a browser stores, with its name,
;;;     value and attributes as given, and its name=value, sent as a
;;;     browser sends it beside the case's others, in one cookie field or
;;;     two, reads back by req-cookies and req-cookie; one res-expire-cookie
;;;     takes, a browser reads as an Expires at the epoch for that name,
;;;     path and domain. A case draws one to four cookies, mostly ones the
;;;     library takes, prefixed names among them, each written on a
;;;     response of its own, holding set-cookie fields, most of other names;
;;;   - P2 res-add-cookie and res-expire-cookie take exactly what the rules
;;;     take, writing the field they write, and refuse the rest with the
;;;     rules' assertion violation, its who, message and irritants: names,
;;;     values and options drawn from every kind the interface takes, bad
;;;     characters, the empty string, what is no string, sizes at 4096 and
;;;     1024 and a step past, constructors given bare, what no constructor
;;;     made, an option twice, and what is no response; and responses that
;;;     hold a set-cookie field of the name already, as res-add-cookie
;;;     writes one or as a hand might, spaced, in a field named in any case,
;;;     beside ones that hold the name where it sets no cookie;
;;;   - P3 req-cookies reads any cookie fields as the design's rules do, and
;;;     req-cookie answers the first of each name: fields drawn from ;, =,
;;;     spaces, tabs, quotes, letters, controls, Latin-1 and characters
;;;     past 255, in cookie fields named in any case, and fields of other
;;;     names that hold cookies too.
;;;
;;; A property's actual value is its failing cases, each shrunk, and its
;;; expected value '(). Each failing case is also written to stdout as
;;; data, with the seed and the case's index, ready to paste.
;;;
;;; Arguments, after the program: [SEED [MULTIPLIER]]. make test gives
;;; none, so the seed and the case counts are the fixed ones. Each case's
;;; random state comes from the seed and its index alone, mixed by murmur3's
;;; finalizer, then drawn on through a linear congruential sequence, so a
;;; seed means the same everywhere.
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (only (circuit response) make-res res-headers)
        (only (circuit test) make-test-req)
        (circuit cookies))

(define runner (test-runner-simple))
(test-runner-current runner)

;; --- the arguments ------------------------------------------------------------

(define default-seed 20261031)
(define default-multiplier 1)

;; parse-arguments : (Listof String) -> (U (List Nat Nat) #f)
;; The seed and the multiplier, defaults where not given; #f when one given
;; is not a whole number, or the multiplier is 0, or there are more.
(define (parse-arguments args)
  (let ((nat (lambda (text)
               (let ((n (string->number text)))
                 (and n (integer? n) (exact? n) (>= n 0) n)))))
    (cond ((null? args) (list default-seed default-multiplier))
          ((null? (cdr args))
           (let ((s (nat (car args)))) (and s (list s default-multiplier))))
          ((null? (cddr args))
           (let* ((s (nat (car args))) (m (nat (cadr args))))
             (and s m (> m 0) (list s m))))
          (else #f))))

(define parsed-arguments (parse-arguments (cdr (command-line))))
(define seed (if parsed-arguments (car parsed-arguments) default-seed))
(define multiplier (if parsed-arguments (cadr parsed-arguments) default-multiplier))

;; --- lists --------------------------------------------------------------------

(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))
(define (take xs n) (if (= n 0) '() (cons (car xs) (take (cdr xs) (- n 1)))))
(define (remove-at xs i) (append (take xs i) (list-tail xs (+ i 1))))
(define (replace-at xs i x) (append (take xs i) (list x) (list-tail xs (+ i 1))))
(define (concat-map f xs) (fold-right (lambda (x acc) (append (f x) acc)) '() xs))

;; --- random: a linear congruential sequence, threaded ---------------------------

;; Gen a = Nat -> (Pair a Nat): a draw takes the state and answers the
;; value and the next state. draw* binds draws in turn, each from the state
;; the one before left, so no two draws are ever arguments of one call.

;; next-random : Nat -> Nat
(define (next-random x) (mod (+ (* x 1103515245) 12345) 2147483648))

(define-syntax draw*
  (syntax-rules ()
    ((_ s () body0 body ...) (let () body0 body ...))
    ((_ s ((x g) more ...) body0 body ...)
     (let* ((drawn (g s)) (x (car drawn)) (s (cdr drawn)))
       (draw* s (more ...) body0 body ...)))))

;; mix : Nat -> Nat
;; murmur3's 32-bit finalizer, taken modulo 2^31: each bit of X moves about
;; half the bits of the answer.
(define (mix x)
  (let* ((x (mod x 4294967296))
         (x (bitwise-xor x (bitwise-arithmetic-shift-right x 16)))
         (x (mod (* x #x85ebca6b) 4294967296))
         (x (bitwise-xor x (bitwise-arithmetic-shift-right x 13)))
         (x (mod (* x #xc2b2ae35) 4294967296))
         (x (bitwise-xor x (bitwise-arithmetic-shift-right x 16))))
    (mod x 2147483648)))

;; case-state : Nat Nat -> Nat
;; Property PROP's case INDEX's first state, from the seed alone.
(define (case-state prop index)
  (mix (+ (mix (+ (mix seed) prop)) index)))

;; g-int : Nat -> Gen Nat
;; A whole number in [0, n), n at most 32768, each equally likely: the
;; state's bits 16 to 30, drawn again while they are at or above the largest
;; multiple of n not above 32768.
(define (g-int n)
  (let ((limit (* n (div 32768 n))))
    (lambda (s)
      (let retry ((s (next-random s)))
        (let ((bits (div s 65536)))
          (if (< bits limit)
              (cons (mod bits n) s)
              (retry (next-random s))))))))

;; g-range : Nat Nat -> Gen Nat
;; A whole number in [lo, hi], hi - lo under 2^30.
(define (g-range lo hi)
  (let ((n (+ (- hi lo) 1)))
    (if (<= n 32768)
        (lambda (s) (draw* s ((i (g-int n))) (cons (+ lo i) s)))
        (let ((blocks (div (+ n 32767) 32768)))
          (lambda (s)
            (let retry ((s s))
              (draw* s ((a (g-int blocks)) (b (g-int 32768)))
                (let ((x (+ (* a 32768) b)))
                  (if (< x n) (cons (+ lo x) s) (retry s))))))))))

(define (g-pick xs) (lambda (s) (draw* s ((i (g-int (length xs)))) (cons (list-ref xs i) s))))

;; g-weighted : (Listof (Pair Nat a)) -> Gen a
(define (g-weighted pairs)
  (let ((total (fold-left + 0 (map car pairs))))
    (lambda (s)
      (draw* s ((i (g-int total)))
        (cons (let loop ((ps pairs) (i i))
                  (if (< i (caar ps)) (cdar ps) (loop (cdr ps) (- i (caar ps)))))
                s)))))

;; g-choose : (Listof (Pair Nat (Gen a))) -> Gen a
(define (g-choose pairs)
  (let ((pick (g-weighted pairs)))
    (lambda (s) (draw* s ((g pick)) (g s)))))

;; g-list : Nat (Gen a) -> Gen (Listof a)
(define (g-list n g)
  (lambda (s)
    (let loop ((i 0) (acc '()) (s s))
      (if (= i n)
          (cons (reverse acc) s)
          (draw* s ((x g)) (loop (+ i 1) (cons x acc) s))))))


;; --- the runner and the shrinker --------------------------------------------------

;; safe-check : (Case -> (U #f Evidence)) Case -> (U #f Evidence)
;; A raise in a check is a failing case, so one raise hides no other.
(define (safe-check check kase)
  (guard (e (#t (list 'check-raised (describe e))))
    (check kase)))

;; shrink : Case (Case -> (U #f Evidence)) (Case -> (Listof Case)) -> Case
;; The first smaller case that still fails, again and again.
(define (shrink kase check shrinks)
  (let loop ((kase kase) (steps 0))
    (if (>= steps 500)
        kase
        (let ((next (find (lambda (c) (safe-check check c)) (shrinks kase))))
          (if next (loop next (+ steps 1)) kase)))))

(define shrunk-at-most 3)

;; property-failures : Symbol Nat (Nat -> Case) Check Shrinks -> (Listof Failure)
;; Runs N cases; shrinks the first failures; reports each on stdout.
(define (property-failures name n gen-case check shrinks tally)
  (let loop ((i 0) (found '()) (failed 0))
    (if (= i n)
        (begin
          (summary! name n failed tally)
          (append (reverse found)
                  (if (> failed (length found)) (list (list 'and (- failed (length found)) 'more)) '())))
        (let* ((kase (gen-case i))
               (evidence (safe-check check kase)))
          (cond ((not evidence) (loop (+ i 1) found failed))
                ((< (length found) shrunk-at-most)
                 (let* ((small (shrink kase check shrinks))
                        (failure (list name 'seed seed 'case i 'minimised small
                                       'evidence (safe-check check small))))
                   (report! failure)
                   (loop (+ i 1) (cons failure found) (+ failed 1))))
                (else (loop (+ i 1) found (+ failed 1))))))))

(define (report! failure)
  (let ((out (current-output-port)))
    (put-string out "cookies-properties: failing case:\n")
    (write failure out)
    (newline out)
    (flush-output-port out)))

;; Tallies: what the cases drew, counted per property.
(define (make-tally) (vector '()))
(define (tally-counts t) (vector-ref t 0))
(define (tally! t key)
  (let* ((counts (tally-counts t)) (p (assq key counts)))
    (vector-set! t 0 (cons (cons key (if p (+ (cdr p) 1) 1))
                           (filter (lambda (q) (not (eq? (car q) key))) counts)))))

(define (summary! name ran failed tally)
  (let ((out (current-output-port))
        (counts (list-sort (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b))))
                           (tally-counts tally))))
    (put-string out (string-append "cookies-properties: " (symbol->string name) ": "
                                   (number->string ran) " cases, " (number->string failed) " failing"))
    (unless (null? counts)
      (put-string out " (")
      (let loop ((cs counts) (first? #t))
        (unless (null? cs)
          (unless first? (put-string out ", "))
          (put-string out (string-append (symbol->string (caar cs)) " " (number->string (cdar cs))))
          (loop (cdr cs) #f)))
      (put-string out ")"))
    (newline out)
    (flush-output-port out)))


;; map-in-order : (a -> b) (Listof a) -> (Listof b)
;; map, calling F on each element in turn: map's order is unspecified.
(define (map-in-order f xs)
  (let loop ((xs xs) (out '()))
    (if (null? xs) (reverse out) (loop (cdr xs) (cons (f (car xs)) out)))))

(define (string-shrinks s)
  (map (lambda (i) (string-append (substring s 0 i) (substring s (+ i 1) (string-length s))))
       (iota (string-length s))))

;; --- characters and strings ------------------------------------------------------

(define (char-string n) (string (integer->char n)))

;; The RFC's sets, as its ranges.
(define (cookie-octet? n)
  (or (= n #x21) (<= #x23 n #x2B) (<= #x2D n #x3A) (<= #x3C n #x5B) (<= #x5D n #x7E)))
(define (tchar? n)
  (or (<= 48 n 57) (<= 65 n 90) (<= 97 n 122)
      (and (memv n (map char->integer (string->list "!#$%&'*+-.^_`|~"))) #t)))
(define (av-octet? n) (or (<= #x20 n #x3A) (<= #x3C n #x7E)))

(define (all? ok? s) (for-all (lambda (c) (ok? (char->integer c))) (string->list s)))

(define tchars (filter (lambda (c) (tchar? (char->integer c))) (map integer->char (iota 128))))
(define octet-chars (filter (lambda (c) (cookie-octet? (char->integer c))) (map integer->char (iota 128))))

(define (lower s)
  (list->string (map (lambda (c) (if (char<=? #\A c #\Z) (integer->char (+ (char->integer c) 32)) c))
                     (string->list s))))

;; ci-prefix? : String String -> Boolean — whether S begins with P, in any ASCII case.
(define (ci-prefix? s p)
  (and (>= (string-length s) (string-length p))
       (string=? (lower (substring s 0 (string-length p))) (lower p))))

(define (insert-at text i piece)
  (string-append (substring text 0 i) piece (substring text i (string-length text))))

;; --- generators ----------------------------------------------------------------------

(define (g-string-of g lo hi)
  (lambda (s) (draw* s ((n (g-range lo hi)) (cs (g-list n g))) (cons (list->string cs) s))))

(define (flip-case c)
  (cond ((char<=? #\a c #\z) (char-upcase c))
        ((char<=? #\A c #\Z) (char-downcase c))
        (else c)))

;; g-cased : String -> Gen String — TEXT, each letter's case drawn.
(define (g-cased text)
  (lambda (s)
    (draw* s ((flips (g-list (string-length text) (g-int 2))))
      (cons (list->string (map (lambda (c f) (if (= f 1) (flip-case c) c)) (string->list text) flips)) s))))

(define bad-chars
  (map char-string '(32 9 61 59 44 34 92 40 41 0 1 13 127 #xE9 #xFF #x100 #x10FFFF)))

;; with-bad : (Gen String) -> Gen String — a string of G with a bad character put in.
(define (with-bad g)
  (lambda (s)
    (draw* s ((text g) (bad (g-pick bad-chars)) (i (g-range 0 (string-length text))))
      (cons (insert-at text i bad) s))))

(define (g-tagged tag g) (lambda (s) (draw* s ((x g)) (cons (cons tag x) s))))

;; g-name : Boolean -> Gen (Pair Symbol Any) — a name, and its kind; with
;; WILD, names res-add-cookie refuses too.
(define (g-name wild)
  (g-choose
   (append
    (list (cons 10 (g-tagged 'plain (g-string-of (g-pick tchars) 1 8)))
          (cons 4 (g-tagged 'prefixed
                            (lambda (s)
                              (draw* s ((p (g-pick '("__Secure-" "__Host-"))) (cased (g-cased p))
                                        (rest (g-string-of (g-pick tchars) 0 5)))
                                (cons (string-append cased rest) s)))))
          (cons 1 (g-tagged 'near-prefix
                            (lambda (s)
                              (draw* s ((p (g-pick '("__Secure" "_Host-" "__Host_" "x__Host-" "__Hos" "__Secure_")))
                                        (rest (g-string-of (g-pick tchars) 0 3)))
                                (cons (string-append p rest) s)))))
          (cons 1 (g-tagged 'long (lambda (s) (draw* s ((n (g-range 4090 4097))) (cons (make-string n #\n) s))))))
    (if wild
        (list (cons 3 (g-tagged 'bad-char (with-bad (g-string-of (g-pick tchars) 0 4))))
              (cons 1 (g-tagged 'empty (g-pick '(""))))
              (cons 1 (g-tagged 'not-a-string (g-pick '(a #f 7)))))
        '()))))

;; g-value : Boolean -> Gen (Pair Symbol Any)
(define (g-value wild)
  (g-choose
   (append
    (list (cons 8 (g-tagged 'octets (g-string-of (g-pick octet-chars) 0 8)))
          (cons 3 (g-tagged 'quoted (lambda (s) (draw* s ((v (g-string-of (g-pick octet-chars) 0 6)))
                                                  (cons (string-append "\"" v "\"") s)))))
          (cons 1 (g-tagged 'empty (g-pick '("")))))
    (if wild
        (list (cons 3 (g-tagged 'bad-char (with-bad (g-string-of (g-pick octet-chars) 0 4))))
              (cons 1 (g-tagged 'bad-quoted (lambda (s) (draw* s ((v (with-bad (g-string-of (g-pick octet-chars) 0 3))))
                                                          (cons (string-append "\"" v "\"") s)))))
              (cons 1 (g-tagged 'stray-quote (g-pick '("\"" "\"x" "x\"" "\"\"\"" "x\"y"))))
              (cons 1 (g-tagged 'not-a-string (g-pick '(1 #f v)))))
        '()))))

(define long-path-1024 (string-append "/" (make-string 1023 #\p)))
(define long-path-1025 (string-append "/" (make-string 1024 #\p)))

;; An option, as data: (cookie-path "/a"), (cookie-secure), (bare
;; cookie-secure) for a constructor given bare, or (junk X) for what no
;; constructor made.
(define (g-option wild)
  (g-choose
   (append
    (list (cons 4 (g-tagged 'path (lambda (s) (draw* s ((p (g-pick (list "/" "/a" "/a/b/" "/x y" "/x " "/~" "/a%20b|c" long-path-1024))))
                                                (cons (list 'cookie-path p) s)))))
          (cons 3 (g-tagged 'domain (lambda (s) (draw* s ((d (g-pick (list "site.example" ".site.example" "Site.Example"
                                                                          "a.b.c" " a.b.c" "." "localhost:8080" "_x.Example"
                                                                          (make-string 1024 #\d)))))
                                                  (cons (list 'cookie-domain d) s)))))
          (cons 3 (g-tagged 'max-age (lambda (s) (draw* s ((n (g-pick (list 1 2 60 34560000 34560001 (expt 2 100) (- (expt 10 1024) 1)))))
                                                   (cons (list 'cookie-max-age n) s)))))
          (cons 4 (g-tagged 'secure (g-pick '((cookie-secure)))))
          (cons 3 (g-tagged 'http-only (g-pick '((cookie-http-only)))))
          (cons 3 (g-tagged 'same-site (lambda (s) (draw* s ((m (g-pick '(strict lax none))))
                                                     (cons (list 'cookie-same-site m) s))))))
    (if wild
        (list (cons 2 (g-tagged 'bad-path (lambda (s) (draw* s ((p (g-pick (list "" "a" "/a;b" "/x " "/ " "/a?b" "/a\\b" "/caf\xE9;" "/\x1;" "/\x7F;"
                                                                                 "/\x100;" long-path-1025 'p))))
                                                        (cons (list 'cookie-path p) s)))))
              (cons 2 (g-tagged 'bad-domain (lambda (s) (draw* s ((d (g-pick (list "" "." "a;b" " site.example" "site.example " " " "a/b" "[::1]" "caf\xE9;.example" "\x0;"
                                                                                   (string-append "." (make-string 1024 #\d))
                                                                                   (make-string 1025 #\d) #f))))
                                                          (cons (list 'cookie-domain d) s)))))
              (cons 2 (g-tagged 'bad-max-age (lambda (s) (draw* s ((n (g-pick (list 0 -1 1.5 "60" 1/2 3/2 (- (expt 2 100)) (expt 10 1024)))))
                                                           (cons (list 'cookie-max-age n) s)))))
              (cons 1 (g-tagged 'bad-same-site (lambda (s) (draw* s ((m (g-pick '(Lax "lax" other #f))))
                                                             (cons (list 'cookie-same-site m) s)))))
              (cons 1 (g-tagged 'bare (lambda (s) (draw* s ((k (g-pick '(cookie-path cookie-domain cookie-max-age cookie-secure
                                                                         cookie-http-only cookie-same-site))))
                                                    (cons (list 'bare k) s)))))
              (cons 1 (g-tagged 'junk (lambda (s) (draw* s ((x (g-pick '("Secure" #f path))))
                                                    (cons (list 'junk x) s))))))
        '()))))

;; g-held : Any Boolean -> Gen (Pair Symbol Headers)
;; The response's own fields beside the cookie NAME, and their kind:
;; set-cookie fields of other names, and NAME where a field sets no cookie
;; of it; with WILD, fields that set NAME too.
(define (g-held name wild)
  (if (or (not (string? name)) (string=? name ""))
      (g-tagged 'held-base (g-pick (list base-headers)))
      (let ((one (lambda (text) (list (cons "set-cookie" text))))
            (n (string-length name)))
        (g-choose
         (append
          (list (cons 4 (g-tagged 'held-base (g-pick (list base-headers))))
                (cons 1 (g-tagged 'held-none (g-pick '(()))))
                (cons 3 (g-tagged 'held-other
                                  (g-pick (list (one (string-append name "x=0")) (one (string-append "x" name "=0"))
                                                (one (if (> n 1) (string-append (substring name 0 (- n 1)) "=0") "y=0"))
                                                (one (string-append "z=0; " name "=1")) (one (string-append "z=" name))
                                                (one name) (one (string-append name "; Path=/"))
                                                (one (string-append "x;" name "=0")) (one (string-append name ";=0"))
                                                (list (cons "x-set-cookie" (string-append name "=0")))
                                                (list (cons "cookie" (string-append name "=0")))))))
                (cons 1 (g-tagged 'held-cased (lambda (s) (draw* s ((cased (g-cased name)))
                                                            (cons (one (string-append cased "=0")) s))))))
          (if wild
              (list (cons 4 (g-tagged 'held-same
                                      (lambda (s)
                                        (draw* s ((before (g-pick '("" " " "\t" " \t"))) (after (g-pick '("" " " "\t" " \t")))
                                                  (field (g-pick '("set-cookie" "Set-Cookie" "SET-COOKIE")))
                                                  (rest (g-pick '("0" "" "0; Path=/x; Secure" " 0 ")))
                                                  (later (g-int 2)))
                                          (cons (append (if (= later 0) '() base-headers)
                                                        (list (cons field (string-append before name after "=" rest))))
                                                s))))))
              '()))))))

;; A spec: (KIND RES NAME VALUE OPTIONS), KIND add or expire, RES the
;; response's own fields or not-a-response, OPTIONS a list of options as
;; data.
(define (spec-kind spec) (list-ref spec 0))
(define (spec-res spec) (list-ref spec 1))
(define (spec-name spec) (list-ref spec 2))
(define (spec-value spec) (list-ref spec 3))
(define (spec-options spec) (list-ref spec 4))

;; g-spec : Boolean -> Gen (Pair (Listof Symbol) Spec)
;; A spec and the kinds it drew. Without WILD, an option is never given
;; twice, and a prefixed name, or SameSite=None, is mostly given what it
;; needs, so most specs are taken.
(define (g-spec wild)
  (lambda (s)
    (draw* s ((expire (g-int 4)) (not-res (g-int 40)) (name (g-name wild)) (held (g-held (cdr name) wild))
              (value (g-value wild))
              (sized (g-int 12)) (total (g-range 4095 4097))
              (n (g-weighted '((2 . 0) (3 . 1) (3 . 2) (2 . 3) (1 . 4) (1 . 5)))) (options (g-list n (g-option wild)))
              (fix (g-int 10)))
      (let* ((kind (if (= expire 0) 'expire 'add))
             (res (if (and wild (= not-res 0)) 'not-a-response (cdr held)))
             (sized? (and (= sized 0) (string? (cdr name)) (>= total (string-length (cdr name)))))
             (value-text (if sized? (make-string (- total (string-length (cdr name))) #\v) (cdr value)))
             (descs (map cdr options))
             (descs (if wild descs (once-each descs)))
             (descs (if (or wild (< fix 3)) descs (needs (cdr name) descs)))
             (tags (append (list kind (car name) (car held)) (if sized? '(sized) (list (car value)))
                           (map car options))))
        (cons (cons tags (list kind res (cdr name) value-text descs)) s)))))

;; once-each : (Listof Option) -> (Listof Option) — the first option of each constructor.
(define (once-each descs)
  (let loop ((ds descs) (seen '()) (out '()))
    (cond ((null? ds) (reverse out))
          ((memq (caar ds) seen) (loop (cdr ds) seen out))
          (else (loop (cdr ds) (cons (caar ds) seen) (cons (car ds) out))))))

;; needs : Any (Listof Option) -> (Listof Option)
;; DESCS with what NAME's prefix, or SameSite=None, needs: Secure; for
;; __Host-, Path=/ and no Domain.
(define (needs name descs)
  (let* ((host? (and (string? name) (ci-prefix? name "__Host-")))
         (secure? (or host? (and (string? name) (ci-prefix? name "__Secure-"))
                      (member '(cookie-same-site none) descs)))
         (descs (if host?
                    (append (remp (lambda (d) (memq (car d) '(cookie-path cookie-domain))) descs) '((cookie-path "/")))
                    descs)))
    (if (and secure? (not (assq 'cookie-secure descs))) (append descs '((cookie-secure))) descs)))

;; --- running a spec ------------------------------------------------------------------

(define base-headers '(("set-cookie" . "x=0") ("content-type" . "text/plain")))

(define (constructor name)
  (case name
    ((cookie-path) cookie-path) ((cookie-domain) cookie-domain) ((cookie-max-age) cookie-max-age)
    ((cookie-secure) cookie-secure) ((cookie-http-only) cookie-http-only) ((cookie-same-site) cookie-same-site)))

;; build-options : (Listof Option) -> (Listof Any)
;; Each option made, in order, so the first one refused raises.
(define (build-options descs)
  (let loop ((ds descs) (out '()))
    (if (null? ds)
        (reverse out)
        (let* ((d (car ds))
               (made (case (car d)
                       ((bare) (constructor (cadr d)))
                       ((junk) (cadr d))
                       (else (apply (constructor (car d)) (cdr d))))))
          (loop (cdr ds) (cons made out))))))

;; raised : (-> Any) -> Any
;; What THUNK raised: (refused WHO MESSAGE IRRITANTS) for an assertion
;; violation, (other-raise X) for anything else, and (returned V) if it
;; returned V.
(define (raised thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (message-condition? e)
                  (irritants-condition? e))
             (list 'refused (condition-who e) (condition-message e) (condition-irritants e)))
            ((condition? e) (list 'other-raise (describe e)))
            (#t (list 'other-raise e)))
    (list 'returned (thunk))))

;; run-spec : Spec -> Any — what writing SPEC answers: the headers, or the raise.
(define (run-spec spec)
  (raised (lambda ()
            (let* ((options (build-options (spec-options spec)))
                   (res (if (list? (spec-res spec)) (make-res 200 (spec-res spec) "hi") 'not-a-response)))
              (res-headers
               (if (eq? (spec-kind spec) 'add)
                   (apply res-add-cookie res (spec-name spec) (spec-value spec) options)
                   (apply res-expire-cookie res (spec-name spec) options)))))))

(define epoch "Thu, 01 Jan 1970 00:00:00 GMT")

;; --- the browser's model: §5.6 and §5.7 ----------------------------------------------

(define (wsp? c) (or (char=? c #\space) (char=? c #\tab)))

(define (trim-wsp s)
  (let* ((cs (string->list s))
         (cs (let drop ((cs cs)) (if (and (pair? cs) (wsp? (car cs))) (drop (cdr cs)) cs)))
         (cs (reverse (let drop ((cs (reverse cs))) (if (and (pair? cs) (wsp? (car cs))) (drop (cdr cs)) cs)))))
    (list->string cs)))

;; first-index : String Char -> (U Nat #f)
(define (first-index s c)
  (let loop ((i 0))
    (cond ((= i (string-length s)) #f)
          ((char=? (string-ref s i) c) i)
          (else (loop (+ i 1))))))

(define (digit? c) (char<=? #\0 c #\9))

;; attribute : String String -> (U (Pair Symbol Any) #f)
;; §5.6.1 to §5.6.7: the attribute a browser reads from a cookie-av, or #f.
(define (attribute name value)
  (let ((name (lower name)))
    (cond ((string=? name "expires") (cons 'expires value))
          ((string=? name "max-age")
           (let ((cs (string->list value)))
             (and (pair? cs)
                  (or (digit? (car cs)) (and (char=? (car cs) #\-) (pair? (cdr cs)) (digit? (cadr cs))))
                  (for-all digit? (cdr cs))
                  (cons 'max-age (string->number value)))))
          ((string=? name "domain")
           (cons 'domain (lower (if (and (> (string-length value) 0) (char=? (string-ref value 0) #\.))
                                    (substring value 1 (string-length value))
                                    value))))
          ((string=? name "path")
           (cons 'path (if (or (string=? value "") (not (char=? (string-ref value 0) #\/))) 'default value)))
          ((string=? name "secure") (cons 'secure #t))
          ((string=? name "httponly") (cons 'http-only #t))
          ((string=? name "samesite")
           (cons 'same-site (let ((v (lower value)))
                              (cond ((string=? v "none") "None") ((string=? v "strict") "Strict")
                                    ((string=? v "lax") "Lax") (else "Default")))))
          (else #f))))

;; attributes : String -> (Listof (Pair Symbol Any)) — §5.6's unparsed-attributes, read.
(define (attributes text)
  (let loop ((rest text) (out '()))
    (if (string=? rest "")
        (reverse out)
        (let* ((rest (substring rest 1 (string-length rest)))
               (semi (first-index rest #\;))
               (av (substring rest 0 (or semi (string-length rest))))
               (rest (if semi (substring rest semi (string-length rest)) ""))
               (eq (first-index av #\=))
               (name (trim-wsp (if eq (substring av 0 eq) av)))
               (value (trim-wsp (if eq (substring av (+ eq 1) (string-length av)) ""))))
          (loop rest (let ((a (and (<= (string-length value) 1024) (attribute name value))))
                       (if a (cons a out) out)))))))

(define (last-of attrs key)
  (let ((hits (filter (lambda (a) (eq? (car a) key)) attrs)))
    (and (pair? hits) (cdr (list-ref hits (- (length hits) 1))))))

;; stored : String -> (U (List String String Path Domain MaxAge Expires
;;                              Boolean Boolean String) #f)
;; The cookie a browser stores from the set-cookie field TEXT, or #f for
;; one it ignores: Path is 'default-path without a Path attribute, Domain
;; #f for a host-only cookie.
(define (stored text)
  (and (not (exists (lambda (c) (let ((n (char->integer c))) (or (<= 0 n 8) (<= #x0A n #x1F) (= n #x7F))))
                    (string->list text)))
       (let* ((semi (first-index text #\;))
              (pair (substring text 0 (or semi (string-length text))))
              (attrs (attributes (if semi (substring text semi (string-length text)) "")))
              (eq (first-index pair #\=))
              (name (trim-wsp (if eq (substring pair 0 eq) "")))
              (value (trim-wsp (if eq (substring pair (+ eq 1) (string-length pair)) pair)))
              (max-age (last-of attrs 'max-age))
              (expires (and (not max-age) (last-of attrs 'expires)))
              (domain (or (last-of attrs 'domain) ""))
              (path-attr (last-of attrs 'path))
              (path (if (and path-attr (not (eq? path-attr 'default))) path-attr 'default-path))
              (secure? (and (last-of attrs 'secure) #t))
              (same-site (let ((ss (last-of attrs 'same-site)))
                           (if (and ss (member ss '("Strict" "Lax" "None"))) ss "Default"))))
         (cond ((> (+ (string-length name) (string-length value)) 4096) #f)
               ((and (string=? name "") (string=? value "")) #f)
               ((exists (lambda (c) (> (char->integer c) #x7F)) (string->list domain)) #f)
               ((and (string=? same-site "None") (not secure?)) #f)
               ((and (ci-prefix? name "__Secure-") (not secure?)) #f)
               ((and (ci-prefix? name "__Host-")
                     (not (and secure? (string=? domain "") path-attr (equal? path "/"))))
                #f)
               ((and (string=? name "") (or (ci-prefix? value "__Secure-") (ci-prefix? value "__Host-"))) #f)
               (else (list name value path (if (string=? domain "") #f domain) max-age expires
                           secure? (and (last-of attrs 'http-only) #t) same-site))))))

;; meant : Spec -> List — the cookie SPEC asks a browser to store, as stored has it.
(define (meant spec)
  (let* ((descs (spec-options spec))
         (setting (lambda (k) (let ((d (assq k descs))) (and d (if (null? (cdr d)) #t (cadr d))))))
         (domain (setting 'cookie-domain))
         (domain (and domain (lower (if (char=? (string-ref domain 0) #\.)
                                        (substring domain 1 (string-length domain))
                                        domain))))
         (add? (eq? (spec-kind spec) 'add)))
    (list (spec-name spec) (if add? (spec-value spec) "")
          (or (setting 'cookie-path) 'default-path)
          (and domain (if (string=? domain "") 'lost domain))
          (and add? (setting 'cookie-max-age))
          (if add? #f epoch)
          (and (setting 'cookie-secure) #t) (and (setting 'cookie-http-only) #t)
          (case (setting 'cookie-same-site) ((strict) "Strict") ((lax) "Lax") ((none) "None") (else "Default")))))

;; --- the rules: what the design refuses, in its order ---------------------------------

(define (refusal who message . irritants) (list 'refused who message irritants))

(define messages
  `((not-a-request . "not a request")
    (not-a-response . "not a response")
    (name-string . "a cookie name is a string")
    (name-token . "a cookie name is a token: letters, digits and !#$%&'*+-.^_`|~, at least one")
    (value-string . "a cookie value is a string")
    (value-octets . ,(string-append "a cookie value is cookie-octets, bare or between two quotes: encode a space,"
                                    " a quote, a comma, a semicolon, a backslash, a control or anything past"
                                    " ASCII first"))
    (too-big . "a cookie's name and value are at most 4096 bytes together: a browser ignores a longer one")
    (path-string . "a path is a string")
    (path-chars . "a path holds ASCII from a space to ~ alone, with no ;")
    (path-long . "a path is at most 1024 bytes: a browser ignores a longer one")
    (path-slash . "a path starts with /: a browser ignores any other")
    (path-url . ,(string-append "a path holds no space, \", #, <, >, ?, ^, `, {, } or \\:"
                                " a URL's path never does, so a browser would never send the cookie"))
    (domain-string . "a domain is a string")
    (domain-chars . "a domain holds ASCII from a space to ~ alone, with no ;")
    (domain-long . "a domain is at most 1024 bytes: a browser ignores a longer one")
    (domain-empty . "a domain is not empty, nor . alone: a browser reads either as no Domain")
    (domain-host . ,(string-append "a domain holds no space, #, %, /, :, <, >, ?, @, [, \\, ], ^ or |:"
                                   " no host does, so a browser ignores the cookie"))
    (max-age-count . "a max-age is a whole number of seconds, at least 1: res-expire-cookie expires a cookie")
    (max-age-digits . "a max-age is at most 1024 digits: a browser ignores a longer one")
    (same-site-kind . "a same-site is strict, lax or none")
    (none-secure . "SameSite=None needs cookie-secure: a browser ignores the cookie without it")
    (secure-prefix . "a __Secure- name needs cookie-secure: a browser ignores the cookie without it")
    (host-prefix . ,(string-append "a __Host- name needs cookie-secure and (cookie-path \"/\"), and no cookie-domain:"
                                   " a browser ignores the cookie otherwise"))
    (once . "each option once")
    (bare . "an option's constructor, given bare: call it")
    (no-option . "an option is what a cookie- constructor makes")
    (no-max-age . "res-expire-cookie takes no max-age: its date in the past expires the cookie")
    (name-once . "a response sets each cookie name once: it holds a set-cookie field of this name already")))

(define (message key) (cdr (assq key messages)))

;; option-refusal : Option -> (U Refusal #f) — what making the option D raises.
(define (option-refusal d)
  (let ((arg (and (pair? (cdr d)) (cadr d))))
    (case (car d)
      ((cookie-path)
       (cond ((not (string? arg)) (refusal 'cookie-path (message 'path-string) arg))
             ((not (all? av-octet? arg)) (refusal 'cookie-path (message 'path-chars) arg))
             ((exists (lambda (c) (memv c (string->list " \"#<>?^`{}\\"))) (string->list arg))
              (refusal 'cookie-path (message 'path-url) arg))
             ((> (string-length arg) 1024) (refusal 'cookie-path (message 'path-long) arg))
             ((not (ci-prefix? arg "/")) (refusal 'cookie-path (message 'path-slash) arg))
             (else #f)))
      ((cookie-domain)
       (cond ((not (string? arg)) (refusal 'cookie-domain (message 'domain-string) arg))
             ((member arg '("" ".")) (refusal 'cookie-domain (message 'domain-empty) arg))
             ((not (all? av-octet? arg)) (refusal 'cookie-domain (message 'domain-chars) arg))
             ((exists (lambda (c) (memv c (string->list " #%/:<>?@[\\]^|"))) (string->list arg))
              (refusal 'cookie-domain (message 'domain-host) arg))
             ((> (string-length arg) 1024) (refusal 'cookie-domain (message 'domain-long) arg))
             (else #f)))
      ((cookie-max-age)
       (cond ((not (and (integer? arg) (exact? arg) (>= arg 1))) (refusal 'cookie-max-age (message 'max-age-count) arg))
             ((> (string-length (number->string arg)) 1024) (refusal 'cookie-max-age (message 'max-age-digits) arg))
             (else #f)))
      ((cookie-same-site)
       (and (not (memq arg '(strict lax none)))
            (refusal 'cookie-same-site (message 'same-site-kind) arg)))
      (else #f))))

(define (cookie-value? v)
  (let ((n (string-length v)))
    (or (all? cookie-octet? v)
        (and (>= n 2) (char=? (string-ref v 0) #\") (char=? (string-ref v (- n 1)) #\")
             (all? cookie-octet? (substring v 1 (- n 1)))))))

;; rules : Spec -> Any — what writing SPEC answers, by the rules.
(define (rules spec)
  (let* ((descs (spec-options spec))
         (who (if (eq? (spec-kind spec) 'add) 'res-add-cookie 'res-expire-cookie))
         (add? (eq? who 'res-add-cookie))
         (name (spec-name spec))
         (value (if add? (spec-value spec) "")))
    (or (exists option-refusal descs)
        (cond ((not (list? (spec-res spec))) (refusal who (message 'not-a-response) 'not-a-response))
              ((not (string? name)) (refusal who (message 'name-string) name))
              ((not (and (> (string-length name) 0) (all? tchar? name))) (refusal who (message 'name-token) name))
              ((not (string? value)) (refusal who (message 'value-string) value))
              ((not (cookie-value? value)) (refusal who (message 'value-octets) value))
              ((> (+ (string-length name) (string-length value)) 4096)
               (refusal who (message 'too-big) (+ (string-length name) (string-length value))))
              (else (or (exists (lambda (d) (case (car d)
                                              ((bare) (refusal who (message 'bare) (cadr d)))
                                              ((junk) (refusal who (message 'no-option) (cadr d)))
                                              (else #f)))
                                descs)
                        (let loop ((ds descs) (seen '()))
                          (cond ((null? ds) #f)
                                ((memq (caar ds) seen) (refusal who (message 'once) (caar ds)))
                                (else (loop (cdr ds) (cons (caar ds) seen)))))
                        (and (not add?) (assq 'cookie-max-age descs)
                             (refusal who (message 'no-max-age) 'cookie-max-age))
                        (let ((secure? (assq 'cookie-secure descs))
                              (path (assq 'cookie-path descs)))
                          (cond ((and (member '(cookie-same-site none) descs) (not secure?))
                                 (refusal who (message 'none-secure) name))
                                ((and (ci-prefix? name "__Secure-") (not secure?))
                                 (refusal who (message 'secure-prefix) name))
                                ((and (ci-prefix? name "__Host-")
                                      (not (and secure? path (string=? (cadr path) "/")
                                                (not (assq 'cookie-domain descs)))))
                                 (refusal who (message 'host-prefix) name))
                                (else #f)))
                        (and (exists (lambda (f) (and (string=? (lower (car f)) "set-cookie")
                                                      (string=? (held-name (cdr f)) name)))
                                     (spec-res spec))
                             (refusal who (message 'name-once) name))
                        (list 'returned (append (spec-res spec)
                                                (list (cons "set-cookie" (rules-field name value descs add?)))))))))))

;; held-name : String -> String
;; The name a set-cookie field TEXT sets, as §5.6 reads it: in the piece
;; before the first ;, before its first =, less spaces and tabs; "" when
;; that piece holds no =.
(define (held-name text)
  (let* ((semi (first-index text #\;))
         (pair (substring text 0 (or semi (string-length text))))
         (eq (first-index pair #\=)))
    (if eq (trim-wsp (substring pair 0 eq)) "")))

;; rules-field : String String (Listof Option) Boolean -> String
(define (rules-field name value descs add?)
  (let ((arg (lambda (k) (let ((d (assq k descs))) (and d (cadr d)))))
        (flag (lambda (k text) (if (assq k descs) text ""))))
    (string-append
     name "=" value
     (if (arg 'cookie-path) (string-append "; Path=" (arg 'cookie-path)) "")
     (if (arg 'cookie-domain) (string-append "; Domain=" (arg 'cookie-domain)) "")
     (if add?
         (if (arg 'cookie-max-age) (string-append "; Max-Age=" (number->string (arg 'cookie-max-age))) "")
         (string-append "; Expires=" epoch))
     (flag 'cookie-secure "; Secure")
     (flag 'cookie-http-only "; HttpOnly")
     (case (arg 'cookie-same-site)
       ((strict) "; SameSite=Strict") ((lax) "; SameSite=Lax") ((none) "; SameSite=None") (else "")))))

;; --- shrinks -----------------------------------------------------------------------------

;; spec-shrinks : Spec -> (Listof Spec) — SPEC less an option or a field
;; of its response, or with a name or value a character shorter.
(define (spec-shrinks spec)
  (let ((with (lambda (i x) (replace-at spec i x))))
    (append (map (lambda (i) (with 4 (remove-at (spec-options spec) i))) (iota (length (spec-options spec))))
            (if (list? (spec-res spec))
                (map (lambda (i) (with 1 (remove-at (spec-res spec) i))) (iota (length (spec-res spec))))
                '())
            (if (string? (spec-name spec)) (map (lambda (n) (with 2 n)) (string-shrinks (spec-name spec))) '())
            (if (string? (spec-value spec)) (map (lambda (v) (with 3 v)) (string-shrinks (spec-value spec))) '()))))

;; --- P1: what a browser stores, and reads back --------------------------------------------

(define p1-tally (make-tally))

;; A P1 case: (SPECS SPLIT), SPLIT where the cookie string is cut into two
;; fields, or #f for one.
(define (p1-case i)
  (let ((s (case-state 1 i)))
    (draw* s ((n (g-range 1 4)) (specs (g-list n (g-spec #f))) (split (g-int 3)) (at (g-int 4)))
      (let* ((kase (list (map cdr specs) (and (= split 0) at)))
             (taken (filter (lambda (spec) (eq? (car (run-spec spec)) 'returned)) (car kase)))
             (adds (filter (lambda (spec) (eq? (spec-kind spec) 'add)) taken)))
        (for-each (lambda (tagged) (for-each (lambda (tag) (tally! p1-tally tag)) (car tagged))) specs)
        (for-each (lambda (spec) (tally! p1-tally (if (memq spec taken) 'taken 'refused))) (car kase))
        (when (= (length (cookie-fields (map (lambda (spec) (cons (spec-name spec) (spec-value spec))) adds)
                                        (cadr kase)))
                 2)
          (tally! p1-tally 'two-fields))
        kase))))

;; cookie-fields : (Listof (Pair String String)) (U Nat #f) -> (Listof String)
;; COOKIES as a browser serializes them (§5.8.3), in one field, or cut
;; into two before the SPLIT-th cookie.
(define (cookie-fields cookies split)
  (let* ((written (map (lambda (c) (string-append (car c) "=" (cdr c))) cookies))
         (join (lambda (ws) (if (null? ws) "" (fold-left (lambda (out w) (string-append out "; " w)) (car ws) (cdr ws)))))
         (k (and split (< 0 split (length written)) split)))
    (if k
        (list (join (take written k)) (join (list-tail written k)))
        (list (join written)))))

(define (p1-check kase)
  (let* ((specs (car kase))
         (outcomes (map-in-order run-spec specs))
         (taken (filter (lambda (so) (eq? (car (cdr so)) 'returned)) (map cons specs outcomes)))
         (wrong (filter
                 (lambda (so)
                   (let* ((headers (cadr (cdr so)))
                          (field (cdr (list-ref headers (- (length headers) 1)))))
                     (not (and (equal? (list-head headers (- (length headers) 1)) (spec-res (car so)))
                               (equal? (stored field) (meant (car so)))))))
                 taken))
         (cookies (map (lambda (so) (cons (spec-name (car so)) (spec-value (car so))))
                       (filter (lambda (so) (eq? (spec-kind (car so)) 'add)) taken)))
         (fields (cookie-fields cookies (cadr kase)))
         (req (make-test-req 'GET "/" (map (lambda (f) (cons "cookie" f)) fields)))
         (read (req-cookies req))
         (firsts (map-in-order (lambda (c) (req-cookie req (car c))) cookies))
         (meant-firsts (map (lambda (c) (cdr (assoc (car c) cookies))) cookies)))
    (and (or (pair? wrong) (not (equal? read cookies)) (not (equal? firsts meant-firsts)))
         (list 'wrong (map (lambda (so) (list (car so) (stored (cdr (list-ref (cadr (cdr so)) (- (length (cadr (cdr so))) 1))))))
                           wrong)
               'sent fields 'read read 'firsts firsts))))

(define (list-head xs n) (take xs n))

(define (p1-shrinks kase)
  (let ((specs (car kase)))
    (append (map (lambda (i) (list (remove-at specs i) (cadr kase))) (iota (length specs)))
            (concat-map (lambda (i) (map (lambda (sp) (list (replace-at specs i sp) (cadr kase)))
                                         (spec-shrinks (list-ref specs i))))
                        (iota (length specs))))))

(test-equal "P1: a cookie res-add-cookie or res-expire-cookie takes, a browser stores as given, and req-cookies reads back"
  '()
  (property-failures 'P1 (* 2000 multiplier) p1-case p1-check p1-shrinks p1-tally))

;; --- P2: the rules, and nothing else -----------------------------------------------------

(define p2-tally (make-tally))

(define (p2-case i)
  (let ((drawn (car ((g-spec #t) (case-state 2 i)))))
    (for-each (lambda (tag) (tally! p2-tally tag)) (car drawn))
    (tally! p2-tally (let ((expected (rules (cdr drawn))))
                       (cond ((eq? (car expected) 'returned) 'rules-take)
                             ((equal? (caddr expected) (message 'name-once)) 'rules-refuse-once)
                             (else 'rules-refuse))))
    (cdr drawn)))

(define (p2-check spec)
  (let ((actual (run-spec spec))
        (expected (rules spec)))
    (and (not (equal? actual expected))
         (list 'actual actual 'expected expected))))

(test-equal "P2: res-add-cookie and res-expire-cookie take what the rules take, as they write it, and refuse the rest as they refuse it"
  '()
  (property-failures 'P2 (* 5000 multiplier) p2-case p2-check spec-shrinks p2-tally))

;; --- P3: reading -------------------------------------------------------------------------

(define p3-tally (make-tally))

(define g-field-char
  (g-weighted (list (cons 4 #\;) (cons 3 #\=) (cons 3 #\space) (cons 2 #\tab) (cons 1 #\")
                    (cons 4 #\a) (cons 2 #\b) (cons 2 #\A) (cons 1 #\,) (cons 1 #\\)
                    (cons 1 (integer->char 0)) (cons 1 (integer->char 11)) (cons 1 (integer->char 13))
                    (cons 1 (integer->char #xE9)) (cons 1 (integer->char #xFF)) (cons 1 (integer->char #x100))
                    (cons 1 (integer->char #x10FFFF)))))

;; A P3 case: a list of (FIELD-NAME . VALUE).
(define (p3-case i)
  (let ((s (case-state 3 i)))
    (draw* s ((n (g-range 0 3))
              (fields (g-list n (lambda (s)
                                  (draw* s ((name (g-weighted '((3 . "cookie") (1 . "Cookie") (1 . "COOKIE")
                                                                 (1 . "x-cookie") (1 . "set-cookie"))))
                                            (value (g-string-of g-field-char 0 16)))
                                    (cons (cons name value) s))))))
      (for-each (lambda (f) (tally! p3-tally (if (string-ci=? (car f) "cookie") 'cookie-field 'other-field))) fields)
      (for-each (lambda (c) (tally! p3-tally 'cookie)) (read-cookies fields))
      fields)))

(define (split-on cs c)
  (let loop ((cs cs) (piece '()) (out '()))
    (cond ((null? cs) (reverse (cons (reverse piece) out)))
          ((char=? (car cs) c) (loop (cdr cs) '() (cons (reverse piece) out)))
          (else (loop (cdr cs) (cons (car cs) piece) out)))))

(define (trim-list cs)
  (let ((drop (lambda (cs) (let loop ((cs cs)) (if (and (pair? cs) (wsp? (car cs))) (loop (cdr cs)) cs)))))
    (reverse (drop (reverse (drop cs))))))

;; read-cookies : (Listof (Pair String String)) -> (Listof (Pair String String))
;; The design's reading of FIELDS: each cookie field, each piece between ;,
;; split at its first =, the name and value trimmed, an empty name skipped.
(define (read-cookies fields)
  (concat-map
   (lambda (f)
     (if (string-ci=? (car f) "cookie")
         (concat-map (lambda (piece)
                       (let ((at (memv #\= piece)))
                         (if (not at)
                             '()
                             (let ((name (trim-list (list-head piece (- (length piece) (length at)))))
                                   (value (trim-list (cdr at))))
                               (if (null? name) '() (list (cons (list->string name) (list->string value))))))))
                     (split-on (trim-list (string->list (cdr f))) #\;))
         '()))
   fields))

(define (p3-check fields)
  (let* ((req (make-test-req 'GET "/" fields))
         (read (req-cookies req))
         (expected (read-cookies fields))
         (names (append (map car expected) '("a" "A" "b" "")))
         (firsts (map-in-order (lambda (n) (req-cookie req n)) names))
         (meant-firsts (map (lambda (n) (let ((p (assoc n expected))) (and p (cdr p)))) names)))
    (and (not (and (equal? read expected) (equal? firsts meant-firsts)))
         (list 'read read 'expected expected 'firsts firsts 'meant meant-firsts))))

(define (fields-shrinks fields)
  (append (map (lambda (i) (remove-at fields i)) (iota (length fields)))
          (concat-map (lambda (i) (let ((f (list-ref fields i)))
                                    (map (lambda (v) (replace-at fields i (cons (car f) v))) (string-shrinks (cdr f)))))
                      (iota (length fields)))))

(test-equal "P3: req-cookies reads any cookie fields by the design's rules, and req-cookie answers each name's first"
  '()
  (property-failures 'P3 (* 3000 multiplier) p3-case p3-check fields-shrinks p3-tally))


(exit (suite-exit-status runner))
