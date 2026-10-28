#!r6rs
;;; (circuit websocket): a WebSocket for a circuit app.
;;;
;;;   (import (rnrs) (circuit) (circuit http-server) (circuit websocket) (websocket))
;;;   (define (echo ws) (let loop () (websocket-send! ws (websocket-receive ws)) (loop)))
;;;   (run-server (lambda (req) (websocket-res req echo)))
;;;
;;; websocket-res hands chez-websocket's websocket-handshake what it reads of
;;; the request: req-method, every line of a field by req-header-values, and
;;; req-host. The handshake decides, and this library maps its answer onto
;;; circuit's responses (slice 6 design §6). Accepted, the answer is
;;; make-upgrade-res's 101, of the handshake's headers and its take-over,
;;; which runs the procedure with the WebSocket once the 101 is written.
;;; Refused, it is make-res's response of the handshake's status and
;;; headers, with no body.
;;;
;;; The take-over answers the server, and a middleware that wraps it must
;;; answer what it answers: dropped, the 101 is written and the procedure
;;; never runs (chez-websocket's ADR-0009).
;;;
;;; An app imports (websocket) for the rest: websocket-receive,
;;; websocket-send!, websocket-close!, make-handshake-settings and the
;;; limits. This library imports (websocket), which imports the server, and
;;; neither (http-server) nor (chezscheme), nor any other (websocket ...)
;;; library: ADR-0006's third library that depends on the server.
(library (circuit websocket)
  (export websocket-res)
  (import (rnrs)
          (only (circuit request) req? req-method req-header-values req-host)
          (only (circuit response) make-res make-upgrade-res)
          (only (websocket)
                websocket-handshake handshake-accepted? handshake-accepted-headers
                handshake-accepted-take-over handshake-refused-status handshake-refused-headers
                handshake-settings? websocket-limits?))

  ;; websocket-res : Req (WebSocket -> Any) [HandshakeSettings [WebsocketLimits]] -> Res
  ;; The answer to REQ: a 101 whose take-over runs PROC with the WebSocket,
  ;; or the handshake's refusal, 400 or 403, with no body. SETTINGS and
  ;; LIMITS, when left out, are left out of websocket-handshake too, so its
  ;; defaults are its own: no subprotocols, the request's own host as the
  ;; one origin, and the environment's limits. A REQ that is no request, a
  ;; PROC that is no procedure, SETTINGS that are no handshake settings and
  ;; LIMITS that are no limits are each an assertion violation naming
  ;; websocket-res, checked in that order, before the request is read.
  (define websocket-res
    (case-lambda
      ((req proc)
       (check-req req)
       (check-proc proc)
       (answer (websocket-handshake (req-method req) (field-lines req) (req-host req) proc)))
      ((req proc settings)
       (check-req req)
       (check-proc proc)
       (check-settings settings)
       (answer (websocket-handshake (req-method req) (field-lines req) (req-host req) proc
                                    settings)))
      ((req proc settings limits)
       (check-req req)
       (check-proc proc)
       (check-settings settings)
       (check-limits limits)
       (answer (websocket-handshake (req-method req) (field-lines req) (req-host req) proc
                                    settings limits)))))

  (define (check-req req)
    (unless (req? req) (assertion-violation 'websocket-res "not a request" req)))

  (define (check-proc proc)
    (unless (procedure? proc) (assertion-violation 'websocket-res "not a procedure" proc)))

  (define (check-settings settings)
    (unless (handshake-settings? settings)
      (assertion-violation 'websocket-res "not handshake settings" settings)))

  (define (check-limits limits)
    (unless (websocket-limits? limits) (assertion-violation 'websocket-res "not limits" limits)))

  ;; field-lines : Req -> (String -> (Listof String))
  ;; The handshake's reader: every line of the field NAME, in any case, in
  ;; order, which the handshake joins.
  (define (field-lines req)
    (lambda (name) (req-header-values req name)))

  ;; answer : Handshake -> Res
  ;; An accepted handshake's 101, its headers and take-over as the
  ;; handshake made them, or a refused one's status and headers, no body.
  (define (answer h)
    (if (handshake-accepted? h)
        (make-upgrade-res (handshake-accepted-headers h) (handshake-accepted-take-over h))
        (make-res (handshake-refused-status h) (handshake-refused-headers h) #f))))
