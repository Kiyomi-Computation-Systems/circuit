#!r6rs
;;; Taking a connection over: an HTTP/1.1 request with Connection: upgrade
;;; and Upgrade: echo gets a 101, and from then on every byte it sends comes
;;; back. One with Upgrade: echo that the server can't take, without
;;; Connection: upgrade or over HTTP/1.0, gets the server's 500, logged
;;; invalid-response not-an-upgrade. One with no Upgrade: echo is told how
;;; to ask.
;;;
;;;   make run PROGRAM=examples/upgrade.sps
;;;   curl -i http://127.0.0.1:8080/
;;;
;;; curl can't talk once the 101 is in, so try the echo with bash's /dev/tcp:
;;;
;;;   exec 3<>/dev/tcp/127.0.0.1/8080
;;;   printf 'GET / HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: echo\r\n\r\nhi' >&3
;;;   timeout 1 cat <&3
(import (rnrs) (circuit) (circuit http-server))

;; echo : Transport Bytevector -> Any
;; The take-over. RETAINED, the bytes past the request the server had
;; already read, goes back first; whatever the client sends after comes
;; through the reads, each written back as it comes. When the client closes
;; its side, or the server shuts down, the stream closes.
(define (echo t retained)
  (when (> (bytevector-length retained) 0)
    (transport-write! t retained))
  (transport-read-start! t
                         (lambda (bytes start end) (transport-write! t bytes start end))
                         (lambda (why) (transport-close! t)))
  (transport-on-drain! t (lambda () (transport-close! t))))

;; app : Req -> Res
;; Any request with Upgrade: echo is answered the upgrade. The server
;; switches only one that can take it, HTTP/1.1 with Connection: upgrade,
;; and answers the upgrade to any other with its 500.
(define (app req)
  (if (equal? (req-header req "upgrade") "echo")
      (make-upgrade-res '(("upgrade" . "echo")) echo)
      (make-res 200 '(("content-type" . "text/plain")) "ask for Upgrade: echo\n")))

(run-server app)
