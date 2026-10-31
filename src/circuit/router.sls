#!r6rs
;;; (circuit router): a table of routes, compiled once into one handler.
;;;
;;;   (make-router
;;;     (list (route "/users"     (GET list-users) (POST create-user))
;;;           (route "/users/new" (GET new-user-form))
;;;           (route "/users/:id" 'user (GET show-user) (DELETE delete-user))
;;;           (group "/admin" (list wrap-admin)
;;;             (route "/stats" (GET stats)))
;;;           (mount "/assets" assets)))
;;;
;;; A template splits at / into segments: a word, matched exactly; a
;;; parameter, :name, which takes one segment that isn't empty; or a
;;; catch-all, *name, last, which takes the rest after the slash before it,
;;; slashes kept, possibly empty. A mount takes its path and every path
;;; under it, and its handler sees the rest of the path.
;;;
;;; The path is matched as the client sent it, undecoded. Among the
;;; templates that match it, the leftmost segment where they differ
;;; decides: a word beats a parameter, which beats a catch-all or a mount;
;;; a template that ends where the path does beats a mount taking nothing.
;;; So the order of the table never matters, and make-router refuses two
;;; templates of one shape. The captures are then percent-decoded as
;;; UTF-8, and one that doesn't decode is a 400: a malformed escape, bytes
;;; that aren't UTF-8, or a raw character a path can't hold, past ASCII or
;;; outside RFC 3986's pchar (and / in a catch-all). A mount's rest is no
;;; capture, and isn't checked. Then the method picks the handler: HEAD
;;; goes to the route's own HEAD, else its GET, else its ANY, and a method
;;; the route can't take is a 405 with its Allow. No route for the path
;;; runs the not-found handler.
;;;
;;; The app may answer the 404, the 400 and the 405 itself, through
;;; make-router's options, in any order: (on-not-found h), or h bare,
;;; (on-bad-request h) and (on-method-not-allowed h). The 404's and the
;;; 400's handler gets the request as it came to the router; the 405's gets
;;; it with the route's match on it, and when it answers a 405 the router
;;; sets Allow on it, as RFC 9110 requires. Any other answer goes on as it
;;; is, so a 405 handler may answer a 404 that hides the route. A
;;; constructor given bare among the options, such as on-bad-request with
;;; no handler, is refused. An answer left to the router is made once,
;;; not at each request: the empty 404 and 400 here, each route's empty 405
;;; when the router is made.
;;;
;;; The match goes on the request with one req-set, under this library's
;;; key: the template, the params, and the nearest mount the request is
;;; under. A router joins its template and params onto that mount's, so a
;;; router under a mount, even through a route under it, reads the whole
;;; template; one with no mount above it uses its own alone. A mount's
;;; match keeps the path it matched and where its rest begins:
;;; req-mount-path builds the part the mounts took from those only when it
;;; is called. So wherever a middleware or a handler stands, req-mount-path
;;; then req-path is the path as the server read it, unless a middleware
;;; rewrote the path, or where a mount's rest is the / that stands for
;;; nothing after it.
;;;
;;; A group's middleware around a mount sees what it sees around a route:
;;; the path as the router matched it, req-route and req-path-params the
;;; mount's, and req-mount-path the part the mounts above that router took,
;;; not counting the mount it wraps. Only the mount's handler sees the rest
;;; of the path, and the mount's part in req-mount-path. For that a mount
;;; that a group's middleware wraps hands the middleware its match behind a
;;; marker, and sets it with a second req-set inside: about 96 B a request
;;; more. A mount no middleware wraps sets its match once. A request the
;;; middleware hands on without the marker, one it made or one a router of
;;; its own matched, reaches the mount's handler as it is, as it would a
;;; route's.
;;;
;;; A route's name, the symbol after its template, is kept for reverse
;;; routing, which nothing reads yet.
;;;
;;; A decoded value is the client's: it can hold / (from %2F), .. and NUL
;;; (from %00), and the server passes dot segments through as sent, so
;;; /f/../../etc/passwd reaches /f/*p with p ../../etc/passwd. Check a
;;; decoded value, not req-path, before using one as a file name.
;;;
;;; req-route's template and the names in req-path-params are the router's
;;; own strings, shared by every request it routes: don't mutate them.
;;;
;;; It is not in the (circuit) facade: an app imports it beside (circuit).
(library (circuit router)
  (export make-router on-not-found on-bad-request on-method-not-allowed
          route GET POST PUT PATCH DELETE OPTIONS ANY METHOD group mount
          req-path-param req-path-params req-route req-mount-path)
  (import (rnrs) (rnrs mutable-strings)
          (only (circuit request)
                req? req-method req-path req-ref req-set req-with-path make-req-key)
          (only (circuit response) make-res res? res-status res-set-header)
          (only (circuit middleware) wrap))

  ;; Handler = Req -> Res
  ;; Middleware = Handler -> Handler
  ;; Route = what route, group and mount make
  ;; MethodEntry = what GET, POST, PUT, PATCH, DELETE, OPTIONS, ANY and METHOD make
  ;; RouterOption = what on-not-found, on-bad-request and on-method-not-allowed make,
  ;;   or a Handler, which stands for (on-not-found it)
  ;; Params = (Listof (Pair String String))

  ;; --- the table's parts ------------------------------------------------------

  ;; A method entry: the method, as the symbol a request names it by, ANY
  ;; for every method its route doesn't list, and its handler.
  (define-record-type (entry make-entry entry?)
    (fields method handler)
    (sealed #t)
    (opaque #t))

  ;; Segment = (U String Param CatchAll): a word, possibly empty, or a
  ;; parameter or a catch-all, with its name.
  (define-record-type (param make-param param?)
    (fields name)
    (sealed #t))

  (define-record-type (catch-all make-catch-all catch-all?)
    (fields name)
    (sealed #t))

  ;; A route: its template, its segments, its name or #f, and its entries,
  ;; in the order given.
  (define-record-type (route-item make-route-item route-item?)
    (fields template segments name entries)
    (sealed #t)
    (opaque #t))

  ;; A group: its prefix, its segments, its middlewares and its routes.
  (define-record-type (group-item make-group-item group-item?)
    (fields prefix segments middlewares items)
    (sealed #t)
    (opaque #t))

  ;; A mount: its template, its segments and its handler.
  (define-record-type (mount-item make-mount-item mount-item?)
    (fields template segments handler)
    (sealed #t)
    (opaque #t))

  (define (item? x) (or (route-item? x) (group-item? x) (mount-item? x)))

  ;; --- templates --------------------------------------------------------------

  ;; pchars : Bytevector
  ;; 1 at each ASCII code RFC 3986's pchar holds unescaped, but pct-encoded:
  ;; unreserved, sub-delims, : and @. What a path carries as it is.
  (define pchars
    (let ((table (make-bytevector 128 0)))
      (for-each (lambda (c) (bytevector-u8-set! table (char->integer c) 1))
                (string->list (string-append "abcdefghijklmnopqrstuvwxyz"
                                             "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                                             "0123456789-._~!$&'()*+,;=:@")))
      table))

  ;; word-char? : Char -> Boolean
  ;; RFC 3986's pchar, but pct-encoded: what a path carries unescaped.
  (define (word-char? c)
    (let ((b (char->integer c)))
      (and (< b 128) (= (bytevector-u8-ref pchars b) 1))))

  ;; raw-char? : Char -> Boolean
  ;; What a capture holds as it is: a word's character, or the / a
  ;; catch-all's rest keeps. A parameter's segment holds no /.
  (define (raw-char? c)
    (or (word-char? c) (char=? c #\/)))

  ;; name-char? : Char -> Boolean
  ;; What a parameter's or a catch-all's name holds: ASCII letters, digits,
  ;; - and _.
  (define (name-char? c)
    (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9)
        (char=? c #\-) (char=? c #\_)))

  ;; method-char? : Char -> Boolean
  ;; RFC 9110's tchar, but a lower-case letter: the server takes a method
  ;; in upper case, and answers 400 to one in lower case.
  (define (method-char? c)
    (or (char<=? #\A c #\Z) (char<=? #\0 c #\9)
        (memv c '(#\! #\# #\$ #\% #\& #\' #\* #\+ #\- #\. #\^ #\_ #\` #\| #\~))))

  ;; template-segments : Symbol Any -> (Listof Segment)
  ;; TEMPLATE's segments: "" has none, and one that begins with / splits at
  ;; each / after it, so "/" is one empty word. A template that is no
  ;; string, begins otherwise, or holds a segment that is no word,
  ;; parameter or catch-all is an assertion violation from WHO.
  (define (template-segments who template)
    (unless (string? template)
      (assertion-violation who "a template is a string" template))
    (let ((n (string-length template)))
      (cond ((= n 0) '())
            ((char=? (string-ref template 0) #\/)
             (let loop ((i 1) (acc '()))
               (let* ((e (segment-end template i n))
                      (segment (parse-segment who template (substring template i e))))
                 (if (= e n)
                     (reverse (cons segment acc))
                     (loop (+ e 1) (cons segment acc))))))
            (else (assertion-violation who "a template is \"\" or begins with /" template)))))

  ;; parse-segment : Symbol String String -> Segment
  ;; S, a segment of TEMPLATE: a word, but . or .., which a client removes
  ;; from its path (RFC 3986 §5.2.4), so no request could reach it; or a
  ;; parameter or a catch-all, its name one or more name characters.
  (define (parse-segment who template s)
    (define (named make)
      (let ((name (substring s 1 (string-length s))))
        (unless (and (> (string-length name) 0) (for-all name-char? (string->list name)))
          (assertion-violation who
                               "a parameter's or catch-all's name is ASCII letters, digits, - and _"
                               template s))
        (make name)))
    (cond ((= (string-length s) 0) s)
          ((char=? (string-ref s 0) #\:) (named make-param))
          ((char=? (string-ref s 0) #\*) (named make-catch-all))
          ((member s '("." ".."))
           (assertion-violation who "a word is no dot segment: a client removes . and .."
                                template s))
          ((for-all word-char? (string->list s)) s)
          (else
           (assertion-violation who "a word holds only pchar: what a path carries unescaped"
                                template s))))

  ;; segment-end : String Nat Nat -> Nat
  ;; Where the segment of S that starts at I ends: the next / before N, or N.
  (define (segment-end s i n)
    (cond ((= i n) n)
          ((char=? (string-ref s i) #\/) i)
          (else (segment-end s (+ i 1) n))))

  ;; --- the constructors ---------------------------------------------------------

  ;; GET POST PUT PATCH DELETE OPTIONS ANY : Handler -> MethodEntry
  ;; HANDLER for that method; ANY's takes every method its route doesn't
  ;; list. A HANDLER that is no procedure is an assertion violation.
  (define (GET handler) (method-entry 'GET 'GET handler))
  (define (POST handler) (method-entry 'POST 'POST handler))
  (define (PUT handler) (method-entry 'PUT 'PUT handler))
  (define (PATCH handler) (method-entry 'PATCH 'PATCH handler))
  (define (DELETE handler) (method-entry 'DELETE 'DELETE handler))
  (define (OPTIONS handler) (method-entry 'OPTIONS 'OPTIONS handler))
  (define (ANY handler) (method-entry 'ANY 'ANY handler))

  ;; METHOD : Symbol Handler -> MethodEntry
  ;; HANDLER for any method, HEAD among them: (METHOD 'PROPFIND h).
  ;; (METHOD 'GET h) is (GET h), and (METHOD 'ANY h) is (ANY h). A METHOD
  ;; that is no symbol, or whose name isn't one or more of RFC 9110's
  ;; tchar in upper case, is an assertion violation.
  (define (METHOD method handler)
    (unless (symbol? method)
      (assertion-violation 'METHOD "a method is a symbol" method))
    (let ((name (symbol->string method)))
      (unless (and (> (string-length name) 0) (for-all method-char? (string->list name)))
        (assertion-violation 'METHOD "a method's name is RFC 9110's tchar, in upper case" method)))
    (method-entry 'METHOD method handler))

  (define (method-entry who method handler)
    (unless (procedure? handler)
      (assertion-violation who "a handler is a procedure" handler))
    (make-entry method handler))

  ;; route : String [Symbol] MethodEntry ... -> Route
  ;; A route for TEMPLATE, "" or beginning with /, named by the symbol that
  ;; follows it, if one does, and taking the methods its entries name. No
  ;; entry, what is no entry, or two entries for one method is an assertion
  ;; violation, as is a bad template.
  (define (route template . rest)
    (let* ((segments (template-segments 'route template))
           (name (and (pair? rest) (symbol? (car rest)) (car rest)))
           (entries (if name (cdr rest) rest)))
      (for-each (lambda (x)
                  (unless (entry? x)
                    (assertion-violation 'route "not a method entry" x)))
                entries)
      (when (null? entries)
        (assertion-violation 'route "a route takes a method entry or more" template))
      (let loop ((entries entries) (seen '()))
        (unless (null? entries)
          (let ((method (entry-method (car entries))))
            (when (memq method seen)
              (assertion-violation 'route "a route takes one entry for a method" template method))
            (loop (cdr entries) (cons method seen)))))
      (make-route-item template segments name entries)))

  ;; group : String (Listof Middleware) Route ... -> Route
  ;; ROUTES under PREFIX, "" or beginning with /, each of their handlers
  ;; wrapped in MIDDLEWARES, in wrap's order, when the router is made. A
  ;; bad prefix, middlewares that are no list of procedures, or what is no
  ;; route is an assertion violation.
  (define (group prefix middlewares . items)
    (let ((segments (template-segments 'group prefix)))
      (unless (list? middlewares)
        (assertion-violation 'group "middlewares are a list" middlewares))
      (for-each (lambda (m)
                  (unless (procedure? m)
                    (assertion-violation 'group "a middleware is a procedure" m)))
                middlewares)
      (for-each (lambda (x)
                  (unless (item? x)
                    (assertion-violation 'group "not a route, a group or a mount" x)))
                items)
      (make-group-item prefix segments middlewares items)))

  ;; mount : String Handler -> Route
  ;; HANDLER for TEMPLATE, "" or beginning with /, and every path under it,
  ;; whatever the method. HANDLER sees the path's rest. A bad template, or
  ;; a HANDLER that is no procedure, is an assertion violation.
  (define (mount template handler)
    (let ((segments (template-segments 'mount template)))
      (unless (procedure? handler)
        (assertion-violation 'mount "a handler is a procedure" handler))
      (make-mount-item template segments handler)))

  ;; An option of make-router's: the answer its handler gives, by the name
  ;; of the constructor that made it, and the handler.
  (define-record-type (option make-option option?)
    (fields answer handler)
    (sealed #t)
    (opaque #t))

  ;; on-not-found : Handler -> RouterOption
  ;; HANDLER for a path no route takes, handed the request as it came to
  ;; the router. A HANDLER that is no procedure is an assertion violation.
  (define (on-not-found handler) (router-option 'on-not-found handler))

  ;; on-bad-request : Handler -> RouterOption
  ;; HANDLER for a capture that doesn't decode, the router's 400, handed
  ;; the request as it came to the router. A HANDLER that is no procedure
  ;; is an assertion violation.
  (define (on-bad-request handler) (router-option 'on-bad-request handler))

  ;; on-method-not-allowed : Handler -> RouterOption
  ;; HANDLER for a method its route doesn't take, the router's 405, handed
  ;; the request with the route's match on it. When it answers a 405, the
  ;; router sets Allow on it, replacing any it set; any other answer goes on
  ;; as it is. A HANDLER that is no procedure is an assertion violation.
  (define (on-method-not-allowed handler) (router-option 'on-method-not-allowed handler))

  (define (router-option who handler)
    (unless (procedure? handler)
      (assertion-violation who "a handler is a procedure" handler))
    (make-option who handler))

  ;; --- make-router: the checks ----------------------------------------------

  ;; option-handlers : (Listof Any) -> (List (U Handler #f) (U Handler #f) (U Handler #f))
  ;; The not-found, 400 and 405 handlers the options give, #f where none does.
  ;; A procedure stands for (on-not-found it), but one of the option
  ;; constructors themselves, given bare where its option was meant. That,
  ;; what is neither an option nor a procedure, or two options for one
  ;; answer, is an assertion violation.
  (define (option-handlers options)
    (let loop ((options options) (not-found #f) (bad-request #f) (not-allowed #f))
      (if (null? options)
          (list not-found bad-request not-allowed)
          (let* ((x (car options))
                 (answer (cond ((option? x) (option-answer x))
                               ((constructor-name x)
                                => (lambda (name)
                                     (assertion-violation
                                      'make-router
                                      (string-append "an option's constructor is no handler: call it"
                                                     " with one, as (" (symbol->string name)
                                                     " handler)")
                                      name)))
                               ((procedure? x) 'on-not-found)
                               (else (assertion-violation
                                      'make-router
                                      (string-append "an option is what on-not-found, on-bad-request"
                                                     " or on-method-not-allowed makes, or a not-found"
                                                     " handler")
                                      x))))
                 (handler (if (option? x) (option-handler x) x))
                 (given (case answer
                          ((on-not-found) not-found)
                          ((on-bad-request) bad-request)
                          (else not-allowed))))
            (when given
              (assertion-violation 'make-router "one option for each answer" answer))
            (case answer
              ((on-not-found) (loop (cdr options) handler bad-request not-allowed))
              ((on-bad-request) (loop (cdr options) not-found handler not-allowed))
              (else (loop (cdr options) not-found bad-request handler)))))))

  ;; constructor-name : Any -> (U Symbol #f)
  ;; The name of the option constructor X is, or #f.
  (define (constructor-name x)
    (cond ((eq? x on-not-found) 'on-not-found)
          ((eq? x on-bad-request) 'on-bad-request)
          ((eq? x on-method-not-allowed) 'on-method-not-allowed)
          (else #f)))

  ;; One route or mount of the table: its template and segments, joined with
  ;; its groups', and its groups' middleware lists, innermost first.
  (define-record-type (flat make-flat flat?)
    (fields item template segments stacks)
    (sealed #t))

  (define (flat-mount? f) (mount-item? (flat-item f)))

  ;; flatten : (Listof Route) String (Listof Segment) (Listof (Listof Middleware))
  ;;           (Listof Flat) -> (Listof Flat)
  ;; ITEMS under PREFIX, its SEGMENTS and its STACKS, onto ACC, newest first.
  (define (flatten items prefix segments stacks acc)
    (fold-left
     (lambda (acc item)
       (cond ((route-item? item)
              (cons (make-flat item (string-append prefix (route-item-template item))
                               (append segments (route-item-segments item)) stacks)
                    acc))
             ((mount-item? item)
              (cons (make-flat item (string-append prefix (mount-item-template item))
                               (append segments (mount-item-segments item)) stacks)
                    acc))
             (else
              (flatten (group-item-items item)
                       (string-append prefix (group-item-prefix item))
                       (append segments (group-item-segments item))
                       (cons (group-item-middlewares item) stacks)
                       acc))))
     acc items))

  (define (segment-name s)
    (cond ((param? s) (param-name s))
          ((catch-all? s) (catch-all-name s))
          (else #f)))

  (define (empty-word? s) (and (string? s) (= (string-length s) 0)))

  ;; check-joined : Flat -> Void
  ;; F's joined template begins with /; an empty segment and a catch-all
  ;; come only last; a name comes once. A mount's has no catch-all and
  ;; doesn't end in /, so it isn't / alone.
  (define (check-joined f)
    (let ((template (flat-template f)))
      (unless (and (> (string-length template) 0) (char=? (string-ref template 0) #\/))
        (assertion-violation 'make-router "a joined template begins with /" template))
      (let loop ((segments (flat-segments f)) (names '()))
        (unless (null? segments)
          (let ((s (car segments))
                (last? (null? (cdr segments))))
            (when (and (empty-word? s) (not last?))
              (assertion-violation 'make-router "an empty segment comes only last" template))
            (when (and (catch-all? s) (not last?))
              (assertion-violation 'make-router "a catch-all comes only last" template))
            (let ((name (segment-name s)))
              (when (and name (member name names))
                (assertion-violation 'make-router "a name comes once in a template" template name))
              (loop (cdr segments) (if name (cons name names) names))))))
      (when (flat-mount? f)
        (when (exists catch-all? (flat-segments f))
          (assertion-violation 'make-router
                               "a mount takes the rest itself, so its template has no catch-all"
                               template))
        (when (empty-word? (car (reverse (flat-segments f))))
          (assertion-violation 'make-router
                               (string-append "a mount's template doesn't end in /, and isn't /"
                                              " alone: the not-found handler takes every path")
                               template)))))

  ;; Shape = (Listof (U String 'param 'rest))
  ;; shape : Flat -> Shape
  ;; F's segments, words as they are, parameters as param, and a catch-all,
  ;; or a mount's rest after its segments, as rest. Two templates of one
  ;; shape take the same paths at one rank.
  (define (shape f)
    (let ((segments (map (lambda (s)
                           (cond ((string? s) s) ((param? s) 'param) (else 'rest)))
                         (flat-segments f))))
      (if (flat-mount? f) (append segments '(rest)) segments)))

  ;; check-shapes : (Listof Flat) -> Void
  (define (check-shapes flats)
    (let ((seen (make-hashtable equal-hash equal?)))
      (for-each (lambda (f)
                  (let* ((s (shape f))
                         (earlier (hashtable-ref seen s #f)))
                    (when earlier
                      (assertion-violation 'make-router
                                           "two templates of one shape take the same paths"
                                           earlier (flat-template f)))
                    (hashtable-set! seen s (flat-template f))))
                flats)))

  ;; check-names : (Listof Flat) -> Void
  (define (check-names flats)
    (let ((seen (make-eq-hashtable)))
      (for-each (lambda (f)
                  (let ((name (and (route-item? (flat-item f))
                                   (route-item-name (flat-item f)))))
                    (when name
                      (let ((earlier (hashtable-ref seen name #f)))
                        (when earlier
                          (assertion-violation 'make-router "two routes have one name"
                                               name earlier (flat-template f)))
                        (hashtable-set! seen name (flat-template f))))))
                flats)))

  ;; --- make-router: the compiled table ----------------------------------------

  ;; The match, on the request under match-key: the template and the
  ;; params, each joined onto the nearest mount's, and that mount's match,
  ;; or #f under none.
  (define-record-type (match make-match match?)
    (fields template params under)
    (opaque #t))

  ;; A mount's match: a match, its under the mount above it, and the path
  ;; the mount matched and where its rest begins, at the slash, or the
  ;; path's end.
  (define-record-type (mount-match make-mount-match mount-match?)
    (parent match)
    (fields path cut)
    (sealed #t))

  ;; A mount's match as the group's middleware around the mount sees it,
  ;; before the mount takes its part: req-route and req-path-params read
  ;; the match, and req-mount-path the mounts above it.
  (define-record-type (ahead make-ahead ahead?)
    (fields match)
    (sealed #t)
    (opaque #t))

  (define match-key (make-req-key 'circuit-router))

  ;; A route as matched: its joined template; its segments as capture reads
  ;; them, a word as itself, a parameter as param, a catch-all as rest; its
  ;; names, left to right; its match, made once when it captures nothing;
  ;; its methods and their handlers, wrapped, as listed; the handler HEAD
  ;; gets; ANY's; its Allow and its empty 405 with it, each #f with ANY; and
  ;; its name.
  (define-record-type (leaf make-leaf leaf?)
    (fields template captures names match entries head any allow refusal name)
    (sealed #t))

  ;; A mount as matched: its joined template; its segments as capture reads
  ;; them; its names; how many segments it takes; whether a group's
  ;; middleware wraps it; and its handler, made to see the rest of the
  ;; path, then wrapped.
  (define-record-type (mount-leaf make-mount-leaf mount-leaf?)
    (fields template captures names depth wrapped? handler)
    (sealed #t))

  ;; A trie node: its word children, (String . Node), its parameter child,
  ;; the route that ends here, and the catch-all or mount that takes the
  ;; rest from here.
  (define-record-type (node %make-node node?)
    (fields (mutable words node-words node-words-set!)
            (mutable param node-param node-param-set!)
            (mutable end node-end node-end-set!)
            (mutable rest node-rest node-rest-set!))
    (sealed #t))

  (define (make-node) (%make-node '() #f #f #f))

  ;; insert! : Node Shape (U Leaf MountLeaf) -> Void
  ;; LEAF at SHAPE's place under ROOT. The shapes were checked distinct.
  (define (insert! root shape leaf)
    (let loop ((n root) (shape shape))
      (cond ((null? shape) (node-end-set! n leaf))
            ((eq? (car shape) 'rest) (node-rest-set! n leaf))
            ((eq? (car shape) 'param)
             (loop (or (node-param n)
                       (let ((child (make-node))) (node-param-set! n child) child))
                   (cdr shape)))
            (else
             (loop (cond ((assoc (car shape) (node-words n)) => cdr)
                         (else (let ((child (make-node)))
                                 (node-words-set! n (append (node-words n)
                                                            (list (cons (car shape) child))))
                                 child)))
                   (cdr shape))))))

  ;; wrapped : Handler (Listof (Listof Middleware)) -> Handler
  ;; HANDLER in each group's middlewares, innermost group first, each list
  ;; in wrap's order.
  (define (wrapped handler stacks)
    (fold-left (lambda (h middlewares) (apply wrap h middlewares)) handler stacks))

  (define (captures-of f)
    (map (lambda (s) (cond ((string? s) s) ((param? s) 'param) (else 'rest)))
         (flat-segments f)))

  (define (names-of f)
    (fold-right (lambda (s acc) (let ((name (segment-name s))) (if name (cons name acc) acc)))
                '() (flat-segments f)))

  ;; allow : (Listof Symbol) -> String
  ;; METHODS as listed, joined by ", ", HEAD right after GET when METHODS
  ;; has no HEAD of its own.
  (define (allow methods)
    (let ((names (fold-right (lambda (m acc)
                               (if (and (eq? m 'GET) (not (memq 'HEAD methods)))
                                   (cons "GET" (cons "HEAD" acc))
                                   (cons (symbol->string m) acc)))
                             '() methods)))
      (fold-left (lambda (joined name) (string-append joined ", " name))
                 (car names) (cdr names))))

  ;; leaf-of : Flat -> (U Leaf MountLeaf)
  ;; F as matched, its handlers wrapped in its groups' middlewares, each
  ;; once, in the table's order.
  (define (leaf-of f)
    (let* ((item (flat-item f))
           (template (flat-template f))
           (names (names-of f)))
      (if (mount-item? item)
          (let ((wraps? (exists pair? (flat-stacks f))))
            (make-mount-leaf template (captures-of f) names
                             (length (flat-segments f))
                             wraps?
                             (if wraps?
                                 (wrapped (entering (mount-item-handler item)) (flat-stacks f))
                                 (cutting (mount-item-handler item)))))
          (let* ((entries (let loop ((es (route-item-entries item)) (acc '()))
                            (if (null? es)
                                (reverse acc)
                                (let ((e (car es)))
                                  (loop (cdr es)
                                        (cons (cons (entry-method e)
                                                    (wrapped (entry-handler e) (flat-stacks f)))
                                              acc))))))
                 (any (cond ((assq 'ANY entries) => cdr) (else #f)))
                 (head (cond ((assq 'HEAD entries) => cdr)
                             ((assq 'GET entries) => cdr)
                             (else any)))
                 (allowed (and (not any) (allow (map car entries)))))
            (make-leaf template (captures-of f) names
                       (and (null? names) (make-match template '() #f))
                       entries head any allowed
                       (and allowed (make-res 405 (list (cons "allow" allowed)) #f))
                       (route-item-name item))))))

  (define not-found-res (make-res 404 '() #f))
  (define bad-request-res (make-res 400 '() #f))
  (define (default-not-found req) not-found-res)

  ;; make-router : (Listof Route) RouterOption ... -> Handler
  ;; A handler for ROUTES, compiled once, here: each route's handlers and
  ;; each mount's wrapped in their groups' middlewares. A request no route
  ;; takes goes to the not-found handler, by default an empty 404; a
  ;; capture that doesn't decode to the 400 handler, by default an empty
  ;; 400; a method its route doesn't take to the 405 handler, by default an
  ;; empty 405, and Allow on any 405. The options after ROUTES give those
  ;; handlers, in any order. Routes that are no list of routes, an option
  ;; that is no option nor procedure, an option constructor given bare,
  ;; two options for one answer, a joined template that breaks a
  ;; template's rules, two templates of one shape, or two routes of one
  ;; name are each an assertion violation, checked before any middleware is
  ;; applied.
  (define (make-router items . options)
    (unless (list? items)
      (assertion-violation 'make-router "routes are a list" items))
    (for-each (lambda (x)
                (unless (item? x)
                  (assertion-violation 'make-router "not a route, a group or a mount" x)))
              items)
    (let* ((handlers (option-handlers options))
           (not-found (or (car handlers) default-not-found))
           (bad-request (cadr handlers))
           (not-allowed (caddr handlers))
           (flats (reverse (flatten items "" '() '() '())))
           (root (make-node)))
      (for-each check-joined flats)
      (check-shapes flats)
      (check-names flats)
      (for-each (lambda (f) (insert! root (shape f) (leaf-of f))) flats)
      (lambda (req)
        (let* ((path (req-path req))
               (n (string-length path))
               (found (and (> n 0) (char=? (string-ref path 0) #\/)
                           (walk root path n 1))))
          (cond ((not found) (not-found req))
                ((leaf? found) (serve-route found req path n bad-request not-allowed))
                (else (serve-mount found req path n bad-request)))))))

  ;; --- a request ---------------------------------------------------------------

  ;; walk : Node String Nat Nat -> (U Leaf MountLeaf #f)
  ;; What under NODE takes PATH from I, the start of its next segment, or
  ;; N + 1 when none is left: the word that matches the segment, else the
  ;; parameter, else the catch-all or mount here, backtracking from each that
  ;; takes the segment but not the rest. With no segment left, the route
  ;; that ends here, else the mount here.
  (define (walk node path n i)
    (if (> i n)
        (or (node-end node)
            (let ((rest (node-rest node)))
              (and (mount-leaf? rest) rest)))
        (let ((e (segment-end path i n)))
          (or (let ((child (word-child node path i e)))
                (and child (walk child path n (+ e 1))))
              (let ((child (node-param node)))
                (and child (< i e) (walk child path n (+ e 1))))
              (node-rest node)))))

  ;; word-child : Node String Nat Nat -> (U Node #f)
  ;; NODE's child for the word PATH holds from I to E, compared in place.
  (define (word-child node path i e)
    (let loop ((words (node-words node)))
      (cond ((null? words) #f)
            ((same-word? (caar words) path i e) (cdar words))
            (else (loop (cdr words))))))

  (define (same-word? word path i e)
    (let ((len (string-length word)))
      (and (= len (- e i))
           (let loop ((k 0))
             (or (= k len)
                 (and (char=? (string-ref word k) (string-ref path (+ i k)))
                      (loop (+ k 1))))))))

  ;; serve-route : Leaf Req String Nat (U Handler #f) (U Handler #f) -> Res
  ;; The route's handler for REQ's method, handed REQ with the route's
  ;; match. A capture that doesn't decode is BAD-REQUEST's, handed REQ as
  ;; it came, or the empty 400; a method the route doesn't take is
  ;; NOT-ALLOWED's, handed REQ with the match, its answer given the route's
  ;; Allow when it is a 405 and left as it is otherwise, or the route's
  ;; empty 405.
  (define (serve-route leaf req path n bad-request not-allowed)
    (let ((params (if (null? (leaf-names leaf))
                      '()
                      (capture (leaf-captures leaf) (leaf-names leaf) path n 1))))
      (if (not params)
          (if bad-request (bad-request req) bad-request-res)
          (let ((handler (let ((method (req-method req)))
                           (if (eq? method 'HEAD)
                               (leaf-head leaf)
                               (cond ((assq method (leaf-entries leaf)) => cdr)
                                     (else (leaf-any leaf)))))))
            (cond (handler (handler (req-set req match-key (route-match req leaf params))))
                  (not-allowed
                   (let ((answer (not-allowed (req-set req match-key (route-match req leaf params)))))
                     (if (and (res? answer) (= (res-status answer) 405))
                         (res-set-header answer "allow" (leaf-allow leaf))
                         answer)))
                  (else (leaf-refusal leaf)))))))

  ;; route-match : Req Leaf Params -> Match
  ;; LEAF's match, joined onto the nearest mount REQ is under, else its
  ;; own, made once when it captures nothing.
  (define (route-match req leaf params)
    (let ((under (mount-of (req-ref req match-key #f))))
      (cond (under (make-match (string-append (match-template under) (leaf-template leaf))
                               (append (match-params under) params)
                               under))
            ((leaf-match leaf) => (lambda (prebuilt) prebuilt))
            (else (make-match (leaf-template leaf) params #f)))))

  ;; serve-mount : MountLeaf Req String Nat (U Handler #f) -> Res
  ;; The mount's handler, its group's middleware around it, handed REQ
  ;; with the mount's match, the path it matched and where its rest begins:
  ;; behind a marker, when middleware wraps the mount. A capture that
  ;; doesn't decode is BAD-REQUEST's, handed REQ as it came, or the empty
  ;; 400.
  (define (serve-mount leaf req path n bad-request)
    (let ((params (if (null? (mount-leaf-names leaf))
                      '()
                      (capture (mount-leaf-captures leaf) (mount-leaf-names leaf) path n 1))))
      (if (not params)
          (if bad-request (bad-request req) bad-request-res)
          (let ((under (mount-of (req-ref req match-key #f)))
                (cut (- (skip path n 1 (mount-leaf-depth leaf)) 1)))
            (let ((m (make-mount-match (if under
                                           (string-append (match-template under)
                                                          (mount-leaf-template leaf))
                                           (mount-leaf-template leaf))
                                       (if under (append (match-params under) params) params)
                                       under path cut)))
              ((mount-leaf-handler leaf)
               (req-set req match-key (if (mount-leaf-wrapped? leaf) (make-ahead m) m))))))))

  ;; mount-of : (U Match Ahead #f) -> (U MountMatch #f)
  ;; The nearest mount a request whose latest match is M is under: M, when
  ;; a mount set it; else the mount M was under, a marked mount's too.
  (define (mount-of m)
    (cond ((not m) #f)
          ((ahead? m) (match-under (ahead-match m)))
          ((mount-match? m) m)
          (else (match-under m))))

  ;; cutting : Handler -> Handler
  ;; HANDLER, handed the request with its path the rest of the path its
  ;; mount matched, which the mount's match on it holds.
  (define (cutting handler)
    (lambda (req)
      (handler (req-with-path req (rest-of (req-ref req match-key #f))))))

  ;; entering : Handler -> Handler
  ;; HANDLER inside its group's middleware: handed the request with the
  ;; mount's match set from behind its marker, and its path the rest of the
  ;; path the mount matched, whatever path the middleware passed on. A
  ;; request without the marker is handed on as it is.
  (define (entering handler)
    (lambda (req)
      (let ((ahead (req-ref req match-key #f)))
        (if (ahead? ahead)
            (let ((m (ahead-match ahead)))
              (handler (req-with-path (req-set req match-key m) (rest-of m))))
            (handler req)))))

  ;; rest-of : MountMatch -> String
  ;; What follows the mount's part of the path it matched, or "/" when
  ;; nothing or only / does.
  (define (rest-of m)
    (let ((path (mount-match-path m))
          (cut (mount-match-cut m)))
      (if (>= (+ cut 1) (string-length path))
          "/"
          (substring path cut (string-length path)))))

  ;; skip : String Nat Nat Nat -> Nat
  ;; Where PATH's segment K segments on from I starts, or N + 1.
  (define (skip path n i k)
    (if (= k 0) i (skip path n (+ (segment-end path i n) 1) (- k 1))))

  ;; capture : (Listof (U String 'param 'rest)) (Listof String) String Nat Nat
  ;;           -> (U Params #f)
  ;; The params PATH gives CAPTURES from I, each named in turn from NAMES
  ;; and decoded; #f when one doesn't decode.
  (define (capture captures names path n i)
    (cond ((null? captures) '())
          ((string? (car captures))
           (capture (cdr captures) names path n (+ (segment-end path i n) 1)))
          ((eq? (car captures) 'param)
           (let* ((e (segment-end path i n))
                  (value (decoded path i e)))
             (and value
                  (let ((more (capture (cdr captures) (cdr names) path n (+ e 1))))
                    (and more (cons (cons (car names) value) more))))))
          (else
           (let ((value (decoded path i n)))
             (and value (list (cons (car names) value)))))))

  ;; --- decoding ----------------------------------------------------------------

  ;; decoded : String Nat Nat -> (U String #f)
  ;; PATH from I to E, percent-decoded as UTF-8; #f when an escape is
  ;; malformed, a raw character is one a capture can't hold (past ASCII, or
  ;; outside RFC 3986's pchar and /), or the bytes are no UTF-8: overlong,
  ;; a surrogate, past U+10FFFF, or cut short. The server lets neither a
  ;; malformed escape nor a raw byte a path can't hold into a path, so
  ;; those come only from req-with-path or a test request; bytes that
  ;; aren't UTF-8, %FF among them, come from the wire.
  (define (decoded path i e)
    (if (plain? path i e)
        (substring path i e)
        (let ((count (utf-8 path i e #f)))
          (and count
               (let ((s (make-string count)))
                 (utf-8 path i e s)
                 s)))))

  ;; plain? : String Nat Nat -> Boolean
  ;; Only what a capture holds raw from I to E: no %, nothing past ASCII.
  (define (plain? path i e)
    (or (= i e)
        (and (raw-char? (string-ref path i)) (plain? path (+ i 1) e))))

  ;; utf-8 : String Nat Nat (U String #f) -> (U Nat #f)
  ;; How many characters the bytes of PATH from I to E decode to, each put
  ;; in OUT in turn when OUT is a string; #f when they don't decode.
  (define (utf-8 path i e out)
    (let loop ((k i) (count 0))
      (if (= k e)
          count
          (let ((b (byte-at path k e)))
            (cond ((< b 0) #f)
                  ((< b #x80)
                   (when out (string-set! out count (integer->char b)))
                   (loop (+ k (width path k)) (+ count 1)))
                  (else
                   (let ((more (cond ((<= #xC2 b #xDF) 1)
                                     ((<= #xE0 b #xEF) 2)
                                     ((<= #xF0 b #xF4) 3)
                                     (else 0))))
                     (and (> more 0)
                          (let sequence ((k (+ k (width path k)))
                                         (left more)
                                         (code (bitwise-and b (case more
                                                                ((1) #x1F)
                                                                ((2) #x0F)
                                                                (else #x07))))
                                         (low (case b ((#xE0) #xA0) ((#xF0) #x90) (else #x80)))
                                         (high (case b ((#xED) #x9F) ((#xF4) #x8F) (else #xBF))))
                            (if (= left 0)
                                (begin
                                  (when out (string-set! out count (integer->char code)))
                                  (loop k (+ count 1)))
                                (and (< k e)
                                     (let ((c (byte-at path k e)))
                                       (and (<= low c high)
                                            (sequence (+ k (width path k))
                                                      (- left 1)
                                                      (+ (* code 64) (- c #x80))
                                                      #x80
                                                      #xBF))))))))))))))

  ;; byte-at : String Nat Nat -> Integer
  ;; The byte PATH holds at K, an escape or a character, before E; -1 for a
  ;; malformed escape or a character a capture can't hold raw.
  (define (byte-at path k e)
    (let ((c (string-ref path k)))
      (cond ((char=? c #\%)
             (let ((high (and (< (+ k 2) e) (hex (string-ref path (+ k 1)))))
                   (low (and (< (+ k 2) e) (hex (string-ref path (+ k 2))))))
               (if (and high low) (+ (* 16 high) low) -1)))
            ((raw-char? c) (char->integer c))
            (else -1))))

  ;; width : String Nat -> Nat — how many characters PATH's byte at K takes.
  (define (width path k) (if (char=? (string-ref path k) #\%) 3 1))

  (define (hex c)
    (cond ((char<=? #\0 c #\9) (- (char->integer c) 48))
          ((char<=? #\a c #\f) (- (char->integer c) 87))
          ((char<=? #\A c #\F) (- (char->integer c) 55))
          (else #f)))

  ;; --- the request's match -----------------------------------------------------

  (define (match-of who req)
    (unless (req? req)
      (assertion-violation who "not a request" req))
    (req-ref req match-key #f))

  ;; seen : (U Match Ahead #f) -> (U Match #f) — the match behind a marker.
  (define (seen m)
    (if (ahead? m) (ahead-match m) m))

  ;; req-route : Req -> (U String #f)
  ;; The joined template of what the last router REQ passed matched, #f
  ;; when no router matched it.
  (define (req-route req)
    (let ((m (seen (match-of 'req-route req))))
      (and m (match-template m))))

  ;; req-path-params : Req -> (Listof (Pair String String))
  ;; The params that match captured, decoded, left to right in its
  ;; template; '() with none.
  (define (req-path-params req)
    (let ((m (seen (match-of 'req-path-params req))))
      (if m (match-params m) '())))

  ;; req-path-param : Req String -> (U String #f)
  ;; The last of req-path-params named NAME, or #f. A NAME that is no
  ;; string is an assertion violation.
  (define (req-path-param req name)
    (let ((m (seen (match-of 'req-path-param req))))
      (unless (string? name)
        (assertion-violation 'req-path-param "a parameter's name is a string" name))
      (and m
           (fold-left (lambda (found pair) (if (string=? (car pair) name) (cdr pair) found))
                      #f (match-params m)))))

  ;; req-mount-path : Req -> String
  ;; The part of REQ's path that the mounts above it took, undecoded, as
  ;; req-path is: for /api/2/users/7 under (mount "/api/:v" ...), "/api/2".
  ;; Nested mounts' parts join; under none, "". A route under a mount
  ;; answers that mount's part; the group's middleware around a mount, the
  ;; part above it. Made at each call, from the mounts' matches.
  (define (req-mount-path req)
    (mount-path (mount-of (match-of 'req-mount-path req))))

  (define (mount-path m)
    (if m
        (string-append (mount-path (match-under m))
                       (substring (mount-match-path m) 0 (mount-match-cut m)))
        "")))
