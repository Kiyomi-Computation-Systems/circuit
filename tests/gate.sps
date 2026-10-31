#!r6rs
;;; The cost gate (design §15.6): what circuit costs over the raw server, in
;;; bytes a request, with the parts circuit controls held to a bound.
;;;
;;; Spike S2's method (.plans/research/s2-coroutine-cost.md, and its program
;;; .plans/research/spike/s2-coroutine-cost.sps). One server in this
;;; process, started as `serve` starts one, under the default limits, whose
;;; handler is whichever variant is current, so every variant runs in the
;;; same build as its baseline. oha runs in a process of its own, spawned on
;;; the server's loop, and the loop is turned as `serve` turns it,
;;; shell-run-turns!, until oha has ended. Two modes:
;;;
;;;   bytes OHA
;;;     The gate. Bytes a request, the whole process: Chez's cumulative
;;;     counter, `sstats-bytes`, read as oha starts and once it has ended,
;;;     for 5,000 requests and then 25,000; the difference over the extra
;;;     20,000 leaves out what does not grow with the requests. At 1 and 50
;;;     keep-alive connections, two rounds. It prints each variant's figure
;;;     and each gate's (`gates`, below), and exits 1 when a held gate
;;;     fails, naming it, and 0 otherwise. A run in which oha saw anything
;;;     but its count of 200s, each with the 6-byte body, measured nothing:
;;;     the gate exits 1 there and then, naming it.
;;;   rps OHA
;;;     G6, the smoke: requests a second, `oha -z 5s`, get-adapter against
;;;     get-raw at 1 and 50 keep-alive connections, two rounds, the two
;;;     taking turns, each round starting one further on. It prints
;;;     get-adapter's rate over get-raw's, round by round, against the
;;;     smoke's 90% at 50 connections, and never fails on it.
;;;
;;; The variants (`variants`, below) each answer a 6-byte text/plain
;;; "hello\n": a GET raw, its response built once; answered `awaiting`;
;;; through the adapter; through the adapter under five middlewares that
;;; each `req-set` a key; through the adapter with the app parked once,
;;; `(sleep-ms 0)`; the adapter's app, and the parked one, inside the catch
;;; helper, nothing raised; the adapter's app registering a no-op
;;; req-on-done! procedure; inside wrap-log, its lines written to
;;; /dev/null; inside wrap-timeout, its deadline never passing, the app
;;; parked once inside it and not; through
;;; the adapter as a bytevector body, and
;;; as a bytevector port body, which the adapter reads whole, a port of
;;; one piece or less (design §5); a 13-byte POST read raw, by
;;; read-whole-body, and from an `awaiting` thunk and through the adapter,
;;; each by get-bytevector-n of its declared length, the cheapest read
;;; (design §4), so G3 POST is circuit's work over the same read; and,
;;; through the adapter, a router of twenty routes asked a word route, a
;;; one-parameter route, and a path no route takes, which its not-found
;;; handler answers, each over an app that reads the path at the same URL
;;; and answers hello, so G10 is the router's own work. Each variant asks a
;;; path of its own, / unless it names one. The handlers a G10 variant
;;; should reach count each request in a fixnum, which allocates nothing,
;;; and a run whose count isn't its request count refuses: oha asked
;;; another path.
;;;
;;; The adapter is circuit's own, (circuit http-server)'s circuit->handler,
;;; given an environment that answers #f for every name, so the process's
;;; environment moves no figure: the server under it is started with a
;;; lookup of its own. The catch helper, wrap-log and wrap-timeout are
;;; circuit's own, (circuit middleware waits)'s, and the router (circuit
;;; router)'s. Every run's standard output
;;; goes to /dev/null, so wrap-log's lines cost what they cost on a file.
;;;
;;; Run from the checkout's root, inside the Guix container, through make,
;;; once `make oha` has fetched oha on the host:
;;;
;;;   scripts/guix-env make gate
;;;   scripts/guix-env make gate-rps
(import (rnrs) (rnrs mutable-pairs)
        (only (chezscheme) printf statistics sstats-bytes collect scheme-version machine-type
              open-process-ports native-transcoder parameterize)
        ;; (rnrs)'s current-output-port is a procedure, not Chez's parameter,
        ;; which display reads: parameterize takes Chez's.
        (rename (only (chezscheme) current-output-port) (current-output-port chez:current-output-port))
        (only (libuv) make-uv-loop make-uv-pipe uv-spawn! uv-read-start! uv-close! uv-version)
        (only (uv-testing) make-byte-collector collect-span! collector-bytes)
        (http-server)
        (only (http-server awaiting) make-deadline-passed make-client-closed)
        (only (http-server private shell) shell-run-turns!)
        (only (http-server private serve) start-server)
        (only (circuit request) make-req-view make-req req-body req-header req-ref req-set
              make-req-key req-on-done! test-req-done! req-with-path req-path)
        (only (circuit response) make-res res? res-status res-headers)
        (only (circuit middleware) wrap)
        (only (circuit middleware waits) wrap-catch wrap-timeout wrap-log)
        (only (circuit router) make-router route group GET POST PUT DELETE)
        (only (circuit http-server) circuit->handler))

;;; ------------------------------------------------------------------------
;;; The counts and the gates: design §15.6. The bounds are slice 4's,
;;; measured through the real adapter, each with headroom over the worst
;;; figure eight runs read and under what a known regression reads
;;; (ADR-0007). G10's are 6b's, over the worst of three runs (design
;;; §15.24).

;; Fixed: 5,000 against 25,000 requests, two rounds, at 1 and 50 keep-alive
;; connections, which reads a gate's worst figure to within about 10 B from
;; run to run, and 25 B where the app parks.
(define small-count 5000)
(define large-count 25000)
(define rounds 2)
(define connection-counts '(1 50))

;; G6, the smoke: oha -z 5s, two rounds; its floor, 90% of raw's rate at 50
;; connections, is printed and never fails.
(define rps-seconds 5)
(define rps-floor 9/10)

;; make-gate : String String String Nat (U Nat #f) Boolean String -> Gate
;; A gate: its name; the variant over its base, paired round by round and
;; divided by `per`; its bound in bytes, or #f for a printed one with none;
;; whether it is held, failing the gate, or printed; and what it measures.
(define-record-type (gate make-gate gate?)
  (fields name variant base per bound held? what))

(define gates
  (list
   (make-gate "G1" "get-adapter" "get-raw" 1 1536 #f
              "a GET through the adapter over raw, the server's coroutine included")
   (make-gate "G2" "post-adapter" "post-raw" 1 1536 #f
              "a 13-byte POST through the adapter, pulled by get-bytevector-n of its length, over raw's read-whole-body, the server's coroutine and port included")
   (make-gate "G3 GET" "get-adapter" "get-awaiting" 1 384 #t
              "circuit's own work over the server's awaiting path, a GET")
   (make-gate "G3 POST" "post-adapter" "post-awaiting" 1 352 #t
              "circuit's own work over the server's awaiting path, a POST pulled by get-bytevector-n of its length")
   (make-gate "G4 one" "get-five" "get-adapter" 5 88 #t
              "one req-set, five middlewares' cost over five, its bound between a record's 16 B size steps")
   (make-gate "G4 five" "get-five" "get-adapter" 1 440 #t
              "five req-set middlewares, five times G4 one's bound")
   (make-gate "G5" "catch-none" "get-adapter" 1 512 #t
              "the catch helper over the unwrapped app, nothing raised")
   (make-gate "G5 park" "catch-none-park" "get-adapter-park" 1 512 #t
              "the catch helper over the unwrapped app, nothing raised, the app parked once inside it")
   (make-gate "G7" "get-adapter-port" "get-adapter-bytes" 1 384 #t
              "a 6-byte bytevector port body over the same bytes as a bytevector, through the adapter, the port made per request and read whole")
   (make-gate "G8" "log" "get-adapter" 1 #f #f
              "wrap-log over the unwrapped app, its line written to /dev/null")
   (make-gate "G8 own" "log" "get-ondone" 1 384 #t
              "wrap-log's own work: wrap-log over the app, over the app registering a no-op req-on-done! procedure")
   (make-gate "G8 on-done" "get-ondone" "get-adapter" 1 #f #f
              "a no-op req-on-done! procedure, registered by the app, what wrap-log pays the server (chez-http-server #245)")
   (make-gate "G9" "timeout" "get-adapter" 1 768 #t
              "wrap-timeout over the unwrapped app, its deadline never passing")
   (make-gate "G9 park" "timeout-park" "get-adapter-park" 1 768 #t
              (string-append "wrap-timeout over the unwrapped app, its deadline never passing,"
                             " the app parked once inside it"))
   (make-gate "G10 word" "router-word" "path-word" 1 128 #t
              (string-append "a router of twenty routes over an app that reads the path, both asked"
                             " /users/new: the router's own work for a word route"))
   (make-gate "G10 param" "router-param" "path-param" 1 256 #t
              (string-append "the same, both asked /users/42: the router's own work for a"
                             " one-parameter route"))
   (make-gate "G10 miss" "router-miss" "path-miss" 1 64 #t
              (string-append "the same, both asked /nope/nothing, which no route takes:"
                             " the router's own work to find nothing"))))

;;; ------------------------------------------------------------------------
;;; The adapter's environment.

;; no-env : String -> #f — every adapter's environment: no setting is set,
;; so circuit->handler takes its defaults whatever the process's
;; environment holds.
(define (no-env name) #f)

;;; ------------------------------------------------------------------------
;;; The apps and the raw handlers. A POST answers 200 only for the body oha
;;; sends, and 400 otherwise, so oha's tallies show the body was read.

(define text-headers '(("content-type" . "text/plain")))
(define text-headers/bytes (list (cons (string->utf8 "content-type") (string->utf8 "text/plain"))))
(define post-body "hello, world!")
(define post-bytes (string->utf8 post-body))
(define hello-bytes (string->utf8 "hello\n"))

;; sent? : (U Bytevector Eof) -> Boolean — whether `got` is oha's body.
(define (sent? got) (and (bytevector? got) (bytevector=? got post-bytes)))

;; declared : (U String #f) -> Nat — a content-length's count, or 0 for
;; none or a malformed one, which reads nothing and so answers 400.
(define (declared value)
  (let ((n (and value (string->number value 10))))
    (if (and n (exact? n) (integer? n) (>= n 0)) n 0)))

;; hello : Req -> Res — the app.
(define (hello req) (make-res 200 text-headers "hello\n"))

;; parked-hello : Req -> Res — hello, after one park.
(define (parked-hello req) (sleep-ms 0) (make-res 200 text-headers "hello\n"))

;; bytes-hello, port-hello : Req -> Res — hello's 6 bytes as a bytevector
;; body, and as a bytevector port body, a port made per request.
(define (bytes-hello req) (make-res 200 text-headers hello-bytes))
(define (port-hello req) (make-res 200 text-headers (open-bytevector-input-port hello-bytes)))

;; ondone-hello : Req -> Res — hello, after registering a no-op req-on-done!
;; procedure.
(define (ondone-hello req) (req-on-done! req ignore-ending) (make-res 200 text-headers "hello\n"))

;; ignore-ending : Symbol -> #f
(define (ignore-ending how) #f)

;; post-hello : Req -> Res — hello, once the body is read by
;; get-bytevector-n of its declared length.
(define (post-hello req)
  (let ((body (get-bytevector-n (req-body req) (declared (req-header req "content-length")))))
    (make-res (if (sent? body) 200 400) text-headers "hello\n")))

;; key-setter : Key -> Middleware — sets `key` on every request.
(define (key-setter key)
  (lambda (handler)
    (lambda (req) (handler (req-set req key #t)))))

(define five-keys (list (make-req-key 'one) (make-req-key 'two) (make-req-key 'three)
                        (make-req-key 'four) (make-req-key 'five)))

;; five : Req -> Res — hello under five middlewares, each setting its key.
(define five (apply wrap hello (map key-setter five-keys)))

;; asked : (Vector Fixnum ...) — how many requests each counted handler has
;; answered since its variant's run began: the router's word route, its
;; parameter route and its not-found handler, then each path variant's app,
;; for the path it names. A fixnum in a vector: a count allocates nothing.
(define asked (make-vector 6 0))
(define (count! k) (vector-set! asked k (fx+ (vector-ref asked k) 1)))

;; through : Headers Nat -> Handler — hello, its headers HEADERS, counted at
;; K: the same bytes as hello's, from a list of its own, so a probe can tell
;; by eq? which handler answered.
(define (through headers k)
  (lambda (req)
    (count! k)
    (make-res 200 headers "hello\n")))

;; path-hello : String Nat -> Handler — hello, once it has read the path, as
;; a router does; counted at K when the path is PATH.
(define (path-hello path k)
  (lambda (req)
    (when (string=? (req-path req) path) (count! k))
    (make-res 200 text-headers "hello\n")))

(define word-headers (list (cons "content-type" "text/plain")))
(define param-headers (list (cons "content-type" "text/plain")))
(define miss-headers (list (cons "content-type" "text/plain")))

;; pass-through : Middleware — the admin group's, which adds nothing.
(define (pass-through next) (lambda (req) (next req)))

;; routed : Handler — a router of twenty routes of the shapes apps have:
;; words, parameters, a group, a catch-all. Its word route, its
;; one-parameter route and its not-found handler answer `through` their own
;; headers, and every other route hello.
(define routed
  (make-router
   (list (route "/" (GET hello))
         (route "/health" (GET hello))
         (route "/login" (GET hello) (POST hello))
         (route "/logout" (POST hello))
         (route "/search" (GET hello))
         (route "/about" (GET hello))
         (route "/users" (GET hello) (POST hello))
         (route "/users/new" (GET (through word-headers 0)))
         (route "/users/:id" (GET (through param-headers 1)) (PUT hello) (DELETE hello))
         (route "/users/:id/edit" (GET hello))
         (route "/users/:id/followers" (GET hello))
         (route "/users/:id/posts" (GET hello) (POST hello))
         (route "/users/:id/posts/:post" (GET hello) (DELETE hello))
         (route "/posts" (GET hello))
         (route "/posts/:id" (GET hello))
         (route "/posts/:id/comments" (GET hello) (POST hello))
         (group "/admin" (list pass-through)
           (route "" (GET hello))
           (route "/stats" (GET hello))
           (route "/users/:id" (GET hello) (DELETE hello)))
         (route "/static/*path" (GET hello)))
   (through miss-headers 2)))

;; hello-response, refused-response : Response — built once.
(define hello-response (make-response 200 #f text-headers/bytes hello-bytes))
(define refused-response (make-response 400 #f text-headers/bytes hello-bytes))

;; raw : Request -> Response — the raw server's handler, in place.
(define (raw request) hello-response)

;; awaited : Request -> Awaiting — raw's response from a coroutine.
(define (awaited request) (awaiting (lambda () hello-response)))

;; body-answer : Bytevector -> Response
(define (body-answer body) (if (sent? body) hello-response refused-response))

;; post-raw : Request -> BodyReader — the body read whole, in place.
(define (post-raw request) (read-whole-body body-answer))

;; post-awaited : Request -> Awaiting — the body read from the thunk,
;; through the server's port, by get-bytevector-n of its declared length,
;; then raw's response.
(define (post-awaited request)
  (awaiting
   (lambda ()
     (body-answer
      (get-bytevector-n (body-input-port) (declared (request-header request "content-length")))))))

;;; ------------------------------------------------------------------------
;;; The variants.

;; make-variant : String (U String #f) Symbol Handler [String [Nat]] -> Variant
;; A variant: its name, its baseline's in the table, GET or POST, its
;; handler, the path oha asks, / unless given, and the slot of `asked` its
;; handler counts in, or #f.
(define-record-type (variant make-variant variant?)
  (fields name base method handler path counter)
  (protocol (lambda (new)
              (case-lambda
                ((name base method handler) (new name base method handler "/" #f))
                ((name base method handler path) (new name base method handler path #f))
                ((name base method handler path k) (new name base method handler path k))))))

;; path-variant : String String Nat -> Variant — path-hello through the
;; adapter, asked PATH, counted at K.
(define (path-variant name path k)
  (make-variant name "get-adapter" 'GET (circuit->handler (path-hello path k) no-env) path k))

;; routed-variant : String String String Nat -> Variant — the router through
;; the adapter over BASE, asked PATH, its handler for it counted at K.
(define (routed-variant name base path k)
  (make-variant name base 'GET (circuit->handler routed no-env) path k))

(define variants
  (list (make-variant "get-raw" #f 'GET raw)
        (make-variant "get-awaiting" "get-raw" 'GET awaited)
        (make-variant "get-adapter" "get-raw" 'GET (circuit->handler hello no-env))
        (make-variant "get-five" "get-adapter" 'GET (circuit->handler five no-env))
        (make-variant "get-adapter-park" "get-adapter" 'GET (circuit->handler parked-hello no-env))
        (make-variant "catch-none" "get-adapter" 'GET (circuit->handler (wrap-catch hello) no-env))
        (make-variant "catch-none-park" "get-adapter-park" 'GET
                      (circuit->handler (wrap-catch parked-hello) no-env))
        (make-variant "get-ondone" "get-adapter" 'GET (circuit->handler ondone-hello no-env))
        (make-variant "log" "get-adapter" 'GET (circuit->handler (wrap-log hello) no-env))
        (make-variant "timeout" "get-adapter" 'GET (circuit->handler ((wrap-timeout 30000) hello) no-env))
        (make-variant "timeout-park" "get-adapter-park" 'GET
                      (circuit->handler ((wrap-timeout 30000) parked-hello) no-env))
        (make-variant "get-adapter-bytes" "get-adapter" 'GET (circuit->handler bytes-hello no-env))
        (make-variant "get-adapter-port" "get-adapter-bytes" 'GET (circuit->handler port-hello no-env))
        (make-variant "post-raw" #f 'POST post-raw)
        (make-variant "post-awaiting" "post-raw" 'POST post-awaited)
        (make-variant "post-adapter" "post-raw" 'POST (circuit->handler post-hello no-env))
        (path-variant "path-word" "/users/new" 3)
        (path-variant "path-param" "/users/42" 4)
        (path-variant "path-miss" "/nope/nothing" 5)
        (routed-variant "router-word" "path-word" "/users/new" 0)
        (routed-variant "router-param" "path-param" "/users/42" 1)
        (routed-variant "router-miss" "path-miss" "/nope/nothing" 2)))

;; variant-named : String -> Variant
(define (variant-named name) (find (lambda (v) (string=? (variant-name v) name)) variants))

;;; ------------------------------------------------------------------------
;;; Probes, off the server: the variants do what their names say, so a
;;; figure measures what its gate names.

;; refuse : String -> Void — says why the gate measured nothing, and exits 1.
(define (refuse why)
  (printf "gate: ~a\n" why)
  (exit 1))

;; probe-req : -> Req — a request over a view of nothing.
(define probe-view
  (make-req-view (lambda (s) 'GET) (lambda (s) "") (lambda (s) "/") #f (lambda (s) '(1 . 1))
                 #f #f #f #f #f #f #f #f #f))
(define (probe-req) (make-req probe-view #f))

;; outcome : (-> Any) -> Any — what `thunk` returns, or (raised . Symbol).
(define (outcome thunk)
  (guard (e ((deadline-passed? e) '(raised . deadline-passed))
            ((client-closed? e) '(raised . client-closed))
            (#t '(raised . other)))
    (thunk)))

(define (probe!)
  (for-each
   (lambda (probe)
     (let* ((v (variant-named (car probe)))
            (route-name (cadr probe))
            (got (outcome (lambda () (routed (req-with-path (probe-req) (variant-path v)))))))
       (unless (and (res? got) (= (res-status got) 200) (eq? (res-headers got) (caddr probe)))
         (refuse (call-with-string-output-port
                  (lambda (p) (put-string p (variant-name v)) (put-string p ", GET ")
                          (put-string p (variant-path v)) (put-string p ", answered ")
                          (write (if (res? got) (list 'res (res-status got) (res-headers got)) got)
                                 p)
                          (put-string p ", not through ") (put-string p route-name)))))))
   (list (list "router-word" "the word route /users/new" word-headers)
         (list "router-param" "the parameter route /users/:id" param-headers)
         (list "router-miss" "the not-found handler" miss-headers)))
  (let ((keys (outcome (lambda ()
                         ((apply wrap (lambda (req) (map (lambda (k) (req-ref req k)) five-keys))
                                 (map key-setter five-keys))
                          (probe-req))))))
    (unless (equal? keys '(#t #t #t #t #t))
      (refuse (call-with-string-output-port
               (lambda (p) (put-string p "the five middlewares set ") (write keys p)
                       (put-string p ", not their five keys"))))))
  (let-values (((out said) (open-string-output-port)))
    (parameterize ((chez:current-output-port out))
      (for-each
       (lambda (probe)
         (let* ((label (car probe)) (app (cadr probe)) (expected (caddr probe))
                (got (outcome (lambda ()
                                (let ((r ((wrap-catch app) (probe-req))))
                                  (if (res? r) (list 'res (res-status r)) r))))))
           (unless (equal? got expected)
             (refuse (call-with-string-output-port
                      (lambda (p) (put-string p "the catch helper, ") (put-string p label)
                              (put-string p ", answered ") (write got p) (put-string p ", not ")
                              (write expected p)))))))
       (list (list "nothing raised" hello '(res 200))
             (list "an error raised" (lambda (req) (error 'app "boom")) '(res 500))
             (list "&deadline-passed raised" (lambda (req) (raise (make-deadline-passed)))
                   '(raised . deadline-passed))
             (list "&client-closed raised" (lambda (req) (raise (make-client-closed)))
                   '(raised . client-closed)))))
    (let ((text (said)))
      (unless (string=? text "handler-failed Exception in app: boom\n")
        (refuse (call-with-string-output-port
                 (lambda (p) (put-string p "the catch helper wrote ") (write text p)
                         (put-string p ", not its one handler-failed line")))))))
  (let-values (((out said) (open-string-output-port)))
    (let* ((req (probe-req))
           (got (parameterize ((chez:current-output-port out))
                  (outcome (lambda ()
                             (let ((r ((wrap-log hello (lambda () 7)) req)))
                               (test-req-done! req 'written)
                               (if (res? r) (list 'res (res-status r)) r))))))
           (text (said)))
      (unless (and (equal? got '(res 200)) (string=? text "request GET / 200 written 0 -\n"))
        (refuse (call-with-string-output-port
                 (lambda (p) (put-string p "wrap-log answered ") (write got p)
                         (put-string p " and wrote ") (write text p)
                         (put-string p ", not (res 200) and its one request line"))))))))

;;; ------------------------------------------------------------------------
;;; The server, and oha spawned on its loop.

;; current : Request -> Answer — the variant the server answers with.
(define current raw)

;; counts : (Listof (Pair Symbol Nat)) — the server's log, counted by kind.
(define counts '())
(define listening #f)

;; log! : Symbol (Listof Any) -> Void — the server's log: counted, and the
;; listening port noted.
(define (log! what details)
  (when (eq? what 'listening) (set! listening details))
  (let ((cell (assq what counts)))
    (if cell (set-cdr! cell (+ (cdr cell) 1)) (set! counts (cons (cons what 1) counts)))))

(define loop #f)
(define sh #f)
(define url #f)

;; start! : -> Void — the server, listening on a port the kernel picks.
(define (start!)
  (set! loop (make-uv-loop))
  (set! sh (start-server loop
                         (lambda (request) (current request))
                         (lambda (name) (and (string=? name "CHEZ_HTTP_PORT") "0"))
                         log!))
  (set! url (string-append "http://127.0.0.1:" (number->string (cadr listening)))))

;; null-port : TextualOutputPort — /dev/null, every run's standard output,
;; flushed as standard output is: wrap-log flushes each line.
(define null-port
  (open-file-output-port "/dev/null" (file-options no-fail) (buffer-mode block) (native-transcoder)))

;; allocated : -> Nat — the bytes this process has allocated, all told.
(define (allocated) (sstats-bytes (statistics)))

;; spawn : String (Listof String) -> (Values Nat (U Nat #f) String)
;; Run `program` with `args` to its end, turning the server's loop as
;; `serve` does meanwhile, with this process's standard output at
;; /dev/null: the bytes allocated from its start to its end, its exit
;; status, and what it wrote on standard output.
(define (spawn program args)
  (let* ((out (make-uv-pipe loop)) (said (make-byte-collector)) (exit #f)
         (b0 (allocated))
         (child (uv-spawn! loop program (cons program args)
                           (list (cons 'stdio (list 'ignore (list 'pipe out 'from-child) 'ignore)))
                           (lambda (status signal) (set! exit (list status signal))))))
    (uv-read-start! out (lambda (bv start end) (collect-span! said bv start end)) (lambda () #f) (lambda (e) #f))
    (parameterize ((chez:current-output-port null-port))
      (shell-run-turns! sh (lambda () (not exit))))
    (let ((b1 (allocated)))
      (uv-close! child)
      (uv-close! out)
      (values (- b1 b0) (car exit) (utf8->string (collector-bytes said))))))

;; target : Variant -> String — the URL oha asks for V: the server's, and its path.
(define (target v) (string-append url (variant-path v)))

;; method-args : Variant -> (Listof String) — oha's flags for its method.
(define (method-args v)
  (if (eq? (variant-method v) 'POST) (list "-m" "POST" "-d" post-body) '()))

;; load : String Variant Nat Nat -> Nat
;; oha's `n` requests at `c` connections: the bytes allocated. A run that
;; is not `n` 200s, each with the 6-byte body, and no error, refuses.
(define (load oha v c n)
  (collect)
  (when (variant-counter v)
    (vector-set! asked (variant-counter v) 0))
  (let-values (((bytes status text)
                (spawn oha (append (list "--no-tui" "--output-format" "json" "-t" "10s"
                                         "-n" (number->string n) "-c" (number->string c))
                                   (method-args v) (list (target v))))))
    (let ((codes (json-object text "statusCodeDistribution"))
          (errors (json-object text "errorDistribution"))
          (data (json-number text "totalData")))
      (unless (and (eqv? status 0)
                   (equal? codes (string-append "{\"200\":" (number->string n) "}"))
                   (equal? errors "{}")
                   (eqv? data (* n (bytevector-length hello-bytes))))
        (refuse (string-append (variant-name v) ", " (number->string n) " requests at "
                               (number->string c) " conn: oha exited " (if status (number->string status) "#f")
                               ", status " (or codes "none") ", errors " (or errors "none")
                               ", body bytes " (if data (number->string data) "none")
                               "; its bytes measure nothing")))
      (let ((k (variant-counter v)))
        (when (and k (not (= (vector-ref asked k) n)))
          (refuse (string-append (variant-name v) ", " (number->string n) " requests at "
                                 (number->string c) " conn: its handler for " (variant-path v)
                                 " answered " (number->string (vector-ref asked k))
                                 "; oha asked another path, so its bytes measure nothing"))))
      bytes)))

;; rate : String Variant Nat Nat -> (List Real String)
;; oha for `seconds` at `c` connections: requests a second, and its tallies.
;; A status other than 200 refuses.
(define (rate oha v c seconds)
  (let-values (((bytes status text)
                (spawn oha (append (list "--no-tui" "--output-format" "json"
                                         "-z" (string-append (number->string seconds) "s")
                                         "-c" (number->string c))
                                   (method-args v) (list (target v))))))
    (let ((codes (json-object text "statusCodeDistribution"))
          (errors (json-object text "errorDistribution")))
      (unless (and (eqv? status 0) codes (only-200s? codes))
        (refuse (string-append (variant-name v) ", " (number->string seconds) " s at "
                               (number->string c) " conn: oha exited " (if status (number->string status) "#f")
                               ", status " (or codes "none") ", errors " (or errors "none"))))
      (list (or (json-number text "requestsPerSec") 0)
            (string-append "status " codes " errors " (or errors "none"))))))

;;; oha's report.

;; find-text : String String -> (U Nat #f) — where `sub` first is in `s`.
(define (find-text s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let scan ((i 0))
      (cond ((> (+ i m) n) #f) ((string=? (substring s i (+ i m)) sub) i) (else (scan (+ i 1)))))))

;; json-object : String String -> (U String #f) — the flat object after
;; "key":, its whitespace outside strings removed.
(define (json-object text key)
  (let ((at (find-text text (string-append "\"" key "\":"))))
    (and at
         (let ((n (string-length text)))
           (let open ((i (+ at (string-length key) 3)))
             (cond ((>= i n) #f)
                   ((char=? (string-ref text i) #\{)
                    (let close ((j i) (acc '()) (quoted? #f))
                      (if (>= j n)
                          #f
                          (let ((ch (string-ref text j)))
                            (cond ((char=? ch #\") (close (+ j 1) (cons ch acc) (not quoted?)))
                                  (quoted? (close (+ j 1) (cons ch acc) #t))
                                  ((char=? ch #\}) (list->string (reverse (cons ch acc))))
                                  ((char-whitespace? ch) (close (+ j 1) acc #f))
                                  (else (close (+ j 1) (cons ch acc) #f)))))))
                   (else (open (+ i 1)))))))))

;; only-200s? : String -> Boolean — whether the status object counts 200s
;; and nothing else.
(define (only-200s? codes)
  (let ((prefix "{\"200\":"))
    (and (> (string-length codes) (string-length prefix))
         (string=? (substring codes 0 (string-length prefix)) prefix)
         (for-all char-numeric?
                  (string->list (substring codes (string-length prefix) (- (string-length codes) 1))))
         (char=? (string-ref codes (- (string-length codes) 1)) #\}))))

;; json-number : String String -> (U Real #f) — the number after "key":.
(define (json-number text key)
  (let ((at (find-text text (string-append "\"" key "\":"))))
    (and at
         (let* ((n (string-length text))
                (start (let skip ((i (+ at (string-length key) 3)))
                         (if (and (< i n) (char=? (string-ref text i) #\space)) (skip (+ i 1)) i)))
                (end (let scan ((i start))
                       (if (and (< i n) (memv (string-ref text i) (string->list "0123456789.eE+-"))) (scan (+ i 1)) i))))
           (string->number (substring text start end))))))

;;; ------------------------------------------------------------------------
;;; Tables.

;; results : Hashtable — (name . connections) -> (Listof (Pair Round Real)).
(define results (make-hashtable equal-hash equal?))

;; record! : String Nat Nat Real -> Void
(define (record! name c round value)
  (hashtable-update! results (cons name c) (lambda (l) (cons (cons round value) l)) '()))

;; values-of : String Nat -> (Listof Real) — every round's.
(define (values-of name c) (map cdr (hashtable-ref results (cons name c) '())))

;; paired : String String Nat (Real Real -> Real) -> (Listof Real)
;; `op` of the variant's and its baseline's figure, round by round.
(define (paired name base c op)
  (let ((mine (hashtable-ref results (cons name c) '()))
        (theirs (hashtable-ref results (cons base c) '())))
    (fold-left (lambda (acc m)
                 (let ((t (assv (car m) theirs)))
                   (if t (cons (op (cdr m) (cdr t)) acc) acc)))
               '() mine)))

;; span : (Listof Real) (Real -> String) -> String — "a" or "a–b".
(define (span xs show)
  (if (null? xs)
      "-"
      (let ((lo (show (apply min xs))) (hi (show (apply max xs))))
        (if (string=? lo hi) lo (string-append lo "–" hi)))))

;; grouped : Integer -> String — with a comma between each three digits.
(define (grouped n)
  (let* ((s (number->string (abs n))))
    (let loop ((i (string-length s)) (acc '()))
      (if (<= i 3)
          (apply string-append (if (< n 0) "-" "") (substring s 0 i) acc)
          (loop (- i 3) (cons (string-append "," (substring s (- i 3) i)) acc))))))

;; whole : Real -> String — rounded to an integer.
(define (whole x) (grouped (exact (round x))))

;; signed : Real -> String — rounded, with its sign.
(define (signed x) (let ((s (whole x))) (if (>= (round x) 0) (string-append "+" s) s)))

;; percent : Real -> String — a ratio as a percentage, one decimal.
(define (percent r) (let ((t (exact (round (* 1000 r))))) (string-append (number->string (/ t 10.)) "%")))

;; table : (Listof Variant) String String (Real Real -> Real) (Real -> String) -> Void
;; One row a variant: its figures at 1 and at 50 connections, over its
;; rounds, and `op` of each against its baseline's, round by round.
(define (table vs unit against op show-op)
  (printf "\n| variant | baseline | ~a, 1 conn | ~a, 50 conns | ~a baseline, 1 | ~a baseline, 50 |\n"
          unit unit against against)
  (printf "|:--|:--|--:|--:|--:|--:|\n")
  (for-each
   (lambda (v)
     (let ((name (variant-name v)) (base (variant-base v)))
       (printf "| ~a | ~a | ~a | ~a | ~a | ~a |\n" name (or base "")
               (span (values-of name 1) whole) (span (values-of name 50) whole)
               (if base (span (paired name base 1 op) show-op) "")
               (if base (span (paired name base 50 op) show-op) ""))))
   vs))

;; gate-figures : Gate Nat -> (Listof Real) — the gate's figure at `c`
;; connections, round by round.
(define (gate-figures g c)
  (map (lambda (d) (/ d (gate-per g))) (paired (gate-variant g) (gate-base g) c -)))

;; gate-worst : Gate -> Integer — its worst figure over the rounds and both
;; connection counts, rounded as printed.
(define (gate-worst g)
  (exact (round (apply max (apply append (map (lambda (c) (gate-figures g c)) connection-counts))))))

;; gate-table : -> (Listof Gate) — prints each gate's figure, bound and
;; headroom, and answers the held gates that failed.
(define (gate-table)
  (printf "\nThe gates, design §15.6. Worst is over the rounds and both connection counts; a held gate fails over its bound.\n")
  (printf "\n| gate | figure | 1 conn | 50 conns | worst | bound | headroom | |\n")
  (printf "|:--|:--|--:|--:|--:|--:|--:|:--|\n")
  (fold-left
   (lambda (failed g)
     (let* ((worst (gate-worst g)) (bound (gate-bound g)) (ok? (or (not bound) (<= worst bound))))
       (printf "| ~a | ~a over ~a~a | ~a | ~a | ~a | ~a | ~a | ~a |\n"
               (gate-name g) (gate-variant g) (gate-base g)
               (if (= (gate-per g) 1) "" (string-append ", over " (number->string (gate-per g))))
               (span (gate-figures g 1) signed) (span (gate-figures g 50) signed)
               (signed worst) (if bound (whole bound) "-") (if bound (whole (- bound worst)) "-")
               (cond ((not (gate-held? g)) "printed") (ok? "held, pass") (else "held, FAIL")))
       (if (and (gate-held? g) (not ok?)) (append failed (list g)) failed)))
   '() gates))

;; counted-log : -> String — the server's log, counted by kind.
(define (counted-log)
  (apply string-append
         (map (lambda (cell) (string-append " " (symbol->string (car cell)) "=" (number->string (cdr cell))))
              (list-sort (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b)))) counts))))

;; first-line : String -> String — a command's first line of output.
(define (first-line command)
  (let-values (((to from err pid) (open-process-ports command 'block (native-transcoder))))
    (let ((l (get-line from))) (close-port to) (close-port from) (close-port err)
      (if (eof-object? l) "" l))))

;; header : String -> Void — the machine, Chez, libuv and oha.
(define (header oha)
  (printf "~a, ~a (~a), libuv ~a, ~a\n" (first-line "uname -srm") (scheme-version) (machine-type)
          (uv-version) (first-line (string-append oha " --version"))))

;; iota* : Nat -> (Listof Nat) — 1 to n.
(define (iota* n) (let count ((k n) (acc '())) (if (= k 0) acc (count (- k 1) (cons k acc)))))

;; rotate : (Listof Any) Nat -> (Listof Any) — the list begun `k` further on.
(define (rotate xs k)
  (let ((k (mod k (length xs))))
    (append (list-tail xs k) (let head ((xs xs) (k k)) (if (= k 0) '() (cons (car xs) (head (cdr xs) (- k 1))))))))

;;; ------------------------------------------------------------------------
;;; bytes: the gate

;; bytes-mode : String -> Void — exits 1 when a held gate fails, 0 otherwise.
(define (bytes-mode oha)
  (header oha)
  (set! current raw)
  (load oha (car variants) 1 2000)
  (for-each
   (lambda (k)
     (for-each
      (lambda (v)
        (set! current (variant-handler v))
        (for-each
         (lambda (c)
           (let* ((small (load oha v c small-count))
                  (big (load oha v c large-count))
                  (per (/ (- big small) (- large-count small-count))))
             (record! (variant-name v) c k per)
             (printf "round ~a, ~a, ~a conn: ~a ~a B; ~a ~a B; a request ~a B\n"
                     k (variant-name v) c (grouped small-count) (grouped small)
                     (grouped large-count) (grouped big) (whole per))))
         connection-counts))
      variants))
   (iota* rounds))
  (printf "\nlog:~a\n" (counted-log))
  (printf "\nBytes a request, the whole process; over baseline is the difference, round by round.\n")
  (table variants "B/request" "over" - signed)
  (let ((failed (gate-table)))
    (for-each (lambda (g) (printf "\n  ~a: ~a\n" (gate-name g) (gate-what g))) gates)
    (newline)
    (for-each (lambda (g)
                (printf "gate: FAIL ~a, ~a: ~a over ~a reads ~a B, over its bound of ~a B\n"
                        (gate-name g) (gate-what g) (gate-variant g) (gate-base g)
                        (signed (gate-worst g)) (whole (gate-bound g))))
              failed)
    (if (null? failed)
        (begin (printf "gate: pass, every held gate within its bound\n") (exit 0))
        (exit 1))))

;;; ------------------------------------------------------------------------
;;; rps: G6, the smoke

;; rps-mode : String -> Void — prints, and exits 0 whatever the ratio.
(define (rps-mode oha)
  (let ((vs (list (variant-named "get-raw") (variant-named "get-adapter"))))
    (header oha)
    (set! current raw)
    (rate oha (car vs) 50 1)
    (for-each
     (lambda (k)
       (for-each
        (lambda (c)
          (for-each
           (lambda (v)
             (set! current (variant-handler v))
             (let ((r (rate oha v c rps-seconds)))
               (record! (variant-name v) c k (car r))
               (printf "round ~a, ~a conn, ~a: ~a a second, ~a\n" k c (variant-name v) (whole (car r)) (cadr r))))
           (rotate vs (- k 1))))
        connection-counts))
     (iota* rounds))
    (printf "\nlog:~a\n" (counted-log))
    (printf "\nRequests a second, oha -z ~as, ~a rounds; of baseline is the variant's rate over its baseline's, round by round.\n"
            rps-seconds rounds)
    (table vs "req/s" "of" / percent)
    (let ((ratios (paired "get-adapter" "get-raw" 50 /)))
      (printf "\nG6, the smoke (design §15.6): get-adapter answered ~a of get-raw's rate at 50 connections, against a floor of ~a; ~a. It never fails.\n"
              (span ratios percent) (percent rps-floor)
              (if (for-all (lambda (r) (>= r rps-floor)) ratios) "above it" "BELOW it")))
    (exit 0)))

;;; ------------------------------------------------------------------------

(define args (cdr (command-line)))

(cond
 ((and (= (length args) 2) (member (car args) '("bytes" "rps")))
  (probe!)
  (start!)
  (if (string=? (car args) "bytes") (bytes-mode (cadr args)) (rps-mode (cadr args))))
 (else (printf "usage: gate.sps bytes OHA | rps OHA\n")
       (exit 2)))
