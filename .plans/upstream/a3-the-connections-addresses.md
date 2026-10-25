Title: Give a request the addresses of the connection it came on
Drafted: 2026-10-25, not filed

**The problem**

A request doesn't carry the peer's address, and that was chosen on
purpose. `docs/deploying.md:45` says: "A request does not carry the peer's
address; behind a proxy it would be the proxy's anyway. Read
`X-Forwarded-For` …, and trust it only from your own proxy."

The guide's own advice needs the address it leaves out. To trust
`X-Forwarded-For` only from your own proxy, a handler has to know who sent
the request, and the field is a list anyone can write. So the peer's
address matters whenever the proxy isn't the only one who can reach the
server:

- **In a container.** The guide says to listen on `0.0.0.0` there
  (`docs/deploying.md:63`, `docs/configuration.md:25`), so anything on the
  container's network can connect, and send any `X-Forwarded-For` it
  likes.
- **With no proxy.** An internal service, a development server, or a
  health check.
- **To log, or to rate-limit, by peer.** Behind a proxy the peer is the
  proxy, which is exactly the address the trust check compares.

The local address answers the other half: which of the host's addresses,
and which port, the request came in on. A server listening on `0.0.0.0`
can't otherwise tell.

Ring's request has `:remote-addr`, `:server-name` and `:server-port`;
Rack's env and WSGI's environ have `REMOTE_ADDR` and `SERVER_PORT`.
circuit, a Ring-like layer over the server, has `req-remote-address`, which
answers `#f` today.

**What you propose**

Four accessors, exported by the facade, each answering `#f` when the
server can't say:

- `request-remote-address : Request -> (U String #f)`, as text: `"::1"`,
  `"192.0.2.7"`;
- `request-remote-port : Request -> (U Nat #f)`;
- `request-local-address : Request -> (U String #f)`;
- `request-local-port : Request -> (U Nat #f)`.

They describe the connection, so every request on a kept-alive connection
answers the same. chez-libuv already gives both ends,
`uv-tcp-peer-address` and `uv-tcp-sockname-address`, at the version the
server pins (chez-libuv's `docs/reference.md:431` and `:441`). The server
could read them once, when it accepts the connection (`accept!`,
`src/http-server/private/shell.sls:529`, at v0.8.0, a996eef), so a request
costs nothing more. The details are the server's to decide, including
whether the core's requests hold the addresses or the shell hands them
over.

The guide's line would then read: trust `X-Forwarded-For` only when
`request-remote-address` is your proxy's.

**What the RFCs say**

No wire change. RFC 7239 (the `Forwarded` field, which `X-Forwarded-For`
came before) leaves the recipient to decide whom to trust (§8.1), and that
decision needs the address that sent it.

**Meanwhile**

circuit's `req-remote-address` answers `#f`, so middleware that trusts
`X-Forwarded-For` can't check who sent it. An app behind a proxy on the
same host, with the server listening on `127.0.0.1`, as the guide's first
example has it, is safe, since only the host's own processes can connect.
