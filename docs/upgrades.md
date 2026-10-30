# Upgrades and WebSockets

A handler can take a connection over for another protocol: it answers 101,
and from then on it reads and writes the raw bytes. For a WebSocket,
`websocket-res` does the handshake and the framing for you.

## Take a connection over

```scheme
(import (rnrs) (circuit) (circuit http-server))

(define (echo t retained)
  (when (> (bytevector-length retained) 0)
    (transport-write! t retained))
  (transport-read-start! t
                         (lambda (bytes start end) (transport-write! t bytes start end))
                         (lambda (why) (transport-close! t)))
  (transport-on-drain! t (lambda () (transport-close! t))))

(run-server
 (lambda (req)
   (if (equal? (req-header req "upgrade") "echo")
       (make-upgrade-res '(("upgrade" . "echo")) echo)
       (make-res 200 '(("content-type" . "text/plain")) "ask for Upgrade: echo\n"))))
```

curl can't talk once the 101 is in, so try it with bash's `/dev/tcp`:

```text
$ exec 3<>/dev/tcp/127.0.0.1/8080
$ printf 'GET / HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: echo\r\n\r\nhi' >&3
$ timeout 1 cat <&3
HTTP/1.1 101 Switching Protocols
upgrade: echo
Connection: upgrade

hi
```

- `(make-upgrade-res headers take-over)` answers 101 with your headers. The
  server adds `Connection: upgrade`. Your `upgrade` field must name a
  protocol the client asked for: any other gets the server's 500, logged
  `invalid-upgrade`.
- Once the 101 is written, the server calls
  `(take-over transport retained)`. `retained` holds what the client sent
  past its request that the server had already read: here, `hi`.
- The server switches only an HTTP/1.1 request with `Connection: upgrade`
  and `Upgrade`, and no body. Any other gets the server's own 500, logged
  `invalid-response not-an-upgrade`.
- The transport procedures come from `(circuit http-server)`.

## Use the transport

| Call | Does |
|:--|:--|
| `(transport-write! t bv [start end] [done])` | sends the bytes; `done` gets `#f` once they are sent, or the error |
| `(transport-read-start! t on-bytes on-end)` | hands each read to `(on-bytes bv start end)`, then calls `(on-end why)` once |
| `(transport-read-stop! t)` | stops reading |
| `(transport-close! t)` | closes, once your writes are out and the client closes too |
| `(transport-abort! t)` | closes now, dropping what isn't sent |
| `(transport-deadline! t ms proc)` | calls `proc` once `ms` milliseconds pass; `#f` for `ms` cancels |
| `(transport-on-drain! t proc)` | calls `proc` when the server shuts down |
| `(transport-on-close! t proc)` | calls `proc` once the stream has closed |

- The stream stays open until something closes it. When the client
  finishes, `on-end` gets `eof`: close there, as the echo does.
- The take-over and its callbacks run inside the server's own callbacks:
  keep them quick. A raise in one is logged `taker-failed`, and the stream
  closed.
- The server's
  [Upgrades](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.9.1/docs/upgrades.md)
  page has the rules for reads, writes, closing and shutdown.

## Wait inside a take-over

```scheme
(define (greet t retained)
  (awaiting
   (lambda ()
     (sleep-ms 500)
     (transport-write! t (string->utf8 "hello\n"))
     (transport-close! t))))
```

With `(make-upgrade-res '(("upgrade" . "echo")) greet)`, the same session
prints, half a second after the 101:

```text
HTTP/1.1 101 Switching Protocols
upgrade: echo
Connection: upgrade

hello
```

- A take-over can't wait as it is. One that tries is logged
  `taker-failed Exception in sleep-ms: a wait inside a libuv callback`.
- To wait, it answers `(awaiting thunk)`. The server runs `thunk` on a
  coroutine, where it can `sleep-ms`, `await` and `with-deadline`
  ([Waiting](waiting.md)).
- What `thunk` returns is dropped.
- Once the stream closes, the wait `thunk` is in raises `&client-closed`.
- A handler never answers `awaiting` itself: circuit does that for every
  request.

## Middleware around an upgrade

```scheme
(define (wrap-note-upgrades handler)
  (lambda (req)
    (let ((res (handler req)))
      (if (res-upgrade-body? (res-body res))
          (let ((take-over (res-upgrade-body-take-over (res-body res))))
            (make-upgrade-res (res-headers res)
                              (lambda (t retained)
                                (display "taken over\n")
                                (take-over t retained))))
          res))))
```

Around the WebSocket echo below, the server's terminal shows, once a
client connects:

```text
listening 127.0.0.1 8080
taken over
```

- `(res-upgrade-body? (res-body res))` tells an upgrade from any other
  response.
- `res-set-header`, `res-add-header` and `res-remove-header` keep an upgrade
  an upgrade. `res-with-status`, `res-with-body`, `res-wrap-body` and
  `res-tap-body` refuse one.
- To wrap the take-over, get it with `res-upgrade-body-take-over`, and make
  a new upgrade around yours with `make-upgrade-res`.
- Answer what the wrapped take-over answers: it goes to the server. Drop
  it, and the 101 still goes out, but a WebSocket's procedure never runs.
- `wrap-catch` passes an upgrade through. `wrap-log` logs it as
  `101 written` once the 101 is out, before the take-over runs.
  `wrap-timeout`'s deadline covers the handler, not the take-over.

## Answer a WebSocket

```scheme
(import (rnrs) (circuit) (circuit http-server) (circuit websocket) (websocket))

(define (echo ws)
  (let loop ()
    (websocket-send! ws (websocket-receive ws))
    (loop)))

(run-server
 (lambda (req)
   (if (string=? (req-path req) "/echo")
       (websocket-res req echo)
       (make-res 404 '() #f))))
```

```text
$ printf hi | curl -s --max-time 1 -T - ws://127.0.0.1:8080/echo
hi
$ curl -i http://127.0.0.1:8080/echo
HTTP/1.1 400 Bad Request
Date: Fri, 30 Oct 2026 10:51:28 GMT
Content-Length: 0
```

- `(websocket-res req proc)` answers the handshake's 101, then runs
  `(proc ws)` on a coroutine of its own.
- A request that is no handshake gets an empty 400, and a browser's page
  from another site an empty 403. Then `proc` never runs.
- `websocket-receive` waits for the next message: a string for text, a
  bytevector for binary. `websocket-send!` sends a string as text and a
  bytevector as binary.
- When the client closes, `websocket-receive` raises `&websocket-closed`.
  Let it out of `proc`, and the connection ends quietly.
- `(websocket)` is chez-websocket's library: import it beside
  `(circuit websocket)` for the rest, such as `websocket-close!`. See its
  [Handlers](https://github.com/Kiyomi-Computation-Systems/chez-websocket/blob/v0.4.1/docs/handlers.md).
- curl 8.11 or later speaks WebSocket. It sends what it reads as one binary
  message, prints what comes back, and waits until `--max-time`. To type
  messages yourself, use [websocat](https://github.com/vi/websocat):
  `websocat ws://127.0.0.1:8080/echo`.

## Choose a subprotocol, check the origin

```scheme
(define settings
  (make-handshake-settings '("chat.v2" "chat.v1")
                           '(same-host "https://app.example.com")))

(define (chat ws)
  (let ((chosen (or (websocket-subprotocol ws) "none")))
    (websocket-send! ws (string-append "speaking " chosen "\n"))
    (echo ws)))

(websocket-res req chat settings)
```

With `/echo` answered this way in the program above:

```text
$ curl -s --max-time 1 -H 'Sec-WebSocket-Protocol: chat.v1' ws://127.0.0.1:8080/echo
speaking chat.v1
```

- Settings come third. Make them once, as the program starts: a bad name
  stops it there.
- The first subprotocol in your list that the client offered is chosen,
  and `websocket-subprotocol` reads it. With none of yours offered, the
  handshake still goes through, with none.
- Origins: `same-host`, the default, takes a page from the request's own
  host, and a string takes that origin. `'any`, in place of the list,
  takes every one.
- A request with no `Origin` is no browser's, and is always taken.

## Set a WebSocket's limits

```sh
CHEZ_WS_MAX_MESSAGE_BYTES=4 make run PROGRAM=app.sps
```

With the echo, `printf hello | curl ...` sends 5 bytes. The server closes
the WebSocket, and its terminal shows:

```text
listening 127.0.0.1 8080
websocket-failed 1009 message-too-big
```

To take the limits from an `env` of your own, a procedure from a name to
its value such as the one on [Configuration](configuration.md):

```scheme
(define settings (make-handshake-settings '()))
(define limits (websocket-limits-from-environment env))

(run-server (lambda (req) (websocket-res req echo settings limits)) env)
```

- An `env` given to `run-server` doesn't reach the `CHEZ_WS_` variables.
  Build limits from it with `websocket-limits-from-environment`, and give
  them to `websocket-res`, fourth, after the settings.
- `(make-handshake-settings '())` are the default settings.
- [Configuration](configuration.md) lists the variables, and when they are
  read.

## Examples

- [examples/upgrade.sps](../examples/upgrade.sps) takes a connection over
  and echoes every byte back.
- [examples/websocket.sps](../examples/websocket.sps) is a WebSocket echo,
  with a hint for any other path.
