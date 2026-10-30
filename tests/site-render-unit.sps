#!r6rs
;;; The docs site's whole pipeline, (site render), on small inputs: markdown
;;; through chez-cmark-gfm, headings slugged, links rewritten across pages,
;;; each page templated.  Imports (cmark gfm), which loads libcmark-gfm.  Not
;;; named test-*.sps, so `make test` does not run it; `make check-site` does.
;;; From the repository root:
;;;   CHEZSCHEMELIBDIRS=.:tests:build/scheme-libs:vendor/chez-cmark-gfm/src \
;;;     chez --program tests/site-render-unit.sps
(import (rnrs) (srfi :64) (circuit-testing) (site render) (site serializer))

;; string-contains-sub? : String String -> Boolean
(define (string-contains-sub? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? needle (substring hay i (+ i n))) #t)
            (else (loop (+ i 1)))))))

;; count-substring : String String -> Integer
;; Non-overlapping occurrences of NEEDLE in HAY.
(define (count-substring hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0) (count 0))
      (cond ((> (+ i n) h) count)
            ((string=? needle (substring hay i (+ i n))) (loop (+ i n) (+ count 1)))
            (else (loop (+ i 1) count))))))

;; page-html : SiteResult String -> String
(define (page-html r name)
  (sxml->html (cond ((assoc name (site-result-pages r)) => cdr)
                    (else (error 'site-render-unit "page missing" name)))))

;; Two pages; the home page links to a heading on quickstart.md, and
;; quickstart.md links back to the home page.  The anchor is only knowable
;; after quickstart.md is slugged.
(define inputs
  '(("README.md" . "# Home\n\nSee [reading](quickstart.md#reading-a-request).\n")
    ("quickstart.md" . "# Quickstart\n\n## Reading a request\n\ntext\n\n### The path\n\nmore text\n\n[home](README.md)\n")))

(define r (render-site inputs "main"))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "site-render-unit")

(test-equal "every input yields a page, in input order"
  '("README.md" "quickstart.md") (map car (site-result-pages r)))
(test-equal "the registry carries every one of a page's heading slugs, its h1 included"
  '("quickstart" "reading-a-request" "the-path")
  (cond ((assoc "quickstart.md" (site-result-registry r)) => cdr) (else 'missing)))
(test-equal "resolvable cross-page links, README.md among them, do not dangle"
  '() (site-result-leaked r))

(let ((html (page-html r "quickstart.md")))
  (test-eq "the rail links the h2 anchor" 'linked
    (if (string-contains-sub? html "href=\"#reading-a-request\"") 'linked 'missing))
  (test-eq "the rail does not link the h1 anchor" 'absent
    (if (string-contains-sub? html "href=\"#quickstart\"") 'present 'absent))
  (test-eq "an h3 remains a rendered link target" 'present
    (if (string-contains-sub? html "id=\"the-path\"") 'present 'missing))
  (test-eq "the rail lists h2 sections, not h3 details" 'absent
    (if (string-contains-sub? html "href=\"#the-path\"") 'present 'absent))
  (test-eqv "a link to README.md is written as index.html, beside the wordmark's"
    2 (count-substring html "href=\"index.html\""))
  (test-eq "no link keeps the README.md name" 'absent
    (if (string-contains-sub? html "README") 'present 'absent))
  (test-eq "the page's title is its nav label" 'present
    (if (string-contains-sub? html "<title>Quickstart</title>") 'present 'missing)))

;; The home page is reached from the wordmark and the page text, not
;; listed as a nav item: only the wordmark links index.html on a page that
;; does not link it in its text.
(let ((html (page-html r "README.md")))
  (test-eqv "index.html is linked once on the home page: the wordmark, not a nav item"
    1 (count-substring html "href=\"index.html\""))
  (test-eq "the home page has no footer nav" 'absent
    (if (string-contains-sub? html "class=\"pagenav\"") 'present 'absent)))

;; The nav's two pages link each other as footer neighbours, and each end
;; links nothing on its open side: an empty span, no link.
(let* ((two (render-site '(("installing.md" . "# Installing\n")
                           ("quickstart.md" . "# Quickstart\n"))
                         "main"))
       (first (page-html two "installing.md"))
       (last (page-html two "quickstart.md")))
  (test-equal "the first page links the next one, and no previous"
    '(#t #f)
    (list (string-contains-sub? first "<a href=\"quickstart.html\" class=\"next\">")
          (string-contains-sub? first "Previous")))
  (test-equal "the last page links the one before it, and no next"
    '(#t #f)
    (list (string-contains-sub?
           last "<a href=\"installing.html\"><span class=\"lbl\">Previous")
          (string-contains-sub? last "class=\"next\""))))

;; A warning-led blockquote passes through the whole pipeline as a callout.
(let ((html (page-html (render-site '(("quickstart.md" . "> ⚠️ Answer quickly.\n")) "main")
                       "quickstart.md")))
  (test-eq "a warning blockquote is rendered inside a callout div" 'present
    (if (string-contains-sub? html "<div class=\"callout warning\"><blockquote>")
        'present 'missing)))

(test-equal "an unresolvable cross-page anchor is reported"
  '(("README.md" . "quickstart.md#gone"))
  (site-result-leaked
   (render-site '(("README.md" . "[x](quickstart.md#gone)\n")
                  ("quickstart.md" . "# Quickstart\n"))
                "main")))
(test-equal "an unresolvable README.md anchor is reported"
  '(("quickstart.md" . "README.md#gone"))
  (site-result-leaked
   (render-site '(("README.md" . "# Home\n")
                  ("quickstart.md" . "[x](README.md#gone)\n"))
                "main")))
(test-equal "danglers across pages come back in page order"
  '(("README.md" . "#a") ("quickstart.md" . "#b"))
  (site-result-leaked
   (render-site '(("README.md" . "[x](#a)\n") ("quickstart.md" . "[y](#b)\n"))
                "main")))

(test-end "site-render-unit")

(exit (suite-exit-status runner))
