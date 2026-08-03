# Agent adapter core boundary

This first #1303 slice defines pure contracts and validation only. It has no
production ingress and is independently reviewable from #1302.

## Three planes

The **presentation plane** contains a stable agent ID, normalized display text,
exact executable aliases, and a data-driven style token. One migration catalog
preserves Pine's five exact legacy built-in identifiers and retains each generic
legacy identifier alongside a deterministic SHA-256-derived canonical ID.
All five built-in IDs and executable aliases are globally reserved even when a
compiled caller omits a built-in record; supplied built-ins are also checked
against the complete core-owned catalog. A separate bounded
programmatic user registration accepts only presentation and aliases, namespaces
the ID, and normalizes to generic, inference-only presentation. It cannot name
an adapter, factory, authentication, capability, command, or provenance.

This slice deliberately provides no JSON registration decoder. A future bounded
configuration loader must limit total bytes before allocation or decoding and
reject duplicate JSON keys.

The **compiled adapter plane** contains adapter and factory IDs, Pine contract
versions, and bounded capability profiles. Each profile describes exactly one
transport, explicit lifecycle scope/phase pairs, coherent tool/file-change
evidence, replay, ordering, and a minimum core-derived authentication
requirement. V1 exposes no control operations. Raw factories and their maximum
capabilities stay private to the registry. The unskippable authority flow is:
registered factory probe → registry-minted opaque offer → policy negotiation →
registry-bound contract → exact registered factory session. A raw probe result
cannot authorize negotiation, copied offers share one registry-owned one-shot
gate, and an offer from another registry is rejected before any factory
invocation. The resulting contract is bound to that probe generation and carries
one fresh-session authority; resume instead requires a one-shot checkpoint.
Negotiation derives offered profiles and Pine
contract versions only from the exact stored factory's probe result, then
selects the highest policy-allowed version and one whole offered profile within
the compiled maximum. Only the minting registry constructs and wraps sessions:
it rejects foreign contracts, checkpoints for no-replay profiles, and
checkpoints not bound to the exact minting registry, negotiated contract, and
source-session namespace. It passes its exact contract and core-owned validating
sink to the exact factory, and rejects a returned session whose contract differs
before it can escape.

The **candidate plane** contains discriminated, non-authoritative lifecycle,
question, approval, tool, file-change, process-exit, timestamp, and vendor
reference hints. Questions and approvals carry an exact lifecycle scope,
matching attention phase, request reference, and only an optional context
reference whose role must match that scope. Explicit pairs prevent Pi run
completion and session settlement, or Codex thread/turn/item phases, from
authorizing one another.
Source sequences start at 1. Ordered delivery requires them; unordered profiles
reject producer sequences rather than silently inventing monotonic semantics.
Source-cursor replay requires one structurally
complete source position containing an event identity, resume cursor, and
positive source sequence; no-replay profiles reject event/cursor positions.
A checkpoint cannot be caller-constructed. The registry derives its redacted
internal envelope from the latest complete replay position accepted through one
core-wrapped source session; callers cannot supply a position to checkpoint.
The adapter-facing payload contains the opaque vendor
cursor plus the last accepted source event identity and sequence; the private
binding contains no credential, task, project, terminal, process, or routing
authority. Resume reserves the checkpoint exclusively before factory invocation,
commits its one-shot consumption only after a contract-matching session activates,
and rolls the reservation back on construction failure, failed start,
cancellation, stop-before-start, or abandoned construction. It requires
the same registry and exact negotiated contract before the payload reaches a
factory. Session sinks reject input before `start()`, after `stop()`, and after
a failed start. During `start()` they hold only a core-bounded number of
already-validated candidates
and return the distinct `bufferedUntilActivation` outcome. After underlying
startup succeeds, core checks cancellation and commits activation in one
synchronous actor transition, freezing exactly that finite batch before
draining it. Ingress during the drain is rejected without advancing source
ordering, so it cannot extend startup and receives the explicit
`retryAfterActivation` outcome rather than a permanent-invalid result. The same
sequence can retry after the session becomes active. Failure or
cancellation before the commit discards
it without publication; downstream revocation or cancellation after the commit
may retire the live session, but cannot retroactively turn `start()` into a
failed transaction. Minting a checkpoint
requires an active session with no in-flight downstream delivery and atomically
retires the source sink, so the original and
resumed attempts cannot fork one logical source sequence. The logical source
namespace survives resume while each construction
gets a distinct attempt identity. A core-owned session actor drops duplicate,
lower, and stale source sequences before routing and advances checkpoint state
only after downstream acceptance, without regressing when accepted outcomes
complete out of order. Core later stamps its own journal sequence. Candidate
paths and hashes remain untrusted. File-change
batches reject exact and component-prefix path overlaps after conservative case,
width, and diacritic reduction. Accepted paths preserve their exact filesystem
spelling, but paths containing bidi, control, or default-ignorable scalars are
rejected at candidate construction and are never exposed as safe presentation.
Pine must recompute identity beneath a credential-bound, no-follow root before trust.
Vendor references, resume positions, and checkpoints are bounded, non-Codable,
and redacted from description, debug description, and reflection. Process exit
is not successful agent completion.

## Authority and deferred work

Pine creates and lifecycle-binds a session-contract validating sink before the
factory is invoked. Its adapter-facing API is only `ingest(_ candidate:)`; core
wraps validated events with opaque source namespace and attempt identity before
forwarding. Factory failure, returned-contract mismatch, start failure, and stop
revoke the sink.
Adapter DTOs contain no authentication context, credential, task, project,
worktree, terminal, process generation, replay watermark, trust, or routing
field. Those are server-side facts and depend on #1302's durable identity and
routing work.

This commit does **not** complete #1303. It does not prove executable identity,
no-follow/stat/signature/hash verification, socket or peer security, HMAC,
credential storage, hook install,
command execution, rate limiting, replay persistence,
production supervision, crash/hang enforcement, task routing, or vendor
integration.
Factories are pre-bound instances supplied by a future supervised loader; probe
neither searches PATH nor verifies executable identity. Runtime root containment
and forced process teardown remain deferred.

This slice defines no JSON or frame decoder and therefore no byte-allocation
security boundary. Strict duplicate-key, integer-token, nesting, source-envelope,
and schema parsing belong to the future authenticated framed-ingress slice.

Every async throwing factory/session seam propagates `CancellationError`
unchanged. `stop(deadline:)` first closes admission, then supervises already
admitted deliveries and adapter cleanup outside caller cancellation. It returns
when both finish or the shared deadline expires, preserves the actual downstream
outcome for work admitted before closing, and then cancels unfinished cleanup.
It does not claim forced termination when an implementation ignores cancellation.
