#!r6rs
;;; (circuit http-server): the adapter, run through the server's test host,
;;; (http-server testing), with (circuit->handler app env) as its handler and
;;; the same env as its settings (design §9, §10).
;;;
;;;   - the view: every req- accessor through the adapter, HTTP/1.0 and 1.2
;;;     included, the four addresses #f in the test host;
;;;   - req-body: a body sent in pieces read whole, one never read, Expect:
;;;     100-continue sent at the first read, a &body-failed let out answered
;;;     with its status, a with-deadline around a read, one port for every
;;;     copy of the request;
;;;   - the request's cap, from wrap-body-cap, reaching the server: a body
;;;     at it read, one past it refused, declared or chunked, with no 100
;;;     Continue; the innermost cap winning;
;;;   - req-on-done! reaching the server: written, client-closed and failed;
;;;   - each body kind's wire form, and port bodies: sized from their
;;;     position, past their length, chunked in pieces of the piece size,
;;;     closed however the response ends, bare and wrapped, a file that
;;;     shrinks or grows, a measure that raises. A bare port of one piece or
;;;     less is read whole and closed as the app answers, which another
;;;     request woken at the same instant sees; a row that holds the
;;;     streamed path gives a piece size smaller than its port;
;;;   - sized bodies and the server's mismatch handling; wraps and taps;
;;;   - a client that leaves while the app waits;
;;;   - upgrades: the 101, then the taker's bytes and the client's, a taker
;;;     that waits, middleware that adds a field, removes one or wraps the
;;;     take-over, an app that made its req-body, and the refusals, a 101
;;;     that make-res made among them;
;;;   - refusals, each a 500 before the head, logged handler-failed;
;;;   - CIRCUIT_PORT_PIECE_BYTES, read once, from env or the process's
;;;     environment, and the malformed values it refuses;
;;;   - parity: (circuit test)'s res-body->bytevector reads the bytes the
;;;     test host's client reads.
;;;
;;; What a row asserts:
;;;   - a row that asserts a response asserts it whole, as its wire bytes,
;;;     one character a byte (Latin-1), so a header's Latin-1 byte and a
;;;     body's UTF-8 bytes read as sent; and with it whether the connection
;;;     ended and the server's log, whole, each condition in it shown by its
;;;     kind, who, message and irritants;
;;;   - but the FIFO row asserts its log by each entry's kind and the who of
;;;     the condition, port-position: the message is the OS's;
;;;   - the version row and the one-port row assert what the app read, and
;;;     neither the wire nor the log;
;;;   - an upgrade row asserts every byte the client read, the 101 has no
;;;     Date, and what the taker was handed, whether the connection ended
;;;     and the log;
;;;   - the setting rows and the parity row assert the chunks' sizes and the
;;;     body's bytes, or the condition raised, whole, and not the log.
;;; The test host's clock stays under a second, so a Date field reads
;;; Thu, 01 Jan 1970 00:00:00 GMT, but in the long poll's row, where the
;;; 504 is written at 30 s. Whether a port is closed is Chez's port-closed?.
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (only (chezscheme) port-closed? putenv)
        (circuit-testing)
        (http-server)
        (http-server testing)
        (circuit)
        (circuit http-server)
        (circuit test)
        (only (circuit request) req-body-made))

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
  (let* ((n (bytevector-length bv)) (s (make-string n)))
    (let loop ((i 0))
      (if (= i n)
          s
          (begin (string-set! s i (integer->char (bytevector-u8-ref bv i)))
                 (loop (+ i 1)))))))

;; utf8-text : String -> String — S's UTF-8 bytes, one character a byte.
(define (utf8-text s) (text (string->utf8 s)))

;; settings : String ... -> (String -> (U String #f))
;; An environment procedure from NAME VALUE pairs; any other name is unset.
(define (settings . pairs)
  (let loop ((rest pairs) (alist '()))
    (if (null? rest)
        (lambda (name) (let ((hit (assoc name alist))) (and hit (cdr hit))))
        (loop (cddr rest) (cons (cons (car rest) (cadr rest)) alist)))))

(define unset (settings))

(define piece-variable "CIRCUIT_PORT_PIECE_BYTES")

;; host-of : (Req -> Res) (String -> (U String #f)) -> TestHost
;; A test host for the adapter over APP, both reading ENV.
(define (host-of app env)
  (make-test-host (circuit->handler app env) env))

;; wire : TestClient -> (Listof String)
;; Each response the client read, as its bytes on the wire.
(define (wire c)
  (map (lambda (r) (text (test-response-bytes r))) (test-client-responses c)))

;; received : TestClient -> String — every byte the client read.
(define (received c) (text (test-client-received c)))

;; shown : Any -> Any
;; A detail of a log entry: a condition by its kind, who, message and
;; irritants; anything else as it is.
(define (shown d)
  (cond ((not (condition? d)) d)
        ((body-failed? d) (list 'body-failed (body-failed-status d) (body-failed-reason d)))
        (else (list (if (assertion-violation? d) 'assertion 'condition)
                    (and (who-condition? d) (condition-who d))
                    (and (message-condition? d) (condition-message d))
                    (and (irritants-condition? d) (condition-irritants d))))))

;; logged : TestHost -> (Listof Any) — what the server logged, in order.
(define (logged host)
  (map (lambda (entry) (cons (car entry) (map shown (cdr entry)))) (test-host-log host)))

;; exchange : (Req -> Res) String [(String -> (U String #f))]
;;            -> (List (Listof String) Boolean (Listof Any))
;; One client sends REQUEST: what it read, whether the server ended the
;; connection, and what the server logged.
(define exchange
  (case-lambda
    ((app request) (exchange app request unset))
    ((app request env)
     (let* ((host (host-of app env))
            (c (test-host-connect! host)))
       (test-client-send! c (b request))
       (list (wire c) (test-client-connection-closed? c) (logged host))))))

(define (get path) (string-append "GET " path " HTTP/1.1\r\nHost: x\r\n\r\n"))
(define (head path) (string-append "HEAD " path " HTTP/1.1\r\nHost: x\r\n\r\n"))
(define (post path body)
  (string-append "POST " path " HTTP/1.1\r\nHost: x\r\nContent-Length: "
                 (number->string (string-length body)) "\r\n\r\n" body))

;; response : String (Listof String) String -> String
;; A response as the server writes it in its first second: STATUS, Date,
;; FIELDS, BODY.
(define (response status fields body)
  (response-at "00:00:00" status fields body))

;; response-at : String String (Listof String) String -> String
;; As response, written at the time of day CLOCK on 1 January 1970.
(define (response-at clock status fields body)
  (string-append "HTTP/1.1 " status "\r\nDate: Thu, 01 Jan 1970 " clock " GMT\r\n"
                 (apply string-append (map (lambda (f) (string-append f "\r\n")) fields))
                 "\r\n" body))

;; chunks : String ... -> String — each piece a chunk, then the last chunk.
(define (chunks . pieces)
  (string-append (apply string-append
                        (map (lambda (p)
                               (string-append (number->string (string-length p) 16) "\r\n" p "\r\n"))
                             pieces))
                 "0\r\n\r\n"))

(define chunked "Transfer-Encoding: chunked")
(define (length-field n) (string-append "Content-Length: " (number->string n)))
(define server-error (response "500 Internal Server Error" '("Content-Length: 0" "Connection: close") ""))

;; refused : String (Listof Any) -> (List (Listof String) Boolean (Listof Any))
;; The exchange of a request the adapter refuses with MESSAGE and
;; IRRITANTS: a 500, the connection ended, logged handler-failed.
(define (refused message irritants)
  (list (list server-error) #t
        (list (list 'handler-failed (list 'assertion 'circuit->handler message irritants)))))

;; The adapter's messages.
(define not-a-res "the app answered no res")
(define echo "the response's body holds its request's req-body port, which no producer can read")
(define not-a-field "a header is a (name . value) pair of strings")
(define not-latin-1 "a header character above 255 cannot be sent: headers are Latin-1")
(define not-an-app "an app is a procedure from a req to a res")
(define not-an-env "an environment is a procedure from a variable's name to its value or #f")
(define malformed "expected a whole number of bytes, 1 or more, in ASCII digits")

;; producer : String ... -> Producer — each text's bytes in turn, then eof.
(define (producer . texts)
  (let ((left (map b texts)))
    (lambda ()
      (if (null? left)
          (eof-object)
          (let ((piece (car left)))
            (set! left (cdr left))
            piece)))))

;; custom-port : String -> BinaryInputPort
;; A port over S's bytes with no length and no position: Chez can't size it.
(define (custom-port s)
  (waiting-port s #f))

;; positioned-custom-port : String -> BinaryInputPort
;; A port over S's bytes with a position it can tell and set, and no length:
;; Chez gives no custom port one, so it goes out chunked.
(define (positioned-custom-port s)
  (let ((bytes (b s)) (at 0))
    (make-custom-binary-input-port
     "positioned"
     (lambda (bv start count)
       (let ((n (min count (- (bytevector-length bytes) at))))
         (bytevector-copy! bytes at bv start n)
         (set! at (+ at n))
         n))
     (lambda () at)
     (lambda (position) (set! at position))
     #f)))

;; waiting-port : String (U Nat #f) -> BinaryInputPort
;; As custom-port, each read waiting MS first, when MS is a number.
(define (waiting-port s ms)
  (let ((bytes (b s)) (at 0))
    (make-custom-binary-input-port
     "custom"
     (lambda (bv start count)
       (when ms (sleep-ms ms))
       (let ((n (min count (- (bytevector-length bytes) at))))
         (bytevector-copy! bytes at bv start n)
         (set! at (+ at n))
         n))
     #f #f #f)))

;; positioned : String Nat -> BinaryInputPort
;; A bytevector port over S, AT bytes of it already read.
(define (positioned s at)
  (let ((port (open-bytevector-input-port (b s))))
    (get-bytevector-n port at)
    port))

;; write-file : String String -> Unit — PATH holds S's bytes, and only them.
(define (write-file path s)
  (call-with-port (open-file-output-port path (file-options no-fail))
    (lambda (port) (put-bytevector port (b s)))))

;; upcased : Producer -> Producer — each piece's ASCII letters in upper case.
(define (upcased inner)
  (lambda ()
    (let ((piece (inner)))
      (if (eof-object? piece)
          piece
          (u8-list->bytevector
           (map (lambda (u) (if (and (>= u 97) (<= u 122)) (- u 32) u))
                (bytevector->u8-list piece)))))))

;; trailer : String -> (Producer -> Producer)
;; A wrap's f that sends S after the body under it.
(define (trailer s)
  (lambda (inner)
    (let ((done? #f))
      (lambda ()
        (if done?
            (eof-object)
            (let ((piece (inner)))
              (if (eof-object? piece)
                  (begin (set! done? #t) (b s))
                  piece)))))))

(define (as-is inner) inner)

;; chunk-sizes : Bytevector -> (Listof Nat)
;; The sizes of a chunked response's chunks, the last chunk's 0 included.
(define (chunk-sizes bv)
  (let ((n (bytevector-length bv)))
    (define (crlf? i)
      (and (< (+ i 1) n) (= (bytevector-u8-ref bv i) 13) (= (bytevector-u8-ref bv (+ i 1)) 10)))
    (define (line-end i)
      (cond ((crlf? i) i)
            ((< i n) (line-end (+ i 1)))
            (else (assertion-violation 'chunk-sizes "a chunk's line runs past the bytes" i))))
    (define (span from to)
      (let ((out (make-bytevector (- to from))))
        (bytevector-copy! bv from out 0 (- to from))
        out))
    (let find-head ((i 0))
      (if (and (crlf? i) (crlf? (+ i 2)))
          (let loop ((at (+ i 4)) (sizes '()))
            (let* ((end (line-end at))
                   (size (string->number (text (span at end)) 16)))
              (if (= size 0)
                  (reverse (cons 0 sizes))
                  (loop (+ end 2 size 2) (cons size sizes)))))
          (find-head (+ i 1))))))

;; filled : Nat -> String — N bytes of the letters a to z, repeated.
(define (filled n)
  (let ((s (make-string n)))
    (let loop ((i 0))
      (if (= i n)
          s
          (begin (string-set! s i (integer->char (+ 97 (mod i 26)))) (loop (+ i 1)))))))

;; raised-by : (-> Any) -> Any
;; What THUNK raised, by kind, who, message and irritants, with whether it
;; is a config error and an &error; no-raise if it returned.
(define (raised-by thunk)
  (guard (e ((condition? e)
             (list (http-server-config-error? e) (error? e) (assertion-violation? e)
                   (and (who-condition? e) (condition-who e))
                   (and (message-condition? e) (condition-message e))
                   (and (irritants-condition? e) (condition-irritants e))))
            (#t (list 'non-condition e)))
    (thunk)
    'no-raise))

(define (ok-app r) (make-res 200 '() "ok"))

(define key (make-req-key 'test))

;;; ------------------------------------------------------------------------

(test-begin "http-server")

;;; --- the view -------------------------------------------------------------

;; snapshot : Req -> (Listof Any) — every accessor's answer but the body's.
(define (snapshot r)
  (list (req-method r) (req-scheme r) (req-host r) (req-path r) (req-query r)
        (req-http-version r) (req-header r "X-ONE") (req-header r "x-missing")
        (req-header-values r "X-One") (req-headers r)
        (req-remote-address r) (req-remote-port r) (req-local-address r) (req-local-port r)))

(test-equal "the view: every accessor reads the server's request"
  (list '(DELETE http "example.test" "/a%20b/c" "x=1&y=2" (1 . 1) "first" #f ("first" "second")
          (("host" . "example.test") ("x-one" . "first") ("accept" . "*/*") ("x-one" . "second"))
          #f #f #f #f)
        (list (list (response "200 OK" (list (length-field 2)) "ok")) #f '()))
  (let* ((seen 'app-not-called)
         (result (exchange (lambda (r) (set! seen (snapshot r)) (ok-app r))
                           "DELETE /a%20b/c?x=1&y=2 HTTP/1.1\r\nHost: example.test\r\nX-One: first\r\nAccept: */*\r\nx-ONE: second\r\n\r\n")))
    (list seen result)))

(test-equal "the view: the version is major then minor, HTTP/1.0 and HTTP/1.2 alike"
  '(((1 . 0) "" "/old" #f ()) ((1 . 2) "y" "/new" "q" (("host" . "y"))))
  (map (lambda (request)
         (let ((seen 'app-not-called))
           (exchange (lambda (r)
                       (set! seen (list (req-http-version r) (req-host r) (req-path r)
                                        (req-query r) (req-headers r)))
                       (ok-app r))
                     request)
           seen))
       (list "GET /old HTTP/1.0\r\n\r\n" "GET /new?q HTTP/1.2\r\nHost: y\r\n\r\n")))

;;; --- req-body -------------------------------------------------------------

(test-equal "req-body: a body sent in pieces, across advances, is read whole"
  (list '() '() (list (response "200 OK" (list (length-field 11)) "hello world")) '())
  (let* ((host (host-of (lambda (r) (make-res 200 '() (get-bytevector-all (req-body r)))) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhel"))
    (let ((first (wire c)))
      (test-host-advance! host 5)
      (test-client-send! c (b "lo wo"))
      (let ((second (wire c)))
        (test-host-advance! host 5)
        (test-client-send! c (b "rld"))
        (list first second (wire c) (logged host))))))

(test-equal "req-body: an app that never reads it is answered at once, and the adapter makes no port"
  (list (list (list (response "200 OK" (list (length-field 2) "Connection: close") "no")) #t '())
        #f)
  (let* ((kept #f)
         (result (exchange (lambda (r) (set! kept r) (make-res 200 '() "no")) (post "/up" "hello"))))
    (list result (req-body-made kept))))

(test-equal "req-body: Expect: 100-continue is answered at the app's first read, not before"
  (list '()
        '("HTTP/1.1 100 Continue\r\n\r\n")
        (list "HTTP/1.1 100 Continue\r\n\r\n" (response "200 OK" (list (length-field 5)) "hello"))
        '())
  (let* ((host (host-of (lambda (r)
                          (sleep-ms 50)
                          (make-res 200 '() (get-bytevector-n (req-body r) 5)))
                        unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b "POST /up HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"))
    (let ((first (wire c)))
      (test-host-advance! host 50)
      (let ((second (wire c)))
        (test-client-send! c (b "hello"))
        (list first second (wire c) (logged host))))))

(test-equal "req-body: a &body-failed let out is answered with its status, under the env's cap"
  (list (list (response "413 Content Too Large" '("Content-Length: 0" "Connection: close") ""))
        #t
        '((handler-failed (body-failed 413 body-too-large))))
  (exchange (lambda (r) (make-res 200 '() (get-bytevector-all (req-body r))))
            "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n123456789\r\n0\r\n\r\n"
            (settings "CHEZ_HTTP_MAX_BODY_BYTES" "4")))

;;; --- the request's cap ------------------------------------------------------

;; capped-echo : Middleware ... -> (Req -> Res)
;; An app that answers its body, read whole, inside MIDDLEWARES.
(define (capped-echo . middlewares)
  (apply wrap
         (lambda (r)
           (let ((bytes (get-bytevector-all (req-body r))))
             (make-res 200 '() (if (eof-object? bytes) (make-bytevector 0) bytes))))
         middlewares))

;; chunked-post : String String ... -> String — a POST of PIECES, chunked.
(define (chunked-post path . pieces)
  (string-append "POST " path " HTTP/1.1\r\nHost: x\r\n" chunked "\r\n\r\n" (apply chunks pieces)))

;; echoed : String -> (List (Listof String) Boolean (Listof Any)) — BODY answered.
(define (echoed body)
  (list (list (response "200 OK" (list (length-field (string-length body))) body)) #f '()))

;; The exchange of a body past a cap, which the app lets out.
(define too-large
  (list (list (response "413 Content Too Large" '("Content-Length: 0" "Connection: close") ""))
        #t
        '((handler-failed (body-failed 413 body-too-large)))))

(test-equal "the request's cap reaches the server's port: a body at it is read, one past it refused 413, declared or chunked"
  (list (echoed "abcd") too-large too-large (echoed "abcd"))
  (let ((app (capped-echo (wrap-body-cap 4))))
    (let* ((at (exchange app (post "/up" "abcd")))
           (declared (exchange app (post "/up" "abcde")))
           (sent-chunked (exchange app (chunked-post "/up" "abc" "de")))
           (at-chunked (exchange app (chunked-post "/up" "ab" "cd"))))
      (list at declared sent-chunked at-chunked))))

(test-equal "a cap of 0 takes an empty body and refuses a byte"
  (list (echoed "") too-large)
  (let ((app (capped-echo (wrap-body-cap 0))))
    (let* ((empty (exchange app (post "/up" "")))
           (one (exchange app (post "/up" "a"))))
      (list empty one))))

(test-equal "Expect: 100-continue with a declared body past the request's cap: the first read refuses it, with no 100 Continue"
  too-large
  (exchange (capped-echo (wrap-body-cap 4))
            "POST /up HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"))

(test-equal "the innermost cap wins: one inside lifts the cap outside it, #f to the server's alone, and one inside lowers it"
  (list (echoed "abcdefgh") (echoed "abcdefgh") too-large)
  (let* ((lifted (exchange (capped-echo (wrap-body-cap 10) (wrap-body-cap 4)) (post "/up" "abcdefgh")))
         (lifted-to-the-server (exchange (capped-echo (wrap-body-cap #f) (wrap-body-cap 4))
                                         (post "/up" "abcdefgh")))
         (lowered (exchange (capped-echo (wrap-body-cap 4) (wrap-body-cap 10)) (post "/up" "abcdefgh"))))
    (list lifted lifted-to-the-server lowered)))

(test-equal "req-body: a with-deadline around a read raises &deadline-passed, which the app answers"
  (list '() (list (response "504 Gateway Timeout" (list (length-field 4) "Connection: close") "late")) '())
  (let* ((host (host-of (lambda (r)
                          (guard (e ((deadline-passed? e) (make-res 504 '() "late")))
                            (with-deadline 100 (lambda () (make-res 200 '() (get-bytevector-all (req-body r)))))))
                        unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhe"))
    (let ((first (wire c)))
      (test-host-advance! host 100)
      (list first (wire c) (logged host)))))

;; The long poll's shape, as examples/long-poll.sps has it: an app that
;; awaits inside a 30 s with-deadline and answers 504 when &deadline-passed
;; reaches it, forgetting its waiter.
(test-equal "a long poll: an await inside with-deadline 30000 is answered 504 at 30,000 ms, its waiter forgotten"
  (list 1 '()
        (list (response-at "00:00:30" "504 Gateway Timeout"
                           (list "content-type: text/plain" (length-field 16)) "no message came\n"))
        0 '())
  (let* ((waiting '())
         (app (lambda (r)
                (let ((mine #f))
                  (guard (e ((deadline-passed? e)
                             (set! waiting (remq mine waiting))
                             (make-res 504 '(("content-type" . "text/plain")) "no message came\n")))
                    (with-deadline 30000
                      (lambda ()
                        (make-res 200 '()
                                  (await (lambda (resume)
                                           (set! mine resume)
                                           (set! waiting (cons resume waiting)))))))))))
         (host (host-of app unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (get "/wait")))
    (let ((parked (length waiting)))
      (test-host-advance! host 29999)
      (let ((before (wire c)))
        (test-host-advance! host 1)
        (list parked before (wire c) (length waiting) (logged host))))))

(test-equal "req-body: one port for every copy of the request, each reading on from the other"
  '(#t #t "he" "llo")
  (let ((seen 'app-not-called))
    (exchange (lambda (r)
                (let* ((copy (req-set r key 'value))
                       (other (req-with-path r "/elsewhere"))
                       (start (get-bytevector-n (req-body copy) 2))
                       (rest (get-bytevector-all (req-body other))))
                  (set! seen (list (eq? (req-body r) (req-body copy)) (eq? (req-body r) (req-body other))
                                   (utf8->string start) (utf8->string rest)))
                  (ok-app r)))
              (post "/up" "hello"))
    seen))

;;; --- req-on-done! ---------------------------------------------------------

;; ended : (Req -> Res) (TestHost TestClient -> Any) -> (List (Listof Symbol) Any)
;; The endings a procedure APP registers is called with, and what the
;; exchange gave, after STEPS acted on the host and its client.
(define (ended app steps)
  (let* ((endings '())
         (host (host-of (lambda (r)
                          (req-on-done! r (lambda (ending) (set! endings (cons ending endings))))
                          (app r))
                        unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (get "/done")))
    (steps host c)
    (list endings (list (wire c) (test-client-connection-closed? c) (logged host)))))

(test-equal "req-on-done! reaches the server: written"
  (list '(written) (list (list (response "200 OK" (list (length-field 2)) "ok")) #f '()))
  (ended ok-app (lambda (host c) #f)))

(test-equal "req-on-done! reaches the server: client-closed, the client leaving while the app waits"
  (list '(client-closed) (list '() #t '()))
  (ended (lambda (r) (sleep-ms 10) (ok-app r)) (lambda (host c) (test-client-close! c))))

(test-equal "req-on-done! reaches the server: failed, the app raising"
  (list '(failed)
        (list (list server-error) #t '((handler-failed (assertion app "refused" (7))))))
  (ended (lambda (r) (assertion-violation 'app "refused" 7)) (lambda (host c) #f)))

;;; --- each body kind's wire form -------------------------------------------

(test-equal "a #f body goes out empty, with its length"
  (list (list (response "200 OK" (list "x-kind: none" (length-field 0)) "")) #f '())
  (exchange (lambda (r) (make-res 200 '(("x-kind" . "none")) #f)) (get "/")))

(test-equal "a bytevector goes out as it is, with its length"
  (list (list (response "201 Created" (list (length-field 5)) (text #vu8(0 1 2 255 254)))) #f '())
  (exchange (lambda (r) (make-res 201 '() #vu8(0 1 2 255 254))) (get "/")))

(test-equal "a string goes out as its UTF-8 bytes, with their length"
  (list (list (response "200 OK" (list (length-field 22)) (utf8-text "héllo, wörld ✓\x1F600;"))) #f '())
  (exchange (lambda (r) (make-res 200 '() "héllo, wörld ✓\x1F600;")) (get "/")))

(test-equal "a producer goes out chunked, a chunk a piece"
  (list (list (response "200 OK" (list chunked) (chunks "ab" "cde" "f"))) #f '())
  (exchange (lambda (r) (make-res 200 '() (producer "ab" "cde" "f"))) (get "/")))

(test-equal "a producer that waits goes out a piece at each wait's end"
  (let ((top (response "200 OK" (list chunked) "")))
    (list top
          (string-append top "2\r\nab\r\n")
          (string-append top "2\r\nab\r\n3\r\ncde\r\n")
          (string-append top "2\r\nab\r\n3\r\ncde\r\n0\r\n\r\n")))
  (let* ((inner (producer "ab" "cde"))
         (host (host-of (lambda (r) (make-res 200 '() (lambda () (sleep-ms 10) (inner)))) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (get "/")))
    (let* ((at-0 (received c))
           (at-10 (begin (test-host-advance! host 10) (received c)))
           (at-20 (begin (test-host-advance! host 10) (received c)))
           (at-30 (begin (test-host-advance! host 10) (received c))))
      (list at-0 at-10 at-20 at-30))))

(test-equal "headers go out as given, in order, each character one Latin-1 byte"
  (list (list (response "200 OK" (list "x-b: 1" "X-A: café ÿ" "x-b: 2" (length-field 2)) "ok")) #f '())
  (exchange (lambda (r) (make-res 200 '(("x-b" . "1") ("X-A" . "café ÿ") ("x-b" . "2")) "ok")) (get "/")))

(test-equal "the status passes through: the server, not the adapter, refuses a 1xx and a content-length"
  (list (list (list (response "500 Internal Server Error" '("Content-Length: 0" "Connection: close") "")) #t
              '((invalid-response invalid-status)))
        (list (list (response "500 Internal Server Error" '("Content-Length: 0" "Connection: close") "")) #t
              '((invalid-response framing-field))))
  (list (exchange (lambda (r) (make-res 102 '() #f)) (get "/"))
        (exchange (lambda (r) (make-res 200 '(("content-length" . "2")) "ok")) (get "/"))))

;;; --- port bodies ------------------------------------------------------------

;; In pieces of 4 these ports stream, sized by the measure, so a measure
;; that ignores the position sends a length the port doesn't hold; in the
;; default pieces each is read whole, and goes out at the count read.
(define piece-of-4 (settings piece-variable "4"))

(test-equal "a bytevector port goes out with its length, from its position, and is closed: streamed, and read whole"
  (let ((sent (list (list (list (response "200 OK" (list (length-field 7)) "3456789")) #f '()) #t)))
    (list sent sent))
  (map (lambda (env)
         (let* ((port (positioned "0123456789" 3))
                (result (exchange (lambda (r) (make-res 200 '() port)) (get "/") env)))
           (list result (port-closed? port))))
       (list piece-of-4 unset)))

(test-equal "a file goes out with its length, from its position, and is closed: streamed, and read whole"
  (let ((sent (list (list (list (response "200 OK" (list (length-field 7)) "fghijkl")) #f '()) #t)))
    (list sent sent))
  (map (lambda (env)
         (call-with-temp-directory
          (lambda (dir)
            (let ((path (string-append dir "/twelve")) (port #f))
              (write-file path "abcdefghijkl")
              (let ((result (exchange (lambda (r)
                                        (set! port (open-file-input-port path))
                                        (get-bytevector-n port 5)
                                        (make-res 200 '() port))
                                      (get "/")
                                      env)))
                (list result (port-closed? port)))))))
       (list piece-of-4 unset)))

(test-equal "a file whose position is past its length goes out with length 0, and is closed, in pieces smaller than the file and in the default"
  (let ((sent (list (list (list (response "200 OK" (list (length-field 0)) "")) #f '()) #t)))
    (list sent sent))
  (map (lambda (env)
         (call-with-temp-directory
          (lambda (dir)
            (let ((path (string-append dir "/ten")) (port #f))
              (write-file path "abcdefghij")
              (let ((result (exchange (lambda (r)
                                        (set! port (open-file-input-port path))
                                        (set-port-position! port 20)
                                        (make-res 200 '() port))
                                      (get "/")
                                      env)))
                (list result (port-closed? port)))))))
       (list piece-of-4 unset)))

(test-equal "a custom port with a position but no length goes out chunked, and is closed"
  (list (list (list (response "200 OK" (list chunked) (chunks "hello"))) #f '()) #t)
  (let* ((port (positioned-custom-port "hello"))
         (result (exchange (lambda (r) (make-res 200 '() port)) (get "/"))))
    (list result (port-closed? port))))

(test-equal "a custom port, with no length, goes out chunked in pieces of the piece size, and is closed"
  (list (list (list (response "200 OK" (list chunked) (chunks "abcd" "efgh" "ij"))) #f '()) #t)
  (let* ((port (custom-port "abcdefghij"))
         (result (exchange (lambda (r) (make-res 200 '() port)) (get "/")
                           (settings piece-variable "4"))))
    (list result (port-closed? port))))

;; closes : (BinaryInputPort -> Body) Nat String -> (List Any Boolean)
;; A port over "hello" answered as (WRAP port) with STATUS to REQUEST, in
;; pieces of 4, so it is more than one piece and streams: the exchange, and
;; whether the port was closed.
(define (closes wrap status request)
  (let* ((port (open-bytevector-input-port (b "hello")))
         (result (exchange (lambda (r) (make-res status '() (wrap port))) request
                           (settings piece-variable "4"))))
    (list result (port-closed? port))))

(define (bare port) port)
(define (quiet piece) 'ignored)
(define (tapped port) (res-body (res-tap-body (make-res 200 '() port) quiet)))
(define (wrapped port) (res-body (res-wrap-body (make-res 200 '() port) as-is)))

(test-equal "a port of more than one piece answered to a HEAD is never read, and is closed: bare, and tapped"
  (let ((sent (list (list (list (response "200 OK" (list (length-field 5)) "")) #f '()) #t)))
    (list sent sent))
  (list (closes bare 200 (head "/")) (closes tapped 200 (head "/"))))

(test-equal "a port of more than one piece answered 204 is never read, and is closed: bare, tapped and wrapped"
  (let ((sent (list (list (list (response "204 No Content" '() "")) #f '()) #t)))
    (list sent sent sent))
  (list (closes bare 204 (get "/")) (closes tapped 204 (get "/")) (closes wrapped 204 (get "/"))))

(test-equal "a port of more than one piece answered 304 is never read, and is closed: bare, tapped and wrapped"
  (let ((sent (list (list (list (response "304 Not Modified" '() "")) #f '()) #t)))
    (list sent sent sent))
  (list (closes bare 304 (get "/")) (closes tapped 304 (get "/")) (closes wrapped 304 (get "/"))))

;; The adapter's request-on-done! close covers a port sent whole too, so this
;; row holds that it is closed once sent; the core's suites hold the close
;; at its last byte.
(test-equal "a port of more than one piece is closed once it is sent: bare, tapped and wrapped"
  (list (list (list (list (response "200 OK" (list (length-field 5)) "hello")) #f '()) #t)
        (list (list (list (response "200 OK" (list (length-field 5)) "hello")) #f '()) #t)
        (list (list (list (response "200 OK" (list chunked) (chunks "hell" "o"))) #f '()) #t))
  (list (closes bare 200 (get "/")) (closes tapped 200 (get "/")) (closes wrapped 200 (get "/"))))

;; seen-by-another : (BinaryInputPort -> Body) String Nat (U String #f)
;;                   -> (List (Listof String) Boolean Boolean)
;; A port over "hello" answered as (WRAP port) with STATUS to a METHOD
;; request, in pieces of PIECE (the default when #f), the app waking at
;; 10 ms; another client's app, woken at the same instant, runs once that
;; app has answered and before anything the server does later, a producer's
;; piece or a request-on-done! procedure: the first client's responses,
;; whether the other app saw the port closed, and whether it is closed after.
(define (seen-by-another wrap method status piece)
  (let* ((port (open-bytevector-input-port (b "hello")))
         (seen 'other-app-not-called)
         (env (if piece (settings piece-variable piece) unset))
         (host (host-of (lambda (r)
                          (sleep-ms 10)
                          (if (string=? (req-path r) "/port")
                              (make-res status '() (wrap port))
                              (begin (set! seen (port-closed? port)) (make-res 200 '() "other"))))
                        env))
         (first (test-host-connect! host))
         (other (test-host-connect! host)))
    (test-client-send! first (b (string-append method " /port HTTP/1.1\r\nHost: x\r\n\r\n")))
    (test-client-send! other (b (get "/other")))
    (test-host-advance! host 10)
    (list (wire first) seen (port-closed? port))))

(test-equal "a port of one piece is read whole as the app answers, closed before anything after; one byte more streams, open then"
  (let ((hello (list (response "200 OK" (list (length-field 5)) "hello"))))
    (list (list hello #t #t) (list hello #f #t)))
  (list (seen-by-another bare "GET" 200 "5") (seen-by-another bare "GET" 200 "4")))

(test-equal "a port of one piece answered to a HEAD, 204 or 304 is read whole and closed as the app answers: nothing is left to close"
  (list (list (list (response "200 OK" (list (length-field 5)) "")) #t #t)
        (list (list (response "204 No Content" '() "")) #t #t)
        (list (list (response "304 Not Modified" '() "")) #t #t))
  (list (seen-by-another bare "HEAD" 200 #f) (seen-by-another bare "GET" 204 #f)
        (seen-by-another bare "GET" 304 #f)))

(test-equal "a sized port of one piece still streams: open as the app answers, closed once sent"
  (list (list (response "200 OK" (list (length-field 5)) "hello")) #f #t)
  (seen-by-another (lambda (port) (make-sized-body 5 port)) "GET" 200 #f))

(test-equal "a port of one piece, tapped or wrapped, is read whole and closed as the app answers"
  (list (list (list (response "200 OK" (list (length-field 5)) "hello")) #t #t)
        (list (list (response "200 OK" (list chunked) (chunks "hello"))) #t #t))
  (list (seen-by-another tapped "GET" 200 #f) (seen-by-another wrapped "GET" 200 #f)))

;; left-mid-stream : (BinaryInputPort -> Body) -> (List String Boolean (Listof Symbol) (Listof Any))
;; A port that waits 10 ms before each read, in pieces of 4, answered as
;; (WRAP port); the client resets after the first piece: what it read by
;; then, whether the port was closed, the endings, and the log.
(define (left-mid-stream wrap)
  (let* ((endings '())
         (port (waiting-port "abcdefghijkl" 10))
         (host (host-of (lambda (r)
                          (req-on-done! r (lambda (ending) (set! endings (cons ending endings))))
                          (make-res 200 '() (wrap port)))
                        (settings piece-variable "4")))
         (c (test-host-connect! host)))
    (test-client-send! c (b (get "/stream")))
    (test-host-advance! host 10)
    (let ((read (received c)))
      (test-client-reset! c)
      (list read (port-closed? port) endings (logged host)))))

(test-equal "a port is closed when the client leaves mid-stream: bare, tapped and wrapped"
  (let ((left (list (string-append (response "200 OK" (list chunked) "") "4\r\nabcd\r\n")
                    #t '(client-closed) '((read-error ECONNRESET)))))
    (list left left left))
  (list (left-mid-stream bare) (left-mid-stream tapped) (left-mid-stream wrapped)))

;; rewritten : String (U String #f) -> (List (Listof String) Boolean (Listof String) (Listof Any) Boolean)
;; A file of 10 bytes answered to one client in pieces of PIECE (the
;; default when #f), measured, then rewritten to hold NEW by another
;; client's app before the first's producer runs: the first client's
;; responses and whether its connection ended, the other's responses, the
;; log, and whether the port was closed. Both apps wake at 10 ms, the
;; file's first, so the other runs after it has answered and before its
;; producer does.
(define (rewritten new piece)
  (call-with-temp-directory
   (lambda (dir)
     (let* ((path (string-append dir "/ten"))
            (port #f)
            (host (host-of (lambda (r)
                             (sleep-ms 10)
                             (if (string=? (req-path r) "/file")
                                 (begin (set! port (open-file-input-port path))
                                        (make-res 200 '() port))
                                 (begin (write-file path new)
                                        (make-res 200 '() "rewritten"))))
                           (if piece (settings piece-variable piece) unset)))
            (file-client (test-host-connect! host))
            (other-client (test-host-connect! host)))
       (write-file path "abcdefghij")
       (test-client-send! file-client (b (get "/file")))
       (test-client-send! other-client (b (get "/rewrite")))
       (test-host-advance! host 10)
       (list (wire file-client) (test-client-connection-closed? file-client)
             (wire other-client) (logged host) (port-closed? port))))))

(test-equal "a file of more than one piece that shrinks after it is measured ends short, and the server logs the mismatch"
  (list (list (response "200 OK" (list (length-field 10)) "abcde")) #t
        (list (response "200 OK" (list (length-field 9)) "rewritten"))
        '((body-length-mismatch 10 5))
        #t)
  (rewritten "abcde" "4"))

(test-equal "a file of more than one piece that grows after it is measured goes out as long as it was"
  (list (list (response "200 OK" (list (length-field 10)) "ABCDEFGHIJ")) #f
        (list (response "200 OK" (list (length-field 9)) "rewritten"))
        '()
        #t)
  (rewritten "ABCDEFGHIJKLMNOPQRST" "4"))

(test-equal "a file of one piece is read whole as the app answers: rewriting it after changes nothing"
  (let ((rest (list (list (response "200 OK" (list (length-field 9)) "rewritten")) '() #t)))
    (list (append (list (list (response "200 OK" (list (length-field 10)) "abcdefghij")) #f) rest)
          (append (list (list (response "200 OK" (list (length-field 10)) "abcdefghij")) #f) rest)))
  (list (rewritten "abcde" #f) (rewritten "ABCDEFGHIJKLMNOPQRST" #f)))

(test-equal "a measure that raises, a FIFO's position, answers 500 with the port closed"
  (list 0 (list server-error) #t '(handler-failed) 'port-position #t)
  (call-with-temp-directory
   (lambda (dir)
     (let* ((path (string-append dir "/fifo"))
            (made (capture-command (list "mkfifo" path)))
            (writer (open-file-input/output-port path (file-options no-create no-truncate)))
            (reader (open-file-input-port path)))
       ;; The writer closes once its bytes are in, so a read of the FIFO
       ;; ends at eof rather than waiting for a writer.
       (put-bytevector writer (b "hi"))
       (flush-output-port writer)
       (close-port writer)
       (let* ((result (exchange (lambda (r) (make-res 200 '() reader)) (get "/fifo")))
              (log (caddr result)))
         (list (car made) (car result) (cadr result) (map car log)
               (cadr (cadr (car log))) (port-closed? reader)))))))

;;; --- sized bodies -------------------------------------------------------------

(test-equal "a sized producer goes out with its length"
  (list (list (response "200 OK" (list (length-field 5)) "abcde")) #f '())
  (exchange (lambda (r) (make-res 200 '() (make-sized-body 5 (producer "ab" "cde")))) (get "/")))

(test-equal "a sized port goes out with its length, read no further, and is closed"
  (list (list (list (response "200 OK" (list (length-field 4)) "abcd")) #f '()) #t)
  (let* ((port (custom-port "abcdefghij"))
         (result (exchange (lambda (r) (make-res 200 '() (make-sized-body 4 port))) (get "/"))))
    (list result (port-closed? port))))

(test-equal "a sized producer that runs long is cut at its length, and the server logs the mismatch"
  (list (list (response "200 OK" (list (length-field 4)) "ab")) #t '((body-length-mismatch 4 5)))
  (exchange (lambda (r) (make-res 200 '() (make-sized-body 4 (producer "ab" "cde")))) (get "/")))

(test-equal "a sized producer that ends short ends there, and the server logs the mismatch"
  (list (list (response "200 OK" (list (length-field 9)) "abcde")) #t '((body-length-mismatch 9 5)))
  (exchange (lambda (r) (make-res 200 '() (make-sized-body 9 (producer "ab" "cde")))) (get "/")))

;;; --- wraps --------------------------------------------------------------------

(test-equal "a tap over a port goes out sized, each piece handed to on-piece as it is, and the port is closed"
  (list (list (list (response "200 OK" (list (length-field 11)) "hello world")) #f '())
        '("hell" "o wo" "rld")
        #t)
  (let* ((port (open-bytevector-input-port (b "hello world")))
         (seen '())
         (result (exchange (lambda (r) (res-tap-body (make-res 200 '() port)
                                                     (lambda (piece) (set! seen (cons (text piece) seen)))))
                           (get "/")
                           (settings piece-variable "4"))))
    (list result (reverse seen) (port-closed? port))))

(test-equal "a tap over a port of more than one piece, answered to a HEAD, a 204 or a 304, hands on-piece nothing"
  '(() () ())
  (map (lambda (status request)
         (let ((seen '()))
           (closes (lambda (port)
                     (res-body (res-tap-body (make-res 200 '() port)
                                             (lambda (piece) (set! seen (cons (text piece) seen))))))
                   status request)
           seen))
       (list 200 204 304)
       (list (head "/") (get "/") (get "/"))))

(test-equal "a raise from on-piece after the head closes the connection, logged handler-failed, and the port is closed"
  (list (list (list (response "200 OK" (list (length-field 11)) "hell")) #t
              '((handler-failed (assertion my-tap "refused" (2)))))
        #t)
  (let* ((port (open-bytevector-input-port (b "hello world")))
         (count 0)
         (result (exchange (lambda (r)
                             (res-tap-body (make-res 200 '() port)
                                           (lambda (piece)
                                             (set! count (+ count 1))
                                             (when (= count 2) (assertion-violation 'my-tap "refused" count)))))
                           (get "/")
                           (settings piece-variable "4"))))
    (list result (port-closed? port))))

(test-equal "a tap over a sized producer that runs past its length: on-piece sees only what goes out, and the raise closes the connection"
  (list (list (list (response "200 OK" (list (length-field 5)) "abc")) #t
              '((handler-failed (assertion res-body-stream "a piece takes the body past the length it had" (5 7)))))
        '("abc"))
  (let* ((seen '())
         (result (exchange (lambda (r)
                             (res-tap-body (make-res 200 '() (make-sized-body 5 (producer "abc" "defg")))
                                           (lambda (piece) (set! seen (cons (text piece) seen)))))
                           (get "/"))))
    (list result (reverse seen))))

(test-equal "a wrap over a port goes out chunked, and the port is closed"
  (list (list (list (response "200 OK" (list chunked) (chunks "HELL" "O WO" "RLD"))) #f '()) #t)
  (let* ((port (open-bytevector-input-port (b "hello world")))
         (result (exchange (lambda (r) (res-wrap-body (make-res 200 '() port) upcased)) (get "/")
                           (settings piece-variable "4"))))
    (list result (port-closed? port))))

(test-equal "a wrap goes out chunked, and stops at the length of the body under it, never asking past it"
  (list (list (list (response "200 OK" (list chunked) (chunks "abc" "de"))) #f '()) 2)
  (let* ((asked 0)
         (inner (producer "abc" "de" "XYZ"))
         (counted (lambda () (set! asked (+ asked 1)) (inner)))
         (result (exchange (lambda (r) (res-wrap-body (make-res 200 '() (make-sized-body 5 counted)) as-is))
                           (get "/"))))
    (list result asked)))

(test-equal "an empty body reaches f as eof: #f, an empty string and an empty port, the port closed"
  (let ((sent (list (list (response "200 OK" (list chunked) (chunks "END"))) #f '())))
    (list sent sent (list sent #t)))
  (let ((port (open-bytevector-input-port #vu8())))
    (list (exchange (lambda (r) (res-wrap-body (make-res 200 '() #f) (trailer "END"))) (get "/"))
          (exchange (lambda (r) (res-wrap-body (make-res 200 '() "") (trailer "END"))) (get "/"))
          (let ((result (exchange (lambda (r) (res-wrap-body (make-res 200 '() port) (trailer "END")))
                                  (get "/"))))
            (list result (port-closed? port))))))

(test-equal "a wrap's f may wait: it runs on the request's coroutine"
  (list '() (list (response "200 OK" (list chunked) (chunks "HELLO"))) '())
  (let* ((host (host-of (lambda (r)
                          (res-wrap-body (make-res 200 '() "hello")
                                         (lambda (inner) (sleep-ms 20) (upcased inner))))
                        unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (get "/")))
    (let ((first (wire c)))
      (test-host-advance! host 20)
      (list first (wire c) (logged host)))))

(test-equal "a tap's on-piece may wait: each piece goes out once it returns, the end at once"
  (let ((top (response "200 OK" (list chunked) "")))
    (list top
          (string-append top "2\r\nab\r\n")
          (string-append top "2\r\nab\r\n3\r\ncde\r\n0\r\n\r\n")))
  (let* ((host (host-of (lambda (r)
                          (res-tap-body (make-res 200 '() (producer "ab" "cde"))
                                        (lambda (piece) (sleep-ms 10))))
                        unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (get "/")))
    (let* ((at-0 (received c))
           (at-10 (begin (test-host-advance! host 10) (received c)))
           (at-20 (begin (test-host-advance! host 10) (received c))))
      (list at-0 at-10 at-20))))

(test-equal "a wrap's f that raises gives a 500, and the port under it is still closed: of more than one piece, and of one"
  (let ((failed (list (list (list server-error) #t '((handler-failed (assertion my-wrap "refused" (7))))) #t)))
    (list failed failed))
  (map (lambda (env)
         (let* ((port (open-bytevector-input-port (b "hello")))
                (result (exchange (lambda (r)
                                    (res-wrap-body (make-res 200 '() port)
                                                   (lambda (inner) (assertion-violation 'my-wrap "refused" 7))))
                                  (get "/")
                                  env)))
           (list result (port-closed? port))))
       (list (settings piece-variable "4") unset)))

;;; --- a client that leaves while the app waits ----------------------------------

(test-equal "the client leaves while the app waits, and the app answers a port body: the port is closed, nothing else goes wrong, of more than one piece and of one"
  (let ((left (list '() #t #t '(client-closed) '((read-error ECONNRESET)))))
    (list left left))
  (map (lambda (env)
         (let* ((endings '())
                (port (open-bytevector-input-port (b "hello")))
                (host (host-of (lambda (r)
                                 (req-on-done! r (lambda (ending) (set! endings (cons ending endings))))
                                 (guard (e ((client-closed? e) 'left))
                                   (sleep-ms 10))
                                 (make-res 200 '() port))
                               env))
                (c (test-host-connect! host)))
           (test-client-send! c (b (get "/")))
           (test-client-reset! c)
           (test-host-advance! host 10)
           (list (wire c) (test-client-connection-closed? c) (port-closed? port) endings (logged host))))
       (list (settings piece-variable "4") unset)))

;;; --- upgrades -------------------------------------------------------------------

(define upgrade-request "GET /chat HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: echo\r\n\r\n")

;; switching : (Listof String) -> String
;; The 101 as the server writes it: FIELDS, then its own Connection:
;; upgrade. A 1xx carries no Date.
(define (switching fields)
  (string-append "HTTP/1.1 101 Switching Protocols\r\n"
                 (apply string-append (map (lambda (f) (string-append f "\r\n")) fields))
                 "Connection: upgrade\r\n\r\n"))

;; subbytes : Bytevector Nat Nat -> Bytevector — BV from START to END.
(define (subbytes bv start end)
  (let ((out (make-bytevector (- end start))))
    (bytevector-copy! bv start out 0 (- end start))
    out))

;; noting-taker : (Any -> Void) -> (Transport Bytevector -> Any)
;; A take-over that notes the bytes read past the request, writes hello,
;; then notes each read and writes it back, and at the read's end notes why
;; and closes.
(define (noting-taker note)
  (lambda (t retained)
    (note (list 'retained (text retained)))
    (transport-write! t (b "hello"))
    (transport-read-start! t
                           (lambda (bv start end)
                             (let ((bytes (subbytes bv start end)))
                               (note (list 'read (text bytes)))
                               (transport-write! t bytes)))
                           (lambda (why) (note (list 'end why)) (transport-close! t)))))

;; upgraded : ((Transport Bytevector -> Any) (Any -> Void) -> (Req -> Res)) String (Listof String)
;;            -> (List String String (Listof Any) Boolean (Listof Any))
;; The app MAKE-APP makes around a noting taker and its note procedure, a
;; client sending REQUEST: every byte it read; every byte once it has sent
;; each of AFTER; the notes, the taker's and any MAKE-APP's app made; and
;; once the client closes, whether the connection ended, and the log.
(define (upgraded make-app request after)
  (let* ((notes '())
         (note (lambda (x) (set! notes (cons x notes))))
         (host (host-of (make-app (noting-taker note) note) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b request))
    (let ((first (received c)))
      (for-each (lambda (bytes) (test-client-send! c (b bytes))) after)
      (let ((second (received c)))
        (test-client-close! c)
        (list first second (reverse notes) (test-client-connection-closed? c) (logged host))))))

(define (echo-upgrade taker)
  (lambda (r) (make-upgrade-res '(("Upgrade" . "echo") ("x-app" . "yes")) taker)))

;; echo-only : (Transport Bytevector -> Any) (Any -> Void) -> (Req -> Res)
(define (echo-only taker note) (echo-upgrade taker))

(test-equal "an upgrade: the 101, the app's fields then the server's Connection: upgrade, then the taker's bytes; the taker is handed the bytes read past the request, then what the client sends"
  (let ((head (string-append (switching '("Upgrade: echo" "x-app: yes")) "hello")))
    (list (list head (string-append head "pingpong") '((retained "") (read "ping") (read "pong") (end eof))
                #t '())
          (list head (string-append head "ping") '((retained "early") (read "ping") (end eof)) #t '())))
  (list (upgraded echo-only upgrade-request '("ping" "pong"))
        (upgraded echo-only (string-append upgrade-request "early") '("ping"))))

(test-equal "an upgrade whose taker answers awaiting: its thunk runs on a coroutine of its own, where it waits"
  (let ((head (switching '("Upgrade: echo"))))
    (list head head (string-append head "late") #t '()))
  (let* ((host (host-of (lambda (r)
                          (make-upgrade-res '(("Upgrade" . "echo"))
                                            (lambda (t retained)
                                              (awaiting (lambda ()
                                                          (sleep-ms 50)
                                                          (transport-write! t (b "late"))
                                                          (transport-close! t))))))
                        unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b upgrade-request))
    (let ((at-0 (received c)))
      (test-host-advance! host 49)
      (let ((at-49 (received c)))
        (test-host-advance! host 1)
        (let ((at-50 (received c)))
          (test-client-close! c)
          (list at-0 at-49 at-50 (test-client-connection-closed? c) (logged host)))))))

(test-equal "an upgrade carries the field a middleware adds, before the server's Connection: upgrade"
  (let ((head (string-append (switching '("Upgrade: echo" "x-app: yes" "server: circuit")) "hello")))
    (list head (string-append head "ping") '((retained "") (read "ping") (end eof)) #t '()))
  (upgraded (lambda (taker note)
              (wrap (echo-upgrade taker)
                    (lambda (handler) (lambda (r) (res-add-header (handler r) "server" "circuit")))))
            upgrade-request '("ping")))

(test-equal "an upgrade loses the fields a middleware removes, every one of the name, in any case"
  (let ((head (string-append (switching '("Upgrade: echo" "x-app: yes")) "hello")))
    (list head (string-append head "ping") '((retained "") (read "ping") (end eof)) #t '()))
  (upgraded (lambda (taker note)
              (wrap (lambda (r)
                      (make-upgrade-res '(("Upgrade" . "echo") ("X-Secret" . "1") ("x-app" . "yes")
                                          ("x-secret" . "2"))
                                        taker))
                    (lambda (handler) (lambda (r) (res-remove-header (handler r) "x-SECRET")))))
            upgrade-request '("ping")))

;; The middleware makes a new upgrade from the one its handler answers:
;; its headers, and a take-over that notes, then hands on to the old one.
(test-equal "a middleware that wraps the take-over: its own note first, then the inner taker, handed the bytes read past the request"
  (let ((head (string-append (switching '("Upgrade: echo" "x-app: yes")) "hello")))
    (list head (string-append head "ping")
          '((outer "early" #t) (retained "early") (read "ping") (end eof)) #t '()))
  (upgraded (lambda (taker note)
              (wrap (echo-upgrade taker)
                    (lambda (handler)
                      (lambda (r)
                        (let* ((answer (handler r))
                               (inner (res-upgrade-body-take-over (res-body answer))))
                          (make-upgrade-res (res-headers answer)
                                            (lambda (t retained)
                                              (note (list 'outer (text retained) (transport? t)))
                                              (inner t retained))))))))
            (string-append upgrade-request "early") '("ping")))

(test-equal "an app that made its req-body, then answers an upgrade, still switches: an upgrade body holds no port"
  (let ((head (string-append (switching '("Upgrade: echo" "x-app: yes")) "hello")))
    (list (list head (string-append head "ping") '((retained "") (read "ping") (end eof)) #t '()) #t))
  (let* ((made #f)
         (result (upgraded (lambda (taker note)
                             (lambda (r)
                               (req-body r)
                               (set! made (and (req-body-made r) #t))
                               ((echo-upgrade taker) r)))
                           upgrade-request '("ping"))))
    (list result made)))

(test-equal "an upgrade with a header character above 255 is refused: a 500 before the head, logged handler-failed, the taker never called"
  (list (refused not-latin-1 '("λ")) '())
  (let* ((called '())
         (result (exchange (lambda (r)
                             (make-upgrade-res '(("Upgrade" . "echo") ("x-wide" . "λ"))
                                               (lambda (t retained) (set! called (cons 'taker called)))))
                           upgrade-request)))
    (list result called)))

(test-equal "a 101 that make-res made, answered to an upgrade request, is no upgrade: the server's 500, logged invalid-response invalid-status"
  (list (list server-error) #t '((invalid-response invalid-status)))
  (exchange (lambda (r) (make-res 101 '() "text")) upgrade-request))

(test-equal "an upgrade answered to a request that asked for none: the server's 500, logged invalid-response not-an-upgrade, the taker never called"
  (list (list (list server-error) #t '((invalid-response not-an-upgrade))) '())
  (let* ((called '())
         (result (exchange (lambda (r)
                             (make-upgrade-res '(("Upgrade" . "echo"))
                                               (lambda (t retained) (set! called (cons 'taker called)))))
                           (get "/chat"))))
    (list result called)))

;;; --- refusals: each a 500 before the head, logged handler-failed ---------------

(test-equal "an app that answers no res is refused, the value named"
  (refused not-a-res '(42))
  (exchange (lambda (r) 42) (get "/")))

(test-equal "an app that answers a server response is refused: it is no res"
  #t
  (let* ((theirs (make-response 200 #f '() #f))
         (result (exchange (lambda (r) theirs) (get "/"))))
    (equal? result (refused not-a-res (list theirs)))))

(test-equal "the request's own req-body as the body is refused: bare"
  #t
  (let* ((own #f)
         (result (exchange (lambda (r) (set! own (req-body r)) (make-res 200 '() own)) (post "/" "hello"))))
    (equal? result (refused echo (list own)))))

(test-equal "the request's own req-body as the body is refused: under make-sized-body, through a copy"
  #t
  (let* ((own #f)
         (result (exchange (lambda (r)
                             (set! own (req-body (req-set r key 'value)))
                             (make-res 200 '() (make-sized-body 5 own)))
                           (post "/" "hello"))))
    (equal? result (refused echo (list own)))))

(test-equal "the request's own req-body as the body is refused: under a wrap and a tap over a sized body, no f or on-piece called"
  (list #t 0)
  (let* ((own #f)
         (calls 0)
         (f (lambda (inner) (set! calls (+ calls 1)) inner))
         (on-piece (lambda (piece) (set! calls (+ calls 1))))
         (result (exchange (lambda (r)
                             (set! own (req-body r))
                             (res-wrap-body (res-tap-body (make-res 200 '() (make-sized-body 5 own)) on-piece) f))
                           (post "/" "hello"))))
    (list (equal? result (refused echo (list own))) calls)))

(test-equal "a header character above 255 is refused, 256 the first, and a port body is still closed, of more than one piece and of one"
  (list (list (refused not-latin-1 '("λ")) #t)
        (list (refused not-latin-1 '("\x100;")) #t)
        (list (refused not-latin-1 '("λ")) #t))
  (map (lambda (value env)
         (let* ((port (open-bytevector-input-port (b "hello")))
                (result (exchange (lambda (r) (make-res 200 (list '("x-ok" . "fine") (cons "x-wide" value)) port))
                                  (get "/")
                                  env)))
           (list result (port-closed? port))))
       '("λ" "\x100;" "λ")
       (list (settings piece-variable "4") (settings piece-variable "4") unset)))

(test-equal "a header name above 255 is refused"
  (refused not-latin-1 '("x-λ"))
  (exchange (lambda (r) (make-res 200 '(("x-λ" . "v")) "ok")) (get "/")))

(test-equal "a header whose name or value is no string, or that is no pair, is refused, the field named"
  (list (refused not-a-field '((x-name . "v")))
        (refused not-a-field '(("x-name" . 5)))
        (refused not-a-field '("x-name")))
  (list (exchange (lambda (r) (make-res 200 '((x-name . "v")) "ok")) (get "/"))
        (exchange (lambda (r) (make-res 200 '(("x-name" . 5)) "ok")) (get "/"))
        (exchange (lambda (r) (make-res 200 '("x-name") "ok")) (get "/"))))

;;; --- the setting --------------------------------------------------------------

;; pieces : (U (String -> (U String #f)) 'process) Nat -> (List (Listof Nat) Boolean)
;; A custom port of N bytes answered through the adapter made with ENV, or
;; with no env when ENV is process: its chunks' sizes, and whether the body
;; read whole is the port's bytes.
(define (pieces env n)
  (let* ((body (filled n))
         (app (lambda (r) (make-res 200 '() (custom-port body))))
         (host (make-test-host (if (eq? env 'process) (circuit->handler app) (circuit->handler app env))
                               unset))
         (c (test-host-connect! host)))
    (test-client-send! c (b (get "/")))
    (let ((r (car (test-client-responses c))))
      (list (chunk-sizes (test-response-bytes r))
            (string=? (text (test-response-body r)) body)))))

(test-equal "CIRCUIT_PORT_PIECE_BYTES: 65,536 bytes a piece when unset, and when empty"
  (list (list '(65536 100 0) #t) (list '(65536 100 0) #t))
  (list (pieces unset 65636) (pieces (settings piece-variable "") 65636)))

;; A count past Chez's fixnums is taken as the greatest fixnum: no piece could
;; hold more, and get-bytevector-n refuses a count that is no fixnum.
(test-equal "CIRCUIT_PORT_PIECE_BYTES: a given size, leading zeros allowed, and no maximum, a count past the fixnums included"
  (list (list '(5 5 2 0) #t) (list '(7 5 0) #t) (list '(70000 0) #t))
  (list (pieces (settings piece-variable "5") 12)
        (pieces (settings piece-variable "007") 12)
        (pieces (settings piece-variable "1000000000000000000000") 70000)))

(test-equal "CIRCUIT_PORT_PIECE_BYTES: a malformed value is refused as the server's config error, naming the variable and the value"
  (map (lambda (value)
         (list #t #t #f 'circuit->handler malformed (list piece-variable value)))
       (list "-1" "+8" "0" "8.0" "x" "\x663;" " 8" "#x50" 8))
  (map (lambda (value)
         (raised-by (lambda () (circuit->handler ok-app (settings piece-variable value)))))
       (list "-1" "+8" "0" "8.0" "x" "\x663;" " 8" "#x50" 8)))

(test-equal "CIRCUIT_PORT_PIECE_BYTES is read once, when circuit->handler is called"
  (list 1 (list '(3 3 1 0) #t) (list '(3 3 1 0) #t) 1)
  (let* ((reads 0)
         (value "3")
         (env (lambda (name)
                (cond ((string=? name piece-variable) (set! reads (+ reads 1)) value)
                      (else #f))))
         (app (lambda (r) (make-res 200 '() (custom-port "abcdefg"))))
         (handler (circuit->handler app env))
         (after-making reads)
         (host (make-test-host handler unset))
         (first (let ((c (test-host-connect! host)))
                  (test-client-send! c (b (get "/")))
                  (set! value "x")
                  (let ((r (car (test-client-responses c))))
                    (list (chunk-sizes (test-response-bytes r))
                          (string=? (text (test-response-body r)) "abcdefg")))))
         (second (let ((c (test-host-connect! host)))
                   (test-client-send! c (b (get "/")))
                   (let ((r (car (test-client-responses c))))
                     (list (chunk-sizes (test-response-bytes r))
                           (string=? (text (test-response-body r)) "abcdefg"))))))
    (list after-making first second reads)))

(test-equal "an app or an env that is no procedure is refused"
  (list (list #f #f #t 'circuit->handler not-an-app '(42))
        (list #f #f #t 'circuit->handler not-an-app '(42))
        (list #f #f #t 'circuit->handler not-an-env '("env")))
  (list (raised-by (lambda () (circuit->handler 42)))
        (raised-by (lambda () (circuit->handler 42 unset)))
        (raised-by (lambda () (circuit->handler ok-app "env")))))

;; A serve that is reached refuses CHEZ_HTTP_PORT as x before it listens, so
;; a run-server that failed to refuse first raises the server's own error,
;; naming that variable, and never listens.
(test-equal "run-server refuses an app that is no procedure, and a malformed setting, before serve"
  (list (list #f #f #t 'circuit->handler not-an-app '(42))
        (list #f #f #t 'circuit->handler not-an-app '(42))
        (list #t #t #f 'circuit->handler malformed (list piece-variable "x")))
  (let* ((bare (begin (putenv "CHEZ_HTTP_PORT" "x") (raised-by (lambda () (run-server 42)))))
         (given (raised-by (lambda () (run-server 42 (settings "CHEZ_HTTP_PORT" "x")))))
         (bad-setting (raised-by (lambda ()
                                   (run-server ok-app (settings piece-variable "x" "CHEZ_HTTP_PORT" "x"))))))
    (putenv "CHEZ_HTTP_PORT" "")
    (list bare given bad-setting)))

;; The process's CHEZ_HTTP_PORT is y and the given env's x, both malformed,
;; so serve refuses whichever it reads, naming it, before it listens.
(test-equal "run-server hands its env to serve: serve refuses the env's setting, not the process's"
  (list #t #t #t 'limits-from-environment "expected a whole number in ASCII digits"
        '("CHEZ_HTTP_PORT" "x"))
  (let ((refusal (begin (putenv "CHEZ_HTTP_PORT" "y")
                        (raised-by (lambda () (run-server ok-app (settings "CHEZ_HTTP_PORT" "x")))))))
    (putenv "CHEZ_HTTP_PORT" "")
    refusal))

;; These rows set the process's environment, so they come last, and put it
;; back to empty, which keeps the default.
(test-equal "with no env, circuit->handler reads the process's environment, by getenv"
  (list (list '(3 3 1 0) #t)
        (list #t #t #f 'circuit->handler malformed (list piece-variable "x"))
        (list '(65536 100 0) #t))
  (let* ((given (begin (putenv piece-variable "3") (pieces 'process 7)))
         (bad (begin (putenv piece-variable "x") (raised-by (lambda () (circuit->handler ok-app)))))
         (empty (begin (putenv piece-variable "") (pieces 'process 65636))))
    (list given bad empty)))

;;; --- parity with (circuit test) ---------------------------------------------------

;; body-kinds : (Listof (List Symbol (-> Res) String))
;; Each body kind, a thunk that makes a fresh response with it, and the
;; bytes it holds as text.
(define body-kinds
  (list (list 'none (lambda () (make-res 200 '() #f)) "")
        (list 'bytevector (lambda () (make-res 200 '() #vu8(0 1 255))) (text #vu8(0 1 255)))
        (list 'string (lambda () (make-res 200 '() "héllo ✓")) (utf8-text "héllo ✓"))
        (list 'producer (lambda () (make-res 200 '() (producer "ab" "cde"))) "abcde")
        (list 'bytevector-port (lambda () (make-res 200 '() (positioned "0123456789" 4))) "456789")
        (list 'custom-port (lambda () (make-res 200 '() (custom-port "abcdefghij"))) "abcdefghij")
        (list 'positioned-custom-port (lambda () (make-res 200 '() (positioned-custom-port "abcdefg"))) "abcdefg")
        (list 'sized-producer (lambda () (make-res 200 '() (make-sized-body 5 (producer "ab" "cde")))) "abcde")
        (list 'sized-port (lambda () (make-res 200 '() (make-sized-body 4 (custom-port "abcdefghij")))) "abcd")
        (list 'tapped (lambda () (res-tap-body (make-res 200 '() (positioned "hello world" 6)) quiet))
              "world")
        (list 'wrapped (lambda () (res-wrap-body (make-res 200 '() (positioned "hello world" 6)) upcased))
              "WORLD")
        (list 'wrap-dropping
              (lambda () (res-wrap-body (make-res 200 '() (make-sized-body 5 (producer "abc" "de" "XYZ"))) as-is))
              "abcde")
        (list 'wraps-nested
              (lambda () (res-wrap-body (res-wrap-body (make-res 200 '() (custom-port "abc")) upcased)
                                        (trailer "!")))
              "ABC!")
        (list 'tap-over-wrap
              (lambda () (res-tap-body (res-wrap-body (make-res 200 '() (custom-port "abc")) upcased) quiet))
              "ABC")
        (list 'wrap-over-tap
              (lambda () (res-wrap-body (res-tap-body (make-res 200 '() (make-sized-body 5 (producer "ab" "cde" "XYZ")))
                                                      quiet)
                                        (trailer "!")))
              "abcde!")
        (list 'tapped-sized-port
              (lambda () (res-tap-body (make-res 200 '() (make-sized-body 4 (positioned "0123456789" 0))) quiet))
              "0123")
        (list 'empty-wrapped (lambda () (res-wrap-body (make-res 200 '() "") (trailer "END"))) "END")))

;; In pieces of 3 every port here streams from the adapter; in the default
;; pieces every port with a length is read whole. (circuit test) reads in
;; the default pieces either way.
(test-equal "parity: res-body->bytevector answers the bytes the test host's client reads, for every body kind, ports streamed and read whole"
  (let ((each (map (lambda (kind) (list (car kind) (caddr kind) (caddr kind))) body-kinds)))
    (list each each))
  (map (lambda (env)
         (map (lambda (kind)
                (let* ((make (cadr kind))
                       (host (host-of (lambda (r) (make)) env))
                       (c (test-host-connect! host)))
                  (test-client-send! c (b (get "/")))
                  (list (car kind)
                        (text (test-response-body (car (test-client-responses c))))
                        (text (res-body->bytevector (make))))))
              body-kinds))
       (list (settings piece-variable "3") unset)))

(test-end "http-server")

(exit (suite-exit-status runner))
