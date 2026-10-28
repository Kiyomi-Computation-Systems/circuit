#!r6rs
;;; (circuit websocket): websocket-res, called on (circuit test)'s requests
;;; and on a request whose reads it observes, and run through the server's
;;; test host, (http-server testing), with (circuit->handler app env) as its
;;; handler (slice 6 design §6, "Circuit's side (6c)").
;;;
;;;   - RFC 6455 §1.3's handshake: the 101's whole head, a masked text frame
;;;     echoed through the take-over, the client's close answered; a
;;;     subprotocol chosen;
;;;   - each refusal websocket-handshake makes, as a res and on the wire, its
;;;     procedure never run;
;;;   - the host the handshake is handed is req-host's, apart from the Host
;;;     field: an absolute-form target names another;
;;;   - a field over several lines, joined in the order they came;
;;;   - the argument faults, each naming websocket-res before the request is
;;;     read, in each form that takes the argument;
;;;   - the settings and the limits reaching the handshake, and limits an app
;;;     builds from the env it gives run-server;
;;;   - middleware around the answer, and a take-over wrapped with its answer
;;;     dropped.
;;;
;;; Oracles, each written here by hand, never computed by chez-websocket:
;;;   - RFC 6455: §1.3's key, dGhlIHNhbXBsZSBub25jZQ==, and its
;;;     Sec-WebSocket-Accept, s3pPLMBiTxaQ9kYGzzhZRbK+xOo=; §5.7's masked
;;;     "Hello" and its unmasked form; §5.3's masking, which makes the
;;;     client's close from §5.7's key; §5.5.1, a close answered with a close
;;;     that echoes its code; §7.4.1's 1000, and 1009 for a message too big;
;;;     §4.2.1's 400 for a handshake that is not one, §4.4's 400 with
;;;     Sec-WebSocket-Version for a version the server doesn't speak, and
;;;     §4.2.2's 403 for an origin it won't take;
;;;   - chez-websocket's docs/reference.md: the 101's fields, Upgrade,
;;;     Sec-WebSocket-Accept, then Sec-WebSocket-Protocol when a subprotocol
;;;     is chosen; a refusal 400 or 403, its fields Sec-WebSocket-Version: 13
;;;     for a wrong version and otherwise none, with no body; the defaults, no
;;;     subprotocols and the request's own host as the one origin; a
;;;     WebSocket's close code, the client's, or 1006 when no close came; and
;;;     its docs/configuration.md: a message past max-message-bytes closes
;;;     with 1009; websocket-limits-from-environment applies each CHEZ_WS_
;;;     variable its lookup gives over the defaults;
;;;   - the server's docs: a 101 carries no Date, and the server writes its
;;;     Connection: upgrade after the app's fields (upgrades.md); an empty
;;;     response carries Date and Content-Length: 0; a request that asks to
;;;     switch, Connection: upgrade with Upgrade, answered otherwise, is
;;;     closed after it, Connection: close (connections.md); an absolute-form
;;;     target's authority is the request's host, whatever Host says
;;;     (reference.md, request-host);
;;;   - chez-websocket's ADR-0009: a take-over wrapped with its answer
;;;     dropped writes the 101, and the procedure never runs;
;;;   - (websocket handshake)'s header, which its docs leave out: when
;;;     X-Forwarded-Proto names http or https, a same-host Origin's scheme
;;;     must be the one its leftmost element names; and RFC 9110 §5.3: a
;;;     field's lines are one list, in the order they came.
;;;
;;; What a row asserts: a res's status and whole header list; on the wire,
;;; every byte the client read, one character a byte, after the request and
;;; after each frame it sends; whether the connection ended; the server's
;;; log, whole; and the notes the WebSocket's procedure made, so a refusal
;;; shows it never ran. The test host's clock stays at 0, so a Date reads
;;; Thu, 01 Jan 1970 00:00:00 GMT, and no ping comes. chez-websocket writes
;;; its own line for the 1009, websocket-failed 1009 message-too-big, on
;;; standard output, which no row reads.
(import (rnrs)
        (srfi :64)
        (circuit-testing)
        (http-server testing)
        (circuit)
        (circuit http-server)
        (circuit test)
        (only (circuit request) make-req-view make-req)
        (circuit websocket)
        (websocket))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner names a failing test but not its values. Print both.
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
        (newline)))))

;;; ------------------------------------------------------------------------
;;; Helpers

(define (b s) (string->utf8 s))

;; text : Bytevector -> String
;; BV one character a byte, so any bytes read back as they were sent.
(define (text bv)
  (list->string (map integer->char (bytevector->u8-list bv))))

;; frame : (Listof Nat) -> String — a frame's bytes, as text reads them.
(define (frame bytes) (text (u8-list->bytevector bytes)))

;; lines : (Listof String) -> String — each field a line, CRLF after each.
(define (lines fields)
  (apply string-append (map (lambda (f) (string-append f "\r\n")) fields)))

(define unset (lambda (name) #f))

;; shown : Any -> Any
;; A detail of a log entry: a condition by its kind, who, message and
;; irritants; anything else as it is.
(define (shown d)
  (cond ((not (condition? d)) d)
        (else (list (if (assertion-violation? d) 'assertion 'condition)
                    (and (who-condition? d) (condition-who d))
                    (and (message-condition? d) (condition-message d))
                    (and (irritants-condition? d) (condition-irritants d))))))

;; logged : TestHost -> (Listof Any) — what the server logged, in order.
(define (logged host)
  (map (lambda (entry) (cons (car entry) (map shown (cdr entry)))) (test-host-log host)))

;; raised : (-> Any) -> Any
;; What THUNK raised, an assertion violation by its who, message and
;; irritants, anything else by its text; 'nothing-raised when it returns.
(define (raised thunk)
  (guard (e ((assertion-violation? e)
             (list 'assertion
                   (and (who-condition? e) (condition-who e))
                   (and (message-condition? e) (condition-message e))
                   (and (irritants-condition? e) (condition-irritants e))))
            (#t (list 'other (describe e))))
    (thunk)
    'nothing-raised))

;;; ------------------------------------------------------------------------
;;; Frames, RFC 6455's

;; §5.7: a single-frame masked text message, "Hello", and the server's
;; unmasked one.
(define masked-hello '(#x81 #x85 #x37 #xfa #x21 #x3d #x7f #x9f #x4d #x51 #x58))
(define hello '(#x81 #x05 #x48 #x65 #x6c #x6c #x6f))

;; The client's close: code 1000 (§7.4.1), its body's two bytes 03 e8
;; (§5.5.1), masked with §5.7's key 37 fa 21 3d (§5.3): 34 12.
(define masked-close-1000 '(#x88 #x82 #x37 #xfa #x21 #x3d #x34 #x12))

;; The server's close echoing 1000 (§5.5.1), and its close for a message
;; too big, 1009 (§7.4.1), each unmasked.
(define close-1000 '(#x88 #x02 #x03 #xe8))
(define close-1009 '(#x88 #x02 #x03 #xf1))

;;; ------------------------------------------------------------------------
;;; Requests

;; RFC 6455 §1.3's handshake, its Origin left out: a client that is no
;; browser, offering §1.3's subprotocols.
(define rfc-fields
  '("Host: server.example.com" "Upgrade: websocket" "Connection: Upgrade"
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" "Sec-WebSocket-Protocol: chat, superchat"
    "Sec-WebSocket-Version: 13"))

;; request : String (Listof String) -> String
;; The request LINE, then FIELDS, a line each, then the blank line.
(define (request line fields)
  (string-append line "\r\n" (lines fields) "\r\n"))

(define (get-chat fields) (request "GET /chat HTTP/1.1" fields))

;; field-name : String -> String — what a field line holds before its colon.
(define (field-name line)
  (let loop ((i 0))
    (cond ((= i (string-length line)) line)
          ((char=? (string-ref line i) #\:) (substring line 0 i))
          (else (loop (+ i 1))))))

;; without : (Listof String) String -> (Listof String)
;; FIELDS without the field named NAME, in any case.
(define (without fields name)
  (filter (lambda (f) (not (string-ci=? (field-name f) name))) fields))

;; replacing : (Listof String) String -> (Listof String)
;; FIELDS with the field LINE names replaced by LINE, in its place.
(define (replacing fields line)
  (map (lambda (f) (if (string-ci=? (field-name f) (field-name line)) line f)) fields))

;; pairs : (Listof String) -> (Listof (Pair String String))
;; Each "Name: value" line as (Name . value), for make-test-req.
(define (pairs fields)
  (map (lambda (f)
         (let ((name (field-name f)))
           (cons name (substring f (+ (string-length name) 2) (string-length f)))))
       fields))

;;; ------------------------------------------------------------------------
;;; Answers, as the server writes them

(define upgrade-field "Upgrade: websocket")
(define accept-field "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
(define chat-field "Sec-WebSocket-Protocol: chat")

;; switched : (Listof String) -> String
;; The 101 as the server writes it: FIELDS, then its own Connection:
;; upgrade. A 1xx carries no Date.
(define (switched fields)
  (string-append "HTTP/1.1 101 Switching Protocols\r\n" (lines fields) "Connection: upgrade\r\n\r\n"))

;; The 101 for §1.3's key, with no subprotocol, and with chat.
(define rfc-101 (switched (list upgrade-field accept-field)))
(define chat-101 (switched (list upgrade-field accept-field chat-field)))

;; emptied : String (Listof String) Boolean -> String
;; An empty response as the server writes it at 0 ms: STATUS, Date,
;; FIELDS, Content-Length: 0, then Connection: close when CLOSING?.
(define (emptied status fields closing?)
  (string-append "HTTP/1.1 " status "\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\n" (lines fields)
                 "Content-Length: 0\r\n" (if closing? "Connection: close\r\n" "") "\r\n"))

;;; ------------------------------------------------------------------------
;;; Running it

;; noting-echo : (Any -> Void) -> (WebSocket -> Any)
;; A WebSocket's procedure that notes its subprotocol, then sends each
;; message back, noting it, until the connection ends, whose code it notes.
;; The end goes on out, as the WebSocket's own.
(define (noting-echo note)
  (lambda (ws)
    (note (list 'subprotocol (websocket-subprotocol ws)))
    (guard (e ((websocket-closed? e) (note (list 'closed (websocket-closed-code e))) (raise e)))
      (let loop ()
        (let ((message (websocket-receive ws)))
          (note (list 'message message))
          (websocket-send! ws message)
          (loop))))))

;; Talk = (List (Listof String) Boolean (Listof Any))
;; talk : (Req -> Res) String (Listof (Listof Nat)) Env -> Talk
;; A client sends REQUEST, then each of FRAMES: every byte it has read,
;; after the request and after each frame, as text; whether the server
;; ended the connection; and the server's log. The host and
;; circuit->handler read ENV, as run-server's serve and circuit->handler
;; read the env it is given.
(define (talk app req frames env)
  (let* ((host (make-test-host (circuit->handler app env) env))
         (c (test-host-connect! host)))
    (test-client-send! c (b req))
    (let loop ((frames frames) (seen (list (text (test-client-received c)))))
      (if (null? frames)
          (list (reverse seen) (test-client-connection-closed? c) (logged host))
          (begin
            (test-client-send! c (u8-list->bytevector (car frames)))
            (loop (cdr frames) (cons (text (test-client-received c)) seen)))))))

;; noted-talk : ((WebSocket -> Any) (Any -> Void) -> (Req -> Res)) String (Listof (Listof Nat))
;;              [Env] -> (List Talk (Listof Any))
;; talk, its app what MAKE-APP makes of a noting echo and its note
;; procedure, and the notes, in order. ENV is unset when left out.
(define noted-talk
  (case-lambda
    ((make-app req frames) (noted-talk make-app req frames unset))
    ((make-app req frames env)
     (let* ((notes '())
            (note (lambda (x) (set! notes (cons x notes))))
            (seen (talk (make-app (noting-echo note) note) req frames env)))
       (list seen (reverse notes))))))

;; plain : (WebSocket -> Any) (Any -> Void) -> (Req -> Res)
;; The app (websocket-res r echo), its settings and limits the defaults.
(define (plain echo note) (lambda (r) (websocket-res r echo)))

;; with-settings : HandshakeSettings -> ((WebSocket -> Any) (Any -> Void) -> (Req -> Res))
(define (with-settings settings)
  (lambda (echo note) (lambda (r) (websocket-res r echo settings))))

;; The echo's notes for one Hello and the client's close 1000.
(define (echoed subprotocol)
  (list (list 'subprotocol subprotocol) '(message "Hello") '(closed 1000)))

;; What the client reads of a 101 HEAD, a Hello echoed, then the close.
(define (echo-wire head)
  (list head (string-append head (frame hello)) (string-append head (frame hello) (frame close-1000))))

(define chat-settings (make-handshake-settings '("chat")))

;;; ------------------------------------------------------------------------
;;; The rows

(test-begin "websocket")

;;; --- the 101 --------------------------------------------------------------

(test-equal "RFC 6455 §1.3's handshake: a 101 of the handshake's headers, whole, in order, and an upgrade body, so middleware passes it by"
  (list 101 '(("Upgrade" . "websocket") ("Sec-WebSocket-Accept" . "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")) #t)
  (let ((r (websocket-res (make-test-req 'GET "/chat" (pairs rfc-fields)) (lambda (ws) #f))))
    (list (res-status r) (res-headers r) (res-upgrade-body? (res-body r)))))

(test-equal "RFC 6455 §1.3's handshake on the wire: the 101's whole head, no subprotocol by default though two are offered; §5.7's masked Hello echoed unmasked; the client's close 1000 answered 1000, and the connection ended"
  (list (list (echo-wire rfc-101) #t '()) (echoed #f))
  (noted-talk plain (get-chat rfc-fields) (list masked-hello masked-close-1000)))

(test-equal "settings that speak chat: the 101 names it, after the accept, and the WebSocket's procedure sees it"
  (list (list (echo-wire chat-101) #t '()) (echoed "chat"))
  (noted-talk (with-settings chat-settings) (get-chat rfc-fields) (list masked-hello masked-close-1000)))

(test-equal "settings that speak chat: the res's headers, whole, in order"
  (list 101 '(("Upgrade" . "websocket") ("Sec-WebSocket-Accept" . "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
              ("Sec-WebSocket-Protocol" . "chat")))
  (let ((r (websocket-res (make-test-req 'GET "/chat" (pairs rfc-fields)) (lambda (ws) #f) chat-settings)))
    (list (res-status r) (res-headers r))))

;;; --- the refusals -----------------------------------------------------------

;; Each refusal: the request's method and fields, §1.3's with one thing
;; wrong, the status and the res's headers, the status line and fields on
;; the wire, and whether the request asked to switch, so the server closes.
(define refusals
  (list
   (list "the method is not GET" 'POST rfc-fields
         400 '() "400 Bad Request" '() #t)
   (list "no Upgrade: websocket" 'GET (without rfc-fields "Upgrade")
         400 '() "400 Bad Request" '() #f)
   (list "a Connection that lists no upgrade" 'GET (replacing rfc-fields "Connection: keep-alive")
         400 '() "400 Bad Request" '() #f)
   (list "a version that is not 13" 'GET (replacing rfc-fields "Sec-WebSocket-Version: 8")
         400 '(("Sec-WebSocket-Version" . "13")) "400 Bad Request" '("Sec-WebSocket-Version: 13") #t)
   (list "a key that is not the base64 of sixteen bytes" 'GET
         (replacing rfc-fields "Sec-WebSocket-Key: c2hvcnQ=")
         400 '() "400 Bad Request" '() #t)
   (list "an Origin of another host, §1.3's own, by default" 'GET
         (append rfc-fields '("Origin: http://example.com"))
         403 '() "403 Forbidden" '() #t)))

(for-each
 (lambda (row)
   (let ((what (list-ref row 0))
         (method (list-ref row 1))
         (fields (list-ref row 2))
         (status (list-ref row 3))
         (headers (list-ref row 4))
         (status-line (list-ref row 5))
         (wire-fields (list-ref row 6))
         (closing? (list-ref row 7)))
     (test-equal (string-append "a refusal, " what ": its status and its headers, whole, no body, the procedure never run")
       (list status headers #f 0 '())
       (let* ((notes '())
              (r (websocket-res (make-test-req method "/chat" (pairs fields))
                                (lambda (ws) (set! notes (cons 'ran notes))))))
         (list (res-status r) (res-headers r) (res-body r) (res-body-length r) notes)))
     (test-equal (string-append "a refusal, " what ", on the wire: the status, Date, its fields, Content-Length: 0, no body"
                                (if closing? ", then Connection: close, the connection ended" ", the connection kept")
                                "; the procedure never run")
       (list (list (list (emptied status-line wire-fields closing?)) closing? '()) '())
       (noted-talk plain (request (string-append (symbol->string method) " /chat HTTP/1.1") fields) '()))))
 refusals)

;;; --- the host ----------------------------------------------------------------

;; An absolute-form target names app.example, and Host internal:8080: the
;; handshake is handed req-host, so its same-host check takes the target's.
(define (absolute-chat origin)
  (request "GET http://app.example/chat HTTP/1.1"
           (append (replacing rfc-fields "Host: internal:8080") (list origin))))

;; hosted : ((WebSocket -> Any) (Any -> Void) -> (Req -> Res))
;; plain, noting first the request's host and its Host field.
(define (hosted echo note)
  (lambda (r)
    (note (list 'host (req-host r) (req-header r "host")))
    (websocket-res r echo)))

(test-equal "the host is req-host's, app.example, not the Host field's, internal:8080: Origin: https://app.example is accepted"
  (list (list (list rfc-101) #f '()) (list '(host "app.example" "internal:8080") '(subprotocol #f)))
  (noted-talk hosted (absolute-chat "Origin: https://app.example") '()))

(test-equal "the host is req-host's, app.example, not the Host field's, internal:8080: Origin: http://internal:8080 is refused 403"
  (list (list (list (emptied "403 Forbidden" '() #t)) #t '()) (list '(host "app.example" "internal:8080")))
  (noted-talk hosted (absolute-chat "Origin: http://internal:8080") '()))

;;; --- a field over several lines ------------------------------------------------

(test-equal "Connection over two lines, keep-alive then Upgrade: joined, it lists upgrade, and the handshake is taken"
  (list (list (echo-wire rfc-101) #t '()) (echoed #f))
  (noted-talk plain
              (get-chat (append (without rfc-fields "Connection") '("Connection: keep-alive" "Connection: Upgrade")))
              (list masked-hello masked-close-1000)))

(test-equal "X-Forwarded-Proto over two lines, in order: https then http leads with https, and Origin: https://server.example.com is the same host's; http then https leads with http, and it is refused 403"
  (list (list (list (list rfc-101) #f '()) '((subprotocol #f)))
        (list (list (list (emptied "403 Forbidden" '() #t)) #t '()) '()))
  (map (lambda (protos)
         (noted-talk plain
                     (get-chat (append rfc-fields '("Origin: https://server.example.com")
                                       (map (lambda (p) (string-append "X-Forwarded-Proto: " p)) protos)))
                     '()))
       '(("https" "http") ("http" "https"))))

(test-equal "Sec-WebSocket-Protocol over two lines, chat then superchat, and settings that speak chat: joined, chat is chosen"
  (list (list (echo-wire chat-101) #t '()) (echoed "chat"))
  (noted-talk (with-settings chat-settings)
              (get-chat (append (without rfc-fields "Sec-WebSocket-Protocol")
                                '("Sec-WebSocket-Protocol: chat" "Sec-WebSocket-Protocol: superchat")))
              (list masked-hello masked-close-1000)))

;;; --- the argument faults ---------------------------------------------------------

;; observed : -> (Values Req (-> (Listof Symbol)))
;; A request for GET /chat, with no fields, whose view notes each field it
;; is asked for; and a procedure answering those it noted, newest first.
(define (observed)
  (let* ((asked '())
         (ask (lambda (field answer) (lambda args (set! asked (cons field asked)) answer)))
         (view (make-req-view (ask 'method 'GET) (ask 'host "server.example.com") (ask 'path "/chat")
                              (ask 'query #f) (ask 'http-version '(1 . 1)) (ask 'header #f)
                              (ask 'header-values '()) (ask 'headers '()) #f #f #f #f #f #f)))
    (values (make-req view 'source) (lambda () asked))))

(define settings (make-handshake-settings '()))
(define limits default-websocket-limits)
(define (proc ws) #f)

;; faulted : (Req -> Any) -> (List Any (Listof Symbol))
;; What CALL raises on an observed request, then the fields it had asked
;; for by then, in that order.
(define (faulted call)
  (let-values (((r asked) (observed)))
    (let* ((got (raised (lambda () (call r))))
           (seen (asked)))
      (list got seen))))

(test-equal "the observed request is read once the arguments are right: its method, its host and its fields"
  (list 400 #t #t #t)
  (let-values (((r asked) (observed)))
    (let* ((answer (websocket-res r proc))
           (seen (asked)))
      (list (res-status answer) (and (memq 'method seen) #t) (and (memq 'host seen) #t)
            (and (memq 'header-values seen) #t)))))

(test-equal "no request, in each form: an assertion violation naming websocket-res, the value named"
  (list (list 'assertion 'websocket-res "not a request" '(nope))
        (list 'assertion 'websocket-res "not a request" '(nope))
        (list 'assertion 'websocket-res "not a request" '(nope)))
  (list (raised (lambda () (websocket-res 'nope proc)))
        (raised (lambda () (websocket-res 'nope proc settings)))
        (raised (lambda () (websocket-res 'nope proc settings limits)))))

(test-equal "a res is no request: an assertion violation naming websocket-res"
  'websocket-res
  (let* ((r (make-res 200 '() #f))
         (got (raised (lambda () (websocket-res r proc)))))
    (if (and (pair? got) (eq? (car got) 'assertion) (equal? (cadddr got) (list r)))
        (cadr got)
        got)))

(test-equal "a procedure that is none, in each form: an assertion violation naming websocket-res, before the request is read"
  (list (list (list 'assertion 'websocket-res "not a procedure" '(42)) '())
        (list (list 'assertion 'websocket-res "not a procedure" '(42)) '())
        (list (list 'assertion 'websocket-res "not a procedure" '(42)) '()))
  (list (faulted (lambda (r) (websocket-res r 42)))
        (faulted (lambda (r) (websocket-res r 42 settings)))
        (faulted (lambda (r) (websocket-res r 42 settings limits)))))

(test-equal "settings that are none, in each form that takes them: an assertion violation naming websocket-res, before the request is read"
  (list (list (list 'assertion 'websocket-res "not handshake settings" '(chat)) '())
        (list (list 'assertion 'websocket-res "not handshake settings" '(chat)) '()))
  (list (faulted (lambda (r) (websocket-res r proc 'chat)))
        (faulted (lambda (r) (websocket-res r proc 'chat limits)))))

(test-equal "limits that are none: an assertion violation naming websocket-res, before the request is read"
  (list (list 'assertion 'websocket-res "not limits" '(1024)) '())
  (faulted (lambda (r) (websocket-res r proc settings 1024))))

(test-equal "faults in every argument at once: the first in the argument order is named, in each form"
  (list (list 'assertion 'websocket-res "not a request" '(nope))
        (list 'assertion 'websocket-res "not a request" '(nope))
        (list 'assertion 'websocket-res "not a request" '(nope))
        (list (list 'assertion 'websocket-res "not a procedure" '(42)) '())
        (list (list 'assertion 'websocket-res "not handshake settings" '(chat)) '()))
  (list (raised (lambda () (websocket-res 'nope 42)))
        (raised (lambda () (websocket-res 'nope 42 'chat)))
        (raised (lambda () (websocket-res 'nope 42 'chat 1024)))
        (faulted (lambda (r) (websocket-res r 42 'chat 1024)))
        (faulted (lambda (r) (websocket-res r proc 'chat 1024)))))

;;; --- the settings and the limits reach the handshake --------------------------------

(test-equal "settings that take https://elsewhere.example: its Origin is accepted, where the default refuses it 403"
  (list (list (list (list rfc-101) #f '()) '((subprotocol #f)))
        (list (list (list (emptied "403 Forbidden" '() #t)) #t '()) '()))
  (let ((req (get-chat (append rfc-fields '("Origin: https://elsewhere.example")))))
    (list (noted-talk (with-settings (make-handshake-settings '() '("https://elsewhere.example"))) req '())
          (noted-talk plain req '()))))

(test-equal "limits whose max-message-bytes is 4, beside settings that speak chat: the 101 names chat, and a Hello of 5 bytes is closed 1009, the connection ended, no close from the client"
  (list (list (list chat-101 (string-append chat-101 (frame close-1009))) #t '())
        '((subprotocol "chat") (closed 1006)))
  (noted-talk (lambda (echo note)
                (lambda (r)
                  (websocket-res r echo chat-settings
                                 (websocket-limits-with default-websocket-limits '((max-message-bytes . 4))))))
              (get-chat rfc-fields)
              (list masked-hello)))

;; env-app : Env -> ((WebSocket -> Any) (Any -> Void) -> (Req -> Res))
;; README.org's app for the env it gives run-server: its limits built from
;; ENV with websocket-limits-from-environment, beside the default settings,
;; each made once.
(define (env-app env)
  (lambda (echo note)
    (let ((settings (make-handshake-settings '()))
          (limits (websocket-limits-from-environment env)))
      (lambda (r) (websocket-res r echo settings limits)))))

;; An Env that sets CHEZ_WS_MAX_MESSAGE_BYTES to 4, and nothing else.
(define (max-message-4 name) (and (string=? name "CHEZ_WS_MAX_MESSAGE_BYTES") "4"))

(test-equal "limits an app builds from the env it gives run-server: with CHEZ_WS_MAX_MESSAGE_BYTES 4 there, a Hello of 5 bytes is closed 1009, the connection ended; with nothing there, it is echoed"
  (list (list (list (list rfc-101 (string-append rfc-101 (frame close-1009))) #t '())
              '((subprotocol #f) (closed 1006)))
        (list (list (echo-wire rfc-101) #t '()) (echoed #f)))
  (list (noted-talk (env-app max-message-4) (get-chat rfc-fields) (list masked-hello) max-message-4)
        (noted-talk (env-app unset) (get-chat rfc-fields) (list masked-hello masked-close-1000) unset)))

;;; --- middleware ------------------------------------------------------------------------

(test-equal "a refusal's body is no upgrade, and middleware passes it as any response"
  (list 400 #f)
  (let ((r (websocket-res (make-test-req 'GET "/chat" (pairs (without rfc-fields "Upgrade"))) proc)))
    (list (res-status r) (res-upgrade-body? (res-body r)))))

(test-equal "res-set-header on the 101 keeps it an upgrade: the field after the handshake's, then the echo"
  (list (list (echo-wire (switched (list upgrade-field accept-field "x-app: yes"))) #t '()) (echoed #f))
  (noted-talk (lambda (echo note)
                (wrap (lambda (r) (websocket-res r echo))
                      (lambda (handler) (lambda (r) (res-set-header (handler r) "x-app" "yes")))))
              (get-chat rfc-fields)
              (list masked-hello masked-close-1000)))

;; wrapping : Boolean -> ((WebSocket -> Any) (Any -> Void) -> (Req -> Res))
;; plain, under a middleware that makes a new upgrade of the 101's headers
;; and a take-over that notes, then calls the handshake's: answering what
;; it answers when ANSWERS?, else dropping it.
(define (wrapping answers?)
  (lambda (echo note)
    (wrap (lambda (r) (websocket-res r echo))
          (lambda (handler)
            (lambda (r)
              (let* ((answer (handler r))
                     (inner (res-upgrade-body-take-over (res-body answer))))
                (make-upgrade-res (res-headers answer)
                                  (lambda (t retained)
                                    (note '(outer))
                                    (let ((got (inner t retained)))
                                      (if answers? got 'dropped))))))))))

(test-equal "a middleware that wraps the take-over and answers what it answers: its note first, then the echo"
  (list (list (echo-wire rfc-101) #t '()) (cons '(outer) (echoed #f)))
  (noted-talk (wrapping #t) (get-chat rfc-fields) (list masked-hello masked-close-1000)))

;; Whether the connection ends is left out: no oracle says.
(test-equal "a middleware that wraps the take-over and drops its answer: the 101 is written, the procedure never runs, and a Hello gets no echo"
  (list (list rfc-101 rfc-101) '() '((outer)))
  (let* ((got (noted-talk (wrapping #f) (get-chat rfc-fields) (list masked-hello)))
         (seen (car got)))
    (list (car seen) (caddr seen) (cadr got))))

(test-end "websocket")

(exit (suite-exit-status runner))
