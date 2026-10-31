#!r6rs
;; PURE. Imports no library that loads a shared object.
(library (site pages)
  (export pages page-file-name)
  (import (rnrs))

  ;; pages : (Listof (Pairof String String))
  ;; The nav's single source of order and labels: each docs/ file and its
  ;; label, the home page first, then the order of its "Read next" list.
  ;; tests/site-check.sps asserts the file set here equals docs/*.md.
  (define pages
    '(("README.md"        . "Home")
      ("installing.md"    . "Installing")
      ("quickstart.md"    . "Quickstart")
      ("requests.md"      . "Requests and responses")
      ("bodies.md"        . "Bodies and streaming")
      ("params.md"        . "Query strings and forms")
      ("cookies.md"       . "Cookies")
      ("middleware.md"    . "Middleware")
      ("routing.md"       . "Routing")
      ("waiting.md"       . "Waiting")
      ("upgrades.md"      . "Upgrades and WebSockets")
      ("testing.md"       . "Testing handlers")
      ("configuration.md" . "Configuration")
      ("reference.md"     . "API reference")))

  ;; page-file-name : String -> String
  ;; The file a page is written to: README.md, the home page, as index.html,
  ;; and any other page.md as page.html.  tests/site-check.sps holds every
  ;; relative link to these names.
  (define (page-file-name name)
    (if (string=? name "README.md")
        "index.html"
        (string-append (substring name 0 (- (string-length name) 3)) ".html"))))
