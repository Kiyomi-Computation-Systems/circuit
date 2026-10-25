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
;;;       (circuit middleware waits). Every other library is core;
;;;   (c) a core library imports only the (rnrs ...) libraries except
;;;       (rnrs eval), and core (circuit ...) libraries. So it imports neither
;;;       impure library, nor (chezscheme), nor an (http-server ...) library,
;;;       nor anything else;
;;;   (d) an impure library may also import (chezscheme), and the
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
;;;       does not read.
;;;
;;; The lists are allowlists: a library that is not on one is refused, so a
;;; route nobody thought of is closed until a reviewer opens it. Exports are
;;; not read: a library cannot import by exporting.
;;;
;;; On a pass it prints one line to stdout, naming how many libraries it
;;; checked. It exits 0 or 1, never a count. tests/test-check-imports.sps runs
;;; it on a tree for each rule.
(import (rnrs)
        (circuit-testing)
        (only (chezscheme) directory-list file-directory? parameterize print-graph))

;; impure : (Listof (Listof Symbol))
;; The libraries that may import the server, and use Chez's own procedures.
;; Adding one is a reviewed change to the architecture (AGENTS.md).
(define impure '((circuit http-server) (circuit middleware waits)))

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

;; import-complaints : String String (Listof Symbol) Boolean Any (Listof (Listof Symbol))
;;                     -> (Listof String)
;; What is wrong with the import spec SPEC of the library NAME, read from PATH:
;; none, or one. IMPURE? is whether NAME is an impure library, and DEFINED the
;; libraries defined under ROOT.
(define (import-complaints path root name impure? spec defined)
  (let ((imported (spec-name spec '()))
        (library (written name)))
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
      ((member imported rnrs-libraries) '())
      ((eq? (car imported) 'circuit)
       (if (member imported defined)
           '()
           (refuse imported (string-append "no library under " root " defines it"))))
      ((and impure? (equal? imported '(chezscheme))) '())
      ((and (eq? (car imported) 'http-server) (pair? (cdr imported))
            (eq? (cadr imported) 'private))
       (refuse imported "no library may import an (http-server private ...) library"))
      ((and impure? (eq? (car imported) 'http-server)) '())
      ((and (not impure?) (memq (car imported) '(chezscheme http-server)))
       (refuse imported
               "only an impure library, (circuit http-server) or (circuit middleware waits), may import (chezscheme) or an (http-server ...) library"))
      (impure?
       (refuse imported
               "an impure library may import only the (rnrs ...) libraries except (rnrs eval), core (circuit ...) libraries, (chezscheme), and the (http-server ...) libraries except (http-server private ...)"))
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
       (let ((found (cdr (assoc path reads))))
         (if (eq? (car found) 'data)
             (cons (data-complaints path root (cadr found) defined)
                   (length (filter library-form? (cadr found))))
             (cons (list (string-append path ": it cannot be read as data: " (cadr found)))
                   0)))))))

;; main : (Listof String) -> Unit
(define (main args)
  (cond
    ((not (= (length args) 1))
     (say (current-error-port) "usage: scheme --program tests/check-imports.sps DIR")
     (exit 1))
    ((not (file-directory? (car args)))
     (say (current-error-port) (string-append (car args) ": not a directory"))
     (exit 1))
    (else
     (let* ((root (without-slashes (car args)))
            (entries (list-sort (lambda (a b) (string<? (car a) (car b))) (walk root)))
            (reads (map (lambda (entry) (cons (car entry) (read-data (car entry))))
                        (filter (lambda (entry)
                                  (and (eq? (cdr entry) 'file) (suffix? (car entry) ".sls")))
                                entries)))
            (defined (defined-libraries reads))
            (results (map (lambda (entry) (entry-result entry root reads defined)) entries))
            (checked (apply + (map cdr results)))
            (complaints (append (apply append (map car results))
                                (if (= checked 0)
                                    (list (string-append "no library under " root))
                                    '()))))
       (cond
         ((null? complaints)
          (say (current-output-port)
               (string-append "ok, libraries checked: " (number->string checked)))
          (exit 0))
         (else
          (for-each (lambda (c) (say (current-error-port) c)) complaints)
          (exit 1)))))))

(main (cdr (command-line)))
