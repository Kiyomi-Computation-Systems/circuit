# Examples

Small servers, each one file, each showing one thing. Each imports only
`(rnrs)`, `(circuit)` and `(circuit http-server)`; middleware.sps imports
`(circuit middleware waits)` too, router.sps `(circuit router)`, and websocket.sps
`(circuit websocket)` and chez-websocket's `(websocket)`. Run one
from the checkout's root:

```sh
make run PROGRAM=examples/hello.sps
```

Each listens on `127.0.0.1:8080` unless `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT`
say otherwise, and stops on Ctrl-C.

| File | Shows | Try | Answers |
|:--|:--|:--|:--|
| [hello.sps](hello.sps) | the smallest server, and a middleware | `curl -i 127.0.0.1:8080/` | `200`, `text/plain`, a `server: circuit` field, `hello` |
| [echo.sps](echo.sps) | reading the request and its body, capped with `wrap-body-cap` | `curl --data hi '127.0.0.1:8080/a?b=1'` | `200`, `text/plain`: `POST /a?b=1`, a newline, then the body, `hi`; a body past 1 MiB: an empty `413`, the connection closed |
| [stream.sps](stream.sps) | streaming a response, and server-sent events | `curl -N '127.0.0.1:8080/ticks?n=5&ms=1000'` | `200`, `text/event-stream`, chunked: `data: tick 1` to `data: tick 5`, a second apart; `/count?n=5` is the lines `1` to `5` |
| [long-poll.sps](long-poll.sps) | a handler that waits for another request, with a timeout | `curl 127.0.0.1:8080/wait`, then `curl --data hi 127.0.0.1:8080/send` | the send: `200`, `woke 1`; the wait: `200`, `hi`; a wait with no send for 30 s: `504`; `/waiting` is how many wait |
| [upgrade.sps](upgrade.sps) | taking a connection over, with `make-upgrade-res` | `curl -i 127.0.0.1:8080/` | HTTP/1.1 with `Connection: upgrade` and `Upgrade: echo`: `101`, then each byte sent comes back; `Upgrade: echo` without `Connection: upgrade`, or over HTTP/1.0: the server's `500`, logged `invalid-response not-an-upgrade`; no `Upgrade: echo`: `200`, `text/plain`, `ask for Upgrade: echo` |
| [middleware.sps](middleware.sps) | a catch, a timeout of 1 s and a log, composed | `curl -i '127.0.0.1:8080/slow?ms=1500'` | `/`: `200`, `hello`; `/slow?ms=N`: `200`, `waited N ms`, or past 1 s an empty `504`; `/boom`: an empty `500`. Each request logs a line, `request GET /slow 504 written 1001 127.0.0.1`, and `/boom` first `handler-failed Exception in app: boom` |
| [websocket.sps](websocket.sps) | a WebSocket echo, with `websocket-res` | `printf hi \| curl -s --max-time 1 -T - ws://127.0.0.1:8080/echo`, with curl 8.11 or later; or, to type messages, `websocat ws://127.0.0.1:8080/echo` | `/echo`: `101`, then each message back as it came: curl sends `hi` as one binary message, prints the `hi` that comes back, and waits until `--max-time`; `/echo` with no handshake: an empty `400`; a handshake from another site's page: an empty `403`, the connection closed; any other path: `404`, `text/plain`, `open a WebSocket to /echo` |
| [router.sps](router.sps) | routes by path, then method, with `(circuit router)` | `curl -i 127.0.0.1:8080/users/42` | `/`: `200`, `home`; `/users`: `200`, `ann` and `bob`, a line each; `POST /users` with the body `cat`: `201`, `created cat`; `/users/new`: `200`, `the new user form`, the word beating `/users/:id`; `/users/42`: `200`, `user 42`, and `/users/a%20b` `user a b`; `/admin/stats`: `200`, `2 users`, with `x-admin: yes` from the group's middleware; `/files/a/b`: `200`, `file /a/b, mounted at /files`, and `/files` `file /, mounted at /files`; any other path: an empty `404`; `DELETE /users/new`: an empty `405`, `allow: GET, HEAD` |

hello and echo answer any request, and upgrade any request with no
`Upgrade: echo`. stream, long-poll, middleware and websocket answer any other `404`,
with a hint, and router an empty one.

`tests/test-examples.sps` runs each one and checks what it answers.
