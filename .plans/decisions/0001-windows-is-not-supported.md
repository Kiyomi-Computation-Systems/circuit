# ADR-0001: Windows is not supported

- **Status:** Accepted
- **Date:** 2026-10-25
- **Scope:** circuit, until a later decision record reverses this one
- **Related:** chez-curl ADR-0004, which made the same call for its own reasons

## Context

Circuit's adapter runs on chez-http-server, and the server doesn't support
Windows: its `docs/installing.md` says it runs on macOS and Linux, on x86-64
and arm64. Circuit's pure core would run anywhere Chez does, but an app
needs a server to be served.

## Decision

**Windows is not supported.** Circuit doesn't test it, and spends no design
effort keeping it possible: no Windows code paths, no Windows CI.

## Consequences

- **The supported platforms are Linux and macOS, on amd64 and arm64**, the
  server's.
- **Assumptions that hold only off Windows need no flag**, such as POSIX
  paths in the build and the scripts.
- **Reversing this takes its own decision record**, and the server must
  support Windows first.
