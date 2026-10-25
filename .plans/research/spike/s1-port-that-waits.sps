#!chezscheme
;;; S1, a port that waits, 2026-10-25: can circuit's request body be a binary
;;; input port whose read procedure parks the server's coroutine?  (Design
;;; §4 and §13.)
;;;
;;; No server verb reads a body by waiting yet (upstream ask A4), so this
;;; program stands one in.  A CHANNEL, one per id, is the stand-in verb:
;;; `next-piece` parks the coroutine reading it with `await`, until a second
;;; request, POST /feed, resumes it with its own body, the next piece, or with
;;; eof for an empty body.  The WAITING PORT is a custom binary input port
;;; (make-custom-binary-input-port) whose read! hands out what is left of the
;;; piece it holds, and once that is used up calls next-piece.  A handler that
;;; answered `awaiting` reads the port with the standard procedures, under the
;;; real server on loopback, driven by curl from s1-port-that-waits.sh.  Each
;;; read is reported with what it gave or raised, the parks it crossed, the
;;; bytes read! handed to Chez meanwhile, and where its bytes sit in what was
;;; fed.  Pieces are lines "<id><k>-<5 digits>", so a byte's place shows.
;;;
;;; Routes, each answered with text:
;;;   GET  /read?id=I&case=C[&other=J]  read I's port as case C says, on a
;;;                                     coroutine; each report line is also
;;;                                     logged at once, as "s1 I ..."
;;;   POST /feed?id=I&park=N            wait until I's reader is parked at its
;;;                                     Nth park, then resume it with the body
;;;   GET  /until?id=I&parks=N          wait until I's reader is parked at its
;;;                                     Nth park or later
;;;   GET  /done?id=I                   wait until I's case has ended
;;;   GET  /state                       each channel, and which are parked now
;;;   GET  /probe[?control=1]           item 7's checks, from a plain handler
;;; A wait in /feed, /until or /done gives up after 5 s, answering 504.
;;;
;;; #!chezscheme, not #!r6rs, for `#%$current-winders`, the dynamic-wind
;;; entries in force: every lock form Chez has (critical-section, with-mutex,
;;; with-tc-mutex) is a dynamic-wind, so a count of them inside read! shows
;;; whether Chez put one around the call (item 7).
;;;
;;; Run by the driver, inside the container, from the repository's root:
;;;
;;;   scripts/guix-env sh .plans/research/spike/s1-port-that-waits.sh
(import (rnrs)
        (only (chezscheme) format real-time collections disable-interrupts enable-interrupts
              critical-section fork-thread make-mutex mutex-acquire mutex-release make-condition
              condition-wait condition-signal make-time inspect/object port-closed?
              get-string-some scheme-version machine-type file-buffer-size custom-port-buffer-size
              transcoded-port-buffer-size $primitive)
        (http-server))

;;; ------------------------------------------------------------------
;;; Channels: the stand-in for A4's verb.

;; A channel: its id; the parked reader's resume, or #f; how many times its
;; reader has parked; the pieces fed, reversed; the waits on it, each a
;; (Pair (-> Boolean) resume); the bytes its port's read! has handed out;
;; whether read! is probed (item 7), the winders in force where the probed
;; read was called, and the probe's notes, reversed; whether its case ended.
(define-record-type chan
  (fields id (mutable resume) (mutable parks) (mutable fed) (mutable watchers)
          (mutable handed) (mutable probe?) (mutable w0) (mutable notes) (mutable done?))
  (protocol (lambda (new) (lambda (id) (new id #f 0 '() '() 0 #f 0 '() #f)))))

(define chans (make-hashtable string-hash string=?))

;; chan-of : String -> Chan — the channel `id` names, made the first time.
(define (chan-of id)
  (or (hashtable-ref chans id #f)
      (let ((ch (make-chan id)))
        (hashtable-set! chans id ch)
        ch)))

;; fed-all : Chan -> Bytevector — every piece fed, in order.
(define (fed-all ch) (bv-append (reverse (chan-fed ch))))

;; wake-watchers! : Chan -> Void — resume each wait on `ch` now satisfied.
(define (wake-watchers! ch)
  (let loop ((ws (chan-watchers ch)) (keep '()) (due '()))
    (if (pair? ws)
        (if ((car (car ws)))
            (loop (cdr ws) keep (cons (car ws) due))
            (loop (cdr ws) (cons (car ws) keep) due))
        (begin
          (chan-watchers-set! ch keep)
          (for-each (lambda (w) ((cdr w) #t)) due)))))

;; wait-for : Chan (-> Boolean) String -> (U #t String)
;; #t once `ready?` holds, waiting for it on this coroutine if it does not
;; yet; a string saying what did not happen if 5 s pass first.
(define (wait-for ch ready? what)
  (if (ready?)
      #t
      (let ((mine #f))
        (guard (e ((deadline-passed? e)
                   (chan-watchers-set! ch (remq mine (chan-watchers ch)))
                   (format "~a: not within 5 s (reader at park ~a, parked now: ~a)"
                           what (chan-parks ch) (and (chan-resume ch) #t))))
          (with-deadline 5000
            (lambda ()
              (await (lambda (resume)
                       (set! mine (cons ready? resume))
                       (chan-watchers-set! ch (cons mine (chan-watchers ch)))))
              #t))))))

;; next-piece : Chan -> (U Bytevector Eof)
;; The stand-in verb: park until /feed resumes this reader with the next
;; piece, or eof.  A raise out of the wait, a deadline's or a close's, leaves
;; the channel with no reader parked, and is raised on.
(define (next-piece ch)
  (let ((v (with-exception-handler
            (lambda (e) (chan-resume-set! ch #f) (raise e))
            (lambda ()
              (await (lambda (resume)
                       (chan-resume-set! ch resume)
                       (chan-parks-set! ch (+ (chan-parks ch) 1))
                       (wake-watchers! ch)))))))
    (chan-resume-set! ch #f)
    v))

;;; ------------------------------------------------------------------
;;; The waiting port.

;; make-waiting-port : Chan -> BinaryInputPort
;; read! copies out what is left of the piece it holds; once that is used
;; up it parks in next-piece for the next.  Eof, from an empty feed, ends
;; it: read! answers 0 from then on.
(define (make-waiting-port ch)
  (let ((piece #vu8()) (at 0) (ended? #f))
    (make-custom-binary-input-port
     (string-append "body " (chan-id ch))
     (lambda (bv start count)
       (when (chan-probe? ch) (probe-entry! ch count))
       (let fill ()
         (cond ((< at (bytevector-length piece))
                (let ((n (min count (- (bytevector-length piece) at))))
                  (bytevector-copy! piece at bv start n)
                  (set! at (+ at n))
                  (chan-handed-set! ch (+ (chan-handed ch) n))
                  n))
               (ended? 0)
               (else
                (let ((next (next-piece ch)))
                  (when (chan-probe? ch) (probe-resumed! ch))
                  (if (eof-object? next)
                      (begin (set! ended? #t) 0)
                      (begin (set! piece next) (set! at 0) (fill))))))))
     #f #f #f)))

;;; ------------------------------------------------------------------
;;; Item 7's probes.

;; disable-count : -> Nat — this thread's interrupt-disable count, unchanged.
(define (disable-count)
  (let ((n (disable-interrupts)))
    (enable-interrupts)
    (- n 1)))

;; winders : -> Nat — how many dynamic-wind entries are in force.
(define (winders) (length (#%$current-winders)))

;; frame-names : Continuation Nat -> (Listof (U String #f))
;; The names of the code of the first `n` frames of `k`, innermost first.
(define (frame-names k n)
  (let loop ((o (inspect/object k)) (i 0) (acc '()))
    (if (or (= i n) (not (eq? (o 'type) 'continuation)))
        (reverse acc)
        (let* ((code (o 'code)) (name (and code (code 'name))))
          (loop (o 'link) (+ i 1) (cons name acc))))))

;; note! : Chan String -> Void
(define (note! ch s) (chan-notes-set! ch (cons s (chan-notes ch))))

;; probe-entry! : Chan Nat -> Void — read! has been called: its state then.
(define (probe-entry! ch count)
  (note! ch (format "read! called for ~a B: interrupt-disable count ~a, winders beyond the caller's ~a"
                    count (disable-count) (- (winders) (chan-w0 ch))))
  (when (null? (cdr (chan-notes ch)))
    (note! ch (format "read!'s frames, innermost first: ~s"
                      (call/cc (lambda (k) (frame-names k 7)))))))

;; probe-resumed! : Chan -> Void — read!'s park has ended: its state now.
(define (probe-resumed! ch)
  (note! ch (format "read! resumed from its park: interrupt-disable count ~a, winders beyond the caller's ~a"
                    (disable-count) (- (winders) (chan-w0 ch)))))

(define sink #f)

;; gc-while-allocating : -> Nat — collections during 64 MiB of allocation.
(define (gc-while-allocating)
  (let ((c0 (collections)))
    (let loop ((i 0))
      (when (< i 1024)
        (set! sink (make-bytevector 65536))
        (loop (+ i 1))))
    (set! sink #f)
    (- (collections) c0)))

;; thread-probe : -> String
;; A second thread does port I/O of its own: a custom binary port read, a
;; transcoded read, and a file port opened and closed, whose registration
;; takes Chez's tc-mutex.  What it got, or that it did not finish in 2 s.
(define (thread-probe)
  (let ((m (make-mutex)) (c (make-condition)) (done #f))
    (fork-thread
     (lambda ()
       (let* ((p (make-custom-binary-input-port
                  "probe" (lambda (bv s n) (bytevector-u8-set! bv s 120) 1) #f #f #f))
              (bv (get-bytevector-n p 300))
              (s (get-string-all (transcoded-port (open-bytevector-input-port (string->utf8 "h\xe9;llo"))
                                                  (make-transcoder (utf-8-codec)))))
              (f (open-file-input-port "/dev/null")))
         (close-port f)
         (mutex-acquire m)
         (set! done (list (bytevector-length bv) s))
         (condition-signal c)
         (mutex-release m))))
    (mutex-acquire m)
    (let loop ()
      (cond (done (mutex-release m) (format "finished: ~s" done))
            ((condition-wait c m (make-time 'time-duration 0 2)) (loop))
            (else (mutex-release m) "DID NOT FINISH within 2 s")))))

;; probe-text : Boolean -> String — /probe's answer.  The control runs the
;; allocation inside a critical-section, to show the check can tell.
(define (probe-text control?)
  (let* ((dc (disable-count))
         (gcs (if control? (critical-section (gc-while-allocating)) (gc-while-allocating)))
         (th (if control? "not run" (thread-probe))))
    (format "probe~a: interrupt-disable count ~a; collections during 64 MiB allocated~a: ~a; a second thread's port I/O: ~a; parked now: ~a\n"
            (if control? " (control)" "") dc (if control? " inside a critical-section" "") gcs th
            (parked-now))))

;;; ------------------------------------------------------------------
;;; Reporting.

;; bv-append : (Listof Bytevector) -> Bytevector
(define (bv-append bvs)
  (let ((out (make-bytevector (fold-left (lambda (n bv) (+ n (bytevector-length bv))) 0 bvs))))
    (let loop ((bvs bvs) (at 0))
      (if (null? bvs)
          out
          (let ((len (bytevector-length (car bvs))))
            (bytevector-copy! (car bvs) 0 out at len)
            (loop (cdr bvs) (+ at len)))))))

;; bv-index : Bytevector Bytevector -> (U Nat #f) — where `needle` first is
;; in `hay`.
(define (bv-index hay needle)
  (let ((n (bytevector-length hay)) (m (bytevector-length needle)))
    (let scan ((i 0))
      (cond ((> (+ i m) n) #f)
            ((let same ((j 0))
               (or (= j m)
                   (and (= (bytevector-u8-ref hay (+ i j)) (bytevector-u8-ref needle j))
                        (same (+ j 1)))))
             i)
            (else (scan (+ i 1)))))))

;; sub-text : Bytevector Nat Nat -> String — bytes [start, end) as text,
;; each byte a character.
(define (sub-text bv start end)
  (let loop ((i (- end 1)) (acc '()))
    (if (< i start)
        (list->string acc)
        (loop (- i 1) (cons (integer->char (bytevector-u8-ref bv i)) acc)))))

;; placed : Chan Bytevector -> String — where `bv` sits in what was fed.
(define (placed ch bv)
  (let* ((fed (fed-all ch)) (at (bv-index fed bv)))
    (if at
        (format "= fed[~a,~a)" at (+ at (bytevector-length bv)))
        "NOT a run of what was fed")))

;; condition-kind : Any -> String
(define (condition-kind e)
  (let ((who (if (and (condition? e) (who-condition? e)) (condition-who e) "?")))
    (cond ((deadline-passed? e) (format "&deadline-passed (who ~a)" who))
          ((client-closed? e) (format "&client-closed (who ~a)" who))
          ((and (condition? e) (message-condition? e))
           (format "~a (who ~a): ~a" (record-type-name (record-rtd (car (simple-conditions e))))
                   who (condition-message e)))
          (else (format "~s" e)))))

;; describe : Chan (Pair Symbol Any) -> String — a read's outcome.
(define (describe ch r)
  (let ((v (cdr r)))
    (if (eq? (car r) 'raised)
        (string-append "RAISED " (condition-kind v))
        (cond ((eof-object? v) "eof")
              ((bytevector? v)
               (let ((n (bytevector-length v)))
                 (format "~a B ~s..~s ~a" n (sub-text v 0 (min n 8)) (sub-text v (max 0 (- n 8)) n)
                         (placed ch v))))
              ((string? v) (format "~a chars ~s" (string-length v) v))
              ((char? v) (format "char ~s" v))
              ((fixnum? v) (format "byte ~a ~s" v (integer->char v)))
              (else (format "~s" v))))))

;; step : Chan (String -> Void) String (-> Any) -> (Pair Symbol Any)
;; Run `thunk`, one read, and report what it gave or raised, the parks it
;; crossed, the bytes read! handed to Chez meanwhile, and its time.  The
;; outcome is tagged, so a value is never taken for a raise.
(define (step ch say what thunk)
  (let* ((p0 (chan-parks ch)) (h0 (chan-handed ch)) (t0 (real-time))
         (r (guard (e (#t (cons 'raised e))) (cons 'returned (thunk))))
         (t1 (real-time)))
    (say (format "~a -> ~a | parks +~a, read! handed ~a B, ~a ms"
                 what (describe ch r) (- (chan-parks ch) p0) (- (chan-handed ch) h0) (- t1 t0)))
    r))

;; returned-bv? : (Pair Symbol Any) -> Boolean
(define (returned-bv? r) (and (eq? (car r) 'returned) (bytevector? (cdr r))))

;; account : Chan (String -> Void) (Listof Bytevector) -> Void
;; What the app was given against what was fed, as a whole.
(define (account ch say got)
  (let* ((app (bv-append got)) (fed (fed-all ch))
         (lost (- (bytevector-length fed) (bytevector-length app))))
    (say (format "account: fed ~a B, the app was given ~a B, lost ~a B; given = fed: ~a"
                 (bytevector-length fed) (bytevector-length app) lost (bytevector=? app fed)))))

;; count-byte : Bytevector Nat -> Nat
(define (count-byte bv b)
  (let loop ((i 0) (n 0))
    (if (= i (bytevector-length bv))
        n
        (loop (+ i 1) (if (= (bytevector-u8-ref bv i) b) (+ n 1) n)))))

;;; ------------------------------------------------------------------
;;; The cases, one for each item of the work list.

;; case-bytes : Chan (String -> Void) -> Void
;; Item 1: binary reads that cross parks.  The driver feeds 19 pieces of
;; 1,000 B, then eof, each at the park of its number.
(define (case-bytes ch say)
  (let* ((p (make-waiting-port ch))
         (got '())
         (keep! (lambda (r) (when (returned-bv? r) (set! got (cons (cdr r) got))) r)))
    (keep! (step ch say "get-bytevector-n 2500" (lambda () (get-bytevector-n p 2500))))
    (keep! (step ch say "get-bytevector-n 500" (lambda () (get-bytevector-n p 500))))
    (let* ((look (step ch say "lookahead-u8" (lambda () (lookahead-u8 p))))
           (byte (step ch say "get-u8" (lambda () (get-u8 p)))))
      (when (eq? (car byte) 'returned)
        (set! got (cons (u8-list->bytevector (list (cdr byte))) got)))
      (say (format "lookahead-u8 and get-u8 gave the same byte: ~a" (equal? look byte))))
    (keep! (step ch say "get-bytevector-some" (lambda () (get-bytevector-some p))))
    (keep! (step ch say "get-bytevector-some" (lambda () (get-bytevector-some p))))
    (keep! (step ch say "get-bytevector-some" (lambda () (get-bytevector-some p))))
    (keep! (step ch say "get-bytevector-n 12000 (over file-buffer-size, so gathered in blocks)"
                 (lambda () (get-bytevector-n p 12000))))
    (keep! (step ch say "get-bytevector-all" (lambda () (get-bytevector-all p))))
    (step ch say "get-bytevector-n 1, after the end" (lambda () (get-bytevector-n p 1)))
    (account ch say (reverse got))))

;; case-text : Chan (String -> Void) -> Void
;; Item 2: a UTF-8 transcoded port over the waiting port.  The driver feeds
;; five pieces that split a 2-, 3- and 4-byte character between them, then
;; eof.
(define (case-text ch say)
  (let* ((tp (transcoded-port (make-waiting-port ch)
                              (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode raise))))
         (line (step ch say "get-line" (lambda () (get-line tp))))
         (c (step ch say "get-char" (lambda () (get-char tp))))
         (rest (step ch say "get-string-all" (lambda () (get-string-all tp))))
         (fed (utf8->string (fed-all ch))))
    (say (format "what was fed decodes to ~s" fed))
    (say (format "line, newline, char and rest equal it: ~a"
                 (and (eq? (car line) 'returned) (eq? (car c) 'returned) (eq? (car rest) 'returned)
                      (string=? (string-append (cdr line) "\n" (string (cdr c)) (cdr rest)) fed))))))

;; case-deadline : Chan (String -> Void) -> Void
;; Item 3: with-deadline around a read that parks.  Park 1 is the
;; deadline's; the driver feeds pieces 1-3 at parks 2-4, and eof at 5.
(define (case-deadline ch say)
  (let ((p (make-waiting-port ch)))
    (step ch say "with-deadline 300: get-bytevector-n 3000, nothing fed"
          (lambda () (with-deadline 300 (lambda () (get-bytevector-n p 3000)))))
    (say (format "port-closed? after the raise: ~a" (port-closed? p)))
    (step ch say "get-bytevector-n 1500, outside the deadline" (lambda () (get-bytevector-n p 1500)))
    (with-deadline 200
      (lambda ()
        (step ch say "inside with-deadline 200: sleep-ms 300" (lambda () (sleep-ms 300) 'slept))
        (step ch say "  then get-bytevector-n 10, inside the passed deadline"
              (lambda () (get-bytevector-n p 10)))
        (step ch say "  then get-bytevector-n 1000, inside the passed deadline"
              (lambda () (get-bytevector-n p 1000)))))
    (step ch say "get-bytevector-all, outside it" (lambda () (get-bytevector-all p)))))

;; case-closed : Chan (String -> Void) -> Void
;; Item 4: the client leaves while the read is parked.  The driver feeds
;; piece 1 at park 1, kills the client at park 2, and feeds piece 2 at park
;; 3.
(define (case-closed ch say)
  (let ((p (make-waiting-port ch)))
    (step ch say "get-bytevector-n 3000; the client is killed at park 2"
          (lambda () (get-bytevector-n p 3000)))
    (step ch say "get-bytevector-some, after the close" (lambda () (get-bytevector-some p)))
    (step ch say "with-deadline 300: get-bytevector-some"
          (lambda () (with-deadline 300 (lambda () (get-bytevector-some p)))))))

;; case-two : Chan (String -> Void) String -> Void
;; Item 5: one of two readers parked at once; `other` is the other's id.
;; The driver feeds three pieces each, then eof, interleaved.
(define (case-two ch say other)
  (let* ((p (make-waiting-port ch))
         (r1 (step ch say "get-bytevector-n 2500" (lambda () (get-bytevector-n p 2500))))
         (r2 (step ch say "get-bytevector-all" (lambda () (get-bytevector-all p)))))
    (if (and (returned-bv? r1) (returned-bv? r2))
        (let ((app (bv-append (list (cdr r1) (cdr r2)))))
          (account ch say (list app))
          (say (format "bytes of ~s, the other reader's label, in what this one was given: ~a"
                       other (count-byte app (char->integer (string-ref other 0))))))
        (say "a read raised"))))

;; case-partial-n : Chan (String -> Void) Nat -> Void
;; Item 6: a raise after a partial get-bytevector-n of `n`.  The driver
;; feeds pieces 1-2 at parks 1-2; park 3 meets the deadline; pieces 3-4 at
;; parks 4-5, and eof at 6.
(define (case-partial-n ch say n)
  (let* ((p (make-waiting-port ch))
         (r1 (step ch say (format "with-deadline 400: get-bytevector-n ~a; two pieces come, then none" n)
                   (lambda () (with-deadline 400 (lambda () (get-bytevector-n p n))))))
         (r2 (step ch say "get-bytevector-all, after the raise" (lambda () (get-bytevector-all p)))))
    (account ch say (append (if (returned-bv? r1) (list (cdr r1)) '())
                            (if (returned-bv? r2) (list (cdr r2)) '())))))

;; case-partial-some : Chan (String -> Void) -> Void
;; Item 6, get-bytevector-some's claim: the same feeds and deadline, read by
;; get-bytevector-some, each piece kept as it comes.
(define (case-partial-some ch say)
  (let* ((p (make-waiting-port ch))
         (got '())
         (drain! (lambda ()
                   (let loop ()
                     (let ((bv (get-bytevector-some p)))
                       (if (eof-object? bv)
                           'eof
                           (begin (set! got (cons bv got)) (loop))))))))
    (step ch say "with-deadline 400: get-bytevector-some to eof, keeping each; two pieces come, then none"
          (lambda () (with-deadline 400 drain!)))
    (say (format "kept before the raise: ~a B" (bytevector-length (bv-append got))))
    (step ch say "get-bytevector-some to eof, keeping each, after the raise" drain!)
    (account ch say (reverse got))))

;; case-text-raise : Chan (String -> Void) -> Void
;; Item 6 for text: get-string-some on a UTF-8 transcoded port, under a
;; deadline that passes at park 2.  The driver feeds piece 1 at park 1,
;; piece 2 at park 3 and eof at 4.  Run three times: with piece 1 ending
;; inside a character after 10 ASCII bytes (case text-split) or 600 (case
;; text-split-long), and on a character's boundary (case text-boundary).
(define (case-text-raise ch say)
  (let* ((tp (transcoded-port (make-waiting-port ch)
                              (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode replace))))
         (got '())
         (drain! (lambda ()
                   (let loop ()
                     (let ((s (get-string-some tp)))
                       (if (eof-object? s)
                           'eof
                           (begin (set! got (cons s got)) (loop))))))))
    (step ch say "with-deadline 400: get-string-some to eof, keeping each; one piece comes, then none"
          (lambda () (with-deadline 400 drain!)))
    (say (format "kept before the raise: ~s" (clip (apply string-append (reverse got)))))
    (step ch say "get-string-some to eof, keeping each, after the raise" drain!)
    (let ((app (apply string-append (reverse got))) (fed (utf8->string (fed-all ch))))
      (say (format "fed decodes to ~s, ~a chars; the app was given ~s, ~a chars; equal: ~a"
                   (clip fed) (string-length fed) (clip app) (string-length app) (string=? fed app))))))

;; clip : String -> String — a long string's two ends.
(define (clip s)
  (let ((n (string-length s)))
    (if (<= n 40) s (string-append (substring s 0 12) "..." (substring s (- n 12) n)))))

;; case-probe : Chan (String -> Void) -> Void
;; Item 7: read! probed at each call and after each park; the driver calls
;; /probe while the read is parked.  The control reads inside a
;; critical-section, a lock form, to show the probes see one.  Pieces 1-3 at
;; parks 1-3, the third the control's, and eof at 4.
(define (case-probe ch say)
  (let ((p (make-waiting-port ch)))
    (chan-probe?-set! ch #t)
    (say (format "outside any read: interrupt-disable count ~a" (disable-count)))
    (step ch say "get-bytevector-n 1500, probed"
          (lambda () (chan-w0-set! ch (winders)) (get-bytevector-n p 1500)))
    (step ch say "get-bytevector-n 500, probed"
          (lambda () (chan-w0-set! ch (winders)) (get-bytevector-n p 500)))
    (note! ch "the control follows: a read inside a critical-section, the winders counted outside it")
    (step ch say "control: get-bytevector-some inside a critical-section"
          (lambda () (chan-w0-set! ch (winders)) (critical-section (get-bytevector-some p))))
    (say (format "after the control: interrupt-disable count ~a" (disable-count)))
    (step ch say "get-bytevector-all"
          (lambda () (chan-w0-set! ch (winders)) (get-bytevector-all p)))
    (chan-probe?-set! ch #f)
    (for-each say (reverse (chan-notes ch)))))

;; run-case : Chan String String -> Response
;; Run case `name` on `ch`'s port, on this coroutine: each report line is
;; logged at once, and all of them are the answer.
(define (run-case ch name other)
  (let* ((lines '())
         (say (lambda (line)
                (let ((out (current-output-port)))
                  (put-string out (string-append "s1 " (chan-id ch) " " line "\n"))
                  (flush-output-port out))
                (set! lines (cons line lines)))))
    (say (format "case ~a" name))
    (case (string->symbol name)
      ((bytes) (case-bytes ch say))
      ((text) (case-text ch say))
      ((deadline) (case-deadline ch say))
      ((closed) (case-closed ch say))
      ((two) (case-two ch say other))
      ((partial-n) (case-partial-n ch say 5000))
      ((partial-big) (case-partial-n ch say 20000))
      ((partial-some) (case-partial-some ch say))
      ((text-split text-split-long text-boundary) (case-text-raise ch say))
      ((probe) (case-probe ch say))
      (else (say "no such case")))
    (say "end")
    (chan-done?-set! ch #t)
    (wake-watchers! ch)
    (text 200 (apply string-append (map (lambda (l) (string-append l "\n")) (reverse lines))))))

;;; ------------------------------------------------------------------
;;; The server.

;; text : Nat String -> Response
(define (text status s)
  (make-response status #f
                 (list (cons (string->utf8 "content-type") (string->utf8 "text/plain; charset=utf-8")))
                 (string->utf8 s)))

;; param : Request String -> (U String #f) — `key`'s value in the query.
(define (param req key)
  (let ((q (request-query req)) (k (string-append key "=")))
    (and q
         (let loop ((start 0))
           (let* ((end (let find ((i start))
                         (if (or (= i (string-length q)) (char=? (string-ref q i) #\&)) i (find (+ i 1)))))
                  (part (substring q start end)))
             (cond ((and (>= (string-length part) (string-length k))
                         (string=? (substring part 0 (string-length k)) k))
                    (substring part (string-length k) (string-length part)))
                   ((< end (string-length q)) (loop (+ end 1)))
                   (else #f)))))))

;; parked-now : -> String — the ids whose reader is parked now.
(define (parked-now)
  (let ((ids (list-sort string<? (vector->list (hashtable-keys chans)))))
    (fold-left (lambda (acc id) (if (chan-resume (chan-of id)) (string-append acc " " id) acc)) "" ids)))

;; state-text : -> String — /state's answer.
(define (state-text)
  (let ((ids (list-sort string<? (vector->list (hashtable-keys chans)))))
    (string-append
     (apply string-append
            (map (lambda (id)
                   (let ((ch (chan-of id)))
                     (format "~a: parks ~a, parked now ~a, fed ~a B\n" id (chan-parks ch)
                             (and (chan-resume ch) #t) (bytevector-length (fed-all ch)))))
                 ids))
     (format "parked now:~a\n" (parked-now)))))

;; feed : Chan Nat -> Awaiting — /feed: the body, once the reader is parked
;; at park `n`, resumes it; an empty body resumes it with eof.
(define (feed ch n)
  (awaiting
   (lambda ()
     (read-whole-body
      (lambda (body)
        (let ((ok (wait-for ch (lambda () (and (chan-resume ch) (>= (chan-parks ch) n)))
                            (format "park ~a of ~a" n (chan-id ch)))))
          (cond ((string? ok) (text 504 (string-append ok "\n")))
                ((not (and (chan-resume ch) (= (chan-parks ch) n)))
                 (text 409 (format "expected ~a at park ~a; it is at park ~a, parked now ~a\n"
                                   (chan-id ch) n (chan-parks ch) (and (chan-resume ch) #t))))
                (else
                 (let ((resume (chan-resume ch)) (empty? (= 0 (bytevector-length body))))
                   (chan-resume-set! ch #f)
                   (unless empty? (chan-fed-set! ch (cons body (chan-fed ch))))
                   (resume (if empty? (eof-object) body))
                   (text 200 (format "fed ~a at park ~a: ~a\n" (chan-id ch) n
                                     (if empty? "eof" (format "~a B" (bytevector-length body))))))))))
      (* 1024 1024)))))

;; handler : Request -> Answer
(define (handler req)
  (let ((path (request-path req)) (ch (chan-of (or (param req "id") ""))))
    (cond ((string=? path "/read")
           (let ((name (or (param req "case") "")) (other (or (param req "other") "?")))
             (awaiting (lambda () (run-case ch name other)))))
          ((string=? path "/feed") (feed ch (or (string->number (or (param req "park") "")) 0)))
          ((string=? path "/until")
           (let ((n (or (string->number (or (param req "parks") "")) 0)))
             (awaiting
              (lambda ()
                (let ((ok (wait-for ch (lambda () (and (chan-resume ch) (>= (chan-parks ch) n)))
                                    (format "park ~a of ~a" n (chan-id ch)))))
                  (if (string? ok)
                      (text 504 (string-append ok "\n"))
                      (text 200 (format "~a parked at park ~a\n" (chan-id ch) (chan-parks ch)))))))))
          ((string=? path "/done")
           (awaiting
            (lambda ()
              (let ((ok (wait-for ch (lambda () (chan-done? ch)) (format "the end of ~a's case" (chan-id ch)))))
                (if (string? ok) (text 504 (string-append ok "\n")) (text 200 (format "~a done\n" (chan-id ch))))))))
          ((string=? path "/state") (text 200 (state-text)))
          ((string=? path "/probe") (text 200 (probe-text (and (param req "control") #t))))
          (else (text 404 "no such route\n")))))

(let ((out (current-output-port)))
  (put-string out (format "s1 env: ~a, ~a; file-buffer-size ~a, custom-port-buffer-size ~a, transcoded-port-buffer-size ~a\n"
                          (scheme-version) (machine-type) (file-buffer-size) (custom-port-buffer-size)
                          (transcoded-port-buffer-size)))
  (flush-output-port out))

(serve handler (lambda (name) (and (string=? name "CHEZ_HTTP_PORT") "0")))
