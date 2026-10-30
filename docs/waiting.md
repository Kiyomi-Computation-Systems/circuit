# Waiting

A handler can wait: for a moment to pass, for another request, or until a
deadline. Each request runs on a coroutine of its own, so while one waits,
the others go on.

## Wait without holding anyone up

```scheme
(import (rnrs) (circuit) (circuit http-server))

(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

(run-server
 (lambda (req)
   (if (string=? (req-path req) "/slow")
       (begin (sleep-ms 2000) (text 200 "slept\n"))
       (text 200 "fast\n"))))
```

Ask for `/slow`, and while it waits, ask for `/` from another terminal:

```text
$ curl -w '%{time_total} s\n' http://127.0.0.1:8080/slow
slept
2.008326 s
```

```text
$ curl -w '%{time_total} s\n' http://127.0.0.1:8080/
fast
0.000574 s
```

- Each request's handler, its middleware and its body's reads run on its
  coroutine. There is nothing to set up.
- `(sleep-ms n)` waits `n` milliseconds. Meanwhile the server goes on with
  other requests.
- While a handler waits, the next request on its connection waits too.
  Other connections go on.
- The waits come from the server, through `(circuit http-server)`.

## Wait for another request

```scheme
(import (rnrs) (circuit) (circuit http-server))

(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

(define waiting '())

(define (wait req)
  (text 200 (await (lambda (resume) (set! waiting (cons resume waiting))))))

(define (send req)
  (let ((woken waiting))
    (set! waiting '())
    (for-each (lambda (resume) (resume "hello\n")) woken)
    (text 200 (string-append "woke " (number->string (length woken)) "\n"))))

(run-server
 (lambda (req)
   (if (string=? (req-path req) "/wait") (wait req) (send req))))
```

Ask for `/wait`. It waits until, from another terminal, you ask for
`/send`:

```text
$ curl http://127.0.0.1:8080/send
woke 1
```

Then the first one answers:

```text
$ curl http://127.0.0.1:8080/wait
hello
```

- `(await register)` calls `register` with a procedure, `resume`, then
  waits. `(resume v)` wakes it, and `await` gives back `v`.
- Keep `resume` where another request can find it: here, the list
  `waiting`.
- Call each `resume` once. A second call wakes nothing, and the server logs
  `late-resume await`.
- [examples/long-poll.sps](../examples/long-poll.sps) is this, with a
  deadline, and a client that leaves forgotten.

## Give up after a time

In the first program, answer `/slow` this way instead:

```scheme
(guard (e ((deadline-passed? e) (text 504 "gave up\n")))
  (with-deadline 1000
    (lambda () (sleep-ms 5000) (text 200 "slept\n"))))
```

```text
$ curl -w '%{time_total} s\n' http://127.0.0.1:8080/slow
gave up
1.002918 s
```

- `(with-deadline ms thunk)` runs `thunk` and gives back what it returns.
  Once `ms` milliseconds pass, the wait `thunk` is in raises
  `&deadline-passed`, and so does every wait inside it after that.
- Code that isn't waiting is never cut short: it raises at its next wait,
  if it has one.
- `deadline-passed?` tells the deadline from other raises.
- A `resume` called after its deadline wakes nothing, and the server logs
  `late-resume await`.
- `(wrap-timeout ms)` puts a deadline around a whole handler, and answers
  an empty 504: see [Middleware](middleware.md).

## When the client goes away

```scheme
(define (wait req)
  (let ((mine #f))
    (guard (e ((client-closed? e)
               (set! waiting (remq mine waiting))
               (raise e)))
      (text 200 (await (lambda (resume)
                         (set! mine resume)
                         (set! waiting (cons resume waiting))))))))
```

With this `wait` in the program above, a client that gives up is
forgotten:

```text
$ curl --max-time 1 http://127.0.0.1:8080/wait
$ curl http://127.0.0.1:8080/send
woke 0
```

- When the client closes the connection, the wait the handler is in raises
  `&client-closed`. If it isn't waiting just then, its next wait does. It
  happens once.
- Let it raise: the server answers nothing, closes the connection, and
  logs nothing.
- Catch it to clean up, such as to drop a `resume` you kept, then raise it
  again.
- `wrap-catch` passes it on, so it never turns into a 500.

## Look up a name

```scheme
(resolve "localhost")
```

In a handler, that gave `("127.0.0.1")`. Which addresses come back is up
to your system.

- `(resolve host)` waits for the system's resolver, and gives back the
  host's addresses as strings.
- A name that doesn't resolve raises `&resolve-error`.
  `(resolve-error-reason e)` says why, such as `invalid-name` for `""`.

## What not to do

- **Don't block.** A call that holds the thread, such as Chez's `sleep`,
  holds up every request until it returns: while one handler slept 2 s
  that way, a request for `/` took 1.7 s. Use `sleep-ms`.
- **Don't wait outside a request.** A wait at the program's top level
  raises: `a wait on no coroutine`. A take-over can't wait either, unless
  it answers `awaiting`: see [Upgrades and WebSockets](upgrades.md).
- **Don't release in a `dynamic-wind`'s after thunk.** A wait leaves every
  `dynamic-wind` around it and comes back in, so the after thunk runs at
  each wait. Release when your code returns, or in an exception handler.
  Chez's `with-mutex` is a `dynamic-wind` too: it doesn't hold across a
  wait.

The server's
[Waiting](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.9.1/docs/waiting.md)
page goes deeper: memory, costs, and how a body read waits.
