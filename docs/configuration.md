# Configuration

Circuit and the server it runs on take their settings from environment
variables. Set them where you start the program: there is nothing to change
in your code.

## Set a variable

```sh
CHEZ_HTTP_PORT=3000 make run PROGRAM=app.sps
```

It prints `listening 127.0.0.1 3000`. A bad value stops the program before
it listens, naming the variable. `CHEZ_HTTP_PORT=80a` stops it with:

```text
Exception in limits-from-environment: expected a whole number in ASCII digits with irritants ("CHEZ_HTTP_PORT" "80a")
```

- Unset or empty keeps the default.
- A number is the digits `0` to `9` and nothing else. Leading zeros are
  fine, while `-1` and ` 80` are refused.
- Each variable is read once, as the program starts.

## The server's settings

```sh
CHEZ_HTTP_HOST=0.0.0.0 CHEZ_HTTP_PORT=3000 make run PROGRAM=app.sps
```

It prints `listening 0.0.0.0 3000`. The ones you'll reach for first:

| Variable | Default | What it sets |
|:--|:--|:--|
| `CHEZ_HTTP_HOST` | `127.0.0.1` | the IP address to listen on; `0.0.0.0` for every interface |
| `CHEZ_HTTP_PORT` | `8080` | the port; `0` takes any free one |
| `CHEZ_HTTP_MAX_BODY_BYTES` | unbounded | the most any request body may hold; `wrap-body-cap` caps under it ([Bodies and streaming](bodies.md)) |
| `CHEZ_HTTP_READ_HEADER_TIMEOUT` | 60 s | time to receive a request's head |
| `CHEZ_HTTP_IDLE_TIMEOUT` | 75 s | how long a kept-alive connection may sit idle |
| `CHEZ_HTTP_MAX_CONNECTIONS` | 10000 | connections open at once |
| `CHEZ_HTTP_DRAIN_TIMEOUT` | 10 s | how long a shutdown waits for connections to end |

- The host is an IP address: a name such as `localhost` is refused.
- Timeouts are whole seconds.
- On a platform that sets `PORT`, pass it on: `CHEZ_HTTP_PORT=$PORT`.
- The rest, with what each does, are on the server's
  [Configuration](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/v0.9.1/docs/configuration.md)
  page.

## Size a port body's pieces

```sh
CIRCUIT_PORT_PIECE_BYTES=16384 make run PROGRAM=app.sps
```

| Variable | Default | What it sets |
|:--|:--|:--|
| `CIRCUIT_PORT_PIECE_BYTES` | 65536 | the most a piece of a port body holds |

- It must be 1 or more, in digits. `CIRCUIT_PORT_PIECE_BYTES=0` stops the
  program before it listens, with `Exception in circuit->handler`.
- [Bodies and streaming](bodies.md) says how a port body goes out.

## WebSocket limits

```sh
CHEZ_WS_MAX_MESSAGE_BYTES=16777216 CHEZ_WS_PING_INTERVAL=30 make run PROGRAM=app.sps
```

| Variable | Default | What it sets |
|:--|:--|:--|
| `CHEZ_WS_MAX_MESSAGE_BYTES` | 1048576 | the largest message; a bigger one closes with `1009` |
| `CHEZ_WS_MAX_QUEUE` | 16 | messages waiting for `websocket-receive` before reading stops |
| `CHEZ_WS_PING_INTERVAL` | 20 s | quiet time before the server pings; `0` turns pinging off |
| `CHEZ_WS_PING_TIMEOUT` | 20 s | time for the client's pong; past it, the connection closes with `1011` |
| `CHEZ_WS_CLOSE_TIMEOUT` | 10 s | time for the client to finish a close |
| `CHEZ_WS_WRITE_HIGH_WATER` | 262144 | bytes unsent before a send waits and reading stops |
| `CHEZ_WS_WRITE_LOW_WATER` | 65536 | bytes unsent when both go on again |
| `CHEZ_WS_WRITE_TIMEOUT` | 60 s | time a client behind on its reads has for each write |

- chez-websocket reads these once, as the program starts, from the
  process's environment.
- An `env` you give `run-server` doesn't reach them: see
  [Upgrades and WebSockets](upgrades.md) to build limits from one.
- What each limit does is on chez-websocket's
  [Configuration](https://github.com/Kiyomi-Computation-Systems/chez-websocket/blob/v0.4.1/docs/configuration.md)
  page.

## Give run-server an env of your own

```scheme
(import (rnrs) (only (chezscheme) getenv) (circuit) (circuit http-server))

(define settings
  '(("CHEZ_HTTP_MAX_BODY_BYTES" . "16")
    ("CIRCUIT_PORT_PIECE_BYTES" . "16384")))

(define (env name)
  (cond ((assoc name settings) => cdr)
        (else (getenv name))))

(define (app req)
  (let* ((body (get-bytevector-all (req-body req)))
         (n (if (eof-object? body) 0 (bytevector-length body))))
    (make-res 200 '(("content-type" . "text/plain"))
              (string-append "got " (number->string n) " bytes\n"))))

(run-server app env)
```

```text
$ curl --data 'hi there' http://127.0.0.1:8080/
got 8 bytes
$ curl -i --data 'more than sixteen bytes' http://127.0.0.1:8080/
HTTP/1.1 413 Content Too Large
Date: Fri, 30 Oct 2026 10:56:32 GMT
Content-Length: 0
Connection: close
```

- An env is a procedure from a variable's name to its value, or `#f` for
  unset. Chez's `getenv` is one.
- `(run-server app env)` reads every setting from `env` in place of the
  process's environment: the server's, and `CIRCUIT_PORT_PIECE_BYTES`.
- A variable `env` answers `#f` for is unset, whatever the process has.
  Here `getenv` fills in the rest, so `CHEZ_HTTP_PORT` still comes from the
  process.
- Use one to test a setting, or to read settings from a file.
