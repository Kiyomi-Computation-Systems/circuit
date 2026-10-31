#!r6rs
;;; The reference suite: docs/reference.md, the API reference, held to the
;;; code. It reads the page by a narrow convention, not as Markdown: the
;;; lines that begin with `# `, `## ` or `### `, and the fences, each at the
;;; start of its line. The page's first line is `# API reference`; a fenced
;;; text block before the first section holds the type aliases, NAME = TYPE;
;;; each section is ## `(library)`; each entry is ### `name`, then a fenced
;;; block whose info string is text, holding the signature, then words and
;;; links. Its rows:
;;;
;;;   (a) the page's sections are the eight public libraries, in their order,
;;;       each once;
;;;   (b) every library under src/ is one of the eight, or the names it
;;;       exports that no public library exports are exactly the ones this
;;;       suite lists as the adapter's and the tests' own;
;;;   (c) under each section, the entries are the library's exports, by
;;;       library-exports, each once; a failure names what is missing and
;;;       what isn't exported;
;;;   (d) every export but a re-export is defined in one library under src/,
;;;       which gives it one signature comment, `;; name : Type`, and its
;;;       entry's one block is that comment's text, whitespace runs
;;;       collapsed. A comment that names several names, `;; a, b : T` or
;;;       `;; a b : T`, gives each `name : T`. Each such export that is a
;;;       procedure takes the counts of arguments its signature gives, by
;;;       procedure-arity-mask;
;;;   (e) an export is a re-export when the library binds it to the very
;;;       value chez-http-server's or chez-websocket's facade does, by eq?,
;;;       or, for syntax, which has no value, when both export it and src/
;;;       defines it nowhere. Its entry has no block, and one link to that
;;;       one's docs/reference.md at its pin's tag, whose anchored section,
;;;       down to the next heading of its level or a higher one, names it in
;;;       a code span;
;;;   (f) every link in docs/*.md and README.org into chez-http-server's or
;;;       chez-websocket's repository, at blob/<ref>/ or tree/<ref>/, names
;;;       its pin's tag as <ref>;
;;;   (g) every re-export that is a procedure has one signature comment in
;;;       the library under src/ that re-exports it, and its text is the one
;;;       signature that one's docs/reference.md, as vendored at its pin,
;;;       gives it: in a text fence, as a table row's name and type cells,
;;;       or as an inline code span, whitespace runs collapsed. As in (d),
;;;       a comment is held to a reference, never to what the code does.
;;;
;;; A pin's tag is v and the version its vendored copy's Akku.manifest
;;; gives, which the Makefile's comment on the pin, `SERVER_PIN := <sha>  #
;;; vX.Y.Z`, must name too. And the page's own shape: no heading out of the
;;; convention; each type alias in its intro is the alias comment in src/,
;;; `;; NAME = TYPE`, where two that name one type agree; every entry has
;;; words, and every entry but a re-export a link to a guide page, a
;;; relative .md with no anchor that names it in code, inline or fenced; every #anchor
;;; into the server's or chez-websocket's reference names a heading there,
;;; as vendored at its pin. The readers are pure, and rows of their own hold
;;; them to inputs written here by hand.
;;;
;;; Run it from the checkout's root, as make test does. To run it on mutant
;;; copies, name a docs directory, which holds reference.md, a README, and,
;;; if you like, a src directory, whose comments and definitions it reads.
;;; The exports and their values are always those of the libraries on the
;;; library path: put a mutant src first on it to change them.
;;;
;;;   $CHEZ --libdirs ... --program tests/test-reference.sps build/m/docs build/m/README.org [build/m/src]
(import (rnrs)
        (rnrs eval)
        (srfi :64)
        (circuit-testing)
        (only (chezscheme) library-exports directory-list file-directory? procedure-arity-mask))

(define runner (test-runner-simple))
(test-runner-current runner)

;; evidence : (Listof String)
;; Lines the next test prints under its values if it fails, then forgets.
(define evidence '())

;; The simple runner names a failing test but not its values. Print both,
;; and the evidence.
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
        (newline)
        (for-each (lambda (line) (display "  ") (display line) (newline)) evidence))
      (set! evidence '()))))

;; --- what the suite reads -----------------------------------------------------

(define arguments (cdr (command-line)))
(define docs-dir (if (pair? arguments) (car arguments) "docs"))
(define readme (if (and (pair? arguments) (pair? (cdr arguments))) (cadr arguments) "README.org"))
(define page (string-append docs-dir "/reference.md"))
(define src-dir
  (if (and (pair? arguments) (pair? (cdr arguments)) (pair? (cddr arguments))) (caddr arguments) "src"))
(define makefile "Makefile")

;; public-libraries : (Listof (Listof Symbol))
;; The eight, in the page's order.
(define public-libraries
  '((circuit) (circuit http-server) (circuit middleware waits) (circuit middleware cors)
    (circuit middleware headers) (circuit router) (circuit websocket) (circuit test)))

;; internal-exports : (Listof (Pair (Listof Symbol) (Listof Symbol)))
;; What a library under src/ exports for the adapter and the tests, which no
;; public library exports, so the page leaves out. Any other library's is ().
(define internal-exports
  '(((circuit request) make-req make-req-view req-body-made)
    ((circuit response) res-body-port res-body-stream
     res-sized-body-inner res-sized-body-length res-sized-body?
     res-tapped-body-inner res-tapped-body-proc res-tapped-body?
     res-wrapped-body-inner res-wrapped-body-proc res-wrapped-body?)))

;; upstream-specs : (Listof (List (Listof Symbol) String String String String))
;; Each library circuit re-exports from: its facade, its repository, the
;; Makefile variable that pins it, its vendored reference and Akku.manifest.
(define upstream-specs
  '(((http-server) "chez-http-server" "SERVER_PIN"
     "vendor/chez-http-server/docs/reference.md" "vendor/chez-http-server/Akku.manifest")
    ((websocket) "chez-websocket" "WEBSOCKET_PIN"
     "vendor/chez-websocket/docs/reference.md" "vendor/chez-websocket/Akku.manifest")))

(define github "https://github.com/Kiyomi-Computation-Systems/")

;; --- text -----------------------------------------------------------------------

;; read-text : String -> (U String #f)
;; The file at PATH as UTF-8, or #f when it can't be read.
(define (read-text path)
  (guard (e (#t #f))
    (let ((text (call-with-port
                 (open-file-input-port path (file-options) (buffer-mode block)
                                       (make-transcoder (utf-8-codec)))
                 get-string-all)))
      (if (eof-object? text) "" text))))

;; string-lines : String -> (Listof String)
(define (string-lines s)
  (let ((n (string-length s)))
    (let loop ((start 0) (i 0) (out '()))
      (cond ((= i n) (reverse (cons (substring s start n) out)))
            ((char=? (string-ref s i) #\newline)
             (loop (+ i 1) (+ i 1) (cons (substring s start i) out)))
            (else (loop start (+ i 1) out))))))

;; joined : String (Listof String) -> String
(define (joined separator strings)
  (if (null? strings)
      ""
      (fold-left (lambda (text s) (string-append text separator s)) (car strings) (cdr strings))))

(define (prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))

(define (suffix? s x)
  (let ((n (string-length s)) (m (string-length x)))
    (and (>= n m) (string=? (substring s (- n m) n) x))))

;; string-search : String String Nat -> (U Nat #f)
;; Where NEEDLE first stands in S at START or after.
(define (string-search s needle start)
  (let ((n (string-length s)) (m (string-length needle)))
    (let loop ((i start))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) needle) i)
            (else (loop (+ i 1)))))))

(define (trim-left s)
  (let ((n (string-length s)))
    (let loop ((i 0))
      (if (and (< i n) (char-whitespace? (string-ref s i))) (loop (+ i 1)) (substring s i n)))))

(define (trim s)
  (let* ((s (trim-left s)) (n (string-length s)))
    (let loop ((j n))
      (if (and (> j 0) (char-whitespace? (string-ref s (- j 1)))) (loop (- j 1)) (substring s 0 j)))))

;; collapse : String -> String
;; S with each run of whitespace one space, and none at either end.
(define (collapse s)
  (let loop ((cs (string->list s)) (out '()) (gap #f))
    (cond ((null? cs) (list->string (reverse out)))
          ((char-whitespace? (car cs)) (loop (cdr cs) out (pair? out)))
          (else (loop (cdr cs) (cons (car cs) (if gap (cons #\space out) out)) #f)))))

;; starts-indented? : String -> Boolean
(define (starts-indented? s)
  (and (> (string-length s) 0) (char-whitespace? (string-ref s 0))))

(define (written datum)
  (call-with-string-output-port (lambda (p) (write datum p))))

(define (symbol<? a b) (string<? (symbol->string a) (symbol->string b)))
(define (sorted-symbols names) (list-sort symbol<? names))

;; repeated : (Listof Symbol) -> (Listof Symbol)
;; Each name NAMES holds more than once, once, sorted.
(define (repeated names)
  (let loop ((rest (sorted-symbols names)) (out '()))
    (cond ((or (null? rest) (null? (cdr rest))) (reverse out))
          ((and (eq? (car rest) (cadr rest)) (not (and (pair? out) (eq? (car out) (car rest)))))
           (loop (cdr rest) (cons (car rest) out)))
          (else (loop (cdr rest) out)))))

(define (without names others) (filter (lambda (x) (not (memq x others))) names))

;; distinct : (Listof Symbol) -> (Listof Symbol)
;; NAMES, each once, sorted.
(define (distinct names)
  (let loop ((rest (sorted-symbols names)) (out '()))
    (cond ((null? rest) (reverse out))
          ((and (pair? out) (eq? (car out) (car rest))) (loop (cdr rest) out))
          (else (loop (cdr rest) (cons (car rest) out))))))

;; --- Markdown, narrowly -------------------------------------------------------------

;; heading-level : String -> (U Nat #f)
;; How many #s begin LINE, when a space follows them.
(define (heading-level line)
  (let ((n (string-length line)))
    (let loop ((i 0))
      (cond ((and (< i n) (char=? (string-ref line i) #\#)) (loop (+ i 1)))
            ((and (> i 0) (< i n) (char=? (string-ref line i) #\space)) i)
            (else #f)))))

;; outside-fences : String -> (Listof String)
;; TEXT's lines but the fences and what they hold.
(define (outside-fences text)
  (let loop ((lines (string-lines text)) (fence? #f) (out '()))
    (cond ((null? lines) (reverse out))
          ((prefix? "```" (car lines)) (loop (cdr lines) (not fence?) out))
          (fence? (loop (cdr lines) fence? out))
          (else (loop (cdr lines) fence? (cons (car lines) out))))))

;; backtick-run : String Nat -> Nat
;; How many backticks stand in S from I.
(define (backtick-run s i)
  (let ((n (string-length s)))
    (let loop ((j i)) (if (and (< j n) (char=? (string-ref s j) #\`)) (loop (+ j 1)) (- j i)))))

;; code-spans : String -> (Listof String)
;; What each inline code span in the Markdown TEXT holds, outside fences: a
;; run of backticks, up to the next run of as many.
(define (code-spans text)
  (let* ((s (joined "\n" (outside-fences text)))
         (n (string-length s)))
    (define (closing start k)
      (let loop ((i start))
        (cond ((>= i n) #f)
              ((char=? (string-ref s i) #\`)
               (let ((m (backtick-run s i))) (if (= m k) i (loop (+ i m)))))
              (else (loop (+ i 1))))))
    (let loop ((i 0) (found '()))
      (cond ((>= i n) (reverse found))
            ((char=? (string-ref s i) #\`)
             (let* ((k (backtick-run s i))
                    (close (closing (+ i k) k)))
               (if close
                   (loop (+ close k) (cons (substring s (+ i k) close) found))
                   (loop (+ i k) found))))
            (else (loop (+ i 1) found))))))

;; words : String -> (Listof String)
;; S split at whitespace, brackets, quotes and commas.
(define (words s)
  (let loop ((cs (string->list s)) (word '()) (out '()))
    (define (flush) (if (null? word) out (cons (list->string (reverse word)) out)))
    (cond ((null? cs) (reverse (flush)))
          ((or (char-whitespace? (car cs)) (memv (car cs) '(#\( #\) #\[ #\] #\{ #\} #\' #\` #\" #\,)))
           (loop (cdr cs) '() (flush)))
          (else (loop (cdr cs) (cons (car cs) word) out)))))

;; inside-fences : String -> (Listof String)
;; The lines TEXT's fences hold.
(define (inside-fences text)
  (let loop ((lines (string-lines text)) (fence? #f) (out '()))
    (cond ((null? lines) (reverse out))
          ((prefix? "```" (car lines)) (loop (cdr lines) (not fence?) out))
          (fence? (loop (cdr lines) fence? (cons (car lines) out)))
          (else (loop (cdr lines) fence? out)))))

;; code-names : String -> (Listof Symbol)
;; Every name in the Markdown TEXT's code: its inline code spans, then its
;; fenced blocks.
(define (code-names text)
  (map string->symbol
       (append (apply append (map words (code-spans text)))
               (apply append (map words (inside-fences text))))))

;; markdown-links : String -> (Listof String)
;; The target of every [text](target) in TEXT, in order.
(define (markdown-links text)
  (let loop ((i 0) (found '()))
    (let ((at (string-search text "](" i)))
      (if (not at)
          (reverse found)
          (let ((end (string-search text ")" (+ at 2))))
            (if (not end)
                (reverse found)
                (loop (+ end 1) (cons (substring text (+ at 2) end) found))))))))

;; github-slug : String -> String
;; A heading's anchor as GitHub makes it: lower case, then only letters,
;; digits, spaces, - and _, each space a -.
(define (github-slug heading)
  (list->string
   (map (lambda (c) (if (char=? c #\space) #\- c))
        (filter (lambda (c) (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\space #\- #\_))))
                (string->list (string-downcase heading))))))

;; page-headings : String -> (Listof (List String Nat Nat))
;; Every heading in the Markdown TEXT, outside fences, in order: its
;; anchor, a repeat getting -1, -2 and so on as GitHub gives it, its level,
;; and its line's index, from 0.
(define (page-headings text)
  (let loop ((lines (string-lines text)) (i 0) (fence? #f) (seen '()) (out '()))
    (if (null? lines)
        (reverse out)
        (let ((line (car lines)))
          (cond
            ((prefix? "```" line) (loop (cdr lines) (+ i 1) (not fence?) seen out))
            ((and (not fence?) (heading-level line))
             => (lambda (level)
                  (let* ((base (github-slug (trim (substring line level (string-length line)))))
                         (count (length (filter (lambda (s) (string=? s base)) seen)))
                         (anchor (if (= count 0) base (string-append base "-" (number->string count)))))
                    (loop (cdr lines) (+ i 1) fence? (cons base seen) (cons (list anchor level i) out)))))
            (else (loop (cdr lines) (+ i 1) fence? seen out)))))))

(define (page-anchors text) (map car (page-headings text)))

;; anchor-sections : String -> (Listof (Pair String String))
;; Each heading's anchor in the Markdown TEXT, with the text under it, down
;; to the next heading of its level or a higher one.
(define (anchor-sections text)
  (let* ((lines (list->vector (string-lines text)))
         (headings (page-headings text)))
    (let loop ((hs headings) (out '()))
      (if (null? hs)
          (reverse out)
          (let* ((h (car hs))
                 (next (find (lambda (later) (<= (cadr later) (cadr h))) (cdr hs)))
                 (end (if next (caddr next) (vector-length lines))))
            (loop (cdr hs)
                  (cons (cons (car h)
                              (joined "\n" (let collect ((i (+ (caddr h) 1)) (acc '()))
                                             (if (>= i end)
                                                 (reverse acc)
                                                 (collect (+ i 1) (cons (vector-ref lines i) acc))))))
                        out)))))))

;; --- the page ---------------------------------------------------------------------

;; An entry: its name, its fenced blocks, each (info . text) with the
;; text's whitespace collapsed, and its other lines.
(define-record-type entry
  (fields name (mutable blocks) (mutable prose)))

;; A section: the library its heading names, and its entries.
(define-record-type section
  (fields library (mutable entries)))

;; code-heading : String String -> (U String #f)
;; What stands between the backticks of LINE, when LINE is MARK, a space,
;; then one code span and nothing else.
(define (code-heading mark line)
  (let ((s (trim line)) (open (string-append mark " `")))
    (and (prefix? open s)
         (suffix? s "`")
         (> (string-length s) (+ (string-length open) 1))
         (let ((inner (substring s (string-length open) (- (string-length s) 1))))
           (and (not (memv #\` (string->list inner))) inner)))))

;; library-heading : String -> (U (Listof Symbol) #f)
(define (library-heading line)
  (let ((inner (code-heading "##" line)))
    (and inner
         (guard (e (#t #f))
           (let* ((port (open-string-input-port inner))
                  (datum (read port)))
             (and (list? datum) (pair? datum) (for-all symbol? datum)
                  (eof-object? (read port))
                  datum))))))

;; entry-heading : String -> (U Symbol #f)
(define (entry-heading line)
  (let ((inner (code-heading "###" line)))
    (and inner
         (not (exists char-whitespace? (string->list inner)))
         (string->symbol inner))))

;; parse-page : String -> (Values (Listof Section) (Listof String) (Listof String)
;;                                (Listof (Pair String (Listof String))))
;; TEXT's sections, what breaks the convention, each naming its line,
;; every line outside a fence, and the fenced blocks before the first ##
;; heading, each (info . its lines as written).
(define (parse-page text)
  (let ((sections '()) (problems '()) (outside '()) (intro '()) (sectioned? #f)
        (current-section #f) (current-entry #f) (fence #f) (fence-line 0) (fence-lines '()))
    (define (problem n what)
      (set! problems (cons (string-append "line " (number->string n) ": " what) problems)))
    (unless (string=? (trim (car (string-lines text))) "# API reference")
      (problem 1 "the page begins with no # API reference"))
    (let loop ((lines (string-lines text)) (n 1))
      (unless (null? lines)
        (let ((line (car lines)))
          (cond
            (fence
             (if (string=? (trim line) "```")
                 (let ((block-lines (reverse fence-lines)))
                   (cond (current-entry
                          (entry-blocks-set! current-entry
                                             (append (entry-blocks current-entry)
                                                     (list (cons fence (collapse (joined "\n" block-lines)))))))
                         ((not sectioned?) (set! intro (cons (cons fence block-lines) intro))))
                   (set! fence #f)
                   (set! fence-lines '()))
                 (set! fence-lines (cons line fence-lines))))
            ((prefix? "```" line)
             (set! fence (trim (substring line 3 (string-length line))))
             (set! fence-line n))
            (else
             (set! outside (cons line outside))
             (let ((level (heading-level line)))
               (cond
                 ((not level)
                  (when current-entry
                    (entry-prose-set! current-entry (append (entry-prose current-entry) (list line)))))
                 ((= level 1)
                  ;; Line 1 is the title's, checked above.
                  (unless (= n 1)
                    (problem n (string-append "a # heading but the title on line 1: " line))))
                 ((= level 2)
                  (set! current-entry #f)
                  (set! sectioned? #t)
                  (let ((library (library-heading line)))
                    (if library
                        (let ((s (make-section library '())))
                          (set! sections (cons s sections))
                          (set! current-section s))
                        (begin
                          (set! current-section #f)
                          (problem n (string-append "a ## heading that names no library: " line))))))
                 ((= level 3)
                  (let ((name (entry-heading line)))
                    (cond
                      ((not name)
                       (set! current-entry #f)
                       (problem n (string-append "a ### heading that names no one name: " line)))
                      ((not current-section)
                       (set! current-entry #f)
                       (problem n (string-append "an entry outside any library's section: " line)))
                      (else
                       (let ((e (make-entry name '() '())))
                         (section-entries-set! current-section
                                               (append (section-entries current-section) (list e)))
                         (set! current-entry e))))))
                 (else (problem n (string-append "a heading deeper than ###: " line))))))))
        (loop (cdr lines) (+ n 1))))
    (when fence
      (problem fence-line "a fence opened here is never closed"))
    (values (reverse sections) (reverse problems) (reverse outside) (reverse intro))))

(define (entry-links e) (markdown-links (joined " " (entry-prose e))))

;; github-target : String -> (U (List String String String String (U String #f)) #f)
;; For a link into one of the organization's repositories, the repository,
;; blob or tree, the ref, the path after it and the anchor, or #f.
(define (github-target url)
  (and (prefix? github url)
       (let* ((rest (substring url (string-length github) (string-length url)))
              (hash (string-search rest "#" 0))
              (path (if hash (substring rest 0 hash) rest))
              (anchor (and hash (substring rest (+ hash 1) (string-length rest))))
              (parts (split-at-slashes path)))
         (and (>= (length parts) 3)
              (list (car parts) (cadr parts) (caddr parts) (joined "/" (cdddr parts)) anchor)))))

(define (split-at-slashes s)
  (let ((n (string-length s)))
    (let loop ((start 0) (i 0) (out '()))
      (cond ((= i n) (reverse (cons (substring s start n) out)))
            ((char=? (string-ref s i) #\/) (loop (+ i 1) (+ i 1) (cons (substring s start i) out)))
            (else (loop start (+ i 1) out))))))

(define (without-anchor url)
  (let ((hash (string-search url "#" 0))) (if hash (substring url 0 hash) url)))

(define (relative-link? url)
  (not (or (string-search url "://" 0) (prefix? "#" url) (prefix? "mailto:" url))))

;; --- links into the pinned repositories, in any text ---------------------------

;; repository-refs : String -> (Listof (List String String String))
;; Every link in TEXT into chez-http-server's or chez-websocket's
;; repository at blob/<ref> or tree/<ref>, as its repository, blob or tree,
;; and the ref, in order. TEXT is read as text: Markdown, Org or anything.
(define (repository-refs text)
  (let ((host "github.com/Kiyomi-Computation-Systems/"))
    (let loop ((i 0) (found '()))
      (let ((at (string-search text host i)))
        (if (not at)
            (reverse found)
            (let* ((start (+ at (string-length host)))
                   (end (url-end text start))
                   (parts (split-at-slashes (substring text start end))))
              (loop end
                    (if (and (>= (length parts) 3)
                             (member (car parts) '("chez-http-server" "chez-websocket"))
                             (member (cadr parts) '("blob" "tree")))
                        (cons (list (car parts) (cadr parts) (caddr parts)) found)
                        found))))))))

;; url-end : String Nat -> Nat
;; Where the URL that runs on from START ends: at whitespace, a bracket, a
;; quote, a # or a ?.
(define (url-end text start)
  (let ((n (string-length text)))
    (let loop ((i start))
      (if (or (= i n)
              (let ((c (string-ref text i)))
                (or (char-whitespace? c) (memv c '(#\) #\] #\> #\< #\" #\' #\# #\?)))))
          i
          (loop (+ i 1))))))

;; --- the source ---------------------------------------------------------------------

;; A library under src/: its file, its name, its export clause's names,
;; the names its body defines, its signature comments, each
;; (name . "name : Type"), and its alias comments, each (name . type).
(define-record-type source
  (fields path name exports defines signatures aliases))

;; sls-files : String -> (Listof String)
;; Every .sls file under DIR, sorted.
(define (sls-files dir)
  (list-sort string<?
             (let walk ((dir dir))
               (apply append
                      (map (lambda (name)
                             (let ((path (string-append dir "/" name)))
                               (cond ((file-directory? path) (walk path))
                                     ((suffix? path ".sls") (list path))
                                     (else '()))))
                           (directory-list dir))))))

;; read-data : String -> (U (Listof Any) #f)
(define (read-data path)
  (guard (e (#t #f))
    (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                          (make-transcoder (utf-8-codec)))
      (lambda (port)
        (let loop ((found '()))
          (let ((datum (read port)))
            (if (eof-object? datum) (reverse found) (loop (cons datum found)))))))))

;; library-form? : Any -> Boolean
(define (library-form? d)
  (and (list? d) (>= (length d) 4) (eq? (car d) 'library)
       (list? (cadr d)) (for-all symbol? (cadr d))
       (pair? (caddr d)) (eq? (car (caddr d)) 'export)
       (pair? (cadddr d)) (eq? (car (cadddr d)) 'import)))

;; export-names : (Listof Any) -> (Listof Symbol)
;; The names an export clause's specs export, renames included.
(define (export-names specs)
  (apply append
         (map (lambda (spec)
                (cond ((symbol? spec) (list spec))
                      ((and (list? spec) (pair? spec) (eq? (car spec) 'rename))
                       (map cadr (filter (lambda (p) (and (list? p) (= (length p) 2))) (cdr spec))))
                      (else '())))
              specs)))

;; defined-names : Any -> (Listof Symbol)
;; The names a body form defines: define, define-syntax,
;; define-record-type and define-condition-type.
(define (defined-names form)
  (if (not (and (list? form) (pair? form) (pair? (cdr form))))
      '()
      (case (car form)
        ((define)
         (let loop ((target (cadr form)))
           (cond ((symbol? target) (list target)) ((pair? target) (loop (car target))) (else '()))))
        ((define-syntax) (if (symbol? (cadr form)) (list (cadr form)) '()))
        ((define-record-type) (record-names form))
        ((define-condition-type) (condition-names form))
        (else '()))))

;; record-names : (Listof Any) -> (Listof Symbol)
;; The type's name, its constructor and predicate, and its fields'
;; accessors and mutators, named or by R6RS's defaults.
(define (record-names form)
  (let* ((spec (cadr form))
         (type (if (pair? spec) (car spec) spec)))
    (if (not (symbol? type))
        '()
        (let* ((type-name (symbol->string type))
               (made (if (pair? spec)
                         (filter symbol? (cdr spec))
                         (list (string->symbol (string-append "make-" type-name))
                               (string->symbol (string-append type-name "?")))))
               (fields (apply append
                              (map (lambda (clause)
                                     (if (and (list? clause) (pair? clause) (eq? (car clause) 'fields))
                                         (cdr clause)
                                         '()))
                                   (cddr form)))))
          (define (default name suffix)
            (string->symbol (string-append type-name "-" (symbol->string name) suffix)))
          (append (list type) made
                  (apply append
                         (map (lambda (f)
                                (cond ((symbol? f) (list (default f "")))
                                      ((and (list? f) (= (length f) 2) (symbol? (cadr f)))
                                       (if (eq? (car f) 'mutable)
                                           (list (default (cadr f) "") (default (cadr f) "-set!"))
                                           (list (default (cadr f) ""))))
                                      ((and (list? f) (> (length f) 2)) (filter symbol? (cddr f)))
                                      (else '())))
                              fields)))))))

;; condition-names : (Listof Any) -> (Listof Symbol)
;; (define-condition-type &name &parent make-name name? (field accessor) ...)
(define (condition-names form)
  (if (< (length form) 5)
      '()
      (append (filter symbol? (list (list-ref form 1) (list-ref form 3) (list-ref form 4)))
              (apply append
                     (map (lambda (f) (if (and (list? f) (= (length f) 2) (symbol? (cadr f))) (list (cadr f)) '()))
                          (list-tail form 5))))))

;; comment-text : String -> (U String #f)
;; LINE's text after `;; `, when LINE is a comment of two semicolons: ""
;; for a bare `;;`, #f for any other line, `;;;` among them.
(define (comment-text line)
  (let ((s (trim-left line)))
    (cond ((string=? (trim s) ";;") "")
          ((prefix? ";; " s) (substring s 3 (string-length s)))
          (else #f))))

;; name-tokens : String -> (U (Listof Symbol) #f)
;; The names in S, split at commas and spaces, when every piece is a name.
(define (name-tokens s)
  (let ((pieces (filter (lambda (p) (not (string=? p "")))
                        (let loop ((cs (string->list s)) (word '()) (out '()))
                          (cond ((null? cs) (reverse (cons (list->string (reverse word)) out)))
                                ((memv (car cs) '(#\space #\,))
                                 (loop (cdr cs) '() (cons (list->string (reverse word)) out)))
                                (else (loop (cdr cs) (cons (car cs) word) out)))))))
    (and (pair? pieces)
         (for-all (lambda (p)
                    (not (exists (lambda (c) (memv c '(#\( #\) #\[ #\] #\{ #\} #\" #\' #\` #\| #\;)))
                                 (string->list p))))
                  pieces)
         (map string->symbol pieces))))

;; signature-line : String -> (U (Pair (Listof Symbol) String) #f)
;; A comment's text that opens a signature, NAMES : TYPE, or NAMES : alone
;; with the type on the lines under it: its names and the type it gives.
(define (signature-line text)
  (and (> (string-length text) 0)
       (not (char-whitespace? (string-ref text 0)))
       (let* ((at (string-search text " : " 0))
              (names (cond (at (substring text 0 at))
                           ((suffix? text " :") (substring text 0 (- (string-length text) 2)))
                           (else #f))))
         (and names
              (let ((tokens (name-tokens names)))
                (and tokens
                     (cons tokens (if at (substring text (+ at 3) (string-length text)) ""))))))))

;; alias-line : String -> (U (Pair Symbol String) #f)
;; A line that opens a type alias, NAME = TYPE: the name and the type's
;; text on the line.
(define (alias-line text)
  (and (> (string-length text) 0)
       (not (char-whitespace? (string-ref text 0)))
       (let ((at (string-search text " = " 0)))
         (and at
              (let ((tokens (name-tokens (substring text 0 at))))
                (and tokens (= (length tokens) 1)
                     (cons (car tokens) (substring text (+ at 3) (string-length text)))))))))

;; commented : String (String -> (U (Pair Any String) #f)) -> (Listof (Pair Any String))
;; Each comment in TEXT that OPENER opens, its text joined with each
;; comment line under it whose text begins with a space.
(define (commented text opener)
  (let loop ((lines (string-lines text)) (found '()))
    (if (null? lines)
        (reverse found)
        (let* ((c (comment-text (car lines)))
               (opened (and c (opener c))))
          (if (not opened)
              (loop (cdr lines) found)
              (let more ((rest (cdr lines)) (body (cdr opened)))
                (let ((next (and (pair? rest) (comment-text (car rest)))))
                  (if (and next (starts-indented? next))
                      (more (cdr rest) (string-append body " " next))
                      (loop rest (cons (cons (car opened) body) found))))))))))

;; signature-comments : String -> (Listof (Pair Symbol String))
;; Every signature comment in TEXT, as (name . "name : Type"), whitespace
;; collapsed: a line NAMES : TYPE, then each comment line under it whose
;; text begins with a space. A line of several names gives each one.
(define (signature-comments text)
  (apply append
         (map (lambda (found)
                (map (lambda (name)
                       (cons name (collapse (string-append (symbol->string name) " : " (cdr found)))))
                     (car found)))
              (commented text signature-line))))

;; balanced : String -> String
;; S collapsed, cut where its balanced expression ends when it begins with
;; (: the prose after it is no part of the type.
(define (balanced s)
  (let ((s (collapse s)))
    (if (not (prefix? "(" s))
        s
        (let loop ((i 0) (depth 0))
          (cond ((= i (string-length s)) s)
                ((char=? (string-ref s i) #\() (loop (+ i 1) (+ depth 1)))
                ((char=? (string-ref s i) #\))
                 (if (= depth 1) (substring s 0 (+ i 1)) (loop (+ i 1) (- depth 1))))
                (else (loop (+ i 1) depth)))))))

;; alias-comments : String -> (Listof (Pair Symbol String))
;; Every type alias comment in TEXT, `;; NAME = TYPE` and the comment lines
;; under it that begin with a space, as (name . type), the type balanced.
(define (alias-comments text)
  (map (lambda (found) (cons (car found) (balanced (cdr found))))
       (commented text alias-line)))

;; block-aliases : (Listof String) -> (Listof (Pair Symbol String))
;; The aliases a page's block holds: a line NAME = TYPE, then each line
;; under it that begins with a space, the type collapsed.
(define (block-aliases lines)
  (let loop ((lines lines) (current #f) (out '()))
    (let ((flushed (if current (cons (cons (car current) (collapse (cdr current))) out) out)))
      (cond ((null? lines) (reverse flushed))
            ((and current (starts-indented? (car lines)))
             (loop (cdr lines) (cons (car current) (string-append (cdr current) " " (car lines))) out))
            (else (loop (cdr lines) (alias-line (car lines)) flushed))))))

;; --- the upstreams' signatures --------------------------------------------------------

;; signature-pairs : (Pair (Listof Symbol) String) -> (Listof (Pair Symbol String))
;; A signature line's names, each with "name : Type", the type collapsed.
(define (signature-pairs found)
  (map (lambda (name) (cons name (collapse (string-append (symbol->string name) " : " (cdr found)))))
       (car found)))

;; span-signatures : String -> (Listof (Pair Symbol String))
;; Each inline code span in the Markdown TEXT that is a signature, NAMES :
;; TYPE, its whitespace collapsed: one pair a name.
(define (span-signatures text)
  (apply append
         (map (lambda (span)
                (let ((found (signature-line (collapse span))))
                  (if (and found (not (string=? (cdr found) ""))) (signature-pairs found) '())))
              (code-spans text))))

;; split-at-bars : String -> (Listof String)
(define (split-at-bars s)
  (let ((n (string-length s)))
    (let loop ((start 0) (i 0) (out '()))
      (cond ((= i n) (reverse (cons (substring s start n) out)))
            ((char=? (string-ref s i) #\|) (loop (+ i 1) (+ i 1) (cons (substring s start i) out)))
            (else (loop start (+ i 1) out))))))

;; lone-span : String -> (U String #f)
;; What CELL's code span holds, when CELL is one code span and nothing else.
(define (lone-span cell)
  (and (> (string-length cell) 2)
       (prefix? "`" cell)
       (suffix? cell "`")
       (let ((inner (substring cell 1 (- (string-length cell) 1))))
         (and (not (memv #\` (string->list inner))) inner))))

;; table-signatures : String -> (Listof (Pair Symbol String))
;; Each table row, outside fences, in the Markdown TEXT whose first cell is
;; one name in a code span and whose second is one code span: that name,
;; with "name : " and the span's text, collapsed. A row whose second cell
;; is prose, a code span in it or not, gives none.
(define (table-signatures text)
  (apply append
         (map (lambda (line)
                (let ((s (trim line)))
                  (if (and (> (string-length s) 1) (prefix? "|" s) (suffix? s "|"))
                      (let ((cells (map trim (split-at-bars (substring s 1 (- (string-length s) 1))))))
                        (let* ((name (and (>= (length cells) 2) (lone-span (car cells))))
                               (tokens (and name (name-tokens name)))
                               (type (and tokens (= (length tokens) 1) (lone-span (cadr cells)))))
                          (if type
                              (list (cons (car tokens) (collapse (string-append name " : " type))))
                              '())))
                      '())))
              (outside-fences text))))

;; text-fences : String -> (Listof (Listof String))
;; The lines of each fence in the Markdown TEXT whose info string is text.
(define (text-fences text)
  (let loop ((lines (string-lines text)) (fence #f) (block '()) (out '()))
    (cond ((null? lines) (reverse out))
          (fence
           (if (string=? (trim (car lines)) "```")
               (loop (cdr lines) #f '() (if (string=? fence "text") (cons (reverse block) out) out))
               (loop (cdr lines) fence (cons (car lines) block) out)))
          ((prefix? "```" (car lines))
           (loop (cdr lines) (trim (substring (car lines) 3 (string-length (car lines)))) '() out))
          (else (loop (cdr lines) #f '() out)))))

;; block-signatures : (Listof String) -> (Listof (Pair Symbol String))
;; The signatures a text fence's LINES hold: a line NAMES : TYPE, or NAMES :
;; with the type below, then each line under it that begins with whitespace.
(define (block-signatures lines)
  (let loop ((lines lines) (current #f) (out '()))
    (let ((flushed (if (and current (not (string=? (collapse (cdr current)) "")))
                       (append out (signature-pairs current))
                       out)))
      (cond ((null? lines) flushed)
            ((and current (starts-indented? (car lines)))
             (loop (cdr lines) (cons (car current) (string-append (cdr current) " " (car lines))) out))
            (else (loop (cdr lines) (signature-line (car lines)) flushed))))))

;; documented-signatures : String -> (Listof (Pair Symbol String))
;; Every signature an upstream's reference, the Markdown TEXT, gives: in a
;; text fence, as a table row's name and type, and as an inline code span.
(define (documented-signatures text)
  (append (apply append (map block-signatures (text-fences text)))
          (table-signatures text)
          (span-signatures text)))

;; read-source : String -> (U Source String)
;; The library at PATH, or why it can't be read as one.
(define (read-source path)
  (let ((data (read-data path))
        (text (read-text path)))
    (cond ((not (and data text)) (string-append path ": it can't be read"))
          ((not (and (= (length data) 1) (library-form? (car data))))
           (string-append path ": it holds no one library form"))
          (else
           (let ((form (car data)))
             (make-source path (cadr form) (export-names (cdr (caddr form)))
                          (apply append (map defined-names (list-tail form 4)))
                          (signature-comments text)
                          (alias-comments text)))))))

;; --- arities ---------------------------------------------------------------------------

;; signature-arguments : String -> (U String #f)
;; What a signature, "name : ARGS -> RESULT", takes: the text before its
;; first -> that stands in no () or [], or #f when it has none.
(define (signature-arguments sig)
  (let ((colon (string-search sig " : " 0)))
    (and colon
         (let* ((type (substring sig (+ colon 3) (string-length sig)))
                (n (string-length type)))
           (let loop ((i 0) (depth 0))
             (cond ((>= (+ i 1) n) #f)
                   ((memv (string-ref type i) '(#\( #\[)) (loop (+ i 1) (+ depth 1)))
                   ((memv (string-ref type i) '(#\) #\])) (loop (+ i 1) (- depth 1)))
                   ((and (= depth 0)
                         (char=? (string-ref type i) #\-) (char=? (string-ref type (+ i 1)) #\>)
                         (or (= i 0) (char-whitespace? (string-ref type (- i 1))))
                         (or (= (+ i 2) n) (char-whitespace? (string-ref type (+ i 2)))))
                    (trim (substring type 0 i)))
                   (else (loop (+ i 1) depth))))))))

;; argument-tokens : String -> (Listof (U 'item 'open 'close 'rest 'bad))
;; ARGS as items: a type or a (...) group is an item, [ and ] open and
;; close optional items, and ... makes the item before it any number.
(define (argument-tokens s)
  (let ((n (string-length s)))
    (define (group-end i)
      (let loop ((j i) (depth 0))
        (cond ((= j n) #f)
              ((char=? (string-ref s j) #\() (loop (+ j 1) (+ depth 1)))
              ((char=? (string-ref s j) #\)) (if (= depth 1) (+ j 1) (loop (+ j 1) (- depth 1))))
              (else (loop (+ j 1) depth)))))
    (define (word-end i)
      (let loop ((j i))
        (if (or (= j n) (char-whitespace? (string-ref s j)) (memv (string-ref s j) '(#\( #\) #\[ #\])))
            j
            (loop (+ j 1)))))
    (let loop ((i 0) (out '()))
      (cond ((= i n) (reverse out))
            ((char-whitespace? (string-ref s i)) (loop (+ i 1) out))
            ((char=? (string-ref s i) #\[) (loop (+ i 1) (cons 'open out)))
            ((char=? (string-ref s i) #\]) (loop (+ i 1) (cons 'close out)))
            ((char=? (string-ref s i) #\()
             (let ((end (group-end i))) (if end (loop end (cons 'item out)) (reverse (cons 'bad out)))))
            ((char=? (string-ref s i) #\)) (reverse (cons 'bad out)))
            (else
             (let ((end (word-end i)))
               (loop end (cons (if (string=? (substring s i end) "...") 'rest 'item) out))))))))

;; argument-counts : (Listof Token) -> (U (List (Listof Nat) Boolean (Listof Token)) #f)
;; The counts of arguments TOKENS take up to a ] or their end, whether an
;; item takes any number, and the tokens left; #f when they don't parse.
;; Each [ ] is optional on its own: [a] [b] takes none, one or both.
(define (argument-counts tokens)
  (let loop ((tokens tokens) (counts '(0)) (any? #f))
    (cond
      ((or (null? tokens) (eq? (car tokens) 'close)) (list counts any? tokens))
      ((eq? (car tokens) 'item)
       (if (and (pair? (cdr tokens)) (eq? (cadr tokens) 'rest))
           (loop (cddr tokens) counts #t)
           (loop (cdr tokens) (map (lambda (c) (+ c 1)) counts) any?)))
      ((eq? (car tokens) 'open)
       (let ((inner (argument-counts (cdr tokens))))
         (and inner
              (pair? (caddr inner))
              (loop (cdr (caddr inner))
                    (append counts
                            (apply append (map (lambda (c) (map (lambda (d) (+ c d)) (car inner))) counts)))
                    (or any? (cadr inner))))))
      (else #f))))

;; arity-mask : String -> (U Integer #f)
;; The counts of arguments ARGS takes, as procedure-arity-mask writes them:
;; bit n for n arguments, and every bit from the least count up when an
;; item takes any number. #f when ARGS doesn't parse.
(define (arity-mask args)
  (let ((parsed (argument-counts (argument-tokens args))))
    (and parsed
         (null? (caddr parsed))
         (if (cadr parsed)
             (bitwise-arithmetic-shift-left -1 (apply min (car parsed)))
             (fold-left (lambda (mask c) (bitwise-ior mask (bitwise-arithmetic-shift-left 1 c)))
                        0 (car parsed))))))

;; counts-text : (U Integer #f) -> String
;; A mask as words: "1", "1 or 2", "2 or more".
(define (counts-text mask)
  (if (not (integer? mask))
      "no counts it can read"
      (let* ((top (let loop ((k 0))
                    (cond ((>= mask 0) #f)
                          ((= (bitwise-arithmetic-shift-right mask k) -1) k)
                          (else (loop (+ k 1))))))
             (limit (or top (bitwise-length mask)))
             (finite (filter (lambda (k) (bitwise-bit-set? mask k))
                             (let loop ((k (- limit 1)) (out '())) (if (< k 0) out (loop (- k 1) (cons k out))))))
             (listed (let ((parts (map number->string finite)))
                       (cond ((null? parts) #f)
                             ((null? (cdr parts)) (car parts))
                             (else (string-append (joined ", " (reverse (cdr (reverse parts))))
                                                  " or " (car (reverse parts))))))))
        (cond ((and top listed) (string-append listed ", or " (number->string top) " or more"))
              (top (string-append (number->string top) " or more"))
              (listed listed)
              (else "none")))))

;; --- the pins --------------------------------------------------------------------------

;; pin-tag : String String -> (U String #f)
;; The tag after # on the Makefile line `VARIABLE := <sha>  # <tag>`.
(define (pin-tag text variable)
  (let loop ((lines (string-lines text)))
    (if (null? lines)
        #f
        (let ((line (car lines)))
          (if (and (prefix? variable line)
                   (prefix? ":=" (trim-left (substring line (string-length variable) (string-length line)))))
              (let ((hash (string-search line "#" 0)))
                (and hash
                     (let ((tag (trim (substring line (+ hash 1) (string-length line)))))
                       (and (not (string=? tag "")) tag))))
              (loop (cdr lines)))))))

;; manifest-package : (Listof Any) -> (U (Pair String String) #f)
;; The name and the version an Akku.manifest's data give, in
;; (akku-package (NAME VERSION) ...).
(define (manifest-package data)
  (let ((form (find (lambda (d)
                      (and (list? d) (>= (length d) 2) (eq? (car d) 'akku-package)
                           (list? (cadr d)) (= (length (cadr d)) 2)
                           (string? (car (cadr d))) (string? (cadr (cadr d)))))
                    data)))
    (and form (cons (car (cadr form)) (cadr (cadr form))))))

;; release-tag? : Any -> Boolean
;; vX.Y.Z, each a run of digits.
(define (release-tag? tag)
  (and (string? tag)
       (prefix? "v" tag)
       (let ((parts (split-at-slashes (list->string (map (lambda (c) (if (char=? c #\.) #\/ c))
                                                        (string->list (substring tag 1 (string-length tag))))))))
         (and (= (length parts) 3)
              (for-all (lambda (p) (and (> (string-length p) 0) (for-all char-numeric? (string->list p))))
                       parts)))))

;; --- loading what the suite reads ------------------------------------------------------

;; environments : (Listof (Pair (Listof Symbol) (U Environment #f)))
;; Each public library's and each upstream's, once Chez has loaded it from
;; the library path; #f when it can't.
(define environments
  (map (lambda (library) (cons library (guard (e (#t #f)) (environment library))))
       (append public-libraries (map car upstream-specs))))

;; exports-of : (Listof Symbol) -> (U (Listof Symbol) #f)
;; LIBRARY's exports, sorted, once Chez has loaded it from the library
;; path; #f when it can't.
(define (exports-of library)
  (guard (e (#t #f))
    (environment library)
    (sorted-symbols (library-exports library))))

;; binding : (Listof Symbol) Symbol -> (U (Pair 'value Any) (List 'syntax) (List 'unloadable))
;; What NAME is bound to in LIBRARY: its value, or syntax, which has none
;; to evaluate.
(define (binding library name)
  (let ((env (cond ((assoc library environments) => cdr) (else #f))))
    (if (not env)
        (list 'unloadable)
        (guard (e (#t (list 'syntax)))
          (cons 'value (eval name env))))))

;; An upstream: the library circuit re-exports from, its repository, the
;; Makefile variable that pins it, its reference and manifest as vendored,
;; and, read, its exports, its package's name and version, its tag (v and
;; that version), the Makefile's tag, its reference's text, and that
;; reference's sections by anchor.
(define-record-type upstream
  (fields library repo variable reference manifest exports package tag makefile-tag
          reference-text sections))

(define makefile-text (or (read-text makefile) ""))

;; upstreams : (Listof Upstream)
;; None when reading them raises: every re-export then fails, as defined
;; nowhere.
(define upstreams
  (guard (e (#t '()))
    (map (lambda (spec)
           (let* ((reference (list-ref spec 3))
                  (manifest (list-ref spec 4))
                  (package (manifest-package (or (read-data manifest) '())))
                  (text (or (read-text reference) "")))
             (make-upstream (car spec) (cadr spec) (caddr spec) reference manifest
                            (or (exports-of (car spec)) '())
                            package
                            (and package (string-append "v" (cdr package)))
                            (pin-tag makefile-text (caddr spec))
                            text
                            (anchor-sections text))))
         upstream-specs)))

(define (upstream-of-repo repo)
  (find (lambda (u) (string=? (upstream-repo u) repo)) upstreams))

;; upstream-signatures : (Listof (Pair String (Listof (Pair Symbol String))))
;; Each upstream's repository, with every signature its reference gives.
(define upstream-signatures
  (guard (e (#t '()))
    (map (lambda (u) (cons (upstream-repo u) (documented-signatures (upstream-reference-text u))))
         upstreams)))

;; upstream-signature : Upstream Symbol -> (U String (List Symbol String (Listof String)))
;; The one signature U's reference gives NAME, or what is wrong: none, or
;; two that differ.
(define (upstream-signature u name)
  (let* ((all (cond ((assoc (upstream-repo u) upstream-signatures) => cdr) (else '())))
         (found (fold-left (lambda (types p)
                             (if (and (eq? (car p) name) (not (member (cdr p) types)))
                                 (append types (list (cdr p)))
                                 types))
                           '() all)))
    (if (= (length found) 1)
        (car found)
        (list 'signatures-in (upstream-reference u) found))))

;; reference-url : Upstream -> String
(define (reference-url u)
  (string-append github (upstream-repo u) "/blob/" (or (upstream-tag u) "<no tag>")
                 "/docs/reference.md"))

;; names-it? : Upstream String Symbol -> Boolean
;; Whether U's reference, under ANCHOR, or anywhere for #f, names NAME in a
;; code span.
(define (names-it? u anchor name)
  (let ((text (if anchor
                  (cond ((assoc anchor (upstream-sections u)) => cdr) (else #f))
                  (upstream-reference-text u))))
    (and text (memq name (code-names text)) #t)))

(define src-reads
  (guard (e (#t (list (string-append src-dir ": " (describe e)))))
    (map read-source (sls-files src-dir))))

(define sources (filter source? src-reads))

;; public-exports : (Listof (Pair (Listof Symbol) (U (Listof Symbol) #f)))
(define public-exports (map (lambda (library) (cons library (exports-of library))) public-libraries))

(define all-public-names
  (apply append (map (lambda (p) (or (cdr p) '())) public-exports)))

;; origin : (Listof Symbol) Symbol
;;          -> (U (Pair 'upstream Upstream) (Pair 'defined Source) (Pair Symbol Any))
;; Where LIBRARY's NAME comes from: the upstream whose facade binds it to
;; the same value, by eq?, or, when both bind it to syntax, which has none,
;; the one that exports it while src/ defines it nowhere; otherwise the one
;; library under src/ that defines and exports it.
(define origin-table (make-hashtable equal-hash equal?))

(define (origin library name)
  (let ((key (cons library name)))
    (or (hashtable-ref origin-table key #f)
        (let ((found (find-origin library name)))
          (hashtable-set! origin-table key found)
          found))))

(define (find-origin library name)
  (let* ((defining (filter (lambda (s) (and (memq name (source-exports s)) (memq name (source-defines s))))
                           sources))
         (here (binding library name))
         (u (find (lambda (u)
                    (and (memq name (upstream-exports u))
                         (let ((there (binding (upstream-library u) name)))
                           (case (car here)
                             ((value) (and (eq? (car there) 'value) (eq? (cdr here) (cdr there))))
                             ((syntax) (and (eq? (car there) 'syntax) (null? defining)))
                             (else #f)))))
                  upstreams)))
    (cond (u (cons 'upstream u))
          ((= (length defining) 1) (cons 'defined (car defining)))
          ((pair? defining) (cons 'defined-in (map source-path defining)))
          (else (cons 'defined-nowhere #f)))))

;; source-signature : Source Symbol -> (U String (List Symbol String Nat))
;; NAME's one signature comment in S, or what is wrong.
(define (source-signature s name)
  (let ((found (filter (lambda (p) (eq? (car p) name)) (source-signatures s))))
    (if (= (length found) 1)
        (cdar found)
        (list 'signature-comments-in (source-path s) (length found)))))

;; src-aliases : (Listof (List Symbol String String))
;; Every alias comment under src/: its name, its type and its file.
(define src-aliases
  (apply append
         (map (lambda (s) (map (lambda (a) (list (car a) (cdr a) (source-path s))) (source-aliases s)))
              sources)))

;; alias-types : Symbol -> (Listof String)
;; The types src/'s alias comments give NAME, each once.
(define (alias-types name)
  (fold-left (lambda (types a)
               (if (and (eq? (car a) name) (not (member (cadr a) types))) (append types (list (cadr a))) types))
             '() src-aliases))

;; --- the page, read ------------------------------------------------------------------

(define page-text (read-text page))

;; page-read : (List (Listof Section) (Listof String) (Listof String) (Listof (Pair String (Listof String))))
(define page-read
  (guard (e (#t (list '() (list (string-append "unparsed: " (describe e))) '() '())))
    (if page-text
        (call-with-values (lambda () (parse-page page-text)) list)
        (list '() (list "unreadable") '() '()))))

(define page-sections (car page-read))
(define page-problems (cadr page-read))
(define page-outside (caddr page-read))
(define page-intro (cadddr page-read))

;; page-aliases : (Listof (Pair Symbol String))
;; The aliases in the intro's text blocks, in order.
(define page-aliases
  (apply append (map (lambda (b) (if (string=? (car b) "text") (block-aliases (cdr b)) '())) page-intro)))

;; entries-of : (Listof Symbol) -> (Listof Entry)
;; Every entry under the sections that name LIBRARY.
(define (entries-of library)
  (apply append (map section-entries
                     (filter (lambda (s) (equal? (section-library s) library)) page-sections))))

;; guide-names : String -> (U (Listof Symbol) #f)
;; The names in the code spans of the docs page at the relative URL, or #f
;; when there is no such page.
(define guide-table (make-hashtable string-hash string=?))

(define (guide-names url)
  (let ((hit (hashtable-ref guide-table url 'unread)))
    (if (eq? hit 'unread)
        (let* ((text (read-text (string-append docs-dir "/" url)))
               (names (and text (code-names text))))
          (hashtable-set! guide-table url names)
          names)
        hit)))

;; =====================================================================================

(test-begin "reference")

;; --- the readers, on inputs written here -------------------------------------------

(test-equal "parse-page reads sections, entries, their blocks and links, the intro's blocks, and no heading inside a fence"
  '((((lib one) (a (("text" . "a : Nat -> Nat")) ("x.md"))
                (b? () ("https://example.com/r.md#b")))
     ((lib two)))
    ()
    (("text" "A = (B" "      C)")))
  (guard (e (#t (list 'raised (describe e))))
    (let-values (((sections problems outside intro)
                  (parse-page (joined "\n" '("# API reference" "```text" "A = (B" "      C)" "```"
                                             "" "## `(lib one)`" ""
                                             "```scheme" "## not a heading" "### `nor-this`" "```"
                                             "### `a`" "" "```text" "a :   Nat" "  -> Nat" "```"
                                             "Does a. See" "[x](x.md)." "### `b?`"
                                             "One line, [up](https://example.com/r.md#b)."
                                             "## `(lib two)`" "")))))
      (list (map (lambda (s)
                   (cons (section-library s)
                         (map (lambda (e) (list (entry-name e) (entry-blocks e) (entry-links e)))
                              (section-entries s))))
                 sections)
            problems
            intro))))

(test-equal "parse-page names each heading out of the convention, and a fence never closed"
  '("line 1: the page begins with no # API reference"
    "line 2: a # heading but the title on line 1: # Second title"
    "line 3: an entry outside any library's section: ### `early`"
    "line 4: a ## heading that names no library: ## Prose"
    "line 5: an entry outside any library's section: ### `lost`"
    "line 7: a ### heading that names no one name: ### `two words`"
    "line 8: a ### heading that names no one name: ### plain"
    "line 9: a heading deeper than ###: #### `deep`"
    "line 10: a ## heading that names no library: ## `(lib) extra`"
    "line 11: a fence opened here is never closed")
  (guard (e (#t (list 'raised (describe e))))
    (let-values (((sections problems outside intro)
                  (parse-page (joined "\n" '("# Other" "# Second title" "### `early`" "## Prose"
                                             "### `lost`" "## `(lib)`" "### `two words`" "### plain"
                                             "#### `deep`" "## `(lib) extra`" "```text" "x")))))
      problems)))

(test-equal "signature-comments reads one name, a type on the lines under it, and several names; no ;;; line, no prose"
  '((f . "f : Nat -> Nat")
    (g . "g : Nat (U Nat #f) -> Nat")
    (h . "h : Any -> Boolean") (h2? . "h2? : Any -> Boolean")
    (GET . "GET : Handler -> Entry") (PUT . "PUT : Handler -> Entry")
    (k . "k : -> Void"))
  (guard (e (#t (list 'raised (describe e))))
    (signature-comments
     (joined "\n" '(";;; (lib): f : a header, not a signature"
                    "  ;; f : Nat -> Nat"
                    "  ;; What f answers: nothing, said in words."
                    "  ;; g :"
                    "  ;;   Nat (U Nat #f)"
                    "  ;;     -> Nat"
                    "  ;; h, h2? : Any -> Boolean"
                    "  ;; GET PUT : Handler -> Entry"
                    "  ;;"
                    "  ;;   an indented line under no signature"
                    "  (define (f x) x) ; f : not this either"
                    "  ;; k : -> Void")))))

(test-equal "alias-comments reads NAME = TYPE, a type on the lines under it, and cuts a ( type where it closes"
  '((A . "Req -> Res") (B . "(U #f Bytevector String)") (C . "(X Y -> Z)") (d . "what make-d makes"))
  (guard (e (#t (list 'raised (describe e))))
    (alias-comments
     (joined "\n" '(";;; T = a header, not an alias"
                    "  ;; A = Req -> Res"
                    "  ;; B = (U #f Bytevector"
                    "  ;;      String)"
                    "  ;; C = (X Y -> Z), X the server's, and"
                    "  ;;   Z what goes back"
                    "  ;; d = what make-d makes"
                    "  ;; Two words = not an alias"
                    "  ;;   E = indented, not an alias")))))

(test-equal "block-aliases reads a page block's aliases, each type over the lines under it"
  '((Handler . "Req -> Res") (Body . "(U #f Bytevector SizedBody)") (Env . "(String -> (U String #f))"))
  (guard (e (#t (list 'raised (describe e))))
    (block-aliases '("Handler    = Req -> Res" "Body       = (U #f Bytevector" "                SizedBody)" ""
                     "Env = (String -> (U String #f))"))))

(test-equal "documented-signatures reads a text fence's signatures, a table's name and type cells, and a code span's signature; no prose cell, no other fence, no header"
  '((serve . "serve : (Request -> Answer) -> Void") (two . "two : Bytevector -> Nat")
    (make-it . "make-it : a b [c] -> Thing")
    (await . "await : ((Any -> Void) -> Any) -> Any") (sleep-ms . "sleep-ms : Nat -> Void")
    (gone? . "gone? : Any -> Boolean") (why . "why : Gone -> Symbol") (a . "a : T") (b . "b : T"))
  (guard (e (#t (list 'raised (describe e))))
    (documented-signatures
     (joined "\n" '("# Ref" "```text" "serve : (Request -> Answer)" "        -> Void" "" "two :"
                     "  Bytevector -> Nat" "```" "```scheme" "(define (f x) x) : nope" "```"
                     "```text" "make-it : a b [c]" "          -> Thing" "```"
                     "| Name | Type | Does |" "|:--|:--|:--|"
                     "| `await` | `((Any -> Void) -> Any) -> Any` | waits, with `resume` |"
                     "| `sleep-ms` | `Nat  ->  Void` | sleeps |"
                     "| `&gone` | a `serve` connection went | `gone? : Any -> Boolean` |"
                     "| `two words` | `T` | not one name |"
                     "`why : Gone -> Symbol` says why, and `a, b : T` both; `plain` is no signature")))))

(test-equal "defined-names reads define, define-syntax, both kinds of record type and a condition type"
  '((f) (g) (h) (m)
    (rec make-rec rec? rec-a rec-b rec-b-set! get-c)
    (thing %make-thing thing? thing-x)
    (&oops make-oops oops? oops-why)
    ())
  (guard (e (#t (list 'raised (describe e))))
    (map defined-names
         '((define (f x) x) (define g 1) (define ((h a) b) a) (define-syntax m (syntax-rules ()))
           (define-record-type rec (fields a (mutable b) (immutable c get-c)))
           (define-record-type (thing %make-thing thing?) (fields x) (sealed #t))
           (define-condition-type &oops &error make-oops oops? (why oops-why))
           (set! g 2)))))

(test-equal "signature-arguments takes what stands before the first -> in no brackets"
  '("(Req -> Res) [Env]" "" "Handler [(Req Any -> Res)]" #f #f)
  (guard (e (#t (list 'raised (describe e))))
    (map signature-arguments
         '("run-server : (Req -> Res) [Env] -> Void" "k : -> Void"
           "wrap-catch : Handler [(Req Any -> Res)] -> Handler" "x : Nat" "no colon -> here"))))

(test-equal "arity-mask counts required, [optional] and nested [optional], any number, and refuses what doesn't parse"
  '(1 2 12 28 -2 -4 60 #f #f #f)
  (guard (e (#t (list 'raised (describe e))))
    (map arity-mask
         '("" "Req" "Req Key [Any]" "Symbol String [Headers [(U Bytevector String #f)]]"
           "Handler Middleware ..." "String (Listof Middleware) Route ..."
           "Transport Bytevector [Nat Nat] [(U #f ((U #f Symbol) -> Any))]"
           "Req ]" "Req (U" "... Req"))))

(test-equal "counts-text says a mask in words"
  '("1" "1 or 2" "2, 3 or 4" "1 or more" "0, or 2 or more" "none")
  (guard (e (#t (list 'raised (describe e))))
    (map counts-text '(2 6 28 -2 -3 0))))

(test-equal "repository-refs reads every blob and tree link into the two repositories, in Markdown or Org"
  '(("chez-http-server" "blob" "v1.2.3") ("chez-websocket" "tree" "main")
    ("chez-http-server" "blob" "v0.0.1"))
  (guard (e (#t (list 'raised (describe e))))
    (repository-refs
     (string-append
      "[a](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v1.2.3/docs/x.md#y) "
      "https://github.com/Kiyomi-Computation-Systems/chez-websocket/tree/main and "
      "https://github.com/Kiyomi-Computation-Systems/circuit/blob/v9.9.9/README.org "
      "https://github.com/Kiyomi-Computation-Systems/chez-http-server/issues/3\n"
      "[[https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.0.1/README.md][b]]"))))

(test-equal "page-anchors makes GitHub's anchors, a repeat numbered, none from inside a fence"
  '("api-reference" "the-server" "http-server-error-http-server-error" "request-on-done"
    "the-transport" "deadline-passed" "deadline-passed-1" "websocket-accept-procedure" "a_b-c")
  (guard (e (#t (list 'raised (describe e))))
    (page-anchors (joined "\n" '("# API reference" "## The server" "```" "## Inside" "```"
                                 "### &http-server-error, http-server-error?" "### request-on-done!"
                                 "### The transport" "### `&deadline-passed`" "### `deadline-passed?`"
                                 "### `websocket-accept` (procedure)" "#### A_b C")))))

(test-equal "anchor-sections runs each heading's section to the next of its level or a higher one, and code-names reads its spans"
  '(("t" p q r) ("one" p q) ("sub" q) ("two" r))
  (guard (e (#t (list 'raised (describe e))))
    (map (lambda (s) (cons (car s) (code-names (cdr s))))
         (anchor-sections (joined "\n" '("# T" "a" "## One" "`p`" "### Sub" "`q`" "## Two" "`r`"))))))

(test-equal "code-names splits each inline span, a span of `` holding `, then each fenced line"
  '(x y z w f g h k res-body->bytevector inside)
  (guard (e (#t (list 'raised (describe e))))
    (code-names (joined "\n" '("Use `x` and ``y `z` w``," "```scheme" "`inside`" "```"
                               "and `(f g [h])`, `'k`, `res-body->bytevector`.")))))

(test-equal "pin-tag reads the tag after a pin's sha, and release-tag? takes vX.Y.Z alone"
  '("v1.2.3" #f #f (#t #f #f #f))
  (guard (e (#t (list 'raised (describe e))))
    (let ((text (joined "\n" '("SERVER_PIN_DIR := x  # v9.9.9" "SERVER_PIN := 0123abc  # v1.2.3"
                               "WEBSOCKET_PIN := 0123abc" "OTHER_PIN := 0123abc #  "))))
      (list (pin-tag text "SERVER_PIN") (pin-tag text "WEBSOCKET_PIN") (pin-tag text "OTHER_PIN")
            (map release-tag? '("v0.9.1" "v0.9" "0.9.1" "v0.9.x"))))))

(test-equal "manifest-package reads an Akku.manifest's name and version"
  '(("x" . "1.2.3") #f)
  (guard (e (#t (list 'raised (describe e))))
    (list (manifest-package '((import (akku format manifest)) (akku-package ("x" "1.2.3") (synopsis "s"))))
          (manifest-package '((akku-package "x"))))))

;; --- the pins ------------------------------------------------------------------------------

(test-equal "each vendored Akku.manifest names its package and a release version, vX.Y.Z"
  '(("chez-http-server" #t) ("chez-websocket" #t))
  (map (lambda (u) (list (and (upstream-package u) (car (upstream-package u))) (release-tag? (upstream-tag u))))
       upstreams))

(for-each
 (lambda (u)
   (test-equal (string-append makefile ": " (upstream-variable u) "'s comment names "
                              (or (upstream-tag u) "<no tag>") ", v and the version "
                              (upstream-manifest u) " gives")
     (upstream-tag u)
     (upstream-makefile-tag u)))
 upstreams)

;; --- (a) the sections ------------------------------------------------------------------------

(test-equal (string-append page ": its ## sections are the eight public libraries, in order, each once")
  public-libraries
  (map section-library page-sections))

(test-equal (string-append page ": its headings keep the convention: the title, ## `(library)` and ### `name`")
  '()
  page-problems)

;; --- the type aliases ------------------------------------------------------------------------

(test-equal (string-append src-dir "/: the alias comments that name one type agree")
  '()
  (filter (lambda (x) (> (length (cdr x)) 1))
          (map (lambda (name) (cons name (alias-types name)))
               (distinct (map car src-aliases)))))

(test-equal (string-append page ": each type alias in its intro is the alias comment in " src-dir "/")
  (map (lambda (a)
         (let ((types (alias-types (car a))))
           (cons (car a) (if (= (length types) 1) (car types) (list 'alias-comments-in-src types)))))
       page-aliases)
  (if (null? page-aliases) 'no-aliases page-aliases))

;; --- (b) no other public library ---------------------------------------------------------------

(test-equal (string-append src-dir "/: every file is one library form, read as data")
  '()
  (filter string? src-reads))

(for-each
 (lambda (s)
   (let ((library (source-name s)))
     (unless (member library public-libraries)
       (let ((left (guard (e (#t (list 'raised (describe e))))
                     (let ((exports (exports-of library)))
                       (if exports (without exports all-public-names) 'unloadable)))))
         (test-equal (string-append (source-path s) ": " (written library)
                                    " is no public library, so what it exports that none of the eight does is the adapter's and the tests' alone")
           (sorted-symbols (cond ((assoc library internal-exports) => cdr) (else '())))
           left)))))
 sources)

;; --- (c) the entries ---------------------------------------------------------------------------

(for-each
 (lambda (p)
   (let* ((library (car p))
          (exports (cdr p))
          (names (sorted-symbols (map entry-name (entries-of library)))))
     (set! evidence
           (if exports
               (filter string?
                       (list (let ((missing (without exports names)))
                               (and (pair? missing)
                                    (string-append "missing from the page: " (written missing))))
                             (let ((extra (without names exports)))
                               (and (pair? extra)
                                    (string-append "not exported by " (written library) ": "
                                                   (written (distinct extra)))))
                             (let ((twice (repeated names)))
                               (and (pair? twice)
                                    (string-append "more than once: " (written twice))))))
               (list (string-append (written library) " can't be loaded"))))
     (test-equal (string-append page ", " (written library) ": its entries are its exports, each once")
       exports
       names)))
 public-exports)

;; --- (d) the signatures ------------------------------------------------------------------------

(for-each
 (lambda (p)
   (let ((library (car p)) (exports (or (cdr p) '())))
     (test-equal (string-append src-dir "/, " (written library)
                                ": each export is defined in one library under src/ with one signature comment, or re-exported from the server or chez-websocket")
       '()
       (filter pair?
               (map (lambda (name)
                      (let ((o (origin library name)))
                        (case (car o)
                          ((upstream) #f)
                          ((defined)
                           (let ((sig (source-signature (cdr o) name)))
                             (and (not (string? sig)) (cons name sig))))
                          (else (list name (car o) (cdr o))))))
                    exports)))))
 public-exports)

(for-each
 (lambda (p)
   (let ((library (car p)) (exports (or (cdr p) '())))
     (for-each
      (lambda (e)
        (let ((name (entry-name e)))
          (when (memq name exports)
            (let ((o (origin library name)))
              (when (eq? (car o) 'defined)
                (let ((sig (source-signature (cdr o) name)))
                  (test-equal (string-append page ", " (written library) ", " (symbol->string name)
                                             ": its one block is text, the signature comment in "
                                             (source-path (cdr o)))
                    (list (cons "text" sig))
                    (entry-blocks e))))))))
      (entries-of library))))
 public-exports)

;; The arities: each export of the library with a signature comment whose
;; value is a procedure, its signature's counts against Chez's.
(for-each
 (lambda (p)
   (let* ((library (car p))
          (signed (filter (lambda (x) (string? (cdr x)))
                          (map (lambda (name)
                                 (let ((o (origin library name)))
                                   (cons name (and (eq? (car o) 'defined) (source-signature (cdr o) name)))))
                               (or (cdr p) '()))))
          (bound (map (lambda (x) (binding library (car x))) signed))
          (procedures (filter (lambda (pair) (and (eq? (car (cdr pair)) 'value) (procedure? (cdr (cdr pair)))))
                              (map cons signed bound)))
          (skipped (without (map car signed) (map caar procedures)))
          (expected (map (lambda (pair)
                           (let ((args (signature-arguments (cdar pair))))
                             (cons (caar pair) (and args (arity-mask args)))))
                         procedures))
          (actual (map (lambda (pair) (cons (caar pair) (procedure-arity-mask (cdr (cdr pair))))) procedures)))
     ;; EXPECTED and ACTUAL are made from PROCEDURES alike, name by name.
     (set! evidence
           (apply append
                  (map (lambda (e a)
                         (if (equal? e a)
                             '()
                             (list (string-append (symbol->string (car e)) ": its signature takes "
                                                  (counts-text (cdr e)) ", the procedure "
                                                  (counts-text (cdr a))))))
                       expected actual)))
     (test-equal (string-append src-dir "/, " (written library)
                                ": each procedure's signature comment takes the counts of arguments it does, by procedure-arity-mask; skipped, as syntax or no procedure: "
                                (if (null? skipped) "none" (written skipped)))
       expected
       actual)))
 public-exports)

;; --- (e) the re-exports --------------------------------------------------------------------------

(for-each
 (lambda (p)
   (let ((library (car p)) (exports (or (cdr p) '())))
     (for-each
      (lambda (e)
        (let ((name (entry-name e)))
          (when (memq name exports)
            (let ((o (origin library name)))
              (when (eq? (car o) 'upstream)
                (let* ((u (cdr o))
                       (links (filter (lambda (url)
                                        (let ((t (github-target url)))
                                          (and t (string=? (car t) (upstream-repo u))
                                               (string=? (cadddr t) "docs/reference.md"))))
                                      (entry-links e))))
                  (test-equal (string-append page ", " (written library) ", " (symbol->string name)
                                             ": re-exported from " (upstream-repo u)
                                             ", so no block, and one link to its reference at "
                                             (or (upstream-tag u) "its pin's tag")
                                             ", whose section there names it")
                    (list 'blocks '() 'reference-links (list (reference-url u)) 'section-names-it '(#t))
                    (list 'blocks (entry-blocks e)
                          'reference-links (map without-anchor links)
                          'section-names-it
                          (map (lambda (url) (names-it? u (list-ref (github-target url) 4) name)) links)))))))))
      (entries-of library))))
 public-exports)

;; --- (g) the re-exports' signature comments -----------------------------------------------------

;; reexported-procedures : (Listof (Pair (Listof Symbol) (Listof (Pair Symbol Upstream))))
;; Each public library that re-exports a procedure, with each such name and
;; the upstream it comes from. Syntax, such as a condition type, has no
;; signature to hold.
(define reexported-procedures
  (guard (e (#t (list (list 'raised (describe e)))))
    (filter (lambda (row) (pair? (cdr row)))
            (map (lambda (p)
                   (let ((library (car p)))
                     (cons library
                           (filter pair?
                                   (map (lambda (name)
                                          (let ((o (origin library name))
                                                (b (binding library name)))
                                            (and (eq? (car o) 'upstream)
                                                 (eq? (car b) 'value)
                                                 (procedure? (cdr b))
                                                 (cons name (cdr o)))))
                                        (or (cdr p) '()))))))
                 public-exports))))

(test-equal "some public library re-exports a procedure, so the rows below hold something"
  #t
  (and (pair? reexported-procedures)
       (for-all (lambda (row) (and (list? (car row)) (pair? (cdr row)) (pair? (cadr row))
                                   (upstream? (cdadr row))))
                reexported-procedures)))

(for-each
 (lambda (row)
   (let* ((library (car row))
          (s (find (lambda (s) (equal? (source-name s) library)) sources)))
     (test-equal (string-append src-dir "/, " (written library)
                                ": each re-exported procedure has one signature comment, the signature its upstream's reference gives it")
       (map (lambda (x) (cons (car x) (upstream-signature (cdr x) (car x)))) (cdr row))
       (map (lambda (x) (cons (car x) (if s (source-signature s (car x)) 'no-library-under-src)))
            (cdr row)))))
 (if (and (pair? reexported-procedures) (list? (car (car reexported-procedures))))
     reexported-procedures
     '()))

;; --- the entries' words and links ---------------------------------------------------------------

(for-each
 (lambda (library)
   (test-equal (string-append page ", " (written library)
                              ": every entry has words, and every one but a re-export links a guide page, a .md with no anchor that names it in code, inline or fenced")
     '()
     (apply append
            (map (lambda (e)
                   (let* ((name (entry-name e))
                          (relative (filter relative-link? (entry-links e)))
                          (upstream? (eq? (car (origin library name)) 'upstream)))
                     (append
                      (if (exists (lambda (line) (not (string=? (trim line) ""))) (entry-prose e))
                          '()
                          (list (list name 'no-words)))
                      (if (or upstream? (pair? relative)) '() (list (list name 'no-guide-link)))
                      (apply append
                             (map (lambda (url)
                                    (cond ((or (string-search url "#" 0) (not (suffix? url ".md")))
                                           (list (list name 'not-a-page-link url)))
                                          ((not (guide-names url)) (list (list name 'no-such-page url)))
                                          ((not (memq name (guide-names url)))
                                           (list (list name 'page-does-not-name-it url)))
                                          (else '())))
                                  relative)))))
                 (entries-of library)))))
 public-libraries)

(test-equal (string-append page ": every #anchor into the server's or chez-websocket's reference names a heading there, as vendored at its pin")
  '()
  (filter (lambda (url)
            (let ((t (github-target url)))
              (and t
                   (let ((u (upstream-of-repo (car t))))
                     (and u
                          (string=? (cadddr t) "docs/reference.md")
                          (list-ref t 4)
                          (not (assoc (list-ref t 4) (upstream-sections u))))))))
          (markdown-links (joined " " page-outside))))

;; --- (f) pinned links -----------------------------------------------------------------------------

(for-each
 (lambda (path)
   (let ((text (read-text path)))
     (test-equal (string-append path ": every link into chez-http-server's or chez-websocket's repository at a ref names its pin's tag, "
                                (joined " and " (map (lambda (u) (or (upstream-tag u) "<none>")) upstreams)))
       '()
       (if text
           (filter (lambda (ref)
                     (let ((u (upstream-of-repo (car ref))))
                       (not (and u (upstream-tag u) (string=? (caddr ref) (upstream-tag u))))))
                   (repository-refs text))
           'unreadable))))
 (append (guard (e (#t (list docs-dir)))
           (map (lambda (name) (string-append docs-dir "/" name))
                (list-sort string<? (filter (lambda (name) (suffix? name ".md")) (directory-list docs-dir)))))
         (list readme)))

(test-end "reference")

(exit (suite-exit-status runner))
