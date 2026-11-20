# Agent adapter core boundary

This first #1303 slice defines pure contracts and validation only. It has no
production ingress and is independently reviewable from #1302.

For a pinned-source comparison with T3 Code and the Codex-first integration
sequence, see [agent integration research](t3-code-agent-integration-2026-11-15.md).
It distinguishes protocol foundations from a complete production task flow.

For Pine-computed content/environment capture and scheme migration, see
[ADE content identities](ade-content-identities.md). These primitives do not
authorize checks, provider execution, Ready publication, or result actions.

For bounded concurrent independent tasks — launch admission, the documented
limit `N`, resource bounds, and cross-task isolation — see
[parallel task isolation](ade-parallel-task-isolation.md).

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

**State table.** The canonical meanings, one row per state. "Established
by" is the only evidence that may produce the state; everything else —
including process exit, terminal silence, and an agent claim — produces
`unknown`/`unverified` instead.

| State | Meaning | Established by | Never established by |
| --- | --- | --- | --- |
| execution `working` | The current attempt has an unresolved active turn | a live run with observed active state | silence, a queued delta, a claim |
| execution `blocked` | A current live authenticated attempt has an unresolved question or approval request | a live, authenticated, positive provider request | transport loss (execution degrades to `unknown`; the historical request is not actionable until revalidated) |
| execution `idle` | A current live session has no active turn or outstanding request | positive provider state or reconciliation for the current attempt | terminal silence, process exit, a quiet stream (stays `unknown`) |
| execution `unknown` | Current execution evidence is absent, stale, contradictory, or unsupported | the default; any gap in positive evidence | — (fail-closed default) |
| outcome `success` | A settled attempt with an agent-reported completion plus ALL required independent evidence bound to one shared code-state identity | `settleOutcome` over bound facts | process exit, silence, a claim alone |
| outcome `failure` | A settled attempt whose claim a failing independent fact bound to the claim's own code state vetoes | a bound failing check or reviewer fact | a claim alone, a failing fact bound to an older state |
| outcome `cancellation` | The user cancelled the attempt | a `userCancellation` fact | provider silence |
| outcome `superseded` | The attempt was replaced by a newer one on the same route | run replacement (PID/process incarnation change) | a late event from the replaced process |
| outcome `unverified` | An attempt ended or reported completion without all required independent evidence | the default settlement for any gap | optimistic presentation as success |
| attention `none` / `isUnread` | No outstanding review signal / an unread transition exists | the settled outcome and attention transitions | — |
| verification `none` / `pending` / `verified` / `stale` | No evidence recorded / re-verification in flight / required evidence complete and bound to the current identities / invalidated by a relevant change or relaunch | recording the required passing evidence (via shared settlement) or the verification layer's explicit actions | any later fact alone re-upgrading `stale` |
| acceptance `notAccepted` / `accepted` | The user did not / did accept the recorded result | `recordUserAcceptance` with caller-proven identities | inheritance across relevant changes or attempts |

**Invariants.** No transition maps process exit, terminal silence, or an
agent claim directly to Ready. A finished attempt without required
verification is explicitly `unverified`. Missing positive idle evidence is
`unknown`, never `idle`. Ready is derived only from current required
evidence and is never stored. Unknown future raw values decode fail-closed
(`executionState` to `unknown`, `outcome` to `unverified`,
`verificationState` to `stale`, `acceptanceState` to `notAccepted`).

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

**Ordering and delivery.** Ordered/source-cursor delivery is negotiated ONLY
when the provider documents a real lifecycle sequence and a replay cursor
(the adapter profile carries both; replay without ordering is rejected at
profile construction). Otherwise the delivery is unordered/no-replay:
deduplication is scoped to the event identity (source sequence alone for
ordered streams; the observed timestamp quantized to millisecond precision
for unordered ones), and current state is re-established by reconciliation
rather than by replay. Legitimate cross-scope reordering — facts of
different attempts or runs arriving out of chronology — is admitted, never
rejected: the fence orders facts only within their own attempt (identity,
incarnation, session reference, chronology from the run start). Source
sequences are never manufactured from arrival order: an unordered stream
carries none, and an ordered stream that delivers a delta without a
sequence fails closed at the hydration barrier rather than inventing one.

**Hydration barrier.** A structured stream reconnecting to an already-live
attempt hydrates through a race-free barrier
(`AgentTaskHydrationBarrier`): the caller buffers incoming deltas while it
obtains the reconciled current state of one attempt (outstanding turns and
requests reconciled, attempt and vendor-session identity revalidated — the
`AgentTaskHydrationSnapshot`), then applies only the buffered deltas proven
newer within the same attempt: for ordered delivery, source sequences above
the fetched state's watermark; for unordered delivery, the shared fence
alone. At-or-below-watermark deltas are stale replays and are dropped; an
ordered delta without a sequence is unprovable and is dropped. A snapshot
that references an unknown attempt, a mismatched incarnation, or a vendor
session that does not revalidate fences every delta and applies nothing,
including its execution state; a snapshot of a replaced attempt never
overwrites the current attempt's view. A quiet stream reconciles to
`unknown`, never to a positive state, and never settles an outcome:
silence is not completion.

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

**Crash ordering.** When one operation touches more than one durable
surface, the task metadata — invalidation plus new-attempt state — must be
durable BEFORE the dependent positive evidence (the fact recorded after the
invalidation, or a provenance-journal record referencing the attempt). A
crash between the metadata write and the journal/evidence write fails
closed: recovery sees the durable invalidation without the dependent
evidence, refuses Ready, and never adopts evidence whose durable attempt
basis it cannot prove. Provenance-journal records are provenance history,
not a promotion path into the task model: a journal record whose attempt is
absent from the durable metadata is never adopted as evidence. Evidence
that does land later re-settles through the shared fence and still cannot
re-upgrade a stale verification on its own.

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

**Integration deferral.** The composed UI/integration scenario from the
additional acceptance criteria — create a task in a selected project with
the remembered agent, record feedback/check/review/result metadata,
relaunch, and continue without rebuilding context — is deferred to #1761
(integrated acceptance); there is no composed UI test in this slice by
design. Its legs are pinned separately: registry-level relaunch and
continuation in a selected project with the remembered agent (base), and
relaunch over real storage of the durable relationship with fail-closed
crash ordering (this slice).

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

**Legacy `.done` and task-completed notifications.** The run state `.done`
and the legacy task-completed notification mean only that an agent reported
or appeared to finish. They are observations, not evidence facts: a
terminated `.done` run with no recorded facts settles `unverified`, and the
legacy `.completed` notification kind may still fire for compatibility, but
it never migrates into the new model — it does not record an
`agentReportedCompletion` fact, does not upgrade the outcome or the
verification state, and never establishes Ready. No verified-result or
Ready notification kind exists: the notification surface is exactly
`waitingInput`, `failed`, and `completed` (legacy). At the
persistence level the legacy completed state (completed lifecycle and
attention without a recorded outcome and evidence basis) is rejected as
invalid metadata rather than migrated.

**Code-state and environment identity.** `AgentTaskCodeStateIdentity` is
computed under content scheme 2: the worktree HEAD and framed hashes of actual
tracked, untracked, ignored/generated input contents, paths, modes, symlinks,
Git indexes/configuration, and initialized submodule inputs. Status categories
and path lists alone are not content identities. `AgentTaskEnvironmentIdentity`
scheme 2 adds the observed OS build, actual selected executable bytes, and a
configuration/environment/policy fingerprint. All three environment components
are required for current equivalence. Bounded older/unknown schemes survive as
history but cannot authorize Ready or re-verification. See
[ADE content identities](ade-content-identities.md) for encoding, bounds,
input/output declarations, editor preflight, and unsupported states. Provider-supplied paths and hashes are untrusted
until recomputed beneath the authorized no-follow root; the registry seams
take caller-proven identities only.

**Data classification, retention, and logs.** Every durable field of the
task model is classified, bounded, and content-free: the model persists
bounded redacted metadata and references — never transcripts, prompts,
file contents, environment values, visual attachments, or credentials.
"Provider transmission" is what leaves Pine toward the provider: the model
transmits only the opaque vendor identity (one argv element) and the launch
executable; task content (title, objective, feedback) is never transmitted
by the task model. Notification content is exactly the transition events'
bounded fields (catalog display name ≤64 B, project name = last path
component ≤80 B, title ≤120 B, elapsed time, and the UUID/generation
routing keys); no field value, path, prompt, or output reaches a
notification body. Logs emit valueless diagnostics only — rejection
reasons and notification routing IDs — never field values, paths, labels,
vendor identifiers, or event payloads.

| Field | Class | Bound | Redaction | Provider transmission | Notifications | Logs |
| --- | --- | --- | --- | --- | --- | --- |
| task/run/route IDs, `paneID`, `tabID`, `terminalID` | identity | UUID | n/a | not transmitted | `userInfo` routing keys only | task/run UUID in rejection lines only |
| `project.canonicalProjectPath` / `canonicalWorktreePath` | path | canonical absolute path | mode-0600 file only; never re-exposed | not transmitted | last path component ≤80 B | not logged |
| `presentationContext.terminalLabel` | reference | ≤256 B, no NUL/CR/LF | the terminal's stable label only — never OSC title, cwd, command line, prompt, or output | not transmitted | quick-terminal project name only | not logged |
| `descriptor.typeIdentifier` / `launchExecutable` | identity | ≤128 B each | stable catalog identifier + executable name | launch executable only | catalog display name ≤64 B | not logged |
| `title` | text | ≤256 B | user-provided; sanitized for notification (control/newline removal, ≤120 B) | not transmitted | ≤120 B in body | not logged |
| `objective` | text | ≤2048 B | user-provided | not transmitted | not emitted | not logged |
| `runs[].process` (`processIdentifier`, `processGeneration`, `startIdentifier`, `observedStartedAt`) | observation | pid, generation, ≤512 B start, date | process observation; never provider-trusted beyond fencing | not transmitted | `generation` routing key | not logged |
| `runs[].vendorIdentity` (`provider`, `opaqueIdentifier`, `executableVersion`) | opaque reference | ≤128 B / ≤1024 B / ≤256 B | opaque vendor identity; never rendered; one argv element at launch | the opaque identity, re-probed version-gated | not emitted | not logged |
| `runs[].state` / `liveness` / `outcome`, `executionState`, `verificationState`, `acceptanceState`, `lifecycle`, `attention`, `isUnread`, timestamps | derived/attention | enum / date | n/a | not transmitted | event kind only (no field values) | not logged |
| `evidence[]` facts | evidence | 64 facts/task; 12 bounded fields each | hashes, fingerprints, and identifiers only — no payload, transcript, prompt, or output | structured adapter records facts; never raw event payloads | not emitted | not logged |
| `reviewedSnapshot` / `acceptedSnapshot` | identity | 1 code-state + environment identity each | fingerprints only | not transmitted | not emitted | not logged |
| task `environment` | identity | OS/tool identity ≤64 B each + 64-hex config fingerprint | opaque identifiers, never environment values | not transmitted | not emitted | not logged |
| `feedback[]` | reference | ≤32 records × ≤256 B reference | provider id or hash, never feedback text | not transmitted | not emitted | not logged |
| `worktreeSetup` checkpoint | identity | scheme 1 bounded proofs | filesystem object/repository proofs, no contents | not transmitted | not emitted | not logged |
| envelope `rememberedAgent` | identity | descriptor bounds (≤128 B identifier, ≤128 B executable) | stable identifier + executable name | not transmitted | not emitted | not logged |

**Retention.** Per project: ≤200 tasks, ≤1 MiB metadata file, ≤50 runs per
task (trimming keeps the latest), ≤64 evidence facts, ≤32 feedback records.
The registry's in-memory run-ID merge index (`historicalTaskIDByRunID`) is
additionally bounded at 8 192 references — a load-time admission bound, not
persisted references. The retention sweep dismisses a
fully settled task (paused or completed, route missing, no live run, no
pending claim) only after its last honest timestamp is at least 7 days old;
dismissal keeps the durable metadata until the per-project cap reclaims it.
Journal-side retention belongs to the provenance store's own bounded limits
(count/byte/quarantine), never to the task model.

**Legacy evidence.** Facts without an environment or operation fingerprints
remain admissible as historical metadata. They cannot establish Ready or
restore current verification: each required check and reviewer fact must
bind the caller-proven current environment and matching pre/post code-state
identities. Missing environment binding reports `environmentChanged`;
missing operation fingerprints report stale evidence for that kind.
A fact's
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
