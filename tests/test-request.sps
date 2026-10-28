#!r6rs
;;; (circuit request): the view and its refusals, every accessor, the body's
;;; one port shared by every copy, the body's cap, keys, the req-with-
;;; helpers, req-on-done! and test-req-done!'s rules.
;;;
;;; The views here are the suite's own. Each procedure checks it is handed
;;; the host's request, and answers a value no default could: a method of
;;; PATCH, HTTP/1.0, ports and addresses. The calls whose count matters, the
;;; body's and on-done's, go in a log. A value that can be #f or '() is
;;; asserted behind a tag, since SRFI-64 turns a raise into #f.
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (circuit request))

(define runner (test-runner-simple))
(test-runner-current runner)

;; raised : (-> Any) -> Any
;; What THUNK raised: (assertion-violation WHO IRRITANTS) for an assertion
;; violation, (other-raise X) for anything else raised, X itself when it is
;; no condition, and no-raise if it returned.
(define (raised thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (irritants-condition? e))
             (list 'assertion-violation (condition-who e) (condition-irritants e)))
            ((condition? e) (list 'other-raise (describe e)))
            (#t (list 'other-raise e)))
    (thunk)
    'no-raise))

;; answer : (-> Any) -> (List 'answer Any) | (List 'raised String)
(define (answer thunk)
  (guard (e (#t (list 'raised (describe e))))
    (list 'answer (thunk))))

;; The log: what the views' body and on-done procedures, and the kept
;; procedures, were called with, oldest first once taken. The body notes the
;; cap it was handed.
(define the-log '())
(define (note! x) (set! the-log (cons x the-log)))
(define (take-log!)
  (let ((taken (reverse the-log)))
    (set! the-log '())
    taken))

(define (range n)
  (let loop ((i (- n 1)) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons i acc)))))

;; replace-at : (Listof Any) Nat Any -> (Listof Any)
(define (replace-at items i value)
  (let loop ((items items) (j 0))
    (cond ((null? items) '())
          ((= j i) (cons value (cdr items)))
          (else (cons (car items) (loop (cdr items) (+ j 1)))))))

;; --- the views ------------------------------------------------------------------

(define host (vector 'the-host-request))

(define (from-host value)
  (lambda (h) (if (eq? h host) value (list 'wrong-host h))))

(define (body-from-host bytes)
  (lambda (h cap)
    (note! (list 'body cap))
    (if (eq? h host) (open-bytevector-input-port bytes) (list 'wrong-host h))))

(define view-names
  '(method host path query http-version header header-values headers body
    remote-address remote-port local-address local-port on-done))

;; full-view-args : -> (Listof Any)
;; make-req-view's fourteen arguments, every one a procedure but on-done.
(define (full-view-args)
  (list (from-host 'PATCH)
        (from-host "example.test:8443")
        (from-host "/a/b")
        (from-host "x=1&y")
        (from-host (cons 1 0))
        (lambda (h name) (if (eq? h host) (string-append "first " name) 'wrong-host))
        (lambda (h name)
          (if (eq? h host)
              (list (string-append "one " name) (string-append "two " name))
              'wrong-host))
        (from-host (list (cons "X-Mixed" "1") (cons "set-cookie" "a") (cons "SET-Cookie" "b")))
        (body-from-host (string->utf8 "the body"))
        (from-host "192.0.2.7")
        (from-host 54321)
        (from-host "198.51.100.1")
        (from-host 8443)
        #f))

(define (full-view) (apply make-req-view (full-view-args)))

;; minimal-view : -> View
;; The four required procedures alone.
(define (minimal-view)
  (make-req-view (from-host 'GET) (from-host "h.test") (from-host "/m") #f (from-host (cons 1 1))
                 #f #f #f #f #f #f #f #f #f))

;; on-done-view : -> View
;; The full view, with an on-done that notes what it is handed.
(define (on-done-view)
  (apply make-req-view
         (replace-at (full-view-args) 13
                     (lambda (h proc) (note! (list 'on-done (eq? h host) proc))))))

;; snapshot : Req -> (Listof Any)
;; Every accessor's answer but the body's, and the body's cap.
(define (snapshot r)
  (list (req-method r) (req-scheme r) (req-host r) (req-path r) (req-query r)
        (req-http-version r) (req-header r "Accept") (req-header-values r "Accept")
        (req-headers r) (req-remote-address r) (req-remote-port r)
        (req-local-address r) (req-local-port r) (req-body-cap r)))

(define full-snapshot
  '(PATCH http "example.test:8443" "/a/b" "x=1&y" (1 . 0) "first Accept"
    ("one Accept" "two Accept")
    (("x-mixed" . "1") ("set-cookie" . "a") ("set-cookie" . "b"))
    "192.0.2.7" 54321 "198.51.100.1" 8443 #f))

;; probe-proc : Symbol -> Any
;; What a hosted snapshot registers through a request.
(define (probe-proc ending) ending)

;; on-done-reach : Req -> (Listof Any)
;; What the host's on-done is handed when a procedure is registered through
;; R: with the on-done view, ((on-done #t probe-proc)).
(define (on-done-reach r)
  (take-log!)
  (req-on-done! r probe-proc)
  (take-log!))

;; hosted-snapshot : Req -> (Listof Any)
;; The snapshot, and what a registration through R hands the host.
(define (hosted-snapshot r)
  (let* ((fields (snapshot r))
         (reach (on-done-reach r)))
    (append fields (list reach))))

(define full-hosted-snapshot
  (append full-snapshot (list (list (list 'on-done #t probe-proc)))))

(test-begin "request")

;; --- the view -----------------------------------------------------------------

(test-equal "every accessor answers its view procedure's answer for the host's request"
  full-snapshot
  (snapshot (make-req (full-view) host)))

(test-equal "with only the four required procedures: #f, '(), and http"
  '(GET http "h.test" "/m" #f (1 . 1) #f () () #f #f #f #f #f)
  (snapshot (make-req (minimal-view) host)))

(test-equal "make-req-view: #f is refused for the four required procedures, and taken for the other ten"
  '((assertion-violation make-req-view (method #f))
    (assertion-violation make-req-view (host #f))
    (assertion-violation make-req-view (path #f))
    no-raise
    (assertion-violation make-req-view (http-version #f))
    no-raise no-raise no-raise no-raise no-raise no-raise no-raise no-raise no-raise)
  (map (lambda (i) (raised (lambda () (apply make-req-view (replace-at (full-view-args) i #f)))))
       (range 14)))

(test-equal "make-req-view: what is neither a procedure nor #f is refused, at every position"
  (map (lambda (name) (list 'assertion-violation 'make-req-view (list name "text")))
       view-names)
  (map (lambda (i) (raised (lambda () (apply make-req-view (replace-at (full-view-args) i "text")))))
       (range 14)))

(test-equal "make-req refuses what is not a view"
  '(assertion-violation make-req (not-a-view))
  (raised (lambda () (make-req 'not-a-view host))))

(test-equal "req-headers folds the view's names to ASCII lower case, in order, duplicates kept"
  (list (cons "content-type" "a") (cons "x-\xC9;" "b") (cons "content-type" "c"))
  (let ((v (apply make-req-view
                  (replace-at (full-view-args) 7
                              (from-host (list (cons "Content-TYPE" "a") (cons "X-\xC9;" "b")
                                               (cons "content-type" "c")))))))
    (req-headers (make-req v host))))

(test-equal "req-header and req-header-values refuse a name that is not a string, with a view or without"
  '((assertion-violation req-header (accept))
    (assertion-violation req-header-values (accept))
    (assertion-violation req-header (accept))
    (assertion-violation req-header-values (accept)))
  (let ((full (make-req (full-view) host))
        (minimal (make-req (minimal-view) host)))
    (list (raised (lambda () (req-header full 'accept)))
          (raised (lambda () (req-header-values full 'accept)))
          (raised (lambda () (req-header minimal 'accept)))
          (raised (lambda () (req-header-values minimal 'accept))))))

(test-equal "every accessor refuses what is not a request"
  (map (lambda (who) (list 'assertion-violation who '(not-a-req)))
       '(req-method req-scheme req-host req-path req-query req-http-version req-header
         req-header-values req-headers req-body req-remote-address req-remote-port
         req-local-address req-local-port req-body-made req-on-done! req-ref req-set
         req-with-method req-with-scheme req-with-host req-with-path req-with-query
         req-with-remote-address req-with-remote-port req-body-cap req-with-body-cap))
  (let ((key (make-req-key 'k)))
    (map raised
         (list (lambda () (req-method 'not-a-req))
               (lambda () (req-scheme 'not-a-req))
               (lambda () (req-host 'not-a-req))
               (lambda () (req-path 'not-a-req))
               (lambda () (req-query 'not-a-req))
               (lambda () (req-http-version 'not-a-req))
               (lambda () (req-header 'not-a-req "a"))
               (lambda () (req-header-values 'not-a-req "a"))
               (lambda () (req-headers 'not-a-req))
               (lambda () (req-body 'not-a-req))
               (lambda () (req-remote-address 'not-a-req))
               (lambda () (req-remote-port 'not-a-req))
               (lambda () (req-local-address 'not-a-req))
               (lambda () (req-local-port 'not-a-req))
               (lambda () (req-body-made 'not-a-req))
               (lambda () (req-on-done! 'not-a-req (lambda (e) e)))
               (lambda () (req-ref 'not-a-req key))
               (lambda () (req-set 'not-a-req key 1))
               (lambda () (req-with-method 'not-a-req 'GET))
               (lambda () (req-with-scheme 'not-a-req 'https))
               (lambda () (req-with-host 'not-a-req "h"))
               (lambda () (req-with-path 'not-a-req "/"))
               (lambda () (req-with-query 'not-a-req "q"))
               (lambda () (req-with-remote-address 'not-a-req "a"))
               (lambda () (req-with-remote-port 'not-a-req 1))
               (lambda () (req-body-cap 'not-a-req))
               (lambda () (req-with-body-cap 'not-a-req 1))))))

;; --- the body: one port, made once, shared by every copy -----------------------

(test-equal "req-body: the view's port, read from the host's request"
  (string->utf8 "the body")
  (get-bytevector-all (req-body (make-req (full-view) host))))

(test-equal "req-body: one port for every copy, made once, through whichever copy asks first"
  '((answer #f) () #t #t #t #t #t ((body #f)))
  (begin
    (take-log!)
    (let* ((r (make-req (full-view) host))
           (key (make-req-key 'k))
           (r2 (req-set r key 1))
           (r3 (req-with-path r2 "/elsewhere"))
           (before (answer (lambda () (req-body-made r3))))
           (calls-before (take-log!))
           (p3 (req-body r3))
           (p1 (req-body r))
           (p2 (req-body r2))
           (p4 (req-body (req-with-method r 'PUT)))
           (p5 (req-body (req-set r3 key 2))))
      (list before calls-before (eq? p1 p3) (eq? p2 p3) (eq? p4 p3) (eq? p5 p3)
            (eq? (req-body-made r) p3) (take-log!)))))

(test-equal "req-body: two requests made apart have two ports"
  '(answer #f)
  (answer (lambda () (eq? (req-body (make-req (full-view) host))
                          (req-body (make-req (full-view) host))))))

(test-equal "req-body-made makes nothing, through any copy"
  '((answer #f) (answer #f) ())
  (begin
    (take-log!)
    (let* ((r (make-req (full-view) host))
           (first (answer (lambda () (req-body-made r))))
           (second (answer (lambda () (req-body-made (req-with-host r "h"))))))
      (list first second (take-log!)))))

(test-equal "req-body without a view body: an empty port, the same one every time, read eof at once"
  '((answer #f) #t #t #t)
  (let* ((r (make-req (minimal-view) host))
         (before (answer (lambda () (req-body-made r))))
         (p (req-body r)))
    (list before
          (eq? p (req-body (req-set r (make-req-key 'k) 1)))
          (eq? p (req-body-made r))
          (eof-object? (get-u8 p)))))

(test-equal "req-headers answers the view's own list when no name needs folding, and a new one when one does"
  '(#t #f (("a" . "1") ("b-c" . "2")))
  (let* ((lower (list (cons "a" "1") (cons "b-c" "2")))
         (mixed (list (cons "A" "1") (cons "b-c" "2")))
         (with-headers (lambda (fields)
                         (make-req (apply make-req-view
                                          (replace-at (full-view-args) 7 (lambda (h) fields)))
                                   host))))
    (list (eq? lower (req-headers (with-headers lower)))
          (eq? mixed (req-headers (with-headers mixed)))
          (req-headers (with-headers mixed)))))

(test-equal "req-body refuses a binary output port from the view"
  '(#t (answer #f))
  (let-values (((out extract) (open-bytevector-output-port)))
    (let* ((r (make-req (apply make-req-view (replace-at (full-view-args) 8 (lambda (h cap) out))) host))
           (refusal (raised (lambda () (req-body r)))))
      (list (equal? refusal (list 'assertion-violation 'req-body (list out)))
            (answer (lambda () (req-body-made r)))))))

(test-equal "req-body refuses a view body that is not a binary input port, and keeps nothing"
  '((assertion-violation req-body (not-a-port)) (answer #f) #t)
  (let* ((text (open-string-input-port "text"))
         (bad (lambda (answer-with)
                (make-req (apply make-req-view (replace-at (full-view-args) 8
                                                           (lambda (h cap) answer-with)))
                          host)))
         (r (bad 'not-a-port))
         (refused (raised (lambda () (req-body r))))
         (kept (answer (lambda () (req-body-made r))))
         (textual (raised (lambda () (req-body (bad text))))))
    (list refused kept (equal? textual (list 'assertion-violation 'req-body (list text))))))

;; --- keys ---------------------------------------------------------------------

(test-equal "req-ref: #f by default, or the default given, for a key never set"
  '((answer #f) none)
  (let ((r (make-req (full-view) host))
        (key (make-req-key 'session)))
    (list (answer (lambda () (req-ref r key)))
          (req-ref r key 'none))))

(test-equal "req-set: a new request with the key, the newest value read, the old request unchanged"
  '(second first none)
  (let* ((key (make-req-key 'session))
         (r (make-req (full-view) host))
         (r1 (req-set r key 'first))
         (r2 (req-set r1 key 'second)))
    (list (req-ref r2 key) (req-ref r1 key) (req-ref r key 'none))))

(test-equal "two keys with one name are two keys"
  '(mine none)
  (let* ((mine (make-req-key 'session))
         (theirs (make-req-key 'session))
         (r (req-set (make-req (full-view) host) mine 'mine)))
    (list (req-ref r mine 'none) (req-ref r theirs 'none))))

(test-equal "req-set keeps every other field"
  full-snapshot
  (snapshot (req-set (make-req (full-view) host) (make-req-key 'k) 1)))

(test-equal "req-key? answers for a key, and for nothing else"
  '(#t #f #f)
  (list (req-key? (make-req-key 'k)) (req-key? 'k) (req-key? (make-req (full-view) host))))

(test-equal "a key is a key from make-req-key, not a symbol"
  '((assertion-violation req-ref (session))
    (assertion-violation req-ref (session))
    (assertion-violation req-set (session)))
  (let ((r (make-req (full-view) host)))
    (list (raised (lambda () (req-ref r 'session)))
          (raised (lambda () (req-ref r 'session 'default)))
          (raised (lambda () (req-set r 'session 1))))))

;; --- the req-with- helpers ------------------------------------------------------

;; Each helper, the snapshot position it changes, and a new value.
(define with-cases
  (list (list 'req-with-method req-with-method 0 'DELETE)
        (list 'req-with-scheme req-with-scheme 1 'https)
        (list 'req-with-host req-with-host 2 "moved.test")
        (list 'req-with-path req-with-path 3 "/mounted/a/b")
        (list 'req-with-query req-with-query 4 "z=26")
        (list 'req-with-remote-address req-with-remote-address 9 "203.0.113.9")
        (list 'req-with-remote-port req-with-remote-port 10 40001)
        (list 'req-with-body-cap req-with-body-cap 13 4096)))

(for-each
 (lambda (c)
   (let ((name (car c)) (with (cadr c)) (i (caddr c)) (value (cadddr c)))
     (test-equal (string-append (symbol->string name)
                                ": the copy answers the new value, nothing else changes, its on-done included, and the original is as it was")
       (list (replace-at full-hosted-snapshot i value) full-hosted-snapshot)
       (let* ((r (make-req (on-done-view) host))
              (copy (with r value))
              (copy-seen (hosted-snapshot copy))
              (original-seen (hosted-snapshot r)))
         (list copy-seen original-seen)))))
 with-cases)

(test-equal "a req-with- copy keeps the keys and shares the cell"
  '((kept kept kept kept kept kept kept kept) #t ((body #f)))
  (begin
    (take-log!)
    (let* ((key (make-req-key 'k))
           (r (req-set (make-req (full-view) host) key 'kept))
           (copies (map (lambda (c) ((cadr c) r (cadddr c))) with-cases))
           (port (req-body (car copies))))
      (list (map (lambda (copy) (req-ref copy key 'lost)) copies)
            (for-all (lambda (copy) (eq? port (req-body copy))) (cons r copies))
            (take-log!)))))

(test-equal "req-set and every req-with- helper keep the view's on-done: a procedure registered through a copy reaches the host"
  (map (lambda (i) (list 'on-done #t probe-proc)) (range 10))
  (let* ((r (make-req (on-done-view) host))
         (copies (append (list (req-set r (make-req-key 'k) 1)
                               (req-with-path (req-with-method r 'PUT) "/twice"))
                         (map (lambda (c) ((cadr c) r (cadddr c))) with-cases))))
    (take-log!)
    (for-each (lambda (copy) (req-on-done! copy probe-proc)) copies)
    (take-log!)))

(test-equal "#f is a query and an address to the helpers, and a view without them takes one"
  '((answer #f) (answer #f) (answer #f) "q=1" "203.0.113.1" 81)
  (let ((full (make-req (full-view) host))
        (minimal (make-req (minimal-view) host)))
    (list (answer (lambda () (req-query (req-with-query full #f))))
          (answer (lambda () (req-remote-address (req-with-remote-address full #f))))
          (answer (lambda () (req-remote-port (req-with-remote-port full #f))))
          (req-query (req-with-query minimal "q=1"))
          (req-remote-address (req-with-remote-address minimal "203.0.113.1"))
          (req-remote-port (req-with-remote-port minimal 81)))))

(test-equal "the helpers refuse a value of the wrong type"
  '((assertion-violation req-with-method ("GET"))
    (assertion-violation req-with-scheme ("https"))
    (assertion-violation req-with-host (h))
    (assertion-violation req-with-host (#f))
    (assertion-violation req-with-path (#f))
    (assertion-violation req-with-query (5))
    (assertion-violation req-with-remote-address (5))
    (assertion-violation req-with-remote-port (-1))
    (assertion-violation req-with-remote-port (1.5))
    (assertion-violation req-with-remote-port ("80"))
    (assertion-violation req-with-remote-port (80.)))
  (let ((r (make-req (full-view) host)))
    (list (raised (lambda () (req-with-method r "GET")))
          (raised (lambda () (req-with-scheme r "https")))
          (raised (lambda () (req-with-host r 'h)))
          (raised (lambda () (req-with-host r #f)))
          (raised (lambda () (req-with-path r #f)))
          (raised (lambda () (req-with-query r 5)))
          (raised (lambda () (req-with-remote-address r 5)))
          (raised (lambda () (req-with-remote-port r -1)))
          (raised (lambda () (req-with-remote-port r 1.5)))
          (raised (lambda () (req-with-remote-port r "80")))
          (raised (lambda () (req-with-remote-port r 80.))))))

;; --- the body's cap -------------------------------------------------------------

;; cap-handed : (Req -> Req) -> (Listof Any)
;; What the view's body is handed when the body is made through (MAKE r),
;; for a fresh request r.
(define (cap-handed make)
  (take-log!)
  (req-body (make (make-req (full-view) host)))
  (take-log!))

(test-equal "req-body hands the view's body the request's cap: #f unless given, else the newest given, through any copy made after it, a bignum's included"
  `(((body #f)) ((body 4096)) ((body 0)) ((body ,(expt 2 100))) ((body 7)) ((body 7)) ((body #f)))
  (map cap-handed
       (list (lambda (r) r)
             (lambda (r) (req-with-body-cap r 4096))
             (lambda (r) (req-with-body-cap r 0))
             (lambda (r) (req-with-body-cap r (expt 2 100)))
             (lambda (r) (req-with-body-cap (req-with-body-cap r 4096) 7))
             (lambda (r) (req-with-path (req-set (req-with-body-cap r 7) (make-req-key 'k) 1) "/p"))
             (lambda (r) (req-with-body-cap (req-with-body-cap r 7) #f)))))

(test-equal "req-set and every req-with- helper but req-with-body-cap keep the cap"
  '(7 7 7 7 7 7 7 7)
  (let ((r (req-with-body-cap (make-req (full-view) host) 7)))
    (map req-body-cap
         (cons (req-set r (make-req-key 'k) 1)
               (map (lambda (c) ((cadr c) r (cadddr c)))
                    (filter (lambda (c) (not (eq? (car c) 'req-with-body-cap))) with-cases))))))

(test-equal "req-with-body-cap is refused once the body's port is made, through any copy, with a view body or without, and the request keeps its cap"
  '((assertion-violation req-with-body-cap (8))
    (assertion-violation req-with-body-cap (#f))
    (assertion-violation req-with-body-cap (1))
    4
    ((body 4)))
  (begin
    (take-log!)
    (let* ((r (req-with-body-cap (make-req (full-view) host) 4))
           (copy (req-set r (make-req-key 'k) 1))
           (minimal (make-req (minimal-view) host)))
      (req-body copy)
      (req-body minimal)
      (let* ((late (raised (lambda () (req-with-body-cap r 8))))
             (lifted (raised (lambda () (req-with-body-cap (req-with-path copy "/q") #f))))
             (bodiless (raised (lambda () (req-with-body-cap minimal 1)))))
        (list late lifted bodiless (req-body-cap r) (take-log!))))))

(test-equal "req-with-body-cap refuses a cap that is neither #f nor a count of bytes"
  '((assertion-violation req-with-body-cap (-1))
    (assertion-violation req-with-body-cap (1.5))
    (assertion-violation req-with-body-cap (4096.))
    (assertion-violation req-with-body-cap ("4096"))
    (assertion-violation req-with-body-cap (#t)))
  (let ((r (make-req (full-view) host)))
    (map (lambda (cap) (raised (lambda () (req-with-body-cap r cap))))
         (list -1 1.5 4096. "4096" #t))))

;; --- req-on-done! ---------------------------------------------------------------

(define kept-proc (lambda (ending) (note! (list 'kept-proc-called ending))))

(test-equal "req-on-done! with the view's on-done: handed to it with the host's request, and not called"
  (list (list 'on-done #t kept-proc))
  (begin
    (take-log!)
    (req-on-done! (make-req (on-done-view) host) kept-proc)
    (take-log!)))

(test-equal "req-on-done! refuses what is not a procedure"
  '((assertion-violation req-on-done! (later)) (assertion-violation req-on-done! (later)))
  (list (raised (lambda () (req-on-done! (make-req (full-view) host) 'later)))
        (raised (lambda () (req-on-done! (make-req (on-done-view) host) 'later)))))

;; --- test-req-done! -------------------------------------------------------------

;; noting : Symbol -> (Symbol -> Any)
;; A procedure that notes its name and the ending it is called with.
(define (noting name) (lambda (ending) (note! (list name ending))))

;; raising : Symbol -> (Symbol -> Any)
;; One that notes its call and raises its name.
(define (raising name) (lambda (ending) (note! (list name ending)) (raise name)))

(test-equal "test-req-done!: newest first, each once, with the ending; '() when none raised"
  '((answer ()) ((c client-closed) (b client-closed) (a client-closed)))
  (begin
    (take-log!)
    (let ((r (make-req (full-view) host)))
      (req-on-done! r (noting 'a))
      (req-on-done! r (noting 'b))
      (req-on-done! r (noting 'c))
      (let ((result (answer (lambda () (test-req-done! r 'client-closed)))))
        (list result (take-log!))))))

(test-equal "test-req-done!: a raise stops none of the rest, and the raises come back oldest first"
  '((four three one) ((four failed) (three failed) (two failed) (one failed)))
  (begin
    (take-log!)
    (let ((r (make-req (full-view) host)))
      (req-on-done! r (raising 'one))
      (req-on-done! r (noting 'two))
      (req-on-done! r (raising 'three))
      (req-on-done! r (raising 'four))
      (let ((result (test-req-done! r 'failed)))
        (list result (take-log!))))))

(test-equal "test-req-done!: what was raised comes back as it was raised, a condition included"
  '(#t 1)
  (let* ((r (make-req (full-view) host))
         (c (make-message-condition "boom")))
    (req-on-done! r (lambda (ending) (raise c)))
    (let ((result (test-req-done! r 'written)))
      (list (eq? (car result) c) (length result)))))

(test-equal "test-req-done!: procedures kept through any copy share the cell, newest first"
  '((z written) (y written) (x written))
  (begin
    (take-log!)
    (let* ((r (make-req (full-view) host))
           (r2 (req-set r (make-req-key 'k) 1))
           (r3 (req-with-path r "/z")))
      (req-on-done! r (noting 'x))
      (req-on-done! r2 (noting 'y))
      (req-on-done! r3 (noting 'z))
      (test-req-done! (req-with-method r2 'PUT) 'written)
      (take-log!))))

(test-equal "test-req-done!: a second call calls nothing and answers '(), whatever its ending"
  '((answer ()) (answer ()) ((a failed)))
  (begin
    (take-log!)
    (let ((r (make-req (full-view) host)))
      (req-on-done! r (noting 'a))
      (test-req-done! r 'failed)
      (let* ((second (answer (lambda () (test-req-done! r 'written))))
             (third (answer (lambda () (test-req-done! (req-set r (make-req-key 'k) 1) 'failed)))))
        (list second third (take-log!))))))

(test-equal "a procedure kept after test-req-done! runs at once, with the first ending, once, even after a second call"
  '(((late client-closed)) ((later client-closed)) (answer ()) () ((last client-closed)))
  (begin
    (take-log!)
    (let ((r (make-req (full-view) host)))
      (test-req-done! r 'client-closed)
      (req-on-done! r (noting 'late))
      (let* ((first (take-log!))
             (ignored (req-on-done! (req-with-path r "/copy") (noting 'later)))
             (second (take-log!))
             (again (answer (lambda () (test-req-done! r 'written))))
             (after-again (take-log!)))
        (req-on-done! r (noting 'last))
        (list first second again after-again (take-log!))))))

(test-equal "a procedure kept after test-req-done! raises to its caller"
  '(other-raise late-raise)
  (let ((r (make-req (full-view) host)))
    (test-req-done! r 'written)
    (raised (lambda () (req-on-done! r (lambda (ending) (raise 'late-raise)))))))

(test-equal "a procedure kept while test-req-done! calls the others runs at once, with that ending"
  '((answer ()) ((outer written) (inner written) (first written)))
  (begin
    (take-log!)
    (let ((r (make-req (full-view) host)))
      (req-on-done! r (noting 'first))
      (req-on-done! r (lambda (ending)
                        (note! (list 'outer ending))
                        (req-on-done! r (noting 'inner))))
      (let ((result (answer (lambda () (test-req-done! r 'written)))))
        (list result (take-log!))))))

(test-equal "test-req-done!: each of the three endings is taken"
  '((answer ()) (answer ()) (answer ()))
  (map (lambda (ending) (answer (lambda () (test-req-done! (make-req (full-view) host) ending))))
       '(written client-closed failed)))

(test-equal "test-req-done!: any other ending is refused, and calls nothing"
  '(((assertion-violation test-req-done! (done))
     (assertion-violation test-req-done! ("written"))
     (assertion-violation test-req-done! (WRITTEN))
     (assertion-violation test-req-done! (#f))
     (assertion-violation test-req-done! (closed)))
    ()
    ((a written)))
  (begin
    (take-log!)
    (let ((r (make-req (full-view) host)))
      (req-on-done! r (noting 'a))
      (let* ((refusals (map (lambda (ending) (raised (lambda () (test-req-done! r ending))))
                            (list 'done "written" 'WRITTEN #f 'closed)))
             (calls (take-log!)))
        (test-req-done! r 'written)
        (list refusals calls (take-log!))))))

(test-equal "test-req-done!: the ending is checked first, before the request"
  '((assertion-violation test-req-done! (done))
    (assertion-violation test-req-done! (done))
    (assertion-violation test-req-done! (not-a-req)))
  (list (raised (lambda () (test-req-done! 'not-a-req 'done)))
        (raised (lambda () (test-req-done! (make-req (on-done-view) host) 'done)))
        (raised (lambda () (test-req-done! 'not-a-req 'written)))))

(test-equal "test-req-done! is refused on a request whose view has on-done: its host calls those"
  '(assertion-violation test-req-done! #t)
  (let* ((r (make-req (on-done-view) host))
         (refusal (raised (lambda () (test-req-done! r 'written)))))
    (list (car refusal) (cadr refusal) (eq? (car (caddr refusal)) r))))

(test-end "request")

(exit (suite-exit-status runner))
