# Parallel independent ADE tasks: isolation and bounded concurrency

The contract for several independent ADE tasks inside one current project
([#1728](https://github.com/batonogov/pine/issues/1728)). It builds on, and
does not restate, the single-task environment binding contract
([#1723](https://github.com/batonogov/pine/issues/1723), implemented by
[#1791](https://github.com/batonogov/pine/issues/1791) and
[#1804](https://github.com/batonogov/pine/issues/1804)): discovery,
canonicalization, validation, adoption, and binding of one task's
environment. This document adds concurrent ownership, scheduling, resource
bounds, and cross-task isolation on top of that contract.

## What Pine guarantees — and what it does not

Pine's guarantee concerns **task routing, reducer and evidence isolation, and
explicit environment ownership**: every event, grant, attention flag, and
result action is fenced to exactly one task, attempt, launch generation, and
environment, and no task's state can settle, answer, or invalidate another's.

A validated cwd or worktree is **not a security sandbox**. A same-user agent
that is malicious or buggy can read or write outside its worktree, and Pine
does not claim to prevent that. Worktrees are also **not a conflict-free merge
mechanism**: three tasks on one repository can still produce overlapping,
conflicting changes. Pine routes and isolates; it does not sandbox or
merge.

Pine also **cannot prevent every external actor from creating a duplicate
worktree**. The adoption contract rejects ambiguous or foreign environments
(fail closed); it does not police the filesystem. A duplicate created outside
Pine makes the affected task's environment unavailable until a user resolves
it, not a silently shared one.

## Concurrent ownership of agent-managed worktrees

- The task's expected task/repository identity is **reserved before
  launch**; only environment setup and reporting are permitted pre-binding.
  Implementation, checks, review, and try actions remain prohibited until
  the single-task binding succeeds.
- **No duplicate creation**: the bindings actor refuses to reserve an
  expected worktree path another active reservation already targets, and a
  fresh reservation requires the target to be absent.
- **Ambiguous adoption is rejected**: discovery must yield exactly one
  candidate; two candidates, a symlink alias of another task's active
  worktree, or a mismatched branch all fail closed. Filesystem proofs
  (device/inode/generation), not path strings, decide identity, so two tasks
  cannot acquire the same filesystem object through alternative spellings.
- **Unavailable environment behavior**: a moved parent, replaced
  worktree, or agent-created branch change invalidates the lease and
  binding for that task only; revalidation fails closed and the task needs
  an explicit user action to recover.

## Launch admission: the documented limit `N` and honest `N+1`

`AgentTaskConcurrencyAdmission` (`Pine/Agent/AgentTaskConcurrencyAdmission.swift`)
is the FIFO gate every Pine-owned launch must pass before a provider process
starts. This slice DEFINES the gate and its bounds; the launch-path wiring
that routes every Pine-owned launch through it lands with the first adapter
slice ([#1811](https://github.com/batonogov/pine/issues/1811)) — until then
no production code calls it, and "N is enforced" is proven at the primitive
level, with launch-path enforcement PENDING-GATE. There is one admission
bucket per **canonical project (repository)
path**: the binding contract holds at most one active task per
(repository, worktree) pair, so independent worktrees of the same repository
share the bucket, and `N` is enforced per repository across its worktrees.

- **`N = 3`** (`AgentTaskConcurrencyLimits.maximumConcurrentAgentTasks`).
  Rationale: the release target proves three independent same-repository
  tasks, and each concurrent agent holds a PTY, a provider process, a
  terminal view, and bounded evidence/output buffers. `N` is an internal
  constant pinned to that proven floor — not a user setting and not a fleet
  size.
- **`N+1` queues, honestly**: with `N` active, a new request receives a
  queue position (FIFO, bounded at 8) or an explicit deferral when the
  queue is full. It never starts another agent process. The queue is
  presented as waiting, not running.
- **One slot per task**: a second request for the same active or queued task
  is rejected as a duplicate. A new attempt re-requests after its
  predecessor is released, so cancellation and relaunch cannot duplicate
  work.
- **Launch generation**: every granted launch receives a monotonic
  per-project generation. Event traffic and child-job ownership are
  attributed to that generation; a superseded or cancelled grant is dead and
  its generation is never reused. **Enforcement obligation**: the gate
  carries the fencing (events record `runID` and `launchGeneration`) but does
  not filter it — the integration caller must, before acting on a drained
  event, compare the held grant against the gate's current grant and/or
  filter the event by its `runID`/`launchGeneration`. That comparison is part
  of the #1811 launch-path wiring, not of this slice.
- **Release discipline**: the slot is released when the task's process
  ends, is cancelled, or is torn down. Release promotes at most one queued
  request per freed slot, and a double release is a no-op. A crash between
  grant and spawn holds the slot until process death: admission state is
  runtime-only and there is no automatic release — the relaunch requests a
  fresh grant, which is the honest behavior.

## Resource bounds under stress

`AgentTaskEventBoundaries` (`Pine/Agent/AgentTaskEventBoundaries.swift`)
bounds concurrent task traffic per project. The bounds apply **per actor
instance**: the integration owns one instance per project (an app-wide
single instance is also valid and stricter).

| Bound | Value | Behavior at the bound |
|---|---|---|
| Queued events per task | 256 | further non-authoritative events dropped; authoritative events fail closed |
| Queued events across tasks | 4,096 | same |
| Event payload | 64 KiB | truncated to the bound, admitted as `.truncated` |
| Coalescing keys per task | 32 | further keyed deltas dropped |
| Coalescing key length | 256 bytes | event dropped (non-authoritative) or failed closed (authoritative); never retained |
| Captured output per task | 1 MiB | retention stops; task flagged truncated |
| Retained diagnostics per project | 4 MiB | retention stops; pool flagged overflowed |

- **Coalescing**: non-authoritative deltas that carry a stable coalescing
  key — per task, attempt (`runID`), and launch generation — replace their
  predecessor in place; the delta count is retained so presentation can say
  "N updates coalesced", not show a stream.
- **Fail closed**: authoritative lifecycle and request/response traffic is
  never coalesced or silently dropped. When it cannot be retained, admission
  returns `.overflow` and a sticky per-task marker is set; the task degrades
  to needs-decision/`unknown`. The marker is cleared only by the task's own
  teardown.
- **No cross-task leak**: a task's teardown removes its queue, overflow
  marker, and output budget; another task's traffic is untouched.

## Cross-task fencing

Evidence and events are fenced by, at minimum:

- **task** — the registry routes evidence to a single task; a fact for run
  `R` recorded against task `T'` that does not contain `R` is fenced
  `unknownRun` and changes nothing in `T'`;
- **attempt** — `runID` (one durable attempt);
- **launch generation** — the admission generation that owns the event
  traffic and child jobs for that attempt;
- **environment** — facts record an `AgentTaskEnvironmentIdentity`; Ready
  and re-verification require the fact's environment to equal the current
  caller-proven environment (mismatch → `environmentChanged`/stale), and
  environment revalidation is per task, so one task's environment change
  cannot invalidate another's;
- **process incarnation** — `processGeneration` (PID-reuse fence);
- **session identity** — the provider's opaque vendor session reference
  (foreign or nested sessions fenced `foreignVendorSession`).

Layer attribution — what enforces which key: the registry fences recorded
evidence by task, attempt (`runID`), process incarnation, and session
identity, and the reducer adds environment comparison at Ready and
re-verification. `AgentTaskEventBoundaries` fences queued traffic by `taskID`
ONLY; the `runID`/`launchGeneration` carried on each queued event is
enforced by the integration caller's grant comparison (see Launch generation
above) and by the registry/reducer when drained events become recorded
facts. This slice carries the keys; the #1811 wiring enforces them.

One task's events cannot settle, answer, or invalidate another task's
attempt. Each task's Ready, needs-decision, unread, verification, and
acceptance state is derived only from that task's own fenced facts and
snapshots.

## Presentation: task-local attention, exact routing

- Tasks and their actionable attention live in the **project/task context**.
  There is **no standalone Inbox, no wall of terminals, and no
  agent-topology dashboard** for ADE tasks.
- Attention is exact: a delivered notification is matched against
  `task + run + process generation` before any action is offered
  (`matchesNotificationRoute`); a route identity for another task matches
  nothing.
- **Intermediate activity is not a notification stream**: a live working
  transition changes only the execution dimension; attention, unread state,
  and notifications are produced solely by settled outcomes and unresolved
  requests, per task.

## Failure paths

- **Cancellation**: releases the task's admission slot (promoting the queue),
  clears its event queue, overflow marker, and output budget, and tears down
  exactly its owned descendant jobs. Unknown-ownership jobs stay unknown and
  are never reaped.
- **Relaunch**: admission state is runtime-only and per grant; a relaunch
  requests a fresh grant with a fresh generation. A cancelled or superseded
  grant is dead: no double release, no duplicate promotion, no inherited
  resources. Environment recovery after a crash uses the existing
  restore-only path — it observes the persisted intent and never issues a
  fresh creation.
- **Worktree removal**: post-binding removal invalidates that task's
  revalidation (stale binding); the other tasks' environments are
  unaffected. No silent recreation without an explicit user setup action.
- **Moved projects**: project and parent leases pin the original directory
  instances; a move fails the lease and therefore the binding, per task.
- **Dirty trees**: setup population never overwrites; an unexpected
  untracked collision fails closed. Dirty worktrees after adoption do not
  invalidate the binding instance but do invalidate verification snapshots
  through the existing code-state identity.
- **Branch/worktree collisions**: reserved-path conflicts are rejected at
  reservation; object-identity collisions (including symlink aliases) are
  rejected at adoption; both fail closed without touching the other task.
- **Agent-created environment changes**: a branch change or instance
  replacement inside one task's worktree invalidates only that task's
  binding on the next revalidation.

## Try-the-result

Every try-the-result command is a **distinct user action** followed by
**immediate environment and grant revalidation for that task** (binding
authority, filesystem lease, branch, and repository instance). Worktree
routing does **not** authorize deployment, publication, external-service
mutation, or credential access.

## Settings and service isolation (audit additions)

`AgentTaskSettingsIsolation` (`Pine/Agent/AgentTaskSettingsIsolation.swift`)
records the scope of each mutable setting/service and decides whether two
launches may run concurrently.

| Setting/service | Scope | Isolated across concurrent launches | Serializable on conflict |
|---|---|---|---|
| Terminal environment (PTY env) | session | yes | yes |
| Working directory / cwd | directory | yes | yes |
| Worktree-local git config | directory | yes | yes |
| DerivedData / build artifacts | owned process | yes | yes |
| Launch command-line flags | owned process | yes | yes |
| Global git config | global | no | no |
| Agent native configuration | global | no | yes |
| Forwarded MCP server definitions | global | no | no |
| Approval policy (agent native) | global | no | yes |
| Provider credentials | account | no | no |
| Provider account/billing | account | no | no |

Rules:

- Each launch captures an **immutable settings snapshot** at spawn time. A
  settings change after capture never rewrites another task's or reviewer's
  snapshot; revalidation compares live values against the snapshot and fails
  closed on difference.
- Two launches that vary a shared **non-isolated** setting to different
  values are decided by the compatibility check: **serializable** conflicts
  require serialization of the conflicting operation, and non-serializable
  ones are exposed as a **concretely unsupported combination**. Unknown
  setting names fail closed as non-isolated and non-serializable. The check
  is consulted at launch; performing the serialization (and capturing the
  snapshots it compares) is owned by the #1811 adapter integration — this
  slice classifies, it does not yet serialize.
- Two launches with the **same canonical directory** are supported: the
  directory-scoped settings are isolated per task environment (worktree),
  and shared values never conflict.
- **Child jobs after the parent turn end**: the ownership rule selects
  teardown targets from observed jobs by `task + run + launch generation`
  (`teardownTargets`): exactly the owned descendants of the torn-down
  generation, preserving shared services and unrelated tasks' jobs, and
  leaving unknown ownership unknown. The job observation store that feeds
  it is owned by the #1811 adapter integration.
- Adapter boundary note: the required adapters inherit their native
  configuration scope (global/account) at launch. Where that scope cannot be
  isolated per task, the compatibility decision above is consulted at
  launch — serialization or a stated unsupported combination, never a
  promise of safe concurrency; executing that serialization is part of the
  #1811 adapter integration.

## Acceptance mapping

| Acceptance criterion (#1728) | Where it is proven |
|---|---|
| ≥3 independent same-repo tasks run concurrently with no cross-task contamination | `AgentTaskParallelTaskStressTests` (three same-repo worktrees bound and revalidated independently; cross-task evidence, readiness, attention, and routing fenced) |
| Documented `N` enforced; `N+1` queues/defers honestly with no extra process launch | `AgentTaskConcurrencyAdmissionTests` (admission gate: 3 grants, 4th queued, only grants start processes, bounded queue, honest deferral) — enforced at the primitive level; launch-path enforcement is PENDING-GATE, wired in #1811 |
| Every action uses its own validated environment and current grant; ambiguous/unavailable binding fails closed | `AgentTaskParallelTaskStressTests` (per-task revalidation; duplicate path, ambiguous candidate, alias, and foreign-object adoption all fail closed) |
| Documented cwd/routing guarantee + "not a sandbox / not conflict-free merge" statement | this document |
| Attention task-local, no standalone Inbox, intermediate activity is not a notification stream | `AgentTaskParallelTaskStressTests` (attention/unread independence; exact `task+run+generation` notification routing) + this document |
| Cancellation and relaunch preserve truthful per-task state without duplicating work | `AgentTaskConcurrencyAdmissionTests` (release/cancel/promote, dead grants, double-release no-op) + `AgentTaskEventBoundariesTests` (per-task teardown) + `AgentTaskParallelTaskStressTests` (crash-between-writes across a real persistence boundary: the durable journal survives the encode/decode round trip, all runtime admission state dies and an explicit re-request is required) |
| Queued events, output, processes, diagnostics within documented bounds under stress | `AgentTaskEventBoundariesTests` + `AgentTaskConcurrencyAdmissionTests` (bounds held under burst) |
| Audit: recorded setting scopes; two tasks + reviewer with differing settings (incl. same canonical directory); serialize-or-unsupported; child-job ownership; adapter boundaries | `AgentTaskSettingsIsolationTests` + the settings table above |

The real three-task provider run is the final gate after
[#1811](https://github.com/batonogov/pine/issues/1811); everything above is
proven with deterministic fixtures and no real providers.
