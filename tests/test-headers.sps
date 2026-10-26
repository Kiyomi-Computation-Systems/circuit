#!r6rs
;;; (circuit headers): lookups in any ASCII case, set, add and remove, and
;;; names written in lower case.
;;;
;;; The base list mixes cases and repeats a name, so a helper that ignored
;;; case, kept only one field, or lost the order answers something else. A
;;; lookup that can raise is wrapped in a list with a tag: SRFI-64 turns a
;;; raise in the actual expression into #f, and #f is an answer here.
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (circuit headers))

(define runner (test-runner-simple))
(test-runner-current runner)

;; raised : (-> Any) -> Any
;; What THUNK raised: (assertion-violation WHO IRRITANTS) for an assertion
;; violation, (other-raise X) for anything else, and no-raise if it returned.
(define (raised thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (irritants-condition? e))
             (list 'assertion-violation (condition-who e) (condition-irritants e)))
            (#t (list 'other-raise (describe e))))
    (thunk)
    'no-raise))

;; answer : (-> Any) -> (U (List 'answer Any) (List 'raised String))
;; THUNK's answer behind a tag, or what it raised.
(define (answer thunk)
  (guard (e (#t (list 'raised (describe e))))
    (list 'answer (thunk))))

;; base : -> Headers
;; A fresh list each call, so no test can see another's changes.
(define (base)
  (list (cons "Content-Type" "text/plain")
        (cons "Set-Cookie" "a=1")
        (cons "X-Trace" "t1")
        (cons "set-cookie" "b=2")
        (cons "SET-COOKIE" "c=3")))

(define base-copy
  '(("Content-Type" . "text/plain") ("Set-Cookie" . "a=1") ("X-Trace" . "t1")
    ("set-cookie" . "b=2") ("SET-COOKIE" . "c=3")))

;; Characters where ASCII and Unicode case rules part: the Kelvin sign folds
;; to "k" under Unicode, and E acute has a lower case only Unicode knows.
(define kelvin (string (integer->char #x212A)))
(define e-acute-upper (string (integer->char #xC9)))
(define e-acute-lower (string (integer->char #xE9)))

(test-begin "headers")

;; --- lookup -----------------------------------------------------------------

(test-equal "header-value: the first field's value, the name in any case"
  '("a=1" "a=1" "a=1" "a=1")
  (let ((h (base)))
    (map (lambda (name) (header-value h name))
         '("set-cookie" "SET-COOKIE" "Set-Cookie" "sEt-CoOkIe"))))

(test-equal "header-value: #f when no field has the name"
  '(answer #f)
  (answer (lambda () (header-value (base) "accept"))))

(test-equal "header-value: #f on an empty list"
  '(answer #f)
  (answer (lambda () (header-value '() "accept"))))

(test-equal "header-values: every field's value, in order, the name in any case"
  '(("a=1" "b=2" "c=3") ("text/plain") ())
  (let ((h (base)))
    (list (header-values h "SeT-cOOKIE")
          (header-values h "content-type")
          (header-values h "accept"))))

;; scan : (Nat -> Headers) -> ...
;; Five lists of five fields, the name at position i in the i-th.
(define (fields-with-key-at i)
  (let loop ((j 0))
    (if (= j 5)
        '()
        (cons (if (= j i)
                  (cons "Key" (string-append "v" (number->string j)))
                  (cons (string-append "Other-" (number->string j)) "x"))
              (loop (+ j 1))))))

(test-equal "header-value finds the name at every position"
  '("v0" "v1" "v2" "v3" "v4")
  (map (lambda (i) (header-value (fields-with-key-at i) "key")) '(0 1 2 3 4)))

(test-equal "header-set replaces the name at every position, where it stood"
  '((("key" . "new") ("Other-1" . "x") ("Other-2" . "x") ("Other-3" . "x") ("Other-4" . "x"))
    (("Other-0" . "x") ("key" . "new") ("Other-2" . "x") ("Other-3" . "x") ("Other-4" . "x"))
    (("Other-0" . "x") ("Other-1" . "x") ("key" . "new") ("Other-3" . "x") ("Other-4" . "x"))
    (("Other-0" . "x") ("Other-1" . "x") ("Other-2" . "x") ("key" . "new") ("Other-4" . "x"))
    (("Other-0" . "x") ("Other-1" . "x") ("Other-2" . "x") ("Other-3" . "x") ("key" . "new")))
  (map (lambda (i) (header-set (fields-with-key-at i) "KEY" "new")) '(0 1 2 3 4)))

(test-equal "header-remove removes the name at every position"
  '((("Other-1" . "x") ("Other-2" . "x") ("Other-3" . "x") ("Other-4" . "x"))
    (("Other-0" . "x") ("Other-2" . "x") ("Other-3" . "x") ("Other-4" . "x"))
    (("Other-0" . "x") ("Other-1" . "x") ("Other-3" . "x") ("Other-4" . "x"))
    (("Other-0" . "x") ("Other-1" . "x") ("Other-2" . "x") ("Other-4" . "x"))
    (("Other-0" . "x") ("Other-1" . "x") ("Other-2" . "x") ("Other-3" . "x")))
  (map (lambda (i) (header-remove (fields-with-key-at i) "kEy")) '(0 1 2 3 4)))

(test-equal "a lookup folds ASCII case alone: the Kelvin sign is not k, and E acute is not e acute"
  '((answer #f) (answer #f) (answer "kelvin") (answer ()))
  (let ((h (list (cons (string-append kelvin "ey") "kelvin")
                 (cons e-acute-upper "upper"))))
    (list (answer (lambda () (header-value h "key")))
          (answer (lambda () (header-value h e-acute-lower)))
          (answer (lambda () (header-value h (string-append kelvin "EY"))))
          (answer (lambda () (header-values h "KEY"))))))

;; --- set, add, remove ---------------------------------------------------------

(test-equal "header-set: every field of the name becomes one, in lower case, at the first one's place"
  '(("Content-Type" . "text/plain") ("set-cookie" . "z=9") ("X-Trace" . "t1"))
  (header-set (base) "SET-cookie" "z=9"))

(test-equal "header-set: a name no field has is appended, in lower case"
  '(("Content-Type" . "text/plain") ("Set-Cookie" . "a=1") ("X-Trace" . "t1")
    ("set-cookie" . "b=2") ("SET-COOKIE" . "c=3") ("accept" . "*/*"))
  (header-set (base) "Accept" "*/*"))

(test-equal "header-set: on an empty list, one field"
  '(("x-one" . "1"))
  (header-set '() "X-One" "1"))

(test-equal "header-add: appended, in lower case, the others kept"
  '(("Content-Type" . "text/plain") ("Set-Cookie" . "a=1") ("X-Trace" . "t1")
    ("set-cookie" . "b=2") ("SET-COOKIE" . "c=3") ("set-cookie" . "d=4"))
  (header-add (base) "Set-Cookie" "d=4"))

(test-equal "header-remove: every field of the name, in any case, the rest in order"
  '(("Content-Type" . "text/plain") ("X-Trace" . "t1"))
  (header-remove (base) "set-COOKIE"))

(test-equal "header-remove: a name no field has leaves the fields as they were"
  base-copy
  (header-remove (base) "accept"))

(test-equal "a name is written in ASCII lower case: E acute and the Kelvin sign stay as given"
  (list (cons (string-append "x-" e-acute-upper kelvin) "v")
        (cons (string-append "y-" e-acute-upper) "w"))
  (header-add (header-set '() (string-append "X-" e-acute-upper kelvin) "v")
              (string-append "Y-" e-acute-upper) "w"))

(test-equal "values are kept as given, case and all"
  '(("x-a" . "MiXeD") ("x-b" . "  Spaced  "))
  (header-add (header-set '() "X-A" "MiXeD") "X-B" "  Spaced  "))

(test-equal "no helper changes the list it is given"
  base-copy
  (let ((h (base)))
    (header-set h "set-cookie" "z")
    (header-add h "X-New" "n")
    (header-remove h "content-type")
    (header-names-downcase h)
    h))

;; --- names in lower case --------------------------------------------------------

(test-equal "header-names-downcase: each name in lower case, in order, duplicates kept"
  '(("content-type" . "text/plain") ("set-cookie" . "a=1") ("x-trace" . "t1")
    ("set-cookie" . "b=2") ("set-cookie" . "c=3"))
  (header-names-downcase (base)))

(test-equal "header-names-downcase: ASCII alone, as the server folds"
  (list (cons (string-append "x-" e-acute-upper kelvin) "V"))
  (header-names-downcase (list (cons (string-append "X-" e-acute-upper kelvin) "V"))))

(test-equal "header-names-downcase: the list itself when every name is in lower case already"
  '(#t #t)
  (let ((h (list (cons "a" "1") (cons "b-c" "2")))
        (empty '()))
    (list (eq? h (header-names-downcase h))
          (eq? empty (header-names-downcase empty)))))

;; --- refusals -----------------------------------------------------------------

(test-equal "a name that is not a string is refused, by every helper"
  '((assertion-violation header-value (accept))
    (assertion-violation header-values (accept))
    (assertion-violation header-set (accept))
    (assertion-violation header-add (accept))
    (assertion-violation header-remove (accept)))
  (let ((h (base)))
    (list (raised (lambda () (header-value h 'accept)))
          (raised (lambda () (header-values h 'accept)))
          (raised (lambda () (header-set h 'accept "v")))
          (raised (lambda () (header-add h 'accept "v")))
          (raised (lambda () (header-remove h 'accept))))))

(test-equal "a value that is not a string is refused"
  '((assertion-violation header-set (5)) (assertion-violation header-add (#f)))
  (let ((h (base)))
    (list (raised (lambda () (header-set h "x" 5)))
          (raised (lambda () (header-add h "x" #f))))))

(test-equal "what is not a list is refused, by every helper"
  '((assertion-violation header-value (x))
    (assertion-violation header-values ((("a" . "1") . "rest")))
    (assertion-violation header-set (x))
    (assertion-violation header-add (x))
    (assertion-violation header-remove (x))
    (assertion-violation header-names-downcase (x)))
  (list (raised (lambda () (header-value 'x "a")))
        (raised (lambda () (header-values '(("a" . "1") . "rest") "a")))
        (raised (lambda () (header-set 'x "a" "1")))
        (raised (lambda () (header-add 'x "a" "1")))
        (raised (lambda () (header-remove 'x "a")))
        (raised (lambda () (header-names-downcase 'x)))))

(test-equal "a field that is not a pair of strings is refused, wherever it stands"
  '((assertion-violation header-value (bogus))
    (assertion-violation header-values (("a" . 1)))
    (assertion-violation header-set ((a . "1")))
    (assertion-violation header-add (bogus))
    (assertion-violation header-remove (bogus))
    (assertion-violation header-names-downcase (("A" . 1))))
  (list (raised (lambda () (header-value '(("b" . "2") bogus) "b")))
        (raised (lambda () (header-values '(("a" . 1)) "z")))
        (raised (lambda () (header-set '(("b" . "2") (a . "1")) "b" "3")))
        (raised (lambda () (header-add '(bogus) "b" "3")))
        (raised (lambda () (header-remove '(("b" . "2") bogus ("c" . "3")) "b")))
        (raised (lambda () (header-names-downcase '(("b" . "2") ("A" . 1)))))))

(test-end "headers")

(exit (suite-exit-status runner))
