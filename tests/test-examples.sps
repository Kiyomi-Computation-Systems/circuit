#!r6rs
;;; The programs under examples/, and tests/loopback-app.sps, each run as a
;;; process of its own and asked over loopback with curl: what the server's
;;; test host, which has no socket, leaves out (design §10). upgrade.sps's
;;; switch is asked with bash's /dev/tcp instead, since curl can't talk past
;;; a 101. So is each WebSocket's handshake, its frames written by hand,
;;; websocket.sps's and the loopback program's /websocket: the command line
;;; of curl 8.11 and later talks past a WebSocket's 101, but sends its
;;; standard input as one binary message, never a text or a close, and ends
;;; only at its --max-time. A row holds that, skipped where curl --version
;;; lists no ws, as CI's 8.5.0 doesn't. A row runs each with
;;; CHEZ_WS_MAX_MESSAGE_BYTES=4, which chez-websocket reads as the program
;;; starts. Run it from the checkout's root, as make test does.
;;;
;;; Each program runs with the Chez that CHEZ names, on this suite's own
;;; library path, in an environment of PATH, CHEZ_HTTP_HOST=127.0.0.1,
;;; CHEZ_HTTP_PORT=0 and the row's own settings, and nothing else (env -i),
;;; so a setting in the caller's shell changes nothing. The suite waits for
;;; the `listening HOST PORT` line serve writes, asks with curl, each call
;;; capped by --max-time, then kills the program, after a failing row too,
;;; and asserts it has ended. Every wait is a poll with a bound. No fixed
;;; sleep stands in for "ready", and the long poll's order comes from the
;;; example's own count of the waits in progress, GET /waiting.
;;;
;;; A program runs under a sh of its own, the suite's child, which writes the
;;; program's pid before the program runs and its exit status once it has
;;; ended. The program is that sh's child, in the suite's process group, so
;;; make test's timeout reaches it too. Chez reaps no child, so each sh stays
;;; a zombie, holding nothing, until the suite exits.
;;;
;;; Oracles: examples/README.md, which says what each example answers; curl,
;;; which says which local port it used; the settings a row gives; the
;;; bytes a row sends, which the echo hands back; and, for
;;; the line (circuit middleware waits)'s catch writes, the line the server
;;; writes in the same process for the same raise let out. A response is
;;; asserted whole: its status line, its header fields in order, Date's
;;; value aside, and its body. Each example is also read as data: it
;;; imports (rnrs), (circuit) and (circuit http-server) alone, but
;;; middleware.sps, which imports (circuit middleware waits) too,
;;; router.sps, which imports (circuit router) too, and websocket.sps, which
;;; imports (circuit websocket) and (websocket) too; and its last form calls
;;; run-server. For websocket.sps, RFC 6455 is an oracle too: §1.3's key
;;; and its accept, §5.7's masked Hello and its unmasked form, and §5.5.1's
;;; close answered with its code.
;;;
;;; Where a row reads a program's standard output, it asserts every line,
;;; whole and in order, one character a byte, a request line's milliseconds
;;; aside, which a row bounds where it can. The suite waits, with a bound,
;;; for each request's lines before it makes the next, so their order is
;;; the program's.
;;;
;;; The two addresses read the same over 127.0.0.1, so one row connects from
;;; 127.0.0.2. Linux routes all of 127.0.0.0/8 to loopback. Where curl can't
;;; bind it (exit 45, as on a Mac without the alias), that row is skipped.
;;;
;;; Left out: the long poll's 504, which comes 30 s into a wait. Its shape,
;;; an app that awaits inside with-deadline and answers 504, is a row of
;;; tests/test-http-server.sps.
;;;
;;; To run mutants, run this suite from a directory holding an examples/ and
;;; a tests/loopback-app.sps of its own, on an absolute library path, with a
;;; mutant library first on it for the adapter's or (circuit middleware
;;; waits).
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (only (chezscheme) getenv library-directories open-process-ports native-transcoder
              sleep make-time current-time time-second time-nanosecond mkdir))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner names a failing test but not its values. Print both.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (memq (test-result-kind r) '(fail xpass))
        (display "  expected: ")
        (write (test-result-ref r 'expected-value))
        (newline)
        (display "  actual:   ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

;;; ------------------------------------------------------------------------
;;; Text and files

;; join : String (Listof String) -> String
(define (join separator words)
  (if (null? words)
      ""
      (fold-left (lambda (line word) (string-append line separator word)) (car words) (cdr words))))

;; shell-quote : String -> String — S as one POSIX shell word.
(define (shell-quote s)
  (call-with-string-output-port
   (lambda (p)
     (put-char p #\')
     (string-for-each (lambda (c) (if (char=? c #\') (put-string p "'\\''") (put-char p c))) s)
     (put-char p #\'))))

;; string-search : String String Nat -> (U Nat #f)
;; Where PART first begins in S, at START or after.
(define (string-search s part start)
  (let ((n (string-length s))
        (m (string-length part)))
    (let loop ((i start))
      (cond ((> (+ i m) n) #f)
            ((let match ((j 0))
               (or (= j m)
                   (and (char=? (string-ref s (+ i j)) (string-ref part j)) (match (+ j 1)))))
             i)
            (else (loop (+ i 1)))))))

;; split : String String -> (Listof String) — S cut at each SEPARATOR.
(define (split s separator)
  (let loop ((start 0) (pieces '()))
    (let ((at (string-search s separator start)))
      (if at
          (loop (+ at (string-length separator)) (cons (substring s start at) pieces))
          (reverse (cons (substring s start (string-length s)) pieces))))))

;; file-text : String -> (U String #f) — the file's bytes as UTF-8, or #f if it doesn't exist.
(define (file-text path)
  (and (file-exists? path)
       (call-with-port (open-file-input-port path)
         (lambda (p)
           (let ((bytes (get-bytevector-all p)))
             (if (eof-object? bytes) "" (utf8->string bytes)))))))

;; write-file! : String Bytevector -> Void
(define (write-file! path bytes)
  (call-with-port (open-file-output-port path (file-options no-fail))
    (lambda (p) (put-bytevector p bytes))))

;; counting : Nat -> (Listof Nat) — 0 to N - 1.
(define (counting n)
  (let loop ((i n) (acc '()))
    (if (= i 0) acc (loop (- i 1) (cons (- i 1) acc)))))

;;; ------------------------------------------------------------------------
;;; Time and waits

;; now-ms : -> Nat — the monotonic clock, in milliseconds.
(define (now-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* (time-second t) 1000) (div (time-nanosecond t) 1000000))))

;; pause : Nat -> Void — MS milliseconds, MS under 1,000.
(define (pause ms) (sleep (make-time 'time-duration (* ms 1000000) 0)))

;; poll : (-> Any) Nat -> Any
;; THUNK's first answer that is not #f, asked every 10 ms for at most MS
;; milliseconds and once more at the end; #f if none came.
(define (poll thunk ms)
  (let ((deadline (+ (now-ms) ms)))
    (let loop ()
      (or (thunk)
          (if (< (now-ms) deadline)
              (begin (pause 10) (loop))
              (thunk))))))

;;; ------------------------------------------------------------------------
;;; Processes

;; file-in : String String -> String
(define (file-in dir name) (string-append dir "/" name))

;; number-in : String String -> (U Number #f) — the number DIR's file NAME holds, once it exists.
(define (number-in dir name)
  (let ((text (file-text (file-in dir name))))
    (and text
         (let ((n (string-length text)))
           (string->number (if (and (> n 0) (char=? (string-ref text (- n 1)) #\newline))
                               (substring text 0 (- n 1))
                               text))))))

;; start! : String (Listof String) -> Void
;; Runs ARGV in the background under a sh of its own, which writes in DIR:
;; `pid`, ARGV's pid, before ARGV runs; `out` and `err`, ARGV's standard
;; output and error; and `status`, ARGV's exit status, once it has ended.
;; Each of pid and status is written aside and renamed, so it is whole once
;; it exists. ARGV's standard input is /dev/null.
(define (start! dir argv)
  (let ((d (shell-quote dir)))
    (let-values (((to-sh from-sh errors-of-sh pid)
                  (open-process-ports
                   (string-append
                    "exec </dev/null >" d "/sh 2>&1\n"
                    "sh -c "
                    (shell-quote "echo $$ >\"$0/pid.new\" && mv \"$0/pid.new\" \"$0/pid\" && exec \"$@\"")
                    " " d " " (join " " (map shell-quote argv)) " >" d "/out 2>" d "/err\n"
                    "echo $? >" d "/status.new && mv " d "/status.new " d "/status\n")
                   (buffer-mode block)
                   (native-transcoder))))
      (close-port to-sh)
      (close-port from-sh)
      (close-port errors-of-sh))))

;; ended? : String -> Boolean — whether the process DIR's sh runs has ended.
(define (ended? dir) (file-exists? (file-in dir "status")))

;; stop! : String -> (U 'ended 'outlived-its-kill 'never-ran)
;; Kills the process DIR's sh runs, unless it has ended, and waits at most
;; 10 s for the sh to see it end.
(define (stop! dir)
  (if (ended? dir)
      'ended
      (let ((pid (poll (lambda () (number-in dir "pid")) 10000)))
        (when pid
          (capture-command (list "kill" "-KILL" (number->string pid))))
        (cond ((poll (lambda () (ended? dir)) 10000) 'ended)
              (pid 'outlived-its-kill)
              (else 'never-ran)))))

;;; ------------------------------------------------------------------------
;;; Programs

(define chez (getenv "CHEZ"))

;; library-path : String — this suite's own, as --libdirs takes it.
(define library-path (join ":" (map car (library-directories))))

;; program-argv : String (Listof String) -> (Listof String)
;; PROGRAM run by CHEZ on the suite's library path, its environment PATH,
;; the address settings and SETTINGS ("NAME=VALUE") alone.
(define (program-argv program settings)
  (append (list "env" "-i" (string-append "PATH=" (or (getenv "PATH") ""))
                "CHEZ_HTTP_HOST=127.0.0.1" "CHEZ_HTTP_PORT=0")
          settings
          (list chez "--libdirs" library-path "--program" program)))

;; listening-in : String -> (U (Pair String Nat) #f)
;; The host and port of the first whole line `listening HOST PORT` the
;; program in DIR has written.
(define (listening-in dir)
  (let ((text (file-text (file-in dir "out"))))
    (and text
         (let loop ((lines (split text "\n")))
           ;; The last piece follows the last newline: no whole line.
           (and (pair? lines)
                (pair? (cdr lines))
                (let ((words (split (car lines) " ")))
                  (if (and (= (length words) 3)
                           (string=? (car words) "listening")
                           (string->number (caddr words)))
                      (cons (cadr words) (string->number (caddr words)))
                      (loop (cdr lines)))))))))

;; lines-in : String -> (Listof String)
;; The whole lines the program in DIR has written on standard output, in
;; order, one character a byte, so two lines are equal as strings only when
;; their bytes are.
(define (lines-in dir)
  (let ((path (file-in dir "out")))
    (if (file-exists? path)
        (let ((pieces (reverse (split (call-with-port (open-file-input-port path) bytes-text) "\n"))))
          ;; The last piece follows the last newline: no whole line.
          (reverse (cdr pieces)))
        '())))

;; bytes-text : BinaryInputPort -> String — what is left of PORT, one character a byte.
(define (bytes-text port)
  (let ((bytes (get-bytevector-all port)))
    (if (eof-object? bytes)
        ""
        (list->string (map integer->char (bytevector->u8-list bytes))))))

;; until-lines : String Nat -> (Listof String)
;; lines-in, once the program in DIR has written N whole lines or more,
;; waiting at most 5 s; else the lines it has written by then.
(define (until-lines dir n)
  (or (poll (lambda () (let ((lines (lines-in dir))) (and (>= (length lines) n) lines))) 5000)
      (lines-in dir)))

;; digits? : String -> Boolean — one or more of #\0 to #\9, nothing else.
(define (digits? s)
  (and (> (string-length s) 0)
       (for-all (lambda (c) (char<=? #\0 c #\9)) (string->list s))))

;; blank-ms : String -> (Pair String (U Nat #f))
;; A request line, `request ... MS` with MS in digits, as `request ... N`,
;; and MS; any other line as it is, and #f.
(define (blank-ms line)
  (let* ((words (split line " "))
         (last-word (car (reverse words))))
    (if (and (pair? (cdr words)) (string=? (car words) "request") (digits? last-word))
        (cons (join " " (reverse (cons "N" (cdr (reverse words))))) (string->number last-word 10))
        (cons line #f))))

;; with-program : String String (Listof String)
;;                (String (U (Pair String Nat) 'ended #f) -> Any) -> Void
;; Starts PROGRAM with SETTINGS, waits at most 60 s for its listening line
;; or its end, and calls BODY with its directory and what came: the host
;; and port, 'ended, or #f. Then it kills the program, however BODY ended,
;; and asserts it has ended. NAME begins each row's name. A raise outside a
;; row is a failing row of its own.
(define (with-program name program settings body)
  (let* ((ending 'never-started)
         (raised
          (guard (e (#t (describe e)))
            (call-with-temp-directory
             (lambda (dir)
               (dynamic-wind
                 (lambda () #f)
                 (lambda ()
                   (start! dir (program-argv program settings))
                   (body dir (poll (lambda () (or (listening-in dir) (and (ended? dir) 'ended)))
                                   60000)))
                 (lambda () (set! ending (stop! dir))))))
            #f)))
    (when raised
      (test-equal (string-append name ": nothing raises outside a row") "nothing" raised))
    (test-equal (string-append name ": it has ended once the rows are done") 'ended ending)))

;; with-server-in : String String (Listof String) (String Nat -> Any) -> Void
;; with-program, asserting the program listens on 127.0.0.1 at a port the
;; kernel chose, and then calling BODY with its directory and the port.
(define (with-server-in name program settings body)
  (with-program name program settings
    (lambda (dir heard)
      (test-equal (string-append name ": it listens on 127.0.0.1, at a port the kernel chose")
                  '("127.0.0.1" kernel)
                  (if (pair? heard)
                      (list (car heard) (if (kernel-port? (cdr heard)) 'kernel (cdr heard)))
                      (list heard (file-text (file-in dir "out")) (file-text (file-in dir "err")))))
      (when (pair? heard)
        (body dir (cdr heard))))))

;; with-server : String String (Listof String) (Nat -> Any) -> Void
;; with-server-in, calling BODY with the port alone.
(define (with-server name program settings body)
  (with-server-in name program settings (lambda (dir port) (body port))))

;; kernel-port? : Any -> Boolean
;; A port number, and not 8080, the server's default: the kernel's choice
;; for CHEZ_HTTP_PORT=0, never 8080 on Linux or macOS.
(define (kernel-port? port)
  (and (integer? port) (exact? port) (< 0 port 65536) (not (= port 8080))))

;;; ------------------------------------------------------------------------
;;; curl

;; The most any one request may take, in seconds.
(define curl-seconds "10")

;; url : Nat String -> String
(define (url port target) (string-append "http://127.0.0.1:" (number->string port) target))

;; Answer = (List String (Listof (Pair String String)) String)
;; Fetched = (List (U Answer Any) (U Nat #f))
;; fetch : Nat String String ... -> Fetched
;; curl -i for TARGET on 127.0.0.1:PORT, ARGS before the URL: the answer
;; and the local port curl used, which its --write-out puts on stderr. A
;; curl that fails gives (curl-failed STATUS STDERR) in the answer's place.
(define (fetch port target . args)
  (let* ((r (capture-command
             (append (list "curl" "-sS" "-i" "--max-time" curl-seconds
                           "--write-out" "%{stderr}%{local_port}")
                     args
                     (list (url port target)))))
         (status (car r)))
    (if (= status 0)
        (list (parse-answer (cadr r)) (string->number (caddr r)))
        (list (list 'curl-failed status (caddr r)) #f))))

;; answer : Fetched -> (U Answer Any)
(define (answer fetched) (car fetched))

;; local-port : Fetched -> (U Nat #f)
(define (local-port fetched) (cadr fetched))

;; parse-answer : String -> (U Answer (List 'no-head String))
;; curl -i's output: the status line, the header fields in order, and the
;; body.
(define (parse-answer text)
  (let ((end (string-search text "\r\n\r\n" 0)))
    (if end
        (let ((lines (split (substring text 0 end) "\r\n")))
          (list (car lines)
                (map field (cdr lines))
                (substring text (+ end 4) (string-length text))))
        (list 'no-head text))))

;; field : String -> (Pair String (U String 'no-colon))
;; "Name: value" as (Name . value), Date's value as "<date>": it is the clock's.
(define (field line)
  (let ((at (string-search line ": " 0)))
    (if at
        (let ((name (substring line 0 at)))
          (cons name (if (string=? name "Date") "<date>" (substring line (+ at 2) (string-length line)))))
        (cons line 'no-colon))))

;; The fields the server writes, and the examples' own.
(define date '("Date" . "<date>"))
(define chunked '("Transfer-Encoding" . "chunked"))
(define text-plain '("content-type" . "text/plain"))
(define (content-length n) (cons "Content-Length" (number->string n)))

;; text-answer : String String -> Answer — a text/plain body, sent with its length.
(define (text-answer status-line body)
  (list status-line (list date text-plain (content-length (bytevector-length (string->utf8 body)))) body))

;; empty-answer : String (Pair String String) ... -> Answer — no body, MORE-FIELDS after its length.
(define (empty-answer status-line . more-fields)
  (list status-line (append (list date (content-length 0)) more-fields) ""))

;;; ------------------------------------------------------------------------
;;; The long poll

;; waiting-count : Nat -> (U Nat #f) — N, when GET /waiting answers "N waiting\n".
(define (waiting-count port)
  (let ((a (answer (fetch port "/waiting"))))
    (and (pair? a) (= (length a) 3) (string? (caddr a))
         (let* ((body (caddr a))
                (n (string-length body)))
           (and (equal? a (text-answer "HTTP/1.1 200 OK" body))
                (> n 9)
                (string=? (substring body (- n 9) n) " waiting\n")
                (string->number (substring body 0 (- n 9))))))))

;; until-waiting : Nat Nat -> (U Nat #f)
;; N, once GET /waiting says N waits are in progress; #f if it hasn't in 20 s.
(define (until-waiting port n)
  (poll (lambda () (and (eqv? (waiting-count port) n) n)) 20000))

;; with-waiters : Nat Nat ((Listof String) -> Any) -> (List Any (Listof (List (U Number #f) Any)))
;; Starts N curls on GET /wait, each under a sh of its own (start!), waits
;; for GET /waiting to say N, calls THUNK with their directories, then waits
;; at most 20 s for each to end. THUNK's answer, or (never-waiting N K) when
;; the count never reached N; then each waiter's exit status and answer, in
;; the order they started. Every waiter is killed after, if it hasn't ended.
(define (with-waiters port n thunk)
  (call-with-temp-directory
   (lambda (dir)
     (let ((waiters (map (lambda (i) (file-in dir (string-append "waiter-" (number->string i))))
                         (counting n))))
       (dynamic-wind
         (lambda () #f)
         (lambda ()
           (for-each (lambda (d)
                       (mkdir d)
                       (start! d (list "curl" "-sS" "-i" "--max-time" "30" (url port "/wait"))))
                     waiters)
           (let ((first (if (until-waiting port n)
                            (thunk waiters)
                            (list 'never-waiting n (waiting-count port)))))
             (for-each (lambda (d) (poll (lambda () (ended? d)) 20000)) waiters)
             (list first
                   (map (lambda (d)
                          (list (number-in d "status") (parse-answer (or (file-text (file-in d "out")) ""))))
                        waiters))))
         (lambda () (for-each stop! waiters)))))))

;; send : Nat String -> Any — the answer to POST /send with MESSAGE.
(define (send port message) (answer (fetch port "/send" "--data-binary" message)))

;;; ------------------------------------------------------------------------
;;; The upgrade

;; A bash script, its port its first argument: it asks for Upgrade: echo,
;; "early" right behind the request, and writes on standard output every
;; byte it reads: the head, a line at a time, up to its blank line, then
;; the echo of "early", then of "ping" and of "pong", each sent once the
;; echo before it is in, so a byte too many shifts the next. Each read is
;; bounded by 10 s. bash reads a socket a byte at a time, so no read takes
;; bytes past its own.
(define echo-script
  (string-append
   "LC_ALL=C\n"
   "exec 3<>/dev/tcp/127.0.0.1/\"$1\" || exit 3\n"
   "printf 'GET /chat HTTP/1.1\\r\\nHost: x\\r\\nConnection: upgrade\\r\\nUpgrade: echo\\r\\n\\r\\nearly' >&3\n"
   "while IFS= read -r -t 10 line <&3; do\n"
   "  printf '%s\\n' \"$line\"\n"
   "  [ \"$line\" = $'\\r' ] && break\n"
   "done\n"
   "read -r -t 10 -N 5 got <&3; printf '%s' \"$got\"\n"
   "printf 'ping' >&3\n"
   "read -r -t 10 -N 4 got <&3; printf '%s' \"$got\"\n"
   "printf 'pong' >&3\n"
   "read -r -t 10 -N 4 got <&3; printf '%s' \"$got\"\n"
   "exec 3>&-\n"))

;; echoed : Nat -> (List Nat String String)
;; echo-script run against PORT: its exit status, what it read, and its
;; standard error.
(define (echoed port)
  (capture-command (list "bash" "-c" echo-script "bash" (number->string port))))

;;; ------------------------------------------------------------------------
;;; The WebSocket

;; RFC 6455's frames, as bash's printf writes them: §5.7's masked Hello, and
;; a close of code 1000 (§7.4.1), its body 03 e8 masked with §5.7's key
;; (§5.3).
(define masked-hello "\\x81\\x85\\x37\\xfa\\x21\\x3d\\x7f\\x9f\\x4d\\x51\\x58")
(define masked-close "\\x88\\x82\\x37\\xfa\\x21\\x3d\\x34\\x12")

;; The 101 for RFC 6455 §1.3's key, as the server writes it: no Date, and
;; its Connection: upgrade after the handshake's fields.
(define websocket-head
  (string-append "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                 "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
                 "Connection: upgrade\r\n\r\n"))

;; websocket-script : String (Listof (Pair String Nat)) -> String
;; A bash script, its port its first argument: RFC 6455 §1.3's handshake to
;; PATH, its Origin and subprotocols left out. It writes on standard output
;; the 101's head, a line at a time, up to its blank line; then, for each
;; (FRAME . N) of SENDS, it sends FRAME, once the answer before it is in, and
;; writes in hex, on a line of their own, the N bytes that answer it; then
;; the status of a read past them, 1 at the end of the stream. Each read is
;; bounded by 10 s. bash reads a socket a byte at a time, so no read takes
;; bytes past its own, and none of these frames holds a NUL, which bash
;; would drop.
(define (websocket-script path sends)
  (string-append
   "LC_ALL=C\n"
   "exec 3<>/dev/tcp/127.0.0.1/\"$1\" || exit 3\n"
   "printf 'GET " path " HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n"
   "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\\r\\nSec-WebSocket-Version: 13\\r\\n\\r\\n' >&3\n"
   "while IFS= read -r -t 10 line <&3; do\n"
   "  printf '%s\\n' \"$line\"\n"
   "  [ \"$line\" = $'\\r' ] && break\n"
   "done\n"
   (apply string-append
          (map (lambda (send)
                 (string-append
                  "printf '" (car send) "' >&3\n"
                  "IFS= read -r -t 10 -N " (number->string (cdr send))
                  " got <&3; printf '%s' \"$got\" | od -An -tx1 | tr -d ' \\n'; echo\n"))
               sends))
   "IFS= read -r -t 10 -N 1 got <&3; echo \"read $?\"\n"
   "exec 3>&-\n"))

;; websocket-talked : Nat String (Listof (Pair String Nat)) -> (List Nat String String)
;; websocket-script for PATH and SENDS, run against PORT: its exit status,
;; what it wrote, and its standard error.
(define (websocket-talked port path sends)
  (capture-command (list "bash" "-c" (websocket-script path sends) "bash" (number->string port))))

;; curl-speaks-ws? : Boolean
;; Whether curl --version lists ws among its protocols. curl turns
;; WebSocket on by default from 8.11; CI's, Ubuntu 24.04's 8.5.0, lists no
;; ws and refuses a ws:// URL. A curl that can't be asked speaks none.
(define curl-speaks-ws?
  (guard (e (#t #f))
    (let ((r (capture-command '("curl" "--version"))))
      (and (= (car r) 0)
           (exists (lambda (line)
                     (let ((words (split line " ")))
                       (and (pair? words) (string=? (car words) "Protocols:")
                            (member "ws" (cdr words))
                            #t)))
                   (split (cadr r) "\n"))))))

;;; ------------------------------------------------------------------------
;;; The loopback program

;; addresses-verdict : Fetched String Nat (Pair String String) ... -> Any
;; 'as-curl-saw-them when the answer to /addresses is the four addresses as
;; curl saw them: REMOTE and curl's local port, then 127.0.0.1 and PORT,
;; where the server listens, as text, with MORE-FIELDS after its length;
;; else the answer and curl's port.
(define (addresses-verdict fetched remote port . more-fields)
  (let ((lp (local-port fetched)))
    (if (and lp
             (equal? (answer fetched)
                     (let ((a (text-answer "HTTP/1.1 200 OK"
                                           (string-append "(\"" remote "\" " (number->string lp)
                                                          " \"127.0.0.1\" " (number->string port) ")\n"))))
                       (list (car a) (append (cadr a) more-fields) (caddr a)))))
        'as-curl-saw-them
        (list (answer fetched) 'curl-local-port lp))))

;; could-not-bind? : Fetched -> Boolean — curl's exit 45: the --interface given can't be used.
(define (could-not-bind? fetched)
  (let ((a (answer fetched)))
    (and (pair? a) (eq? (car a) 'curl-failed) (eqv? (cadr a) 45))))

;; The body echo.sps reads chunked: big-size bytes of lower-case letters.
(define big-size 300000)
(define big-bytes
  (let ((bv (make-bytevector big-size)))
    (for-each (lambda (i) (bytevector-u8-set! bv i (+ 97 (mod (* i 7) 26)))) (counting big-size))
    bv))

;;; ------------------------------------------------------------------------
;;; The examples as data

;; program-shape : String -> Any
;; The first datum of the program at PATH, and the operator of its last:
;; for an example, its import form and run-server. Or why it can't say.
(define (program-shape path)
  (guard (e (#t (list 'unreadable (describe e))))
    (call-with-port (open-input-file path)
      (lambda (port)
        (let loop ((data '()))
          (let ((datum (read port)))
            (cond ((not (eof-object? datum)) (loop (cons datum data)))
                  ((and (pair? data) (pair? (car data)))
                   (list (car (reverse data)) (car (car data))))
                  (else (list 'no-form-last (reverse data))))))))))

;;; ------------------------------------------------------------------------
;;; The rows

(test-begin "examples")

(if (not chez)
    (test-equal "CHEZ names the Chez each program runs with" "a Chez" 'unset)
    (begin
      (for-each
       (lambda (name)
         (test-equal (string-append name ": it imports (rnrs), (circuit) and (circuit http-server) alone, and ends in run-server")
                     '((import (rnrs) (circuit) (circuit http-server)) run-server)
                     (program-shape (string-append "examples/" name ".sps"))))
       '("hello" "echo" "stream" "long-poll" "upgrade"))
      (test-equal "middleware: it imports (rnrs), (circuit), (circuit http-server) and (circuit middleware waits) alone, and ends in run-server"
                  '((import (rnrs) (circuit) (circuit http-server) (circuit middleware waits)) run-server)
                  (program-shape "examples/middleware.sps"))
      (test-equal (string-append "router: it imports (rnrs), (circuit), (circuit http-server) and"
                                 " (circuit router) alone, and ends in run-server")
                  '((import (rnrs) (circuit) (circuit http-server) (circuit router)) run-server)
                  (program-shape "examples/router.sps"))
      (test-equal (string-append "websocket: it imports (rnrs), (circuit), (circuit http-server),"
                                 " (circuit websocket) and (websocket) alone, and ends in run-server")
                  '((import (rnrs) (circuit) (circuit http-server) (circuit websocket) (websocket)) run-server)
                  (program-shape "examples/websocket.sps"))

      (with-server "hello" "examples/hello.sps" '()
        (lambda (port)
          (let ((hello (list "HTTP/1.1 200 OK"
                             (list date text-plain '("server" . "circuit") (content-length 6))
                             "hello\n")))
            (test-equal "hello: GET / is hello, as text, with the middleware's server field"
                        hello
                        (answer (fetch port "/")))
            (test-equal "hello: any method and path gets the same"
                        hello
                        (answer (fetch port "/any/path?x=1" "-X" "DELETE"))))))

      (with-server "echo" "examples/echo.sps" '()
        (lambda (port)
          (test-equal "echo: a POST is told its method, path and query, then given its body"
                      (text-answer "HTTP/1.1 200 OK" "POST /some/path?x=1&y=2\nhi there")
                      (answer (fetch port "/some/path?x=1&y=2" "--data-binary" "hi there")))
          (test-equal "echo: a GET with no query and no body"
                      (text-answer "HTTP/1.1 200 OK" "GET /\n")
                      (answer (fetch port "/")))
          (test-equal "echo: a body of 1 MiB, its cap, is read whole"
                      (list "HTTP/1.1 200 OK" (list date text-plain (content-length (+ 9 1048576)))
                            'the-body-sent)
                      (call-with-temp-directory
                       (lambda (dir)
                         (let ((at (make-bytevector 1048576 98)))
                           (write-file! (file-in dir "at") at)
                           (let ((a (answer (fetch port "/at" "-H" "Expect:"
                                                   "--data-binary" (string-append "@" (file-in dir "at"))))))
                             (if (and (pair? a) (= (length a) 3) (string? (caddr a)))
                                 (list (car a) (cadr a)
                                       (if (string=? (caddr a) (string-append "POST /at\n" (utf8->string at)))
                                           'the-body-sent
                                           (list 'a-body-of (string-length (caddr a)))))
                                 a))))))
          (test-equal "echo: a body declared past its cap, 1 MiB, is answered 413, with no 100 Continue"
                      (empty-answer "HTTP/1.1 413 Content Too Large" '("Connection" . "close"))
                      (call-with-temp-directory
                       (lambda (dir)
                         (write-file! (file-in dir "past") (make-bytevector (+ 1048576 1) 97))
                         (let ((a (answer (fetch port "/past" "-H" "Expect: 100-continue"
                                                 "--data-binary" (string-append "@" (file-in dir "past"))))))
                           (if (and (pair? a) (= (length a) 3) (string? (caddr a))
                                    (> (string-length (caddr a)) 100))
                               (list (car a) (cadr a) (list 'a-body-of (string-length (caddr a))))
                               a)))))
          (test-equal "echo: a body of 300,000 bytes, sent chunked, is read whole"
                      (list "HTTP/1.1 200 OK" (list date text-plain (content-length (+ 10 big-size)))
                            'the-body-sent)
                      (call-with-temp-directory
                       (lambda (dir)
                         (write-file! (file-in dir "big") big-bytes)
                         (let ((a (answer (fetch port "/big" "-H" "Transfer-Encoding: chunked"
                                                 "--data-binary" (string-append "@" (file-in dir "big"))))))
                           (if (and (pair? a) (= (length a) 3) (string? (caddr a)))
                               (list (car a) (cadr a)
                                     (if (string=? (caddr a) (string-append "POST /big\n" (utf8->string big-bytes)))
                                         'the-body-sent
                                         (list 'a-body-of (string-length (caddr a)))))
                               a)))))))

      (with-server "stream" "examples/stream.sps" '()
        (lambda (port)
          (test-equal "stream: /count?n=3 is three lines, chunked"
                      (list "HTTP/1.1 200 OK" (list date text-plain chunked) "1\n2\n3\n")
                      (answer (fetch port "/count?n=3")))
          (test-equal "stream: /count?n=+3 is no digits, so it is the default, ten lines"
                      (list "HTTP/1.1 200 OK" (list date text-plain chunked)
                            "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
                      (answer (fetch port "/count?n=+3")))
          (test-equal "stream: /ticks?n=3&ms=100 is three events, chunked, 100 ms apart"
                      (list (list "HTTP/1.1 200 OK"
                                  (list date '("content-type" . "text/event-stream")
                                        '("cache-control" . "no-cache") chunked)
                                  "data: tick 1\n\ndata: tick 2\n\ndata: tick 3\n\n")
                            'waited)
                      (let* ((start (now-ms))
                             (f (fetch port "/ticks?n=3&ms=100"))
                             (took (- (now-ms) start)))
                        (list (answer f) (if (>= took 200) 'waited (list 'took-ms took)))))
          (test-equal "stream: any other path is 404, with a hint"
                      (text-answer "HTTP/1.1 404 Not Found" "try /count?n=5 or /ticks?n=5&ms=1000\n")
                      (answer (fetch port "/nope")))))

      (with-server "long-poll" "examples/long-poll.sps" '()
        (lambda (port)
          (test-equal "long-poll: a POST /send wakes the GET /wait, which answers with the message"
                      (list (text-answer "HTTP/1.1 200 OK" "woke 1\n")
                            (list (list 0 (list "HTTP/1.1 200 OK" (list date (content-length 2)) "hi"))))
                      (with-waiters port 1 (lambda (waiters) (send port "hi"))))
          (test-equal "long-poll: with no one waiting, a send wakes no one"
                      (list (text-answer "HTTP/1.1 200 OK" "0 waiting\n")
                            (text-answer "HTTP/1.1 200 OK" "woke 0\n"))
                      (let* ((waiting (answer (fetch port "/waiting")))
                             (sent (send port "hi")))
                        (list waiting sent)))
          (test-equal "long-poll: one send wakes every waiter, each answered with the message"
                      (let ((both (list 0 (list "HTTP/1.1 200 OK" (list date (content-length 4)) "both"))))
                        (list (text-answer "HTTP/1.1 200 OK" "woke 2\n") (list both both)))
                      (with-waiters port 2 (lambda (waiters) (send port "both"))))
          ;; Killed, curl closes its connection; the server's await raises
          ;; &client-closed in the waiting handler, which forgets the wait.
          (test-equal "long-poll: a waiter that leaves is forgotten"
                      (list (list 'ended 0 (text-answer "HTTP/1.1 200 OK" "woke 0\n"))
                            (list (list 137 (list 'no-head ""))))
                      (with-waiters port 1
                        (lambda (waiters)
                          (let* ((ended (stop! (car waiters)))
                                 (left (until-waiting port 0))
                                 (sent (send port "anyone?")))
                            (list ended left sent)))))
          (test-equal "long-poll: anything else is 404, with a hint"
                      (text-answer "HTTP/1.1 404 Not Found" "GET /wait or /waiting, or POST /send with a message\n")
                      (answer (fetch port "/send")))))

      (with-server "upgrade" "examples/upgrade.sps" '()
        (lambda (port)
          (test-equal "upgrade: Upgrade: echo is switched, a 101 with no Date, then every byte sent comes back, the bytes behind the request first"
                      (list 0
                            (string-append "HTTP/1.1 101 Switching Protocols\r\nupgrade: echo\r\n"
                                           "Connection: upgrade\r\n\r\nearlypingpong")
                            "")
                      (echoed port))
          (test-equal "upgrade: a request that asks for no upgrade is told how to ask, as text"
                      (text-answer "HTTP/1.1 200 OK" "ask for Upgrade: echo\n")
                      (answer (fetch port "/")))
          (test-equal "upgrade: Upgrade: echo without Connection: upgrade is the server's empty 500, the connection closed"
                      (empty-answer "HTTP/1.1 500 Internal Server Error" '("Connection" . "close"))
                      (answer (fetch port "/" "-H" "Upgrade: echo")))
          (test-equal "upgrade: Upgrade: echo over HTTP/1.0, Connection: upgrade and all, is the server's empty 500, the connection closed"
                      (empty-answer "HTTP/1.1 500 Internal Server Error" '("Connection" . "close"))
                      (answer (fetch port "/" "-0" "-H" "Connection: upgrade" "-H" "Upgrade: echo")))))

      (with-server "websocket" "examples/websocket.sps" '()
        (lambda (port)
          (test-equal (string-append "websocket: RFC 6455 §1.3's handshake to /echo is switched, a 101 of"
                                     " Upgrade and §1.3's accept, no Date; §5.7's masked Hello, twice, comes"
                                     " back unmasked each time; a masked close 1000 is answered 1000, and"
                                     " the stream ends")
                      (list 0 (string-append websocket-head "810548656c6c6f\n810548656c6c6f\n880203e8\nread 1\n") "")
                      (websocket-talked port "/echo"
                                        (list (cons masked-hello 7) (cons masked-hello 7) (cons masked-close 4))))
          ;; Skipped, and so reported, where curl lists no ws: CI's 8.5.0.
          ;; The row above is the echo's proof.
          (unless curl-speaks-ws?
            (test-skip 1))
          (test-equal (string-append "websocket: curl's -T - over ws:// sends its standard input, hello, as"
                                     " one message, and prints the echo, then waits for its --max-time:"
                                     " exit 28; skipped where curl --version lists no ws, below 8.11")
                      (list 28 "hello" "")
                      (capture-command
                       (list "sh" "-c"
                             (string-append "printf hello | curl -s --max-time 2 -T - "
                                            (shell-quote (string-append "ws://127.0.0.1:" (number->string port)
                                                                        "/echo"))))))
          (test-equal "websocket: GET /echo that is no handshake is refused, an empty 400, the connection kept"
                      (empty-answer "HTTP/1.1 400 Bad Request")
                      (answer (fetch port "/echo")))
          (test-equal (string-append "websocket: a handshake from another site's page is refused, an empty"
                                     " 403, the connection closed after: it asked to switch")
                      (empty-answer "HTTP/1.1 403 Forbidden" '("Connection" . "close"))
                      (answer (fetch port "/echo" "-H" "Connection: Upgrade" "-H" "Upgrade: websocket"
                                     "-H" "Sec-WebSocket-Version: 13"
                                     "-H" "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="
                                     "-H" "Origin: https://elsewhere.example")))
          (test-equal "websocket: any other path is 404, with a hint"
                      (text-answer "HTTP/1.1 404 Not Found" "open a WebSocket to /echo\n")
                      (answer (fetch port "/")))))

      ;; chez-websocket reads its CHEZ_WS_ variables as the program starts.
      (with-server "websocket, CHEZ_WS_MAX_MESSAGE_BYTES=4" "examples/websocket.sps"
        '("CHEZ_WS_MAX_MESSAGE_BYTES=4")
        (lambda (port)
          (test-equal (string-append "websocket, CHEZ_WS_MAX_MESSAGE_BYTES=4: websocket-res with no limits"
                                     " takes the environment's, so §5.7's Hello of 5 bytes is closed 1009,"
                                     " and the stream ends")
                      (list 0 (string-append websocket-head "880203f1\nread 1\n") "")
                      (websocket-talked port "/echo" (list (cons masked-hello 4))))))

      (with-server "router" "examples/router.sps" '()
        (lambda (port)
          (test-equal "router: GET / is home"
                      (text-answer "HTTP/1.1 200 OK" "home\n")
                      (answer (fetch port "/")))
          (test-equal
            "router: GET /users is the list, and POST /users adds the user its body names, 201"
                      (list (text-answer "HTTP/1.1 200 OK" "ann\nbob\n")
                            (text-answer "HTTP/1.1 201 Created" "created cat\n"))
                      (list (answer (fetch port "/users"))
                            (answer (fetch port "/users" "--data-binary" "cat"))))
          (test-equal "router: GET /users/new is the form: the word beats /users/:id beside it"
                      (text-answer "HTTP/1.1 200 OK" "the new user form\n")
                      (answer (fetch port "/users/new")))
          (test-equal "router: GET /users/42 is user 42, and /users/a%20b user a b, its id decoded"
                      (list (text-answer "HTTP/1.1 200 OK" "user 42\n")
                            (text-answer "HTTP/1.1 200 OK" "user a b\n"))
                      (list (answer (fetch port "/users/42")) (answer (fetch port "/users/a%20b"))))
          (test-equal "router: HEAD /users/42 is GET's head, with no body"
                      (list "HTTP/1.1 200 OK" (list date text-plain (content-length 8)) "")
                      (answer (fetch port "/users/42" "-I")))
          (test-equal (string-append "router: GET /admin/stats is answered through the group's"
                                     " middleware, which adds x-admin")
                      (list "HTTP/1.1 200 OK"
                            (list date text-plain '("x-admin" . "yes") (content-length 8))
                            "2 users\n")
                      (answer (fetch port "/admin/stats")))
          (test-equal
            "router: the mount at /files sees the rest of the path, / when nothing follows"
                      (list (text-answer "HTTP/1.1 200 OK" "file /a/b, mounted at /files\n")
                            (text-answer "HTTP/1.1 200 OK" "file /, mounted at /files\n"))
                      (list (answer (fetch port "/files/a/b")) (answer (fetch port "/files"))))
          (test-equal "router: any other path is an empty 404"
                      (empty-answer "HTTP/1.1 404 Not Found")
                      (answer (fetch port "/nope")))
          (test-equal (string-append "router: DELETE /users/new is an empty 405, its Allow"
                                     " GET, HEAD, though /users/:id is beside it")
                      (list "HTTP/1.1 405 Method Not Allowed"
                            (list date '("allow" . "GET, HEAD") (content-length 0))
                            "")
                      (answer (fetch port "/users/new" "-X" "DELETE")))))

      ;; Each request's lines are waited for before the next request.
      ;; Sleeps and deadlines run on a timer of their own, not the server's
      ;; tick, which ends the waits due earliest first. A sleep is armed
      ;; after the deadline around it, so one of 1001 ms is due after a
      ;; deadline of 1000 however late the loop runs: its 504 rests on no
      ;; timing, and pins the timeout below 1001 ms. A 504's ms is the
      ;; timeout and the loop's lateness, 3 to 6 ms here, with four busy
      ;; loops beside it too; the bound of 1500 allows the loop 500 ms, and
      ;; a clock that read a finer unit than ms would read 1000 times more.
      (with-server-in "middleware" "examples/middleware.sps" '()
        (lambda (dir port)
          (test-equal "middleware: GET / is hello, as text"
                      (text-answer "HTTP/1.1 200 OK" "hello\n")
                      (answer (fetch port "/")))
          (until-lines dir 2)
          (test-equal "middleware: GET /boom raises, and the catch answers an empty 500, the connection kept"
                      (empty-answer "HTTP/1.1 500 Internal Server Error")
                      (answer (fetch port "/boom")))
          (until-lines dir 4)
          (test-equal "middleware: GET /slow?ms=0 answers inside the timeout"
                      (text-answer "HTTP/1.1 200 OK" "waited 0 ms\n")
                      (answer (fetch port "/slow?ms=0")))
          (until-lines dir 5)
          (test-equal "middleware: GET /slow?ms=1500 is cut short by the timeout: an empty 504, no sooner than 1000 ms"
                      (list (empty-answer "HTTP/1.1 504 Gateway Timeout") 'not-before-the-timeout)
                      (let* ((start (now-ms))
                             (f (fetch port "/slow?ms=1500"))
                             (took (- (now-ms) start)))
                        (list (answer f) (if (>= took 1000) 'not-before-the-timeout (list 'took-ms took)))))
          (until-lines dir 6)
          (test-equal "middleware: GET /slow?ms=1001, a millisecond past the timeout, is an empty 504 too"
                      (empty-answer "HTTP/1.1 504 Gateway Timeout")
                      (answer (fetch port "/slow?ms=1001")))
          (until-lines dir 7)
          (test-equal "middleware: any other path is 404, with a hint"
                      (text-answer "HTTP/1.1 404 Not Found" "try /, /slow?ms=1500 or /boom\n")
                      (answer (fetch port "/nope")))
          (let ((lines (map blank-ms (until-lines dir 8))))
            (test-equal "middleware: its standard output, each line whole and in order, a request line's ms aside: the catch's line before its request's"
                        (list (string-append "listening 127.0.0.1 " (number->string port))
                              "request GET / 200 written N"
                              "handler-failed Exception in app: boom"
                              "request GET /boom 500 written N"
                              "request GET /slow 200 written N"
                              "request GET /slow 504 written N"
                              "request GET /slow 504 written N"
                              "request GET /nope 404 written N")
                        (map car lines))
            (test-equal "middleware: each 504's ms, by the real clock, is at least the timeout's 1000, and under 1500, the timeout and 500 ms for the loop's lateness"
                        '(from-1000-to-under-1500 from-1000-to-under-1500)
                        (map (lambda (line)
                               (let ((ms (cdr line)))
                                 (if (and ms (<= 1000 ms) (< ms 1500)) 'from-1000-to-under-1500 (list 'ms ms))))
                             (filter (lambda (line) (string=? (car line) "request GET /slow 504 written N"))
                                     lines))))))

      (with-server "loopback" "tests/loopback-app.sps"
        '("CIRCUIT_PORT_PIECE_BYTES=4" "CHEZ_HTTP_MAX_BODY_BYTES=4")
        (lambda (port)
          (test-equal "loopback: the four addresses are the connection's, as curl saw them"
                      'as-curl-saw-them
                      (addresses-verdict (fetch port "/addresses") "127.0.0.1" port))
          (let ((f (guard (e (#t (list (list 'raised (describe e)) #f)))
                     (fetch port "/addresses" "--interface" "127.0.0.2"))))
            (when (could-not-bind? f)
              (test-skip 1))
            (test-equal "loopback: from 127.0.0.2, the remote address is the client's and the local one the server's"
                        'as-curl-saw-them
                        (addresses-verdict f "127.0.0.2" port)))
          (test-equal "loopback: a port body goes out chunked, in pieces of the CIRCUIT_PORT_PIECE_BYTES its environment set"
                      (list "HTTP/1.1 200 OK" (list date text-plain chunked)
                            "4\r\nabcd\r\n4\r\nefgh\r\n2\r\nij\r\n0\r\n\r\n")
                      (answer (fetch port "/pieces" "--raw")))
          (test-equal (string-append "loopback: /websocket, websocket-res given settings and no limits,"
                                     " echoes §5.7's Hello, and answers a close 1000 with 1000")
                      (list 0 (string-append websocket-head "810548656c6c6f\n880203e8\nread 1\n") "")
                      (websocket-talked port "/websocket" (list (cons masked-hello 7) (cons masked-close 4))))
          (test-equal "loopback: a body as long as the CHEZ_HTTP_MAX_BODY_BYTES its environment set is read whole"
                      (list "HTTP/1.1 200 OK" (list date (content-length 4)) "abcd")
                      (answer (fetch port "/body" "--data-binary" "abcd")))
          (test-equal "loopback: a body past that CHEZ_HTTP_MAX_BODY_BYTES is refused 413"
                      (list "HTTP/1.1 413 Content Too Large"
                            (list date (content-length 0) '("Connection" . "close"))
                            "")
                      (answer (fetch port "/body" "--data-binary" "abcde")))
          ;; /addresses never reads its body. A declared length past the cap
          ;; is refused from the head; a chunked body only by a read, so the
          ;; app answers, and the server closes the connection after it.
          (test-equal "loopback: a declared length past that cap is refused 413, and an app that never reads the body doesn't answer"
                      (list "HTTP/1.1 413 Content Too Large"
                            (list date (content-length 0) '("Connection" . "close"))
                            "")
                      (answer (fetch port "/addresses" "--data-binary" "abcde")))
          (test-equal "loopback: a chunked body past that cap, never read, gets the app's own answer, the connection closed after"
                      'as-curl-saw-them
                      (addresses-verdict (fetch port "/addresses" "-H" "Transfer-Encoding: chunked"
                                                "--data-binary" "abcdefghij")
                                         "127.0.0.1" port '("Connection" . "close")))))

      ;; The raises are irritant, (error 'app "refused" 7); lines,
      ;; (error 'app "two\nlines"); and components, a &warning alone, which
      ;; display-condition shows on two lines. Each is raised under the catch
      ;; and then let out, so the server writes its own line for it; the
      ;; catch's line is held against the server's, in the same process.
      ;; GET /stream writes "1", then waits 30 s before its next write, so a
      ;; line within the 5 s until-lines waits can only come from the
      ;; server reading the client's close: curl, leaving at its
      ;; --max-time, closes with a FIN.
      (with-server-in "loopback, its log" "tests/loopback-app.sps" '()
        (lambda (dir port)
          (let ((raises '(("irritant" . "handler-failed Exception in app: refused with irritant 7")
                          ("lines" . "handler-failed Exception in app: two lines")
                          ("components" . "handler-failed Exception occurred with condition components:   0. &warning"))))
            (for-each
             (lambda (r i)
               (let* ((caught (answer (fetch port (string-append "/caught/" (car r)))))
                      (circuit-line (let ((lines (until-lines dir (+ 2 (* 2 i)))))
                                      (and (= (length lines) (+ 2 (* 2 i))) (list-ref lines (+ 1 (* 2 i))))))
                      (raised (answer (fetch port (string-append "/raised/" (car r)))))
                      (server-line (let ((lines (until-lines dir (+ 3 (* 2 i)))))
                                     (and (= (length lines) (+ 3 (* 2 i))) (list-ref lines (+ 2 (* 2 i)))))))
                 (test-equal (string-append "loopback, its log: " (car r) ", let out, reaches the server, which answers 500, closing, and writes its handler-failed line")
                             (list (empty-answer "HTTP/1.1 500 Internal Server Error" '("Connection" . "close")) (cdr r))
                             (list raised server-line))
                 (test-equal (string-append "loopback, its log: " (car r) ", under wrap-catch, is an empty 500, the connection kept, and the line the server writes for it, byte for byte")
                             (list (empty-answer "HTTP/1.1 500 Internal Server Error")
                                   (if (and (string? server-line) (>= (string-length server-line) 15)
                                            (string=? (substring server-line 0 15) "handler-failed "))
                                       server-line
                                       (list 'no-server-line server-line)))
                             (list caught circuit-line))))
             raises (counting (length raises)))
            (test-equal "loopback, its log: a client that leaves mid-stream, with no write due for 29 s, is heard within 5 s: wrap-log's line ends client-closed"
                        (list 28 "1\n" "request GET /stream 200 client-closed N")
                        (let* ((r (capture-command (list "curl" "-sS" "-N" "--max-time" "1" (url port "/stream"))))
                               (n (+ 2 (* 2 (length raises))))
                               (lines (until-lines dir n)))
                          (list (car r) (cadr r) (and (= (length lines) n) (car (blank-ms (list-ref lines (- n 1))))))))
            (test-equal "loopback, its log: its standard output, each line whole and in order, a request line's ms aside"
                        (append (list (string-append "listening 127.0.0.1 " (number->string port)))
                                (apply append (map (lambda (r) (list (cdr r) (cdr r))) raises))
                                (list "request GET /stream 200 client-closed N"))
                        (map car (map blank-ms (lines-in dir)))))))

      (with-server "loopback, CHEZ_WS_MAX_MESSAGE_BYTES=4" "tests/loopback-app.sps"
        '("CHEZ_WS_MAX_MESSAGE_BYTES=4")
        (lambda (port)
          (test-equal (string-append "loopback, CHEZ_WS_MAX_MESSAGE_BYTES=4: websocket-res given settings and"
                                     " no limits takes the environment's, so §5.7's Hello of 5 bytes is"
                                     " closed 1009, and the stream ends")
                      (list 0 (string-append websocket-head "880203f1\nread 1\n") "")
                      (websocket-talked port "/websocket" (list (cons masked-hello 4))))))

      (with-program "loopback, CIRCUIT_PORT_PIECE_BYTES=12x" "tests/loopback-app.sps"
        '("CIRCUIT_PORT_PIECE_BYTES=12x")
        (lambda (dir heard)
          (test-equal "loopback, CIRCUIT_PORT_PIECE_BYTES=12x: it exits 255 with the config error, before any listening line"
                      (list 'ended 255 ""
                            "Exception in circuit->handler: expected a whole number of bytes, 1 or more, in ASCII digits with irritants (\"CIRCUIT_PORT_PIECE_BYTES\" \"12x\")\n")
                      (list heard (number-in dir "status") (file-text (file-in dir "out"))
                            (file-text (file-in dir "err"))))))))

(test-end "examples")

(exit (suite-exit-status runner))
