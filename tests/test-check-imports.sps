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
;;; pass say so with the program's own pass line, count included. The fixture
;;; trees are never suites: make test runs tests/test-*.sps only, which
;;; check-suites reads.
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
  "but an impure library imports (chezscheme) only through only, right around it, naming getenv, port-has-port-length?, port-length, real-time, display-condition alone: anything wider gives its body import and eval, which reach any library")

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

;; cases : (Listof (List String String Expected))
;; The fixture directory, what it holds, and the program's whole answer for it.
(define cases
  (list
   (list "legal"
         "a legal tree: core libraries and both impure ones; every wrapper over an (rnrs ...) import, nested; a version reference; getenv from (chezscheme) through only, and the (http-server ...) libraries but the private ones, in an impure library; a comment and a string that say what a library must not do; every file headed #!r6rs"
         (ok 6))
   (list "impure-chezscheme"
         "rule (d): an impure library takes from (chezscheme) only getenv, port-has-port-length?, port-length, real-time and display-condition, through only right around it: bare, eval, getenv with import, call/1cc, except, prefix, rename, for, library, only around for, and only around a wider only are named; prefix, rename and for around the narrow only, only around (library (chezscheme)), and a version reference are not"
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
         "rule (d): both impure libraries take real-time and display-condition from (chezscheme), with the other allowed names and without, through only right around it, bare and under prefix and rename"
         (ok 2))
   (list "impure-real-time-wider"
         "rule (d): an only beside real-time and display-condition still refuses a name off the list: current-time and cpu-time, which read clocks, condition-message, condition-continuation and display-statistics, which read or show a condition or the system, and interpret, which evaluates, are each named"
         (apply refused
                (map (lambda (i)
                       (imports "impure-real-time-wider" "circuit/middleware/waits.sls"
                                "(circuit middleware waits)" "(chezscheme)" chez-tail))
                     (iota 6))))
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
         "rule (f): a file that cannot be read as data"
         (refused (string-append (at "unreadable" "circuit/broken.sls")
                                 ": it cannot be read as data: Exception in read: unexpected end-of-file reading list before file-position 61 of #<input port "
                                 (at "unreadable" "circuit/broken.sls")
                                 ">; the character position might differ")))
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

   ;; --- rule (h): the #!r6rs line ---
   (list "header-missing"
         "rule (h): a library with no #!r6rs line, otherwise legal"
         (refused (no-header (at "header-missing" "circuit.sls") (root "header-missing"))))
   (list "header-chezscheme"
         "rule (h): the review's library, headed #!chezscheme, reading a repeat vector and an fxvector literal and importing only (rnrs)"
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

;; A fixture nothing runs guards nothing, and a case with no fixture runs on a
;; missing directory.
(test-equal "every fixture directory is a case above, and every case has its directory"
  (list-sort string<? (map car cases))
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
(define chez-allowed '(getenv port-has-port-length? port-length real-time display-condition))

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
  (list 1 "" "check-imports: usage: scheme --program tests/check-imports.sps DIR\n"))

(test-equal "no directory named: the usage line, exit 1" usage (run '()))

(test-equal "two directories named: the usage line, exit 1" usage (run '("a" "b")))

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

(test-end "check-imports")

(exit (suite-exit-status runner))
