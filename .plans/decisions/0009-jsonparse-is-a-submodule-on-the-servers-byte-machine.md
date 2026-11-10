# ADR-0009: jsonparse is a submodule, on the server's byte-machine

- **Status:** Accepted, 2026-11-10, in slice 11, which brings it in; the owner chose
  jsonparse, its pin and its packaging, and answered the design's questions the same day
  (design §15.36)
- **Date:** 2026-11-10
- **Scope:** reading a JSON body for `(circuit json)`, and how jsonparse and the
  byte-machine it runs on reach the build, the container, CI and an app
- **Related:** [ADR-0003](0003-chez-http-server-is-a-submodule-pinned-at-a-release-tag.md),
  [ADR-0006](0006-only-the-adapter-and-middleware-waits-import-the-server.md),
  [ADR-0008](0008-hashing-from-akku-is-the-first-runtime-dependency.md)

## Context

A JSON body needs a JSON parser, which neither R6RS nor Chez has. jsonparse, the
organisation's own, is strict (RFC 8259) and portable R6RS: its libraries import
`(rnrs)`, each other, and `(byte-machine runtime)`, whose own imports are `(rnrs)` and
two private libraries of its own. Its `read-json` reads a binary port 16 KiB at a time,
parsing each 16 KiB, or the body's last bytes, once they are in, and stops at the first
16 KiB that holds a bad byte. On a request's coroutine, a read that waits parks that
request alone, and a body that isn't JSON is refused once the 16 KiB holding its first
bad byte is in, not at that byte. It bounds what it builds: 512 containers open at once
and 1,000 digits a number, by default.

jsonparse isn't on the Akku index. It pins byte-machine as a submodule, as chez-httparse
does under the server, and a library path that held two byte-machines would load
whichever came first for both. jsonparse v0.1.0 (`a939f31`) was built on byte-machine
v0.8.0 (`c1f7791`), the commit chez-http-server v0.10.0 carries through chez-httparse
v0.5.0. The organisation's libraries are moving to byte-machine 0.9.0, a server release
after the others, and jsonparse's next release is on 0.9.0 too.

## Decision

1. **jsonparse is a submodule at `vendor/jsonparse`, pinned at a release tag,** v0.1.0
   (`a939f31`), as the server and chez-websocket are (ADR-0003, item 8).
   `JSONPARSE_PIN` names the same commit.
2. **Its `src/` is on the library path; its `vendor/` is not.** `make submodules` clones
   jsonparse alone, not its byte-machine or chez-srfi, so the path holds one
   byte-machine, the server's under chez-httparse. jsonparse's gitlink for byte-machine
   must equal the one chez-httparse records: `make check-pins` holds that. And
   `make check-imports` holds that no other directory on the path holds a `jsonparse`,
   a `generated/jsonparse` or a `byte-machine` (its rule (p)).
3. **Only `(circuit json)` imports it, only `(jsonparse easy)`, through `only`.**
   `make check-imports` holds that (its rule (n)), and reads `(jsonparse easy)`'s closure,
   as Chez resolves it from byte-machine's `src/` and jsonparse's, in the library path's
   order: it imports
   `(rnrs ...)` but `(rnrs eval)`, jsonparse's own libraries, `(generated jsonparse)`,
   and byte-machine's runtime and its two private libraries, alone (rule (o))
   (ADR-0006, amended). So the core stays plain R6RS.
4. **jsonparse's pin moves with the byte-machine under it.** A move of the server that
   moves chez-httparse's byte-machine moves `JSONPARSE_PIN` on the same commit, to a
   jsonparse release on that byte-machine, or `make check-pins` fails. A move is tried
   first: circuit's suites pass on the pair before it lands.

## Consequences

- **circuit runs jsonparse on every JSON body `wrap-json-body` reads.** Its input is
  bounded by the cap `wrap-json-body` requires, and its tree by its depth and digit
  limits. The owner measured its tree builder at 33 to 200 MB/s, on the owner's NUC.
- **The next server release on byte-machine 0.9.0 waits for jsonparse's on it too,**
  and the reverse: circuit can't take either alone.
- **An app working from a checkout runs `make submodules`,** as it does for the server.
  Circuit can't be published on Akku while jsonparse isn't on the index, as it can't
  while the server isn't.
