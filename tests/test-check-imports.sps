#!r6rs
;;; The suite for tests/check-imports.sps, the program behind
;;; `make check-imports`. Every rule it holds has a fixture tree under
;;; tests/fixtures/imports/<case>/, and this suite runs the program on each,
;;; in a fresh Chez, through capture-command. A case asserts the exit status,
;;; the whole of stdout and the whole of stderr, as text written by hand
;;; here, never read back from the program: a substring would pass whenever
;;; another rule produced the same words. Without this suite, deleting a rule
;;; would leave `make test` green: the real tree under src/ breaks none of
;;; them.
;;;
;;; Each case's tree is the one fault it names, in an otherwise legal
;;; setting, so that only that rule can make it fail. The cases that must
;;; pass say so with the program's own pass lines, counts included. A case
;;; whose (circuit session) imports (hashing sha-2), so that rule (l) reads
;;; its closure, holds its tree in src/ beside the AKKUs it is run with, each
;;; holding stand-ins for hashing's files, written for it. So does a case
;;; whose (circuit json) imports (jsonparse easy), so that rule (o) reads its
;;; closure, beside the JSONPARSEs and BYTE-MACHINEs it is run with, each
;;; holding stand-ins for jsonparse's or byte-machine's files, written for
;;; it, never copied from vendor/. The fixture trees are never suites: make
;;; test runs tests/test-*.sps only, which check-suites reads.
;;;
;;; make test runs every suite from the repository root, where tests/ is, with
;;; CHEZ exported. Without CHEZ nothing below can run: that fails here, by
;;; name, and never skips. The program runs with this suite's own library
;;; path, which make test sets to TEST_LIBDIRS. To run the suite against
;;; another copy of the program, name it after the suite:
;;;
;;;   $CHEZ --libdirs ... --program tests/test-check-imports.sps build/copy.sps
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (only (chezscheme) getenv iota library-directories library-list library-exports
              file-directory? directory-list))

;; SRFI-64 sets no exit status. This suite's last line turns the runner's
;; counts into one.
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

(define program
  (if (null? (cdr (command-line))) "tests/check-imports.sps" (cadr (command-line))))

(define fixtures "tests/fixtures/imports")

;; libdirs : String
;; The library path this suite was started with, as --libdirs takes it.
(define libdirs
  (let ((dirs (map (lambda (d) (if (pair? d) (car d) d)) (library-directories))))
    (if (null? dirs)
        ""
        (fold-left (lambda (text d) (string-append text ":" d)) (car dirs) (cdr dirs)))))

;; run : (Listof String) -> (List Integer String String)
;; The program in a fresh Chez with ARGS: its exit status, stdout and stderr.
(define (run args)
  (capture-command (append (list chez "--libdirs" libdirs "--program" program) args)))

;; root : String -> String
;; The tree of the fixture CASE, as the program is told it and names it.
(define (root case) (string-append fixtures "/" case))

;; at : String String -> String
;; The path the program names for FILE in the fixture tree CASE.
(define (at case file) (string-append (root case) "/" file))

;; ok : Natural -> (List 0 String "")
;; What a pass prints: how many libraries it checked.
(define (ok libraries)
  (list 0
        (string-append "check-imports: ok, libraries checked: " (number->string libraries) "\n")
        ""))

;; refused : String ... -> (List 1 "" String)
;; What a failure prints: PROBLEMS, one line each, and nothing on stdout.
(define (refused . problems)
  (list 1
        ""
        (apply string-append
               (map (lambda (p) (string-append "check-imports: " p "\n")) problems))))

;; The words the program ends some complaints with.
(define core-tail
  "but a core library may import only the (rnrs ...) libraries except (rnrs eval), and core (circuit ...) libraries")

(define impure-tail
  "but an impure library may import only the (rnrs ...) libraries except (rnrs eval), core (circuit ...) libraries, (chezscheme) through only, and the (http-server ...) libraries except (http-server private ...)")

(define chez-tail
  "but an impure library imports (chezscheme) only through only, right around it, naming getenv, port-has-port-length?, port-length, real-time, display-condition, print-record, parameterize alone: anything wider gives its body import and eval, which reach any library")

(define edge-tail
  "but only an impure library, (circuit http-server) or (circuit middleware waits), may import (chezscheme) or an (http-server ...) library")

(define private-tail
  "but no library may import an (http-server private ...) library")

;; impure-import-tail : String -> String
;; The words a complaint about importing the impure library NAME ends with.
(define (impure-import-tail name)
  (string-append "but no library may import an impure library: " name
                 " is one, and the core stays free of the server"))

;; Rule (i)'s: chez-websocket's facade, the rest of its libraries,
;; (circuit websocket) imported, and what it imports.
(define facade-tail
  "but only (circuit websocket) may import (websocket), chez-websocket's facade")

(define inner-tail
  "but no library may import a (websocket ...) library but the facade, (websocket), which only (circuit websocket) may import")

(define glue-import-tail
  "but no library may import (circuit websocket): it reaches the server through (websocket), and the core stays free of the server")

(define glue-tail
  "but (circuit websocket) may import only the (rnrs ...) libraries except (rnrs eval), core (circuit ...) libraries, and (websocket)")

;; Rule (k)'s: a (hashing ...) library imported elsewhere, another one in
;; (circuit session), (hashing sha-2) through anything but only, and the rest
;; of what (circuit session) imports.
(define hashing-elsewhere-tail
  "but only (circuit session) may import a (hashing ...) library")

(define hashing-other-tail
  "but (circuit session) may import no (hashing ...) library but (hashing sha-2)")

(define hashing-only-tail
  "but (circuit session) imports (hashing sha-2) only through only, right around it, naming at least one identifier: so its header names all it takes from code circuit didn't write")

(define session-tail
  "but (circuit session) may import only the (rnrs ...) libraries except (rnrs eval), core (circuit ...) libraries, and (hashing sha-2) through only")

;; Rule (n)'s, as rule (k)'s: a (jsonparse ...) library imported elsewhere,
;; another one in (circuit json), (jsonparse easy) through anything but
;; only, and the rest of what (circuit json) imports.
(define jsonparse-elsewhere-tail
  "but only (circuit json) may import a (jsonparse ...) library")

(define jsonparse-other-tail
  "but (circuit json) may import no (jsonparse ...) library but (jsonparse easy)")

(define jsonparse-only-tail
  "but (circuit json) imports (jsonparse easy) only through only, right around it, naming at least one identifier: so its header names all it takes from code circuit didn't write")

(define json-tail
  "but (circuit json) may import only the (rnrs ...) libraries except (rnrs eval), core (circuit ...) libraries, and (jsonparse easy) through only")

;; imports : String String String String String -> String
;; The complaint about the library LIB, in FILE of the tree CASE, importing
;; IMPORTED, ended with TAIL.
(define (imports case file lib imported tail)
  (string-append (at case file) ": " lib " imports " imported ", " tail))

;; unreadable-spec : String String String String -> String
(define (unreadable-spec case file lib spec)
  (string-append (at case file) ": " lib " has an import it cannot read: " spec))

;; misplaced : String String String String -> String
;; Rule (a): the library LIB, defined in FILE of the tree CASE, belongs at WANT.
(define (misplaced case file lib want)
  (string-append (at case file) ": " lib " is defined here, but its name's path is "
                 (at case want)))

;; not-circuit : String String String -> String
(define (not-circuit case file lib)
  (string-append (at case file) ": " lib " is not a (circuit ...) library: every library under "
                 (root case) " is named (circuit ...)"))

;; not-sls : String String -> String
(define (not-sls case file)
  (string-append (at case file) ": it is not a .sls file, and only .sls libraries belong under "
                 (root case)))

;; undefined : String String String String -> String
(define (undefined case file lib imported)
  (string-append (at case file) ": " lib " imports " imported ", but no library under "
                 (root case) " defines it"))

;; no-header : String String -> String
;; Rule (h): the file at PATH, under ROOT, does not begin with the line #!r6rs.
(define (no-header path root)
  (string-append path ": its first line is not #!r6rs, which every .sls file under " root
                 " begins with, so that Chez reads it as R6RS and not with its own syntax"))

;; stray-directive : String String -> String
;; Rule (h): the file at PATH holds #! on LINES, past the #!r6rs it begins
;; with, or where it has none.
(define (stray-directive path lines)
  (string-append path ": it holds #! on " lines
                 ", and only the #!r6rs it begins with may: a #! may switch Chez's reader to its own syntax, and this check, which cannot tell a directive from text, refuses one in a comment or a string too"))

;; read-error : String -> String
;; What Chez's reader raises on the file at PATH, read as the program reads
;; it, port and all, and shown as the program shows it, by describe: the
;; running Chez's own words, which another Chez may put otherwise. A file
;; that reads without a raise answers words no complaint holds, so its row
;; fails.
(define (read-error path)
  (guard (e (#t (describe e)))
    (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                          (make-transcoder (utf-8-codec)))
      (lambda (port)
        (let loop ()
          (unless (eof-object? (read port)) (loop)))))
    "<the file was read whole, with no raise>"))

;; cases : (Listof (List String String Expected))
;; The fixture directory, what it holds, and the program's whole answer for it.
(define cases
  (list
   (list "legal"
         "a legal tree: core libraries and both impure ones; every wrapper over an (rnrs ...) import, nested; a version reference; getenv from (chezscheme) through only, and the (http-server ...) libraries but the private ones, in an impure library; a comment and a string that say what a library must not do; every file headed #!r6rs"
         (ok 6))
   (list "impure-chezscheme"
         "rule (d): an impure library takes from (chezscheme) only getenv, port-has-port-length?, port-length, real-time, display-condition, print-record and parameterize, through only right around it: bare, eval, getenv with import, call/1cc, except, prefix, rename, for, library, only around for, and only around a wider only are named; prefix, rename and for around the narrow only, only around (library (chezscheme)), and a version reference are not"
         (apply refused
                (map (lambda (i)
                       (imports "impure-chezscheme" "circuit/http-server.sls" "(circuit http-server)"
                                "(chezscheme)" chez-tail))
                     (iota 11))))
   (list "impure-port-length"
         "rule (d): both impure libraries take port-has-port-length? and port-length from (chezscheme), with getenv and without it, through only right around it, bare and under prefix and rename"
         (ok 2))
   (list "impure-port-length-wider"
         "rule (d): an only beside the allowed names still refuses a name off the list: file-length, set-port-length!, eval and port-has-set-port-length!? are each named"
         (apply refused
                (map (lambda (i)
                       (imports "impure-port-length-wider" "circuit/http-server.sls"
                                "(circuit http-server)" "(chezscheme)" chez-tail))
                     (iota 4))))
   (list "impure-real-time"
         "rule (d): both impure libraries take real-time, display-condition, print-record and parameterize from (chezscheme), with the other allowed names and without, through only right around it, bare and under prefix and rename"
         (ok 2))
   (list "impure-real-time-wider"
         "rule (d): an only beside real-time, display-condition, print-record and parameterize still refuses a name off the list: current-time and cpu-time, which read clocks, condition-message, condition-continuation and display-statistics, which read or show a condition or the system, interpret, which evaluates, print-graph and print-level, the printer's other parameters, and fluid-let, which rebinds as parameterize does, are each named"
         (apply refused
                (map (lambda (i)
                       (imports "impure-real-time-wider" "circuit/middleware/waits.sls"
                                "(circuit middleware waits)" "(chezscheme)" chez-tail))
                     (iota 9))))
   (list "case-mismatch"
         "rule (a): a library's path matches its name letter for letter: (circuit request) in circuit/Request.sls is at the wrong path"
         (refused (misplaced "case-mismatch" "circuit/Request.sls" "(circuit request)"
                             "circuit/request.sls")))
   (list "rnrs-libraries"
         "every (rnrs ...) library but (rnrs eval), imported by one core library"
         (ok 1))
   (list "versions-ok"
         "version references: on an (rnrs ...) import, on a core library of the tree, on (chezscheme) and the server's in an impure library, and on the libraries' own names"
         (ok 3))

   ;; --- rule (a): files, names and places ---
   (list "misnamed"
         "rule (a): a library that is not at its name's path, in a subdirectory, in a file named for another and in one named for a prefix of it; the library at its own path is not named"
         (refused (misplaced "misnamed" "circuit/deep/x.sls" "(circuit x)" "circuit/x.sls")
                  (misplaced "misnamed" "circuit/foo.sls" "(circuit bar)" "circuit/bar.sls")
                  (misplaced "misnamed" "circuit/other.sls" "(circuit other extra)"
                             "circuit/other/extra.sls")))
   (list "chez-extension"
         "rule (a): Chez prefers request.chezscheme.sls to request.sls for (circuit request), so a library in it is at the wrong path"
         (refused (misplaced "chez-extension" "circuit/request.chezscheme.sls" "(circuit request)"
                             "circuit/request.sls")))
   (list "not-circuit"
         "rule (a): a library whose name does not start with circuit, at its own path, and one that only starts with its letters"
         (refused (not-circuit "not-circuit" "circuit-testing.sls" "(circuit-testing)")
                  (not-circuit "not-circuit" "util.sls" "(util)")))
   (list "non-sls"
         "rule (a): files that are not .sls: a hidden one, one with no extension, .scm, .txt, .ss, .sls.bak and .SLS; each is named and none is read, so a library one of them holds is undefined"
         (refused (undefined "non-sls" "circuit.sls" "(circuit)" "(circuit old)")
                  (not-sls "non-sls" "circuit/.hidden")
                  (not-sls "non-sls" "circuit/README")
                  (not-sls "non-sls" "circuit/helper.scm")
                  (not-sls "non-sls" "circuit/notes.txt")
                  (not-sls "non-sls" "circuit/old.ss")
                  (not-sls "non-sls" "circuit/request.sls.bak")
                  (not-sls "non-sls" "circuit/shout.SLS")))
   (list "two-libraries"
         "rule (a): a file that holds two libraries, which names the count and the second, off its name's path"
         (refused (string-append (at "two-libraries" "circuit/two.sls")
                                 ": it holds 2 libraries, but a file holds exactly one")
                  (misplaced "two-libraries" "circuit/two.sls" "(circuit three)"
                             "circuit/three.sls")))
   (list "not-a-library"
         "rule (a): a datum that is no library form, the first or a later one, one cut short, one with its export and import clauses in the wrong order, and one whose name is an improper list"
         (refused (string-append (at "not-a-library" "circuit/d1.sls")
                                 ": datum 1 is (define x 1), not a library form")
                  (string-append (at "not-a-library" "circuit/d2.sls")
                                 ": datum 2 is (define y 2), not a library form")
                  (string-append (at "not-a-library" "circuit/d3.sls")
                                 ": datum 1 is (define abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuv..., not a library form")
                  (string-append (at "not-a-library" "circuit/d4.sls")
                                 ": datum 1 is (library (circuit d4)), not a library form")
                  (string-append (at "not-a-library" "circuit/d5.sls")
                                 ": datum 1 is (library (circuit d5) (import (rnrs)) (export)), not a library form")
                  (string-append (at "not-a-library" "circuit/d6.sls")
                                 ": datum 1 is (library (circuit . d6) (export) (import (rnrs))), not a library form")))
   (list "no-datum"
         "rule (f): a file that holds comments and no datum"
         (refused (string-append (at "no-datum" "circuit/empty.sls")
                                 ": it holds no datum, so it holds no library")))
   (list "unreadable"
         "rule (f): a file that cannot be read as data, named with the running Chez's own words for it"
         (refused (string-append (at "unreadable" "circuit/broken.sls")
                                 ": it cannot be read as data: "
                                 (read-error (at "unreadable" "circuit/broken.sls")))))
   (list "dir-symlink"
         "rule (a): a symbolic link to a directory, which the program names and does not follow"
         (refused (string-append (at "dir-symlink" "linked")
                                 ": it is a symbolic link to a directory, which this check does not follow")))

   ;; --- rules (b), (c) and (d): who may import what ---
   (list "core-imports-server"
         "rule (c): a core library importing the server, (http-server) and (http-server waits)"
         (refused (imports "core-imports-server" "circuit.sls" "(circuit)" "(http-server)" edge-tail)
                  (imports "core-imports-server" "circuit.sls" "(circuit)" "(http-server waits)" edge-tail)))
   (list "core-imports-chezscheme"
         "rule (c): a core library importing (chezscheme)"
         (refused (imports "core-imports-chezscheme" "circuit.sls" "(circuit)" "(chezscheme)" edge-tail)))
   (list "core-imports-impure"
         "rule (c): a core library importing each impure library, both of which the tree defines"
         (refused (imports "core-imports-impure" "circuit.sls" "(circuit)" "(circuit http-server)"
                           (impure-import-tail "(circuit http-server)"))
                  (imports "core-imports-impure" "circuit.sls" "(circuit)" "(circuit middleware waits)"
                           (impure-import-tail "(circuit middleware waits)"))))
   (list "impure-imports-impure"
         "rule (d): an impure library importing the other impure library, and itself"
         (refused (imports "impure-imports-impure" "circuit/http-server.sls" "(circuit http-server)"
                           "(circuit middleware waits)" (impure-import-tail "(circuit middleware waits)"))
                  (imports "impure-imports-impure" "circuit/http-server.sls" "(circuit http-server)"
                           "(circuit http-server)" (impure-import-tail "(circuit http-server)"))
                  (imports "impure-imports-impure" "circuit/middleware/waits.sls"
                           "(circuit middleware waits)" "(circuit http-server)"
                           (impure-import-tail "(circuit http-server)"))))
   (list "impure-lookalikes"
         "rule (b): libraries named like the impure ones, longer or shorter, are core: each importing the server or (chezscheme) fails"
         (refused (imports "impure-lookalikes" "circuit/http-server/extra.sls"
                           "(circuit http-server extra)" "(http-server)" edge-tail)
                  (imports "impure-lookalikes" "circuit/middleware.sls"
                           "(circuit middleware)" "(http-server)" edge-tail)
                  (imports "impure-lookalikes" "circuit/middleware/waits/extra.sls"
                           "(circuit middleware waits extra)" "(chezscheme)" edge-tail)
                  (imports "impure-lookalikes" "circuit/waits.sls"
                           "(circuit waits)" "(chezscheme)" edge-tail)))
   (list "private-server"
         "rule (d): (http-server private ...) libraries, imported by a core library and by an impure one; (http-server), (http-server waits) and (http-server privateer) beside them are not named"
         (refused (imports "private-server" "circuit.sls" "(circuit)" "(http-server private x)" private-tail)
                  (imports "private-server" "circuit/http-server.sls" "(circuit http-server)"
                           "(http-server private)" private-tail)
                  (imports "private-server" "circuit/http-server.sls" "(circuit http-server)"
                           "(http-server private x y)" private-tail)))
   (list "rnrs-eval"
         "rule (c): (rnrs eval), plain and wrapped, in a core library, and in an impure one"
         (refused (imports "rnrs-eval" "circuit.sls" "(circuit)" "(rnrs eval)" core-tail)
                  (imports "rnrs-eval" "circuit.sls" "(circuit)" "(rnrs eval)" core-tail)
                  (imports "rnrs-eval" "circuit/http-server.sls" "(circuit http-server)"
                           "(rnrs eval)" impure-tail)))
   (list "unlisted-core"
         "rule (c): in a core library, a third-party library, (scheme), ($system), (chezscheme csv7), a test library, near-family names and an (rnrs ...) name R6RS lacks"
         (refused (imports "unlisted-core" "circuit.sls" "(circuit)" "(srfi :1)" core-tail)
                  (imports "unlisted-core" "circuit.sls" "(circuit)" "(scheme)" core-tail)
                  (imports "unlisted-core" "circuit.sls" "(circuit)" "($system)" core-tail)
                  (imports "unlisted-core" "circuit.sls" "(circuit)" "(chezscheme csv7)" edge-tail)
                  (imports "unlisted-core" "circuit.sls" "(circuit)" "(circuit-testing)" core-tail)
                  (imports "unlisted-core" "circuit.sls" "(circuit)" "(http-server-extras)" core-tail)
                  (imports "unlisted-core" "circuit.sls" "(circuit)" "(chezscheme-extras)" core-tail)
                  (imports "unlisted-core" "circuit.sls" "(circuit)" "(scheme csv7)" core-tail)
                  (imports "unlisted-core" "circuit.sls" "(circuit)" "(rnrs foo)" core-tail)
                  (imports "unlisted-core" "circuit.sls" "(circuit)" "(srfi :64)" core-tail)))
   (list "unlisted-impure"
         "rule (d): the same libraries in an impure library, which may import none of them"
         (refused (imports "unlisted-impure" "circuit/http-server.sls" "(circuit http-server)" "(srfi :1)" impure-tail)
                  (imports "unlisted-impure" "circuit/http-server.sls" "(circuit http-server)" "(scheme)" impure-tail)
                  (imports "unlisted-impure" "circuit/http-server.sls" "(circuit http-server)" "($system)" impure-tail)
                  (imports "unlisted-impure" "circuit/http-server.sls" "(circuit http-server)" "(chezscheme csv7)" impure-tail)
                  (imports "unlisted-impure" "circuit/http-server.sls" "(circuit http-server)" "(circuit-testing)" impure-tail)
                  (imports "unlisted-impure" "circuit/http-server.sls" "(circuit http-server)" "(http-server-extras)" impure-tail)
                  (imports "unlisted-impure" "circuit/http-server.sls" "(circuit http-server)" "(chezscheme-extras)" impure-tail)
                  (imports "unlisted-impure" "circuit/http-server.sls" "(circuit http-server)" "(scheme csv7)" impure-tail)
                  (imports "unlisted-impure" "circuit/http-server.sls" "(circuit http-server)" "(rnrs foo)" impure-tail)
                  (imports "unlisted-impure" "circuit/http-server.sls" "(circuit http-server)" "(srfi :64)" impure-tail)))
   (list "undefined-circuit"
         "rule (g): a (circuit ...) library that no library under the tree defines, imported by a core library and by an impure one; the one the tree defines is not named"
         (refused (undefined "undefined-circuit" "circuit.sls" "(circuit)" "(circuit nope)")
                  (undefined "undefined-circuit" "circuit/http-server.sls" "(circuit http-server)"
                             "(circuit nope-too)")))

   ;; --- rule (i): chez-websocket, through (circuit websocket) alone ---
   (list "websocket-facade"
         "rule (i): (circuit websocket) imports (websocket), bare, through only, prefix, rename and library, and with a version reference, beside core libraries; an impure library beside it still imports the server"
         (ok 4))
   (list "websocket-elsewhere"
         "rule (i): (websocket) in a core library, in each impure library, and in lookalikes of (circuit websocket), longer and plural, which are core"
         (refused (imports "websocket-elsewhere" "circuit.sls" "(circuit)" "(websocket)" facade-tail)
                  (imports "websocket-elsewhere" "circuit/http-server.sls" "(circuit http-server)"
                           "(websocket)" facade-tail)
                  (imports "websocket-elsewhere" "circuit/middleware/waits.sls" "(circuit middleware waits)"
                           "(websocket)" facade-tail)
                  (imports "websocket-elsewhere" "circuit/websocket/extra.sls" "(circuit websocket extra)"
                           "(websocket)" facade-tail)
                  (imports "websocket-elsewhere" "circuit/websockets.sls" "(circuit websockets)"
                           "(websocket)" facade-tail)))
   (list "websocket-inner"
         "rule (i): a (websocket ...) library past the facade, (websocket handshake), (websocket limits), (websocket frame) and (websocket private binding), in a core library, an impure one and (circuit websocket), wrapped or not; (websocket-extras) and (websockets), no family of it, are each library's own refusal"
         (refused (imports "websocket-inner" "circuit.sls" "(circuit)" "(websocket handshake)" inner-tail)
                  (imports "websocket-inner" "circuit/http-server.sls" "(circuit http-server)"
                           "(websocket private binding)" inner-tail)
                  (imports "websocket-inner" "circuit/request.sls" "(circuit request)"
                           "(websocket-extras)" core-tail)
                  (imports "websocket-inner" "circuit/websocket.sls" "(circuit websocket)"
                           "(websocket handshake)" inner-tail)
                  (imports "websocket-inner" "circuit/websocket.sls" "(circuit websocket)"
                           "(websocket limits)" inner-tail)
                  (imports "websocket-inner" "circuit/websocket.sls" "(circuit websocket)"
                           "(websocket private binding)" inner-tail)
                  (imports "websocket-inner" "circuit/websocket.sls" "(circuit websocket)"
                           "(websocket frame)" inner-tail)
                  (imports "websocket-inner" "circuit/websocket.sls" "(circuit websocket)"
                           "(websockets)" glue-tail)))
   (list "websocket-glue-limits"
         "rule (i): (circuit websocket) beside the facade imports none of the server's libraries, (chezscheme) even through only, an impure library, (rnrs eval) or a third party's"
         (refused (imports "websocket-glue-limits" "circuit/websocket.sls" "(circuit websocket)"
                           "(http-server)" edge-tail)
                  (imports "websocket-glue-limits" "circuit/websocket.sls" "(circuit websocket)"
                           "(chezscheme)" edge-tail)
                  (imports "websocket-glue-limits" "circuit/websocket.sls" "(circuit websocket)"
                           "(http-server private x)" private-tail)
                  (imports "websocket-glue-limits" "circuit/websocket.sls" "(circuit websocket)"
                           "(rnrs eval)" glue-tail)
                  (imports "websocket-glue-limits" "circuit/websocket.sls" "(circuit websocket)"
                           "(srfi :1)" glue-tail)
                  (imports "websocket-glue-limits" "circuit/websocket.sls" "(circuit websocket)"
                           "(circuit http-server)" (impure-import-tail "(circuit http-server)"))
                  (imports "websocket-glue-limits" "circuit/websocket.sls" "(circuit websocket)"
                           "(http-server waits)" edge-tail)))
   (list "websocket-imported"
         "rule (i): (circuit websocket) imported by a core library, by an impure one, through only, through prefix with a version reference, and by itself"
         (refused (imports "websocket-imported" "circuit.sls" "(circuit)" "(circuit websocket)" glue-import-tail)
                  (imports "websocket-imported" "circuit/http-server.sls" "(circuit http-server)"
                           "(circuit websocket)" glue-import-tail)
                  (imports "websocket-imported" "circuit/router.sls" "(circuit router)"
                           "(circuit websocket)" glue-import-tail)
                  (imports "websocket-imported" "circuit/websocket.sls" "(circuit websocket)"
                           "(circuit websocket)" glue-import-tail)))

   ;; --- rule (k): hashing, through (circuit session) alone ---
   ;; None of these trees imports (hashing sha-2) as rule (k) lets it, so
   ;; rule (l) reads no closure. akku-cases holds the trees that do.
   (list "hashing-elsewhere"
         "rule (k): a (hashing ...) library, through only or bare, in a core library, in each impure library, in (circuit websocket), and in lookalikes of (circuit session), longer and plural, which are core; (hashing-extras), no family of it, is a core library's own refusal"
         (refused (imports "hashing-elsewhere" "circuit.sls" "(circuit)" "(hashing sha-2)"
                           hashing-elsewhere-tail)
                  (imports "hashing-elsewhere" "circuit/http-server.sls" "(circuit http-server)"
                           "(hashing sha-2)" hashing-elsewhere-tail)
                  (imports "hashing-elsewhere" "circuit/middleware/waits.sls" "(circuit middleware waits)"
                           "(hashing)" hashing-elsewhere-tail)
                  (imports "hashing-elsewhere" "circuit/request.sls" "(circuit request)"
                           "(hashing-extras)" core-tail)
                  (imports "hashing-elsewhere" "circuit/session/extra.sls" "(circuit session extra)"
                           "(hashing sha-2)" hashing-elsewhere-tail)
                  (imports "hashing-elsewhere" "circuit/sessions.sls" "(circuit sessions)"
                           "(hashing sha-2)" hashing-elsewhere-tail)
                  (imports "hashing-elsewhere" "circuit/websocket.sls" "(circuit websocket)"
                           "(hashing hmac)" hashing-elsewhere-tail)))
   (list "hashing-session-other"
         "rule (k): (circuit session) importing a (hashing ...) library but (hashing sha-2), through only: (hashing hmac), (hashing fixnums), (hashing) bare, a longer (hashing sha-2 extra), (hashing md5) and (hashing private common)"
         (apply refused
                (map (lambda (imported)
                       (imports "hashing-session-other" "circuit/session.sls" "(circuit session)"
                                imported hashing-other-tail))
                     '("(hashing hmac)" "(hashing fixnums)" "(hashing)" "(hashing sha-2 extra)"
                       "(hashing md5)" "(hashing private common)"))))
   (list "hashing-session-bare"
         "rule (k): (circuit session) importing (hashing sha-2) through anything but an only right around it that names identifiers: bare, with a version reference, library, prefix, except, rename, for, an only naming nothing, only around prefix, only around except, and an only naming a number"
         (apply refused
                (map (lambda (i)
                       (imports "hashing-session-bare" "circuit/session.sls" "(circuit session)"
                                "(hashing sha-2)" hashing-only-tail))
                     (iota 11))))
   (list "hashing-session-core"
         "rule (k): (circuit session) is otherwise a core library: (chezscheme), bare and through only, the server, (rnrs eval), a third party's, chez-websocket's facade, an impure library, (circuit websocket), (hashing-extras) and a (circuit ...) library the tree does not define are each named"
         (refused (imports "hashing-session-core" "circuit/session.sls" "(circuit session)"
                           "(chezscheme)" edge-tail)
                  (imports "hashing-session-core" "circuit/session.sls" "(circuit session)"
                           "(chezscheme)" edge-tail)
                  (imports "hashing-session-core" "circuit/session.sls" "(circuit session)"
                           "(http-server)" edge-tail)
                  (imports "hashing-session-core" "circuit/session.sls" "(circuit session)"
                           "(rnrs eval)" session-tail)
                  (imports "hashing-session-core" "circuit/session.sls" "(circuit session)"
                           "(srfi :1)" session-tail)
                  (imports "hashing-session-core" "circuit/session.sls" "(circuit session)"
                           "(websocket)" facade-tail)
                  (imports "hashing-session-core" "circuit/session.sls" "(circuit session)"
                           "(circuit http-server)" (impure-import-tail "(circuit http-server)"))
                  (imports "hashing-session-core" "circuit/session.sls" "(circuit session)"
                           "(circuit websocket)" glue-import-tail)
                  (imports "hashing-session-core" "circuit/session.sls" "(circuit session)"
                           "(hashing-extras)" session-tail)
                  (undefined "hashing-session-core" "circuit/session.sls" "(circuit session)"
                             "(circuit nope)")))

   ;; --- rule (n): jsonparse, through (circuit json) alone ---
   ;; None of these trees imports (jsonparse easy) as rule (n) lets it, so
   ;; rule (o) reads no closure. jsonparse-cases holds the trees that do.
   (list "jsonparse-elsewhere"
         "rule (n): a (jsonparse ...) library, through only or bare, in a core library, in each impure library, in (circuit websocket) and (circuit session), and in lookalikes of (circuit json), longer and plural, which are core; (jsonparse-extras), no family of it, is a core library's own refusal"
         (refused (imports "jsonparse-elsewhere" "circuit.sls" "(circuit)" "(jsonparse easy)"
                           jsonparse-elsewhere-tail)
                  (imports "jsonparse-elsewhere" "circuit/http-server.sls" "(circuit http-server)"
                           "(jsonparse easy)" jsonparse-elsewhere-tail)
                  (imports "jsonparse-elsewhere" "circuit/json/extra.sls" "(circuit json extra)"
                           "(jsonparse easy)" jsonparse-elsewhere-tail)
                  (imports "jsonparse-elsewhere" "circuit/jsons.sls" "(circuit jsons)"
                           "(jsonparse easy)" jsonparse-elsewhere-tail)
                  (imports "jsonparse-elsewhere" "circuit/middleware/waits.sls" "(circuit middleware waits)"
                           "(jsonparse)" jsonparse-elsewhere-tail)
                  (imports "jsonparse-elsewhere" "circuit/request.sls" "(circuit request)"
                           "(jsonparse-extras)" core-tail)
                  (imports "jsonparse-elsewhere" "circuit/session.sls" "(circuit session)"
                           "(jsonparse easy)" jsonparse-elsewhere-tail)
                  (imports "jsonparse-elsewhere" "circuit/websocket.sls" "(circuit websocket)"
                           "(jsonparse tree)" jsonparse-elsewhere-tail)))
   (list "jsonparse-json-other"
         "rule (n): (circuit json) importing a (jsonparse ...) library but (jsonparse easy), through only: each of jsonparse's seven others, (jsonparse) bare, a longer (jsonparse easy extra) and (jsonparse private x)"
         (apply refused
                (map (lambda (imported)
                       (imports "jsonparse-json-other" "circuit/json.sls" "(circuit json)"
                                imported jsonparse-other-tail))
                     '("(jsonparse tree)" "(jsonparse parser)" "(jsonparse error)" "(jsonparse options)"
                       "(jsonparse sequence)" "(jsonparse string)" "(jsonparse writer)" "(jsonparse)"
                       "(jsonparse easy extra)" "(jsonparse private x)"))))
   (list "jsonparse-json-bare"
         "rule (n): (circuit json) importing (jsonparse easy) through anything but an only right around it that names identifiers: bare, with a version reference, library, prefix, except, rename, for, an only naming nothing, only around prefix, only around except, and an only naming a number"
         (apply refused
                (map (lambda (i)
                       (imports "jsonparse-json-bare" "circuit/json.sls" "(circuit json)"
                                "(jsonparse easy)" jsonparse-only-tail))
                     (iota 11))))
   (list "jsonparse-json-core"
         "rule (n): (circuit json) is otherwise a core library: (chezscheme), bare and through only, the server, (rnrs eval), a third party's, chez-websocket's facade, an impure library, (circuit websocket), (hashing sha-2), (jsonparse-extras), (generated jsonparse), (byte-machine runtime) through only, (byte-machine private names) and a (circuit ...) library the tree does not define are each named"
         (let ((named (lambda (imported tail)
                        (imports "jsonparse-json-core" "circuit/json.sls" "(circuit json)" imported tail))))
           (refused (named "(chezscheme)" edge-tail)
                    (named "(chezscheme)" edge-tail)
                    (named "(http-server)" edge-tail)
                    (named "(rnrs eval)" json-tail)
                    (named "(srfi :1)" json-tail)
                    (named "(websocket)" facade-tail)
                    (named "(circuit http-server)" (impure-import-tail "(circuit http-server)"))
                    (named "(circuit websocket)" glue-import-tail)
                    (named "(hashing sha-2)" hashing-elsewhere-tail)
                    (named "(jsonparse-extras)" json-tail)
                    (named "(generated jsonparse)" json-tail)
                    (named "(byte-machine runtime)" json-tail)
                    (named "(byte-machine private names)" json-tail)
                    (undefined "jsonparse-json-core" "circuit/json.sls" "(circuit json)" "(circuit nope)"))))
   (list "jsonparse-generated"
         "rule (c): the machine jsonparse generates and the byte-machine that runs it are no core library's to import: (generated jsonparse), bare and through only and prefix, (generated httparse-message), (generated), (byte-machine runtime), bare and through only, (byte-machine private conditions), (byte-machine private names) through for, and (byte-machine)"
         (let ((named (lambda (file lib imported)
                        (imports "jsonparse-generated" file lib imported core-tail))))
           (refused (named "circuit.sls" "(circuit)" "(generated jsonparse)")
                    (named "circuit.sls" "(circuit)" "(generated jsonparse)")
                    (named "circuit.sls" "(circuit)" "(generated httparse-message)")
                    (named "circuit.sls" "(circuit)" "(generated)")
                    (named "circuit.sls" "(circuit)" "(byte-machine runtime)")
                    (named "circuit.sls" "(circuit)" "(byte-machine runtime)")
                    (named "circuit.sls" "(circuit)" "(byte-machine private conditions)")
                    (named "circuit.sls" "(circuit)" "(byte-machine)")
                    (named "circuit/request.sls" "(circuit request)" "(generated jsonparse)")
                    (named "circuit/request.sls" "(circuit request)" "(byte-machine private names)"))))

   ;; --- rule (h): the #!r6rs line ---
   (list "header-missing"
         "rule (h): a library with no #!r6rs line, otherwise legal"
         (refused (no-header (at "header-missing" "circuit.sls") (root "header-missing"))))
   (list "header-chezscheme"
         "rule (h): a library headed #!chezscheme, reading a repeat vector and an fxvector literal and importing only (rnrs)"
         (refused (no-header (at "header-chezscheme" "circuit.sls") (root "header-chezscheme"))))
   (list "header-later"
         "rule (h): the #!r6rs line, and #!chezscheme on a later line, turning Chez's syntax back on"
         (refused (stray-directive (at "header-later" "circuit.sls") "line 3")))
   (list "header-in-text"
         "rule (h): #! in a line comment, a block comment and a string, each refused by its line; one file holding it on three lines, twice on one"
         (refused (stray-directive (at "header-in-text" "circuit/block.sls") "line 3")
                  (stray-directive (at "header-in-text" "circuit/comment.sls") "line 2")
                  (stray-directive (at "header-in-text" "circuit/several.sls") "lines 2, 6 and 7")
                  (stray-directive (at "header-in-text" "circuit/string.sls") "line 5")))
   (list "header-not-first"
         "rule (h): the #!r6rs line after a comment line: the file does not begin with it, and its #! is on line 2"
         (refused (no-header (at "header-not-first" "circuit.sls") (root "header-not-first"))
                  (stray-directive (at "header-not-first" "circuit.sls") "line 2")))
   (list "header-variants"
         "rule (h): #!r6rs with the library on the same line is not the line #!r6rs"
         (refused (no-header (at "header-variants" "circuit/same-line.sls") (root "header-variants"))))

   ;; --- rule (e): import specs ---
   (list "wrapped"
         "rule (e): a banned library imported through only, except, prefix, rename, for, for with a meta level and library; (http-server) through only; an impure library through only"
         (refused (imports "wrapped" "circuit/w1.sls" "(circuit w1)" "(chezscheme)" edge-tail)
                  (imports "wrapped" "circuit/w2.sls" "(circuit w2)" "(chezscheme)" edge-tail)
                  (imports "wrapped" "circuit/w3.sls" "(circuit w3)" "(chezscheme)" edge-tail)
                  (imports "wrapped" "circuit/w4.sls" "(circuit w4)" "(chezscheme)" edge-tail)
                  (imports "wrapped" "circuit/w5.sls" "(circuit w5)" "(chezscheme)" edge-tail)
                  (imports "wrapped" "circuit/w6.sls" "(circuit w6)" "(chezscheme)" edge-tail)
                  (imports "wrapped" "circuit/w7.sls" "(circuit w7)" "(chezscheme)" edge-tail)
                  (imports "wrapped" "circuit/w8.sls" "(circuit w8)" "(http-server)" edge-tail)
                  (imports "wrapped" "circuit/w9.sls" "(circuit w9)" "(circuit http-server)"
                           (impure-import-tail "(circuit http-server)"))))
   (list "wrapped-nested"
         "rule (e): wrappers nested to any depth: five kinds deep around (chezscheme), prefix and only around an impure library, forty onlys around (http-server); a legal nested import beside them is not named"
         (refused (imports "wrapped-nested" "circuit/n1.sls" "(circuit n1)" "(chezscheme)" edge-tail)
                  (imports "wrapped-nested" "circuit/n2.sls" "(circuit n2)" "(circuit http-server)"
                           (impure-import-tail "(circuit http-server)"))
                  (imports "wrapped-nested" "circuit/n3.sls" "(circuit n3)" "(http-server)" edge-tail)))
   (list "versions-banned"
         "rule (e): a version reference does not hide the library: (chezscheme (9)), (http-server (1 0)), (http-server waits (>= 1)), an impure library and (rnrs eval (6))"
         (refused (imports "versions-banned" "circuit.sls" "(circuit)" "(chezscheme)" edge-tail)
                  (imports "versions-banned" "circuit.sls" "(circuit)" "(http-server)" edge-tail)
                  (imports "versions-banned" "circuit.sls" "(circuit)" "(http-server waits)" edge-tail)
                  (imports "versions-banned" "circuit.sls" "(circuit)" "(circuit http-server)"
                           (impure-import-tail "(circuit http-server)"))
                  (imports "versions-banned" "circuit.sls" "(circuit)" "(rnrs eval)" core-tail)))
   (list "cyclic"
         "rule (e): an import spec that contains itself, through only, for, rename and a tail, is named and the program ends. Chez refuses datum labels after #!r6rs, so the file has no header, and rule (h) names it first"
         (refused (no-header (at "cyclic" "circuit.sls") (root "cyclic"))
                  (unreadable-spec "cyclic" "circuit.sls" "(circuit)" "#0=(only #0# x)")
                  (unreadable-spec "cyclic" "circuit.sls" "(circuit)" "#0=(for #0# run)")
                  (unreadable-spec "cyclic" "circuit.sls" "(circuit)" "#0=(rename #0# (a b))")
                  (unreadable-spec "cyclic" "circuit.sls" "(circuit)" "#0=(only (rnrs) . #0#)")))
   (list "cannot-read-spec"
         "rule (e): specs that name no library: a number, a string, an empty list, a wrapper with nothing to wrap, library with no or two or a bare reference, a reference with a bad version or a bad shape"
         (apply refused
                (map (lambda (spec) (unreadable-spec "cannot-read-spec" "circuit.sls" "(circuit)" spec))
                     '("42" "()" "(only)" "(for)" "(library)" "(library x)" "(library (rnrs) extra)"
                       "(rnrs 5)" "(rnrs (6) base)" "\"str\"" "(rnrs . base)" "(library (rnrs . base))"
                       "((rnrs))" "(only 5)"))))))

;; --- rules (k) and (l): the trees whose closure is read ----------------------------------

;; What the closure of (jsonparse easy) may import, as rule (o)'s pass line
;; and its complaints say it.
(define jsonparse-allows
  "the (rnrs ...) libraries except (rnrs eval), (jsonparse error), (jsonparse options), (jsonparse parser), (jsonparse sequence), (jsonparse string), (jsonparse tree), (jsonparse writer), (generated jsonparse), (byte-machine runtime), (byte-machine private conditions) and (byte-machine private names)")

;; passed : Natural (U Natural #f) (U (Pair String Natural) #f) (U Natural #f)
;;          [(U (List String String Natural) #f) (U Natural #f) (U Natural #f)]
;;          -> (List 0 String "")
;; A pass's whole answer: the tree's line, with how many libraries it
;; checked; rule (j)'s, with how many LIBDIRs it looked in, when it was
;; named any; rule (l)'s, naming AKKU and how many libraries it read, when
;; it read the closure; rule (m)'s, with how many LIBDIRs it looked in, when
;; --akku was named; rule (o)'s, naming JSONPARSE, BYTE-MACHINE and how many
;; libraries it read, when it read that closure; and rule (p)'s, with how
;; many LIBDIRs it looked in, for jsonparse when --jsonparse was named and
;; for byte-machine when --byte-machine was.
(define passed
  (case-lambda
    ((libraries circuit-looked closure hashing-looked)
     (passed libraries circuit-looked closure hashing-looked #f #f #f))
    ((libraries circuit-looked closure hashing-looked json-closure jsonparse-looked byte-machine-looked)
     (list 0
           (string-append
            "check-imports: ok, libraries checked: " (number->string libraries) "\n"
            (if circuit-looked
                (string-append "check-imports: ok, no other directory on the library path holds circuit: "
                               (number->string circuit-looked) " looked in\n")
                "")
            (if closure
                (string-append "check-imports: ok, the closure of (hashing sha-2) in " (car closure)
                               " imports only the (rnrs ...) libraries except (rnrs eval), (hashing fixnums) and (hashing hmac): "
                               (number->string (cdr closure)) " libraries read\n")
                "")
            (if hashing-looked
                (string-append "check-imports: ok, no other directory on the library path holds hashing: "
                               (number->string hashing-looked) " looked in\n")
                "")
            (if json-closure
                (string-append "check-imports: ok, the closure of (jsonparse easy) in " (car json-closure)
                               " and " (cadr json-closure) " imports only " jsonparse-allows ": "
                               (number->string (caddr json-closure)) " libraries read\n")
                "")
            (if jsonparse-looked
                (string-append "check-imports: ok, no other directory on the library path holds jsonparse: "
                               (number->string jsonparse-looked) " looked in\n")
                "")
            (if byte-machine-looked
                (string-append "check-imports: ok, no other directory on the library path holds byte-machine: "
                               (number->string byte-machine-looked) " looked in\n")
                ""))
           ""))))

;; Rule (l)'s complaints: no --akku, and for a library of the closure, no
;; source, a compiled object, a file that is no one library form of its
;; name, an import it cannot read, and one it may not import.
(define no-akku
  "(circuit session) imports (hashing sha-2), but no --akku names the directory this check reads its closure from")

;; not-found : String String -> String
(define (not-found akku lib)
  (string-append akku ": Chez finds no source for " lib " in it, so this check cannot read what it imports"))

;; compiled : String String -> String
(define (compiled object lib)
  (string-append object ": it is compiled, so Chez could load " lib
                 " from it in place of its source, which this check reads"))

;; misshapen : String String -> String
(define (misshapen source lib)
  (string-append source ": Chez loads " lib " from it, but it is not exactly one library form named " lib))

;; closure-spec : String String String -> String
(define (closure-spec source lib spec)
  (string-append source ": " lib " has an import it cannot read: " spec))

;; closure-imports : String String String -> String
(define (closure-imports source lib imported)
  (string-append source ": " lib " imports " imported
                 ", but the closure of (hashing sha-2) may import only the (rnrs ...) libraries except (rnrs eval), (hashing fixnums) and (hashing hmac)"))

;; cannot-read : String -> String
(define (cannot-read source)
  (string-append source ": it cannot be read as data: " (read-error source)))

;; on-hashing-path : String String (U String #f) -> String
;; Rule (m)'s complaint about ENTRY, in the library directory DIR, when
;; --akku names AKKU, or names none.
(define (on-hashing-path dir entry akku)
  (string-append dir "/" entry
                 (if akku
                     (string-append ": its directory is on the library path beside " akku
                                    ", so Chez could load a (hashing ...) library from it in place of "
                                    akku "'s, which this check reads; only " akku " may hold one")
                     ": its directory is on the library path, so Chez could load a (hashing ...) library from it, and no --akku names the one directory that may hold one")))

;; akku-cases : (Listof (List String String (Listof String) Expected))
;; The fixture directory, which holds a tree in src/ and one AKKU or more,
;; what it holds, the command line, each path in it under the fixture
;; directory, and the program's whole answer. Each src/ but the first
;; case's holds (circuit session) alone, importing (hashing sha-2) through
;; only, so the closure is read. Each fake hashing file is a stand-in,
;; written for its fixture, and its #!r6rs comes after a comment, as
;; hashing's do: rule (h) does not hold them.
(define akku-cases
  (let ((akku (lambda (case dir) (at case dir)))
        (file (lambda (case dir name) (at case (string-append dir "/hashing/" name)))))
    (list
     (list "hashing-session"
           "rule (k): (circuit session) imports (hashing sha-2) through only right around it, around library, and inside prefix, rename, except and for, with a version reference, beside a core library; a core library imports (circuit session); the closure is read once"
           '("src" "--akku" "akku")
           (passed 3 #f (cons (akku "hashing-session" "akku") 3) 0))
     (list "hashing-legal"
           "rule (l): the closure as the pin has it, (hashing sha-2) in a .scm importing (rnrs ...) libraries and its two siblings, (hashing fixnums) in a .sls with a version reference on (rnrs), (hashing hmac) in a .scm; hashing's other files, which import (chezscheme) and (guile), are not in it and are not read"
           '("src" "--akku" "akku")
           (passed 1 #f (cons (akku "hashing-legal" "akku") 3) 0))
     (list "hashing-legal"
           "rule (l): a slash after AKKU changes nothing: the line names AKKU without it"
           '("src" "--akku" "akku/")
           (passed 1 #f (cons (akku "hashing-legal" "akku") 3) 0))
     (list "hashing-legal"
           "rule (l): (hashing sha-2) imported, and no --akku named"
           '("src")
           (refused no-akku))
     (list "hashing-legal"
           "rules (l) and (m): the command line before --akku, AKKU named as a LIBDIR alone: no closure is read, and rule (m) names its hashing and hashing.sha256"
           '("src" "akku")
           (refused no-akku
                    (on-hashing-path (akku "hashing-legal" "akku") "hashing" #f)
                    (on-hashing-path (akku "hashing-legal" "akku") "hashing.sha256" #f)))
     (list "hashing-extensions"
           "rule (l): each library is the file Chez takes, by its extensions' order: (hashing sha-2) from .sch, the last; (hashing fixnums) from .ss, over a .sls, .scm and .sch that import (chezscheme); (hashing hmac) from .sls, over a .scm and .sch that do"
           '("src" "--akku" "akku")
           (passed 1 #f (cons (akku "hashing-extensions" "akku") 3) 0))
     (list "hashing-preferred"
           "rule (l): a .chezscheme.sls beside (hashing sha-2)'s legal .scm, and a .ss beside (hashing hmac)'s, are the files Chez loads, and are read: each one's import is named"
           '("src" "--akku" "akku")
           (refused (closure-imports (file "hashing-preferred" "akku" "sha-2.chezscheme.sls")
                                     "(hashing sha-2)" "(chezscheme)")
                    (closure-imports (file "hashing-preferred" "akku" "hmac.ss")
                                     "(hashing hmac)" "(rnrs eval)")))
     (list "hashing-cycle"
           "rule (l): (hashing fixnums) and (hashing hmac) import each other, with version references on the libraries' names and imports: each is read once, and the closure ends"
           '("src" "--akku" "akku")
           (passed 1 #f (cons (akku "hashing-cycle" "akku") 3) 0))
     (list "hashing-not-found"
           "rule (l): no source for (hashing hmac), beside files Chez would not take for it: .guile.sls, .scm.bak, hmacs.scm and a directory hmac/"
           '("src" "--akku" "akku-no-hmac")
           (refused (not-found (akku "hashing-not-found" "akku-no-hmac") "(hashing hmac)")))
     (list "hashing-not-found"
           "rule (l): no source for (hashing sha-2), beside its siblings and files Chez would not take for it: .guile.sls, sha2.scm, .scm.bak, and a sha-2.scm outside hashing/"
           '("src" "--akku" "akku-no-sha-2")
           (refused (not-found (akku "hashing-not-found" "akku-no-sha-2") "(hashing sha-2)")))
     (list "hashing-unreadable"
           "rule (l): a source that cannot be read as data, named with the running Chez's own words for it"
           '("src" "--akku" "akku-broken")
           (refused (cannot-read (file "hashing-unreadable" "akku-broken" "hmac.scm"))))
     (list "hashing-unreadable"
           "rule (l): a directory where the source would be, which Chez's search handler names, cannot be read as data"
           '("src" "--akku" "akku-directory")
           (refused (cannot-read (file "hashing-unreadable" "akku-directory" "hmac.scm"))))
     (list "hashing-shape"
           "rule (l): a library of another name where Chez finds (hashing fixnums), and a second library after (hashing hmac)"
           '("src" "--akku" "akku-a")
           (refused (misshapen (file "hashing-shape" "akku-a" "fixnums.sls") "(hashing fixnums)")
                    (misshapen (file "hashing-shape" "akku-a" "hmac.scm") "(hashing hmac)")))
     (list "hashing-shape"
           "rule (l): a file of comments alone where Chez finds (hashing fixnums), and a datum before (hashing hmac)"
           '("src" "--akku" "akku-b")
           (refused (misshapen (file "hashing-shape" "akku-b" "fixnums.sls") "(hashing fixnums)")
                    (misshapen (file "hashing-shape" "akku-b" "hmac.scm") "(hashing hmac)")))
     (list "hashing-shape"
           "rule (l): (hashing sha-2) with its import clause before its export clause, which is no library form: its imports, and so its siblings, are not read"
           '("src" "--akku" "akku-c")
           (refused (misshapen (file "hashing-shape" "akku-c" "sha-2.scm") "(hashing sha-2)")))
     (list "hashing-spec"
           "rule (l): imports in the closure that name no library: (library (rnrs) extra), 42 and (only); the (rnrs) beside them is not named"
           '("src" "--akku" "akku")
           (refused (closure-spec (file "hashing-spec" "akku" "fixnums.sls") "(hashing fixnums)"
                                  "(library (rnrs) extra)")
                    (closure-spec (file "hashing-spec" "akku" "hmac.scm") "(hashing hmac)" "42")
                    (closure-spec (file "hashing-spec" "akku" "hmac.scm") "(hashing hmac)" "(only)")))
     (list "hashing-imports"
           "rule (l): the closure imports nothing but (rnrs ...), (hashing fixnums) and (hashing hmac): (rnrs eval), plain and under prefix with a version reference, (hashing sha-2) itself, (hashing md5), (chezscheme) through only, a (circuit ...) library, a third party's, (hashing-extras), (hashing private compat) and (hashing) are each named; (hashing fixnums), reached twice, is read once"
           '("src" "--akku" "akku")
           (let ((sha-2 (file "hashing-imports" "akku" "sha-2.scm"))
                 (fixnums (file "hashing-imports" "akku" "fixnums.sls"))
                 (hmac (file "hashing-imports" "akku" "hmac.scm")))
             (refused (closure-imports sha-2 "(hashing sha-2)" "(rnrs eval)")
                      (closure-imports sha-2 "(hashing sha-2)" "(rnrs eval)")
                      (closure-imports sha-2 "(hashing sha-2)" "(hashing sha-2)")
                      (closure-imports sha-2 "(hashing sha-2)" "(hashing md5)")
                      (closure-imports sha-2 "(hashing sha-2)" "(chezscheme)")
                      (closure-imports fixnums "(hashing fixnums)" "(circuit session)")
                      (closure-imports fixnums "(hashing fixnums)" "(srfi :1)")
                      (closure-imports fixnums "(hashing fixnums)" "(hashing-extras)")
                      (closure-imports hmac "(hashing hmac)" "(hashing sha-2)")
                      (closure-imports hmac "(hashing hmac)" "(hashing private compat)")
                      (closure-imports hmac "(hashing hmac)" "(hashing)")))))))

;; --- rules (n) and (o): the trees whose jsonparse closure is read ------------------------

;; Rule (o)'s complaints: no --jsonparse, no --byte-machine, a library of
;; the closure with no source in either directory, and an import it may not
;; make. The others are rule (l)'s words: compiled, misshapen, closure-spec
;; and cannot-read.
(define no-jsonparse
  "(circuit json) imports (jsonparse easy), but no --jsonparse names the directory this check reads its closure's (jsonparse ...) and (generated ...) libraries from")

(define no-byte-machine
  "(circuit json) imports (jsonparse easy), but no --byte-machine names the directory this check reads its closure's (byte-machine ...) libraries from")

;; not-found-in : String String String -> String
;; The closure's directories are named in the order it searches them:
;; BYTE-MACHINE, then JSONPARSE, as the library path has them.
(define (not-found-in jsonparse byte-machine lib)
  (string-append byte-machine " and " jsonparse ": Chez finds no source for " lib
                 " in them, so this check cannot read what it imports"))

;; jsonparse-imports : String String String -> String
(define (jsonparse-imports source lib imported)
  (string-append source ": " lib " imports " imported
                 ", but the closure of (jsonparse easy) may import only " jsonparse-allows))

;; on-jsonparse-path : String String (U String #f) -> String
;; Rule (p)'s complaint about ENTRY, in the library directory DIR, when
;; --jsonparse names JSONPARSE, or names none.
(define (on-jsonparse-path dir entry jsonparse)
  (string-append dir "/" entry
                 (if jsonparse
                     (string-append ": its directory is on the library path beside " jsonparse
                                    ", so Chez could load a (jsonparse ...) library from it in place of "
                                    jsonparse "'s, which this check reads; only " jsonparse " may hold one")
                     ": its directory is on the library path, so Chez could load a (jsonparse ...) library from it, and no --jsonparse names the one directory that may hold one")))

;; on-generated-path : String String String (U String #f) -> String
;; Rule (p)'s complaint about ENTRY, in the directory GENERATED of the
;; library directory DIR, when --jsonparse names JSONPARSE, or names none.
(define (on-generated-path dir generated entry jsonparse)
  (string-append dir "/" generated "/" entry ": it is in " dir
                 (if jsonparse
                     (string-append ", which is on the library path beside " jsonparse
                                    ", so Chez could load a (generated jsonparse ...) library from it in place of "
                                    jsonparse "'s, which this check reads; only " jsonparse " may hold one")
                     ", which is on the library path, so Chez could load a (generated jsonparse ...) library from it, and no --jsonparse names the one directory that may hold one")))

;; on-byte-machine-path : String String (U String #f) -> String
;; Rule (p)'s complaint about ENTRY, in the library directory DIR, when
;; --byte-machine names BYTE-MACHINE, or names none.
(define (on-byte-machine-path dir entry byte-machine)
  (string-append dir "/" entry
                 (if byte-machine
                     (string-append ": its directory is on the library path beside " byte-machine
                                    ", so Chez could load a (byte-machine ...) library from it in place of "
                                    byte-machine "'s, which this check reads; only " byte-machine " may hold one")
                     ": its directory is on the library path, so Chez could load a (byte-machine ...) library from it, and no --byte-machine names the one directory that may hold one")))

;; Rule (p)'s complaints about a jsonparse in BYTE-MACHINE, which rule (o)
;; reads before JSONPARSE: there, BYTE-MACHINE's copy is the one it reads.

;; on-jsonparse-path-ahead : String String String -> String
;; About ENTRY in BYTE-MACHINE, when --jsonparse names JSONPARSE.
(define (on-jsonparse-path-ahead byte-machine entry jsonparse)
  (string-append byte-machine "/" entry ": its directory is on the library path beside " jsonparse
                 ", so Chez could load a (jsonparse ...) library from it in place of " jsonparse
                 "'s, and this check reads " byte-machine " before " jsonparse
                 ", in the library path's order; only " jsonparse " may hold one"))

;; on-generated-path-ahead : String String String String -> String
;; About ENTRY in BYTE-MACHINE's directory GENERATED, when --jsonparse names
;; JSONPARSE.
(define (on-generated-path-ahead byte-machine generated entry jsonparse)
  (string-append byte-machine "/" generated "/" entry ": it is in " byte-machine
                 ", which is on the library path beside " jsonparse
                 ", so Chez could load a (generated jsonparse ...) library from it in place of " jsonparse
                 "'s, and this check reads " byte-machine " before " jsonparse
                 ", in the library path's order; only " jsonparse " may hold one"))

;; jsonparse-cases : (Listof (List String String (Listof String) Expected))
;; As akku-cases: the fixture directory, which holds a tree in src/ and a
;; JSONPARSE and a BYTE-MACHINE or more, what it holds, the command line,
;; each path in it under the fixture directory, and the program's whole
;; answer. Each src/ but the first case's and the last's holds (circuit
;; json) alone, importing (jsonparse easy) through only, so the closure is
;; read. Most read the small closure of seven libraries: (jsonparse easy),
;; which imports (jsonparse parser) and (jsonparse tree); the parser, which
;; imports (generated jsonparse) and (byte-machine runtime); the tree, which
;; imports the parser; the machine, which imports the runtime; and the
;; runtime, which imports (byte-machine private conditions) and
;; (byte-machine private names).
(define jsonparse-cases
  (let ((dir (lambda (case d) (at case d)))
        (file (lambda (case d name) (at case (string-append d "/" name))))
        (whole '("src" "--jsonparse" "jsonparse" "--byte-machine" "byte-machine")))
    (list
     (list "jsonparse-json"
           "rule (n): (circuit json) imports (jsonparse easy) through only right around it, around library, and inside prefix, rename, except and for, with a version reference, beside a core library; a core library imports (circuit json); the closure is read"
           whole
           (passed 3 #f #f #f
                   (list (dir "jsonparse-json" "jsonparse") (dir "jsonparse-json" "byte-machine") 7) 0 0))
     (list "jsonparse-legal"
           "rule (o): the closure as the pin has it: (jsonparse easy) importing jsonparse's seven others, which import each other, (generated jsonparse) and (byte-machine runtime), the machine headed #!r6rs after a comment, and the runtime its two private libraries; jsonparse's and byte-machine's other files, which import (chezscheme), are not in it and are not read"
           whole
           (passed 1 #f #f #f
                   (list (dir "jsonparse-legal" "jsonparse") (dir "jsonparse-legal" "byte-machine") 12) 0 0))
     (list "jsonparse-legal"
           "rule (o): a slash after JSONPARSE and BYTE-MACHINE changes nothing: the line names each without it"
           '("src" "--jsonparse" "jsonparse/" "--byte-machine" "byte-machine//")
           (passed 1 #f #f #f
                   (list (dir "jsonparse-legal" "jsonparse") (dir "jsonparse-legal" "byte-machine") 12) 0 0))
     (list "jsonparse-legal"
           "rule (o): --byte-machine before --jsonparse changes nothing"
           '("src" "--byte-machine" "byte-machine" "--jsonparse" "jsonparse")
           (passed 1 #f #f #f
                   (list (dir "jsonparse-legal" "jsonparse") (dir "jsonparse-legal" "byte-machine") 12) 0 0))
     (list "jsonparse-legal"
           "rule (o): (jsonparse easy) imported, and no --jsonparse named"
           '("src" "--byte-machine" "byte-machine")
           (refused no-jsonparse))
     (list "jsonparse-legal"
           "rule (o): (jsonparse easy) imported, and no --byte-machine named"
           '("src" "--jsonparse" "jsonparse")
           (refused no-byte-machine))
     (list "jsonparse-legal"
           "rule (o): (jsonparse easy) imported, and neither flag named"
           '("src")
           (refused no-jsonparse no-byte-machine))
     (list "jsonparse-legal"
           "rules (o) and (p): JSONPARSE and BYTE-MACHINE named as LIBDIRs alone: no closure is read, and rule (p) names their jsonparse, generated/jsonparse.sls and byte-machine"
           '("src" "jsonparse" "byte-machine")
           (refused no-jsonparse
                    no-byte-machine
                    (on-jsonparse-path (dir "jsonparse-legal" "jsonparse") "jsonparse" #f)
                    (on-generated-path (dir "jsonparse-legal" "jsonparse") "generated" "jsonparse.sls" #f)
                    (on-byte-machine-path (dir "jsonparse-legal" "byte-machine") "byte-machine" #f)))
     (list "jsonparse-order"
           "rule (o): BYTE-MACHINE is the first library directory, as the library path has it: its (jsonparse tree), which imports (chezscheme), is the one read, over JSONPARSE's legal one, and JSONPARSE's (byte-machine runtime), which imports (chezscheme), is not read"
           whole
           (refused (jsonparse-imports (file "jsonparse-order" "byte-machine" "jsonparse/tree.sls")
                                       "(jsonparse tree)" "(chezscheme)")))
     (list "jsonparse-order"
           "rule (o): the flags' order on the command line is not the directories' order"
           '("src" "--byte-machine" "byte-machine" "--jsonparse" "jsonparse")
           (refused (jsonparse-imports (file "jsonparse-order" "byte-machine" "jsonparse/tree.sls")
                                       "(jsonparse tree)" "(chezscheme)")))
     (list "jsonparse-preferred"
           "rule (o): a .chezscheme.sls beside (jsonparse tree)'s legal .sls, and a .ss beside (byte-machine runtime)'s, are the files Chez loads, and are read: each one's import is named"
           whole
           (refused (jsonparse-imports (file "jsonparse-preferred" "jsonparse" "jsonparse/tree.chezscheme.sls")
                                       "(jsonparse tree)" "(chezscheme)")
                    (jsonparse-imports (file "jsonparse-preferred" "byte-machine" "byte-machine/runtime.ss")
                                       "(byte-machine runtime)" "(rnrs eval)")))
     (list "jsonparse-cycle"
           "rule (o): (jsonparse parser) and (jsonparse tree) import each other, and so do byte-machine's two private libraries, with version references on the libraries' names and imports: each is read once, and the closure ends"
           whole
           (passed 1 #f #f #f
                   (list (dir "jsonparse-cycle" "jsonparse") (dir "jsonparse-cycle" "byte-machine") 7) 0 0))
     (list "jsonparse-not-found"
           "rule (o): no source for (jsonparse tree) in either directory, beside files Chez would not take for it: .guile.sls, .sls.bak, trees.sls and a directory tree/"
           '("src" "--jsonparse" "jsonparse-no-tree" "--byte-machine" "byte-machine")
           (refused (not-found-in (dir "jsonparse-not-found" "jsonparse-no-tree")
                                  (dir "jsonparse-not-found" "byte-machine") "(jsonparse tree)")))
     (list "jsonparse-not-found"
           "rule (o): no source for (generated jsonparse), beside files Chez would not take for it: generated/jsonparse-machine.sls, generated/httparse-message.sls, a jsonparse.sls outside generated/, and jsonparse/generated.sls"
           '("src" "--jsonparse" "jsonparse-no-generated" "--byte-machine" "byte-machine")
           (refused (not-found-in (dir "jsonparse-not-found" "jsonparse-no-generated")
                                  (dir "jsonparse-not-found" "byte-machine") "(generated jsonparse)")))
     (list "jsonparse-not-found"
           "rule (o): no source for (byte-machine private names), beside files Chez would not take for it: byte-machine/names.sls, a .scm.bak and private/name.sls"
           '("src" "--jsonparse" "jsonparse" "--byte-machine" "byte-machine-no-names")
           (refused (not-found-in (dir "jsonparse-not-found" "jsonparse")
                                  (dir "jsonparse-not-found" "byte-machine-no-names")
                                  "(byte-machine private names)")))
     (list "jsonparse-unreadable"
           "rule (o): a source in JSONPARSE that cannot be read as data, named with the running Chez's own words for it"
           '("src" "--jsonparse" "jsonparse-broken" "--byte-machine" "byte-machine")
           (refused (cannot-read (file "jsonparse-unreadable" "jsonparse-broken" "jsonparse/tree.sls"))))
     (list "jsonparse-unreadable"
           "rule (o): a directory in BYTE-MACHINE where the source would be, which Chez's search handler names, cannot be read as data"
           '("src" "--jsonparse" "jsonparse" "--byte-machine" "byte-machine-directory")
           (refused (cannot-read (file "jsonparse-unreadable" "byte-machine-directory" "byte-machine/runtime.sls"))))
     (list "jsonparse-shape"
           "rule (o): a library of another name where Chez finds (jsonparse tree), and a second library after (generated jsonparse)"
           '("src" "--jsonparse" "jsonparse-a" "--byte-machine" "byte-machine")
           (refused (misshapen (file "jsonparse-shape" "jsonparse-a" "jsonparse/tree.sls") "(jsonparse tree)")
                    (misshapen (file "jsonparse-shape" "jsonparse-a" "generated/jsonparse.sls")
                               "(generated jsonparse)")))
     (list "jsonparse-shape"
           "rule (o): a datum before (byte-machine private conditions), and a file of comments alone where Chez finds (byte-machine private names)"
           '("src" "--jsonparse" "jsonparse" "--byte-machine" "byte-machine-b")
           (refused (misshapen (file "jsonparse-shape" "byte-machine-b" "byte-machine/private/conditions.sls")
                               "(byte-machine private conditions)")
                    (misshapen (file "jsonparse-shape" "byte-machine-b" "byte-machine/private/names.sls")
                               "(byte-machine private names)")))
     (list "jsonparse-shape"
           "rule (o): (jsonparse easy) with its import clause before its export clause, which is no library form: its imports, and so the rest of the closure, are not read"
           '("src" "--jsonparse" "jsonparse-c" "--byte-machine" "byte-machine")
           (refused (misshapen (file "jsonparse-shape" "jsonparse-c" "jsonparse/easy.sls") "(jsonparse easy)")))
     (list "jsonparse-spec"
           "rule (o): imports in the closure that name no library: (library (rnrs) extra) in JSONPARSE, 42 and (only) in BYTE-MACHINE; the (rnrs) beside them is not named"
           whole
           (refused (closure-spec (file "jsonparse-spec" "jsonparse" "jsonparse/tree.sls") "(jsonparse tree)"
                                  "(library (rnrs) extra)")
                    (closure-spec (file "jsonparse-spec" "byte-machine" "byte-machine/runtime.sls")
                                  "(byte-machine runtime)" "42")
                    (closure-spec (file "jsonparse-spec" "byte-machine" "byte-machine/runtime.sls")
                                  "(byte-machine runtime)" "(only)")))
     (list "jsonparse-imports"
           "rule (o): the closure imports nothing but (rnrs ...) and its allowlist: (rnrs eval), plain and under prefix with a version reference, (jsonparse easy) itself, (jsonparse), (jsonparse private x), (jsonparse-extras), (chezscheme) through only, another generated machine, (generated), (hashing sha-2), a (circuit ...) library, byte-machine's compile, interpret, ir and verify libraries, (byte-machine) and a third party's are each named; (jsonparse tree), imported twice, is read once"
           whole
           (let ((easy (file "jsonparse-imports" "jsonparse" "jsonparse/easy.sls"))
                 (parser (file "jsonparse-imports" "jsonparse" "jsonparse/parser.sls"))
                 (runtime (file "jsonparse-imports" "byte-machine" "byte-machine/runtime.sls")))
             (refused (jsonparse-imports easy "(jsonparse easy)" "(rnrs eval)")
                      (jsonparse-imports easy "(jsonparse easy)" "(rnrs eval)")
                      (jsonparse-imports easy "(jsonparse easy)" "(jsonparse easy)")
                      (jsonparse-imports easy "(jsonparse easy)" "(jsonparse)")
                      (jsonparse-imports easy "(jsonparse easy)" "(jsonparse private x)")
                      (jsonparse-imports easy "(jsonparse easy)" "(jsonparse-extras)")
                      (jsonparse-imports parser "(jsonparse parser)" "(chezscheme)")
                      (jsonparse-imports parser "(jsonparse parser)" "(generated httparse-message)")
                      (jsonparse-imports parser "(jsonparse parser)" "(generated)")
                      (jsonparse-imports parser "(jsonparse parser)" "(hashing sha-2)")
                      (jsonparse-imports parser "(jsonparse parser)" "(circuit json)")
                      (jsonparse-imports runtime "(byte-machine runtime)" "(byte-machine compile)")
                      (jsonparse-imports runtime "(byte-machine runtime)" "(byte-machine interpret)")
                      (jsonparse-imports runtime "(byte-machine runtime)" "(byte-machine private ir)")
                      (jsonparse-imports runtime "(byte-machine runtime)" "(byte-machine verify)")
                      (jsonparse-imports runtime "(byte-machine runtime)" "(byte-machine)")
                      (jsonparse-imports runtime "(byte-machine runtime)" "(srfi :1)"))))
     (list "jsonparse-hashing"
           "rules (l) and (o) together: (circuit session) imports (hashing sha-2) and (circuit json) imports (jsonparse easy), run with every flag, in another order, and with AKKU, JSONPARSE and BYTE-MACHINE as LIBDIRs: every pass line, each rule looking in all but its own directory"
           '("src" "--byte-machine" "byte-machine" "--akku" "akku" "--jsonparse" "jsonparse"
             "jsonparse" "byte-machine" "akku")
           (passed 3 3 (cons (dir "jsonparse-hashing" "akku") 3) 2
                   (list (dir "jsonparse-hashing" "jsonparse") (dir "jsonparse-hashing" "byte-machine") 7) 2 2)))))

;; akku-args : String (Listof String) -> (Listof String)
;; ARGS, each path in them under the fixture directory CASE: all but the
;; flags.
(define (akku-args case args)
  (map (lambda (arg) (if (member arg '("--akku" "--jsonparse" "--byte-machine")) arg (at case arg))) args))

(test-begin "check-imports")

(test-equal "CHEZ names the Chez to spawn"
  'set
  (if (and chez (not (string=? chez ""))) 'set 'unset))

(unless (and chez (not (string=? chez "")))
  (exit 1))

(for-each
 (lambda (case)
   (test-equal (string-append (car case) ": " (cadr case))
     (caddr case)
     (run (list (root (car case))))))
 cases)

;; spaced : (Pairof String (Listof String)) -> String
;; WORDS, a space between each two.
(define (spaced words)
  (fold-left (lambda (text word) (string-append text " " word)) (car words) (cdr words)))

(for-each
 (lambda (case)
   (test-equal (string-append (car case) ", run with " (spaced (caddr case)) ": " (cadr case))
     (cadddr case)
     (run (akku-args (car case) (caddr case)))))
 (append akku-cases jsonparse-cases))

;; unique : (Listof String) -> (Listof String)
;; NAMES, each once, in the order first named.
(define (unique names)
  (fold-left (lambda (found name) (if (member name found) found (append found (list name))))
             '()
             names))

;; A fixture nothing runs guards nothing, and a case with no fixture runs on a
;; missing directory.
(test-equal "every fixture directory is a case above, and every case has its directory"
  (list-sort string<? (unique (append (map car cases) (map car akku-cases) (map car jsonparse-cases))))
  (list-sort string<?
             (filter (lambda (name) (file-directory? (string-append fixtures "/" name)))
                     (directory-list fixtures))))

(test-equal "a slash after the directory changes nothing: no doubled slash in a path it names"
  (caddr (assoc "misnamed" cases))
  (run (list (string-append (root "misnamed") "/"))))

;; --- the cases no fixture tree can hold ----------------------------------------------

;; Git keeps no empty directory, and the program is told a path that need not
;; exist.
(test-equal "an empty directory holds no library"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (let ((want (refused (string-append "no library under " dir)))
           (got (run (list dir))))
       (if (equal? got want) 'refused got)))))

(test-equal "a directory that does not exist is named"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (let* ((missing (string-append dir "/no-such-directory"))
            (want (refused (string-append missing ": not a directory")))
            (got (run (list missing))))
       (if (equal? got want) 'refused got)))))

;; split-lines : String -> (Listof String)
;; TEXT's lines, each without its line feed; a last line with none is kept.
(define (split-lines text)
  (let loop ((i 0) (start 0) (found '()))
    (cond ((= i (string-length text))
           (reverse (if (< start i) (cons (substring text start i) found) found)))
          ((char=? (string-ref text i) #\newline)
           (loop (+ i 1) (+ i 1) (cons (substring text start i) found)))
          (else (loop (+ i 1) start found)))))

;; bytes-append : Bytevector ... -> Bytevector
(define (bytes-append . parts)
  (let-values (((out extract) (open-bytevector-output-port)))
    (for-each (lambda (part) (put-bytevector out part)) parts)
    (extract)))

;; Git may change a line's end or keep a trailing space as it likes, so
;; these headers are written at run time: a trailing space, a CRLF line end,
;; and a byte order mark before it. Chez reads all three.
(test-equal "rule (h): a header with a trailing space, a CR before its LF, or a byte order mark before it, is not the line #!r6rs"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (let ((write-file (lambda (name bytes)
                         (call-with-port (open-file-output-port (string-append dir "/circuit/" name))
                           (lambda (port) (put-bytevector port bytes)))))
           (library (lambda (name) (string->utf8 (string-append "(library (circuit " name
                                                                 ") (export) (import (rnrs)))\n")))))
       (capture-command (list "mkdir" (string-append dir "/circuit")))
       (write-file "a.sls" (bytes-append (string->utf8 "#!r6rs \n") (library "a")))
       (write-file "b.sls" (bytes-append (string->utf8 "#!r6rs\r\n") (library "b")))
       (write-file "c.sls" (bytes-append (u8-list->bytevector '(#xEF #xBB #xBF))
                                              (string->utf8 "#!r6rs\n") (library "c")))
       (let ((want (refused (no-header (string-append dir "/circuit/a.sls") dir)
                            (no-header (string-append dir "/circuit/b.sls") dir)
                            (no-header (string-append dir "/circuit/c.sls") dir)
                            (stray-directive (string-append dir "/circuit/c.sls") "line 1")))
             (got (run (list dir))))
         (if (equal? got want) 'refused got))))))

;; The allowlist against its whole complement: an impure library that
;; takes the allowlist's names through one only, and every other name
;; (chezscheme) exports through an only of its own. Each of those is named,
;; in order, and the allowlist's are not. The complaint names the library,
;; not the name, so the count of complaints is what holds each refused: a
;; failure answers how many there were, and any line that differs.
(define chez-allowed '(getenv port-has-port-length? port-length real-time display-condition
                       print-record parameterize))

(test-equal "rule (d): every name (chezscheme) exports but the allowlist's is refused through an only of its own; the allowlist's, beside them, are not"
  'refused-each
  (call-with-temp-directory
   (lambda (dir)
     (let* ((others (filter (lambda (n) (not (memq n chez-allowed))) (library-exports '(chezscheme))))
            (file (string-append dir "/circuit/middleware/waits.sls"))
            (complaint (string-append "check-imports: " file
                                      ": (circuit middleware waits) imports (chezscheme), " chez-tail)))
       (capture-command (list "mkdir" "-p" (string-append dir "/circuit/middleware")))
       (call-with-port (open-file-output-port file (file-options) (buffer-mode block)
                                              (make-transcoder (utf-8-codec)))
         (lambda (p)
           (put-string p "#!r6rs\n(library (circuit middleware waits)\n  (export)\n  (import (rnrs)\n")
           (put-string p "          (only (chezscheme)")
           (for-each (lambda (n) (put-char p #\space) (write n p)) chez-allowed)
           (put-string p ")\n")
           (for-each (lambda (n) (put-string p "          (only (chezscheme) ") (write n p) (put-string p ")\n"))
                     others)
           (put-string p "))\n")))
       (let* ((got (run (list dir)))
              (lines (split-lines (caddr got)))
              (odd (filter (lambda (line) (not (string=? line complaint))) lines)))
         (if (and (= (car got) 1) (string=? (cadr got) "") (= (length lines) (length others)) (null? odd)
                  (> (length others) 1000))
             'refused-each
             (list (car got) (cadr got) (length others) (length lines) odd)))))))

(test-equal "a file is no directory"
  (refused "tests/check-suites.sps: not a directory")
  (run '("tests/check-suites.sps")))

(define usage
  (list 1 "" "check-imports: usage: scheme --program tests/check-imports.sps DIR [--akku AKKU] [--jsonparse JSONPARSE] [--byte-machine BYTE-MACHINE] [LIBDIR ...]\n"))

(test-equal "no directory named: the usage line, exit 1" usage (run '()))

(test-equal "--akku with no directory after it is named, exit 1"
  (refused "--akku names no directory after it")
  (run (list (root "legal") "--akku")))

(test-equal "--akku naming no directory is named, exit 1: one that does not exist, and a file before a LIBDIR"
  (list (refused "--akku no-such-directory: not a directory")
        (refused "--akku tests/check-suites.sps: not a directory"))
  (list (run (list (root "legal") "--akku" "no-such-directory"))
        (run (list (root "legal") "--akku" "tests/check-suites.sps" "src"))))

(test-equal "--jsonparse and --byte-machine with no directory after them are named, exit 1: alone, and after another flag"
  (list (refused "--jsonparse names no directory after it")
        (refused "--byte-machine names no directory after it"))
  (list (run (list (root "legal") "--jsonparse"))
        (run (list (root "legal") "--akku" "src" "--byte-machine"))))

(test-equal "--jsonparse and --byte-machine naming no directory are named, exit 1: one that does not exist, after another flag, and a file before a LIBDIR"
  (list (refused "--jsonparse no-such-directory: not a directory")
        (refused "--byte-machine tests/check-suites.sps: not a directory"))
  (list (run (list (root "legal") "--byte-machine" "src" "--jsonparse" "no-such-directory"))
        (run (list (root "legal") "--byte-machine" "tests/check-suites.sps" "src"))))

(test-equal "a flag given twice is named, exit 1: --akku, --jsonparse with another flag between, and --byte-machine naming two directories"
  (list (refused "--akku is given twice, and a flag is given at most once")
        (refused "--jsonparse is given twice, and a flag is given at most once")
        (refused "--byte-machine is given twice, and a flag is given at most once"))
  (list (run (list (root "legal") "--akku" "src" "--akku" "src"))
        (run (list (root "legal") "--jsonparse" "src" "--byte-machine" "src" "--jsonparse" "src"))
        (run (list (root "legal") "--byte-machine" "src" "--byte-machine" "tests"))))

(test-equal "a directory that does not exist, named before LIBDIRs, is named"
  (refused "no-such-directory: not a directory")
  (run '("no-such-directory" "src")))

;; --- rule (j): the library path ---------------------------------------------------------

;; on-path : String String -> String
;; Rule (j)'s complaint about ENTRY, in the library directory DIR, beside ROOT.
(define (on-path dir entry root)
  (string-append dir "/" entry ": its directory is on the library path beside " root
                 ", so Chez could load a (circuit ...) library from it in place of " root
                 "'s, which this check reads; only " root " may hold one"))

;; path-ok : Natural Natural -> (List 0 String "")
;; A pass with LIBDIRs named: the tree's line, then how many it looked in.
(define (path-ok libraries looked)
  (list 0
        (string-append "check-imports: ok, libraries checked: " (number->string libraries) "\n"
                       "check-imports: ok, no other directory on the library path holds circuit: "
                       (number->string looked) " looked in\n")
        ""))

;; make-tree : String (Listof String) -> Unspecified
;; Under DIR, each of PATHS: a file, or a directory when it ends with /.
(define (make-tree dir paths)
  (for-each (lambda (path)
              (let ((full (string-append dir "/" path)))
                (if (char=? (string-ref path (- (string-length path) 1)) #\/)
                    (capture-command (list "mkdir" "-p" full))
                    (begin
                      (capture-command (list "mkdir" "-p" (dirname full)))
                      (call-with-port (open-file-output-port full)
                        (lambda (p) (put-bytevector p (string->utf8 "#!r6rs\n"))))))))
            paths))

;; dirname : String -> String
(define (dirname path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) ".")
          ((char=? (string-ref path i) #\/) (substring path 0 i))
          (else (loop (- i 1))))))

;; Every name Chez could take a (circuit ...) library from: the directory,
;; a library file under each extension, source and compiled, and a link to
;; a directory. Beside them, names that only begin with circuit's letters.
(test-equal "rule (j): each library directory but DIR that holds circuit, or circuit.<anything>, is named, entry by entry, in the order the directories are named"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("a/circuit/request.sls" "b/circuit.sls" "b/circuit.ss" "b/circuit.chezscheme.sls"
                      "b/circuit.so" "c/circuits/x.sls" "c/circuit-testing.sls" "c/circuitry.sls"
                      "c/xcircuit.sls" "d/linked/" "e/"))
     (capture-command (list "ln" "-s" (string-append dir "/d/linked") (string-append dir "/e/circuit")))
     (let* ((at (lambda (d) (string-append dir "/" d)))
            (want (refused (on-path (at "b") "circuit.chezscheme.sls" (root "legal"))
                           (on-path (at "b") "circuit.sls" (root "legal"))
                           (on-path (at "b") "circuit.so" (root "legal"))
                           (on-path (at "b") "circuit.ss" (root "legal"))
                           (on-path (at "a") "circuit" (root "legal"))
                           (on-path (at "e") "circuit" (root "legal"))))
            (got (run (list (root "legal") (at "b") (at "c") (at "a") (at "e") (at "d")))))
       (if (equal? got want) 'refused got)))))

(test-equal "rule (j): DIR itself, a LIBDIR that does not exist, a file, and names that only begin with circuit's letters pass, and the pass names how many it looked in"
  'passed
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("c/circuits/x.sls" "c/circuit-testing.sls" "c/circuitry.sls" "c/xcircuit.sls"
                      "f/plain.sls"))
     (let* ((at (lambda (d) (string-append dir "/" d)))
            (want (path-ok 6 2))
            (got (run (list (root "legal") (at "c") (root "legal") (string-append (root "legal") "/")
                            (at "no-such") (at "f/plain.sls") (at "f")))))
       (if (equal? got want) 'passed got)))))

(test-equal "rule (j): with no LIBDIR the pass is the tree's line alone"
  (ok 6)
  (run (list (root "legal"))))

;; A Mac's default disk finds a name in any case, so Chez there would take
;; (circuit request) from Circuit/request.sls, and (circuit) from
;; CIRCUIT.sls.
(test-equal "rule (j): circuit's names in any case are named; names in another case that only begin with its letters are not"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("g/Circuit/request.sls" "g/CIRCUIT.sls" "g/cIrCuIt.Ss" "g/Circuits/x.sls"
                      "g/CIRCUIT-TESTING.sls" "g/CIRCUITRY.SLS"))
     (let* ((g (string-append dir "/g"))
            (want (refused (on-path g "CIRCUIT.sls" (root "legal"))
                           (on-path g "Circuit" (root "legal"))
                           (on-path g "cIrCuIt.Ss" (root "legal"))))
            (got (run (list (root "legal") g))))
       (if (equal? got want) 'refused got)))))

;; listing-error : String -> String
;; What Chez raises listing the directory DIR, shown by describe, as the
;; program shows it: the running Chez's words. A listing that raises
;; nothing answers words no complaint holds, so its row fails.
(define (listing-error dir)
  (guard (e (#t (describe e)))
    (directory-list dir)
    "<the directory was listed, with no raise>"))

;; A directory of mode 000 can't be listed but by root, which neither CI
;; nor the container runs as. Its mode is given back before the directory
;; is removed.
(test-equal "rule (j): a library directory it cannot list is named, with Chez's words for why, and the audit fails closed"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (let* ((h (string-append dir "/h"))
            (made (begin (make-tree dir '("h/")) (capture-command (list "chmod" "000" h))))
            (why (listing-error h))
            (got (run (list (root "legal") h)))
            (restored (capture-command (list "chmod" "755" h)))
            (want (refused (string-append h ": it is on the library path beside " (root "legal")
                                          ", and cannot be listed, so this check cannot tell whether it holds a (circuit ...) library: "
                                          why))))
       (if (and (equal? got want) (= (car made) 0) (= (car restored) 0)) 'refused (list made got))))))

;; --- rule (l): compiled objects ---------------------------------------------------------
;; Git keeps no .so here (.gitignore), so these trees are hashing-legal's,
;; copied, with objects beside them.

;; with-legal-copy : (String -> Any) -> Any
;; PROC on a copy of the fixture hashing-legal, in a directory of its own.
(define (with-legal-copy proc)
  (call-with-temp-directory
   (lambda (dir)
     (let ((copy (string-append dir "/legal")))
       (capture-command (list "cp" "-R" (root "hashing-legal") copy))
       (proc copy)))))

(test-equal "rule (l): a compiled object beside each library's source is named, as Chez could load it unread; one beside a file the closure does not hold is not"
  'refused
  (with-legal-copy
   (lambda (copy)
     (let* ((at (lambda (name) (string-append copy "/akku/hashing/" name)))
            (made (begin (make-tree copy '("akku/hashing/sha-2.so" "akku/hashing/fixnums.so"
                                           "akku/hashing/hmac.so" "akku/hashing/md5.so"))
                         'made))
            (want (refused (compiled (at "sha-2.so") "(hashing sha-2)")
                           (compiled (at "fixnums.so") "(hashing fixnums)")
                           (compiled (at "hmac.so") "(hashing hmac)")))
            (got (run (list (string-append copy "/src") "--akku" (string-append copy "/akku")))))
       (if (and (eq? made 'made) (equal? got want)) 'refused got)))))

(test-equal "rule (l): a compiled object with no source beside it is named, and so is the missing source"
  'refused
  (with-legal-copy
   (lambda (copy)
     (let* ((akku (string-append copy "/akku"))
            (removed (capture-command (list "rm" (string-append akku "/hashing/hmac.scm"))))
            (made (begin (make-tree copy '("akku/hashing/hmac.so")) 'made))
            (want (refused (not-found akku "(hashing hmac)")
                           (compiled (string-append akku "/hashing/hmac.so") "(hashing hmac)")))
            (got (run (list (string-append copy "/src") "--akku" akku))))
       (if (and (= (car removed) 0) (eq? made 'made) (equal? got want)) 'refused (list removed got))))))

;; --- rule (m): no other hashing on the library path -------------------------------------

;; Every name Chez could take a (hashing ...) library from: the directory,
;; a library file under each extension, source and compiled, and a link to
;; a directory. Beside them, names that only begin with hashing's letters,
;; and AKKU, named again among the LIBDIRs, which holds hashing.
(test-equal "rule (m): each library directory but DIR and AKKU that holds hashing, or hashing.<anything>, is named, entry by entry, in the order the directories are named"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("akku/hashing/sha-2.scm" "akku/hashing.sha256"
                      "a/hashing/sha-2.scm" "b/hashing.sls" "b/hashing.ss" "b/hashing.chezscheme.sls"
                      "b/hashing.so" "b/hashing.scm" "b/hashing.sch" "c/hashings/x.sls"
                      "c/hashing-extras.sls" "c/hashingx.sls" "c/xhashing.sls" "c/sha-2.scm" "d/linked/" "e/"))
     (capture-command (list "ln" "-s" (string-append dir "/d/linked") (string-append dir "/e/hashing")))
     (let* ((at (lambda (d) (string-append dir "/" d)))
            (akku (at "akku"))
            (want (refused (on-hashing-path (at "b") "hashing.chezscheme.sls" akku)
                           (on-hashing-path (at "b") "hashing.sch" akku)
                           (on-hashing-path (at "b") "hashing.scm" akku)
                           (on-hashing-path (at "b") "hashing.sls" akku)
                           (on-hashing-path (at "b") "hashing.so" akku)
                           (on-hashing-path (at "b") "hashing.ss" akku)
                           (on-hashing-path (at "a") "hashing" akku)
                           (on-hashing-path (at "e") "hashing" akku)))
            (got (run (list (root "legal") "--akku" akku (at "b") (at "c") (at "a") akku (at "e") (at "d")))))
       (if (equal? got want) 'refused got)))))

;; A Mac's default disk finds a name in any case, so Chez there would take
;; (hashing sha-2) from Hashing/sha-2.scm, and (hashing) from HASHING.scm.
(test-equal "rule (m): hashing's names in any case are named; names in another case that only begin with its letters are not"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("akku/hashing/sha-2.scm" "g/Hashing/sha-2.scm" "g/HASHING.scm" "g/hAsHiNg.Ss"
                      "g/Hashings/x.sls" "g/HASHING-EXTRAS.sls" "g/HASHINGX.SLS"))
     (let* ((g (string-append dir "/g"))
            (akku (string-append dir "/akku"))
            (want (refused (on-hashing-path g "HASHING.scm" akku)
                           (on-hashing-path g "Hashing" akku)
                           (on-hashing-path g "hAsHiNg.Ss" akku)))
            (got (run (list (root "legal") "--akku" akku g))))
       (if (equal? got want) 'refused got)))))

(test-equal "rule (m): with no --akku, every library directory that holds hashing is named, the one --akku would name among them"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("akku/hashing/sha-2.scm" "b/hashing.sls" "c/hashings/x.sls"))
     (let* ((at (lambda (d) (string-append dir "/" d)))
            (want (refused (on-hashing-path (at "akku") "hashing" #f)
                           (on-hashing-path (at "b") "hashing.sls" #f)))
            (got (run (list (root "legal") (at "akku") (at "c") (at "b")))))
       (if (equal? got want) 'refused got)))))

(test-equal "rule (m): DIR, AKKU named again with a slash and without, a LIBDIR that does not exist, a file, and names that only begin with hashing's letters pass, and the pass names how many rules (j) and (m) looked in"
  'passed
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("akku/hashing/sha-2.scm" "akku/hashing.sha256" "c/hashings/x.sls"
                      "c/hashing-extras.sls" "c/hashingx.sls" "c/xhashing.sls" "c/sha-2.scm" "f/plain.sls"))
     (let* ((at (lambda (d) (string-append dir "/" d)))
            (want (passed 6 4 #f 2))
            (got (run (list (root "legal") "--akku" (at "akku") (at "akku") (at "c") (root "legal")
                            (string-append (at "akku") "/") (at "no-such") (at "f/plain.sls") (at "f")))))
       (if (equal? got want) 'passed got)))))

(test-equal "rule (m): with --akku and no LIBDIR, the pass is the tree's line and rule (m)'s, which looked in none"
  (passed 6 #f #f 0)
  (run (list (root "legal") "--akku" (at "hashing-legal" "akku"))))

(test-equal "rule (j) holds AKKU as it holds any library directory: a circuit there is named, and its hashing is not"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("akku/hashing/sha-2.scm" "akku/circuit/request.sls"))
     (let* ((akku (string-append dir "/akku"))
            (want (refused (on-path akku "circuit" (root "legal"))))
            (got (run (list (root "legal") "--akku" akku akku))))
       (if (equal? got want) 'refused got)))))

;; --- rule (o): compiled objects ---------------------------------------------------------
;; As rule (l)'s: Git keeps no .so here, so these trees are jsonparse-legal's,
;; copied, with objects beside them.

;; with-jsonparse-copy : (String String String -> Any) -> Any
;; PROC on a copy of the fixture jsonparse-legal, in a directory of its own:
;; its src/, JSONPARSE and BYTE-MACHINE.
(define (with-jsonparse-copy proc)
  (call-with-temp-directory
   (lambda (dir)
     (let ((copy (string-append dir "/legal")))
       (capture-command (list "cp" "-R" (root "jsonparse-legal") copy))
       (proc (string-append copy "/src") (string-append copy "/jsonparse")
             (string-append copy "/byte-machine"))))))

(test-equal "rule (o): a compiled object beside a jsonparse library's source, beside (generated jsonparse)'s and beside a byte-machine library's is named, as Chez could load it unread; one beside a file the closure does not hold is not"
  'refused
  (with-jsonparse-copy
   (lambda (src jsonparse byte-machine)
     (let* ((made (begin (make-tree jsonparse '("jsonparse/easy.so" "generated/jsonparse.so"))
                         (make-tree byte-machine '("byte-machine/runtime.so" "byte-machine/compile.so"))
                         'made))
            (want (refused (compiled (string-append jsonparse "/jsonparse/easy.so") "(jsonparse easy)")
                           (compiled (string-append byte-machine "/byte-machine/runtime.so")
                                     "(byte-machine runtime)")
                           (compiled (string-append jsonparse "/generated/jsonparse.so")
                                     "(generated jsonparse)")))
            (got (run (list src "--jsonparse" jsonparse "--byte-machine" byte-machine))))
       (if (and (eq? made 'made) (equal? got want)) 'refused got)))))

(test-equal "rule (o): a compiled object with no source beside it is named, and so is the missing source"
  'refused
  (with-jsonparse-copy
   (lambda (src jsonparse byte-machine)
     (let* ((removed (capture-command (list "rm" (string-append byte-machine "/byte-machine/private/names.sls"))))
            (made (begin (make-tree byte-machine '("byte-machine/private/names.so")) 'made))
            (want (refused (not-found-in jsonparse byte-machine "(byte-machine private names)")
                           (compiled (string-append byte-machine "/byte-machine/private/names.so")
                                     "(byte-machine private names)")))
            (got (run (list src "--jsonparse" jsonparse "--byte-machine" byte-machine))))
       (if (and (= (car removed) 0) (eq? made 'made) (equal? got want)) 'refused (list removed got))))))

(test-equal "rule (o): a compiled (generated jsonparse) in BYTE-MACHINE, which Chez looks in first, is the file Chez takes, over JSONPARSE's source, and both are named; a compiled (byte-machine runtime) in JSONPARSE, behind BYTE-MACHINE's source, is not"
  'refused
  (with-jsonparse-copy
   (lambda (src jsonparse byte-machine)
     (let* ((made (begin (make-tree byte-machine '("generated/jsonparse.so"))
                         (make-tree jsonparse '("byte-machine/runtime.so"))
                         'made))
            (want (refused (not-found-in jsonparse byte-machine "(generated jsonparse)")
                           (compiled (string-append byte-machine "/generated/jsonparse.so")
                                     "(generated jsonparse)")))
            (got (run (list src "--jsonparse" jsonparse "--byte-machine" byte-machine))))
       (if (and (eq? made 'made) (equal? got want)) 'refused got)))))

;; --- rule (p): one jsonparse and one byte-machine on the library path ------------------

;; Every name Chez could take a (jsonparse ...) library from, and every one
;; in a generated directory it could take (generated jsonparse) from: the
;; directory, a library file under each extension, source and compiled, and
;; a link to a directory, a generated one among them. Beside them, names
;; that only begin with jsonparse's or generated's letters, and JSONPARSE
;; and BYTE-MACHINE, named again among the LIBDIRs.
(test-equal "rule (p): each library directory but DIR and JSONPARSE that holds jsonparse, or jsonparse.<anything>, or whose generated directory does, is named, entry by entry, in the order the directories are named"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("jp/jsonparse/easy.sls" "jp/generated/jsonparse.sls" "bm/byte-machine/runtime.sls"
                      "a/jsonparse/easy.sls"
                      "b/jsonparse.sls" "b/jsonparse.ss" "b/jsonparse.chezscheme.sls" "b/jsonparse.so"
                      "b/jsonparse.scm" "b/jsonparse.sch"
                      "b/generated/jsonparse.sls" "b/generated/jsonparse.so" "b/generated/jsonparse/x.sls"
                      "c/jsonparser.sls" "c/jsonparse-extras.sls" "c/xjsonparse.sls" "c/jsonparses/x.sls"
                      "c/easy.sls" "c/generated.sls" "c/generated/jsonparse-machine.sls"
                      "c/generated/httparse-message.sls" "c/generators/jsonparse.sls"
                      "d/linked/" "e/" "f/" "g/jsonparse.sls"))
     (capture-command (list "ln" "-s" (string-append dir "/d/linked") (string-append dir "/e/jsonparse")))
     (capture-command (list "ln" "-s" (string-append dir "/g") (string-append dir "/f/generated")))
     (let* ((at (lambda (d) (string-append dir "/" d)))
            (jp (at "jp"))
            (want (refused (on-jsonparse-path (at "b") "jsonparse.chezscheme.sls" jp)
                           (on-jsonparse-path (at "b") "jsonparse.sch" jp)
                           (on-jsonparse-path (at "b") "jsonparse.scm" jp)
                           (on-jsonparse-path (at "b") "jsonparse.sls" jp)
                           (on-jsonparse-path (at "b") "jsonparse.so" jp)
                           (on-jsonparse-path (at "b") "jsonparse.ss" jp)
                           (on-jsonparse-path (at "a") "jsonparse" jp)
                           (on-jsonparse-path (at "e") "jsonparse" jp)
                           (on-generated-path (at "b") "generated" "jsonparse" jp)
                           (on-generated-path (at "b") "generated" "jsonparse.sls" jp)
                           (on-generated-path (at "b") "generated" "jsonparse.so" jp)
                           (on-generated-path (at "f") "generated" "jsonparse.sls" jp)))
            (got (run (list (root "legal") "--jsonparse" jp "--byte-machine" (at "bm")
                            (at "b") (at "c") (at "a") jp (at "e") (at "bm") (at "d") (at "f")))))
       (if (equal? got want) 'refused got)))))

(test-equal "rule (p): each library directory but DIR and BYTE-MACHINE that holds byte-machine, or byte-machine.<anything>, is named, entry by entry, in the order the directories are named"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("bm/byte-machine/runtime.sls" "jp/jsonparse/easy.sls" "jp/generated/jsonparse.sls"
                      "a/byte-machine/runtime.sls"
                      "b/byte-machine.sls" "b/byte-machine.ss" "b/byte-machine.so" "b/byte-machine.chezscheme.sls"
                      "c/byte-machines/x.sls" "c/byte-machine-extras.sls" "c/byte-machinery.sls"
                      "c/bytemachine.sls" "c/byte.sls" "c/machine.sls" "c/generated/byte-machine.sls"))
     (let* ((at (lambda (d) (string-append dir "/" d)))
            (bm (at "bm"))
            (want (refused (on-byte-machine-path (at "b") "byte-machine.chezscheme.sls" bm)
                           (on-byte-machine-path (at "b") "byte-machine.sls" bm)
                           (on-byte-machine-path (at "b") "byte-machine.so" bm)
                           (on-byte-machine-path (at "b") "byte-machine.ss" bm)
                           (on-byte-machine-path (at "a") "byte-machine" bm)))
            (got (run (list (root "legal") "--byte-machine" bm "--jsonparse" (at "jp")
                            (at "b") (at "c") (at "a") bm (at "jp")))))
       (if (equal? got want) 'refused got)))))

;; A Mac's default disk finds a name in any case, so Chez there would take
;; (jsonparse easy) from Jsonparse/easy.sls, (generated jsonparse) from
;; Generated/jsonparse.sls, and (byte-machine) from BYTE-MACHINE.so.
;; Generated and GENERATED are in directories of their own: macOS's file
;; system ignores case by default, so in one they would be one directory.
(test-equal "rule (p): jsonparse's, generated's and byte-machine's names in any case are named; names in another case that only begin with their letters are not"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("jp/" "bm/" "g/Jsonparse/easy.sls" "g/JSONPARSE.sls" "g/jSoNpArSe.Ss" "g/JSONPARSER.SLS"
                      "g/Generated/jsonparse.sls" "h/GENERATED/JsonParse.so" "h/GENERATED/JSONPARSE-MACHINE.sls"
                      "g/Byte-Machine/runtime.sls" "g/BYTE-MACHINE.so" "g/Byte-Machinery.sls"))
     (let* ((g (string-append dir "/g"))
            (h (string-append dir "/h"))
            (jp (string-append dir "/jp"))
            (bm (string-append dir "/bm"))
            (want (refused (on-jsonparse-path g "JSONPARSE.sls" jp)
                           (on-jsonparse-path g "Jsonparse" jp)
                           (on-jsonparse-path g "jSoNpArSe.Ss" jp)
                           (on-generated-path g "Generated" "jsonparse.sls" jp)
                           (on-generated-path h "GENERATED" "JsonParse.so" jp)
                           (on-byte-machine-path g "BYTE-MACHINE.so" bm)
                           (on-byte-machine-path g "Byte-Machine" bm)))
            (got (run (list (root "legal") "--jsonparse" jp "--byte-machine" bm g h))))
       (if (equal? got want) 'refused got)))))

(test-equal "rule (p): with no --jsonparse and no --byte-machine, every library directory that holds jsonparse, (generated jsonparse) or byte-machine is named, the ones the flags would name among them"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("jp/jsonparse/easy.sls" "jp/generated/jsonparse.sls" "bm/byte-machine/runtime.sls"
                      "b/jsonparse.sls" "b/byte-machine.sls" "c/jsonparses/x.sls"))
     (let* ((at (lambda (d) (string-append dir "/" d)))
            (want (refused (on-jsonparse-path (at "jp") "jsonparse" #f)
                           (on-jsonparse-path (at "b") "jsonparse.sls" #f)
                           (on-generated-path (at "jp") "generated" "jsonparse.sls" #f)
                           (on-byte-machine-path (at "b") "byte-machine.sls" #f)
                           (on-byte-machine-path (at "bm") "byte-machine" #f)))
            (got (run (list (root "legal") (at "jp") (at "c") (at "b") (at "bm")))))
       (if (equal? got want) 'refused got)))))

;; Mode 000, as rule (j)'s row: its mode is given back before the directory
;; is removed.
(test-equal "rule (p): a generated directory it cannot list is named, with Chez's words for why, and the audit fails closed"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (let* ((h (string-append dir "/h"))
            (generated (string-append h "/generated"))
            (made (begin (make-tree dir '("h/generated/")) (capture-command (list "chmod" "000" generated))))
            (why (listing-error generated))
            (got (run (list (root "legal") h)))
            (restored (capture-command (list "chmod" "755" generated)))
            (want (refused (string-append generated ": it is in " h
                                          ", which is on the library path, and cannot be listed, so this check cannot tell whether it holds a (generated jsonparse ...) library: "
                                          why))))
       (if (and (equal? got want) (= (car made) 0) (= (car restored) 0)) 'refused (list made got))))))

(test-equal "rule (p): DIR, JSONPARSE and BYTE-MACHINE named again with a slash and without, a LIBDIR that does not exist, a file, and names that only begin with jsonparse's, generated's and byte-machine's letters pass, and the pass names how many rules (j) and (p) looked in"
  'passed
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("jp/jsonparse/easy.sls" "jp/generated/jsonparse.sls" "bm/byte-machine/runtime.sls"
                      "c/jsonparser.sls" "c/jsonparse-extras.sls" "c/generated/httparse-message.sls"
                      "c/generated/jsonparse-machine.sls" "c/generators/jsonparse.sls" "c/byte-machinery.sls"
                      "c/byte-machine-extras.sls" "f/plain.sls"))
     (let* ((at (lambda (d) (string-append dir "/" d)))
            (want (passed 6 6 #f #f #f 4 4))
            (got (run (list (root "legal") "--jsonparse" (at "jp") "--byte-machine" (at "bm")
                            (at "jp") (at "bm") (at "c") (root "legal") (string-append (at "jp") "/")
                            (string-append (at "bm") "/") (at "no-such") (at "f/plain.sls") (at "f")))))
       (if (equal? got want) 'passed got)))))

(test-equal "rule (p): with --jsonparse and --byte-machine and no LIBDIR, the pass is the tree's line and rule (p)'s, which looked in none"
  (passed 6 #f #f #f #f 0 0)
  (run (list (root "legal") "--jsonparse" (at "jsonparse-legal" "jsonparse")
             "--byte-machine" (at "jsonparse-legal" "byte-machine"))))

(test-equal "rules (j) and (m) hold JSONPARSE and BYTE-MACHINE as they hold any library directory: a circuit and a hashing there are named, and their jsonparse and byte-machine are not"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("jp/jsonparse/easy.sls" "jp/generated/jsonparse.sls" "jp/circuit/request.sls"
                      "bm/byte-machine/runtime.sls" "bm/hashing/sha-2.scm"))
     (let* ((jp (string-append dir "/jp"))
            (bm (string-append dir "/bm"))
            (want (refused (on-path jp "circuit" (root "legal"))
                           (on-hashing-path bm "hashing" #f)))
            (got (run (list (root "legal") "--jsonparse" jp "--byte-machine" bm jp bm))))
       (if (equal? got want) 'refused got)))))

;; The Makefile names both closure directories by flag and among the
;; LIBDIRs. Rule (p) holds each to its own family there too, so neither can
;; hold a copy that stands in for the other's: BYTE-MACHINE's jsonparse,
;; which rule (o) reads before JSONPARSE's, and JSONPARSE's byte-machine.
(test-equal "rule (p): BYTE-MACHINE and JSONPARSE, named by their flags and among the LIBDIRs, each holding the other's library: BYTE-MACHINE's jsonparse and generated/jsonparse.sls, which this check reads before JSONPARSE's, and JSONPARSE's byte-machine are each named"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (make-tree dir '("jp/jsonparse/easy.sls" "jp/generated/jsonparse.sls" "jp/byte-machine/runtime.sls"
                      "bm/byte-machine/runtime.sls" "bm/jsonparse/easy.sls" "bm/generated/jsonparse.sls"))
     (let* ((jp (string-append dir "/jp"))
            (bm (string-append dir "/bm"))
            (want (refused (on-jsonparse-path-ahead bm "jsonparse" jp)
                           (on-generated-path-ahead bm "generated" "jsonparse.sls" jp)
                           (on-byte-machine-path jp "byte-machine" bm)))
            (got (run (list (root "legal") "--jsonparse" jp "--byte-machine" bm bm jp))))
       (if (equal? got want) 'refused got)))))

;; make-check-imports : String -> (List Integer String String)
;; make check-imports, in a make of its own, with BUILD_DIR at BUILD: its
;; scheme-libs, where deps links SRFI-64, is then a directory of every
;; library path the Makefile builds. The make line that names the failed
;; target is written as make 3.81 writes it, without the Makefile's line,
;; which make 4 adds.
(define (make-check-imports build)
  (let ((got (capture-command (list "env" "-u" "MAKEFLAGS" "-u" "MAKELEVEL" "-u" "MFLAGS"
                                    "make" "--no-print-directory" "check-imports"
                                    (string-append "BUILD_DIR=" build)))))
    (list (car got) (cadr got) (without-make-line (caddr got)))))

;; without-make-line : String -> String
;; TEXT with "Makefile:N: " cut from each line that begins "make: *** [".
(define (without-make-line text)
  (let ((head "make: *** [Makefile:"))
    (apply string-append
           (map (lambda (line)
                  (string-append
                   (if (and (>= (string-length line) (string-length head))
                            (string=? (substring line 0 (string-length head)) head))
                       (let loop ((i (string-length head)))
                         (cond ((>= i (string-length line)) line)
                               ((char=? (string-ref line i) #\:)
                                (string-append "make: *** ["
                                               (substring line (min (string-length line) (+ i 2))
                                                          (string-length line))))
                               (else (loop (+ i 1)))))
                       line)
                   "\n"))
                (split-lines text)))))

;; begins? : String String -> Boolean
(define (begins? text head)
  (and (>= (string-length text) (string-length head))
       (string=? (substring text 0 (string-length head)) head)))

;; looked-in : String String -> (U Natural #f)
;; How many directories LINE, a pass's rule (j), (m) or (p) line for FAMILY,
;; says it looked in; #f when it is no such line.
(define (looked-in line family)
  (let ((head (string-append "check-imports: ok, no other directory on the library path holds "
                             family ": "))
        (tail " looked in"))
    (and (begins? line head)
         (> (string-length line) (+ (string-length head) (string-length tail)))
         (string=? (substring line (- (string-length line) (string-length tail)) (string-length line))
                   tail)
         (let ((n (string->number (substring line (string-length head)
                                             (- (string-length line) (string-length tail))))))
           (and (integer? n) (exact? n) (>= n 0) n)))))

;; make-closure-line : String
;; Rule (l)'s pass line through make, on the pinned hashing in vendor/akku.
(define make-closure-line
  "check-imports: ok, the closure of (hashing sha-2) in vendor/akku imports only the (rnrs ...) libraries except (rnrs eval), (hashing fixnums) and (hashing hmac): 3 libraries read")

;; make-jsonparse-closure-line : String
;; Rule (o)'s pass line through make, on the pinned jsonparse's src/ and
;; the byte-machine chez-httparse pins.
(define make-jsonparse-closure-line
  (string-append "check-imports: ok, the closure of (jsonparse easy) in vendor/jsonparse/src and vendor/chez-http-server/vendor/chez-httparse/vendor/byte-machine/src imports only "
                 jsonparse-allows ": 12 libraries read"))

;; The Makefile's wiring: check-imports passes the audit every directory
;; of the library paths, so a (circuit ...) library in one of them, here
;; the scheme-libs of a BUILD_DIR of the row's own, fails make
;; check-imports, and the same tree without it passes. The pass reads
;; hashing's closure from vendor/akku and jsonparse's from jsonparse's src/
;; and byte-machine's, and rules (m) and (p) look in every directory rule
;; (j) does but their own.
(test-equal "rule (j), through make: a circuit/ in a directory of the library path fails make check-imports, and without it the audit passes"
  'refused-then-passed
  (call-with-temp-directory
   (lambda (dir)
     (let* ((build (string-append dir "/build"))
            (libs (string-append build "/scheme-libs"))
            (deps-line (string-append "deps: chez-libuv's shim built; vendor/chez-http-server/vendor/chez-srfi linked into "
                                      libs "/srfi\n"))
            (passed (make-check-imports build))
            (planted (begin (make-tree build '("scheme-libs/circuit/request.sls"))
                            (make-check-imports build)))
            (want-planted (list 2 deps-line
                                (string-append "check-imports: " (on-path libs "circuit" "src") "\n"
                                               "make: *** [check-imports] Error 1\n")))
            (passed-lines (split-lines (cadr passed)))
            (whole? (= (length passed-lines) 8))
            (circuit-looked (and whole? (looked-in (list-ref passed-lines 2) "circuit")))
            (hashing-looked (and whole? (looked-in (list-ref passed-lines 4) "hashing")))
            (jsonparse-looked (and whole? (looked-in (list-ref passed-lines 6) "jsonparse")))
            (byte-machine-looked (and whole? (looked-in (list-ref passed-lines 7) "byte-machine"))))
       (if (and (equal? planted want-planted)
                (= (car passed) 0)
                (string=? (caddr passed) "")
                whole?
                (string=? (string-append (car passed-lines) "\n") deps-line)
                (begins? (cadr passed-lines) "check-imports: ok, libraries checked: ")
                circuit-looked
                (string=? (list-ref passed-lines 3) make-closure-line)
                hashing-looked
                (= hashing-looked (- circuit-looked 1))
                (string=? (list-ref passed-lines 5) make-jsonparse-closure-line)
                jsonparse-looked
                (= jsonparse-looked (- circuit-looked 1))
                byte-machine-looked
                (= byte-machine-looked (- circuit-looked 1)))
           'refused-then-passed
           (list 'passed passed 'planted planted))))))

;; The Makefile names vendor/akku twice: by --akku, and among the library
;; path's directories. So a hashing/ in another of them fails make
;; check-imports, while vendor/akku's own is passed over.
(test-equal "rule (m), through make: a hashing/ in a directory of the library path but vendor/akku fails make check-imports"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (let* ((build (string-append dir "/build"))
            (libs (string-append build "/scheme-libs"))
            (deps-line (string-append "deps: chez-libuv's shim built; vendor/chez-http-server/vendor/chez-srfi linked into "
                                      libs "/srfi\n"))
            (planted (begin (make-tree build '("scheme-libs/hashing/sha-2.scm"))
                            (make-check-imports build)))
            (want (list 2 deps-line
                        (string-append "check-imports: " (on-hashing-path libs "hashing" "vendor/akku") "\n"
                                       "make: *** [check-imports] Error 1\n"))))
       (if (equal? planted want) 'refused planted)))))

;; The Makefile names jsonparse's src/ and byte-machine's twice: by flag,
;; and among the library path's directories. So a jsonparse/, a
;; generated/jsonparse.sls or a byte-machine/ in another of them fails make
;; check-imports, while their own are passed over.
(test-equal "rule (p), through make: a jsonparse/, a generated/jsonparse.sls and a byte-machine/ in a directory of the library path but their own fail make check-imports"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (let* ((build (string-append dir "/build"))
            (libs (string-append build "/scheme-libs"))
            (deps-line (string-append "deps: chez-libuv's shim built; vendor/chez-http-server/vendor/chez-srfi linked into "
                                      libs "/srfi\n"))
            (planted (begin (make-tree build '("scheme-libs/jsonparse/easy.sls" "scheme-libs/generated/jsonparse.sls"
                                               "scheme-libs/byte-machine/runtime.sls"))
                            (make-check-imports build)))
            (want (list 2 deps-line
                        (string-append "check-imports: " (on-jsonparse-path libs "jsonparse" "vendor/jsonparse/src") "\n"
                                       "check-imports: "
                                       (on-generated-path libs "generated" "jsonparse.sls" "vendor/jsonparse/src") "\n"
                                       "check-imports: "
                                       (on-byte-machine-path libs "byte-machine"
                                                             "vendor/chez-http-server/vendor/chez-httparse/vendor/byte-machine/src")
                                       "\n"
                                       "make: *** [check-imports] Error 1\n"))))
       (if (equal? planted want) 'refused planted)))))

;; --- the lists the program holds are exact ---------------------------------------------
;; The program's lists are read from it as data, never from its output.

;; read-forms : String -> (Listof Any)
(define (read-forms path)
  (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                        (make-transcoder (utf-8-codec)))
    (lambda (port)
      (let loop ((found '()))
        (let ((datum (read port)))
          (if (eof-object? datum) (reverse found) (loop (cons datum found))))))))

;; declared : Symbol -> Any
;; What the program's (define NAME '(...)) lists.
(define (declared name)
  (guard (e (#t (list 'unreadable (describe e))))
    (let ((form (find (lambda (form)
                        (and (pair? form) (eq? (car form) 'define)
                             (pair? (cdr form)) (eq? (cadr form) name)))
                      (read-forms program))))
      (if form (cadr (caddr form)) '(not-defined)))))

;; written : Any -> String
(define (written x) (call-with-string-output-port (lambda (p) (write x p))))

;; sorted-libraries : Any -> Any
;; NAMES, a list of library names, sorted as written; (unsortable NAMES) when
;; it is no list of lists. SRFI-64 does not catch a raise in an expected
;; expression, so neither side may raise.
(define (sorted-libraries names)
  (guard (e (#t (list 'unsortable names)))
    (list-sort (lambda (a b) (string<? (written a) (written b))) names)))

(test-equal "rnrs-libraries is the (rnrs ...) libraries this Chez has, but (rnrs eval)"
  (sorted-libraries
   (filter (lambda (name)
             (and (pair? name) (eq? (car name) 'rnrs) (not (equal? name '(rnrs eval)))))
           (library-list)))
  (sorted-libraries (declared 'rnrs-libraries)))

(test-equal "the impure libraries are exactly (circuit http-server) and (circuit middleware waits)"
  (sorted-libraries '((circuit http-server) (circuit middleware waits)))
  (sorted-libraries (declared 'impure)))

(test-equal "the one library that may import (websocket) is exactly (circuit websocket)"
  '(circuit websocket)
  (declared 'websocket-library))

(test-equal "the one library that may import a (hashing ...) library is exactly (circuit session)"
  '(circuit session)
  (declared 'session-library))

(test-equal "the one (hashing ...) library (circuit session) may import is exactly (hashing sha-2)"
  '(hashing sha-2)
  (declared 'hashing-library))

(test-equal "the (hashing ...) libraries the closure may import are exactly (hashing fixnums) and (hashing hmac)"
  (sorted-libraries '((hashing fixnums) (hashing hmac)))
  (sorted-libraries (declared 'hashing-siblings)))

(test-equal "the one library that may import a (jsonparse ...) library is exactly (circuit json)"
  '(circuit json)
  (declared 'json-library))

(test-equal "the one (jsonparse ...) library (circuit json) may import is exactly (jsonparse easy)"
  '(jsonparse easy)
  (declared 'jsonparse-library))

(test-equal "the libraries the closure of (jsonparse easy) may import are exactly jsonparse's seven others, (generated jsonparse), (byte-machine runtime) and byte-machine's two private libraries"
  (sorted-libraries '((jsonparse error) (jsonparse options) (jsonparse parser) (jsonparse sequence)
                      (jsonparse string) (jsonparse tree) (jsonparse writer) (generated jsonparse)
                      (byte-machine runtime) (byte-machine private conditions) (byte-machine private names)))
  (sorted-libraries (declared 'jsonparse-siblings)))

(test-end "check-imports")

(exit (suite-exit-status runner))
