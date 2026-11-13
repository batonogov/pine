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
commits its one-shot consumption at the core-owned activation boundary immediately
before any frozen startup candidate can reach downstream,
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
sequence can retry after the session becomes active. Failure or cancellation
before the commit discards the reservation without publication. Stop,
downstream revocation, or cancellation after the commit may make `start()` fail,
but cannot reopen the consumed authority after buffered publication has become
possible. Minting a checkpoint
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

## Lifecycle and evidence contract (#1722)

Durable task state uses one versioned lifecycle/evidence contract built on
the #1302 registry and metadata store (schema v3). Every ADE surface —
Inbox, notifications, recovery, result views — projects the same durable
fields; none keeps a parallel status store.

**State dimensions.** A task tracks, as distinct dimensions:

- `executionState` (`working` / `blocked` / `idle` / `unknown`): the current
  view of the latest attempt. `working` is an unresolved active turn;
  `blocked` is a live, authenticated, unresolved question or approval;
  `idle` is a live session with no active turn or outstanding request,
  established by provider state or reconciliation — idle is not task
  completion; `unknown` is missing, stale, contradictory, or unsupported
  evidence. Terminal silence and process exit never establish `idle`.
- `outcome` per settled run (`success` / `failure` / `cancellation` /
  `superseded` / `unverified`), `nil` while in flight. `success` requires an
  agent-reported completion plus all required independent evidence
  (independent check and reviewer outcome) bound to one shared code-state
  identity. Process exit, terminal silence, and an agent claim alone settle
  `unverified`, never `success`. The latest observed completion claim is
  what the attempt settles against; a failing independent fact vetoes the
  claim only when it is bound to the claim's own code state — a failure
  recorded against an older state is history, never a rejection of the
  current claim. Without a claim, check and review facts settle
  `unverified`, never `failure`.
- `attention` / `isUnread`: the legacy review dimensions, unchanged.
- `verificationState` (`none` / `pending` / `verified` / `stale`): the
  current validity of independent verification for the latest result.
  `pending` is produced by the verification layer while a re-run is in
  flight; `stale` is left only by the explicit re-verification action
  described under Ready.
- `acceptanceState` (`notAccepted` / `accepted`) plus
  `acceptedSnapshot`: user acceptance as a separate fact; the recorded
  state identity is preserved so later edits can prove they do not inherit
  it. Acceptance may also be recorded against an `unverified` outcome: it
  closes the work and snapshots the identity, but never upgrades the
  outcome or the verification state.

**Evidence facts.** `AgentTaskEvidenceFact` is one bounded fact bound to one
attempt: kind (`processCompletion`, `agentReportedCompletion`,
`independentCheck`, `reviewerOutcome`, `userAcceptance`,
`userCancellation`), the provenance `TrustLevel` (process observations are
at most `observed`; user actions and structured reports may be `verified`),
a bounded result, observed time, code-state identity, environment identity,
an optional provider session reference, and an optional source sequence.
Observed process completion, agent-reported completion, independent checks,
reviewer outcomes, and user acceptance remain separate facts; no fact
establishes any other. Facts store hashes and identifiers only — never
transcripts, prompts, file contents, environment values, or credentials.

**Operation fingerprints.** Check and reviewer facts additionally carry
pre- and post-operation code-state fingerprints: the recording layer
(#1724) computes the code-state identity before and after the operation and
records the fact only when the two are equal — a check whose tree moved
during the operation cannot prove relevance, so the fact is simply never
recorded and Ready stays refused. Persisted pre/post fingerprints are always
equal to each other and to the fact's own code-state identity; any other
combination (one side only, a mismatch, or pre/post on any other fact kind)
is fenced at admission and rejected fail-closed from durable files.

**Fencing.** Facts are fenced by attempt identity (run ID), process
incarnation (process generation), provider session reference, source
sequence, and observed chronology; duplicate event identities are rejected.
Ordered delivery deduplicates by source sequence ALONE — a reconnect
re-emission (or clock skew) with a different observed timestamp is a
duplicate, never a new event — while unordered delivery deduplicates by the
observed timestamp quantized to millisecond precision, stable across the
persistence encoding. Facts are also bounded (64 per task) at admission.
Late, duplicate, replayed, nested, and foreign-provider events cannot settle
a different or newer attempt.

**Ready.** Ready is derived, never stored, and exists only from current
required evidence: a settled `success` outcome, current `verified`
verification state, and every required evidence fact passing and bound to
the current code-state and environment identities. Process exit, terminal
silence, and an agent claim never map to Ready. Invalidation — relevant
edits, environment changes, or relaunch — fails closed and names the repeat
work (`missingEvidence(kind)`, `failingEvidence(kind)`,
`staleEvidence(kind)`, `environmentChanged`, plus the code-state and
environment unknown gaps), while reviewed and accepted snapshots stay
identifiable. The projection mirrors the settlement veto scope: a failing
fact bound to the CURRENT code state names `failingEvidence(kind)` and no
older passing fact can override it.

**Revalidation before publication.** The surface that publishes Ready — and
the surface that tries the result (#1725) — recomputes and proves the
current code-state and environment identities immediately before each, and
passes them to the readiness projection; identities captured earlier do not
establish Ready.

**Re-verification.** `.stale` (and `.pending`) is left only by an explicit
re-verification action, which the verification layer (#1724) will drive
through these seams; the grant mechanism is #1724's to define. No later
fact alone re-upgrades a stale result. The layer
re-runs the required evidence against the current identities, records the
new bound facts (`recordEvidence`), optionally marks in-flight verification
(`markVerificationPending`), and then restores the current state
(`markVerificationCurrent`, reducer `reverify`) — which requires a settled
`success` attempt and every required fact passing bound to the
caller-proven code-state and environment identities. Those current
identities are computed and proven by the verification layer; the registry
seams take caller-proven identities only.

**Persistence.** Task metadata is schema v3. Outcome state is writable only
with an evidence basis: a settled run carrying a recorded outcome plus at
least one durable evidence fact bound to it. Relaunch normalization marks
live evidence stale, invalidates current verified and accepted state, and
preserves the snapshots: surfaces never see un-normalized state, and
un-normalized state is never persisted (the re-save is scheduled after
normalization). Invalidation and the evidence recorded after it land in
the same durable task snapshot, so a persisted write can never contain
dependent positive evidence without its invalidation; a crash between a
mutation and the metadata write leaves only the previous consistent state.

**Durable relationship.** The task itself carries the bindings that survive
individual runs. A task-level `environment` identity (the `bindEnvironment`
seam, caller-proven and revalidated on every save and load) is the slot the
structured adapters (#1723) bind their session, launch generation, and
attempt identity to. A bounded list of content-free feedback records
(`recordFeedback`, ≤32 per task, admitted at that one point) stores the
user's bounded feedback references; each `reference` is a redacted provider
identifier or hash — never feedback text, a path, or a secret — together
with the code state the feedback referred to, when known. The per-project
envelope remembers the agent explicitly used by the last Pine-owned launch
in that project (`rememberedAgentDescriptor(for:)`): an explicit choice at
launch time always wins, and task dismissal and the retention sweep never
erase the envelope state.

**Recovery.** Application restoration loads the durable metadata and
normalizes it fail-closed before any surface may present it: live execution
evidence degrades to `unknown`, current `verified`/`pending` verification to
`stale`, acceptance resets, and the reviewed and accepted snapshots survive.
Restoration never reconciles against a provider, never re-arms a claim, and
never resumes a correction loop; automatic reconciliation is allowed only
with an already-live process and an authenticated channel whose identity is
revalidated (the structured layer, #1723). Starting a new agent process —
including native provider resume — always requires explicit user action and
creates a new run and source namespace, never a continuation of a lost one.

**Code-state and environment identity.** `AgentTaskCodeStateIdentity` is
conservative by contract: the worktree head commit plus SHA-256
fingerprints over the canonicalized tracked status entries (tracked
modifications, symlinks, and submodules as the git status reports them),
the sorted untracked path list, and the relevant ignored inputs (for
example, generated files the required checks consume).
`AgentTaskEnvironmentIdentity` adds the OS build, the toolchain, and a
configuration fingerprint. Provider-supplied paths and hashes are untrusted
until recomputed beneath the authorized no-follow root; the registry seams
take caller-proven identities only.

**Data classification and logs.** Every new durable field is bounded and
content-free:

| Field | Class | Bound | Redaction | Notifications | Logs |
| --- | --- | --- | --- | --- | --- |
| task `environment` | identity | 3 × ≤64 B components + 64-hex config fingerprint | opaque identifiers, never values | not emitted | not logged |
| task `feedback` | reference | ≤32 records × ≤256 B reference | provider id or hash, never text | not emitted | not logged |
| fact `pre/postOperationCodeState` | identity | 2 × code-state identity | fingerprints only | not emitted | not logged |
| envelope `rememberedAgent` | identity | descriptor bounds (≤128 B identifier, ≤128 B executable) | stable identifier + executable name | not emitted | not logged |

The only new log lines emit rejection-enum diagnostics (which rule rejected
a file); no field value, path, or identifier is ever logged.

**Known asymmetries.** A fact bound to a code state but not to an
environment is invisible to the `environmentChanged` dimension — the
normative rule binds success to the code-state identity, while `reverify`
does require the environment binding to leave `.stale`. A fact's
vendor-session reference is fenced only when the bound run carries a vendor
identity; on an identity-less run the field is inert and never influences
outcome or readiness.

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
unchanged, and core checks cancellation again after an untrusted probe or session
factory returns. `stop(deadline:)` first closes admission, then starts at most one
shared adapter cleanup per session and supervises the current set of already
admitted deliveries outside caller cancellation. Concurrent callers and
last-copy abandonment share that same single-flight cleanup; abandonment uses a
bounded core-owned deadline. Stop preserves the actual downstream outcome for
work admitted before closing and cancels the supervised adapter task at the
initiating deadline. Cleanup capacity is reserved before a
core-bound session is exposed; construction fails with
`cleanupCapacityUnavailable` when no permit remains. A cleanup that ignores
cancellation keeps its pre-reserved process-wide quarantine slot until it exits,
so quarantine remains bounded without denying cleanup to an already-issued
session. This slice does not claim forced in-process termination.
