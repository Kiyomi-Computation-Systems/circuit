#!r6rs
;;; (circuit params), by property: param lists and bytes generated from a
;;; fixed seed (the slice 9 design §5).
;;;
;;; The rows:
;;;   - P1 a param list written by params->string reads back whole from
;;;     parse-params, from a query through req-query-params, and from a
;;;     form's body through wrap-form-params: its names and values drawn
;;;     from every kind of string, the empty one, =, &, +, %, a space, what
;;;     looks like an escape, controls, Latin-1, U+FEFF and U+FFFD, and
;;;     characters of two, three and four UTF-8 bytes; names repeated;
;;;   - P2 params->string writes only ASCII letters and digits, *, -, ., _,
;;;     +, =, & and escapes of two upper-case hex digits, and as many & as
;;;     the list has pairs, less one;
;;;   - P3 parse-params never fails: any bytes answer a param list, a pair
;;;     for each piece between & that isn't empty, in order.
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
        (only (circuit request) req-with-query)
        (only (circuit middleware) wrap)
        (only (circuit test) make-test-req)
        (circuit params))

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
    (put-string out "params-properties: failing case:\n")
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
    (put-string out (string-append "params-properties: " (symbol->string name) ": "
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

;; --- P1: the round trip -----------------------------------------------------------

(define p1-tally (make-tally))

(define (p1-case i)
  (let ((drawn (car (g-params (case-state 1 i)))))
    (for-each (lambda (tag) (tally! p1-tally tag)) (car drawn))
    (when (null? (cdr drawn)) (tally! p1-tally 'empty-list))
    (cdr drawn)))

;; form-read : String -> Params — TEXT as a form's body, read by wrap-form-params.
(define (form-read text)
  ((wrap req-form-params (wrap-form-params 1048576))
   (make-test-req 'POST "/" '(("content-type" . "application/x-www-form-urlencoded")) text)))

(define (p1-check ps)
  (let* ((text (params->string ps))
         (parsed (parse-params (string->utf8 text)))
         (queried (req-query-params (req-with-query (make-test-req 'GET "/") text)))
         (formed (form-read text)))
    (and (not (and (equal? parsed ps) (equal? queried ps) (equal? formed ps)))
         (list 'written text 'parsed parsed 'queried queried 'formed formed))))

(test-equal "P1: params->string, read back by parse-params, req-query-params and wrap-form-params, is the list it wrote"
  '()
  (property-failures 'P1 (* 3000 multiplier) p1-case p1-check params-shrinks p1-tally))

;; --- P2: what params->string writes ---------------------------------------------

(define p2-tally (make-tally))

(define (p2-case i)
  (let ((drawn (car (g-params (case-state 2 i)))))
    (for-each (lambda (tag) (tally! p2-tally tag)) (car drawn))
    (cdr drawn)))

(define (upper-hex? c) (or (char<=? #\0 c #\9) (char<=? #\A c #\F)))

;; written-badly : String -> (U #f (List Nat Char))
;; The first character of TEXT outside params->string's set, by its index,
;; or a % not followed by two upper-case hex digits; #f when there is none.
(define (written-badly text)
  (let ((n (string-length text)))
    (let loop ((i 0))
      (if (= i n)
          #f
          (let ((c (string-ref text i)))
            (cond ((char=? c #\%)
                   (if (and (< (+ i 2) n) (upper-hex? (string-ref text (+ i 1))) (upper-hex? (string-ref text (+ i 2))))
                       (loop (+ i 3))
                       (list i c)))
                  ((or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9)
                       (memv c '(#\* #\- #\. #\_ #\+ #\= #\&)))
                   (loop (+ i 1)))
                  (else (list i c))))))))

(define (count-char c text)
  (fold-left (lambda (k x) (if (char=? x c) (+ k 1) k)) 0 (string->list text)))

(define (p2-check ps)
  (let* ((text (params->string ps))
         (bad (written-badly text))
         (ands (count-char #\& text)))
    (and (or bad (not (= ands (max 0 (- (length ps) 1)))))
         (list 'written text 'bad bad 'ampersands ands))))

(test-equal "P2: params->string writes only its set, each escape two upper-case hex digits, and an & between pairs alone"
  '()
  (property-failures 'P2 (* 3000 multiplier) p2-case p2-check params-shrinks p2-tally))

;; --- P3: parse-params never fails ------------------------------------------------

(define p3-tally (make-tally))

;; Bytes, weighted to the ones the parser treats apart.
(define g-byte
  (g-choose
   (list (cons 4 (g-pick '(38 61 43 37)))
         (cons 4 (g-pick (map char->integer (string->list "0123456789abcdefABCDEF"))))
         (cons 2 (g-pick (map char->integer (string->list "gz ~*\x0;"))))
         (cons 4 (g-pick '(#x80 #x8F #x90 #x9F #xA0 #xBF #xC0 #xC1 #xC2 #xDF #xE0 #xED #xEF #xF0 #xF4 #xF5 #xFF)))
         (cons 1 (g-range 0 255)))))

(define (p3-case i)
  (let ((s (case-state 3 i)))
    (draw* s ((n (g-range 0 16)) (bs (g-list n g-byte)))
      (for-each (lambda (b) (tally! p3-tally (cond ((= b 38) 'amp) ((= b 61) 'equals) ((= b 37) 'percent)
                                                    ((= b 43) 'plus) ((>= b #x80) 'high) (else 'other))))
                bs)
      bs)))

;; pieces : (Listof Byte) -> Nat — how many pieces between & aren't empty.
(define (pieces bs)
  (let loop ((bs bs) (in-piece? #f) (k 0))
    (cond ((null? bs) (if in-piece? (+ k 1) k))
          ((= (car bs) 38) (loop (cdr bs) #f (if in-piece? (+ k 1) k)))
          (else (loop (cdr bs) #t k)))))

(define (param-list? x)
  (and (list? x) (for-all (lambda (p) (and (pair? p) (string? (car p)) (string? (cdr p)))) x)))

(define (p3-check bs)
  (let ((parsed (parse-params (u8-list->bytevector bs))))
    (and (not (and (param-list? parsed) (= (length parsed) (pieces bs))))
         (list 'parsed parsed 'pieces (pieces bs)))))

(define (byte-shrinks bs) (map (lambda (i) (remove-at bs i)) (iota (length bs))))

(test-equal "P3: parse-params answers any bytes with a param list, a pair for each piece between & that isn't empty"
  '()
  (property-failures 'P3 (* 5000 multiplier) p3-case p3-check byte-shrinks p3-tally))

(exit (suite-exit-status runner))
