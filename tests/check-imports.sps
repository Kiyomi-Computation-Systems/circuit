#!r6rs
;;; make check-imports: reads every file under the directory named on the
;;; command line (make passes src) as data, with Chez's reader, and evaluates
;;; nothing. It names, on stderr, each place that breaks one of these rules,
;;; with the file and the import or the problem, one line each, then exits 1:
;;;
;;;   (a) every file is a .sls holding exactly one library form, which stands
;;;       at its name's path (src/circuit/request.sls is (circuit request))
;;;       and is named (circuit ...). Any other file is named, and so is a
;;;       symbolic link to a directory, which is not followed;
;;;   (b) two libraries are impure, (circuit http-server) and
;;;       (circuit middleware waits), and one is the WebSocket library,
;;;       (circuit websocket). Every other library is core;
;;;   (c) a core library imports only the (rnrs ...) libraries except
;;;       (rnrs eval), and core (circuit ...) libraries. So it imports neither
;;;       impure library, nor (circuit websocket), nor (chezscheme), nor an
;;;       (http-server ...) or (websocket ...) library, nor anything else;
;;;   (d) an impure library may also import (chezscheme), but only through an
;;;       only right around it that names nothing but chez-names: bare, its
;;;       body would have import, eval and load, and reach any library, which
;;;       this check reads only the header to hold. And it may import the
;;;       (http-server) and (http-server NAME ...) libraries except the
;;;       (http-server private ...) ones. The other impure library is no core
;;;       library, so no library imports an impure one;
;;;   (e) an import spec is unwrapped to the library it names: through only,
;;;       except, prefix, rename and library, nested to any depth, and for,
;;;       with its import levels. A version reference, the last element of a
;;;       library reference, is dropped: it picks a version of the library the
;;;       name already picks, so it cannot make a library another one. A spec
;;;       it cannot unwrap is named, a cyclic one included;
;;;   (f) it fails closed: a directory with no library under it, a directory
;;;       that does not exist, a file it cannot read as data, and a datum that
;;;       is no library form are each named;
;;;   (g) a (circuit ...) library is imported only when a library under the
;;;       directory defines it. Chez would load any other from elsewhere on its
;;;       library path, and the suites' path holds tests/, which this check
;;;       does not read. Rule (j) closes the rest: no other directory on the
;;;       path holds one Chez could load in place of the directory's own;
;;;   (h) every .sls file begins with the line #!r6rs, and holds #! nowhere
;;;       else. Chez reads a file with no directive, or after #!chezscheme,
;;;       with its own syntax ('#3(0), '#vfx(1 2)), which R6RS lacks and the
;;;       rules above, reading only the data, never see. It fails closed:
;;;       this check cannot tell a directive from text, so a #! in a comment
;;;       or a string is refused too, and the complaint says so. The file is
;;;       read as bytes: the line is #!r6rs and a line feed, with no space,
;;;       carriage return or byte order mark;
;;;   (i) (circuit websocket) may also import (websocket), chez-websocket's
;;;       facade, and no other library may. No library may import any other
;;;       (websocket ...) library, (websocket handshake) or one under
;;;       (websocket private ...) among them. (websocket) imports the server,
;;;       so no library imports (circuit websocket), as none imports an
;;;       impure one; and (circuit websocket) imports neither (chezscheme)
;;;       nor an (http-server ...) library, as a core library doesn't
;;;       (ADR-0006);
;;;   (j) each LIBDIR named after the directory, a directory on a library
;;;       path, holds nothing named circuit or circuit.<anything>, in any
;;;       case, as a Mac's disk finds one: a directory Chez would look in
;;;       for a (circuit ...) library, or a file it would load as (circuit).
;;;       Chez takes a library from the first directory on its path that has
;;;       it, so one there could stand in for the directory's own, unread,
;;;       wherever the path puts it. A LIBDIR it cannot list is named, as
;;;       what it holds is unknown. make passes every directory of the
;;;       library paths it builds for circuit's libraries; the directory
;;;       itself, and a LIBDIR that does not exist, which holds nothing, are
;;;       passed over. A name such as circuit-testing is another library's,
;;;       and tests/fixtures/, where this check's own fixtures hold
;;;       (circuit ...) libraries, is no directory on a path;
;;;   (k) (circuit session) is a core library that may also import
;;;       (hashing sha-2), weinholt's hashing from Akku, for HMAC-SHA-256,
;;;       and no other library may import a (hashing ...) library (ADR-0008).
;;;       It imports no other (hashing ...) library, and that one only through
;;;       an only right around it, or around (library ...), naming at least
;;;       one identifier, as rule (d) reads an only: so its header names all
;;;       it takes from code circuit didn't write;
;;;   (l) when (circuit session) imports (hashing sha-2) as rule (k) lets
;;;       it, the AKKU that --akku names is read as data for that library's
;;;       closure: (hashing sha-2) and the (hashing fixnums) and (hashing
;;;       hmac) it reaches, each read once, so a cycle ends. Each is found as
;;;       Chez finds it, by Chez's own library search handler over its own
;;;       library extensions, with AKKU the one library directory: a
;;;       .chezscheme.sls, which Chez prefers to a .scm, is the file read.
;;;       The closure imports only the (rnrs ...) libraries except (rnrs
;;;       eval), and those two. It fails closed: no --akku, a library Chez
;;;       finds no source for, a compiled object Chez could load in place of
;;;       the source unread, a source it cannot read as data, a file that is
;;;       not exactly one library form of the library's name, and an import
;;;       spec it cannot read are each named. Rule (h) does not hold these
;;;       files: hashing's carry #!r6rs after a comment;
;;;   (m) as rule (j) holds circuit, each LIBDIR but the directory and AKKU
;;;       holds nothing named hashing or hashing.<anything>, in any case: one
;;;       there could stand in for the closure rule (l) reads. It holds
;;;       whether --akku is named or not, and with no --akku, every LIBDIR
;;;       holding one is named. AKKU is still a LIBDIR to rule (j), and a
;;;       LIBDIR it cannot list is rule (j)'s to name;
;;;   (n) (circuit json) is a core library that may also import
;;;       (jsonparse easy), jsonparse's whole-document layer, to read and
;;;       write JSON, and no other library may import a (jsonparse ...)
;;;       library (ADR-0009). It imports no other (jsonparse ...) library,
;;;       and that one only through an only right around it, or around
;;;       (library ...), naming at least one identifier, as rule (k) holds
;;;       (circuit session) to (hashing sha-2). The machine jsonparse
;;;       generates and the byte-machine that runs it are no core library's
;;;       to import: rule (c) refuses each (generated ...) and
;;;       (byte-machine ...) library;
;;;   (o) when (circuit json) imports (jsonparse easy) as rule (n) lets it,
;;;       the JSONPARSE and BYTE-MACHINE that --jsonparse and --byte-machine
;;;       name are read as data for that library's closure, by rule (l)'s
;;;       reader: each library found by Chez's own library search handler
;;;       over its own library extensions, with BYTE-MACHINE and then
;;;       JSONPARSE the library directories, in the library path's order as
;;;       the Makefile builds it, so that where both hold a library the one
;;;       read is the one Chez loads, and each read once, so a cycle ends.
;;;       The closure imports only the (rnrs ...) libraries except
;;;       (rnrs eval), and jsonparse's seven other libraries, the
;;;       (generated jsonparse) machine, and (byte-machine runtime) and the
;;;       (byte-machine private conditions) and (byte-machine private names)
;;;       it imports. It fails closed as rule (l) does: no --jsonparse, no
;;;       --byte-machine, a library Chez finds no source for, a compiled
;;;       object Chez could load in place of the source unread, a source it
;;;       cannot read as data, a file that is not exactly one library form of
;;;       the library's name, and an import spec it cannot read are each
;;;       named. Rule (h) does not hold these files;
;;;   (p) as rule (m) holds hashing, the path holds one jsonparse and one
;;;       byte-machine: each LIBDIR but the directory and JSONPARSE holds
;;;       nothing named jsonparse or jsonparse.<anything>, in any case, nor
;;;       does a generated directory in it, in any case: Chez takes
;;;       (generated jsonparse) from the first LIBDIR whose generated/ has
;;;       it, and chez-httparse's and uriparse's src/ hold generated/
;;;       directories of their own, of other names. A generated directory it
;;;       cannot list is named, as what it holds is unknown. Each LIBDIR but
;;;       the directory and BYTE-MACHINE holds nothing named byte-machine or
;;;       byte-machine.<anything>, in any case. So BYTE-MACHINE, named among
;;;       the LIBDIRs, holds no jsonparse, and JSONPARSE no byte-machine: a
;;;       jsonparse in BYTE-MACHINE, which rule (o) reads first, is named as
;;;       the copy this check reads. It holds whether --jsonparse and
;;;       --byte-machine are named or not, and with one absent, every LIBDIR
;;;       holding its library is named. JSONPARSE and BYTE-MACHINE are still
;;;       LIBDIRs to rules (j) and (m).
;;;
;;; The lists are allowlists: a library that is not on one is refused, so a
;;; route nobody thought of is closed until a reviewer opens it. Exports are
;;; not read: a library cannot import by exporting.
;;;
;;;   usage: scheme --program tests/check-imports.sps DIR [--akku AKKU]
;;;            [--jsonparse JSONPARSE] [--byte-machine BYTE-MACHINE] [LIBDIR ...]
;;;
;;; Each flag is optional, and given at most once, in any order, after DIR
;;; and before the LIBDIRs. A flag with no directory after it, one that is
;;; no directory, and one given twice are each named. On a pass it prints one
;;; line to stdout, naming how many libraries it checked; when it was named
;;; LIBDIRs, a second, naming how many of them rule (j) looked in; when it
;;; read hashing's closure, a third, naming AKKU and how many libraries it
;;; read; when it was named --akku, a fourth, naming how many LIBDIRs rule
;;; (m) looked in; when it read jsonparse's closure, a fifth, naming
;;; JSONPARSE, BYTE-MACHINE and how many libraries it read; and when it was
;;; named --jsonparse, and when it was named --byte-machine, a line each,
;;; naming how many LIBDIRs rule (p) looked in for that library. It exits 0
;;; or 1, never a count. tests/test-check-imports.sps runs it on a tree for
;;; each rule.
(import (rnrs)
        (circuit-testing)
        (only (chezscheme) directory-list file-directory? library-extensions
              library-search-handler parameterize print-graph))

;; impure : (Listof (Listof Symbol))
;; The libraries that may import the server, and use Chez's own procedures.
;; Adding one is a reviewed change to the architecture (AGENTS.md).
(define impure '((circuit http-server) (circuit middleware waits)))

;; websocket-library : (Listof Symbol)
;; The one library that may import (websocket), chez-websocket's facade,
;; which imports the server: so no library may import it. Changing it is a
;; reviewed change to the architecture (ADR-0006).
(define websocket-library '(circuit websocket))

;; websocket-facade : (Listof Symbol)
(define websocket-facade '(websocket))

;; session-library : (Listof Symbol)
;; The one library that may import a (hashing ...) library: weinholt's
;; hashing, from Akku, signs its cookies. Changing it is a reviewed change to
;; the architecture (ADR-0006, ADR-0008).
(define session-library '(circuit session))

;; hashing-library : (Listof Symbol)
;; The one (hashing ...) library session-library may import, through only.
(define hashing-library '(hashing sha-2))

;; hashing-siblings : (Listof (Listof Symbol))
;; The (hashing ...) libraries hashing-library's closure may import beside
;; the (rnrs ...) ones. A pin that adds one is a reviewed change (ADR-0008).
(define hashing-siblings '((hashing fixnums) (hashing hmac)))

;; json-library : (Listof Symbol)
;; The one library that may import a (jsonparse ...) library: jsonparse
;; reads and writes its JSON. Changing it is a reviewed change to the
;; architecture (ADR-0006, ADR-0009).
(define json-library '(circuit json))

;; jsonparse-library : (Listof Symbol)
;; The one (jsonparse ...) library json-library may import, through only.
(define jsonparse-library '(jsonparse easy))

;; jsonparse-siblings : (Listof (Listof Symbol))
;; The libraries jsonparse-library's closure may import beside the (rnrs
;; ...) ones: jsonparse's others, the machine it generates, and the
;; byte-machine runtime that runs it, with the two it imports. A pin that
;; adds one is a reviewed change (ADR-0009).
(define jsonparse-siblings
  '((jsonparse error) (jsonparse options) (jsonparse parser) (jsonparse sequence)
    (jsonparse string) (jsonparse tree) (jsonparse writer) (generated jsonparse)
    (byte-machine runtime) (byte-machine private conditions) (byte-machine private names)))

;; rnrs-libraries : (Listof (Listof Symbol))
;; The standard libraries a library under the directory may import: R6RS's, but
;; for (rnrs eval). tests/test-check-imports.sps requires the list to equal the
;; (rnrs ...) libraries Chez has, but that one.
(define rnrs-libraries
  '((rnrs) (rnrs base) (rnrs arithmetic bitwise) (rnrs arithmetic fixnums)
    (rnrs arithmetic flonums) (rnrs bytevectors) (rnrs conditions)
    (rnrs control) (rnrs enums) (rnrs exceptions) (rnrs files)
    (rnrs hashtables) (rnrs io ports) (rnrs io simple) (rnrs lists)
    (rnrs mutable-pairs) (rnrs mutable-strings) (rnrs programs) (rnrs r5rs)
    (rnrs records inspection) (rnrs records procedural)
    (rnrs records syntactic) (rnrs sorting) (rnrs syntax-case) (rnrs unicode)))

;; chez-names : (Listof Symbol)
;; What an impure library may take from (chezscheme). None of them can import,
;; evaluate or load: a name that could would let a library's body reach what
;; its header may not import. Adding one is a reviewed change (ADR-0006).
;; getenv is the adapter's default environment, as it is `serve`'s;
;; port-has-port-length? and port-length size a port body from Chez's own
;; length of it, which plain R6RS can't ask (design §5, §15.8). real-time
;; is request logging's default clock: R6RS has none, and it counts
;; milliseconds from the process's start in a fixnum. display-condition
;; shows a condition in the catch helper's default line as the server's log
;; shows it, which R6RS can't (design §6); print-record, under
;; parameterize, shows a record inside it by its type alone, as the
;; server's log does: R6RS has neither.
(define chez-names '(getenv port-has-port-length? port-length real-time display-condition
                     print-record parameterize))

;; wrappers : (Listof Symbol)
;; The import-set forms that wrap one import set, in their second element.
;; (library <reference>) wraps a reference, and is handled apart.
(define wrappers '(for only except prefix rename))

;; written : Any -> String
;; print-graph makes write label a cyclic datum, #0=(only #0# x), where it
;; would warn on stderr and then do the same.
(define (written datum)
  (call-with-string-output-port
    (lambda (p) (parameterize ((print-graph #t)) (write datum p)))))

;; abbreviated : Any -> String
;; DATUM written, cut to 57 characters and three dots when over 60.
(define (abbreviated datum)
  (let ((text (written datum)))
    (if (> (string-length text) 60)
        (string-append (substring text 0 57) "...")
        text)))

;; say : Port String -> Unit
(define (say port text)
  (put-string port (string-append "check-imports: " text "\n")))

;; suffix? : String String -> Boolean
(define (suffix? s suffix)
  (let ((n (string-length s)) (m (string-length suffix)))
    (and (>= n m) (string=? (substring s (- n m) n) suffix))))

;; joined : String (Pairof String (Listof String)) -> String
;; The strings, a separator between each two. There is always one.
(define (joined separator strings)
  (fold-left (lambda (text s) (string-append text separator s))
             (car strings)
             (cdr strings)))

;; listed : (Pairof String (Listof String)) -> String
;; "a", "a and b", "a, b and c".
(define (listed strings)
  (if (null? (cdr strings))
      (car strings)
      (string-append (joined ", " (reverse (cdr (reverse strings))))
                     " and " (list-ref strings (- (length strings) 1)))))

;; without-slashes : String -> String
;; DIR without the slashes it ends with: a name is appended to it after one.
(define (without-slashes dir)
  (let ((n (string-length dir)))
    (if (and (> n 1) (char=? (string-ref dir (- n 1)) #\/))
        (without-slashes (substring dir 0 (- n 1)))
        dir)))

;; read-data : String -> (U (List 'data (Listof Any)) (List 'unreadable String))
(define (read-data path)
  (guard (e (#t (list 'unreadable (describe e))))
    (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                          (make-transcoder (utf-8-codec)))
      (lambda (port)
        (let loop ((found '()))
          (let ((datum (read port)))
            (if (eof-object? datum)
                (list 'data (reverse found))
                (loop (cons datum found)))))))))

;; header-complaints : String String -> (Listof String)
;; Rule (h) for the file at PATH below ROOT: that it does not begin with the
;; line #!r6rs, and the lines that hold #! anywhere but its first two bytes.
;; A file it cannot read as bytes is left to read-data, which names it.
(define (header-complaints path root)
  (let ((bytes (guard (e (#t #f))
                 (let ((all (call-with-port (open-file-input-port path) get-bytevector-all)))
                   (if (eof-object? all) #vu8() all)))))
    (if (not bytes)
        '()
        (let ((lines (directive-lines bytes)))
          (append
           (if (begins-with-header? bytes)
               '()
               (list (string-append path ": its first line is not #!r6rs, which every .sls file under "
                                    root " begins with, so that Chez reads it as R6RS and not with its own syntax")))
           (if (null? lines)
               '()
               (list (string-append path ": it holds #! on " (line-list lines)
                                    ", and only the #!r6rs it begins with may: a #! may switch Chez's reader to its own syntax, and this check, which cannot tell a directive from text, refuses one in a comment or a string too"))))))))

(define header (string->utf8 "#!r6rs\n"))

;; begins-with-header? : Bytevector -> Boolean
;; Whether BYTES begin with #!r6rs and a line feed.
(define (begins-with-header? bytes)
  (let ((n (bytevector-length header)))
    (and (>= (bytevector-length bytes) n)
         (let loop ((i 0))
           (or (= i n)
               (and (= (bytevector-u8-ref bytes i) (bytevector-u8-ref header i))
                    (loop (+ i 1))))))))

;; directive-lines : Bytevector -> (Listof Natural)
;; The lines, counted from 1, that hold #! at any byte but the first: each
;; line once, in order.
(define (directive-lines bytes)
  (let ((n (bytevector-length bytes)))
    (let loop ((i 0) (line 1) (found '()))
      (cond
        ((>= (+ i 1) n) (reverse found))
        ((= (bytevector-u8-ref bytes i) 10) (loop (+ i 1) (+ line 1) found))
        ((and (> i 0)
              (= (bytevector-u8-ref bytes i) 35)
              (= (bytevector-u8-ref bytes (+ i 1)) 33))
         (loop (+ i 2) line (if (and (pair? found) (= (car found) line)) found (cons line found))))
        (else (loop (+ i 1) line found))))))

;; line-list : (Pairof Natural (Listof Natural)) -> String
;; "line 3", "lines 3 and 5", "lines 2, 6 and 7".
(define (line-list lines)
  (string-append (if (null? (cdr lines)) "line " "lines ") (listed (map number->string lines))))

;; walk : String -> (Listof (Pair String (U 'file 'directory-link)))
;; Everything under DIR, as paths: the files, and the symbolic links to
;; directories, which it does not follow. A link that loops would never end.
(define (walk dir)
  (apply append
         (map (lambda (name)
                (let ((path (string-append dir "/" name)))
                  (cond
                    ((file-directory? path #f) (walk path))
                    ((file-directory? path) (list (cons path 'directory-link)))
                    (else (list (cons path 'file))))))
              (directory-list dir))))

;; reference-name : Any -> (U (Listof Symbol) #f)
;; The name in a library reference: its identifiers, and then at most one
;; list, the version reference, which is dropped. #f when it is no reference.
(define (reference-name ref)
  (and (list? ref)
       (let loop ((rest ref) (found '()))
         (cond
           ((null? rest) (and (pair? found) (reverse found)))
           ((symbol? (car rest)) (loop (cdr rest) (cons (car rest) found)))
           ((and (null? (cdr rest)) (list? (car rest))) (loop (cdr rest) found))
           (else #f)))))

;; spec-name : Any (Listof Any) -> (U (Listof Symbol) #f)
;; The one library an import spec imports, looking through the wrappers at any
;; depth. SEEN holds the specs it is inside, so a cyclic one ends in #f, not
;; in a loop. #f when it is no import spec this check can read.
(define (spec-name spec seen)
  (cond
    ((not (and (list? spec) (pair? spec))) #f)
    ((memq spec seen) #f)
    ((eq? (car spec) 'library)
     (and (= (length spec) 2) (pair? (cadr spec)) (reference-name (cadr spec))))
    ((memq (car spec) wrappers)
     (and (pair? (cdr spec)) (spec-name (cadr spec) (cons spec seen))))
    (else (reference-name spec))))

;; narrowed? : Any ((Listof Any) -> Boolean) -> Boolean
;; Whether the import set right around SPEC's reference, or around
;; (library ...), is an only whose names NAMES-OK? takes. The wrappers
;; outside it can only drop or rename what it lets through. spec-name has
;; unwrapped SPEC, so it holds no cycle.
(define (narrowed? spec names-ok?)
  (and (memq (car spec) wrappers)
       (let ((inner (cadr spec)))
         (if (and (pair? inner) (memq (car inner) wrappers))
             (narrowed? inner names-ok?)
             (and (eq? (car spec) 'only) (names-ok? (cddr spec)))))))

;; narrow-chez? : Any -> Boolean
;; Whether SPEC, which imports (chezscheme), takes from it only chez-names,
;; through an only that names nothing else.
(define (narrow-chez? spec)
  (narrowed? spec (lambda (ids) (for-all (lambda (id) (memq id chez-names)) ids))))

;; narrow-dependency? : Any -> Boolean
;; Whether SPEC, which imports hashing-library or jsonparse-library, names
;; what it takes from it, through an only that names at least one
;; identifier and nothing else.
(define (narrow-dependency? spec)
  (narrowed? spec (lambda (ids) (and (pair? ids) (for-all symbol? ids)))))

;; headed? : Symbol Any -> Boolean
(define (headed? key form)
  (and (pair? form) (list? form) (eq? (car form) key)))

;; library-form? : Any -> Boolean
;; (library <name> (export ...) (import ...) <body> ...)
(define (library-form? datum)
  (and (list? datum)
       (>= (length datum) 4)
       (eq? (car datum) 'library)
       (reference-name (cadr datum))
       (headed? 'export (caddr datum))
       (headed? 'import (cadddr datum))
       #t))

;; library-path : String (Listof Symbol) -> String
;; Where a library named NAME stands below ROOT: its identifiers joined by /,
;; then .sls. Chez looks for it there, in each library directory in turn.
(define (library-path root name)
  (string-append root "/" (joined "/" (map symbol->string name)) ".sls"))

;; defined-libraries : (Listof (Pair String (U (List 'data (Listof Any)) (List 'unreadable String))))
;;                     -> (Listof (Listof Symbol))
;; The name of every library form in the files read, those it can read.
(define (defined-libraries reads)
  (apply append
         (map (lambda (entry)
                (let ((found (cdr entry)))
                  (if (eq? (car found) 'data)
                      (map (lambda (form) (reference-name (cadr form)))
                           (filter library-form? (cadr found)))
                      '())))
              reads)))

;; dependency-complaints : (Listof Symbol) (Listof Symbol) (Listof Symbol) (Listof Symbol) Any
;;                         ((Listof Symbol) String -> (Listof String)) -> (Listof String)
;; Rules (k) and (n): what is wrong with the library NAME importing
;; IMPORTED, of DEPENDENCY's family, through SPEC. Only OWNER may import one
;; of the family, and only DEPENDENCY, through only. REFUSE words a
;; complaint about IMPORTED from its reason.
(define (dependency-complaints name owner dependency imported spec refuse)
  (let ((family (string-append "(" (symbol->string (car dependency)) " ...) library")))
    (cond ((not (equal? name owner))
           (refuse imported (string-append "only " (written owner) " may import a " family)))
          ((not (equal? imported dependency))
           (refuse imported
                   (string-append (written owner) " may import no " family " but " (written dependency))))
          ((narrow-dependency? spec) '())
          (else
           (refuse imported
                   (string-append (written owner) " imports " (written dependency)
                                  " only through only, right around it, naming at least one identifier: so its header names all it takes from code circuit didn't write"))))))

;; owner-reason : (Listof Symbol) (Listof Symbol) -> String
;; Why OWNER, a core library that may also import DEPENDENCY, may import no
;; other library than a core one may.
(define (owner-reason owner dependency)
  (string-append (written owner)
                 " may import only the (rnrs ...) libraries except (rnrs eval), core (circuit ...) libraries, and "
                 (written dependency) " through only"))

;; import-complaints : String String (Listof Symbol) Boolean Any (Listof (Listof Symbol))
;;                     -> (Listof String)
;; What is wrong with the import spec SPEC of the library NAME, read from PATH:
;; none, or one. IMPURE? is whether NAME is an impure library, and DEFINED the
;; libraries defined under ROOT.
(define (import-complaints path root name impure? spec defined)
  (let ((imported (spec-name spec '()))
        (library (written name))
        (websocket? (equal? name websocket-library))
        (session? (equal? name session-library))
        (json? (equal? name json-library)))
    (define (refuse imported reason)
      (list (string-append path ": " library " imports " (written imported)
                           ", but " reason)))
    (cond
      ((not imported)
       (list (string-append path ": " library " has an import it cannot read: "
                            (abbreviated spec))))
      ((member imported impure)
       (refuse imported
               (string-append "no library may import an impure library: "
                              (written imported) " is one, and the core stays free of the server")))
      ((equal? imported websocket-library)
       (refuse imported
               (string-append "no library may import " (written websocket-library)
                              ": it reaches the server through " (written websocket-facade)
                              ", and the core stays free of the server")))
      ((member imported rnrs-libraries) '())
      ((eq? (car imported) 'circuit)
       (if (member imported defined)
           '()
           (refuse imported (string-append "no library under " root " defines it"))))
      ((eq? (car imported) (car websocket-facade))
       (cond ((not (equal? imported websocket-facade))
              (refuse imported
                      (string-append "no library may import a (websocket ...) library but the facade, "
                                     (written websocket-facade) ", which only "
                                     (written websocket-library) " may import")))
             (websocket? '())
             (else
              (refuse imported
                      (string-append "only " (written websocket-library) " may import "
                                     (written websocket-facade) ", chez-websocket's facade")))))
      ((eq? (car imported) (car hashing-library))
       (dependency-complaints name session-library hashing-library imported spec refuse))
      ((eq? (car imported) (car jsonparse-library))
       (dependency-complaints name json-library jsonparse-library imported spec refuse))
      ((and impure? (equal? imported '(chezscheme)))
       (if (narrow-chez? spec)
           '()
           (refuse imported
                   (string-append "an impure library imports (chezscheme) only through only, right around it, naming "
                                  (joined ", " (map symbol->string chez-names))
                                  " alone: anything wider gives its body import and eval, which reach any library"))))
      ((and (eq? (car imported) 'http-server) (pair? (cdr imported))
            (eq? (cadr imported) 'private))
       (refuse imported "no library may import an (http-server private ...) library"))
      ((and impure? (eq? (car imported) 'http-server)) '())
      ((and (not impure?) (memq (car imported) '(chezscheme http-server)))
       (refuse imported
               "only an impure library, (circuit http-server) or (circuit middleware waits), may import (chezscheme) or an (http-server ...) library"))
      (impure?
       (refuse imported
               "an impure library may import only the (rnrs ...) libraries except (rnrs eval), core (circuit ...) libraries, (chezscheme) through only, and the (http-server ...) libraries except (http-server private ...)"))
      (websocket?
       (refuse imported
               (string-append (written websocket-library)
                              " may import only the (rnrs ...) libraries except (rnrs eval), core (circuit ...) libraries, and "
                              (written websocket-facade))))
      (session? (refuse imported (owner-reason session-library hashing-library)))
      (json? (refuse imported (owner-reason json-library jsonparse-library)))
      (else
       (refuse imported
               "a core library may import only the (rnrs ...) libraries except (rnrs eval), and core (circuit ...) libraries")))))

;; library-complaints : String String Any (Listof (Listof Symbol)) -> (Listof String)
;; What is wrong with the library form FORM, read from PATH below ROOT: its
;; family, its place, then its imports, in import order.
(define (library-complaints path root form defined)
  (let* ((name (reference-name (cadr form)))
         (library (written name))
         (impure? (and (member name impure) #t))
         (want (library-path root name)))
    (append
     (if (eq? (car name) 'circuit)
         '()
         (list (string-append path ": " library " is not a (circuit ...) library: every library under "
                              root " is named (circuit ...)")))
     (if (string=? path want)
         '()
         (list (string-append path ": " library " is defined here, but its name's path is " want)))
     (apply append
            (map (lambda (spec) (import-complaints path root name impure? spec defined))
                 (cdr (cadddr form)))))))

;; data-complaints : String String (Listof Any) (Listof (Listof Symbol)) -> (Listof String)
;; What is wrong with the data of the file at PATH below ROOT: each datum that
;; is no library form, the count when there is more than one library, then each
;; library's own problems, in the order found.
(define (data-complaints path root data defined)
  (let ((forms (filter library-form? data)))
    (append
     (if (null? data)
         (list (string-append path ": it holds no datum, so it holds no library"))
         '())
     (let loop ((rest data) (n 1))
       (cond
         ((null? rest) '())
         ((library-form? (car rest)) (loop (cdr rest) (+ n 1)))
         (else (cons (string-append path ": datum " (number->string n) " is "
                                    (abbreviated (car rest)) ", not a library form")
                     (loop (cdr rest) (+ n 1))))))
     (if (> (length forms) 1)
         (list (string-append path ": it holds " (number->string (length forms))
                              " libraries, but a file holds exactly one"))
         '())
     (apply append
            (map (lambda (form) (library-complaints path root form defined)) forms)))))

;; entry-result : (Pair String (U 'file 'directory-link)) String
;;                (Listof (Pair String Read)) (Listof (Listof Symbol))
;;                -> (Pair (Listof String) Natural)
;; The complaints about one thing under ROOT, and how many libraries it holds.
(define (entry-result entry root reads defined)
  (let ((path (car entry)))
    (cond
      ((eq? (cdr entry) 'directory-link)
       (cons (list (string-append path ": it is a symbolic link to a directory,"
                                  " which this check does not follow"))
             0))
      ((not (suffix? path ".sls"))
       (cons (list (string-append path ": it is not a .sls file, and only .sls libraries belong under "
                                  root))
             0))
      (else
       (let ((found (cdr (assoc path reads)))
             (header (header-complaints path root)))
         (if (eq? (car found) 'data)
             (cons (append header (data-complaints path root (cadr found) defined))
                   (length (filter library-form? (cadr found))))
             (cons (append header
                           (list (string-append path ": it cannot be read as data: " (cadr found))))
                   0)))))))

;; imports-dependency? : (Listof (Pair String Read)) (Listof Symbol) (Listof Symbol) -> Boolean
;; Whether a library form named OWNER, in the files read, imports DEPENDENCY
;; as rule (k) or (n) lets it, so rule (l) or (o) reads its closure.
(define (imports-dependency? reads owner dependency)
  (exists (lambda (entry)
            (let ((found (cdr entry)))
              (and (eq? (car found) 'data)
                   (exists (lambda (form)
                             (and (equal? (reference-name (cadr form)) owner)
                                  (exists (lambda (spec)
                                            (and (equal? (spec-name spec '()) dependency)
                                                 (narrow-dependency? spec)))
                                          (cdr (cadddr form)))))
                           (filter library-form? (cadr found))))))
          reads))

;; resolved : (Pairof String (Listof String)) (Listof Symbol)
;;            -> (List (U String #f) (U String #f) Boolean)
;; Where Chez finds the library NAME with DIRS its library directories, in
;; order, for sources and objects both: by Chez's own search handler, over
;; its own library extensions, so the file named is the one Chez would load.
;; The source, or #f; the object file's path, or #f; whether that object
;; exists.
(define (resolved dirs name)
  (call-with-values
    (lambda () ((library-search-handler) 'import name (map (lambda (dir) (cons dir dir)) dirs)
                                         (library-extensions)))
    list))

;; closure-allows : (Pairof (Listof Symbol) (Listof (Listof Symbol))) -> String
;; What a closure whose siblings are SIBLINGS may import, in its complaints
;; and its pass line.
(define (closure-allows siblings)
  (string-append "the (rnrs ...) libraries except (rnrs eval), " (listed (map written siblings))))

;; closure-import-complaints : (Listof Symbol) (Listof (Listof Symbol)) String String Any
;;                             -> (Listof String)
;; What is wrong with the import spec SPEC of the library LIBRARY, written,
;; read from SOURCE, in the closure of TOP, which may import SIBLINGS: none,
;; or one.
(define (closure-import-complaints top siblings source library spec)
  (let ((imported (spec-name spec '())))
    (cond
      ((not imported)
       (list (string-append source ": " library " has an import it cannot read: " (abbreviated spec))))
      ((or (member imported rnrs-libraries) (member imported siblings)) '())
      (else
       (list (string-append source ": " library " imports " (written imported)
                            ", but the closure of " (written top)
                            " may import only " (closure-allows siblings)))))))

;; closure-library : (Listof Symbol) (Listof (Listof Symbol)) (Pairof String (Listof String))
;;                   (Listof Symbol) -> (Pair (Listof String) (Listof (Listof Symbol)))
;; Rule (l) or (o) for the library NAME, found in DIRS, in TOP's closure:
;; its complaints, and the SIBLINGS it imports, which the closure reads
;; next. A file that is not exactly one library form of NAME is named, and
;; its imports are not read: what Chez would make of it is unknown.
(define (closure-library top siblings dirs name)
  (let* ((where (resolved dirs name))
         (source (car where))
         (library (written name))
         (compiled (if (caddr where)
                       (list (string-append (cadr where) ": it is compiled, so Chez could load " library
                                            " from it in place of its source, which this check reads"))
                       '())))
    (if (not source)
        (cons (cons (string-append (listed dirs) ": Chez finds no source for " library
                                   (if (null? (cdr dirs)) " in it" " in them")
                                   ", so this check cannot read what it imports")
                    compiled)
              '())
        (let ((found (read-data source)))
          (cond
            ((eq? (car found) 'unreadable)
             (cons (append compiled
                           (list (string-append source ": it cannot be read as data: " (cadr found))))
                   '()))
            ((not (and (= (length (cadr found)) 1)
                       (library-form? (car (cadr found)))
                       (equal? (reference-name (cadr (car (cadr found)))) name)))
             (cons (append compiled
                           (list (string-append source ": Chez loads " library
                                                " from it, but it is not exactly one library form named "
                                                library)))
                   '()))
            (else
             (let ((specs (cdr (cadddr (car (cadr found))))))
               (cons (append compiled
                             (apply append
                                    (map (lambda (spec)
                                           (closure-import-complaints top siblings source library spec))
                                         specs)))
                     (filter (lambda (imported) (member imported siblings))
                             (map (lambda (spec) (spec-name spec '())) specs))))))))))

;; closure-result : (Listof Symbol) (Listof (Listof Symbol)) (Pairof String (Listof String))
;;                  -> (Pair (Listof String) Natural)
;; Rules (l) and (o): the complaints about TOP's closure, which may import
;; SIBLINGS, found in DIRS, in the order read, and how many libraries it
;; read. Each is read once, however often it is imported, so a cycle ends.
(define (closure-result top siblings dirs)
  (let loop ((todo (list top)) (seen '()) (complaints '()))
    (cond
      ((null? todo) (cons complaints (length seen)))
      ((member (car todo) seen) (loop (cdr todo) seen complaints))
      (else
       (let ((found (closure-library top siblings dirs (car todo))))
         (loop (append (cdr todo) (cdr found))
               (cons (car todo) seen)
               (append complaints (car found))))))))

;; family-entry? : String String -> Boolean
;; Whether NAME, an entry of a directory on a library path, is one Chez could
;; take a (FAMILY ...) library from: FAMILY, the directory of every
;; (FAMILY NAME ...), or FAMILY.<extension>, the file of (FAMILY) itself
;; under any of Chez's library extensions, compiled ones among them. In any
;; case: a Mac's default disk finds Circuit/ or CIRCUIT.sls for circuit.
(define (family-entry? family name)
  (let ((name (string-downcase name))
        (dotted (string-append family ".")))
    (or (string=? name family)
        (and (> (string-length name) (string-length dotted))
             (string=? (substring name 0 (string-length dotted)) dotted)))))

;; circuit-entry? : String -> Boolean
(define (circuit-entry? name) (family-entry? "circuit" name))

;; generated-entry? : String -> Boolean
;; Whether NAME, an entry of a directory on a library path, is generated in
;; any case: where Chez looks for (generated jsonparse), as a Mac's disk
;; finds it.
(define (generated-entry? name) (string=? (string-downcase name) "generated"))

;; path-dirs : String (Listof String) -> (Listof String)
;; The LIBDIRS rule (j) looks in, each without the slashes it ends with: not
;; ROOT, and not one that is no directory, in the order named.
(define (path-dirs root libdirs)
  (filter (lambda (dir) (and (not (string=? dir root)) (file-directory? dir)))
          (map without-slashes libdirs)))

;; path-complaints : String (Listof String) -> (Listof String)
;; Rule (j): each entry of each of DIRS that circuit-entry? takes, sorted. A
;; directory it cannot list is named, failing closed as rule (f) does: what
;; it holds is unknown.
(define (path-complaints root dirs)
  (apply append
         (map (lambda (dir)
                (let ((names (guard (e (#t (describe e))) (directory-list dir))))
                  (if (string? names)
                      (list (string-append dir ": it is on the library path beside " root
                                           ", and cannot be listed, so this check cannot tell whether it holds a (circuit ...) library: "
                                           names))
                      (map (lambda (name)
                             (string-append dir "/" name ": its directory is on the library path beside " root
                                            ", so Chez could load a (circuit ...) library from it in place of "
                                            root "'s, which this check reads; only " root " may hold one"))
                           (list-sort string<? (filter circuit-entry? names))))))
              dirs)))

;; could-load : String String (U String #f) String (Listof String) -> String
;; How a complaint of rule (m) or (p) about an entry of DIR ends: Chez could
;; load WHAT from it in place of HOLDER's, the one directory FLAG names, or
;; no FLAG names one. HOLDER's is the copy this check reads, unless DIR is
;; one of AHEAD, which its closure reads before HOLDER: then DIR's is.
(define (could-load what flag holder dir ahead)
  (cond
    ((not holder)
     (string-append ", so Chez could load " what " from it, and no " flag
                    " names the one directory that may hold one"))
    ((member dir ahead)
     (string-append " beside " holder ", so Chez could load " what " from it in place of "
                    holder "'s, and this check reads " dir " before " holder
                    ", in the library path's order; only " holder " may hold one"))
    (else
     (string-append " beside " holder ", so Chez could load " what " from it in place of "
                    holder "'s, which this check reads; only " holder " may hold one"))))

;; family-path-complaints : String String (U String #f) (Listof String) (Listof String)
;;                          -> (Listof String)
;; Rules (m) and (p): each entry of each of DIRS that family-entry? takes
;; for FAMILY, sorted. DIRS are rule (j)'s, but HOLDER, when FLAG names one,
;; and AHEAD the directories a closure reads before HOLDER. A directory it
;; cannot list is passed over: rule (j) names it, as it looks in each.
(define (family-path-complaints family flag holder ahead dirs)
  (apply append
         (map (lambda (dir)
                (let ((names (guard (e (#t #f)) (directory-list dir))))
                  (map (lambda (name)
                         (string-append dir "/" name ": its directory is on the library path"
                                        (could-load (string-append "a (" family " ...) library") flag holder
                                                    dir ahead)))
                       (list-sort string<? (filter (lambda (name) (family-entry? family name))
                                                   (or names '()))))))
              dirs)))

;; generated-path-complaints : (U String #f) (Listof String) (Listof String) -> (Listof String)
;; Rule (p): in each generated directory, in any case, of each of DIRS, each
;; entry that family-entry? takes for jsonparse, sorted. DIRS are rule (j)'s,
;; but JSONPARSE, when --jsonparse names one, and AHEAD the directories the
;; closure reads before JSONPARSE. A generated directory it cannot list is
;; named, failing closed as rule (j) does: rule (j) looks in none. A LIBDIR
;; it cannot list is passed over, as rule (j) names it.
(define (generated-path-complaints jsonparse ahead dirs)
  (apply append
         (map (lambda (dir)
                (let ((names (guard (e (#t #f)) (directory-list dir))))
                  (apply append
                         (map (lambda (generated)
                                (let* ((at (string-append dir "/" generated))
                                       (inner (guard (e (#t (describe e))) (directory-list at))))
                                  (if (string? inner)
                                      (list (string-append at ": it is in " dir
                                                           ", which is on the library path, and cannot be listed, so this check cannot tell whether it holds a (generated jsonparse ...) library: "
                                                           inner))
                                      (map (lambda (name)
                                             (string-append at "/" name ": it is in " dir
                                                            ", which is on the library path"
                                                            (could-load "a (generated jsonparse ...) library"
                                                                        "--jsonparse" jsonparse dir ahead)))
                                           (list-sort string<? (filter (lambda (name) (family-entry? "jsonparse" name))
                                                                       inner))))))
                              (list-sort string<?
                                         (filter (lambda (name)
                                                   (and (generated-entry? name)
                                                        (file-directory? (string-append dir "/" name))))
                                                 (or names '())))))))
              dirs)))

;; usage : String
(define usage
  "usage: scheme --program tests/check-imports.sps DIR [--akku AKKU] [--jsonparse JSONPARSE] [--byte-machine BYTE-MACHINE] [LIBDIR ...]")

;; flags : (Listof String)
;; The flags the command line may give after DIR, each naming a directory.
(define flags '("--akku" "--jsonparse" "--byte-machine"))

;; parsed-flags : (Listof String) -> (U String (Pair (Listof (Pair String String)) (Listof String)))
;; The flags at the head of ARGS, each with the directory it names, without
;; the slashes it ends with, and then the LIBDIRs after them. Or the problem
;; with the first flag that is wrong: one given twice, one with no
;; directory after it, and one naming no directory.
(define (parsed-flags args)
  (let loop ((args args) (named '()))
    (cond
      ((or (null? args) (not (member (car args) flags))) (cons named args))
      ((assoc (car args) named)
       (string-append (car args) " is given twice, and a flag is given at most once"))
      ((null? (cdr args)) (string-append (car args) " names no directory after it"))
      ((not (file-directory? (cadr args)))
       (string-append (car args) " " (cadr args) ": not a directory"))
      (else (loop (cddr args) (cons (cons (car args) (without-slashes (cadr args))) named))))))

;; main : (Listof String) -> Unit
(define (main args)
  (let ((parsed (and (pair? args) (parsed-flags (cdr args)))))
    (cond
      ((null? args)
       (say (current-error-port) usage)
       (exit 1))
      ((not (file-directory? (car args)))
       (say (current-error-port) (string-append (car args) ": not a directory"))
       (exit 1))
      ((string? parsed)
       (say (current-error-port) parsed)
       (exit 1))
      (else
       (let ((named (lambda (flag) (let ((found (assoc flag (car parsed)))) (and found (cdr found))))))
         (check (without-slashes (car args))
                (named "--akku")
                (named "--jsonparse")
                (named "--byte-machine")
                (cdr parsed)))))))

;; but : (Listof String) (U String #f) -> (Listof String)
;; DIRS, but HOLDER, when a flag names one.
(define (but dirs holder)
  (filter (lambda (dir) (not (and holder (string=? dir holder)))) dirs))

;; jsonparse-order : String String -> (List String String)
;; The directories jsonparse-library's closure is found in, in the order
;; Chez searches them on the library path the Makefile builds: LIBDIR_LIST
;; puts byte-machine's src/ before jsonparse's. So where both hold a
;; library, the one this check reads is the one Chez loads.
(define (jsonparse-order jsonparse byte-machine) (list byte-machine jsonparse))

;; ahead : (Listof String) (U String #f) -> (Listof String)
;; The directories of DIRS, a closure's in the order it reads them, that
;; come before HOLDER: none when HOLDER is not among them.
(define (ahead dirs holder)
  (if (and holder (member holder dirs))
      (let loop ((dirs dirs))
        (if (string=? (car dirs) holder) '() (cons (car dirs) (loop (cdr dirs)))))
      '()))

;; check : String (U String #f) (U String #f) (U String #f) (Listof String) -> Unit
;; The rules, on the tree ROOT, with hashing's closure read from AKKU,
;; jsonparse's from JSONPARSE and BYTE-MACHINE, and the LIBDIRS named.
(define (check root akku jsonparse byte-machine libdirs)
  (let* ((entries (list-sort (lambda (a b) (string<? (car a) (car b))) (walk root)))
         (reads (map (lambda (entry) (cons (car entry) (read-data (car entry))))
                     (filter (lambda (entry)
                               (and (eq? (cdr entry) 'file) (suffix? (car entry) ".sls")))
                             entries)))
         (defined (defined-libraries reads))
         (results (map (lambda (entry) (entry-result entry root reads defined)) entries))
         (checked (apply + (map cdr results)))
         (hashing? (imports-dependency? reads session-library hashing-library))
         (closure (and hashing? akku (closure-result hashing-library hashing-siblings (list akku))))
         (json? (imports-dependency? reads json-library jsonparse-library))
         (json-dirs (if (and jsonparse byte-machine) (jsonparse-order jsonparse byte-machine) '()))
         (json-closure (and json? (pair? json-dirs)
                            (closure-result jsonparse-library jsonparse-siblings json-dirs)))
         (dirs (path-dirs root libdirs))
         (hashing-dirs (but dirs akku))
         (jsonparse-dirs (but dirs jsonparse))
         (byte-machine-dirs (but dirs byte-machine))
         (complaints (append (apply append (map car results))
                             (if (= checked 0)
                                 (list (string-append "no library under " root))
                                 '())
                             (cond
                               ((not hashing?) '())
                               (akku (car closure))
                               (else
                                (list (string-append (written session-library) " imports "
                                                     (written hashing-library)
                                                     ", but no --akku names the directory this check reads its closure from"))))
                             (cond
                               ((not json?) '())
                               (json-closure (car json-closure))
                               (else
                                (append
                                 (if jsonparse
                                     '()
                                     (list (string-append (written json-library) " imports "
                                                          (written jsonparse-library)
                                                          ", but no --jsonparse names the directory this check reads its closure's (jsonparse ...) and (generated ...) libraries from")))
                                 (if byte-machine
                                     '()
                                     (list (string-append (written json-library) " imports "
                                                          (written jsonparse-library)
                                                          ", but no --byte-machine names the directory this check reads its closure's (byte-machine ...) libraries from"))))))
                             (path-complaints root dirs)
                             (family-path-complaints "hashing" "--akku" akku '() hashing-dirs)
                             (family-path-complaints "jsonparse" "--jsonparse" jsonparse
                                                     (ahead json-dirs jsonparse) jsonparse-dirs)
                             (generated-path-complaints jsonparse (ahead json-dirs jsonparse) jsonparse-dirs)
                             (family-path-complaints "byte-machine" "--byte-machine" byte-machine
                                                     (ahead json-dirs byte-machine) byte-machine-dirs))))
    (cond
      ((null? complaints)
       (say (current-output-port)
            (string-append "ok, libraries checked: " (number->string checked)))
       (unless (null? libdirs)
         (say (current-output-port)
              (string-append "ok, no other directory on the library path holds circuit: "
                             (number->string (length dirs)) " looked in")))
       (when closure
         (say (current-output-port)
              (string-append "ok, the closure of " (written hashing-library) " in " akku
                             " imports only " (closure-allows hashing-siblings) ": "
                             (number->string (cdr closure)) " libraries read")))
       (when akku
         (say (current-output-port)
              (string-append "ok, no other directory on the library path holds hashing: "
                             (number->string (length hashing-dirs)) " looked in")))
       (when json-closure
         (say (current-output-port)
              (string-append "ok, the closure of " (written jsonparse-library) " in " jsonparse
                             " and " byte-machine " imports only " (closure-allows jsonparse-siblings) ": "
                             (number->string (cdr json-closure)) " libraries read")))
       (when jsonparse
         (say (current-output-port)
              (string-append "ok, no other directory on the library path holds jsonparse: "
                             (number->string (length jsonparse-dirs)) " looked in")))
       (when byte-machine
         (say (current-output-port)
              (string-append "ok, no other directory on the library path holds byte-machine: "
                             (number->string (length byte-machine-dirs)) " looked in")))
       (exit 0))
      (else
       (for-each (lambda (c) (say (current-error-port) c)) complaints)
       (exit 1)))))

(main (cdr (command-line)))
