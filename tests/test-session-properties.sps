#!r6rs
;;; (circuit session), by property: sessions, cookie names, secrets and
;;; clocks generated from a fixed seed.
;;;
;;; The rows:
;;;   - S1 a session handed back with res-with-session, written by
;;;     wrap-session, and sent back as a browser sends it, reads back whole
;;;     through req-session: its names and values drawn as (circuit
;;;     params)'s P1 draws them, the cookie's name from tokens, a __Host-
;;;     name among them, the secret that signed it at any place in a list of
;;;     one to three, and the clock's answer 0, a ten-digit time or a
;;;     bignum;
;;;   - S2 the same cookie, one character changed to another cookie-octet
;;;     at any position, reads no session, and the cookie itself, in the
;;;     same check, reads back whole.
;;;
;;; A property's actual value is its failing cases, each shrunk, and its
;;; expected value '(). Each failing case is also written to stdout as
;;; data, with the seed and the case's index, ready to paste.
;;;
;;; Arguments, after the program: [SEED [MULTIPLIER]]. make test gives
;;; none, so the seed and the case counts are the fixed ones. Each case's
;;; random state comes from the seed and its index alone, mixed by murmur3's
;;; finalizer, then drawn on through a linear congruential sequence, so a
;;; seed means the same everywhere. The generators and the runner are
;;; (circuit params)'s property suite's, copied: a program holds its own
;;; code.
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (only (circuit) make-res wrap res-headers)
        (only (circuit test) make-test-req)
        (circuit session))

(define runner (test-runner-simple))
(test-runner-current runner)

;; --- the arguments ------------------------------------------------------------

(define default-seed 20261106)
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

;; --- strings --------------------------------------------------------------------

;; A piece of a name or a value, each kind tagged, so the tally says what
;; the cases drew. A scalar value is any character but a surrogate, which
;; Scheme has none of.
(define (tagged tag g) (lambda (s) (draw* s ((x g)) (cons (cons tag x) s))))

(define (g-char-in lo hi)
  (lambda (s) (draw* s ((n (g-range lo hi))) (cons (string (integer->char n)) s))))

(define g-piece
  (g-choose
   (list (cons 6 (tagged 'special (g-pick '("=" "&" "+" "%" " "))))
         (cons 4 (tagged 'escape-like (g-pick '("%41" "%2B" "%20" "%%" "%4" "%4g" "%g4" "%C3%A9"
                                                 "%FF" "%EF%BB%BF" "+%2B" "%25"))))
         (cons 6 (tagged 'ascii (g-char-in #x21 #x7E)))
         (cons 2 (tagged 'control (g-pick (map (lambda (n) (string (integer->char n)))
                                               '(0 9 10 13 31 127)))))
         (cons 3 (tagged 'latin-1 (g-char-in #x80 #xFF)))
         (cons 2 (tagged 'bom-or-replacement (g-pick '("\xFEFF;" "\xFFFD;" "\xFFFF;"))))
         (cons 2 (tagged 'two-bytes (g-char-in #x100 #x7FF)))
         (cons 2 (tagged 'three-bytes (g-choose (list (cons 1 (g-char-in #x800 #xD7FF))
                                                      (cons 1 (g-char-in #xE000 #xFFFF))))))
         (cons 2 (tagged 'four-bytes (g-char-in #x10000 #x10FFFF))))))

;; g-string : Gen (Pair (Listof Symbol) String)
;; A string of 0 to 5 pieces, with the kinds it drew.
(define g-string
  (lambda (s)
    (draw* s ((n (g-weighted '((2 . 0) (3 . 1) (3 . 2) (2 . 3) (1 . 5)))) (pieces (g-list n g-piece)))
      (cons (cons (map car pieces) (apply string-append (map cdr pieces))) s))))

;; g-params : Gen (Pair (Listof Symbol) Params)
;; 0 to 6 pairs, a name sometimes one drawn before.
(define g-params
  (lambda (s)
    (draw* s ((n (g-range 0 6)))
      (let loop ((i 0) (tags '()) (out '()) (s s))
        (if (= i n)
            (cons (cons tags (reverse out)) s)
            (draw* s ((again (g-int 4)) (earlier (g-int 6)) (name g-string) (value g-string))
              (let* ((repeat? (and (= again 0) (pair? out)))
                     (tags (append (if repeat? '(repeated-name) '()) (car name) (car value) tags))
                     (pair (cons (if repeat? (car (list-ref out (mod earlier (length out)))) (cdr name))
                                 (cdr value))))
                (loop (+ i 1) tags (cons pair out) s))))))))

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
    (put-string out "session-properties: failing case:\n")
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
    (put-string out (string-append "session-properties: " (symbol->string name) ": "
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

;; params-shrinks : Params -> (Listof Params)
;; PARAMS less a pair, or with one name or value a character shorter.
(define (params-shrinks ps)
  (append (map (lambda (i) (remove-at ps i)) (iota (length ps)))
          (concat-map (lambda (i)
                        (let ((p (list-ref ps i)))
                          (append (map (lambda (n) (replace-at ps i (cons n (cdr p)))) (string-shrinks (car p)))
                                  (map (lambda (v) (replace-at ps i (cons (car p) v))) (string-shrinks (cdr p))))))
                      (iota (length ps)))))

(define (string-shrinks s)
  (map (lambda (i) (string-append (substring s 0 i) (substring s (+ i 1) (string-length s))))
       (iota (string-length s))))

;; --- the case ---------------------------------------------------------------------

;; A case: (NAME SECRETS SIGNER TIME SESSION). The cookie is written by a
;; wrap-session holding (list-ref SECRETS SIGNER) alone and read by one
;; holding SECRETS, whose clock is at TIME too.
(define secrets-pool
  '("kV9n2Qe0w4tX7bYc1LpR8sZ3uJ6mH5aDfG0hN2oT4iU=" "Zx8cV7bN6mL5kJ4hG3fD2sA1qW0eR9tY8uI7oP6aS5d="
    "Mn0bV9cX8zL7kJ6hG5fD4sA3qW2eR1tY0uI9oP8lK7j=" "\xE9;\xE9;\xE9;\xE9;\xE9;\xE9;\xE9;\xE9;\xE9;\xE9;\xE9;\xE9;\xE9;\xE9;\xE9;\xE9;"))

(define g-name
  (g-weighted (list (cons 3 "__Host-session") (cons 2 "sid") (cons 1 "__Host-x.1")
                    (cons 1 "!#$%&'*+-.^_`|~09AZaz"))))

(define g-time
  (g-choose (list (cons 1 (lambda (s) (cons 0 s)))
                  (cons 6 (g-range 1000000000 1999999999))
                  (cons 1 (lambda (s) (cons (expt 2 100) s))))))

(define (gen-case prop tally)
  (lambda (i)
    (let ((s (case-state prop i)))
      (draw* s ((name g-name) (n (g-range 1 3)) (signer (g-int 3)) (first (g-int 4)) (time g-time)
                (drawn g-params))
        (let ((secrets (map (lambda (k) (list-ref secrets-pool (mod (+ first k) 4))) (iota n))))
          (for-each (lambda (tag) (tally! tally tag)) (car drawn))
          (tally! tally (string->symbol (string-append "signer-" (number->string (mod signer n)) "-of-"
                                                       (number->string n))))
          (when (null? (cdr drawn)) (tally! tally 'empty-session))
          (tally! tally (if (string=? name "__Host-session") 'default-name 'other-name))
          (tally! tally (cond ((= time 0) 'time-0) ((> time 1999999999) 'time-bignum) (else 'time-ten-digits)))
          (list name secrets (mod signer n) time (cdr drawn)))))))

;; middleware-for : String (Listof String) Nat -> Middleware
(define (middleware-for name secrets time)
  (apply wrap-session secrets (lambda () time) 34560000
         (if (string=? name "__Host-session") '() (list (session-name name)))))

;; cookie-of : Case -> (U String #f)
;; The case's cookie, as a browser sends it back, or #f when the session is
;; '(), which expires the cookie.
(define (cookie-of kase)
  (let* ((name (list-ref kase 0)) (secrets (list-ref kase 1)) (signer (list-ref kase 2))
         (time (list-ref kase 3)) (session (list-ref kase 4))
         (writer (middleware-for name (list (list-ref secrets signer)) time))
         (r ((writer (lambda (req) (res-with-session (make-res 200 '() "") session))) (make-test-req 'GET "/")))
         (field (cdr (assoc "set-cookie" (res-headers r)))))
    (let loop ((i 0))
      (if (char=? (string-ref field i) #\;) (substring field 0 i) (loop (+ i 1))))))

;; read-back : Case String -> Session
(define (read-back kase cookie)
  (((middleware-for (list-ref kase 0) (list-ref kase 1) (list-ref kase 3)) req-session)
   (make-test-req 'GET "/" (list (cons "cookie" cookie)))))

(define (case-shrinks kase)
  (map (lambda (s) (replace-at kase 4 s)) (params-shrinks (list-ref kase 4))))

;; --- S1: the round trip -------------------------------------------------------------

(define s1-tally (make-tally))

(define (s1-check kase)
  (let ((session (list-ref kase 4)))
    (and (pair? session)
         (let* ((cookie (cookie-of kase)) (back (read-back kase cookie)))
           (and (not (equal? back session))
                (list 'cookie cookie 'read back))))))

(test-equal "S1: a session written by wrap-session and sent back as a browser sends it reads back whole"
  '()
  (property-failures 'S1 (* 1000 multiplier) (gen-case 1 s1-tally) s1-check case-shrinks s1-tally))

;; --- S2: one character changed ------------------------------------------------------

(define s2-tally (make-tally))

;; changed : Char -> Char — another cookie-octet.
(define (changed c) (if (char=? c #\a) #\b #\a))

;; S2's case is S1's and a position, drawn from its own state.
(define (s2-case i)
  (let ((kase ((gen-case 2 s2-tally) i)))
    (let ((s (case-state 20 i)))
      (draw* s ((at (g-int 32768)))
        (append kase (list at))))))

(define (s2-check kase)
  (let ((session (list-ref kase 4)))
    (and (pair? session)
         (let* ((cookie (cookie-of kase))
                (start (+ (string-length (list-ref kase 0)) 1))
                (at (+ start (mod (list-ref kase 5) (- (string-length cookie) start))))
                (tampered (string-append (substring cookie 0 at) (string (changed (string-ref cookie at)))
                                         (substring cookie (+ at 1) (string-length cookie))))
                (control (read-back kase cookie))
                (back (read-back kase tampered)))
           (and (not (and (equal? control session) (null? back)))
                (list 'tampered tampered 'at at 'read back 'untampered-read control))))))

(define (s2-shrinks kase)
  (map (lambda (s) (replace-at kase 4 s)) (params-shrinks (list-ref kase 4))))

(test-equal "S2: the cookie with one character of its value changed reads no session, and unchanged reads back whole"
  '()
  (property-failures 'S2 (* 1000 multiplier) s2-case s2-check s2-shrinks s2-tally))

(exit (suite-exit-status runner))
