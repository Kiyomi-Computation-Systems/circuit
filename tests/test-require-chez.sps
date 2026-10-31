#!r6rs
;;; scripts/require-chez, and the Makefile's use of it: the check that
;;; refuses a Chez below 10.4.1, one without threads, or no Chez at all,
;;; before a target runs it, and the default CHEZ, the first of scheme and
;;; chez on PATH that is Chez Scheme.
;;;
;;; Each row runs against fake binaries in a directory of its own: shell
;;; scripts that answer the check's probe with a line of their own, and log
;;; each run's arguments beside them. Each runs with that directory alone
;;; as PATH, through env -i, so nothing of the host's environment reaches
;;; it. The script needs nothing but /bin/sh and its builtins, and the
;;; timeout and head it bounds its probe with: each directory holds links to
;;; the real ones, but for the rows that run without them. A row
;;; asserts the exit status, the whole of stdout and the whole of stderr,
;;; as text written by hand here, with the row's directory written DIR, and
;;; each fake's log. The make rows run this checkout's Makefile from the
;;; repository root, where make test runs every suite, and cut the line
;;; number make 4 writes into its own error line.
;;;
;;; One row runs the real Chez, CHEZ as make test exports it: it holds the
;;; probe's program to what Chez answers. To run the script's rows against
;;; another copy of it, name it after the suite; the Makefile's rows run
;;; the Makefile's own:
;;;
;;;   $CHEZ --libdirs ... --program tests/test-require-chez.sps build/copy
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (only (chezscheme) getenv))

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

(define chez (getenv "CHEZ"))

;; tool-path : String -> (U String #f)
;; Where NAME is on this suite's PATH, by an absolute path, or #f.
(define (tool-path name)
  (guard (e (#t #f))
    (let ((got (capture-command (list "sh" "-c" (string-append "command -v " name)))))
      (and (= (car got) 0)
           (> (string-length (cadr got)) 1)
           (char=? (string-ref (cadr got) 0) #\/)
           (substring (cadr got) 0 (- (string-length (cadr got)) 1))))))

;; The tools the rows' directories link to: GNU timeout, as timeout or as
;; gtimeout, Homebrew's name; head; and sleep, which the fakes that hang
;; run by its path.
(define timeout-name (if (tool-path "timeout") "timeout" "gtimeout"))
(define timeout-path (tool-path timeout-name))
(define head-path (tool-path "head"))
(define sleep-path (tool-path "sleep"))

(define script
  (if (null? (cdr (command-line))) "scripts/require-chez" (cadr (command-line))))

;; --- text ------------------------------------------------------------------------------

;; split-lines : String -> (Listof String)
;; TEXT's lines, each without its line feed; a last line with none is kept.
(define (split-lines text)
  (let loop ((i 0) (start 0) (found '()))
    (cond ((= i (string-length text))
           (reverse (if (< start i) (cons (substring text start i) found) found)))
          ((char=? (string-ref text i) #\newline)
           (loop (+ i 1) (+ i 1) (cons (substring text start i) found)))
          (else (loop (+ i 1) start found)))))

;; replaced : String String String -> String
;; TEXT with each OLD, which is not empty, written NEW.
(define (replaced text old new)
  (let ((n (string-length text)) (m (string-length old)))
    (let loop ((i 0) (start 0) (out ""))
      (cond ((> (+ i m) n) (string-append out (substring text start n)))
            ((string=? (substring text i (+ i m)) old)
             (loop (+ i m) (+ i m) (string-append out (substring text start i) new)))
            (else (loop (+ i 1) start out))))))

;; in-dir : String (List Integer String String) -> (List Integer String String)
;; GOT, an answer, with DIR, the row's directory, written DIR in its
;; streams, and "Makefile:N: " cut from each line make begins with
;; "make: *** [", as make 3.81 writes it.
(define (in-dir dir got)
  (list (car got)
        (replaced (cadr got) dir "DIR")
        (without-make-line (replaced (caddr got) dir "DIR"))))

(define (without-make-line text)
  (let ((head "make: *** [Makefile:"))
    (apply string-append
           (map (lambda (line)
                  (string-append
                   (if (and (>= (string-length line) (string-length head))
                            (string=? (substring line 0 (string-length head)) head))
                       (let cut ((i (string-length head)))
                         (cond ((>= (+ i 1) (string-length line)) line)
                               ((char=? (string-ref line i) #\:)
                                (string-append "make: *** [" (substring line (+ i 2) (string-length line))))
                               (else (cut (+ i 1)))))
                       line)
                   "\n"))
                (split-lines text)))))

;; --- fakes -----------------------------------------------------------------------------

;; write-file : String String -> Unspecified
(define (write-file path text)
  (call-with-port (open-file-output-port path (file-options no-fail) (buffer-mode block)
                                         (make-transcoder (utf-8-codec)))
    (lambda (p) (put-string p text))))

;; read-file : String -> String
;; The file at PATH, or "" when there is none.
(define (read-file path)
  (if (file-exists? path)
      (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                            (make-transcoder (utf-8-codec)))
        (lambda (p) (let ((text (get-string-all p))) (if (eof-object? text) "" text))))
      ""))

;; script! : String String String -> Unspecified
;; In DIR, an executable NAME: a shell script that, each time it runs, adds
;; a line of its arguments to DIR/NAME.log, then runs BODY.
(define (script! dir name body)
  (let ((path (string-append dir "/" name)))
    (write-file path (string-append "#!/bin/sh\n" "printf '%s\\n' \"$*\" >>'" path ".log'\n" body))
    (capture-command (list "chmod" "+x" path))))

;; fake! : String String String String Integer -> Unspecified
;; In DIR, an executable NAME that, each time it runs, logs its arguments,
;; writes OUT to stdout, then ERR to stderr, and exits CODE. OUT and ERR
;; hold no ', and a backslash in them is written as it is.
(define (fake! dir name out err code)
  (script! dir name (string-append "printf '%s' '" out "'\n"
                                   "printf '%s' '" err "' >&2\n"
                                   "exit " (number->string code) "\n")))

;; chez! : String String String String -> Unspecified
;; A fake Chez named NAME in DIR, which answers the probe as a Chez of
;; VERSION and BUILD, threaded or nothreads, does.
(define (chez! dir name version build)
  (fake! dir name (string-append "chez-scheme " version " " build "\n") "" 0))

;; other! : String String -> Unspecified
;; A fake of another Scheme named NAME in DIR, which answers the probe with
;; its banner and an error, and exits 14, as MIT/GNU Scheme might.
(define (other! dir name)
  (fake! dir name "MIT/GNU Scheme running under GNU/Linux\n;Unbound variable: threaded?\n" "" 14))

;; log-of : String String -> String
;; The arguments of each run of the fake NAME in DIR, a line each.
(define (log-of dir name) (read-file (string-append dir "/" name ".log")))

;; The probe's arguments: its program comes on stdin, to Chez's REPL.
(define probe "-q\n")

;; --- running it ------------------------------------------------------------------------

;; require-chez : String (Listof String) (Listof String) -> (List Integer String String)
;; The script with ARGS, its environment PATH=DIR and VARS alone, its
;; answer with DIR written DIR.
(define (require-chez dir vars args)
  (in-dir dir (capture-command (append (list "env" "-i" (string-append "PATH=" dir)) vars
                                       (list script) args))))

(define floor-needs "circuit needs Chez Scheme 10.4.1 or later, threaded")
(define floor-install "Chez Scheme 10.4.1 or later, threaded")
(define site-needs "the docs site needs Chez Scheme, threaded")
(define site-install "Chez Scheme, threaded")

;; refusal : String String String [String String] -> String
;; The script's two lines refusing CHEZ for GOAL, saying WHAT it is, then
;; the hint to install, for the floor unless NEEDS and INSTALL say otherwise.
(define refusal
  (case-lambda
    ((goal chez what) (refusal goal chez what floor-needs floor-install))
    ((goal chez what needs install)
     (string-append "make " goal ": CHEZ=" chez " " what "; " needs ".\n"
                    "Install " install ", or name one with CHEZ=/path/to/scheme, then run make "
                    goal " again.\n"))))

(define (is-chez version build) (string-append "is Chez Scheme " version ", " build))

(define (not-chez code answering)
  (not-chez-as (string-append "it exited " (number->string code)) answering))

;; not-chez-as : String String -> String
;; What a refusal says of a CHEZ that is no Chez: HOW its run went, and what
;; it answered.
(define (not-chez-as how answering)
  (string-append "is not Chez Scheme: asked for its version, " how ", answering " answering))

(define passes (list 0 "" ""))

;; with-dir : (String -> Any) -> Any
;; PROC on a fresh directory that holds links to the real timeout and head.
(define (with-dir proc)
  (call-with-temp-directory
   (lambda (dir)
     (for-each (lambda (name path)
                 (when path (capture-command (list "ln" "-s" path (string-append dir "/" name)))))
               (list timeout-name "head")
               (list timeout-path head-path))
     (proc dir))))

;; with-bare-dir : (String -> Any) -> Any
;; PROC on a fresh, empty directory: no timeout, no head.
(define with-bare-dir call-with-temp-directory)

;; A version as a fake prints it, and whether it is 10.4.1 or later.
(define two-to-the-hundred "1267650600228229401496703205376")

(define versions
  (list (cons "10.4.1" #t) (cons "10.4.2" #t) (cons "10.4.10" #t) (cons "10.5.0" #t)
        (cons "10.10.0" #t) (cons "11.0.0" #t) (cons "100.0.0" #t) (cons "10.4.01" #t)
        (cons "010.004.001" #t)
        (cons (string-append two-to-the-hundred ".0.0") #t)
        (cons (string-append "10." two-to-the-hundred ".0") #t)
        (cons (string-append "10.4." two-to-the-hundred) #t)
        (cons "10.4.0" #f) (cons "10.4.00" #f) (cons "10.3.99" #f)
        (cons (string-append "10.3." two-to-the-hundred) #f)
        (cons "10.0.9" #f) (cons "9.99.99" #f)
        (cons (string-append "9." two-to-the-hundred ".0") #f)
        (cons "2.0.0" #f) (cons "1.100.100" #f) (cons "0.0.0" #f)))

(test-begin "require-chez")

(test-equal "CHEZ names the Chez make test runs"
  'set
  (if (and chez (not (string=? chez ""))) 'set 'unset))

(unless (and chez (not (string=? chez "")))
  (exit 1))

;; --- the floor ---------------------------------------------------------------------------

(for-each
 (lambda (v)
   (test-equal (string-append "a threaded Chez " (car v) (if (cdr v) " passes" " is refused, by name"))
     (list (if (cdr v) passes (list 2 "" (refusal "test" "DIR/chez" (is-chez (car v) "threaded"))))
           probe)
     (with-dir
      (lambda (dir)
        (chez! dir "chez" (car v) "threaded")
        (list (require-chez dir '() (list "test" (string-append dir "/chez")))
              (log-of dir "chez"))))))
 versions)

(for-each
 (lambda (version)
   (test-equal (string-append "a Chez " version " without threads is refused, by name")
     (list (list 2 "" (refusal "test" "DIR/chez" (is-chez version "not threaded"))) probe)
     (with-dir
      (lambda (dir)
        (chez! dir "chez" version "nothreads")
        (list (require-chez dir '() (list "test" (string-append dir "/chez")))
              (log-of dir "chez"))))))
 '("10.4.1" "11.0.0" "9.5.9"))

(test-equal "the goal it names is the one it is given"
  (list 2 "" (refusal "gate" "DIR/chez" (is-chez "10.4.0" "threaded")))
  (with-dir
   (lambda (dir)
     (chez! dir "chez" "10.4.0" "threaded")
     (require-chez dir '() (list "gate" (string-append dir "/chez"))))))

;; --- not Chez -----------------------------------------------------------------------------

;; Each: what the row is, what the fake writes to stdout and to stderr, its
;; exit, and what the refusal says it answered.
(define not-chez-rows
  (list (list "another Scheme: its first line, and more"
              "MIT/GNU Scheme running under GNU/Linux\n;Unbound variable: threaded?\n" "" 14
              "'MIT/GNU Scheme running under GNU/Linux' and more")
        (list "an error on stderr alone" "" "Unbound variable: scheme-version-number\n" 1
              "'Unbound variable: scheme-version-number'")
        (list "nothing at all" "" "" 0 "nothing")
        (list "Chez's line, but a failing exit" "chez-scheme 10.4.1 threaded\n" "" 1
              "'chez-scheme 10.4.1 threaded'")
        (list "Chez's line, then another" "chez-scheme 10.4.1 threaded\nwarning\n" "" 0
              "'chez-scheme 10.4.1 threaded' and more")
        (list "Chez's line, after another" "hello\nchez-scheme 10.4.1 threaded\n" "" 0
              "'hello' and more")
        (list "Chez's line, and a warning on stderr" "chez-scheme 10.4.1 threaded\n" "warning\n" 0
              "'chez-scheme 10.4.1 threaded' and more")
        (list "two components" "chez-scheme 10.4 threaded\n" "" 0 "'chez-scheme 10.4 threaded'")
        (list "four components" "chez-scheme 10.4.1.0 threaded\n" "" 0 "'chez-scheme 10.4.1.0 threaded'")
        (list "an empty component" "chez-scheme 10..1 threaded\n" "" 0 "'chez-scheme 10..1 threaded'")
        (list "a letter in a component" "chez-scheme 10.x.1 threaded\n" "" 0 "'chez-scheme 10.x.1 threaded'")
        (list "a sign" "chez-scheme 10.+4.1 threaded\n" "" 0 "'chez-scheme 10.+4.1 threaded'")
        (list "two spaces" "chez-scheme  10.4.1 threaded\n" "" 0 "'chez-scheme  10.4.1 threaded'")
        (list "a space at the end" "chez-scheme 10.4.1 threaded \n" "" 0 "'chez-scheme 10.4.1 threaded '")
        (list "another word for the build" "chez-scheme 10.4.1 Threaded\n" "" 0
              "'chez-scheme 10.4.1 Threaded'")
        (list "no version" "chez-scheme threaded\n" "" 0 "'chez-scheme threaded'")))

(for-each
 (lambda (row)
   (test-equal (string-append "not Chez, refused, naming its exit and what it answered: " (car row))
     (list 2 "" (refusal "test" "DIR/chez" (not-chez (list-ref row 3) (list-ref row 4))))
     (with-dir
      (lambda (dir)
        (fake! dir "chez" (list-ref row 1) (list-ref row 2) (list-ref row 3))
        (require-chez dir '() (list "test" (string-append dir "/chez")))))))
 not-chez-rows)

(test-equal "a CHEZ not on PATH, and an empty one, are refused, by name"
  (list (list 2 "" (refusal "test" "no-such-chez" "not found"))
        (list 2 "" (refusal "test" "" "not found")))
  (with-dir
   (lambda (dir)
     (list (require-chez dir '() '("test" "no-such-chez"))
           (require-chez dir '() '("test" ""))))))

;; --- backslashes ---------------------------------------------------------------------------

;; The container's /bin/sh is bash, whose echo writes a backslash as it is.
;; Debian's and Ubuntu's, CI's among them, is dash, whose echo reads \c as
;; the end of its output and \n as a line feed: there, a refusal written by
;; echo ends at the first \c, and this row fails against one.
(test-equal "a backslash in CHEZ's answer, in its name, or in the goal, is written as it is"
  (list (list 2 "" (refusal "test" "DIR/ch\\cez" (not-chez 0 "'chez-scheme 1\\c0.4.1 thr\\neaded'")))
        (list 2 "" (refusal "te\\cst" "DIR/ol\\cd" (is-chez "10.4.0" "threaded")))
        (list 2 "" (refusal "test" "no\\csuch" "not found")))
  (with-dir
   (lambda (dir)
     (fake! dir "ch\\cez" "chez-scheme 1\\c0.4.1 thr\\neaded\n" "" 0)
     (chez! dir "ol\\cd" "10.4.0" "threaded")
     (list (require-chez dir '() (list "test" (string-append dir "/ch\\cez")))
           (require-chez dir '() (list "te\\cst" (string-append dir "/ol\\cd")))
           (require-chez dir '() (list "test" "no\\csuch"))))))

;; --- the probe's bounds ----------------------------------------------------------------------

;; The rows that wait run with REQUIRE_CHEZ_SECONDS at 2. A fake that hangs
;; sleeps 30 s, by sleep's path, which PATH doesn't hold: a probe with no
;; time limit fails such a row late, rather than hanging the suite.
(define two-seconds '("REQUIRE_CHEZ_SECONDS=2"))

(test-equal "sleep is on PATH, by an absolute path, for the fakes that hang"
  #t
  (string? sleep-path))

(test-equal "a CHEZ that does not end is stopped after REQUIRE_CHEZ_SECONDS, and refused, with what it had answered"
  (list (list 2 "" (refusal "test" "DIR/chez" (not-chez-as "it had not ended after 2 s" "nothing")))
        (list 2 "" (refusal "test" "DIR/late"
                            (not-chez-as "it had not ended after 2 s" "'chez-scheme 10.4.1 threaded'"))))
  (with-dir
   (lambda (dir)
     (script! dir "chez" (string-append (or sleep-path "sleep") " 30\n"))
     (script! dir "late" (string-append "printf 'chez-scheme 10.4.1 threaded\\n'\n"
                                        (or sleep-path "sleep") " 30\n"))
     (list (require-chez dir two-seconds (list "test" (string-append dir "/chez")))
           (require-chez dir two-seconds (list "test" (string-append dir "/late")))))))

(test-equal "gtimeout, Homebrew's name for GNU timeout, stops it too"
  (list 2 "" (refusal "test" "DIR/chez" (not-chez-as "it had not ended after 2 s" "nothing")))
  (call-with-temp-directory
   (lambda (dir)
     (capture-command (list "ln" "-s" (or timeout-path "timeout") (string-append dir "/gtimeout")))
     (capture-command (list "ln" "-s" (or head-path "head") (string-append dir "/head")))
     (script! dir "chez" (string-append (or sleep-path "sleep") " 30\n"))
     (require-chez dir two-seconds (list "test" (string-append dir "/chez"))))))

;; CHEZ's child writes a line 3 s on, holding the answer's pipe till then:
;; a probe that waited for it would read that line, and refuse.
(test-equal "a CHEZ that leaves a child holding its output is answered once it ends: the child ends with it"
  passes
  (with-dir
   (lambda (dir)
     (script! dir "chez" (string-append "(" (or sleep-path "sleep") " 3; printf 'late\\n') &\n"
                                        "printf 'chez-scheme 10.4.1 threaded\\n'\nexit 0\n"))
     (require-chez dir two-seconds (list "test" (string-append dir "/chez"))))))

(test-equal "a CHEZ that answers without end is cut at 4096 bytes, and refused"
  (list 2 "" (refusal "test" "DIR/chez"
                      (not-chez-as "it ran past 4096 bytes" "'chez-scheme 10.4.1 threaded' and more")))
  (with-dir
   (lambda (dir)
     (script! dir "chez" "while :; do printf 'chez-scheme 10.4.1 threaded\\n'; done\n")
     (require-chez dir two-seconds (list "test" (string-append dir "/chez"))))))

;; The 4096 bytes are the answer and the line after it, a line feed and
;; probe-exit 0: 13 bytes, its last line feed aside. So an answer of 4083
;; bytes is read whole, and one of 4084 is cut.
(test-equal "the cap from both sides: an answer of 4083 bytes is read whole, one of 4084 is cut"
  (list (list 2 "" (refusal "test" "DIR/at" (not-chez 0 (string-append "'" (make-string 4082 #\x) "'"))))
        (list 2 "" (refusal "test" "DIR/past"
                            (not-chez-as "it ran past 4096 bytes"
                                         (string-append "'" (make-string 4083 #\x) "' and more")))))
  (with-dir
   (lambda (dir)
     (fake! dir "at" (string-append (make-string 4082 #\x) "\n") "" 0)
     (fake! dir "past" (string-append (make-string 4083 #\x) "\n") "" 0)
     (list (require-chez dir '() (list "test" (string-append dir "/at")))
           (require-chez dir '() (list "test" (string-append dir "/past")))))))

(test-equal "REQUIRE_CHEZ_SECONDS is a whole number of seconds, 1 or more; empty or unset, it is 10"
  (let ((bad (lambda (v)
               (list 2 "" (string-append "require-chez: REQUIRE_CHEZ_SECONDS is '" v
                                         "', not a whole number of seconds, 1 or more\n")))))
    (list (bad "x") (bad "0") (bad "00") (bad "1.5") (bad "-1") (bad " 2") (bad "2\\c3") passes passes passes))
  (with-dir
   (lambda (dir)
     (chez! dir "chez" "10.4.1" "threaded")
     (append (map (lambda (v)
                    (require-chez dir (list (string-append "REQUIRE_CHEZ_SECONDS=" v))
                                  (list "test" (string-append dir "/chez"))))
                  '("x" "0" "00" "1.5" "-1" " 2" "2\\c3" "1" ""))
             (list (require-chez dir '() (list "test" (string-append dir "/chez"))))))))

;; With no timeout on PATH, nothing ends a child CHEZ leaves holding its
;; output: the probe waits for it, and names what it wrote after CHEZ's exit.
(test-equal "with no timeout on PATH, a child CHEZ left behind holds the probe till it ends, and what it writes after is named"
  (list 2 "" (refusal "test" "DIR/chez"
                      (not-chez-as "it exited 0, and something it left running wrote on after it"
                                   "'chez-scheme 10.4.1 threaded' and more")))
  (with-bare-dir
   (lambda (dir)
     (capture-command (list "ln" "-s" (or head-path "head") (string-append dir "/head")))
     (script! dir "chez" (string-append "(" (or sleep-path "sleep") " 3; printf 'late\\n') &\n"
                                        "printf 'chez-scheme 10.4.1 threaded\\n'\nexit 0\n"))
     (require-chez dir '() (list "test" (string-append dir "/chez"))))))

(test-equal "with neither timeout nor head on PATH, or with only one, the probe still asks, and answers"
  (let ((answers (list passes (list 2 "" (refusal "test" "DIR/old" (is-chez "10.4.0" "threaded")))
                       (list 0 "chez\n" ""))))
    (list answers answers answers))
  (map (lambda (tools)
         (with-bare-dir
          (lambda (dir)
            (for-each (lambda (tool)
                        (capture-command (list "ln" "-s" (cdr tool) (string-append dir "/" (car tool)))))
                      tools)
            (chez! dir "chez" "10.4.1" "threaded")
            (chez! dir "old" "10.4.0" "threaded")
            (list (require-chez dir '() (list "test" (string-append dir "/chez")))
                  (require-chez dir '() (list "test" (string-append dir "/old")))
                  (require-chez dir '() '("--find" "scheme" "chez"))))))
       (list '()
             (list (cons timeout-name (or timeout-path "timeout")))
             (list (cons "head" (or head-path "head"))))))

;; --- the hint ------------------------------------------------------------------------------

(test-equal "on a Guix host, outside its container, the hint is the container; inside one, it is to install"
  (list (list 2 ""
              (string-append "make test: CHEZ=DIR/chez " (is-chez "10.4.0" "threaded") "; " floor-needs ".\n"
                             "On this Guix host, run it in the project's container: scripts/guix-env make test\n"))
        (list 2 "" (refusal "test" "DIR/chez" (is-chez "10.4.0" "threaded"))))
  (with-dir
   (lambda (dir)
     (chez! dir "chez" "10.4.0" "threaded")
     (fake! dir "guix" "" "" 0)
     (list (require-chez dir '() (list "test" (string-append dir "/chez")))
           (require-chez dir '("GUIX_ENVIRONMENT=/gnu/store/fake-profile")
                         (list "test" (string-append dir "/chez")))))))

;; --- --any-version, for the docs site ------------------------------------------------------

(test-equal "--any-version passes a threaded Chez of any version"
  (list passes passes passes)
  (map (lambda (version)
         (with-dir
          (lambda (dir)
            (chez! dir "chez" version "threaded")
            (require-chez dir '() (list "--any-version" "site" (string-append dir "/chez"))))))
       '("9.5.9" "10.4.0" "10.4.1")))

(test-equal "--any-version refuses a Chez without threads, another Scheme, and a CHEZ not on PATH, for what the site needs"
  (list (list 2 "" (refusal "site" "DIR/old" (is-chez "9.5.9" "not threaded") site-needs site-install))
        (list 2 "" (refusal "check-site" "DIR/new" (is-chez "10.4.1" "not threaded") site-needs site-install))
        (list 2 "" (refusal "site" "DIR/chez"
                            (not-chez 14 "'MIT/GNU Scheme running under GNU/Linux' and more")
                            site-needs site-install))
        (list 2 "" (refusal "check-site" "no-such-chez" "not found" site-needs site-install)))
  (with-dir
   (lambda (dir)
     (chez! dir "old" "9.5.9" "nothreads")
     (chez! dir "new" "10.4.1" "nothreads")
     (other! dir "chez")
     (list (require-chez dir '() (list "--any-version" "site" (string-append dir "/old")))
           (require-chez dir '() (list "--any-version" "check-site" (string-append dir "/new")))
           (require-chez dir '() (list "--any-version" "site" (string-append dir "/chez")))
           (require-chez dir '() (list "--any-version" "check-site" "no-such-chez"))))))

;; --- usage ---------------------------------------------------------------------------------

(test-equal "a call of the wrong shape is a usage error"
  (let ((usage (list 2 "" "usage: require-chez [--any-version] GOAL CHEZ | require-chez --find NAME...\n")))
    (list usage usage usage usage usage usage))
  (with-dir
   (lambda (dir)
     (map (lambda (args) (require-chez dir '() args))
          '(() ("test") ("test" "a" "b") ("--any-version" "site") ("--any" "site" "chez") ("--find"))))))

;; --- --find, the Makefile's default --------------------------------------------------------

;; find-in : (String -> Any) (Listof String) -> (List (List Integer String String) String String)
;; --find NAMES with PATH a fresh directory SETUP fills with fakes: its
;; answer, then what a scheme and a chez there logged.
(define (find-in setup names)
  (with-dir
   (lambda (dir)
     (setup dir)
     (list (require-chez dir '() (cons "--find" names)) (log-of dir "scheme") (log-of dir "chez")))))

(test-equal "--find: another Scheme owns scheme, so it is chez, the first that is Chez"
  (list (list 0 "chez\n" "") probe probe)
  (find-in (lambda (dir) (other! dir "scheme") (chez! dir "chez" "10.4.1" "threaded")) '("scheme" "chez")))

(test-equal "--find: both are Chez, so it is scheme, and chez never runs"
  (list (list 0 "scheme\n" "") probe "")
  (find-in (lambda (dir) (chez! dir "scheme" "10.4.1" "threaded") (chez! dir "chez" "10.4.1" "threaded"))
           '("scheme" "chez")))

(test-equal "--find prefers a Chez that meets the floor: a scheme below it, threaded or not, gives way to chez"
  (list (list (list 0 "chez\n" "") probe probe) (list (list 0 "chez\n" "") probe probe))
  (list (find-in (lambda (dir) (chez! dir "scheme" "10.4.0" "threaded") (chez! dir "chez" "10.4.1" "threaded"))
                 '("scheme" "chez"))
        (find-in (lambda (dir) (chez! dir "scheme" "10.4.1" "nothreads") (chez! dir "chez" "10.4.1" "threaded"))
                 '("scheme" "chez"))))

(test-equal "--find: neither meets the floor, so it is the first that is Chez, which the check then refuses"
  (list (list (list 0 "scheme\n" "") probe probe) (list (list 0 "chez\n" "") probe probe)
        (list (list 0 "scheme\n" "") probe probe))
  (list (find-in (lambda (dir) (chez! dir "scheme" "10.4.0" "threaded") (chez! dir "chez" "9.5.9" "threaded"))
                 '("scheme" "chez"))
        (find-in (lambda (dir) (other! dir "scheme") (chez! dir "chez" "10.4.0" "threaded"))
                 '("scheme" "chez"))
        (find-in (lambda (dir) (chez! dir "scheme" "10.4.0" "nothreads") (other! dir "chez"))
                 '("scheme" "chez"))))

(test-equal "--find takes the names in the order given"
  (list (list 0 "chez\n" "") "" probe)
  (find-in (lambda (dir) (chez! dir "scheme" "10.4.1" "threaded") (chez! dir "chez" "10.4.1" "threaded"))
           '("chez" "scheme")))

(test-equal "--find: neither is Chez, so it is the first on PATH, scheme, which the check then refuses"
  (list (list 0 "scheme\n" "") probe probe)
  (find-in (lambda (dir) (other! dir "scheme") (other! dir "chez")) '("scheme" "chez")))

(test-equal "--find: only chez is on PATH, and it is no Chez: chez, the first on PATH"
  (list (list 0 "chez\n" "") "" probe)
  (find-in (lambda (dir) (other! dir "chez")) '("scheme" "chez")))

(test-equal "--find: neither is on PATH: scheme, the first name"
  (list (list 0 "scheme\n" "") "" "")
  (find-in (lambda (dir) #f) '("scheme" "chez")))

;; --- the real Chez ---------------------------------------------------------------------------

(test-equal "the Chez make test runs passes, as itself and for the site: it answers the probe's program"
  (list passes passes)
  (list (capture-command (list script "test" chez))
        (capture-command (list script "--any-version" "site" chez))))

;; --- the Makefile ------------------------------------------------------------------------------

;; make-path : (U String #f)
;; The make that runs the rows below, by its path: their PATH holds only fakes.
(define make-path (tool-path "make"))

(test-equal "make is on PATH, by an absolute path, for the Makefile's rows"
  #t
  (string? make-path))

;; run-make : String (Listof String) (Listof String) -> (List Integer String String)
;; This checkout's make with ARGS, its environment PATH=DIR and VARS
;; alone, its answer with DIR written DIR.
(define (run-make dir vars args)
  (in-dir dir (capture-command (append (list "env" "-i" (string-append "PATH=" dir)) vars
                                       (list (or make-path "make") "--no-print-directory")
                                       args))))

;; print-chez : String (Listof String) (Listof String) -> (List Integer String String)
;; The CHEZ the Makefile settles on, with PATH=DIR and VARS, and ARGS on
;; make's command line, printed by a target of a makefile of the row's own,
;; read after the Makefile. The quotes make make run the recipe through the
;; shell, whose echo is built in: PATH has no echo.
(define (print-chez dir vars args)
  (let ((extra (string-append dir "/print.mk")))
    (write-file extra "print-chez: ; @echo \"$(CHEZ)\"\n")
    (run-make dir vars (append (list "-s" "-f" "Makefile" "-f" extra "print-chez") args))))

(test-equal "the Makefile's CHEZ: another Scheme owns scheme, so it is chez"
  (list (list 0 "chez\n" "") probe probe)
  (with-dir
   (lambda (dir)
     (other! dir "scheme")
     (chez! dir "chez" "10.4.1" "threaded")
     (list (print-chez dir '() '()) (log-of dir "scheme") (log-of dir "chez")))))

(test-equal "the Makefile's CHEZ: both are Chez, so it is scheme"
  (list (list 0 "scheme\n" "") probe "")
  (with-dir
   (lambda (dir)
     (chez! dir "scheme" "10.4.1" "threaded")
     (chez! dir "chez" "10.4.1" "threaded")
     (list (print-chez dir '() '()) (log-of dir "scheme") (log-of dir "chez")))))

(test-equal "the Makefile's CHEZ: scheme is a Chez below the floor, so it is chez"
  (list (list 0 "chez\n" "") probe probe)
  (with-dir
   (lambda (dir)
     (chez! dir "scheme" "10.4.0" "threaded")
     (chez! dir "chez" "10.4.1" "threaded")
     (list (print-chez dir '() '()) (log-of dir "scheme") (log-of dir "chez")))))

(test-equal "the Makefile's CHEZ: neither is on PATH, so it is scheme"
  (list 0 "scheme\n" "")
  (with-dir (lambda (dir) (print-chez dir '() '()))))

(test-equal "the Makefile's CHEZ, given on the command line or in the environment, stays as given, and nothing is asked"
  (list (list 0 "/opt/my chez/bin/scheme\n" "") (list 0 "/opt/other/scheme\n" "") "" "")
  (with-dir
   (lambda (dir)
     (other! dir "scheme")
     (chez! dir "chez" "10.4.1" "threaded")
     (list (print-chez dir '() '("CHEZ=/opt/my chez/bin/scheme"))
           (print-chez dir '("CHEZ=/opt/other/scheme") '())
           (log-of dir "scheme")
           (log-of dir "chez")))))

;; Every target that runs Chez on circuit's libraries refuses a Chez below
;; the floor before it runs it: the fake's log holds the probe's run alone.
(for-each
 (lambda (target)
   (test-equal (string-append "make " target " refuses a Chez below the floor before it runs it")
     (list (list 2 "" (string-append (refusal target "DIR/old" (is-chez "10.4.0" "threaded"))
                                     "make: *** [check-chez] Error 2\n"))
           probe)
     (with-dir
      (lambda (dir)
        (chez! dir "old" "10.4.0" "threaded")
        (list (run-make dir '() (list target (string-append "CHEZ=" dir "/old")))
              (log-of dir "old"))))))
 '("test" "run" "dev" "gate" "gate-rps" "check-suites" "check-imports" "deps" "check-chez"))

;; require-chez's own refusal reaches make's user: no require-tools asks
;; first, whose words for a CHEZ not on PATH, or its usage line for an
;; empty one, would stand in its place.
(test-equal "make check-chez refuses a CHEZ not on PATH, and an empty one, in require-chez's words"
  (list (list 2 "" (string-append (refusal "check-chez" "no-such-chez" "not found")
                                  "make: *** [check-chez] Error 2\n"))
        (list 2 "" (string-append (refusal "check-chez" "" "not found")
                                  "make: *** [check-chez] Error 2\n")))
  (with-dir
   (lambda (dir)
     (list (run-make dir '() '("check-chez" "CHEZ=no-such-chez"))
           (run-make dir '() '("check-chez" "CHEZ="))))))

;; The site's targets, with site-deps and srfi taken as made, by -o, so
;; that nothing fetches or links.
(test-equal "make site and make check-site refuse a CHEZ not on PATH, and an empty one, in require-chez's words"
  (list (list 2 "" (string-append (refusal "site" "no-such-chez" "not found" site-needs site-install)
                                  "make: *** [site] Error 2\n"))
        (list 2 "" (string-append (refusal "check-site" "" "not found" site-needs site-install)
                                  "make: *** [check-site] Error 2\n")))
  (with-dir
   (lambda (dir)
     (list (run-make dir '() '("-o" "site-deps" "site" "CHEZ=no-such-chez"))
           (run-make dir '() '("-o" "site-deps" "-o" "srfi" "check-site" "CHEZ="))))))

(test-equal "make site and make check-site refuse another Scheme, and a Chez without threads, before they run it"
  (list (list 2 "" (string-append (refusal "site" "DIR/other"
                                           (not-chez 14 "'MIT/GNU Scheme running under GNU/Linux' and more")
                                           site-needs site-install)
                                  "make: *** [site] Error 2\n"))
        (list 2 "" (string-append (refusal "check-site" "DIR/other"
                                           (not-chez 14 "'MIT/GNU Scheme running under GNU/Linux' and more")
                                           site-needs site-install)
                                  "make: *** [check-site] Error 2\n"))
        (list 2 "" (string-append (refusal "site" "DIR/old" (is-chez "9.5.9" "not threaded")
                                           site-needs site-install)
                                  "make: *** [site] Error 2\n"))
        (list 2 "" (string-append (refusal "check-site" "DIR/old" (is-chez "9.5.9" "not threaded")
                                           site-needs site-install)
                                  "make: *** [check-site] Error 2\n"))
        (string-append probe probe) (string-append probe probe))
  (with-dir
   (lambda (dir)
     (other! dir "other")
     (chez! dir "old" "9.5.9" "nothreads")
     (let* ((site (run-make dir '() (list "-o" "site-deps" "site" (string-append "CHEZ=" dir "/other"))))
            (check (run-make dir '() (list "-o" "site-deps" "-o" "srfi" "check-site"
                                           (string-append "CHEZ=" dir "/other"))))
            (site-old (run-make dir '() (list "-o" "site-deps" "site" (string-append "CHEZ=" dir "/old"))))
            (check-old (run-make dir '() (list "-o" "site-deps" "-o" "srfi" "check-site"
                                               (string-append "CHEZ=" dir "/old")))))
       (list site check site-old check-old (log-of dir "other") (log-of dir "old"))))))

;; A fake mkdir and cp stand in for the real ones, which PATH doesn't hold,
;; and do nothing, so the site's recipe runs to its end and writes nothing.
(test-equal "make site and make check-site run a threaded Chez below the floor: the site loads neither the server nor libuv"
  (list (list 0 "chez-scheme 9.5.9 threaded\nsite: build/site ready (open build/site/index.html)\n" "")
        (list 0 "chez-scheme 9.5.9 threaded\nchez-scheme 9.5.9 threaded\nchez-scheme 9.5.9 threaded\n" "")
        (list "-q" "--program build-site.sps"
              "-q" "--program tests/site-unit.sps" "--program tests/site-render-unit.sps"
              "--program tests/site-check.sps"))
  (with-dir
   (lambda (dir)
     (chez! dir "old" "9.5.9" "threaded")
     (fake! dir "mkdir" "" "" 0)
     (fake! dir "cp" "" "" 0)
     (let* ((site (run-make dir '() (list "-o" "site-deps" "site" (string-append "CHEZ=" dir "/old"))))
            (check (run-make dir '() (list "-o" "site-deps" "-o" "srfi" "check-site"
                                           (string-append "CHEZ=" dir "/old")))))
       ;; Each logged run as its probe's arguments, or its --program and
       ;; what follows: the library path before it is the site's to choose.
       (list site check
             (map (lambda (line)
                    (let loop ((i 0))
                      (cond ((> (+ i 9) (string-length line)) line)
                            ((string=? (substring line i (+ i 9)) "--program")
                             (substring line i (string-length line)))
                            (else (loop (+ i 1))))))
                  (split-lines (log-of dir "old"))))))))

(test-end "require-chez")

(exit (suite-exit-status runner))
