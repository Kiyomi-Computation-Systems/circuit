#!r6rs
(library (circuit worker shell)
  (export)
  (import (rnrs)
          (circuit worker machine)
          (only (http-server) await-outside deadline-passed? client-closed?)
          (only (chezscheme) fork-thread thread-join make-mutex mutex-acquire mutex-release
                make-condition condition-wait condition-signal condition-broadcast
                disable-interrupts enable-interrupts make-thread-parameter get-thread-id)
          (rnrs io ports)
          (rnrs records syntactic)))
