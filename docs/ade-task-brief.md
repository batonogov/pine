# Explicit task brief contract (#1759)

`AgentTaskBrief` projects the existing durable task's objective (with its
goal version), latest attempt and outcome, reviewed/accepted snapshots,
verification, environment, feedback references, and explicit decision/
question annotations. It does not read terminal output, restore a provider
conversation, call a model, or send anything. It is a factual return-to-task
brief: everything it shows comes from task records, so it never claims
restored provider context.

## Goal versioning and evidence invalidation

`AgentTask.objectiveRevision` is `0` while no goal is recorded and is bumped
once per accepted change via `AgentTaskRegistry.setObjective(_:
expectedRevision:taskID:at:)`, which fences stale editors with the expected
revision and bounds the text like task creation. A changed goal invalidates
the current verification (`.verified`/`.pending` → `.stale`) and resets
acceptance (`.accepted` → `.notAccepted`) using the established invalidation
contract: recorded evidence facts and result snapshots keep the identity they
were made against and are never rewritten; a stale verification cannot
re-upgrade from later facts alone, and the verification layer owns explicit
re-verification. A no-op edit (identical text) does not bump the version or
invalidate anything. The metadata store rejects files where the revision and
the goal's presence disagree, and metadata persisted before versioning decodes
to version 1 when a goal exists. This covers the goal; no separate criteria
record exists in the task model, and no historical goal text is stored — the
revision is the disclosure that the criteria moved.

## Decision and question annotations

Decision annotations live in `AgentTask.decisionReferences`, inside the
existing private, project-scoped metadata transaction. There are at most 32
per task; each stores an opaque redacted reference of at most 256 UTF-8
bytes, attempt ID, user action timestamp, kind (`decision` or
`unresolvedQuestion`), stable annotation ID, and revision. The registry's
explicit user-action API supports correction and removal with revision
checks. Callers must use fresh UUIDs for new annotations and supply only
authorized redacted identifiers, not text, paths, credentials, or provider
suggestions. Provider suggestions and generated summaries cannot create these
records: the API records decisions the user already made for the named
attempt, and it does not introduce new task criteria or grant approval to
another result.

Reference resolution is explicit: the default is `notResolved`, not
available. The presentation owner can report available, unavailable, or
expired references. A separately exposed `attemptRetained` flag discloses
when bounded run retention has removed the annotated attempt. An annotation
never makes its referenced result current or verified.

Retention and privacy are bounded by construction: the records are
content-free (no transcripts, prompts, screenshots, or paths), they live in
the existing mode-0600 project metadata, and the store revalidates every
record on load as a persistence backstop. After task dismissal (the
seven-day auto-sweep) annotation creation, correction, and removal are all
permanently closed by the registry's `lifecycle != .dismissed` guard
(`AgentTaskRegistry`); the bounded records stay durable until per-project
task reclamation, and the brief's `attemptRetained` flag plus the explicit
reference states disclose that gap instead of presenting the annotation as
live.

## Provider handoff: ship/defer decision

**Decision: DEFER.** Cross-provider handoff is not selected for this slice
and is not implemented. No transport, no adapter selection flow, no session
identity migration.

Rationale:

- The observed need — users actually changing providers mid-task — is not yet
  measured. The issue scopes handoff as a bounded design experiment with a
  ship/defer decision, not a 3.0 release requirement.
- The simpler composition already satisfies the return-to-task promise: this
  brief plus the existing explicit new-session flow. A user who returns, or
  who deliberately starts a new provider session from the same task, gets the
  outcome, the goal (and that it moved), the decisions, the unresolved
  questions, the latest result, and the next decision without scanning a
  terminal transcript or copy-pasting conversation text.
- Handoff would add a competing-writer surface (environment revalidation,
  settling the previous writer, new session/attempt identity) on top of
  ownership and settlement logic that other work items own. Shipping it
  before observed need would block 3.0 on speculative protocol parity.

The decision stays open under #1735 (brief presentation and
return-to-task usability evaluation): if measured users change providers
mid-task and the brief plus new-session flow does not cover the observed gap,
revisit against the contract below.

Minimal contract that would apply IF handoff were shipped:

- Previewable handoff containing only authorized brief material (redacted
  references, never transcripts/prompts/screenshots), current environment and
  candidate references, and relevant pending feedback.
- Environment ownership revalidated and the previous writer settled or
  cancelled before dispatch; if the previous writer's live state is unknown,
  no competing writer starts in the same environment.
- A new provider session and new Pine attempt with clear attribution: a
  handoff, not native conversation restoration, and no migration of hidden
  reasoning. Historical checks/review are preserved but no current approval
  is inherited into a changed candidate or new criteria; old provider events
  cannot answer new requests or settle the new attempt.
- Capability mismatch, missing authorization, unavailable provider, and
  missing references produce explicit recoverable states; a failed dispatch
  preserves the existing task and local work.
- Provider credentials, permissions, or grants are never transferred merely
  because task content was shared.
- No automatic failover to another paid provider, no concurrent
  multi-provider writers, no silent permission transfer.

## Remaining integration

- #1735 owns inspection/edit/removal presentation (brief, goal editing,
  annotations), the return-to-task usability evaluation, and the ship/defer
  reconsideration. This slice provides no new UI.
