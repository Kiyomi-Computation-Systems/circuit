Title: Ship a supported way to test a handler that waits, without a socket
Drafted: 2026-10-25, not filed

**The problem**

A handler that doesn't wait is tested by calling it. One that waits can't
be: `await`, `sleep-ms`, `with-deadline` and `resolve` work only on the
coroutine of a handler that answered `awaiting`, so testing one needs a
host. That host can be the real server, over loopback, with real time. Or
it can be the fake shell, `tests/fake-shell.sls`, which has everything
such a test wants:
- the real core and parser, with no I/O;
- a fake clock, advanced by the test, which fires sleeps and deadlines;
- a scripted resolver;
- body pieces delivered on credit;
- the bytes the client would read.

But the fake shell isn't a supported library, at v0.8.0 (a996eef):

- **It isn't installed.** It lives under `tests/`, which the Akku package
  leaves out (`Akku.manifest:4`, `.akkuignore:6`). A project that wants it
  vendors the server's whole checkout, as chez-websocket and circuit do.
- **Its surface is the core's.** It is driven with the core's events and
  limits, and reads back actions and wire bytes: `make-fake-connection`,
  `fake-shell-feed-input!`, `fake-shell-advance!`, `fake-shell-fire-waits!`,
  `written-status`, `write-wire`. That surface fits the server's own suites.
  A handler's test wants a request in and a response out.
- **Nothing holds it stable.** It imports `(http-server private scheduler)`,
  `(http-server private waits)` and `(http-server private adapter)`, and
  `docs/reference.md` documents none of them. A test built on it can break
  at any release.

circuit, a Ring-like layer over the server, runs every app on a coroutine,
so its adapter, its timeout middleware, and any app that waits can only be
tested through such a host. Ring has ring-mock, Rack has
`Rack::MockRequest`, Werkzeug has its test `Client`, and Go has
`httptest`.

**What you propose**

A supported library, for example `(http-server testing)`, installed with
the server and documented. It would run a handler against scripted
requests, its waits included, with no socket and no real time. The details
are the server's to decide. These are what circuit's tests would use:

- **a host for a handler**, made with the handler and, optionally, an
  environment procedure for the settings, as `serve` takes;
- **a request sent**, as bytes on the wire (so a test can send a malformed
  or pipelined one), with a body that can come in pieces, sent at once or
  later;
- **the fake clock advanced** by so many milliseconds, firing the sleeps
  and deadlines that come due;
- **a lookup answered**, with addresses or an error, for `resolve`;
- **the client leaving**, closed or reset, while the handler waits;
- **what the client read**: each response's status, headers and body,
  parsed, and the raw bytes beside them, and whether the connection
  closed;
- **what the server logged**, such as `handler-failed` or `late-resume`;
- **a run that ends**: a handler still waiting when nothing more is
  scripted is reported, never left to hang.

The fake shell's harness would stay the server's own, with this library
over it.

**What the RFCs say**

No wire change.

**Meanwhile**

circuit's tests reach into the vendored checkout's `tests/fake-shell.sls`,
as chez-websocket's do, and run the adapter over loopback with curl for the
rest. That ties circuit's suites to the server's private libraries, which
can change at any release.
