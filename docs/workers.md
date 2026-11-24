# Workers

Some work can only block, such as a query through a C library. A worker
runs it on threads of its own, and the handler waits for the answer, so
the server goes on with everyone else meanwhile.

## Run a job on a worker

```scheme
(import (rnrs) (only (chezscheme) sleep make-time)
        (circuit) (circuit http-server) (circuit router) (circuit worker)
        (circuit middleware waits))

(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

;; A stand-in for a database. find-note blocks its thread 2 s, as a query
;; through a C library might.
(define (open-database) 'conn)
(define (close-database conn) (display "closed\n"))
(define (find-note conn id)
  (display (string-append "finding note " id "\n"))
  (sleep (make-time 'time-duration 0 2))
  (string-append "note " id "\n"))

(define db (make-worker open-database 8 1 close-database))

(define (show-note req)
  (let ((id (req-path-param req "id")))        ; plain data, taken first
    (text 200 (worker-call db (lambda (conn) (find-note conn id))))))

(define routes
  (make-router
   (list (route "/" (GET (lambda (req) (text 200 "fast\n"))))
         (route "/notes/:id" (GET show-note)))))

(run-server (wrap routes (wrap-busy 5) wrap-catch (wrap-timeout 5000)))
(worker-stop! db)
```

Ask for a note, and while it waits, ask for `/` from another terminal:

```text
$ curl -w '%{time_total} s\n' http://127.0.0.1:8080/notes/7
note 7
2.001612 s
```

```text
$ curl -w '%{time_total} s\n' http://127.0.0.1:8080/
fast
0.000770 s
```

- `(make-worker open-database 8 1 close-database)` starts a worker of one
  thread, with room for 8 waiting jobs. The thread runs `(open-database)`
  once and keeps what it returns, its *state*: here, the connection.
- `(worker-call db job)` runs `(job state)` on that thread, and gives back
  what the job returns. If the job raises, `worker-call` raises the same.
- Meanwhile the handler waits, as in
  [Wait for another thread](waiting.md#wait-for-another-thread), and the
  server goes on with other requests. The job runs on another thread, so
  take what it needs out of the request first, as `show-note` takes `id`.
- Make workers before `run-server`, never in a handler: `make-worker`
  blocks until every set-up has returned, and a set-up's raise comes out
  of `make-worker`.
- `worker?` tells a worker from any other value.

## Stop it last

Press Ctrl-C, and the server's terminal ends with:

```text
draining 0
stopped
closed
```

- `run-server` returns once the server has finished with its
  connections. Only then does `(worker-stop! db)` run.
- `(worker-stop! w)` refuses every job not yet begun, waits for the
  running ones, runs the tear-down, `close-database`, on each thread with
  its state, and ends the threads. A refused job's caller gets
  `&worker-stopped`, which `worker-stopped?` tells.
- Call it after `run-server` returns, never from a job: on a worker's
  thread it is an assertion violation.
- A tear-down's raise comes out of `worker-stop!`, once every thread has
  ended. A second `worker-stop!` answers the same.
- With several workers, stop them in the order you need, such as the
  readers, then the writer, whose tear-down closes the database.

## When the queue is full: `wrap-busy`

Give the worker room for one waiting job,
`(make-worker open-database 1 1 close-database)`, and ask for three notes,
a moment apart:

```text
$ curl -w '%{time_total} s\n' http://127.0.0.1:8080/notes/1 &
$ curl -w '%{time_total} s\n' http://127.0.0.1:8080/notes/2 &
$ curl -i http://127.0.0.1:8080/notes/3
HTTP/1.1 503 Service Unavailable
Date: Mon, 23 Nov 2026 23:05:51 GMT
retry-after: 5
Content-Length: 0

note 1
2.001537 s
note 2
3.497448 s
```

- Note 1 runs, note 2 waits in the queue, and note 3 finds no room.
- `cap`, the second argument, is how many jobs may wait while every
  thread is busy. A call past it raises `&worker-full` at once, and
  queues nothing. `worker-full?` tells it.
- `(wrap-busy n)` answers `&worker-full` and `&worker-stopped` with an
  empty `503` and `Retry-After: n`, in seconds.
- Put it inside `wrap-catch`, as the first program does: the last is
  outermost, so `wrap-busy` sees the refusal first. Without it, or outside
  the catch, the client gets a `500`, and the server logs
  `handler-failed Exception in worker-call: the worker's queue is full`.

## When the deadline comes first: a 504

Answer with `(wrap-timeout 1000)` instead, and ask for two notes, a
moment apart:

```text
$ curl -w '%{http_code} %{time_total} s\n' http://127.0.0.1:8080/notes/1 &
$ curl -w '%{http_code} %{time_total} s\n' http://127.0.0.1:8080/notes/2
504 1.002944 s
504 1.000442 s
```

The server's terminal shows `finding note 1`, and never `finding note 2`.

- A deadline, or the client's close, ends the handler's wait, not the job.
- A job not yet begun never runs: note 2 left the queue when its deadline
  passed.
- A job already running runs on, and its answer is dropped: note 1 ended
  at 2 s, and no one saw it. The next job waits behind it.
- So a `504` can't tell the client whether its job ran. Make a write that
  a client may retry safe to run twice, such as one keyed by an id the
  client makes.
- Nothing cuts a job short: bound it yourself, such as with the
  database's own timeout.

## Several threads

Give the worker two threads,
`(make-worker open-database 8 2 close-database)`, and two notes at once
take 2 s each, not 4:

```text
$ curl -s -o /dev/null -w '%{time_total} s\n' http://127.0.0.1:8080/notes/1 &
$ curl -s -o /dev/null -w '%{time_total} s\n' http://127.0.0.1:8080/notes/2
2.001020 s
2.000920 s
```

At Ctrl-C the server's terminal shows `closed` twice: once a thread.

- `(make-worker set-up cap threads)` starts `threads` threads, 1 if you
  leave it out. Each runs `set-up` once and keeps its own state.
- Any idle thread takes the next job. Jobs run in the order they came only
  on a worker of one thread.
- Give each kind of job a worker of its own, such as one thread for
  writes and several for reads: a slow write then holds up only other
  writes, and a flood of reads fills only the readers' queue.

## Test a handler that calls a worker

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit worker)
        (circuit middleware waits) (http-server testing))

(define db (make-test-worker (lambda () 'conn)))

(define (found-by conn)
  (string-append "found by " (symbol->string conn) "\n"))

(define (app req)
  (make-res 200 '() (worker-call db found-by)))

;; no-env : String -> #f — every setting at its default
(define (no-env name) #f)

(define host
  (make-test-host (circuit->handler (wrap app (wrap-busy 5) wrap-catch) no-env)
                  no-env))
(define client (test-host-connect! host))
(define (get!)
  (test-client-send! client (string->utf8 "GET / HTTP/1.1\r\nHost: x\r\n\r\n")))

(get!)
(worker-stop! db)
(get!)
(for-each (lambda (res)
            (write (test-response-status res)) (display " ")
            (write (utf8->string (test-response-body res))) (newline))
          (test-client-responses client))
```

It prints what the client read, before the stop and after:

```text
200 "found by conn\n"
503 ""
```

- `(make-test-worker set-up)` is a worker of one thread and no queue, for
  tests. Each call waits until its job has answered, so the answer is in
  when `test-client-send!` returns: no advance, no sleep.
- Its job runs on a thread of its own, as on `make-worker`, so a job that
  waits fails in the test as it would in the server.
- Two things hang a test that the server would survive: a job that never
  ends, where `make-worker` under `wrap-timeout` would answer `504`; and a
  handler that holds a lock of its own across the call, which the job then
  takes.
- It can't show what needs two calls at once, since each call waits for
  its answer: a full queue, or a read answered while a write is stalled.
  Test those on `make-worker`.
- In the test host, `make-worker`'s answers wait for your next
  `test-host-advance!`, and `test-host-posted` counts them: see the
  server's
  [Another thread's answers](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.12.0/docs/testing.md#another-threads-answers).

## What a call costs

One call of a job that does nothing, in the server's test host on Linux
x86-64, both threads counted, over 10,000 calls:

| What | Bytes a call |
|:--|--:|
| `worker-call` on `make-worker`, one thread | about 4,800 |
| `worker-call` on `make-test-worker` | about 4,600 |
| `await-outside`, answered by a thread of your own | about 1,400 |

- The worker adds about 3.4 KB a call to a thread of your own.
- Of that, its machine, which decides every step, takes 448 B, and
  `make gate` holds that part to 512 B. The rest is measured, not gated.
- The test host has no libuv loop. On the server's own loop, a wait
  answered by a thread costs about 2.2 KB
  ([Performance](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.12.0/docs/performance.md#waiting-for-another-thread)),
  so a call in a running server may cost more than the table says. That
  wasn't measured.

## What not to do

- **Don't wait in a job.** A job runs off the loop's thread, where
  `sleep-ms`, `worker-call` and every other wait raise
  `a wait off the loop's thread`.
- **Don't stop a worker from a job.** `worker-stop!` on any worker's
  thread is an assertion violation.
- **Don't let the state out.** Don't return or raise the state, or
  anything holding it, from a job or a tear-down: an error whose irritant
  is the connection carries it to the handler's thread.
- **Pass a job plain data, never a parameter.** A job's current ports and
  Chez's thread parameters are the ones `make-worker` ran with. Another
  parameter's `parameterize` in the handler may or may not reach the job,
  and on `make-test-worker` it always does. Log from the handler.
- **Don't call a worker from an interrupt handler,** such as a signal
  handler or a timer. It can hang the worker or break it, and nothing
  refuses it.
- **A job that leaves its thread stops the worker.** After an `exit` in a
  job, its caller gets an `&error`, a `500` under `wrap-catch`, and every
  call after it `&worker-stopped`, a `503`, until you make a new worker.
- **A warning doesn't end a job.** Chez's `(warning who message)` in a
  job is printed, and the job goes on.
- **A worker that stopped by itself, or broke, shows only when called.**
  A health check can make a small call, such as
  `(worker-call db (lambda (conn) 'ok))`.

The server's
[Traps](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.12.0/docs/waiting.md#traps)
hold for every job too. Above all, bind a job's blocking C call
`__collect_safe`, or the whole server freezes at its next collection, and
don't call `(collect)` once you have a worker.

[examples/worker.sps](../examples/worker.sps) runs a slow job on a worker
of one thread, with a queue of one.

See [`make-worker`](reference.md#make-worker),
[`worker-call`](reference.md#worker-call),
[`worker-stop!`](reference.md#worker-stop),
[`make-test-worker`](reference.md#make-test-worker) and
[`wrap-busy`](reference.md#wrap-busy) for the signatures.
