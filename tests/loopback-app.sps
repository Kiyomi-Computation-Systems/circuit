#!r6rs
;;; A test-only server, which tests/test-examples.sps runs as a process and
;;; asks over loopback: what only a socket shows. It calls run-server with
;;; no env, so the process's environment sets both the server's settings and
;;; circuit's CIRCUIT_PORT_PIECE_BYTES.
;;;
;;;   GET  /addresses  the connection's four addresses, written as data:
;;;                    (remote-address remote-port local-address local-port)
;;;   GET  /pieces     "abcdefghij" from a port with no length, so it goes out
;;;                    chunked, a chunk for each piece the adapter reads
;;;   POST /body       the body, read whole, back
;;;   GET  /caught/R   raise R inside wrap-catch: the catch's default line,
;;;                    then an empty 500
;;;   GET  /raised/R   raise R with no catch: the server's handler-failed
;;;                    line, and its 500
;;;   GET  /stream     a logged stream: the line "1", then, 30 s later, "2";
;;;                    wrap-log's line once the response is done
;;;
;;; R names a raise: irritant, (error 'app "refused" 7); lines,
;;; (error 'app "two\nlines"), its message on two lines; or components, a
;;; &warning alone, which Chez's display-condition shows on two lines.
;;;
;;; The server runs with a current output port over standard output that
;;; is buffered by blocks, so a line reaches standard output only once its
;;; writer flushes it. Chez's own, the console port, writes out at each
;;; line feed when standard output is a file, so a line whose flush is
;;; missing would reach it anyway.
;;;
;;; Not named test-*.sps, so make test doesn't run it as a suite.
(import (rnrs) (circuit) (circuit http-server) (circuit middleware waits)
        (only (chezscheme) parameterize)
        ;; (rnrs)'s current-output-port is no parameter; it reads Chez's.
        (rename (only (chezscheme) current-output-port standard-output-port)
                (current-output-port chez:current-output-port)
                (standard-output-port chez:standard-output-port)))

;; written : Any -> String
(define (written datum)
  (call-with-string-output-port (lambda (p) (write datum p))))

;; addresses : Req -> String
(define (addresses req)
  (string-append (written (list (req-remote-address req) (req-remote-port req)
                                (req-local-address req) (req-local-port req)))
                 "\n"))

;; unmeasured : Bytevector -> BinaryInputPort
;; A port over BYTES with no position, so the adapter can't tell its length.
(define (unmeasured bytes)
  (let ((at 0))
    (make-custom-binary-input-port
     "unmeasured"
     (lambda (target start count)
       (let ((n (min count (- (bytevector-length bytes) at))))
         (bytevector-copy! bytes at target start n)
         (set! at (+ at n))
         n))
     #f #f #f)))

;; read-all : BinaryInputPort -> Bytevector — what is left of PORT, maybe nothing.
(define (read-all port)
  (let ((bytes (get-bytevector-all port)))
    (if (eof-object? bytes) (make-bytevector 0) bytes)))

;; after : String String -> (U String #f) — what follows PREFIX in S, if S begins with it.
(define (after prefix s)
  (let ((n (string-length prefix)))
    (and (>= (string-length s) n)
         (string=? (substring s 0 n) prefix)
         (substring s n (string-length s)))))

;; raise-named : String -> (U (-> Any) #f) — the raise R names, as the header says.
(define (raise-named r)
  (cond ((string=? r "irritant") (lambda () (error 'app "refused" 7)))
        ((string=? r "lines") (lambda () (error 'app "two\nlines")))
        ((string=? r "components") (lambda () (raise (make-warning))))
        (else #f)))

;; ticking : Nat Nat -> (-> (U Bytevector Eof)) — the lines "1" to "N", MS apart.
(define (ticking n ms)
  (let ((i 0))
    (lambda ()
      (set! i (+ i 1))
      (cond ((> i n) (eof-object))
            (else (when (> i 1) (sleep-ms ms))
                  (string->utf8 (string-append (number->string i) "\n")))))))

;; stream : Req -> Res — GET /stream, logged.
(define stream
  (wrap-log (lambda (req) (make-res 200 '(("content-type" . "text/plain")) (ticking 2 30000)))))

;; app : Req -> Res
(define (app req)
  (let ((path (req-path req)))
    (cond ((and (after "/caught/" path) (raise-named (after "/caught/" path)))
           => (lambda (raise-it) ((wrap-catch (lambda (req) (raise-it))) req)))
          ((and (after "/raised/" path) (raise-named (after "/raised/" path)))
           => (lambda (raise-it) (raise-it)))
          ((string=? path "/stream") (stream req))
          ((string=? path "/addresses")
           (make-res 200 '(("content-type" . "text/plain")) (addresses req)))
          ((string=? path "/pieces")
           (make-res 200 '(("content-type" . "text/plain"))
                     (unmeasured (string->utf8 "abcdefghij"))))
          ((string=? path "/body")
           (make-res 200 '() (read-all (req-body req))))
          (else (make-res 404 '() "")))))

(parameterize ((chez:current-output-port
                 (chez:standard-output-port (buffer-mode block) (native-transcoder))))
  (run-server app))
