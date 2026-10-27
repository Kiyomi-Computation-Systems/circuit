#!r6rs
;;; A router, from (circuit router): a table of routes, matched by the path,
;;; then by the method.
;;;
;;;   GET  /              home
;;;   GET  /users         the list
;;;   POST /users         adds the user the body names: 201
;;;   GET  /users/new     a word, which beats /users/:id beside it
;;;   GET  /users/:id     one user, the id decoded: /users/a%20b is "a b"
;;;   GET  /admin/stats   in a group whose middleware adds x-admin: yes
;;;   /files/...          a mount: its handler sees the path past /files
;;;
;;; Any other path is an empty 404. A method a route doesn't take is an
;;; empty 405, its Allow the methods it does: DELETE /users/new reads
;;; Allow: GET, HEAD. HEAD gets GET's answer, and the server drops the body.
;;;
;;;   make run PROGRAM=examples/router.sps
;;;   curl -i http://127.0.0.1:8080/users/42
(import (rnrs) (circuit) (circuit http-server) (circuit router))

;; text : Nat String -> Res
(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

;; body-text : Req -> String — the request's body, as UTF-8.
(define (body-text req)
  (let ((bytes (get-bytevector-all (req-body req))))
    (if (eof-object? bytes) "" (utf8->string bytes))))

(define (home req) (text 200 "home\n"))
(define (list-users req) (text 200 "ann\nbob\n"))
(define (create-user req) (text 201 (string-append "created " (body-text req) "\n")))
(define (new-user req) (text 200 "the new user form\n"))
(define (show-user req) (text 200 (string-append "user " (req-path-param req "id") "\n")))
(define (stats req) (text 200 "2 users\n"))

;; files : Handler — mounted at /files, it sees the rest of the path, and
;; req-route names the mount.
(define (files req)
  (text 200 (string-append "file " (req-path req) ", mounted at " (req-route req) "\n")))

;; wrap-admin : Middleware — adds a field to what the admin routes answer.
(define (wrap-admin handler)
  (lambda (req)
    (res-add-header (handler req) "x-admin" "yes")))

;; app : Req -> Res
(define app
  (make-router
   (list (route "/" (GET home))
         (route "/users" (GET list-users) (POST create-user))
         (route "/users/new" (GET new-user))
         (route "/users/:id" (GET show-user))
         (group "/admin" (list wrap-admin)
           (route "/stats" (GET stats)))
         (mount "/files" files))))

(run-server app)
