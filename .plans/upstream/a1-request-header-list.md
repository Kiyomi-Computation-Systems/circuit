Title: List a request's headers: request-header-list
Filed: chez-http-server #214, 2026-10-25

**The problem**

A handler can read a header it knows the name of (`request-header`,
`request-header-values`) but can't list them. A handler that logs requests,
proxies them, or hands them on as a map can't see a field it doesn't
already know by name.

circuit, a Ring-like layer over the server, builds a headers list for every
request it hands an app. At v0.8.0 (a996eef) the only way is to reach past
the facade: `request-headers` from `(http-server request)`, which answers
spans, with `(http-server span)` to read them and `(http-server headers)`'s
`trim-ows` to trim the values as `request-header` does. `docs/reference.md`
documents none of those three libraries, so nothing holds them stable
between releases.

**What you propose**

`request-header-list : Request -> (Listof (Pair String String))`, in
`(http-server view)` and exported by the facade:

- every field line of the head, in the order it arrived;
- the name as sent, a character per byte, as the other accessors read;
- the value as `request-header` gives it: without the OWS around it
  (`field-value`, `src/http-server/view.sls:120`);
- a name that comes on several lines comes as several pairs, as
  `request-header-values` keeps them;
- made when asked, like the other accessors, so a handler that doesn't ask
  pays nothing.

It would sit beside `request-header-values` (`view.sls:93`): a `map` over
`(request-headers r)` with `field-value` for the value and the same Latin-1
read for the name. A row in `docs/handlers.md`'s table and in
`docs/reference.md`.

The name is the third of the family `request-header`,
`request-header-values`, `request-header-list`. Not `request-headers`:
`(http-server request)` already exports that name, with spans.

**What the RFCs say**

No wire change. RFC 9110 §5.1 makes field names case-insensitive, so names
come as sent and a caller folds case itself. §5.3 keeps the order of field
lines with the same name significant, which this list keeps. Trailers aren't
part of the request today, and wouldn't be here.

**Meanwhile**

circuit carries the workaround above, with a probe that goes red when the
facade exports `request-header-list`, and another that goes red when the
three libraries it reaches into change shape.
