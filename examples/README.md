# Examples

Small servers, each one file, each showing one thing. Each imports only
`(rnrs)`, `(circuit)` and `(circuit http-server)`, and middleware.sps
`(circuit middleware waits)` too. Run one from the checkout's root:

```sh
make run PROGRAM=examples/hello.sps
```

Each listens on `127.0.0.1:8080` unless `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT`
say otherwise, and stops on Ctrl-C.

| File | Shows | Try | Answers |
|:--|:--|:--|:--|
| [hello.sps](hello.sps) | the smallest server, and a middleware | `curl -i 127.0.0.1:8080/` | `200`, `text/plain`, a `server: circuit` field, `hello` |
| [echo.sps](echo.sps) | reading the request and its body | `curl --data hi '127.0.0.1:8080/a?b=1'` | `200`, `text/plain`: `POST /a?b=1`, a newline, then the body, `hi` |
| [stream.sps](stream.sps) | streaming a response, and server-sent events | `curl -N '127.0.0.1:8080/ticks?n=5&ms=1000'` | `200`, `text/event-stream`, chunked: `data: tick 1` to `data: tick 5`, a second apart; `/count?n=5` is the lines `1` to `5` |
| [long-poll.sps](long-poll.sps) | a handler that waits for another request, with a timeout | `curl 127.0.0.1:8080/wait`, then `curl --data hi 127.0.0.1:8080/send` | the send: `200`, `woke 1`; the wait: `200`, `hi`; a wait with no send for 30 s: `504`; `/waiting` is how many wait |
| [middleware.sps](middleware.sps) | a catch, a timeout of 1 s and a log, composed | `curl -i '127.0.0.1:8080/slow?ms=1500'` | `/`: `200`, `hello`; `/slow?ms=N`: `200`, `waited N ms`, or past 1 s an empty `504`; `/boom`: an empty `500`. Each request logs a line, `request GET /slow 504 written 1001`, and `/boom` first `handler-failed Exception in app: boom` |

hello and echo answer any request. stream, long-poll and middleware answer
any other `404`, with a hint.

`tests/test-examples.sps` runs each one and checks what it answers.
