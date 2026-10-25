Title: Export the request's HTTP version from the facade
Filed: chez-http-server #215, 2026-10-25

**The problem**

The request record holds the HTTP version, `request-http-major` and
`request-http-minor` in `(http-server request)`, but the facade exports
neither, and `docs/reference.md` doesn't name them. A handler that logs
requests, or a layer that hands the version on, as Ring's `:protocol` does,
has to import a library the docs don't cover.

circuit, a Ring-like layer over the server, gives its apps
`req-http-version`. At v0.8.0 (a996eef) it imports the two accessors from
`(http-server request)` directly.

**What you propose**

Export `request-http-major` and `request-http-minor` from `(http-server)`,
each `Request -> Nat`, and document them in `docs/handlers.md` and
`docs/reference.md`. They are already the record's own accessors, so this
adds no code.

The docs should say which version they answer: the one the client sent. A
request in HTTP/1.2 to 1.9 records its own minor and is served as 1.1
(`src/http-server/connection.sls:98`, and the record is built at `:1760` from
the parser's numbers). "The version the request names; the server answers
any 1.x past 1.1 as 1.1" covers it.

**What the RFCs say**

No wire change. RFC 9110 §2.5 and RFC 9112 §2.3 define the version a
request names.

**Meanwhile**

circuit imports `(only (http-server request) request-http-major
request-http-minor)`, with a probe that goes red when the facade exports
them.
