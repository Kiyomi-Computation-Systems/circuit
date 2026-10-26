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
;;;
;;; Not named test-*.sps, so make test doesn't run it as a suite.
(import (rnrs) (circuit) (circuit http-server))

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

;; app : Req -> Res
(define (app req)
  (let ((path (req-path req)))
    (cond ((string=? path "/addresses")
           (make-res 200 '(("content-type" . "text/plain")) (addresses req)))
          ((string=? path "/pieces")
           (make-res 200 '(("content-type" . "text/plain"))
                     (unmeasured (string->utf8 "abcdefghij"))))
          ((string=? path "/body")
           (make-res 200 '() (read-all (req-body req))))
          (else (make-res 404 '() "")))))

(run-server app)
