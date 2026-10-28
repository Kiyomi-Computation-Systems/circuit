#!r6rs
;;; A WebSocket echo: /echo takes a WebSocket handshake, and sends every
;;; message back as it came, a text as text and bytes as bytes, until the
;;; client goes. websocket-res answers the handshake's 101, or its refusal:
;;; 400 for a request that is no handshake, 403 for a browser's page from
;;; another site. Any other path is told where to go.
;;;
;;;   make run PROGRAM=examples/websocket.sps
;;;   printf hi | curl -s --max-time 1 -T - ws://127.0.0.1:8080/echo
;;;
;;; That needs curl 8.11 or later. It sends what it reads as one binary
;;; message, prints what comes back, and waits until its --max-time. To type
;;; messages yourself, use websocat, an interactive client:
;;;
;;;   websocat ws://127.0.0.1:8080/echo
(import (rnrs) (circuit) (circuit http-server) (circuit websocket) (websocket))

;; echo : WebSocket -> Void
;; Each message back, as it came. When the client closes, the receive
;; raises &websocket-closed, which ends the procedure; the close is done.
(define (echo ws)
  (let loop ()
    (websocket-send! ws (websocket-receive ws))
    (loop)))

;; app : Req -> Res
(define (app req)
  (if (string=? (req-path req) "/echo")
      (websocket-res req echo)
      (make-res 404 '(("content-type" . "text/plain")) "open a WebSocket to /echo\n")))

(run-server app)
