#!r6rs
;;; (circuit router), by property: tables and paths generated from a fixed
;;; seed, checked against an oracle written from the slice 6 design's §5
;;; alone (design §15.22), before the router's source was read.
;;;
;;; The oracle is naive on purpose. It joins a table's group prefixes into
;;; flat templates, tests every template against the split path, keeps the
;;; ones that match, picks one by the leftmost segment where they differ,
;;; decodes its captures, then picks the method. It shares no code with the
;;; router.
;;;
;;; The rows:
;;;   - sanity: §5's own examples and sentences, each against the oracle and
;;;     the router, so a wrong oracle fails here first;
;;;   - P1 the router answers as the oracle does: the handler, what it and
;;;     each middleware and not-found, 400 and 405 handler read of the
;;;     request, the response, and the middleware that ran. Groups'
;;;     middleware may also rewrite the path, hand on a request it made, or
;;;     be a router of its own (design §15.23);
;;;   - P2 reordering and regrouping a table, and reordering its options,
;;;     changes no answer;
;;;   - P3 a table is refused, by an assertion violation from the router's
;;;     own constructors, exactly when the oracle refuses it, two options
;;;     for one answer among the reasons; a crash inside them is no
;;;     refusal;
;;;   - P4 any string, its UTF-8 percent-encoded, reads back from a
;;;     parameter, a catch-all and a mount's parameter;
;;;   - P5 a bad escape, bad UTF-8, or a raw character past ASCII or outside
;;;     RFC 3986's pchar, anywhere in a capture, answers the empty 400, and
;;;     nothing runs; the same path unspoiled is the route's;
;;;   - P6 req-mount-path then req-path is the path given, at every level
;;;     where the oracle says something reads it, the 400 and 405 handlers
;;;     among them, with no middleware changing the path or the request;
;;;   - P7 the method picks the handler, HEAD and ANY included, or the 405.
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
        (only (circuit request) req-method req-path req-query req-with-path)
        (only (circuit response) make-res res? res-status res-headers)
        (only (circuit test) make-test-req res-body->bytevector)
        (only (circuit middleware) wrap)
        (only (circuit router) make-router on-not-found on-bad-request on-method-not-allowed
              route group mount GET POST PUT PATCH DELETE OPTIONS
              ANY METHOD req-path-param req-path-params req-route req-mount-path))

(define runner (test-runner-simple))
(test-runner-current runner)

;; --- the arguments ------------------------------------------------------------

(define default-seed 20261027)
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

;; --- lists and strings ----------------------------------------------------------

;; Pure helpers: each f is pure, so the order fold-right calls it in is moot.
(define (concat-map f xs) (fold-right (lambda (x acc) (append (f x) acc)) '() xs))
(define (filter-map f xs)
  (fold-right (lambda (x acc) (let ((y (f x))) (if y (cons y acc) acc))) '() xs))
(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))
(define (take xs n) (if (= n 0) '() (cons (car xs) (take (cdr xs) (- n 1)))))
(define (last xs) (if (null? (cdr xs)) (car xs) (last (cdr xs))))
(define (remove-at xs i) (append (take xs i) (list-tail xs (+ i 1))))
(define (splice-at xs i repl) (append (take xs i) repl (list-tail xs (+ i 1))))
(define (has-duplicates? xs)
  (and (pair? xs) (or (member (car xs) (cdr xs)) (has-duplicates? (cdr xs))) #t))
(define (string-join strs sep)
  (if (null? strs)
      ""
      (fold-left (lambda (acc x) (string-append acc sep x)) (car strs) (cdr strs))))
(define (starts-with-slash? text)
  (and (> (string-length text) 0) (char=? (string-ref text 0) #\/)))
(define (ends-with-slash? text)
  (let ((n (string-length text))) (and (> n 0) (char=? (string-ref text (- n 1)) #\/))))
(define (sort-tags tags)
  (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) tags))
(define (repeat x n) (if (= n 0) '() (cons x (repeat x (- n 1)))))

;; --- random: a linear congruential sequence, threaded ---------------------------

;; Gen a = Nat -> (Pair a Nat): a draw takes the state and answers the
;; value and the next state. draw* binds draws in turn, each from the state
;; the one before left, so no two draws are ever arguments of one call.

;; next-random : Nat -> Nat
;; The next of the sequence test-heap.sps uses.
(define (next-random x) (mod (+ (* x 1103515245) 12345) 2147483648))

(define-syntax draw*
  (syntax-rules ()
    ((_ s () body0 body ...) (let () body0 body ...))
    ((_ s ((x g) more ...) body0 body ...)
     (let* ((drawn (g s)) (x (car drawn)) (s (cdr drawn)))
       (draw* s (more ...) body0 body ...)))))

;; let-pair* binds each pair's car and cdr, as let*-values would two
;; values. The suite answers pairs, never multiple values: Chez 10.4.1's
;; cp0 miscompiles a let-values over a producer it inlines in two places,
;; and raises "incorrect number of values" where none is wrong.
(define-syntax let-pair*
  (syntax-rules ()
    ((_ () body0 body ...) (let () body0 body ...))
    ((_ (((a b) e) more ...) body0 body ...)
     (let* ((pr e) (a (car pr)) (b (cdr pr))) (let-pair* (more ...) body0 body ...)))))

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
;; Property PROP's case INDEX's first state, from the seed alone. Mixed, not
;; affine in the index: an affine start, through the affine sequence, put
;; the first draws of neighbouring cases on a line, and a third of them
;; drew alike.
(define (case-state prop index)
  (mix (+ (mix (+ (mix seed) prop)) index)))

;; g-int : Nat -> Gen Nat
;; A whole number in [0, n), n at most 32768, each equally likely: the
;; state's bits 16 to 30, drawn again while they are at or above the largest
;; multiple of n not above 32768. Taken modulo n as they are, the lowest
;; 32768 mod n values would each come once more.
(define (g-int n)
  (let ((limit (* n (div 32768 n))))
    (lambda (s)
      (let retry ((s (next-random s)))
        (let ((bits (div s 65536)))
          (if (< bits limit)
              (cons (mod bits n) s)
              (retry (next-random s))))))))

;; g-range : Nat Nat -> Gen Nat
;; A whole number in [lo, hi].
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

(define (g-const v) (lambda (s) (cons v s)))
(define (g-pick xs) (lambda (s) (draw* s ((i (g-int (length xs)))) (cons (list-ref xs i) s))))
(define (g-chance k n) (lambda (s) (draw* s ((i (g-int n))) (cons (< i k) s))))

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

;; g-shuffle : (Listof a) -> Gen (Listof a)
(define (g-shuffle xs)
  (lambda (s)
    (let loop ((xs xs) (acc '()) (s s))
      (if (null? xs)
          (cons acc s)
          (draw* s ((i (g-int (length xs))))
            (loop (remove-at xs i) (cons (list-ref xs i) acc) s))))))

;; --- characters ----------------------------------------------------------------

(define alpha-digit "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
;; §5: a word holds RFC 3986 pchar without pct-encoded.
(define word-char-list (string->list (string-append alpha-digit "-._~!$&'()*+,;=:@")))
;; §5: a name is ASCII letters, digits, - and _.
(define name-char-list (string->list (string-append alpha-digit "-_")))
;; RFC 9110's tchar, upper case only: §5's METHOD takes a token in upper case.
(define method-char-list (string->list "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"))
(define hex-upper "0123456789ABCDEF")
(define hex-lower "0123456789abcdef")

(define (hex-value c)
  (cond ((and (char>=? c #\0) (char<=? c #\9)) (- (char->integer c) 48))
        ((and (char>=? c #\A) (char<=? c #\F)) (- (char->integer c) 55))
        ((and (char>=? c #\a) (char<=? c #\f)) (- (char->integer c) 87))
        (else #f)))

(define (escape-byte b upper?)
  (let ((h (if upper? hex-upper hex-lower)))
    (string #\% (string-ref h (div b 16)) (string-ref h (mod b 16)))))

;; --- the model ------------------------------------------------------------------

;; A table is data, so a case can be printed, pasted and shrunk:
;;   HM     = (leaf Id) | (nf Id) | (br Id) | (mna Id) | (next) | (wrapped Tag HM)
;;          | (router (Listof Entry) (U (nf Id) #f) [(Listof Opt)])
;;   Opt    = (onf Id) | (br Id) | (mna Id): make-router's options after the
;;            bare not-found handler, in order: on-not-found's, on-bad-request's
;;            and on-method-not-allowed's
;;   Entry  = (route Template (U Symbol #f) (Listof MEntry))
;;          | (group Template (Listof MW) (Listof Entry))
;;          | (mount Template HM)
;;   MEntry = (Method Form HM), Form short for (GET h), method for (METHOD 'GET h)
;;   MW     = (mw Tag) | (rw Tag) | (fresh Tag Method Path Query) | (mr Tag (Listof Entry))
;;   Req    = (Method Path (U String #f))
;; A leaf notes what it read and answers 200 with x-leaf; a nf is a
;; not-found handler; (next), only in a middleware's router, is what the
;; middleware hands on to. A middleware notes what it read on the way in,
;; and notes out on the way out; its kinds are in run-stack.
;;
;; Events, the same from the oracle and the router:
;;   (leaf Id Method Path MountPath Query Route Params Lookups)
;;   (in Tag Method Path MountPath Query Route Params)
;;   (out Tag)
;;   (nf Id Method Path MountPath Query Route Params Lookups), and br and
;;   mna, the 400's and the 405's handlers, the same
;; Lookups is req-path-param for each of lookup-names.

;; router-opts : HM -> (Listof Opt) — a router's options, () when it has none.
(define (router-opts hm) (if (pair? (cdddr hm)) (cadddr hm) '()))

;; router-with : HM (Listof Entry) (U (nf Id) #f) -> HM
;; HM's router with ENTRIES and NF, its options kept.
(define (router-with hm entries nf)
  (if (null? (router-opts hm)) (list 'router entries nf) (list 'router entries nf (router-opts hm))))

;; opt-handler : (Listof Opt) Symbol -> (U HM #f)
;; The handler of the option of KIND, as an HM: onf's a nf.
(define (opt-handler opts kind)
  (let ((o (assq kind opts)))
    (and o (list (if (eq? kind 'onf) 'nf kind) (cadr o)))))

(define param-names '("id" "x" "y" "v" "user-id" "n_2"))
(define catch-names '("p" "rest" "r"))
(define lookup-names (append param-names catch-names '("zz")))

;; A permutation of the names, so a renamed template keeps its names apart.
(define renames
  '(("id" . "x") ("x" . "y") ("y" . "v") ("v" . "id") ("user-id" . "n_2") ("n_2" . "user-id")
    ("p" . "rest") ("rest" . "r") ("r" . "p")))

(define (leaf-response id) (list 200 (list (cons "x-leaf" (symbol->string id))) (make-bytevector 0)))
(define response-404 (list 404 '() (make-bytevector 0)))
(define response-400 (list 400 '() (make-bytevector 0)))
(define (response-405 allow) (list 405 (list (cons "allow" allow)) (make-bytevector 0)))
;; §5: the router sets allow on what the 405 handler answers.
(define (leaf-response-allow id allow)
  (list 200 (list (cons "x-leaf" (symbol->string id)) (cons "allow" allow)) (make-bytevector 0)))

;; =================================================================================
;; The oracle, from §5.
;; =================================================================================

;; --- templates ------------------------------------------------------------------

;; split-slash : String -> (Listof String)
;; "a/b" is ("a" "b"); "" is ("").
(define (split-slash text)
  (let ((n (string-length text)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((= i n) (reverse (cons (substring text start i) acc)))
            ((char=? (string-ref text i) #\/) (loop (+ i 1) (+ i 1) (cons (substring text start i) acc)))
            (else (loop (+ i 1) start acc))))))

;; template-segments : String -> (Listof String)
;; "" has none; "/" has one, empty; "/a/" has a and an empty one.
(define (template-segments t)
  (if (string=? t "") '() (split-slash (substring t 1 (string-length t)))))

;; Seg = (word String) | (param String) | (catch String)
(define (parse-seg text)
  (let ((n (string-length text)))
    (cond ((and (> n 0) (char=? (string-ref text 0) #\:)) (list 'param (substring text 1 n)))
          ((and (> n 0) (char=? (string-ref text 0) #\*)) (list 'catch (substring text 1 n)))
          (else (list 'word text)))))

(define (template-segs t) (map parse-seg (template-segments t)))

(define (seg-valid? seg)
  (let ((text (cadr seg)))
    (if (eq? (car seg) 'word)
        (and (for-all (lambda (c) (memv c word-char-list)) (string->list text))
             (not (member text '("." ".."))))
        (and (> (string-length text) 0)
             (for-all (lambda (c) (memv c name-char-list)) (string->list text))))))

;; template-problem : String (U 'route 'mount) -> (U Symbol #f)
;; What §5 refuses in a joined template, or #f.
(define (template-problem joined kind)
  (if (not (starts-with-slash? joined))
      'joined-template-not-slash
      (let* ((segs (template-segs joined))
             (n (length segs))
             (indexed (map cons (iota n) segs)))
        (cond ((not (for-all seg-valid? segs)) 'bad-segment)
              ((exists (lambda (p) (and (equal? (cdr p) '(word "")) (< (car p) (- n 1)))) indexed)
               'empty-segment-not-last)
              ((exists (lambda (p) (and (eq? (cadr p) 'catch) (< (car p) (- n 1)))) indexed)
               'catch-all-not-last)
              ((has-duplicates? (filter-map (lambda (seg) (and (memq (car seg) '(param catch)) (cadr seg)))
                                            segs))
               'name-twice)
              ((and (eq? kind 'mount) (exists (lambda (seg) (eq? (car seg) 'catch)) segs))
               'mount-catch-all)
              ((and (eq? kind 'mount) (equal? (last segs) '(word ""))) 'mount-ends-in-slash)
              (else #f)))))

;; Flat = (froute Joined Name (Listof MEntry) Stack) | (fmount Joined HM Stack)
;; Stack: the middleware around it, outermost first. The outer group's
;; sits outermost, and each group's list in wrap's order, its last
;; outermost.
(define (flatten entries prefix stack)
  (concat-map
   (lambda (e)
     (case (car e)
       ((route) (list (list 'froute (string-append prefix (cadr e)) (caddr e) (cadddr e) stack)))
       ((mount) (list (list 'fmount (string-append prefix (cadr e)) (caddr e) stack)))
       ((group) (flatten (cadddr e) (string-append prefix (cadr e)) (append stack (reverse (caddr e)))))))
   entries))

(define (given-templates entries)
  (concat-map (lambda (e)
                (case (car e)
                  ((route mount) (list (cadr e)))
                  ((group) (cons (cadr e) (given-templates (cadddr e))))))
              entries))

;; One shape: equal words, and parameters equal, and catch-alls equal,
;; whatever they're called; a mount is its template and a catch-all.
(define (flat-shape item)
  (let ((segs (map (lambda (seg) (if (eq? (car seg) 'word) seg (list (car seg))))
                   (template-segs (cadr item)))))
    (if (eq? (car item) 'fmount) (append segs '((catch))) segs)))

;; method-token? : Symbol -> Boolean
(define (method-token? sym)
  (let ((cs (string->list (symbol->string sym))))
    (and (pair? cs) (for-all (lambda (c) (memv c method-char-list)) cs) #t)))

;; router-refusal : (Listof Entry) -> (U Symbol #f)
;; Why §5 refuses one router's own table, or #f.
(define (router-refusal entries)
  (let ((flat (flatten entries "" '())))
    (cond ((not (for-all (lambda (t) (or (string=? t "") (starts-with-slash? t))) (given-templates entries)))
           'template-neither-empty-nor-slash)
          ((exists (lambda (item)
                     (and (eq? (car item) 'froute)
                          (exists (lambda (m) (and (eq? (cadr m) 'method) (not (method-token? (car m)))))
                                  (cadddr item))))
                   flat)
           'method-not-an-upper-case-token)
          ((exists (lambda (item) (and (eq? (car item) 'froute) (null? (cadddr item)))) flat)
           'route-without-a-method)
          ((exists (lambda (item) (and (eq? (car item) 'froute) (has-duplicates? (map car (cadddr item))))) flat)
           'method-listed-twice)
          ((exists (lambda (item) (template-problem (cadr item) (if (eq? (car item) 'fmount) 'mount 'route)))
                   flat)
           => (lambda (x) x))
          ((has-duplicates? (map flat-shape flat)) 'same-shape)
          ((has-duplicates? (filter-map (lambda (item) (and (eq? (car item) 'froute) (caddr item))) flat))
           'route-name-twice)
          (else #f))))

;; handler-refusal : HM -> (U Symbol #f)
;; Why some router in HM's tree is refused, or #f.
(define (handler-refusal hm)
  (case (car hm)
    ((leaf nf br mna) #f)
    ((wrapped) (handler-refusal (caddr hm)))
    ((router) (or (entries-inner-refusal (cadr hm)) (router-refusal (cadr hm)) (options-refusal hm)))))

;; options-refusal : HM -> (U Symbol #f)
;; §5: two options for one answer, the bare not-found handler on-not-found's.
(define (options-refusal hm)
  (and (has-duplicates? (append (if (caddr hm) '(onf) '()) (map car (router-opts hm))))
       'option-twice))

(define (entries-inner-refusal entries)
  (exists (lambda (e)
            (case (car e)
              ((route) (exists (lambda (m) (handler-refusal (caddr m))) (cadddr e)))
              ((mount) (handler-refusal (caddr e)))
              ((group) (entries-inner-refusal (cadddr e)))))
          entries))

;; --- what make-router applies -----------------------------------------------------

;; expected-applies : HM -> (Listof Tag)
;; Each group's middleware once for each method's handler and each mount
;; under it; a wrapped handler's once.
(define (expected-applies hm)
  (case (car hm)
    ((leaf nf br mna) '())
    ((wrapped) (cons (cadr hm) (expected-applies (caddr hm))))
    ((router) (concat-map entry-applies (cadr hm)))))

(define (entry-applies e)
  (case (car e)
    ((route) (concat-map (lambda (m) (expected-applies (caddr m))) (cadddr e)))
    ((mount) (expected-applies (caddr e)))
    ((group) (let ((n (handler-count (cadddr e))))
               (append (concat-map (lambda (mw) (repeat (cadr mw) n)) (caddr e))
                       (concat-map entry-applies (cadddr e)))))))

(define (handler-count entries)
  (fold-left + 0 (map (lambda (e)
                        (case (car e)
                          ((route) (length (cadddr e)))
                          ((mount) 1)
                          ((group) (handler-count (cadddr e)))))
                      entries)))

;; --- matching ---------------------------------------------------------------------

;; path-segments : String -> (Listof (List String Start End))
;; PATH, which begins with /, split at /, each segment with its span.
(define (path-segments path)
  (let ((n (string-length path)))
    (let loop ((i 1) (start 1) (acc '()))
      (cond ((= i n) (reverse (cons (list (substring path start n) start n) acc)))
            ((char=? (string-ref path i) #\/)
             (loop (+ i 1) (+ i 1) (cons (list (substring path start i) start i) acc)))
            (else (loop (+ i 1) start acc))))))

(define (seg-rank seg) (case (car seg) ((word) 0) ((param) 1) (else 2)))

;; match-pairs : (Listof Seg) (Listof PSeg) -> (U (Listof Capture) #f)
;; Words and parameters against as many path segments. Capture = (Name Start End).
(define (match-pairs segs psegs)
  (let loop ((segs segs) (psegs psegs) (caps '()))
    (if (null? segs)
        (reverse caps)
        (let ((seg (car segs)) (p (car psegs)))
          (case (car seg)
            ((word) (and (string=? (cadr seg) (car p)) (loop (cdr segs) (cdr psegs) caps)))
            ((param) (and (> (string-length (car p)) 0)
                          (loop (cdr segs) (cdr psegs) (cons (list (cadr seg) (cadr p) (caddr p)) caps))))
            (else #f))))))

;; Cand = (cand Flat Ranks (Listof Capture) TakenEnd)
;; Ranks: what took each segment, 0 a word, 1 a parameter, 2 a catch-all
;; or a mount's rest; a route without a catch-all ends with 0, for where
;; the path ends, which beats a mount taking nothing.
(define (cand-item c) (cadr c))
(define (cand-ranks c) (caddr c))
(define (cand-caps c) (cadddr c))
(define (cand-taken c) (list-ref c 4))
(define (cand? c) (and (pair? c) (eq? (car c) 'cand)))

;; match-item : Flat (Listof PSeg) String -> (U Cand #f)
(define (match-item item psegs path)
  (let* ((segs (template-segs (cadr item)))
         (n (length segs))
         (np (length psegs)))
    (case (car item)
      ((froute)
       (if (and (> n 0) (eq? (car (last segs)) 'catch))
           (let ((fixed (take segs (- n 1))))
             (and (> np (- n 1))
                  (let ((caps (match-pairs fixed (take psegs (- n 1)))))
                    (and caps
                         (list 'cand item (append (map seg-rank fixed) '(2))
                               (append caps (list (list (cadr (last segs))
                                                        (cadr (list-ref psegs (- n 1)))
                                                        (string-length path))))
                               #f)))))
           (and (= np n)
                (let ((caps (match-pairs segs psegs)))
                  (and caps (list 'cand item (append (map seg-rank segs) '(0)) caps #f))))))
      ((fmount)
       (and (> n 0) (>= np n)
            (let ((caps (match-pairs segs (take psegs n))))
              (and caps
                   (list 'cand item (append (map seg-rank segs) '(2)) caps
                         (caddr (list-ref psegs (- n 1)))))))))))

;; rank-compare : Ranks Ranks -> Integer
;; Negative when A wins at the leftmost place they differ, positive when B
;; does, 0 when nothing decides.
(define (rank-compare a b)
  (cond ((or (null? a) (null? b)) 0)
        ((< (car a) (car b)) -1)
        ((> (car a) (car b)) 1)
        (else (rank-compare (cdr a) (cdr b)))))

;; best : (Listof Cand) -> (U Cand 'tie)
(define (best cands)
  (let loop ((rest (cdr cands)) (top (car cands)) (tied #f))
    (if (null? rest)
        (if tied 'tie top)
        (let ((c (rank-compare (cand-ranks (car rest)) (cand-ranks top))))
          (cond ((< c 0) (loop (cdr rest) (car rest) #f))
                ((= c 0) (loop (cdr rest) top #t))
                (else (loop (cdr rest) top tied)))))))

;; oracle-winner : HM String -> (U Cand 'tie #f)
;; The router HM's winning match for PATH.
(define (oracle-winner hm path)
  (let ((hm (if (eq? (car hm) 'wrapped) (caddr hm) hm)))
    (and (starts-with-slash? path)
         (let* ((psegs (path-segments path))
                (cands (filter-map (lambda (item) (match-item item psegs path))
                                   (flatten (cadr hm) "" '()))))
           (and (pair? cands) (best cands))))))

;; --- decoding ---------------------------------------------------------------------

;; pct-bytes : String -> (U (Listof Byte) #f)
;; #f for a raw character a path can't hold, past ASCII or outside RFC
;; 3986's pchar and /, or a % not followed by two hex digits.
(define (pct-bytes text)
  (let ((n (string-length text)))
    (let loop ((i 0) (acc '()))
      (if (= i n)
          (reverse acc)
          (let ((c (string-ref text i)))
            (cond ((char=? c #\%)
                   (and (< (+ i 2) n)
                        (let ((hi (hex-value (string-ref text (+ i 1))))
                              (lo (hex-value (string-ref text (+ i 2)))))
                          (and hi lo (loop (+ i 3) (cons (+ (* hi 16) lo) acc))))))
                  ((or (memv c word-char-list) (char=? c #\/))
                   (loop (+ i 1) (cons (char->integer c) acc)))
                  (else #f)))))))

;; utf8-strict : (Listof Byte) -> (U String #f)
;; The scalar values the bytes encode, or #f: a stray continuation byte, a
;; lead byte past F7, a sequence cut short, an overlong form, a surrogate,
;; or a value past 10FFFF.
(define (utf8-strict bytes)
  (let loop ((bs bytes) (acc '()))
    (if (null? bs)
        (list->string (reverse acc))
        (let ((b (car bs)))
          (if (< b #x80)
              (loop (cdr bs) (cons (integer->char b) acc))
              (let* ((lead (cond ((= (bitwise-and b #xE0) #xC0) (list 2 (bitwise-and b #x1F) #x80))
                                 ((= (bitwise-and b #xF0) #xE0) (list 3 (bitwise-and b #x0F) #x800))
                                 ((= (bitwise-and b #xF8) #xF0) (list 4 (bitwise-and b #x07) #x10000))
                                 (else (list #f #f #f))))
                     (n (car lead)) (init (cadr lead)) (least (caddr lead)))
                (and n
                     (let more ((k 1) (rest (cdr bs)) (cp init))
                       (if (= k n)
                           (and (>= cp least)
                                (not (and (>= cp #xD800) (<= cp #xDFFF)))
                                (<= cp #x10FFFF)
                                (loop rest (cons (integer->char cp) acc)))
                           (and (pair? rest)
                                (= (bitwise-and (car rest) #xC0) #x80)
                                (more (+ k 1) (cdr rest) (+ (* cp 64) (bitwise-and (car rest) #x3F)))))))))))))

(define (decode text) (let ((bytes (pct-bytes text))) (and bytes (utf8-strict bytes))))

;; decode-captures : (Listof Capture) String -> (U (Listof (Pair String String)) #f)
(define (decode-captures caps path)
  (let loop ((caps caps) (acc '()))
    (if (null? caps)
        (reverse acc)
        (let* ((cap (car caps)) (v (decode (substring path (cadr cap) (caddr cap)))))
          (and v (loop (cdr caps) (cons (cons (car cap) v) acc)))))))

;; --- the method -------------------------------------------------------------------

;; pick-method : (Listof MEntry) Symbol -> (U HM #f)
;; The method's own; for HEAD, else GET's; else ANY's.
(define (pick-method methods m)
  (let ((find-handler (lambda (sym) (let ((e (assq sym methods))) (and e (caddr e))))))
    (or (find-handler m)
        (and (eq? m 'HEAD) (find-handler 'GET))
        (find-handler 'ANY))))

;; allow-of : (Listof MEntry) -> String
;; The methods as listed, HEAD right after GET when no HEAD is listed.
(define (allow-of methods)
  (let ((listed (map car methods)))
    (string-join (concat-map (lambda (sym)
                               (if (and (eq? sym 'GET) (not (memq 'HEAD listed)))
                                   '("GET" "HEAD")
                                   (list (symbol->string sym))))
                             listed)
                 ", ")))

;; --- the request, as the oracle sees it ---------------------------------------------

;; Match = (U (Pair Route Params) #f): what req-route and req-path-params read.
;; MBase = (U (List Template Params MountPath) #f): the nearest mount above.
;; Marker = (U (List Rest MBase Match) #f): a request inside the group
;; middleware around a mount carries the mount's match, and the mount's
;; handler is given the rest of the path the router matched, under that
;; mount. A request the middleware hands on without it, one it made or
;; one a router of its own matched, reaches the handler as it is (design
;; §15.23).
(define-record-type (ostate make-ostate ostate?)
  (fields method path query match mbase marker))

(define (st-route st) (let ((m (ostate-match st))) (and m (car m))))
(define (st-params st) (let ((m (ostate-match st))) (if m (cdr m) '())))
(define (st-mp st) (let ((b (ostate-mbase st))) (if b (caddr b) "")))
(define (st-with-path st path)
  (make-ostate (ostate-method st) path (ostate-query st) (ostate-match st) (ostate-mbase st)
               (ostate-marker st)))

;; lookups-in : Params -> (Listof (U String #f))
;; req-path-param for each lookup name: the last param of that name.
(define (lookups-in params)
  (map (lambda (name)
         (let loop ((ps params) (v #f))
           (cond ((null? ps) v)
                 ((string=? (caar ps) name) (loop (cdr ps) (cdar ps)))
                 (else (loop (cdr ps) v)))))
       lookup-names))

(define (oracle-leaf-event id st)
  (list 'leaf id (ostate-method st) (ostate-path st) (st-mp st) (ostate-query st) (st-route st)
        (st-params st) (lookups-in (st-params st))))
(define (oracle-in-event tag st)
  (list 'in tag (ostate-method st) (ostate-path st) (st-mp st) (ostate-query st) (st-route st)
        (st-params st)))
;; §5: the not-found handler gets the request as it came to the router.
(define (oracle-nf-event id st) (cons 'nf (cdr (oracle-leaf-event id st))))

;; --- the oracle's answer ------------------------------------------------------------

;; Instruments, for the tallies only: how many routers the last answer
;; passed, and what it went through.
(define routers-passed 0)
(define oracle-seen '())
(define (seen! x) (set! oracle-seen (cons x oracle-seen)))
(define last-mount-wrapped #f)

;; oracle-handler : HM OState (U (OState -> Answer) #f) -> (Pair (Listof Event) Response)
;; NEXT is what a (next) handler, in a middleware's router, hands on to.
(define (oracle-handler hm st next)
  (case (car hm)
    ((leaf) (cons (list (oracle-leaf-event (cadr hm) st)) (leaf-response (cadr hm))))
    ((nf) (cons (list (oracle-nf-event (cadr hm) st)) (leaf-response (cadr hm))))
    ;; The 400's and the 405's handlers note what they read, as a leaf does;
    ;; their callers give them the request §5 says.
    ((br mna)(cons (list (cons (car hm) (cdr (oracle-leaf-event (cadr hm) st)))) (leaf-response (cadr hm))))
    ((next) (next st))
    ((wrapped)
     (let ((inner (oracle-handler (caddr hm) st next)))
       (cons (append (list (oracle-in-event (cadr hm) st)) (car inner) (list (list 'out (cadr hm))))
             (cdr inner))))
    ((router) (oracle-router (cadr hm) (or (caddr hm) (opt-handler (router-opts hm) 'onf))
                             (router-opts hm) st next))))

;; oracle-router : (Listof Entry) (U HM #f) (Listof Opt) OState (U (OState -> Answer) #f) -> Answer
;; NF is the not-found handler, bare or on-not-found's; OPTS give the 400's
;; and the 405's.
(define (oracle-router entries nf opts st next)
  (unless (equal? nf '(next)) (set! routers-passed (+ routers-passed 1)))
  (let ((path (ostate-path st)))
    ;; §5: the 400 handler gets the request as it came to the router.
    (define (bad-request)
      (let ((br (opt-handler opts 'br)))
        (if br
            (begin (seen! (if (ostate-match st) 'br-under-match 'br-unmatched))
                   (oracle-handler br st next))
            (cons '() response-400))))
    (define (not-found)
      (when (and nf (eq? (car nf) 'nf))
        (seen! (cond ((not (ostate-match st)) 'nf-unmatched)
                     ((not (ostate-mbase st)) 'nf-under-route)
                     ((not (string=? (st-route st) (car (ostate-mbase st)))) 'nf-under-route-under-mount)
                     (last-mount-wrapped 'nf-under-wrapped-mount)
                     (else 'nf-under-plain-mount))))
      (if nf (oracle-handler nf st next) (cons '() response-404)))
    (if (not (starts-with-slash? path))
        (not-found)
        (let* ((psegs (path-segments path))
               (cands (filter-map (lambda (item) (match-item item psegs path))
                                  (flatten entries "" '()))))
          (if (null? cands)
              (not-found)
              (let ((w (best cands)))
                (if (eq? w 'tie)
                    (cons '((oracle-tie)) '(oracle-tie))
                    (let ((decoded (decode-captures (cand-caps w) path)))
                      (if decoded
                          (oracle-matched w decoded opts st next)
                          (bad-request))))))))))

(define (handler-router? h)
  (or (eq? (car h) 'router) (and (eq? (car h) 'wrapped) (handler-router? (caddr h)))))

(define (oracle-matched w decoded opts st next)
  (let* ((item (cand-item w))
         (base (or (ostate-mbase st) (list "" '() "")))
         (route-text (string-append (car base) (cadr item)))
         (params (append (cadr base) decoded))
         (match (cons route-text params)))
    (if (eq? (car item) 'froute)
        (let ((h (pick-method (cadddr item) (ostate-method st))))
          (if h
              (begin
                (when (handler-router? h)
                  (seen! (if (ostate-mbase st) 'router-under-route-under-mount 'router-under-route)))
                (run-stack (list-ref item 4) (lambda (s) (oracle-handler h s next))
                           (make-ostate (ostate-method st) (ostate-path st) (ostate-query st) match
                                        (ostate-mbase st) #f)))
              ;; §5: the 405 handler gets the request with the route's match, as
              ;; the route's handler would, but no group's middleware runs; the
              ;; router sets allow on what it answers.
              (let ((mna (opt-handler opts 'mna)) (allow (allow-of (cadddr item))))
                (if mna
                    (begin
                      (seen! (if (ostate-mbase st) 'mna-under-mount 'mna-top))
                      (let ((r (oracle-handler mna (make-ostate (ostate-method st) (ostate-path st)
                                                                (ostate-query st) match (ostate-mbase st) #f)
                                               next)))
                        (cons (car r) (leaf-response-allow (cadr mna) allow))))
                    (cons '() (response-405 allow))))))
        (let* ((path (ostate-path st))
               (end (cand-taken w))
               (taken (substring path 0 end))
               (after (substring path end (string-length path)))
               (rest (if (member after '("" "/")) "/" after))
               (mbase (list route-text params (string-append (caddr base) taken))))
          (run-stack (cadddr item)
                     (lambda (s)
                       (let ((marker (ostate-marker s)))
                         (unless marker (seen! 'mount-handed-as-is))
                         (set! last-mount-wrapped (pair? (cadddr item)))
                         (oracle-handler (caddr item)
                                         (if marker
                                             (make-ostate (ostate-method s) (car marker) (ostate-query s)
                                                          (caddr marker) (cadr marker) #f)
                                             s)
                                         next)))
                     (make-ostate (ostate-method st) path (ostate-query st) match (ostate-mbase st)
                                  (list rest mbase match)))))))

;; run-stack : Stack (OState -> Answer) OState -> Answer
;; MW = (mw Tag): hands on the request; (rw Tag): with the path rewritten;
;; (fresh Tag Method Path Query): a request it made itself; (mr Tag
;; Entries): a router of its own, each route's handler and its not-found
;; handler what follows it.
(define (run-stack stack inner st)
  (if (null? stack)
      (inner st)
      (let* ((mw (car stack))
             (tag (cadr mw))
             (on (lambda (s) (run-stack (cdr stack) inner s)))
             (r (case (car mw)
                  ((rw) (on (st-with-path st (string-append "/rw" (ostate-path st)))))
                  ((fresh) (seen! 'fresh-ran) (on (make-ostate (caddr mw) (cadddr mw) (list-ref mw 4) #f #f #f)))
                  ((mr) (seen! 'router-middleware-ran) (oracle-router (caddr mw) '(next) '() st on))
                  (else (on st)))))
        (cons (append (list (oracle-in-event tag st)) (car r) (list (list 'out tag))) (cdr r)))))

;; oracle-answer : HM Req -> (List (Listof Event) Response (Listof Tag) (Listof Tag))
;; The events, the response, the middleware applied during the request
;; (none), and the middleware applied when the tree was made, sorted.
;; The last few answers, kept for the same table and request asked again:
;; a property tallies its cases before it checks them.
(define recent-oracle '())

(define (oracle-answer hm req)
  (let ((hit (find (lambda (x) (and (eq? (car x) hm) (eq? (cadr x) req))) recent-oracle)))
    (if hit
        (caddr hit)
        (let ((a (oracle-answer-fresh hm req)))
          (set! recent-oracle (cons (list hm req a) (if (> (length recent-oracle) 15) (take recent-oracle 15) recent-oracle)))
          a))))

(define (oracle-answer-fresh hm req)
  (set! routers-passed 0)
  (set! oracle-seen '())
  (guard (e (#t (list 'oracle-raised (describe e))))
    (let ((r (oracle-handler hm (make-ostate (car req) (cadr req) (caddr req) #f #f #f) #f)))
      (list (car r) (cdr r) '() (sort-tags (expected-applies hm))))))

;; =================================================================================
;; The router, built from the same model.
;; =================================================================================

(define the-log '())
(define the-applied '())
(define (note! x) (set! the-log (cons x the-log)))
(define (note-applied! tag) (set! the-applied (cons tag the-applied)))
(define (take-log!) (let ((l (reverse the-log))) (set! the-log '()) l))
(define (take-applied!) (let ((l (reverse the-applied))) (set! the-applied '()) l))

(define (real-lookups r)
  (let loop ((names lookup-names) (acc '()))
    (if (null? names)
        (reverse acc)
        (let ((v (req-path-param r (car names)))) (loop (cdr names) (cons v acc))))))

(define (real-leaf-event id r)
  (let* ((method (req-method r)) (path (req-path r)) (mp (req-mount-path r)) (query (req-query r))
         (rt (req-route r)) (params (req-path-params r)) (lookups (real-lookups r)))
    (list 'leaf id method path mp query rt params lookups)))

(define (real-in-event tag r)
  (let* ((method (req-method r)) (path (req-path r)) (mp (req-mount-path r)) (query (req-query r))
         (rt (req-route r)) (params (req-path-params r)))
    (list 'in tag method path mp query rt params)))

(define (real-nf-event id r) (cons 'nf (cdr (real-leaf-event id r))))

(define (real-leaf-res id) (make-res 200 (list (cons "x-leaf" (symbol->string id))) #f))

;; observing-mw : Tag (Handler -> Handler) -> Middleware
;; A middleware that notes TAG when applied, notes what it reads on the way
;; in and out on the way out, and runs (THROUGH next) on the request.
(define (observing-mw tag through)
  (lambda (next)
    (note-applied! tag)
    (let ((inner (through next)))
      (lambda (r)
        (note! (real-in-event tag r))
        (let ((res (inner r)))
          (note! (list 'out tag))
          res)))))

;; build-mw : MW -> Middleware
(define (build-mw mw)
  (let ((tag (cadr mw)))
    (case (car mw)
      ((rw) (observing-mw tag (lambda (next)
                                (lambda (r) (next (req-with-path r (string-append "/rw" (req-path r))))))))
      ((fresh) (let ((method (caddr mw)) (path (cadddr mw)) (query (list-ref mw 4)))
                 (observing-mw tag (lambda (next)
                                     (lambda (r)
                                       (next (make-test-req method (if query (string-append path "?" query) path))))))))
      ((mr) (observing-mw tag (lambda (next) (make-router (build-mr-routes (caddr mw) next) next))))
      (else (observing-mw tag (lambda (next) next))))))

;; build-mr-routes : (Listof Entry) Handler -> (Listof Route)
;; A middleware router's routes, each method's handler NEXT.
(define (build-mr-routes entries next)
  (let loop ((es entries) (acc '()))
    (if (null? es)
        (reverse acc)
        (let* ((e (car es))
               (ms (let mloop ((ms (cadddr e)) (macc '()))
                     (if (null? ms)
                         (reverse macc)
                         (mloop (cdr ms) (cons (case (car (car ms)) ((ANY) (ANY next)) (else (GET next))) macc)))))
               (built (apply route (cadr e) ms)))
          (loop (cdr es) (cons built acc))))))

;; build-handler : HM -> Handler
;; Each piece is made in turn, by explicit loops: no map, whose order Chez
;; does not fix, makes anything that notes.
(define (build-handler hm)
  (case (car hm)
    ((leaf) (let ((id (cadr hm))) (lambda (r) (note! (real-leaf-event id r)) (real-leaf-res id))))
    ((nf) (let ((id (cadr hm))) (lambda (r) (note! (real-nf-event id r)) (real-leaf-res id))))
    ((br mna) (let ((kind (car hm)) (id (cadr hm)))
                (lambda (r) (note! (cons kind (cdr (real-leaf-event id r)))) (real-leaf-res id))))
    ((wrapped) (let ((inner (build-handler (caddr hm)))) (wrap inner (observing-mw (cadr hm) (lambda (next) next)))))
    ((router)
     (let* ((routes (build-entries (cadr hm)))
            (nf (and (caddr hm) (build-handler (caddr hm))))
            (opts (build-opts (router-opts hm))))
       (apply make-router routes (if nf (cons nf opts) opts))))))

;; build-opts : (Listof Opt) -> (Listof RouterOption)
(define (build-opts opts)
  (let loop ((os opts) (acc '()))
    (if (null? os)
        (reverse acc)
        (let* ((o (car os))
               (built (case (car o)
                        ((onf) (on-not-found (build-handler (list 'nf (cadr o)))))
                        ((br) (on-bad-request (build-handler (list 'br (cadr o)))))
                        (else (on-method-not-allowed (build-handler (list 'mna (cadr o))))))))
          (loop (cdr os) (cons built acc))))))

(define (build-entries entries)
  (let loop ((es entries) (acc '()))
    (if (null? es)
        (reverse acc)
        (let ((built (build-entry (car es)))) (loop (cdr es) (cons built acc))))))

(define (build-mws mws)
  (let loop ((ms mws) (acc '()))
    (if (null? ms)
        (reverse acc)
        (loop (cdr ms) (cons (build-mw (car ms)) acc)))))

(define (build-methods methods)
  (let loop ((ms methods) (acc '()))
    (if (null? ms)
        (reverse acc)
        (let ((built (build-method (car ms)))) (loop (cdr ms) (cons built acc))))))

(define (build-method m)
  (let ((sym (car m)) (h (build-handler (caddr m))))
    (if (eq? (cadr m) 'method)
        (METHOD sym h)
        (case sym
          ((GET) (GET h)) ((POST) (POST h)) ((PUT) (PUT h)) ((PATCH) (PATCH h))
          ((DELETE) (DELETE h)) ((OPTIONS) (OPTIONS h)) ((ANY) (ANY h))))))

(define (build-entry e)
  (case (car e)
    ((route) (let ((ms (build-methods (cadddr e))))
               (if (caddr e) (apply route (cadr e) (caddr e) ms) (apply route (cadr e) ms))))
    ((group) (let* ((mws (build-mws (caddr e))) (es (build-entries (cadddr e))))
               (apply group (cadr e) mws es)))
    ((mount) (let ((h (build-handler (caddr e)))) (mount (cadr e) h)))))

;; make-request : Req -> Req
(define (make-request req)
  (let ((base (make-test-req (car req) (if (caddr req) (string-append "/?" (caddr req)) "/"))))
    (req-with-path base (cadr req))))

(define (response-triple res)
  (cond ((and (pair? res) (eq? (car res) 'raised)) res)
        ((not (res? res)) (list 'not-a-response res))
        (else (guard (e (#t (list 'unreadable-body (describe e))))
                (let* ((status (res-status res)) (headers (res-headers res))
                       (body (res-body->bytevector res)))
                  (list status headers body))))))

;; built : HM -> (U Handler (List 'construction-raised String))
(define (built hm)
  (guard (e (#t (list 'construction-raised (describe e))))
    (build-handler hm)))

;; real-answer : HM Req -> (List (Listof Event) Response (Listof Tag) (Listof Tag))
;; As oracle-answer's, from the router: what it noted, its response, what
;; was applied during the request, and what was applied making it, sorted.
;; The last tree built, kept while the cases ask the same one: a router
;; holds no state of a request's, so one built tree answers them all.
(define last-built #f)

(define (built-once hm)
  (if (and last-built (eq? (car last-built) hm))
      (cdr last-built)
      (let* ((h (built hm)) (made (sort-tags (take-applied!))) (both (cons h made)))
        (set! last-built (cons hm both))
        both)))

(define (real-answer hm req)
  (take-log!)
  (take-applied!)
  (let* ((both (built-once hm))
         (h (car both))
         (made (cdr both)))
    (if (pair? h)
        h
        (let* ((r (make-request req))
               (res (guard (e (#t (list 'raised (describe e)))) (h r)))
               (events (take-log!))
               (during (take-applied!)))
          (list events (response-triple res) during made)))))

;; The router's constructors, which name themselves as a refusal's who.
(define router-whos '(make-router route group mount METHOD GET POST PUT PATCH DELETE OPTIONS ANY))

;; refusal? : Any -> Boolean
;; An assertion violation from one of the router's own constructors, with
;; a message: not a crash inside one, such as a type error from car.
(define (refusal? e)
  (and (assertion-violation? e) (who-condition? e) (memq (condition-who e) router-whos)
       (message-condition? e) (string? (condition-message e)) #t))

;; real-verdict : HM -> (U 'accepted 'refused (List ...))
;; Whether making HM's tree is refused, by a router constructor's
;; assertion violation; refused, too, only if no middleware of the top
;; router's own was applied first.
(define (real-verdict hm)
  (take-applied!)
  (let* ((outcome (guard (e ((refusal? e) 'refused)
                            ((assertion-violation? e) (list 'crashed (describe e)))
                            (#t (list 'other-raise (describe e))))
                    (build-handler hm)
                    'accepted))
         (applied (take-applied!))
         (own (own-tags hm)))
    (if (and (eq? outcome 'refused) (exists (lambda (t) (memq t own)) applied))
        (list 'refused-after-applying (filter (lambda (t) (memq t own)) applied))
        outcome)))

;; own-tags : HM -> (Listof Tag)
;; The tags of the top router's own groups.
(define (own-tags hm)
  (define (entries-tags es)
    (concat-map (lambda (e)
                  (if (eq? (car e) 'group)
                      (append (map cadr (caddr e)) (entries-tags (cadddr e)))
                      '()))
                es))
  (case (car hm)
    ((wrapped) (own-tags (caddr hm)))
    ((router) (entries-tags (cadr hm)))
    (else '())))

;; =================================================================================
;; Generators
;; =================================================================================

;; rw?: groups' middleware may rewrite the path, make a request, or be a
;; router; valid?: keep only what the oracle accepts; bad?: values may hold
;; bad escapes, bad UTF-8 or raw characters a path can't hold; deep?:
;; routers nest more; opts?: routers may have 400 and 405 handlers, and an
;; on-not-found one.
(define-record-type (cfg make-cfg cfg?) (fields rw? valid? bad? deep? opts?))

;; Words: plain ones to collide, and ones holding the rest of what a word
;; may: . ~ : @ * and the sub-delims.
(define word-weights
  '((6 . "a") (6 . "b") (5 . "users") (5 . "new") (2 . "edit") (1 . "A") (1 . "x.y")
    (1 . "a:b") (1 . "~u") (1 . "v1") (1 . "a*b") (1 . "@") (1 . "a!b") (1 . "$") (1 . "(p)")
    (1 . "+1") (1 . "k=v") (1 . "a,b;c") (1 . "'q'") (1 . "&x") (1 . "-_.~")))
(define all-words (map cdr word-weights))
(define g-word (g-weighted word-weights))
(define g-param (lambda (s) (draw* s ((n (g-pick param-names))) (cons (string-append ":" n) s))))
(define g-catch (lambda (s) (draw* s ((n (g-pick catch-names))) (cons (string-append "*" n) s))))
(define g-mid-seg (g-choose (list (cons 6 g-word) (cons 4 g-param))))
(define g-last-seg (g-choose (list (cons 45 g-word) (cons 30 g-param) (cons 12 g-catch) (cons 13 (g-const "")))))

(define (segs->template segs) (apply string-append (map (lambda (x) (string-append "/" x)) segs)))

(define gen-route-template
  (g-choose
   (list (cons 8 (g-const ""))
         (cons 10 (g-const "/"))
         (cons 82 (lambda (s)
                    (draw* s ((k (g-range 0 2)) (mids (g-list k g-mid-seg)) (end g-last-seg))
                      (cons (segs->template (append mids (list end))) s)))))))

(define gen-group-prefix
  (g-choose
   (list (cons 30 (g-const ""))
         (cons 60 (lambda (s)
                    (draw* s ((k (g-range 1 2)) (segs (g-list k g-mid-seg)))
                      (cons (segs->template segs) s))))
         (cons 3 (g-const "/a/"))
         (cons 3 (g-const "/*r"))
         (cons 4 (g-const "/")))))

(define gen-mount-template
  (g-choose
   (list (cons 8 (g-const ""))
         (cons 92 (lambda (s)
                    (draw* s ((k (g-range 1 2)) (segs (g-list k g-mid-seg)))
                      (cons (segs->template segs) s)))))))

(define method-forms
  '((6 . (GET short)) (2 . (GET method)) (4 . (POST short)) (1 . (POST method)) (2 . (PUT short))
    (2 . (PATCH short)) (3 . (DELETE short)) (1 . (DELETE method)) (2 . (OPTIONS short))
    (2 . (ANY short)) (1 . (ANY method)) (2 . (HEAD method)) (2 . (PROPFIND method))
    (1 . (M-SEARCH method))))

;; rename-captures : String -> String
;; T with each name replaced by its rename: the same shape, other names.
(define (rename-captures t)
  (if (string=? t "")
      t
      (segs->template
       (map (lambda (text)
              (let ((seg (parse-seg text)))
                (if (and (memq (car seg) '(param catch)) (assoc (cadr seg) renames))
                    (string-append (if (eq? (car seg) 'param) ":" "*") (cdr (assoc (cadr seg) renames)))
                    text)))
            (template-segments t)))))

;; gen-methods : Cfg Nat String -> Gen (Listof MEntry)
;; One to three entries, each of its own method.
(define (gen-methods c depth joined)
  (lambda (s)
    (draw* s ((k (g-weighted '((9 . 1) (7 . 2) (4 . 3)))))
      (let loop ((acc '()) (tries 0) (s s))
        (if (or (= (length acc) k) (= tries 12))
            (cons (reverse acc) s)
            (draw* s ((form (g-weighted method-forms)))
              (if (assq (car form) acc)
                  (loop acc (+ tries 1) s)
                  (draw* s ((h (gen-route-handler c depth joined)))
                    (loop (cons (list (car form) (cadr form) h) acc) (+ tries 1) s)))))))))

;; gen-route-handler : Cfg Nat String -> Gen HM
;; Mostly a leaf; now and then a router, whose table has the route's own
;; template renamed, since a router under a route sees the whole path.
(define (gen-route-handler c depth joined)
  (lambda (s)
    (draw* s ((r (g-int 100)))
      (cond ((and (> depth 0) (< r (if (cfg-deep? c) 45 20)) (starts-with-slash? joined))
             (let ((renamed (rename-captures joined)))
               (draw* s ((methods (gen-methods c 0 renamed))
                         (seed (g-chance (if (cfg-deep? c) 1 7) (if (cfg-deep? c) 2 10)))
                         (inner (gen-router-seeded c (- depth 1) (if seed (list (list 'route renamed #f methods)) '()) 2))
                         (nf (g-chance 1 2)))
                 (cons (if nf
                           (list 'router (cadr inner) '(nf n)
                                 (filter (lambda (o) (not (eq? (car o) 'onf))) (router-opts inner)))
                           inner)
                       s))))
            ((< r 23) (cons (list 'wrapped 'w (list 'leaf 'h)) s))
            (else (cons (list 'leaf 'h) s))))))

(define (gen-mount-handler c depth)
  (lambda (s)
    (draw* s ((r (g-int 100)))
      (cond ((and (> depth 0) (< r (if (cfg-deep? c) 75 55))) ((gen-router c (- depth 1)) s))
            ((and (> depth 0) (< r (if (cfg-deep? c) 90 65)))
             (draw* s ((inner (gen-router c (- depth 1)))) (cons (list 'wrapped 'w inner) s)))
            ((< r 65) (cons (list 'wrapped 'w (list 'leaf 'h)) s))
            (else (cons (list 'leaf 'h) s))))))

;; gen-mws : Cfg Nat -> Gen (Listof MW)
;; With rw?, a middleware may also rewrite the path, hand on a request it
;; made, or be a router of its own.
(define (gen-mws c n)
  (g-list n (lambda (s)
              (draw* s ((kind (g-weighted (if (cfg-rw? c)
                                              '((64 . mw) (12 . rw) (12 . fresh) (12 . mr))
                                              '((1 . mw))))))
                (case kind
                  ((fresh) (draw* s ((method gen-method)
                                     (path (g-pick '("/" "/a" "/b" "/users/7" "/users/new" "/a/b/c" "/new/"
                                                     "/x.y/~u" "/a/7/b")))
                                     (query (g-weighted '((3 . #f) (1 . "f=1")))))
                             (cons (list 'fresh 'm method path query) s)))
                  ((mr) (draw* s ((es gen-mr-entries)) (cons (list 'mr 'm es) s)))
                  (else (cons (list kind 'm) s)))))))

;; gen-mr-entries : Gen (Listof Entry)
;; A middleware router's table: one or two routes, each ANY or GET, now
;; and then a catch-all that takes every path; kept only as the oracle
;; accepts it.
(define gen-mr-entries
  (lambda (s)
    (draw* s ((k (g-range 1 2))
              (ts (g-list k (g-choose (list (cons 3 (g-const "/*rest")) (cons 7 gen-route-template)))))
              (ms (g-list k (g-weighted '((3 . ANY) (1 . GET))))))
      (let loop ((ts ts) (ms ms) (acc '()))
        (cond ((null? ts)
               (cons (if (null? acc) '((route "/*rest" #f ((ANY short (next))))) (reverse acc)) s))
              (else
               (let ((e (list 'route (car ts) #f (list (list (car ms) 'short '(next))))))
                 (loop (cdr ts) (cdr ms)
                       (if (router-refusal (reverse (cons e acc))) acc (cons e acc))))))))))

(define (gen-route c depth prefix)
  (lambda (s)
    (draw* s ((t gen-route-template)
              (named (g-chance 1 4))
              (name (g-pick '(r1 r2 r3)))
              (methods (gen-methods c depth (string-append prefix t))))
      (cons (list 'route t (and named name) methods) s))))

(define (gen-group c depth gdepth prefix)
  (lambda (s)
    (draw* s ((p gen-group-prefix)
              (nmw (g-weighted '((3 . 0) (5 . 1) (2 . 2))))
              (mws (gen-mws c nmw))
              (nchild (g-weighted '((4 . 1) (4 . 2) (2 . 3))))
              (children (g-list nchild (gen-entry c depth (+ gdepth 1) (string-append prefix p)))))
      (cons (list 'group p mws children) s))))

(define (gen-mount c depth)
  (lambda (s)
    (draw* s ((t gen-mount-template) (h (gen-mount-handler c depth)))
      (cons (list 'mount t h) s))))

(define (gen-entry c depth gdepth prefix)
  (lambda (s)
    (draw* s ((kind (g-weighted (cond ((>= gdepth 2) '((75 . route) (25 . mount)))
                                      ((cfg-deep? c) '((45 . route) (25 . group) (30 . mount)))
                                      (else '((60 . route) (18 . group) (22 . mount)))))))
      (case kind
        ((route) ((gen-route c depth prefix) s))
        ((group) ((gen-group c depth gdepth prefix) s))
        (else ((gen-mount c depth) s))))))

;; gen-router-seeded : Cfg Nat (Listof Entry) Nat -> Gen HM
;; SEEDED, then up to N more entries. With valid?, each entry is kept only
;; if the oracle accepts the table with it, after a few tries.
(define (gen-router-seeded c depth seeded nmax)
  (lambda (s)
    (draw* s ((n (g-range (if (null? seeded) 1 0) nmax)) (empty (g-chance 1 30)))
      (let loop ((i 0) (acc (reverse seeded)) (s s))
        (if (or (= i n) (and empty (null? seeded)))
            (draw* s ((nf (g-chance (if (cfg-deep? c) 2 1) 4)) (opts (gen-opts c nf)))
              (cons (router-with (list 'router '() #f opts)
                                 (cond ((and empty (null? seeded)) '())
                                       ((null? acc) (list '(route "/a" #f ((GET short (leaf h))))))
                                       (else (reverse acc)))
                                 (and nf '(nf n)))
                    s))
            (let retry ((tries 0) (s s))
              (draw* s ((e (gen-entry c depth 0 "")))
                (cond ((or (not (cfg-valid? c))
                           (not (handler-refusal (list 'router (reverse (cons e acc)) #f))))
                       (loop (+ i 1) (cons e acc) s))
                      ((< tries 4) (retry (+ tries 1) s))
                      (else (loop (+ i 1) acc s))))))))))

(define (gen-router c depth) (gen-router-seeded c depth '() 5))

;; gen-opts : Cfg Boolean -> Gen (Listof Opt)
;; With opts?, a 400 handler a time in three, a 405 handler as often, and
;; an on-not-found one a time in four when NF? says no bare one is there,
;; in any order. Their ids are numbered later.
(define (gen-opts c nf?)
  (lambda (s)
    (if (not (cfg-opts? c))
        (cons '() s)
        (draw* s ((br (g-chance 1 3)) (mna (g-chance 1 3)) (onf (g-chance 1 4)))
          ((g-shuffle (append (if br '((br b)) '()) (if mna '((mna a)) '())
                              (if (and onf (not nf?)) '((onf n)) '())))
           s)))))

;; --- ids --------------------------------------------------------------------------

;; number-ids : HM -> HM
;; Every leaf, not-found handler, wrapper and middleware a tag of its own.
(define (number-ids hm) (let-pair* (((hm k) (number-handler hm 1))) hm))

(define (make-id prefix k) (string->symbol (string-append prefix (number->string k))))

(define (number-handler hm k)
  (case (car hm)
    ((leaf) (cons (list 'leaf (make-id "h" k)) (+ k 1)))
    ((nf) (cons (list 'nf (make-id "n" k)) (+ k 1)))
    ((wrapped) (let-pair* (((inner k2) (number-handler (caddr hm) (+ k 1))))
                 (cons (list 'wrapped (make-id "w" k) inner) k2)))
    ((router) (let-pair* (((es k2) (number-entries (cadr hm) k))
                            ((nf k3) (if (caddr hm) (number-handler (caddr hm) k2) (cons #f k2)))
                            ((opts k4) (number-opts (router-opts hm) k3)))
                (cons (router-with (list 'router '() #f opts) es nf) k4)))))

;; number-opts : (Listof Opt) Nat -> (Pair (Listof Opt) Nat)
;; Each option's handler an id of its own: n, b or a and a number.
(define (number-opts opts k)
  (let loop ((os opts) (acc '()) (k k))
    (if (null? os)
        (cons (reverse acc) k)
        (let ((kind (car (car os))))
          (loop (cdr os)
                (cons (list kind (make-id (case kind ((onf) "n") ((br) "b") (else "a")) k)) acc)
                (+ k 1))))))

(define (number-entries es k)
  (let loop ((es es) (acc '()) (k k))
    (if (null? es)
        (cons (reverse acc) k)
        (let-pair* (((e k2) (number-entry (car es) k))) (loop (cdr es) (cons e acc) k2)))))

(define (number-entry e k)
  (case (car e)
    ((route) (let loop ((ms (cadddr e)) (acc '()) (k k))
               (if (null? ms)
                   (cons (list 'route (cadr e) (caddr e) (reverse acc)) k)
                   (let-pair* (((h k2) (number-handler (caddr (car ms)) k)))
                     (loop (cdr ms) (cons (list (car (car ms)) (cadr (car ms)) h) acc) k2)))))
    ((mount) (let-pair* (((h k2) (number-handler (caddr e) k))) (cons (list 'mount (cadr e) h) k2)))
    ((group) (let loop ((ms (caddr e)) (acc '()) (k k))
               (if (null? ms)
                   (let-pair* (((es k2) (number-entries (cadddr e) k)))
                     (cons (list 'group (cadr e) (reverse acc) es) k2))
                   (loop (cdr ms) (cons (cons (car (car ms)) (cons (make-id "m" k) (cddr (car ms)))) acc)
                         (+ k 1)))))))

;; gen-table : Cfg Nat -> Gen HM
;; A router of DEPTH levels, numbered, wrapped now and then.
(define (gen-table c depth)
  (lambda (s)
    (draw* s ((hm (gen-router c depth)) (wrapped (g-chance 1 7)))
      (cons (number-ids (if wrapped (list 'wrapped 'w hm) hm)) s))))

;; --- values -------------------------------------------------------------------------

(define plain-values
  '("7" "42" "new" "a" "b" "users" "edit" "A" "x-y" "~" "a.b" "+" "a+b" "." ".." "x.y" "v1" "a:b"
    "@" "a*b" "~u"))

;; gen-scalar : Gen Char
;; A Unicode scalar value: ASCII, controls, and each UTF-8 length, with its
;; edges.
(define gen-scalar
  (let ((g (g-choose
            (list (cons 25 (g-range #x20 #x7E))
                  (cons 15 (lambda (s) (draw* s ((c (g-pick word-char-list))) (cons (char->integer c) s))))
                  (cons 6 (g-pick '(#x2F #x25 #x2B #x3F #x23 #x00 #x20)))
                  (cons 5 (g-range #x00 #x1F))
                  (cons 2 (g-const #x7F))
                  (cons 12 (g-range #x80 #x7FF))
                  (cons 8 (g-range #x800 #xD7FF))
                  (cons 6 (g-range #xE000 #xFFFF))
                  (cons 4 (g-pick '(#xD7FF #xE000 #xFFFD #xFFFE #xFFFF #x80 #x7FF #x800)))
                  (cons 12 (g-range #x10000 #x10FFFF))
                  (cons 3 (g-pick '(#x10000 #x10FFFF #x1F600 #x1D11E)))))))
    (lambda (s) (draw* s ((cp g)) (cons (integer->char cp) s)))))

;; gen-char-unit : Char Boolean -> Gen String
;; C, bare half the time when a word may hold it (or it is /, when
;; SLASH-BARE?), else each of its UTF-8 bytes escaped, in upper case 7 times
;; in 10.
(define (gen-char-unit c slash-bare?)
  (lambda (s)
    (draw* s ((bare (g-chance 1 2)) (upper (g-chance 7 10)))
      (cons (if (and bare (or (memv c word-char-list) (and slash-bare? (char=? c #\/))))
                  (string c)
                  (apply string-append
                         (map (lambda (b) (escape-byte b upper))
                              (bytevector->u8-list (string->utf8 (string c))))))
              s))))

;; gen-units : String Boolean -> Gen (Listof String)
(define (gen-units text slash-bare?)
  (lambda (s)
    (let loop ((cs (string->list text)) (acc '()) (s s))
      (if (null? cs)
          (cons (reverse acc) s)
          (draw* s ((u (gen-char-unit (car cs) slash-bare?))) (loop (cdr cs) (cons u acc) s))))))

(define (gen-scalar-string lo hi)
  (lambda (s)
    (draw* s ((k (g-range lo hi)) (cs (g-list k gen-scalar)))
      (cons (list->string cs) s))))

(define gen-encoded-value
  (lambda (s)
    (draw* s ((text (gen-scalar-string 1 4)) (units (gen-units text #f)))
      (cons (apply string-append units) s))))

;; A word with one character escaped: "%6Eew" is not the word new.
;; gen-escaped : String -> Gen String
;; W, not empty, with one of its characters escaped. §5 matches the path
;; undecoded, so it no longer matches the word W.
(define (gen-escaped w)
  (lambda (s)
    (draw* s ((i (g-int (string-length w))) (upper (g-chance 1 2)))
      (cons (string-append (substring w 0 i)
                           (escape-byte (char->integer (string-ref w i)) upper)
                           (substring w (+ i 1) (string-length w)))
            s))))

(define gen-encoded-word
  (lambda (s) (draw* s ((w (g-pick all-words)) (e (gen-escaped w))) (cons e s))))

;; Bad tokens. Each is bad wherever it sits between whole characters; the
;; end-only ones only where no hex digit follows, so at a value's end.
(define malformed-tokens '("%G1" "%4g" "%-" "%g0" "%%41" "%x" "%4%41" "%Z"))
(define end-only-tokens '("%" "%4" "%A" "%f"))
(define bad-utf8-tokens
  '("%C0%80" "%C1%BF" "%c0%af" "%E0%80%AF" "%E0%9F%BF" "%F0%82%82%AC" "%F0%8F%BF%BF"
    "%ED%A0%80" "%ED%BF%BF" "%ed%b0%80" "%F4%90%80%80" "%F5%80%80%80" "%F7%BF%BF%BF"
    "%F8%88%80%80%80" "%FF" "%FE" "%ff" "%80" "%BF" "%8f" "%C2" "%E2%82" "%F0%9F%98" "%e2"
    "%C3%28" "%E2%28%A1" "%F0%28%8C%BC"))
;; The last ones are Latin-1 characters whose code points, read as bytes,
;; spell UTF-8: raw, they are still characters past ASCII.
(define raw-tokens
  (list "\xE9;" "\x20AC;" "\x1D11E;" "\x80;" "\xFFFD;" "\x10FFFF;" "\xA0;" "\x7FF;"
        "\xC3;\xA9;" "%C3\xA9;" "\xC2;\x80;" "\xE2;%82%AC" "%E2\x82;%AC" "%F0%9F%98\x80;" "\xC3;%A9"))

;; The raw ASCII characters a capture can't hold: all but RFC 3986's
;; pchar, written out above as the word characters, and /, which ends a
;; parameter, and %, which the escape tokens hold. The controls, space,
;; " # < > ? [ \ ] ^ ` { | } and DEL.
(define raw-ascii-tokens
  (filter-map (lambda (i)
                (let ((c (integer->char i)))
                  (and (not (memv c word-char-list)) (not (memv c '(#\/ #\%))) (string c))))
              (iota 128)))

(define (gen-bad-token end?)
  (g-choose (list (cons 3 (g-pick malformed-tokens))
                  (cons (if end? 2 0) (g-pick end-only-tokens))
                  (cons 5 (g-pick bad-utf8-tokens))
                  (cons 3 (g-pick raw-tokens))
                  (cons 3 (g-pick raw-ascii-tokens)))))

;; gen-good-units : Gen (Listof String)
(define gen-good-units
  (g-choose (list (cons 1 (lambda (s) (draw* s ((v (g-pick plain-values)))
                                         (cons (map string (string->list v)) s))))
                  (cons 1 (lambda (s) (draw* s ((text (gen-scalar-string 0 3)) (units (gen-units text #f)))
                                         (cons units s)))))))

;; A good value with a bad token at a whole character's place.
(define gen-bad-value
  (lambda (s)
    (draw* s ((units gen-good-units)
              (i (g-range 0 (length units)))
              (token (gen-bad-token (= i (length units)))))
      (cons (apply string-append (append (take units i) (list token) (list-tail units i))) s))))

;; gen-value : Cfg -> Gen String
;; What fills a parameter: never empty.
(define (gen-value c)
  (g-choose (list (cons 45 (g-pick plain-values))
                  (cons 25 gen-encoded-value)
                  (cons 5 gen-encoded-word)
                  (cons (if (cfg-bad? c) 25 0) gen-bad-value))))

(define (gen-value-or-empty c)
  (g-choose (list (cons 1 (g-const "")) (cons 4 (gen-value c)))))

;; --- paths ------------------------------------------------------------------------

;; Pat = (Listof (U (w String) (p) (c) (rest)))
(define (seg->pat seg)
  (case (car seg) ((word) (list 'w (cadr seg))) ((param) '(p)) (else '(c))))

;; handler-patterns : HM -> (Listof Pat)
;; The shapes of the paths HM's tree takes, through its mounts.
(define (handler-patterns hm)
  (case (car hm)
    ((leaf nf) '(((rest))))
    ((wrapped) (handler-patterns (caddr hm)))
    ((router)
     (concat-map (lambda (item)
                   (let ((pat (map seg->pat (template-segs (cadr item)))))
                     (if (eq? (car item) 'froute)
                         (list pat)
                         ;; a mounted router's own shapes, and any rest, which it may not take
                         (map (lambda (sub) (append pat sub))
                              (let ((subs (handler-patterns (caddr item))))
                                (if (member '((rest)) subs) subs (cons '((rest)) subs)))))))
                 (filter (lambda (item) (starts-with-slash? (cadr item))) (flatten (cadr hm) "" '()))))))

(define (segs->path segs) (apply string-append (map (lambda (x) (string-append "/" x)) segs)))

;; gen-instance : Cfg Pat -> Gen String
(define (gen-instance c pat)
  (lambda (s)
    (let loop ((pat pat) (segs '()) (s s))
      (if (null? pat)
          (cons (segs->path (reverse segs)) s)
          (case (car (car pat))
            ((w) (let ((w (cadr (car pat))))
                   (draw* s ((r (g-int 100)))
                     (if (and (< r 4) (> (string-length w) 0))
                         (draw* s ((e (gen-escaped w))) (loop (cdr pat) (cons e segs) s))
                         (loop (cdr pat) (cons w segs) s)))))
            ((p) (draw* s ((v (gen-value c))) (loop (cdr pat) (cons v segs) s)))
            ((c) (draw* s ((k (g-weighted '((3 . 1) (3 . 2) (1 . 3)))) (vs (g-list k (gen-value-or-empty c))))
                   (loop (cdr pat) (append (reverse vs) segs) s)))
            (else (draw* s ((k (g-weighted '((3 . 0) (3 . 1) (2 . 2)))) (vs (g-list k (gen-value-or-empty c))))
                    (loop (cdr pat) (append (reverse vs) segs) s))))))))

(define (gen-noise-path c)
  (lambda (s)
    (draw* s ((k (g-range 1 3))
              (segs (g-list k (g-choose (list (cons 4 g-word) (cons 3 (gen-value c)) (cons 1 (g-const "")))))))
      (cons (segs->path segs) s))))

;; gen-mutation : Cfg String -> Gen String
;; PATH with a trailing slash added or taken, a slash doubled, the leading
;; slash dropped, a segment added, or another path not beginning with /.
(define (gen-mutation c path)
  (lambda (s)
    (draw* s ((kind (g-int 8)))
      (case kind
        ((0) (cons (string-append path "/") s))
        ((1) (cons (if (and (ends-with-slash? path) (> (string-length path) 1))
                         (substring path 0 (- (string-length path) 1))
                         (string-append path "/"))
                     s))
        ((2) (let ((slashes (filter (lambda (i) (char=? (string-ref path i) #\/)) (iota (string-length path)))))
               (if (null? slashes)
                   (cons (string-append "/" path) s)
                   (draw* s ((i (g-pick slashes)))
                     (cons (string-append (substring path 0 i) "/" (substring path i (string-length path))) s)))))
        ((3) (cons (if (starts-with-slash? path) (substring path 1 (string-length path)) path) s))
        ((4) (cons "*" s))
        ((5) (cons "" s))
        ((6) (cons (string-append path "/new") s))
        (else (draw* s ((v (gen-value c))) (cons (string-append path "/" v) s)))))))

;; gen-path : Cfg HM -> Gen String
;; Mostly one of the table's own shapes filled in; some noise; now and then
;; mutated.
(define (gen-path c hm)
  (let ((pats (handler-patterns hm)))
    (lambda (s)
      (draw* s ((r (g-int 100))
                (base (if (or (null? pats) (< r 12))
                          (gen-noise-path c)
                          (lambda (s) (draw* s ((pat (g-pick pats))) ((gen-instance c pat) s)))))
                (m (g-int 100))
                (path (if (< m 25) (gen-mutation c base) (g-const base))))
        (cons path s)))))

(define gen-method
  (g-weighted '((25 . GET) (15 . HEAD) (12 . POST) (8 . PUT) (6 . PATCH) (10 . DELETE) (6 . OPTIONS)
                (6 . PROPFIND) (4 . TRACE) (2 . M-SEARCH))))
(define gen-query (g-weighted '((7 . #f) (2 . "q=1") (1 . ""))))

(define (gen-request c hm)
  (lambda (s)
    (draw* s ((method gen-method) (path (gen-path c hm)) (query gen-query))
      (cons (list method path query) s))))

;; =================================================================================
;; The runner and the shrinker
;; =================================================================================

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

;; property-failures : Symbol Nat (Nat -> (Listof Case)) Check Shrinks -> (Listof Failure)
;; Runs N case groups; shrinks the first failures; reports each on stdout.
(define (property-failures name n gen-cases check shrinks tally)
  (let loop ((i 0) (found '()) (failed 0) (ran 0))
    (if (= i n)
        (begin
          (summary! name ran failed tally)
          (append (reverse found)
                  (if (> failed (length found)) (list (list 'and (- failed (length found)) 'more)) '())))
        (let walk ((cases (gen-cases i)) (j 0) (found found) (failed failed) (ran ran))
          (if (null? cases)
              (loop (+ i 1) found failed ran)
              (let ((evidence (safe-check check (car cases))))
                (cond ((not evidence) (walk (cdr cases) (+ j 1) found failed (+ ran 1)))
                      ((< (length found) shrunk-at-most)
                       (let* ((small (shrink (car cases) check shrinks))
                              (ev (safe-check check small))
                              (failure (list name 'seed seed 'case i j 'minimised small 'evidence ev))
                              (seen (exists (lambda (f) (equal? (list-ref f 7) small)) found)))
                         (unless seen (report! failure))
                         (walk (cdr cases) (+ j 1) (if seen found (cons failure found)) (+ failed 1) (+ ran 1))))
                      (else (walk (cdr cases) (+ j 1) found (+ failed 1) (+ ran 1))))))))))

(define (report! failure)
  (let ((out (current-output-port)))
    (put-string out "router-properties: failing case:\n")
    (write failure out)
    (newline out)
    (flush-output-port out)))

;; Tallies: what the cases exercised, counted per property.
(define (make-tally) (vector '()))
(define (tally-counts t) (vector-ref t 0))
(define (tally! t key)
  (let* ((counts (tally-counts t)) (p (assq key counts)))
    (vector-set! t 0 (cons (cons key (if p (+ (cdr p) 1) 1))
                           (filter (lambda (q) (not (eq? (car q) key))) counts)))))

(define (summary! name ran failed tally)
  (let ((out (current-output-port)))
    (put-string out (string-append "router-properties: " (symbol->string name) ": "
                                   (number->string ran) " cases, " (number->string failed) " failing"))
    (unless (null? (tally-counts tally))
      (put-string out " (")
      (put-string out (string-join (map (lambda (p) (string-append (symbol->string (car p)) " "
                                                                   (number->string (cdr p))))
                                        (list-sort (lambda (a b) (string<? (symbol->string (car a))
                                                                           (symbol->string (car b))))
                                                   (tally-counts tally)))
                                   ", "))
      (put-string out ")"))
    (newline out)
    (flush-output-port out)))

;; --- shrinking a table ------------------------------------------------------------

(define shrunk-leaf '(leaf hs))

;; handler-shrinks : HM -> (Listof HM)
;; HM with one thing taken out or made simpler, or a router inside it in
;; its place.
(define (handler-shrinks hm)
  (case (car hm)
    ((leaf nf br mna) '())
    ((wrapped) (cons (caddr hm) (map (lambda (x) (list 'wrapped (cadr hm) x)) (handler-shrinks (caddr hm)))))
    ((router) (append (nested-routers (cadr hm))
                      (if (caddr hm) (list (router-with hm (cadr hm) #f)) '())
                      (map (lambda (i) (list 'router (cadr hm) (caddr hm) (remove-at (router-opts hm) i)))
                           (iota (length (router-opts hm))))
                      (map (lambda (es) (router-with hm es (caddr hm))) (entries-shrinks (cadr hm)))
                      (if (= (length (cadr hm)) 1) (list (router-with hm '() (caddr hm))) '())))))

;; nested-routers : (Listof Entry) -> (Listof HM)
;; The routers directly under the table's routes and mounts.
(define (nested-routers es)
  (concat-map (lambda (e)
                (let ((router-of (lambda (h) (cond ((eq? (car h) 'router) (list h))
                                                   ((and (eq? (car h) 'wrapped) (eq? (car (caddr h)) 'router))
                                                    (list (caddr h)))
                                                   (else '())))))
                  (case (car e)
                    ((route) (concat-map (lambda (m) (router-of (caddr m))) (cadddr e)))
                    ((mount) (router-of (caddr e)))
                    ((group) (nested-routers (cadddr e))))))
              es))

(define (inner-handler-shrinks hm)
  (if (equal? hm shrunk-leaf) '() (cons shrunk-leaf (handler-shrinks hm))))

(define (entries-shrinks es)
  (append
   (if (> (length es) 1) (map (lambda (i) (remove-at es i)) (iota (length es))) '())
   (concat-map (lambda (i) (map (lambda (repl) (splice-at es i repl)) (entry-shrinks (list-ref es i))))
               (iota (length es)))))

(define (push-prefix p e)
  (case (car e)
    ((route) (list 'route (string-append p (cadr e)) (caddr e) (cadddr e)))
    ((mount) (list 'mount (string-append p (cadr e)) (caddr e)))
    ((group) (list 'group (string-append p (cadr e)) (caddr e) (cadddr e)))))

;; template-shrinks : String -> (Listof String)
;; T with one segment taken out.
(define (template-shrinks t)
  (let ((segs (template-segments t)))
    (if (< (length segs) 2)
        '()
        (map (lambda (i) (segs->template (remove-at segs i))) (iota (length segs))))))

;; entry-shrinks : Entry -> (Listof (Listof Entry))
;; Each a list of entries to put in E's place.
(define (entry-shrinks e)
  (case (car e)
    ((route)
     (let ((t (cadr e)) (name (caddr e)) (ms (cadddr e)))
       (append
        (if name (list (list (list 'route t #f ms))) '())
        (if (> (length ms) 1) (map (lambda (i) (list (list 'route t name (remove-at ms i)))) (iota (length ms))) '())
        (concat-map (lambda (i)
                      (let ((m (list-ref ms i)))
                        (map (lambda (h) (list (list 'route t name (splice-at ms i (list (list (car m) (cadr m) h))))))
                             (inner-handler-shrinks (caddr m)))))
                    (iota (length ms)))
        (map (lambda (t2) (list (list 'route t2 name ms))) (template-shrinks t)))))
    ((group)
     (let ((p (cadr e)) (mws (caddr e)) (es (cadddr e)))
       (append
        (list (map (lambda (x) (push-prefix p x)) es))
        (map (lambda (i) (list (list 'group p (remove-at mws i) es))) (iota (length mws)))
        (map (lambda (es2) (list (list 'group p mws es2))) (entries-shrinks es))
        (map (lambda (p2) (list (list 'group p2 mws es))) (template-shrinks p)))))
    ((mount)
     (append
      (map (lambda (h) (list (list 'mount (cadr e) h))) (inner-handler-shrinks (caddr e)))
      (map (lambda (t2) (list (list 'mount t2 (caddr e)))) (template-shrinks (cadr e)))))))

;; --- shrinking a request ----------------------------------------------------------

(define (path-shrinks path)
  (let* ((n (string-length path))
         (segs (if (starts-with-slash? path) (template-segments path) '())))
    (append
     (if (> (length segs) 1) (map (lambda (i) (segs->path (remove-at segs i))) (iota (length segs))) '())
     (map (lambda (i) (string-append (substring path 0 i) (substring path (+ i 1) n)))
          (filter (lambda (i) (not (and (= i 0) (starts-with-slash? path)))) (iota (min n 48)))))))

(define (request-shrinks req)
  (let ((method (car req)) (path (cadr req)) (query (caddr req)))
    (append
     (if (eq? method 'GET) '() (list (list 'GET path query)))
     (if query (list (list method path #f)) '())
     (map (lambda (p) (list method p query)) (path-shrinks path)))))

;; =================================================================================
;; Sanity: §5's examples, against the oracle and the router
;; =================================================================================

(define (leaf-ev id method path mp query rt params)
  (list 'leaf id method path mp query rt params (lookups-in params)))
(define (in-ev tag method path mp query rt params) (list 'in tag method path mp query rt params))
(define (out-ev tag) (list 'out tag))

;; answer : HM (Listof Event) Response -> Answer
(define (answer hm events response) (list events response '() (sort-tags (expected-applies hm))))

;; sanity : HM (Listof (Pair Req (Pair Events Response))) -> (List (Listof Answer) (Listof Answer))
;; Each request's answer from the oracle and from the router, beside what
;; §5 says.
(define (sanity hm rows)
  (let loop ((rows rows) (oracle '()) (real '()) (said '()))
    (if (null? rows)
        (list (reverse said) (reverse oracle) (reverse real))
        (let* ((req (car (car rows)))
               (o (oracle-answer hm req))
               (r (real-answer hm req))
               (s (answer hm (cadr (car rows)) (caddr (car rows)))))
          (loop (cdr rows) (cons o oracle) (cons r real) (cons s said))))))

(define-syntax sanity-row
  (syntax-rules ()
    ((_ name hm-expr rows-expr)
     (let ((result (guard (e (#t (list 'raised (describe e))))
                     (sanity hm-expr rows-expr))))
       (test-equal name
         (if (and (pair? result) (eq? (car result) 'raised)) result (list (car result) (car result)))
         (if (and (pair? result) (eq? (car result) 'raised)) 'sanity-raised (cdr result)))))))

(define (verdicts hms)
  (let loop ((hms hms) (acc '()))
    (if (null? hms)
        (reverse acc)
        (let* ((hm (car hms))
               (o (if (handler-refusal hm) 'refused 'accepted))
               (r (real-verdict hm)))
          (loop (cdr hms) (cons (list o r) acc))))))

(define (rt t . ms) (list 'route t #f ms))
(define (get id) (list 'GET 'short (list 'leaf id)))
(define (router . es) (list 'router es #f))

(define example-app
  (router (rt "/" (get 'home))
          (rt "/users" (get 'list-users) (list 'POST 'short '(leaf create-user)))
          (rt "/users/new" (get 'new-user-form))
          (rt "/users/:id" (get 'show-user) (list 'DELETE 'short '(leaf delete-user)))
          (list 'group "/admin" '((mw wrap-admin)) (list (rt "/stats" (get 'stats))))
          (list 'mount "/assets" '(leaf assets))))

(test-begin "router-properties")

(test-equal "the arguments are a seed and a multiplier, whole numbers, or none"
  #t (and parsed-arguments #t))

;; first-draws : Nat Nat -> (Listof Nat)
;; Property PROP's cases 0 to N - 1, each case's first draw of (g-int 100).
(define (first-draws prop n)
  (map (lambda (i) (car ((g-int 100) (case-state prop i)))) (iota n)))

;; same-neighbours : (Listof Nat) -> Nat — how many neighbours in XS are equal.
(define (same-neighbours xs)
  (let loop ((xs xs) (k 0))
    (if (or (null? xs) (null? (cdr xs)))
        k
        (loop (cdr xs) (if (= (car xs) (cadr xs)) (+ k 1) k)))))

(test-equal "the generators: neighbouring cases start apart: of each property's first 4,000 cases, 10 to 90 of the 3,999 neighbouring pairs draw the same first (g-int 100), where chance is about 40"
  '()
  (filter-map (lambda (prop)
                (let ((k (same-neighbours (first-draws prop 4000))))
                  (and (not (<= 10 k 90)) (list prop k))))
              '(1 2 3 4 5 6 7)))

(test-equal "the generators: g-int is uniform where n doesn't divide 32,768: of 32,768 draws of (g-int 20000) from one state, 62% to 66% are below 12,768, where a uniform draw gives 63.8% and the 15 bits taken modulo n 77.9%"
  '()
  (let loop ((i 0) (below 0) (s 20261030))
    (if (= i 32768)
        (if (<= 20316 below 21627) '() (list below))
        (draw* s ((x (g-int 20000)))
          (loop (+ i 1) (if (< x 12768) (+ below 1) below) s)))))

(sanity-row "sanity: §5's example app: a parameter, a group's middleware, a mount, HEAD by GET"
  example-app
  (list (list '(GET "/users/7" #f) (list (leaf-ev 'show-user 'GET "/users/7" "" #f "/users/:id" '(("id" . "7"))))
              (leaf-response 'show-user))
        (list '(GET "/" #f) (list (leaf-ev 'home 'GET "/" "" #f "/" '())) (leaf-response 'home))
        (list '(GET "/admin/stats" "q=1")
              (list (in-ev 'wrap-admin 'GET "/admin/stats" "" "q=1" "/admin/stats" '())
                    (leaf-ev 'stats 'GET "/admin/stats" "" "q=1" "/admin/stats" '())
                    (out-ev 'wrap-admin))
              (leaf-response 'stats))
        (list '(GET "/assets/css/a.css" #f) (list (leaf-ev 'assets 'GET "/css/a.css" "/assets" #f "/assets" '()))
              (leaf-response 'assets))
        (list '(HEAD "/users" #f) (list (leaf-ev 'list-users 'HEAD "/users" "" #f "/users" '()))
              (leaf-response 'list-users))))

(sanity-row "sanity: DELETE /users/new is /users/new's 405, beside /users/:id's DELETE; PUT /users lists GET, HEAD, POST"
  example-app
  (list (list '(DELETE "/users/new" #f) '() (response-405 "GET, HEAD"))
        (list '(PUT "/users" #f) '() (response-405 "GET, HEAD, POST"))))

(sanity-row "sanity: the trailing slash counts, a path not beginning with / matches nothing, /px is not /p"
  (router (rt "/users" (get 'u)) (list 'mount "/p" '(leaf p)) (list 'route "/*r" #f (list (get 'any))))
  (list (list '(GET "/users/" #f) (list (leaf-ev 'any 'GET "/users/" "" #f "/*r" '(("r" . "users/"))))
              (leaf-response 'any))
        (list '(GET "*" #f) '() response-404)
        (list '(GET "" #f) '() response-404)
        (list '(GET "users" #f) '() response-404)
        (list '(GET "/px" #f) (list (leaf-ev 'any 'GET "/px" "" #f "/*r" '(("r" . "px")))) (leaf-response 'any))))

(sanity-row "sanity: (group \"/admin\" mws (route \"\" ...)) serves /admin"
  (router (list 'group "/admin" '((mw m)) (list (rt "" (get 'admin)))))
  (list (list '(GET "/admin" #f)
              (list (in-ev 'm 'GET "/admin" "" #f "/admin" '()) (leaf-ev 'admin 'GET "/admin" "" #f "/admin" '())
                    (out-ev 'm))
              (leaf-response 'admin))
        (list '(GET "/admin/" #f) '() response-404)))

(sanity-row "sanity: /files/*p takes /files/ and /files/a/b, slashes kept, not /files"
  (router (rt "/files/*p" (get 'f)))
  (list (list '(GET "/files/" #f) (list (leaf-ev 'f 'GET "/files/" "" #f "/files/*p" '(("p" . ""))))
              (leaf-response 'f))
        (list '(GET "/files/a/b" #f) (list (leaf-ev 'f 'GET "/files/a/b" "" #f "/files/*p" '(("p" . "a/b"))))
              (leaf-response 'f))
        (list '(GET "/files//a/" #f) (list (leaf-ev 'f 'GET "/files//a/" "" #f "/files/*p" '(("p" . "/a/"))))
              (leaf-response 'f))
        (list '(GET "/files" #f) '() response-404)))

(sanity-row "sanity: mount /p takes /p and /p/..., its handler sees the rest, / when nothing or only / follows"
  (router (list 'mount "/p" '(leaf p)))
  (list (list '(GET "/p" #f) (list (leaf-ev 'p 'GET "/" "/p" #f "/p" '())) (leaf-response 'p))
        (list '(GET "/p/" #f) (list (leaf-ev 'p 'GET "/" "/p" #f "/p" '())) (leaf-response 'p))
        (list '(POST "/p/a/b" #f) (list (leaf-ev 'p 'POST "/a/b" "/p" #f "/p" '())) (leaf-response 'p))
        (list '(GET "/p//" #f) (list (leaf-ev 'p 'GET "//" "/p" #f "/p" '())) (leaf-response 'p))
        (list '(GET "/px" #f) '() response-404)))

(sanity-row "sanity: route /p beats mount /p for /p; /p/ beats mount /p for /p/; the mount takes /p/x"
  (router (list 'mount "/p" '(leaf m)) (rt "/p" (get 'r)) (rt "/p/" (get 'slash)))
  (list (list '(GET "/p" #f) (list (leaf-ev 'r 'GET "/p" "" #f "/p" '())) (leaf-response 'r))
        (list '(GET "/p/" #f) (list (leaf-ev 'slash 'GET "/p/" "" #f "/p/" '())) (leaf-response 'slash))
        (list '(GET "/p/x" #f) (list (leaf-ev 'm 'GET "/x" "/p" #f "/p" '())) (leaf-response 'm))))

(sanity-row "sanity: a word beats a parameter, a parameter a catch-all; /p/ beats /p/*r for /p/"
  (router (rt "/a/*r" (get 'c)) (rt "/a/:x" (get 'p)) (rt "/a/b" (get 'w)) (rt "/a/" (get 'e)))
  (list (list '(GET "/a/b" #f) (list (leaf-ev 'w 'GET "/a/b" "" #f "/a/b" '())) (leaf-response 'w))
        (list '(GET "/a/c" #f) (list (leaf-ev 'p 'GET "/a/c" "" #f "/a/:x" '(("x" . "c")))) (leaf-response 'p))
        (list '(GET "/a/c/d" #f) (list (leaf-ev 'c 'GET "/a/c/d" "" #f "/a/*r" '(("r" . "c/d"))))
              (leaf-response 'c))
        (list '(GET "/a/" #f) (list (leaf-ev 'e 'GET "/a/" "" #f "/a/" '())) (leaf-response 'e))))

(sanity-row "sanity: the match backtracks: /users/new/edit is /users/:id/edit, not /users/new"
  (router (rt "/users/new" (get 'new)) (rt "/users/:id/edit" (get 'edit)))
  (list (list '(GET "/users/new/edit" #f)
              (list (leaf-ev 'edit 'GET "/users/new/edit" "" #f "/users/:id/edit" '(("id" . "new"))))
              (leaf-response 'edit))
        (list '(GET "/users/new" #f) (list (leaf-ev 'new 'GET "/users/new" "" #f "/users/new" '()))
              (leaf-response 'new))))

(sanity-row "sanity: /users/%6Eew is /users/:id with id new; + stays +; %2F stays in its segment, decodes to /; dot segments pass"
  (router (rt "/users/new" (get 'new)) (rt "/users/:id" (get 'show)) (rt "/f/*p" (get 'f)))
  (list (list '(GET "/users/%6Eew" #f) (list (leaf-ev 'show 'GET "/users/%6Eew" "" #f "/users/:id" '(("id" . "new"))))
              (leaf-response 'show))
        (list '(GET "/users/a+b%2Fc" #f)
              (list (leaf-ev 'show 'GET "/users/a+b%2Fc" "" #f "/users/:id" '(("id" . "a+b/c"))))
              (leaf-response 'show))
        (list '(GET "/f/../../etc/passwd" #f)
              (list (leaf-ev 'f 'GET "/f/../../etc/passwd" "" #f "/f/*p" '(("p" . "../../etc/passwd"))))
              (leaf-response 'f))
        (list '(GET "/users/%00%E2%82%AC%F0%9F%98%80" #f)
              (list (leaf-ev 'show 'GET "/users/%00%E2%82%AC%F0%9F%98%80" "" #f "/users/:id"
                             (list (cons "id" (string #\nul #\x20AC #\x1F600)))))
              (leaf-response 'show))))

(sanity-row "sanity: a word escaped in the path matches no word, since matching is on the path undecoded"
  (router (rt "/a:b" (get 'w1)) (rt "/~u/k=v" (get 'w2)) (rt "/:x" (get 'p)) (rt "/~u/*r" (get 'c)))
  (list (list '(GET "/a%3Ab" #f) (list (leaf-ev 'p 'GET "/a%3Ab" "" #f "/:x" '(("x" . "a:b")))) (leaf-response 'p))
        (list '(GET "/a:b" #f) (list (leaf-ev 'w1 'GET "/a:b" "" #f "/a:b" '())) (leaf-response 'w1))
        (list '(GET "/%7Eu/k=v" #f) '() response-404)
        (list '(GET "/~u/k%3Dv" #f) (list (leaf-ev 'c 'GET "/~u/k%3Dv" "" #f "/~u/*r" '(("r" . "k=v"))))
              (leaf-response 'c))
        (list '(GET "/%61" #f) (list (leaf-ev 'p 'GET "/%61" "" #f "/:x" '(("x" . "a")))) (leaf-response 'p))))

(sanity-row "sanity: a malformed escape, bytes that aren't UTF-8 or a raw non-ASCII character answer an empty 400, and no middleware runs"
  (router (list 'group "/g" '((mw m)) (list (rt "/u/:id" (get 'u)) (list 'mount "/m/:k" '(leaf mt)))))
  (map (lambda (path) (list (list 'POST path #f) '() response-400))
       (list "/g/u/%" "/g/u/a%4" "/g/u/%G1" "/g/u/%FF" "/g/u/%C0%80" "/g/u/%ED%A0%80" "/g/u/%F4%90%80%80"
             "/g/u/%E2%82" "/g/u/%80" "/g/u/\xE9;" "/g/m/%/x" "/g/m/a%E2%82/x")))

(sanity-row "sanity: a raw character a path can't hold in a capture answers an empty 400: a control, space, \" # < > ? [ \\ ] ^ ` { | } or DEL"
  (router (list 'group "/g" '((mw m)) (list (rt "/u/:id" (get 'u)) (rt "/f/*p" (get 'f)) (list 'mount "/m/:k" '(leaf mt)))))
  (map (lambda (path) (list (list 'GET path #f) '() response-400))
       (list "/g/u/a b" "/g/u/a\x0;" "/g/u/\x1F;" "/g/u/a\x7F;" "/g/u/\"" "/g/u/a#" "/g/u/<" "/g/u/>b"
             "/g/u/a?b" "/g/u/[" "/g/u/\\" "/g/u/]" "/g/u/^" "/g/u/`" "/g/u/{" "/g/u/|" "/g/u/}"
             "/g/f/a/b c" "/g/f/a/%41/|" "/g/m/a b/x" "/g/m/%41\x9;/x")))

(sanity-row "sanity: a mount's rest is no capture: its raw characters reach the mounted handler as they came"
  (router (list 'mount "/m" '(leaf mt)))
  (list (list '(GET "/m/a b/<c>" #f) (list (leaf-ev 'mt 'GET "/a b/<c>" "/m" #f "/m" '())) (leaf-response 'mt))))

(sanity-row "sanity: the 400 handler gets the request as it came to the router; the 405 handler gets the route's match, no group's middleware runs, and its answer gets the route's allow"
  (list 'router (list (rt "/u/:id" (get 'u)) (list 'group "/g" '((mw m)) (list (rt "/x" (get 'x) (list 'PROPFIND 'method '(leaf p))))))
        #f '((mna a) (br b)))
  (list (list '(GET "/u/%FF" #f) (list (list 'br 'b 'GET "/u/%FF" "" #f #f '() (lookups-in '()))) (leaf-response 'b))
        (list '(DELETE "/u/a b" "q=1") (list (list 'br 'b 'DELETE "/u/a b" "" "q=1" #f '() (lookups-in '()))) (leaf-response 'b))
        (list '(PUT "/u/7" #f) (list (list 'mna 'a 'PUT "/u/7" "" #f "/u/:id" '(("id" . "7")) (lookups-in '(("id" . "7")))))
              (leaf-response-allow 'a "GET, HEAD"))
        (list '(POST "/g/x" #f) (list (list 'mna 'a 'POST "/g/x" "" #f "/g/x" '() (lookups-in '())))
              (leaf-response-allow 'a "GET, HEAD, PROPFIND"))
        (list '(GET "/nope" #f) '() response-404)))

(sanity-row "sanity: on-not-found's handler is the not-found handler; a router under a mount hands its 400 and 405 handlers the mount's match"
  (router (list 'mount "/api/:v" (list 'router (list (rt "/u/:id" (get 'u))) #f '((onf n) (br b) (mna a)))))
  (list (list '(GET "/api/2/zz" #f) (list (list 'nf 'n 'GET "/zz" "/api/2" #f "/api/:v" '(("v" . "2")) (lookups-in '(("v" . "2")))))
              (leaf-response 'n))
        (list '(GET "/api/2/u/%FF" #f) (list (list 'br 'b 'GET "/u/%FF" "/api/2" #f "/api/:v" '(("v" . "2")) (lookups-in '(("v" . "2")))))
              (leaf-response 'b))
        (list '(PUT "/api/2/u/7" #f)
              (list (list 'mna 'a 'PUT "/u/7" "/api/2" #f "/api/:v/u/:id" '(("v" . "2") ("id" . "7"))
                          (lookups-in '(("v" . "2") ("id" . "7")))))
              (leaf-response-allow 'a "GET, HEAD"))))

(sanity-row "sanity: HEAD goes to HEAD, else GET, else ANY, and sees HEAD; ANY takes the unlisted methods"
  (router (rt "/g" (get 'g) (list 'ANY 'short '(leaf any)))
          (rt "/a" (list 'POST 'short '(leaf post)) (list 'ANY 'method '(leaf any2)))
          (rt "/h" (get 'g2) (list 'HEAD 'method '(leaf head))))
  (list (list '(HEAD "/g" #f) (list (leaf-ev 'g 'HEAD "/g" "" #f "/g" '())) (leaf-response 'g))
        (list '(PROPFIND "/g" #f) (list (leaf-ev 'any 'PROPFIND "/g" "" #f "/g" '())) (leaf-response 'any))
        (list '(HEAD "/a" #f) (list (leaf-ev 'any2 'HEAD "/a" "" #f "/a" '())) (leaf-response 'any2))
        (list '(POST "/a" #f) (list (leaf-ev 'post 'POST "/a" "" #f "/a" '())) (leaf-response 'post))
        (list '(HEAD "/h" #f) (list (leaf-ev 'head 'HEAD "/h" "" #f "/h" '())) (leaf-response 'head))))

(sanity-row "sanity: allow lists the route's methods as listed, HEAD right after GET when it has none of its own"
  (router (rt "/a" (list 'POST 'short '(leaf a1)) (get 'a2))
          (rt "/b" (get 'b1) (list 'POST 'short '(leaf b2)) (list 'HEAD 'method '(leaf b3)))
          (rt "/c" (list 'PROPFIND 'method '(leaf c1)))
          (rt "/d" (list 'DELETE 'short '(leaf d1)) (list 'GET 'method '(leaf d2))))
  (list (list '(PUT "/a" #f) '() (response-405 "POST, GET, HEAD"))
        (list '(PUT "/b" #f) '() (response-405 "GET, POST, HEAD"))
        (list '(HEAD "/c" #f) '() (response-405 "PROPFIND"))
        (list '(PATCH "/d" #f) '() (response-405 "DELETE, GET, HEAD"))))

(sanity-row "sanity: under mount /api/:v, a router's /users/:id reads /api/:v/users/:id, both params, mount path /api/2"
  (router (list 'mount "/api/:v" (router (rt "/users/:id" (get 'u)) (rt "/" (get 'root)))))
  (list (list '(GET "/api/2/users/7" #f)
              (list (leaf-ev 'u 'GET "/users/7" "/api/2" #f "/api/:v/users/:id" '(("v" . "2") ("id" . "7"))))
              (leaf-response 'u))
        (list '(GET "/api/2" #f) (list (leaf-ev 'root 'GET "/" "/api/2" #f "/api/:v/" '(("v" . "2"))))
              (leaf-response 'root))))

(sanity-row "sanity: around a mount, a group's middleware sees the path as matched, the mount's template and params, and the mounts above"
  (router (list 'mount "/o"
                (router (list 'group "/g" '((mw m)) (list (list 'mount "/m/:k" '(leaf x)))))))
  (list (list '(GET "/o/g/m/5/rest" #f)
              (list (in-ev 'm 'GET "/g/m/5/rest" "/o" #f "/o/g/m/:k" '(("k" . "5")))
                    (leaf-ev 'x 'GET "/rest" "/o/g/m/5" #f "/o/g/m/:k" '(("k" . "5")))
                    (out-ev 'm))
              (leaf-response 'x))))

(sanity-row "sanity: the outer group's middleware is outermost, each list in wrap's order, the last outermost"
  (router (list 'group "" '((mw a) (mw b)) (list (list 'group "/x" '((mw c)) (list (rt "" (get 'h)))))))
  (list (list '(GET "/x" #f)
              (list (in-ev 'b 'GET "/x" "" #f "/x" '()) (in-ev 'a 'GET "/x" "" #f "/x" '())
                    (in-ev 'c 'GET "/x" "" #f "/x" '()) (leaf-ev 'h 'GET "/x" "" #f "/x" '())
                    (out-ev 'c) (out-ev 'a) (out-ev 'b))
              (leaf-response 'h))))

(sanity-row "sanity: a group's middleware runs only on a match; middleware around the router runs for 404, 405 and 400 too"
  (list 'wrapped 'outer (router (list 'group "/g" '((mw m)) (list (rt "/x/:id" (get 'h))))))
  (list (list '(GET "/g/y" #f) (list (in-ev 'outer 'GET "/g/y" "" #f #f '()) (out-ev 'outer)) response-404)
        (list '(POST "/g/x/1" #f) (list (in-ev 'outer 'POST "/g/x/1" "" #f #f '()) (out-ev 'outer))
              (response-405 "GET, HEAD"))
        (list '(GET "/g/x/%ZZ" #f) (list (in-ev 'outer 'GET "/g/x/%ZZ" "" #f #f '()) (out-ev 'outer))
              response-400)))

(sanity-row "sanity: the not-found handler runs when no route takes the path; a router under a route uses its own match"
  (list 'router (list (rt "/x/:id" (list 'GET 'short (router (rt "/x/:n" (get 'inner))))))
        '(nf nf))
  (list (list '(GET "/y" #f) (list (list 'nf 'nf 'GET "/y" "" #f #f '() (lookups-in '()))) (leaf-response 'nf))
        (list '(GET "/x/7" #f) (list (leaf-ev 'inner 'GET "/x/7" "" #f "/x/:n" '(("n" . "7"))))
              (leaf-response 'inner))))

(sanity-row "sanity: a mounted handler sees the rest of the path the router matched, though a middleware rewrote it"
  (router (list 'group "" '((rw m)) (list (list 'mount "/p" '(leaf x)))))
  (list (list '(GET "/p/q" #f)
              (list (in-ev 'm 'GET "/p/q" "" #f "/p" '()) (leaf-ev 'x 'GET "/q" "/p" #f "/p" '()) (out-ev 'm))
              (leaf-response 'x))))

(test-equal "sanity: §5's refusals refused, and its controls accepted, by the oracle and by make-router, two options for one answer among them"
  '((refused refused) (refused refused) (refused refused) (refused refused) (refused refused)
    (refused refused) (refused refused) (refused refused) (refused refused) (refused refused)
    (refused refused) (refused refused) (refused refused) (refused refused) (refused refused)
    (refused refused) (refused refused) (refused refused) (refused refused)
    (accepted accepted) (accepted accepted) (accepted accepted) (accepted accepted) (accepted accepted))
  (guard (e (#t (list 'raised (describe e))))
    (verdicts
     (list (router (rt "/u/:id" (get 'a)) (rt "/u/:name" (get 'b)))
           (router (rt "/u" (get 'a)) (rt "/u" (list 'POST 'short '(leaf b))))
           (router (list 'mount "/p" '(leaf a)) (rt "/p/*r" (get 'b)))
           (router (rt "" (get 'a)))
           (router (rt "/a/." (get 'a)))
           (router (rt "/.." (get 'a)))
           (router (list 'mount "/" '(leaf a)))
           (router (list 'mount "/p/" '(leaf a)))
           (router (list 'mount "/p/*r" '(leaf a)))
           (list 'router (list (list 'route "/a" 'n (list (get 'a))) (list 'route "/b" 'n (list (get 'b)))) #f)
           (router (rt "/a//b" (get 'a)))
           (router (rt "/*r/x" (get 'a)))
           (router (list 'group "/:x" '((mw m)) (list (rt "/b/:x" (get 'a)))))
           (router (rt "/a%20b" (get 'a)))
           (router (rt "users" (get 'a)))
           (list 'router (list (rt "/a" (get 'a))) '(nf n) '((onf n2)))
           (list 'router (list (rt "/a" (get 'a))) #f '((onf n) (br b) (onf n2)))
           (list 'router (list (rt "/a" (get 'a))) #f '((br b) (mna a) (br b2)))
           (list 'router (list (rt "/a" (get 'a))) '(nf n) '((mna a) (mna a2)))
           (router (list 'group "/admin" '((mw m)) (list (rt "" (get 'a)))))
           (router (rt "/users/" (get 'a)) (rt "/users" (get 'b)))
           (router (rt "/p" (get 'a)) (list 'mount "/p" '(leaf b)))
           (router (rt "/a:b/~x/@/a*b" (get 'a)) (rt "/:user-id/*n_2" (get 'b)))
           (list 'router (list (rt "/a" (get 'a))) '(nf n) '((mna a) (br b)))))))

;; =================================================================================
;; The properties
;; =================================================================================

(define valid-cfg (make-cfg #t #t #t #f #t))
;; Deep: routers under mounts and routes more often, and not-found
;; handlers in them, so that four routers deep and a router under a route
;; under a mount are common.
(define deep-cfg (make-cfg #t #t #t #t #t))

;; --- P1 ---------------------------------------------------------------------------

;; Case = (HM Req)
(define (p1-check kase)
  (let ((hm (car kase)) (req (cadr kase)))
    (and (not (handler-refusal hm))
         (let* ((o (oracle-answer hm req)) (r (real-answer hm req)))
           (and (not (equal? o r)) (list 'oracle o 'router r))))))

(define (table-request-shrinks kase)
  (let ((hm (car kase)) (req (cadr kase)))
    (append (map (lambda (h) (list h req)) (handler-shrinks hm))
            (map (lambda (q) (list hm q)) (request-shrinks req)))))

(define p1-tally (make-tally))

(define (tally-answer! t hm req)
  (let ((o (oracle-answer hm req)))
    (when (list? (car o))
      (let ((resp (cadr o)))
        (tally! t (case (car resp) ((200) 'handled) ((400) 's400) ((404) 's404) ((405) 's405) (else 'other)))
        (when (exists (lambda (e) (and (memq (car e) '(leaf nf br mna)) (not (string=? (list-ref e 4) "")))) (car o))
          (tally! t 'under-mount))
        (when (exists (lambda (e) (eq? (car e) 'br)) (car o)) (tally! t 'br-ran))
        (when (exists (lambda (e) (eq? (car e) 'mna)) (car o)) (tally! t 'mna-ran))
        (when (exists (lambda (e) (eq? (car e) 'in)) (car o)) (tally! t 'middleware-ran))
        (when (>= routers-passed 2) (tally! t 'two-routers))
        (when (>= routers-passed 3) (tally! t 'three-routers))
        (when (>= routers-passed 4) (tally! t 'four-routers))
        (for-each (lambda (x) (tally! t x))
                  (fold-left (lambda (acc x) (if (memq x acc) acc (cons x acc))) '() oracle-seen))))
    (when (eq? (car req) 'HEAD) (tally! t 'head))))

(define (p1-cases i)
  (let ((s (case-state 1 i)))
    (draw* s ((deep (g-chance 1 3))
              (depth (g-weighted (if deep '((1 . 2) (3 . 3)) '((2 . 0) (3 . 1) (3 . 2) (3 . 3)))))
              (hm (gen-table (if deep deep-cfg valid-cfg) depth))
              (reqs (g-list 8 (gen-request valid-cfg hm))))
      (for-each (lambda (req) (tally-answer! p1-tally hm req)) reqs)
      (map (lambda (req) (list hm req)) reqs))))

(test-equal "P1: for every table make-router accepts, the router answers every request as the oracle does"
  '()
  (property-failures 'P1 (* 4000 multiplier) p1-cases p1-check table-request-shrinks p1-tally))

;; --- P2 ---------------------------------------------------------------------------

;; transform : HM Nat -> HM
;; HM reordered at every level, and regrouped where that keeps every joined
;; template and every middleware stack: a group with no middleware
;; dissolved into its parent, a group split in two with the same prefix
;; and middleware, a prefix pushed into a group's children, an entry put in
;; a group of no prefix and no middleware.
(define (transform hm k)
  (let-pair* (((hm2 s) ((gen-transform hm) (case-state 20 k)))) hm2))

(define (gen-transform hm)
  (lambda (s)
    (case (car hm)
      ((leaf nf br mna) (cons hm s))
      ((wrapped) (draw* s ((inner (gen-transform (caddr hm)))) (cons (list 'wrapped (cadr hm) inner) s)))
      ;; §5: the options come in any order.
      ((router) (draw* s ((es (gen-transform-entries (cadr hm))) (opts (g-shuffle (router-opts hm))))
                  (cons (router-with (list 'router '() #f opts) es (caddr hm)) s))))))

(define (gen-transform-entries es)
  (lambda (s)
    (let loop ((es es) (acc '()) (s s))
      (if (null? es)
          (draw* s ((shuffled (g-shuffle acc))) (cons shuffled s))
          (draw* s ((inside (gen-transform-inside (car es)))
                    (regrouped (gen-regroup inside)))
            (loop (cdr es) (append (reverse regrouped) acc) s))))))

(define (gen-transform-inside e)
  (lambda (s)
    (case (car e)
      ((route) (let loop ((ms (cadddr e)) (acc '()) (s s))
                 (if (null? ms)
                     (cons (list 'route (cadr e) (caddr e) (reverse acc)) s)
                     (draw* s ((h (gen-transform (caddr (car ms)))))
                       (loop (cdr ms) (cons (list (car (car ms)) (cadr (car ms)) h) acc) s)))))
      ((mount) (draw* s ((h (gen-transform (caddr e)))) (cons (list 'mount (cadr e) h) s)))
      ((group) (draw* s ((es (gen-transform-entries (cadddr e))))
                 (cons (list 'group (cadr e) (caddr e) es) s))))))

;; gen-regroup : Entry -> Gen (Listof Entry)
(define (gen-regroup e)
  (lambda (s)
    (draw* s ((r (g-int 100)))
      (cond ((and (eq? (car e) 'group) (null? (caddr e)) (< r 40))
             (cons (map (lambda (x) (push-prefix (cadr e) x)) (cadddr e)) s))
            ((and (eq? (car e) 'group) (> (length (cadddr e)) 1) (< r 70))
             (draw* s ((k (g-range 1 (- (length (cadddr e)) 1))))
               (cons (list (list 'group (cadr e) (caddr e) (take (cadddr e) k))
                             (list 'group (cadr e) (caddr e) (list-tail (cadddr e) k)))
                       s)))
            ((and (eq? (car e) 'group) (not (string=? (cadr e) "")) (< r 85))
             (cons (list (list 'group "" (caddr e) (map (lambda (x) (push-prefix (cadr e) x)) (cadddr e)))) s))
            ((< r 95) (cons (list (list 'group "" '() (list e))) s))
            (else (cons (list e) s))))))

;; Case = (HM K Req)
(define (p2-check kase)
  (let ((hm (car kase)) (k (cadr kase)) (req (caddr kase)))
    (and (not (handler-refusal hm))
         (let ((hm2 (transform hm k)))
           (if (handler-refusal hm2)
               (list 'transform-refused hm2 (handler-refusal hm2))
               (let* ((a (real-answer hm req)) (b (real-answer hm2 req)))
                 (and (not (equal? (refusal-blind a) (refusal-blind b)))
                      (list 'transformed hm2 'answer a 'transformed-answer b))))))))

;; refusal-blind : Answer -> Answer
;; A refusal's message names its irritants in the table's order, which P2
;; changes; P3 holds what is refused.
(define (refusal-blind a)
  (if (and (pair? a) (eq? (car a) 'construction-raised)) '(construction-raised) a))

(define (p2-shrinks kase)
  (let ((hm (car kase)) (k (cadr kase)) (req (caddr kase)))
    (append (map (lambda (h) (list h k req)) (handler-shrinks hm))
            (map (lambda (q) (list hm k q)) (request-shrinks req)))))

(define p2-tally (make-tally))

(define (p2-cases i)
  (let ((s (case-state 2 i)))
    (draw* s ((depth (g-weighted '((3 . 0) (4 . 1) (3 . 2))))
              (hm (gen-table valid-cfg depth))
              (reqs (g-list 6 (gen-request valid-cfg hm))))
      (unless (equal? hm (transform hm i)) (tally! p2-tally 'changed))
      (map (lambda (req) (list hm i req)) reqs))))

(test-equal "P2: reordering a table and its options, and regrouping it keeping its joined templates and stacks, changes no answer"
  '()
  (property-failures 'P2 (* 2000 multiplier) p2-cases p2-check p2-shrinks p2-tally))

;; --- P3 ---------------------------------------------------------------------------

(define bad-route-templates
  '("/a//b" "//" "/*r/a" "/*r/" "/:x/:x" "/:x/*x" "/a/." "/.." "/." "/:" "/*" "/:a.b" "/*a:b" "/a%20"
    "/a%" "/\xE9;" "/a b" "/a?" "/a#" "/:\xE9;" "" "a" "a/b" "/a/" "/a" "/:id/new" "/users/*rest"))
;; §5: a route lists one method entry or more, each method once.
(define method-lists
  '(()
    ((GET short (leaf h)) (GET short (leaf h)))
    ((GET short (leaf h)) (GET method (leaf h)))
    ((ANY short (leaf h)) (ANY method (leaf h)))
    ((POST short (leaf h)) (GET short (leaf h)) (POST method (leaf h)))
    ((HEAD method (leaf h)) (HEAD method (leaf h)))
    ((PROPFIND method (leaf h)) (GET short (leaf h)) (PROPFIND method (leaf h)))
    ((GET short (leaf h)) (HEAD method (leaf h)) (ANY short (leaf h)))))

;; Symbols for METHOD: not tokens, not upper case, and odd tokens that are.
(define method-symbols
  (map string->symbol
       '("get" "Get" "GEt" "A,B" "GE T" "A\"B" "A(B" "A)B" "A/B" "" "A:B" "A;B" "A=B" "A@B" "A[B" "A]B"
         "A{B" "A}B" "A?B" "A\\B" "A<B" "A>B" "\xC9;" "A\x0;B" "A\tB"
         "M-SEARCH" "A!#$%&'*+-.^_`|~9" "X_Y" "B2" "9")))

(define bad-mount-templates '("/p/" "/" "/p/*r" "" "/*r" "//p" "/p//q" "p" "/p/:x" "/:x/:x"))
(define bad-groups
  (list '(group "/:id" () ((route "/b/:id" #f ((GET short (leaf h))))))
        '(group "/a/" () ((route "/b" #f ((GET short (leaf h))))))
        '(group "/a/" () ((route "" #f ((GET short (leaf h))))))
        '(group "/" () ((route "/b" #f ((GET short (leaf h))))))
        '(group "" () ((route "" #f ((GET short (leaf h))))))
        '(group "/*r" () ((route "/b" #f ((GET short (leaf h))))))
        '(group "/*r" () ((route "" #f ((GET short (leaf h))))))
        '(group "a" () ((route "/b" #f ((GET short (leaf h))))))
        '(group "/g" ((mw m)) ((mount "" (leaf h))))
        '(group "/g" ((mw m)) ((mount "/" (leaf h))))
        '(group "/g" () ((route "a" #f ((GET short (leaf h))))))
        '(group "/g" () ((mount "p" (leaf h))))
        '(group "/g" () ((group "x" () ((route "" #f ((GET short (leaf h))))))))
        '(group "/g" () ((group "/x" () ((route "y/z" #f ((GET short (leaf h))))))))))

;; gen-spoiler : (Listof Entry) -> Gen (Listof Entry)
;; ES with an entry added that the oracle likely refuses: a second
;; template of a shape already there, a route name used twice, a bad
;; template, a bad mount, a METHOD whose symbol is no upper-case token (or
;; an odd one that is), a route with no method or one twice (or one that
;; is fine), or a group whose prefix or children break the joins.
(define (gen-spoiler es)
  (lambda (s)
    (let ((flat (filter (lambda (item) (starts-with-slash? (cadr item))) (flatten es "" '()))))
      (draw* s ((kind (g-int 7)) (pos (g-range 0 (length es))))
        (let ((add (lambda (e) (append (take es pos) (list e) (list-tail es pos)))))
          (case kind
            ((0) (if (null? flat)
                     (cons (add '(route "" #f ((GET short (leaf h))))) s)
                     (draw* s ((item (g-pick flat)))
                       (cons (add (if (eq? (car item) 'froute)
                                        (let ((t (cadr item)))
                                          (if (and (ends-with-catch? t) (> (length (template-segments t)) 1))
                                              (list 'mount (drop-last-segment t) '(leaf h))
                                              (list 'route (rename-captures t) #f '((POST short (leaf h))))))
                                        (list 'route (string-append (rename-captures (cadr item)) "/*zz") #f
                                              '((GET short (leaf h))))))
                               s))))
            ((1) (cons (add '(route "/zz9" r1 ((GET short (leaf h))))) s))
            ((2) (draw* s ((t (g-pick bad-route-templates))) (cons (add (list 'route t #f '((GET short (leaf h))))) s)))
            ((3) (draw* s ((t (g-pick bad-mount-templates))) (cons (add (list 'mount t '(leaf h))) s)))
            ((4) (draw* s ((sym (g-pick method-symbols)))
                   (cons (add (list 'route "/zz8" #f (list (list sym 'method '(leaf h))))) s)))
            ((5) (draw* s ((ms (g-pick method-lists)))
                   (cons (add (list 'route "/zz7" #f ms)) s)))
            (else (draw* s ((g (g-pick bad-groups))) (cons (add g) s)))))))))

(define (ends-with-catch? t)
  (let ((segs (template-segs t))) (and (pair? segs) (eq? (car (last segs)) 'catch))))
(define (drop-last-segment t)
  (let ((segs (template-segments t))) (segs->template (take segs (- (length segs) 1)))))

;; gen-spoiled : HM -> Gen HM
;; The spoiler applied to the top router, or now and then to a router
;; mounted in it; or one more option on the top router, which §5 refuses
;; when an option, or a bare not-found handler, gives its answer already.
(define (gen-spoiled hm)
  (lambda (s)
    (draw* s ((deep (g-chance 1 4)) (more-option (g-chance 1 6)) (kind (g-pick '(onf br mna))))
      (if more-option
          (cons (list 'router (cadr hm) (caddr hm) (append (router-opts hm) (list (list kind 'z)))) s)
      (let ((mounted (filter (lambda (i) (let ((e (list-ref (cadr hm) i)))
                                           (and (eq? (car e) 'mount) (eq? (car (caddr e)) 'router))))
                             (iota (length (cadr hm))))))
        (if (and deep (pair? mounted))
            (draw* s ((i (g-pick mounted)))
              (let* ((e (list-ref (cadr hm) i)) (inner (caddr e)))
                (draw* s ((es (gen-spoiler (cadr inner))))
                  (cons (router-with hm (splice-at (cadr hm) i (list (list 'mount (cadr e) (router-with inner es (caddr inner)))))
                                     (caddr hm))
                          s))))
            (draw* s ((es (gen-spoiler (cadr hm)))) (cons (router-with hm es (caddr hm)) s))))))))

(define (p3-check hm)
  (let* ((expected (if (handler-refusal hm) 'refused 'accepted))
         (actual (real-verdict hm)))
    (and (not (equal? expected actual))
         (list 'oracle expected 'because (handler-refusal hm) 'router actual))))

(define (p3-shrinks hm) (handler-shrinks hm))

(define p3-tally (make-tally))

(define noise-cfg (make-cfg #t #f #t #f #t))

(define (p3-cases i)
  (let ((s (case-state 3 i)))
    (draw* s ((kind (g-int 3))
              (depth (g-weighted '((5 . 0) (4 . 1) (1 . 2))))
              (hm (gen-router (if (= kind 2) noise-cfg valid-cfg) depth))
              (spoiled (if (= kind 1) (gen-spoiled hm) (g-const hm))))
      (let* ((hm (number-ids spoiled)) (why (handler-refusal hm)))
        (tally! p3-tally (if why 'refused 'accepted))
        (when why (tally! p3-tally why))
        (list hm)))))

(test-equal "P3: making a table raises an assertion violation exactly when the oracle refuses it, before any of its middleware is applied"
  '()
  (property-failures 'P3 (* 12000 multiplier) p3-cases p3-check p3-shrinks p3-tally))

;; --- P4 ---------------------------------------------------------------------------

(define p4-table
  '(router ((route "/a/:x" #f ((GET short (leaf px))))
            (route "/c/*p" #f ((GET short (leaf pc))))
            (mount "/m/:y" (leaf pm)))
           #f))

;; Case = (Kind String K): the string, placed by KIND, encoded from state K.
(define (p4-path kase)
  (let* ((kind (car kase)) (text (cadr kase)) (k (caddr kase)))
    (let-pair* (((units s) ((gen-units text (eq? kind 'catch)) (case-state 40 k))))
      (let ((enc (apply string-append units)))
        (case kind
          ((param) (string-append "/a/" enc))
          ((catch) (string-append "/c/" enc))
          (else (let-pair* (((tail s2) ((g-pick '("" "/" "/z/w")) s))) (string-append "/m/" enc tail))))))))

(define (p4-check kase)
  (let* ((kind (car kase)) (text (cadr kase))
         (name (case kind ((param) "x") ((catch) "p") (else "y")))
         (path (p4-path kase))
         (r (real-answer p4-table (list 'GET path #f)))
         (leaf (and (pair? (car r)) (= (length (car r)) 1) (car (car r)))))
    (and (not (and leaf (eq? (car leaf) 'leaf)
                   (equal? (list-ref leaf 7) (list (cons name text)))
                   (equal? (list-ref (list-ref leaf 8) (index-of name lookup-names)) text)))
         (list 'path path 'want (list (cons name text)) 'router r))))

(define (index-of x xs) (let loop ((xs xs) (i 0)) (if (equal? (car xs) x) i (loop (cdr xs) (+ i 1)))))

(define (p4-shrinks kase)
  (let ((text (cadr kase)))
    (map (lambda (i) (list (car kase) (string-append (substring text 0 i) (substring text (+ i 1) (string-length text)))
                           (caddr kase)))
         (filter (lambda (i) (or (eq? (car kase) 'catch) (> (string-length text) 1)))
                 (iota (string-length text))))))

(define p4-tally (make-tally))

(define gen-p4-char
  (g-choose (list (cons 5 gen-scalar) (cons 1 (g-pick (string->list "/%+.~ "))))))

(define (gen-p4-string lo hi)
  (lambda (s)
    (draw* s ((k (g-range lo hi)) (cs (g-list k gen-p4-char)))
      (cons (list->string cs) s))))

(define (p4-cases i)
  (let ((s (case-state 4 i)))
    (draw* s ((text (gen-p4-string 1 8)) (ctext (gen-p4-string 0 8)))
      (when (exists (lambda (c) (> (char->integer c) #xFFFF)) (string->list text)) (tally! p4-tally 'astral))
      (when (exists (lambda (c) (char=? c #\/)) (string->list text)) (tally! p4-tally 'slash))
      (list (list 'param text i) (list 'catch ctext i) (list 'mount text i)))))

(test-equal "P4: any string's UTF-8, percent-encoded, reads back from a parameter, a catch-all with / kept, and a mount's parameter"
  '()
  (property-failures 'P4 (* 6000 multiplier) p4-cases p4-check p4-shrinks p4-tally))

;; --- what a route answers ---------------------------------------------------------

;; leaf-id-of : HM -> Id
;; The leaf a handler of leaves and wrappers ends in.
(define (leaf-id-of h) (if (eq? (car h) 'wrapped) (leaf-id-of (caddr h)) (cadr h)))

;; p7-expected : (Listof MEntry) Symbol -> (List Events Response)
;; HEAD to HEAD, else GET, else ANY; any other method to its own, else
;; ANY; else the 405, allow as the route lists them, HEAD after GET.
(define (p7-expected methods m)
  (let* ((own (assq m methods))
         (chosen (cond (own own)
                       ((and (eq? m 'HEAD) (assq 'GET methods)) => (lambda (x) x))
                       ((assq 'ANY methods) => (lambda (x) x))
                       (else #f))))
    (if chosen
        (let ((id (leaf-id-of (caddr chosen))))
          (list (list (list 'leaf id m)) (leaf-response id)))
        (let* ((listed (map car methods))
               (allow (let loop ((ms listed) (acc '()))
                        (cond ((null? ms) (reverse acc))
                              ((and (eq? (car ms) 'GET) (not (memq 'HEAD listed)))
                               (loop (cdr ms) (cons "HEAD" (cons "GET" acc))))
                              (else (loop (cdr ms) (cons (symbol->string (car ms)) acc)))))))
          (list '() (response-405 (string-join allow ", ")))))))

;; route-response : Flat Symbol -> Response
;; What ITEM answers METHOD in a table of leaves: its handler's 200, or its
;; 405; a mount, its handler's.
(define (route-response item m)
  (if (eq? (car item) 'froute)
      (cadr (p7-expected (cadddr item) m))
      (leaf-response (leaf-id-of (caddr item)))))

;; --- P5 ---------------------------------------------------------------------------

(define good-cfg (make-cfg #f #t #f #f #f))

;; char-boundaries : String Nat Nat -> (Listof Nat)
;; The places in PATH between START and END where a whole character starts
;; or the span ends: not inside an escape, and not before a continuation
;; byte.
(define (char-boundaries path start end)
  (let loop ((i start) (acc '()))
    (if (>= i end)
        (reverse (cons end acc))
        (if (char=? (string-ref path i) #\%)
            (let ((b (+ (* 16 (hex-value (string-ref path (+ i 1)))) (hex-value (string-ref path (+ i 2))))))
              (loop (+ i 3) (if (= (bitwise-and b #xC0) #x80) acc (cons i acc))))
            (loop (+ i 1) (cons i acc))))))

;; Case = (HM Method Path TokenStart TokenEnd Unspoiled)
;; p5-in-capture? : Case -> Boolean
;; Whether the token lies in a capture of the match the path wins, and the
;; unspoiled path wins the same route. (Spoiling an empty segment can let
;; a parameter take it; such a case is left out.)
(define (p5-in-capture? kase)
  (let* ((hm (car kase)) (path (caddr kase)) (ts (cadddr kase)) (te (list-ref kase 4))
         (w (oracle-winner hm path))
         (w0 (oracle-winner hm (list-ref kase 5))))
    (and (cand? w) (cand? w0) (equal? (cand-item w) (cand-item w0))
         (exists (lambda (cap) (and (<= (cadr cap) ts) (<= te (caddr cap)))) (cand-caps w))
         #t)))

;; The spoiled path answers the empty 400 and runs nothing; the same path
;; unspoiled is the same route's, and answers as that route does: so a
;; router that answers 400 to everything fails here.
(define (p5-check kase)
  (let ((hm (car kase)) (method (cadr kase)) (path (caddr kase)) (path0 (list-ref kase 5)))
    (and (p5-in-capture? kase)
         (let* ((r (real-answer hm (list method path #f)))
                (spoiled-ok (and (list? (car r)) (null? (car r)) (equal? (cadr r) response-400) (null? (caddr r))))
                (w (oracle-winner hm path))
                (want (route-response (cand-item w) method))
                (r0 (real-answer hm (list method path0 #f))))
           (cond ((and spoiled-ok (list? (car r0)) (equal? (cadr r0) want)) #f)
                 (else (list 'spoiled r 'unspoiled path0 'want want 'router r0)))))))

(define (p5-shrinks kase) (map (lambda (h) (cons h (cdr kase))) (handler-shrinks (car kase))))

(define p5-tally (make-tally))

(define (p5-cases i)
  (let ((s (case-state 5 i)))
    (draw* s ((hm0 (gen-router good-cfg 0))
              (pat (g-pick (let* ((pats (handler-patterns hm0))
                                  (capturing (filter (lambda (pat) (exists (lambda (x) (memq (car x) '(p c))) pat))
                                                     pats)))
                             (cond ((pair? capturing) capturing) ((pair? pats) pats) (else '(((w ""))))))))
              (path0 (gen-instance good-cfg pat))
              (method gen-method))
      (let* ((hm (number-ids hm0)) (w (oracle-winner hm path0)))
        (if (not (and (cand? w) (pair? (cand-caps w))))
            (begin (tally! p5-tally 'no-capture) '())
            (draw* s ((cap (g-pick (cand-caps w)))
                      (at (g-pick (char-boundaries path0 (cadr cap) (caddr cap))))
                      (token (gen-bad-token (or (= at (string-length path0)) (char=? (string-ref path0 at) #\/)))))
              (let* ((path (string-append (substring path0 0 at) token (substring path0 at (string-length path0))))
                     (kase (list hm method path at (+ at (string-length token)) path0)))
                (if (not (p5-in-capture? kase))
                    (begin (tally! p5-tally 'left-out) '())
                    (begin
                (tally! p5-tally (cond ((member token malformed-tokens) 'malformed)
                                       ((member token end-only-tokens) 'malformed-at-end)
                                       ((member token bad-utf8-tokens) 'bad-utf8)
                                       ((member token raw-ascii-tokens) 'raw-ascii)
                                       (else 'raw-non-ascii)))
                (when (eq? (car (cand-item w)) 'fmount) (tally! p5-tally 'mount-param))
                (when (= (cadr cap) at) (tally! p5-tally 'at-start))
                (when (= (caddr cap) at) (tally! p5-tally 'at-end))
                (tally! p5-tally (if (= (car (route-response (cand-item w) method)) 405) 'unspoiled-405 'unspoiled-handled))
                (list kase))))))))))

(test-equal "P5: a bad escape, bytes not UTF-8, or a raw character past ASCII or outside RFC 3986's pchar, anywhere in a capture, answer the empty 400, and nothing runs"
  '()
  (property-failures 'P5 (* 15000 multiplier) p5-cases p5-check p5-shrinks p5-tally))

;; --- P6 ---------------------------------------------------------------------------

(define no-rw-cfg (make-cfg #f #t #t #f #t))

;; Case = (HM Req)
;; A case counts when the oracle says something reads the request; the
;; router must then read it as many times, so a router that runs nothing
;; fails here.
(define (reads events) (filter (lambda (e) (memq (car e) '(leaf in nf br mna))) events))

(define (p6-check kase)
  (let* ((hm (car kase)) (req (cadr kase)) (given (cadr req))
         (o (oracle-answer hm req)))
    (and (list? (car o))
         (pair? (reads (car o)))
         (let ((r (real-answer hm req)))
           (if (not (list? (car r)))
               (list 'router r)
               (let* ((real-reads (reads (car r)))
                      (bad (filter (lambda (e)
                                     (let ((path (list-ref e 3)) (mp (list-ref e 4)))
                                       (not (or (string=? (string-append mp path) given)
                                                (and (string=? path "/") (string=? mp given))))))
                                   real-reads)))
                 (cond ((not (= (length real-reads) (length (reads (car o)))))
                        (list 'given given 'reads real-reads 'oracle-reads (reads (car o))))
                       ((pair? bad) (list 'given given 'events bad))
                       (else #f))))))))

(define p6-tally (make-tally))

(define (p6-cases i)
  (let ((s (case-state 6 i)))
    (draw* s ((depth (g-weighted '((1 . 1) (3 . 2) (2 . 3))))
              (hm (gen-table no-rw-cfg depth))
              (reqs (g-list 8 (gen-request no-rw-cfg hm))))
      (for-each (lambda (req)
                  (let ((o (oracle-answer hm req)))
                    (when (and (list? (car o)) (null? (reads (car o)))) (tally! p6-tally 'no-read))
                    (when (pair? (car o))
                      (for-each (lambda (e)
                                  (when (memq (car e) '(leaf in nf br mna))
                                    (let ((mp (list-ref e 4)))
                                      (tally! p6-tally (cond ((string=? mp "") 'top)
                                                             ((string=? (list-ref e 3) "/") 'rest-slash)
                                                             (else 'under-mount))))))
                                (car o)))))
                reqs)
      (map (lambda (req) (list hm req)) reqs))))

(test-equal "P6: wherever a handler or a middleware reads them, req-mount-path then req-path is the path given, but for a rest / standing for nothing"
  '()
  (property-failures 'P6 (* 3000 multiplier) p6-cases p6-check table-request-shrinks p6-tally))

;; --- P7 ---------------------------------------------------------------------------

(define all-methods '(GET HEAD POST PUT PATCH DELETE OPTIONS PROPFIND TRACE M-SEARCH))

;; strip : HM -> HM
;; No middleware anywhere, and no wrapper: P7's events are its leaves'.
(define (strip hm)
  (case (car hm)
    ((wrapped) (strip (caddr hm)))
    ((router) (list 'router (map strip-entry (cadr hm)) (caddr hm)))
    (else hm)))
(define (strip-entry e)
  (case (car e)
    ((route) (list 'route (cadr e) (caddr e) (map (lambda (m) (list (car m) (cadr m) (strip (caddr m)))) (cadddr e))))
    ((mount) (list 'mount (cadr e) (strip (caddr e))))
    ((group) (list 'group (cadr e) '() (map strip-entry (cadddr e))))))

;; Case = (HM Path Method)
(define (p7-check kase)
  (let* ((hm (car kase)) (path (cadr kase)) (m (caddr kase)) (w (oracle-winner hm path)))
    (and (cand? w) (eq? (car (cand-item w)) 'froute)
         (let* ((expected (p7-expected (cadddr (cand-item w)) m))
                (r (real-answer hm (list m path #f)))
                (actual (if (list? (car r))
                            (list (map (lambda (e) (list (car e) (cadr e) (caddr e))) (car r)) (cadr r))
                            r)))
           (and (not (equal? expected actual)) (list 'expected expected 'router actual))))))

(define (p7-shrinks kase)
  (append (map (lambda (h) (cons h (cdr kase))) (handler-shrinks (car kase)))))

(define p7-tally (make-tally))

(define (p7-kind methods m)
  (let ((e (p7-expected methods m)))
    (cond ((= (car (cadr e)) 405) 's405)
          ((assq m methods) 'own)
          ((eq? m 'HEAD) (if (assq 'GET methods) 'head-by-get 'head-by-any))
          (else 'by-any))))

;; Each route of a table without middleware, reached by a path of its own
;; shape, each value zz9, which no word is; a route another template wins
;; for is counted, and left out.
(define (p7-cases i)
  (let ((s (case-state 7 i)))
    (draw* s ((hm0 (gen-router good-cfg 0)))
      (let* ((hm (number-ids (strip hm0)))
             (routes (filter (lambda (item) (eq? (car item) 'froute)) (flatten (cadr hm) "" '())))
             (reached (filter-map (lambda (item)
                                    (let* ((path (segs->path (map (lambda (seg) (if (eq? (car seg) 'word) (cadr seg) "zz9"))
                                                                  (template-segs (cadr item)))))
                                           (w (oracle-winner hm path)))
                                      (and (cand? w) (equal? (cand-item w) item) (cons item path))))
                                  routes)))
        (for-each (lambda (x) (tally! p7-tally 'route-not-reached)) (repeat 0 (- (length routes) (length reached))))
        (for-each (lambda (r) (for-each (lambda (m) (tally! p7-tally (p7-kind (cadddr (car r)) m))) all-methods))
                  reached)
        (concat-map (lambda (r) (map (lambda (m) (list hm (cdr r) m)) all-methods)) reached)))))

(test-equal "P7: for every route and method: HEAD to HEAD, else GET, else ANY; ANY takes the rest; else the exact 405 and its allow"
  '()
  (property-failures 'P7 (* 2500 multiplier) p7-cases p7-check p7-shrinks p7-tally))

(test-end "router-properties")

(exit (suite-exit-status runner))
