#!r6rs
;;; Spike S2, 2026-10-25: what circuit costs over the raw server when every
;;; request runs on a coroutine (circuit design §13, §15.2).
;;;
;;; One server in this process, started as `serve` starts one, under the
;;; default limits, whose handler is whichever VARIANT is current: the raw
;;; server's handlers, and circuit's adapter as a minimal cost model (§3's
;;; req, view and keys, §5's res, §9's adapter, §6's catch helper), every
;;; variant compiled in the same process as its baseline.  oha or curl runs
;;; in a process of its own, spawned on the server's loop, and the loop is
;;; turned as `serve` turns it, shell-run-turns!, until the client has ended:
;;; the method of the server's .plans/research/spike/hoist-request-alloc.sps.
;;; Three modes:
;;;
;;;   bytes OHA [ROUNDS [LARGE]]
;;;     Bytes a request allocates, the whole process: Chez's cumulative
;;;     counter, `sstats-bytes`, read as oha starts and once it has ended,
;;;     for 5,000 requests and for LARGE (25,000 unless given), alternating;
;;;     the difference over the LARGE less 5,000 more leaves out what does
;;;     not grow with the requests.  At 1 and 50 keep-alive connections,
;;;     ROUNDS rounds (2 unless given).
;;;   rps OHA [SECONDS [ROUNDS [GROUP ...]]]
;;;     Requests a second: oha -z SECONDS (5 unless given) at 1 and 50
;;;     keep-alive connections, the variants taking turns within a round,
;;;     each of ROUNDS rounds (2 unless given) starting one variant further
;;;     on.  GROUP is `main` or `catch`; both unless given.  "of baseline" is
;;;     the variant's rate over its baseline's in the same round.
;;;   show
;;;     The coroutines each path makes, and the catch helper across a park,
;;;     a deadline and a client's close, each through curl (the container's,
;;;     on PATH), with a control that shows what the run would have printed
;;;     had the claim been false.
;;;
;;; The variants (`variants`, below): GET raw, its response built once and
;;; built per request; GET answered `awaiting`; GET through the adapter,
;;; with and without §4's judgement from the head; the adapter under five
;;; middlewares that each `req-set` a key; POST raw, `awaiting`, and through
;;; the adapter; and the adapter's app wrapped in `guard`, the catch helper
;;; by `call/1cc` and by `call/cc`, `with-exception-handler` alone, or
;;; nothing, the app answering, raising Chez's `error` or a plain `&error`,
;;; with and without one park, `(sleep-ms 0)`, first.
;;;
;;; Run from the worktree's root, inside the Guix container, through the
;;; driver, which puts the library path and a timeout around it:
;;;
;;;   scripts/guix-env sh .plans/research/spike/s2-run.sh bytes
;;;   scripts/guix-env sh .plans/research/spike/s2-run.sh rps
;;;   scripts/guix-env sh .plans/research/spike/s2-run.sh show
;;;
;;; The variants differ from their baselines only as their names say; where
;;; a response is built once in one and per request in another, the name
;;; says so (get-raw against get-raw-built).
(import (rnrs) (rnrs mutable-pairs)
        (only (chezscheme) printf statistics sstats-bytes collect scheme-version machine-type
              open-process-ports native-transcoder call/1cc real-time)
        (libuv) (only (uv-testing) make-byte-collector collect-span! collector-bytes)
        (http-server)
        (only (http-server body) make-body-reader body-reader-on-piece body-reader-on-end
              body-reader-max-bytes body-reader-whole?)
        (only (http-server private scheduler) current-coroutine)
        (only (http-server private shell) shell-run-turns!)
        (only (http-server private serve) start-server))

;;; ------------------------------------------------------------------------
;;; The cost model: circuit's request, response and adapter, minimal.

;; make-view : 9 procedures-or-#f -> View — §3's view, one procedure per
;; row the host supplies, each taking the host's request.
(define-record-type (view make-view view?)
  (fields method host path query http-version header header-values headers remote-address))

;; server-view : View — the adapter's view over the server's accessors,
;; built once.  The rows whose workarounds reach into (http-server request)
;; (A1, A2) and the peer's address (A3) are #f: no variant reads them.
(define server-view
  (make-view request-method request-host request-path request-query #f
             request-header request-header-values #f #f))

;; make-req : View Any (U BinaryInputPort #f) (Listof (Pair ReqKey Any)) -> Req
;; §3's request: the view, the host's request, the body's port (#f for a
;; request with no body), and the keys middleware set.
(define-record-type (req make-req req?)
  (fields (immutable view req-view) (immutable native req-native)
          (immutable port req-port) (immutable keys req-keys)))

;; req-method : Req -> Symbol — through the view.
(define (req-method r) ((view-method (req-view r)) (req-native r)))

;; req-path : Req -> String — through the view.
(define (req-path r) ((view-path (req-view r)) (req-native r)))

;; req-header : Req String -> (U String #f) — through the view.
(define (req-header r name) ((view-header (req-view r)) (req-native r) name))

;; req-body : Req -> BinaryInputPort — the body, or a port at eof at once.
(define (req-body r) (or (req-port r) (open-bytevector-input-port (make-bytevector 0))))

;; make-req-key : Any -> ReqKey — a key no other library's can equal.
(define-record-type (req-key make-req-key req-key?) (fields name))

;; req-ref : Req ReqKey [Any] -> Any — the value set under `key`, or `default`.
(define req-ref
  (case-lambda
    ((r key) (req-ref r key #f))
    ((r key default) (let ((p (assq key (req-keys r)))) (if p (cdr p) default)))))

;; req-set : Req ReqKey Any -> Req — a copy of the record, one pair consed
;; onto its keys (§3).
(define (req-set r key value)
  (make-req (req-view r) (req-native r) (req-port r) (cons (cons key value) (req-keys r))))

;; make-res : Nat (Listof (Pair String String)) Body -> Res — §5's response.
(define-record-type (res make-res res?) (fields status headers body))

;; latin-1 : String -> Bytevector — one byte a character; above 255 is an
;; assertion violation (§5).
(define (latin-1 s)
  (let* ((n (string-length s)) (bv (make-bytevector n)))
    (let loop ((i 0))
      (if (fx=? i n)
          bv
          (let ((c (char->integer (string-ref s i))))
            (unless (fx<? c 256) (assertion-violation 'circuit->handler "a header character above 255" s))
            (bytevector-u8-set! bv i c)
            (loop (fx+ i 1)))))))

;; encode-headers : (Listof (Pair String String)) -> (Listof (Pair Bytevector Bytevector))
(define (encode-headers hs)
  (if (null? hs)
      '()
      (let* ((name (latin-1 (caar hs))) (value (latin-1 (cdar hs))))
        (cons (cons name value) (encode-headers (cdr hs))))))

;; res->response : Any -> Response — §9's table, for #f, bytevector and
;; string bodies; anything but a res is an assertion violation.
(define (res->response r)
  (unless (res? r) (assertion-violation 'circuit->handler "not a res" r))
  (let ((body (res-body r)))
    (make-response (res-status r) #f (encode-headers (res-headers r))
                   (if (string? body) (string->utf8 body) body))))

;; has-body? : Request -> Boolean — §4's judgement from the head: a
;; Transfer-Encoding field, or a Content-Length that reads anything but 0.
(define (has-body? request)
  (or (and (request-header request "transfer-encoding") #t)
      (exists (lambda (v) (not (string=? v "0")))
              (request-header-values request "content-length"))))

;; circuit->handler : (Req -> Res) -> (Request -> Awaiting)
;; §9's adapter: awaiting for every request; a request with a body read
;; whole (the interim, §4) and handed over as a bytevector port, the app
;; called in the reader's end; one with none, the app called in the thunk.
(define (circuit->handler app)
  (lambda (request)
    (awaiting
     (lambda ()
       (if (has-body? request)
           (read-whole-body
            (lambda (body)
              (res->response (app (make-req server-view request (open-bytevector-input-port body) '())))))
           (res->response (app (make-req server-view request #f '()))))))))

;; circuit->handler/no-check : (Req -> Res) -> (Request -> Awaiting)
;; The adapter without §4's judgement, for bodiless requests only: what
;; the judgement costs, by difference.
(define (circuit->handler/no-check app)
  (lambda (request)
    (awaiting
     (lambda ()
       (res->response (app (make-req server-view request #f '())))))))

;; wrap : Handler Middleware ... -> Handler — the last is outermost (§6).
(define (wrap handler . ms)
  (fold-left (lambda (h m) (m h)) handler ms))

;; key-setter : ReqKey -> Middleware — sets `key` on every request.
(define (key-setter key)
  (lambda (handler)
    (lambda (r) (handler (req-set r key #t)))))

;;; The catch, three ways (§6), and two more measured beside them.

;; error-res : -> Res — the catch's 500.
(define (error-res) (make-res 500 text-headers "circuit: internal server error\n"))

;; passes? : Any -> Boolean — what a catch must let through (§6).
(define (passes? e) (or (client-closed? e) (deadline-passed? e)))

;; wrap-guard : Handler -> Handler — (a) `guard`; a raise that passes? is
;; matched by no clause, so `guard` raises it again itself.
(define (wrap-guard handler)
  (lambda (r)
    (guard (e ((not (passes? e)) (error-res)))
      (handler r))))

;; wrap-catch : Handler -> Handler — (b) the catch helper: an escape by
;; `call/1cc` around `with-exception-handler`; &client-closed and
;; &deadline-passed raised again, to the handler outside, from where they
;; were raised; anything else escapes to a 500.
(define (wrap-catch handler)
  (lambda (r)
    (call/1cc
     (lambda (k)
       (with-exception-handler
        (lambda (e) (if (passes? e) (raise e) (k (error-res))))
        (lambda () (handler r)))))))

;; wrap-catch/cc : Handler -> Handler — the catch helper with a full
;; continuation, `call/cc`, the portable spelling; measured beside it.
(define (wrap-catch/cc handler)
  (lambda (r)
    (call/cc
     (lambda (k)
       (with-exception-handler
        (lambda (e) (if (passes? e) (raise e) (k (error-res))))
        (lambda () (handler r)))))))

;; wrap-handler-only : Handler -> Handler — `with-exception-handler` alone,
;; whose handler raises again and never escapes: what the handler costs
;; without the escape (docs/waiting.md's "next to nothing").
(define (wrap-handler-only handler)
  (lambda (r)
    (with-exception-handler
     (lambda (e) (raise e))
     (lambda () (handler r)))))

;;; ------------------------------------------------------------------------
;;; The apps and the raw handlers.

(define text-headers '(("content-type" . "text/plain")))
(define text-headers/bytes (list (cons (string->utf8 "content-type") (string->utf8 "text/plain"))))

;; hello-response : Response — built once; the raw handler's every answer.
(define hello-response (make-response 200 #f text-headers/bytes (string->utf8 "hello\n")))

;; hello : Req -> Res — the app.
(define (hello r) (make-res 200 text-headers "hello\n"))

;; boom : Req -> Res — the app that raises an ordinary error every time.
;; Chez's `error` puts the raise's continuation in the condition
;; (`continuation-condition?`), a full capture.
(define (boom r) (error 'app "boom"))

;; plain-boom : Req -> Res — raises an &error made by hand, which carries
;; no continuation: boom without the capture.
(define (plain-boom r) (raise (make-error)))

;; parked-hello : Req -> Res — hello, after one park.
(define (parked-hello r) (sleep-ms 0) (make-res 200 text-headers "hello\n"))

;; parked-boom : Req -> Res — boom, after one park.
(define (parked-boom r) (sleep-ms 0) (error 'app "boom"))

;; raw : Request -> Response — the raw server's handler, in place.
(define (raw request) hello-response)

;; raw-built : Request -> Response — the same, the response built per
;; request: what any app that answers a value of its own pays.
(define (raw-built request) (make-response 200 #f text-headers/bytes (string->utf8 "hello\n")))

;; awaited : Request -> Awaiting — raw's response from a coroutine.
(define (awaited request) (awaiting (lambda () hello-response)))

;; post-raw : Request -> BodyReader — the body read whole, in place.
(define (post-raw request) (read-whole-body (lambda (body) hello-response)))

;; post-awaited : Request -> Awaiting — the same from the thunk (§4).
(define (post-awaited request) (awaiting (lambda () (read-whole-body (lambda (body) hello-response)))))

(define five-keys (list (make-req-key 'one) (make-req-key 'two) (make-req-key 'three)
                        (make-req-key 'four) (make-req-key 'five)))

;;; ------------------------------------------------------------------------
;;; The variants.

;; make-variant : String (U String #f) Symbol Symbol (Listof Symbol) Handler -> Variant
;; A variant: its name, its baseline's, GET or POST, its group, the modes
;; it runs in, and its handler.
(define-record-type (variant make-variant variant?)
  (fields name base method group modes handler))

;; catch-variants : -> (Listof Variant) — wrapper by case, each over the
;; unwrapped app with the same park, answering 200; the unwrapped app's
;; own rows over get-adapter, the same handler as catch-none-ok, so the
;; park's cost shows and the direct row is a control that reads zero.  A
;; variant runs in the modes its wrapper and its case both name.
(define (catch-variants)
  (let ((wrappers (list (list "guard" wrap-guard '(bytes rps))
                        (list "helper" wrap-catch '(bytes rps))
                        (list "helper-cc" wrap-catch/cc '(bytes rps))
                        (list "handler-only" wrap-handler-only '(bytes))
                        (list "none" (lambda (h) h) '(bytes rps))))
        (cases (list (list "ok" "" hello '(bytes rps)) (list "raise" "" boom '(bytes rps))
                     (list "raise-plain" "" plain-boom '(bytes))
                     (list "ok" "-park" parked-hello '(bytes rps))
                     (list "raise" "-park" parked-boom '(bytes rps)))))
    (apply append
           (map (lambda (c)
                  (map (lambda (w)
                         (make-variant (string-append "catch-" (car w) "-" (car c) (cadr c))
                                       (if (and (string=? (car w) "none") (string=? (car c) "ok"))
                                           "get-adapter"
                                           (string-append "catch-none-ok" (cadr c)))
                                       'GET 'catch
                                       (filter (lambda (m) (memq m (cadddr c))) (caddr w))
                                       (circuit->handler ((cadr w) (caddr c)))))
                       wrappers))
                cases))))

(define variants
  (append
   (list (make-variant "get-raw" #f 'GET 'main '(bytes rps) raw)
         (make-variant "get-raw-built" "get-raw" 'GET 'main '(bytes rps) raw-built)
         (make-variant "get-awaiting" "get-raw" 'GET 'main '(bytes rps) awaited)
         (make-variant "get-adapter-no-check" "get-raw" 'GET 'main '(bytes) (circuit->handler/no-check hello))
         (make-variant "get-adapter" "get-raw" 'GET 'main '(bytes rps) (circuit->handler hello))
         (make-variant "get-five" "get-adapter" 'GET 'main '(bytes rps)
                       (circuit->handler (apply wrap hello (map key-setter five-keys))))
         (make-variant "post-raw" #f 'POST 'main '(bytes rps) post-raw)
         (make-variant "post-awaiting" "post-raw" 'POST 'main '(bytes rps) post-awaited)
         (make-variant "post-adapter" "post-raw" 'POST 'main '(bytes rps) (circuit->handler hello)))
   (catch-variants)))

;;; ------------------------------------------------------------------------
;;; The server, and the clients spawned on its loop.

;; current : Request -> Answer — the variant the server answers with.
(define current raw)

;; counts : (Listof (Pair Symbol Nat)) — the server's log, counted by kind.
(define counts '())

;; events : (Listof (Pair Symbol (Listof Any))) — the log kept, in show mode.
(define events '())
(define keep-events? #f)
(define listening #f)

;; log! : Symbol (Listof Any) -> Void — the server's log: counted, kept
;; when show asks, and the listening port noted.
(define (log! what details)
  (when (eq? what 'listening) (set! listening details))
  (let ((cell (assq what counts)))
    (if cell (set-cdr! cell (+ (cdr cell) 1)) (set! counts (cons (cons what 1) counts))))
  (when keep-events? (set! events (cons (cons what details) events))))

(define loop (make-uv-loop))
(define sh (start-server loop
                         (lambda (request) (current request))
                         (lambda (name) (and (string=? name "CHEZ_HTTP_PORT") "0"))
                         log!))
(define url (string-append "http://127.0.0.1:" (number->string (cadr listening)) "/"))
(define post-body "hello, world!")

;; allocated : -> Nat — the bytes this process has allocated, all told.
(define (allocated) (sstats-bytes (statistics)))

;; spawn : String (Listof String) -> (Values Nat (U Nat #f) String)
;; Run `program` with `args` to its end, turning the server's loop as
;; `serve` does meanwhile: the bytes allocated from its start to its end,
;; its exit status, and what it wrote on standard output.
(define (spawn program args)
  (let* ((out (make-uv-pipe loop)) (said (make-byte-collector)) (exit #f)
         (b0 (allocated))
         (child (uv-spawn! loop program (cons program args)
                           (list (cons 'stdio (list 'ignore (list 'pipe out 'from-child) 'ignore)))
                           (lambda (status signal) (set! exit (list status signal))))))
    (uv-read-start! out (lambda (bv start end) (collect-span! said bv start end)) (lambda () #f) (lambda (e) #f))
    (shell-run-turns! sh (lambda () (not exit)))
    (let ((b1 (allocated)))
      (uv-close! child)
      (uv-close! out)
      (values (- b1 b0) (car exit) (utf8->string (collector-bytes said))))))

;; method-args : Variant -> (Listof String) — oha's flags for its method.
(define (method-args v)
  (if (eq? (variant-method v) 'POST) (list "-m" "POST" "-d" post-body) '()))

;; load : String Variant Nat Nat -> (List Nat String)
;; oha's `n` requests at `c` connections: the bytes allocated, and oha's
;; tallies.
(define (load oha v c n)
  (collect)
  (let-values (((bytes status text)
                (spawn oha (append (list "--no-tui" "--output-format" "json" "-t" "10s"
                                         "-n" (number->string n) "-c" (number->string c))
                                   (method-args v) (list url)))))
    (list bytes (tallies text))))

;; rate : String Variant Nat Nat -> (List Real String)
;; oha for `seconds` at `c` connections: requests a second, and its tallies.
(define (rate oha v c seconds)
  (let-values (((bytes status text)
                (spawn oha (append (list "--no-tui" "--output-format" "json"
                                         "-z" (string-append (number->string seconds) "s")
                                         "-c" (number->string c))
                                   (method-args v) (list url)))))
    (list (or (json-number text "requestsPerSec") 0) (tallies text))))

;;; oha's report.

;; find-text : String String -> (U Nat #f) — where `sub` first is in `s`.
(define (find-text s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let scan ((i 0))
      (cond ((> (+ i m) n) #f) ((string=? (substring s i (+ i m)) sub) i) (else (scan (+ i 1)))))))

;; squeeze : String -> String — the text with its runs of whitespace one space.
(define (squeeze s)
  (let walk ((cs (string->list s)) (acc '()) (space? #f))
    (cond ((null? cs) (list->string (reverse acc)))
          ((char-whitespace? (car cs)) (walk (cdr cs) (if space? acc (cons #\space acc)) #t))
          (else (walk (cdr cs) (cons (car cs) acc) #f)))))

;; tallies : String -> String — the report's status and error tallies.
(define (tallies text)
  (let ((object (lambda (key)
                  (let ((at (find-text text (string-append "\"" key "\":"))))
                    (if at
                        (let close ((i at)) (if (char=? (string-ref text i) #\}) (substring text (+ at (string-length key) 3) (+ i 1)) (close (+ i 1))))
                        "none")))))
    (let* ((codes (squeeze (object "statusCodeDistribution")))
           (errors (squeeze (object "errorDistribution"))))
      (string-append "status " codes " errors " errors))))

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

;; values-of : String Nat -> (Listof Real) — every round's, oldest first.
(define (values-of name c)
  (map cdr (list-sort (lambda (a b) (< (car a) (car b))) (hashtable-ref results (cons name c) '()))))

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
      (let ((lo (apply min xs)) (hi (apply max xs)))
        (if (= lo hi) (show lo) (string-append (show lo) "–" (show hi))))))

;; whole : Real -> String — rounded to an integer.
(define (whole x) (number->string (exact (round x))))

;; signed : Real -> String — rounded, with its sign.
(define (signed x) (let ((s (whole x))) (if (>= x 0) (string-append "+" s) s)))

;; percent : Real -> String — a ratio as a percentage, one decimal.
(define (percent r) (let ((t (exact (round (* 1000 r))))) (string-append (number->string (/ t 10.)) "%")))

;; table : (Listof Variant) String String (Real Real -> Real) (Real -> String) -> Void
;; One row a variant: its figures at 1 and at 50 connections, over its
;; rounds, and `op` of each against its baseline's, round by round, the
;; columns headed `against` ("over", "of") baseline.
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

;; counted-log : -> String — the server's log so far, counted by kind.
(define (counted-log)
  (apply string-append
         (map (lambda (cell) (string-append " " (symbol->string (car cell)) "=" (number->string (cdr cell))))
              (list-sort (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b)))) counts))))

;; header : String -> Void — the machine, Chez, libuv and the client.
(define (header client)
  (printf "~a, ~a (~a), libuv ~a, ~a\n"
          (let-values (((to from err pid) (open-process-ports "uname -srm" 'block (native-transcoder))))
            (let ((l (get-line from))) (close-port to) (close-port from) (close-port err) l))
          (scheme-version) (machine-type) (uv-version)
          (let-values (((to from err pid) (open-process-ports (string-append client " --version") 'block (native-transcoder))))
            (let ((l (get-line from))) (close-port to) (close-port from) (close-port err) l))))

;; iota* : Nat -> (Listof Nat) — 1 to n.
(define (iota* n) (let count ((k n) (acc '())) (if (= k 0) acc (count (- k 1) (cons k acc)))))

;; rotate : (Listof Any) Nat -> (Listof Any) — the list begun `k` further on.
(define (rotate xs k)
  (let ((k (mod k (length xs))))
    (append (list-tail xs k) (list-head* xs k))))

;; list-head* : (Listof Any) Nat -> (Listof Any) — the first `k`.
(define (list-head* xs k) (if (= k 0) '() (cons (car xs) (list-head* (cdr xs) (- k 1)))))

;;; ------------------------------------------------------------------------
;;; bytes

;; bytes-mode : String Nat Nat -> Void
(define (bytes-mode oha rounds large)
  (let ((vs (filter (lambda (v) (memq 'bytes (variant-modes v))) variants)))
    (header oha)
    (set! current raw)
    (load oha (car vs) 1 2000)
    (for-each
     (lambda (k)
       (for-each
        (lambda (v)
          (set! current (variant-handler v))
          (for-each
           (lambda (c)
             (let* ((small (load oha v c 5000)) (big (load oha v c large))
                    (per (/ (- (car big) (car small)) (- large 5000))))
               (record! (variant-name v) c k per)
               (printf "round ~a, ~a, ~a conn: 5,000 ~a B, ~a; ~a ~a B, ~a; a request ~a B\n"
                       k (variant-name v) c (car small) (cadr small) large (car big) (cadr big) (whole per))))
           '(1 50)))
        vs))
     (iota* rounds))
    (printf "\nlog:~a\n" (counted-log))
    (printf "\nBytes a request, the whole process; over baseline is the difference, round by round.\n")
    (table vs "B/request" "over" - signed)))

;;; ------------------------------------------------------------------------
;;; rps

;; rps-mode : String Nat Nat (Listof Symbol) -> Void
(define (rps-mode oha seconds rounds groups)
  (let ((vs (filter (lambda (v) (and (memq 'rps (variant-modes v)) (memq (variant-group v) groups))) variants)))
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
             (let ((r (rate oha v c seconds)))
               (record! (variant-name v) c k (car r))
               (printf "round ~a, ~a conn, ~a: ~a a second, ~a\n" k c (variant-name v) (whole (car r)) (cadr r))))
           (rotate vs (- k 1))))
        '(1 50)))
     (iota* rounds))
    (printf "\nlog:~a\n" (counted-log))
    (printf "\nRequests a second, oha -z ~as, ~a round~a; of baseline is the variant's rate over its baseline's, round by round.\n"
            seconds rounds (if (= rounds 1) "" "s"))
    (table vs "req/s" "of" / percent)))

;;; ------------------------------------------------------------------------
;;; show

;; notes : (Listof (Pair Symbol (U Coroutine #f))) — where code ran, newest first.
(define notes '())

;; note! : Symbol -> Void — the coroutine `where` runs on, or #f for none.
(define (note! where) (set! notes (cons (cons where (current-coroutine)) notes)))

;; noted-reader : BodyReader -> BodyReader — the same reader, its piece
;; and its end noted.
(define (noted-reader r)
  (make-body-reader (lambda (bv start end) (note! 'piece) ((body-reader-on-piece r) bv start end))
                    (lambda () (note! 'end) ((body-reader-on-end r)))
                    (body-reader-max-bytes r)
                    (body-reader-whole? r)))

;; coroutine-story : -> String — the notes, oldest first, each coroutine
;; numbered by its first appearance, and how many there were.
(define (coroutine-story)
  (let walk ((ns (reverse notes)) (seen '()) (acc '()))
    (if (null? ns)
        (string-append (apply string-append (reverse acc))
                       "; coroutines: " (number->string (length seen)))
        (let* ((c (cdar ns))
               (seen (if (and c (not (memq c seen))) (append seen (list c)) seen))
               (label (if c
                          (string-append "#" (number->string (- (length seen) (length (memq c seen)) -1)))
                          "none")))
          (walk (cdr ns) seen
                (cons (string-append (if (null? acc) "" ", ") (symbol->string (caar ns)) " on " label) acc))))))

;; recorded : (Listof Any) — what left the handler under the recorder, newest first.
(define recorded '())

;; kind : Any -> Symbol — a raise, named.
(define (kind e)
  (cond ((client-closed? e) 'client-closed)
        ((deadline-passed? e) 'deadline-passed)
        ((error? e) 'error)
        (else 'other)))

;; wrap-recorder : Handler -> Handler — records each return, with its
;; status, and each raise, by kind, and lets the raise go on.
(define (wrap-recorder handler)
  (lambda (r)
    (let ((v (with-exception-handler
              (lambda (e) (set! recorded (cons (list 'raised (kind e)) recorded)) (raise e))
              (lambda () (handler r)))))
      (set! recorded (cons (list 'returned (res-status v)) recorded))
      v)))

;; wrap-timeout* : Nat Handler -> Handler — §6's wrap-timeout in small:
;; `with-deadline` outside the handler, &deadline-passed a 504.
(define (wrap-timeout* ms handler)
  (lambda (r)
    (call/1cc
     (lambda (k)
       (with-exception-handler
        (lambda (e) (if (deadline-passed? e) (k (make-res 504 text-headers "deadline passed\n")) (raise e)))
        (lambda () (with-deadline ms (lambda () (handler r)))))))))

;; wrap-swallow : Handler -> Handler — a catch that wrongly takes every
;; raise, the two that must pass included: the control for the deadline.
(define (wrap-swallow handler)
  (lambda (r)
    (call/1cc
     (lambda (k)
       (with-exception-handler
        (lambda (e) (k (error-res)))
        (lambda () (handler r)))))))

(define resumed 0)

;; parks-then-boom : Nat -> (Req -> Res) — parks `n` times, then raises.
(define (parks-then-boom n)
  (lambda (r)
    (let park ((i 0))
      (when (< i n) (sleep-ms i) (park (+ i 1))))
    (set! resumed (+ resumed 1))
    (error 'app "boom after a park")))

;; sleeper : Req -> Res — parks 3 s, then answers 200.
(define (sleeper r)
  (sleep-ms 3000)
  (set! resumed (+ resumed 1))
  (make-res 200 text-headers "slept\n"))

;; shot-escape : Req -> Res — the control for an escape that is dead: a
;; one-shot continuation already returned through, invoked after a park.
(define (shot-escape r)
  (let ((k (call/1cc (lambda (k) k))))
    (if (procedure? k)
        (begin (sleep-ms 0) (set! resumed (+ resumed 1)) (k 'again))
        (make-res 200 text-headers "the shot continuation was entered\n"))))

;; one-line : String -> String — curl's -i output on one line, CRs gone.
(define (one-line s)
  (let walk ((cs (string->list s)) (acc '()))
    (cond ((null? cs) (list->string (reverse acc)))
          ((char=? (car cs) #\return) (walk (cdr cs) acc))
          ((char=? (car cs) #\newline) (walk (cdr cs) (append (reverse (string->list " | ")) acc)))
          (else (walk (cdr cs) (cons (car cs) acc))))))

;; status-of : String -> (U Nat #f) — the status in curl's first line.
(define (status-of s)
  (and (> (string-length s) 12) (string->number (substring s 9 12))))

;; logged? : Symbol -> Boolean — whether show's log holds `what`.
(define (logged? what) (and (assq what events) #t))

;; show-case : String Handler (Listof String) Boolean (Nat String Nat -> Boolean) -> Void
;; Answer with `handler`, ask with curl, wait for the recorder if
;; `settle?`, and print what came out and whether it is what `expect`
;; says: of curl's exit, its output and the milliseconds it took.
(define (show-case label handler curl-args settle? expect)
  (set! current handler)
  (set! events '()) (set! recorded '()) (set! notes '()) (set! resumed 0)
  (let* ((t0 (real-time)))
    (let-values (((bytes code out) (spawn "curl" (append (list "-sS" "-i") curl-args (list url)))))
      (let ((ms (- (real-time) t0)))
        (when (and settle? (null? recorded))
          (shell-run-turns! sh (lambda () (null? recorded))))
        (printf "~a\n  curl exit ~a after ~a ms: ~a\n  recorded ~s, resumed ~a, logged ~s~a\n  ~a\n\n"
                label code ms (one-line out) (reverse recorded) resumed
                (map car (reverse (filter (lambda (e) (not (eq? (car e) 'listening))) events)))
                (if (null? notes) "" (string-append "\n  " (coroutine-story)))
                (if (expect code out ms) "as expected" "UNEXPECTED"))))))

;; show-mode : -> Void
(define (show-mode)
  (header "curl")
  (set! keep-events? #t)
  (let ((post (list "--max-time" "5" "--data-binary" post-body)))
    (printf "\n# The coroutines each path makes\n\n")
    (show-case "GET, raw: the handler in place" (lambda (request) (note! 'handler) hello-response)
               '("--max-time" "5") #f
               (lambda (code out ms) (and (eqv? (status-of out) 200) (equal? notes '((handler . #f))))))
    (show-case "GET, the adapter: awaiting, the app in the thunk"
               (circuit->handler (lambda (r) (note! 'app) (hello r)))
               '("--max-time" "5") #f
               (lambda (code out ms) (and (eqv? (status-of out) 200) (= (length notes) 1) (cdar notes))))
    (show-case "POST, raw: read-whole-body in place"
               (lambda (request) (note! 'handler)
                 (noted-reader (read-whole-body (lambda (body) (note! 'proc) hello-response))))
               post #f
               (lambda (code out ms) (and (eqv? (status-of out) 200) (for-all (lambda (n) (not (cdr n))) notes))))
    (show-case "POST, awaiting: read-whole-body from the thunk (§4's body path)"
               (lambda (request) (note! 'handler)
                 (awaiting (lambda () (note! 'thunk)
                             (noted-reader (read-whole-body (lambda (body) (note! 'proc) hello-response))))))
               post #f
               (lambda (code out ms) (eqv? (status-of out) 200)))
    (show-case "POST chunked, awaiting: the same, the body chunked"
               (lambda (request) (note! 'handler)
                 (awaiting (lambda () (note! 'thunk)
                             (noted-reader (read-whole-body (lambda (body) (note! 'proc) hello-response))))))
               (append post '("-H" "Transfer-Encoding: chunked")) #f
               (lambda (code out ms) (eqv? (status-of out) 200)))
    (show-case "GET, awaiting a reader: a reader for a request with no body (§4, §14)"
               (lambda (request) (note! 'handler)
                 (awaiting (lambda () (note! 'thunk)
                             (noted-reader (read-whole-body (lambda (body) (note! 'proc) hello-response))))))
               '("--max-time" "5") #f
               (lambda (code out ms) (eqv? (status-of out) 200)))

    (printf "# The catch helper across a park\n\n")
    (show-case "helper, the app parks once then raises: the helper's 500, no handler-failed"
               (circuit->handler (wrap-recorder (wrap-catch (parks-then-boom 1))))
               '("--max-time" "5") #t
               (lambda (code out ms)
                 (and (eqv? (status-of out) 500) (find-text out "circuit: internal server error")
                      (equal? recorded '((returned 500))) (= resumed 1) (not (logged? 'handler-failed)))))
    (show-case "helper, the app parks three times then raises: the same"
               (circuit->handler (wrap-recorder (wrap-catch (parks-then-boom 3))))
               '("--max-time" "5") #t
               (lambda (code out ms)
                 (and (eqv? (status-of out) 500) (find-text out "circuit: internal server error")
                      (equal? recorded '((returned 500))) (= resumed 1) (not (logged? 'handler-failed)))))
    (show-case "helper by call/cc, the app parks once then raises: the helper's 500, no handler-failed"
               (circuit->handler (wrap-recorder (wrap-catch/cc (parks-then-boom 1))))
               '("--max-time" "5") #t
               (lambda (code out ms)
                 (and (eqv? (status-of out) 500) (find-text out "circuit: internal server error")
                      (equal? recorded '((returned 500))) (= resumed 1) (not (logged? 'handler-failed)))))
    (show-case "helper by call/cc, the app parks three times then raises: the same"
               (circuit->handler (wrap-recorder (wrap-catch/cc (parks-then-boom 3))))
               '("--max-time" "5") #t
               (lambda (code out ms)
                 (and (eqv? (status-of out) 500) (find-text out "circuit: internal server error")
                      (equal? recorded '((returned 500))) (= resumed 1) (not (logged? 'handler-failed)))))
    (show-case "guard, the app parks once then raises: guard's 500 too"
               (circuit->handler (wrap-recorder (wrap-guard (parks-then-boom 1))))
               '("--max-time" "5") #t
               (lambda (code out ms)
                 (and (eqv? (status-of out) 500) (find-text out "circuit: internal server error")
                      (equal? recorded '((returned 500))) (not (logged? 'handler-failed)))))
    (show-case "control, no catch: the server's own 500, handler-failed logged, the connection closed"
               (circuit->handler (wrap-recorder (parks-then-boom 1)))
               '("--max-time" "5") #t
               (lambda (code out ms)
                 (and (eqv? (status-of out) 500) (not (find-text out "circuit: internal server error"))
                      (equal? recorded '((raised error))) (logged? 'handler-failed))))
    (show-case "control, a dead escape: a one-shot continuation already returned through, invoked after a park"
               (circuit->handler (wrap-recorder shot-escape))
               '("--max-time" "5") #t
               (lambda (code out ms)
                 (and (eqv? (status-of out) 500) (= (length recorded) 1) (eq? (caar recorded) 'raised)
                      (logged? 'handler-failed))))
    (show-case "deadline: wrap-timeout 50 ms outside the helper, the app parked 3 s: a 504, the helper re-raised it"
               (circuit->handler (wrap-timeout* 50 (wrap-recorder (wrap-catch sleeper))))
               '("--max-time" "5") #t
               (lambda (code out ms)
                 (and (eqv? (status-of out) 504) (find-text out "deadline passed")
                      (equal? recorded '((raised deadline-passed))) (= resumed 0) (< ms 1000)
                      (not (logged? 'handler-failed)))))
    (show-case "deadline, the helper by call/cc: the same 504, re-raised"
               (circuit->handler (wrap-timeout* 50 (wrap-recorder (wrap-catch/cc sleeper))))
               '("--max-time" "5") #t
               (lambda (code out ms)
                 (and (eqv? (status-of out) 504) (find-text out "deadline passed")
                      (equal? recorded '((raised deadline-passed))) (= resumed 0) (< ms 1000)
                      (not (logged? 'handler-failed)))))
    (show-case "control, a catch that swallows the deadline: a 500, not a 504"
               (circuit->handler (wrap-timeout* 50 (wrap-recorder (wrap-swallow sleeper))))
               '("--max-time" "5") #t
               (lambda (code out ms)
                 (and (eqv? (status-of out) 500) (equal? recorded '((returned 500))))))
    (show-case "client-closed: curl leaves after 300 ms, the app parked 3 s inside the helper: re-raised, not logged"
               (circuit->handler (wrap-recorder (wrap-catch sleeper)))
               '("--max-time" "0.3") #t
               (lambda (code out ms)
                 (and (eqv? code 28) (equal? recorded '((raised client-closed))) (= resumed 0)
                      (not (logged? 'handler-failed)))))
    (show-case "client-closed, the helper by call/cc: re-raised, not logged"
               (circuit->handler (wrap-recorder (wrap-catch/cc sleeper)))
               '("--max-time" "0.3") #t
               (lambda (code out ms)
                 (and (eqv? code 28) (equal? recorded '((raised client-closed))) (= resumed 0)
                      (not (logged? 'handler-failed)))))
    (show-case "control, the swallowing catch and the client's close: the close is taken for an error"
               (circuit->handler (wrap-recorder (wrap-swallow sleeper)))
               '("--max-time" "0.3") #t
               (lambda (code out ms)
                 (and (eqv? code 28) (equal? recorded '((returned 500))) (= resumed 0))))))

;;; ------------------------------------------------------------------------

(define args (cdr (command-line)))

;; arg : Nat Any -> Any — the `i`th argument after the mode, as a number,
;; or `default`.
(define (arg i default)
  (if (> (length args) i) (string->number (list-ref args i)) default))

(cond
 ((and (pair? args) (string=? (car args) "bytes")) (bytes-mode (cadr args) (arg 2 2) (arg 3 25000)))
 ((and (pair? args) (string=? (car args) "rps"))
  (rps-mode (cadr args) (arg 2 5) (arg 3 2)
            (if (> (length args) 4) (map string->symbol (list-tail args 4)) '(main catch))))
 ((and (pair? args) (string=? (car args) "show")) (show-mode))
 (else (printf "usage: bytes OHA [ROUNDS [LARGE]] | rps OHA [SECONDS [ROUNDS [GROUP ...]]] | show\n")
       (exit 2)))
