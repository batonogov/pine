# ADR 0003: Durable agent task identity

Status: Accepted

## Context

Pine already observes agent processes through terminal-scoped `AgentSession`
values and joins those session IDs to Activity, History, provenance, verified
patches, and checked undo. A PID is reusable, a terminal can launch multiple
processes, and a vendor conversation ID is private adapter data. None of these
is a durable user-task identity.

## Decision

Pine keeps five identities distinct:

- `AgentTask.id` identifies durable user intent across windows and app launches.
- `AgentTaskRun.id` identifies one attempt. For compatibility it equals the
  legacy `AgentSession.id`; every resume or relaunch creates a new run/session.
- A terminal ID and its monotonic process generation identify one PTY process
  lifetime. PID and process-start evidence corroborate that lifetime but are
  never sufficient to inherit a task.
- `AgentSession` remains the observed, terminal-scoped run used by badges,
  Activity, History, provenance, verified patches, and checked undo.
- An opaque vendor session identity is an in-memory adapter hint. It is neither
  Pine identity nor authority and is never persisted.

The app-level registry stores value records only. Project and worktree paths
enter through `ProjectRegistry.canonicalProjectURL`. Until #1309 supplies
authenticated repository/worktree provenance, Pine's canonical opened project
root is explicitly also its verified worktree root; no synchronous git or
filesystem discovery runs on MainActor. Runtime pane and tab IDs
are hints: routing must re-resolve the canonical project and exact live
terminal/session/generation, reject duplicate matches, and fail closed when a
project, worktree, pane, tab, run, or generation is unavailable. Uniqueness is
assessed across every live matching pane before the persisted route hint is
checked; a duplicate cannot be hidden by the expected pane.

Manual discovery may create a new observed task only from a unique terminal
plus session plus process-start/generation observation. It never claims an
existing durable task by agent type, PID, cwd, or timing. The existing
Send-to-Terminal action is the production launch boundary only when its complete
payload is one exact canonical executable token from `AgentType.cliNames`.
`TerminalManager` reserves immediately before sending those bytes, carries the
runtime-only token to the detector bridge, and cancels if the terminal rejects
the send. Arguments, whitespace, shell expressions, aliases outside the exact
canonical set, and text typed directly into an interactive shell do not reserve
intent. A terminal-tab context menu is the explicit resume UI: the user selects
a paused durable task, Pine late-resolves exactly one canonical open-project and
target-tab route, reserves that task, and only then sends the exact executable.
No task is inferred from cwd, agent type, or timing.
A claim requires the reserved terminal, project/worktree, agent descriptor,
detector generation floor, and a coherent kernel-derived microsecond process
start later than the captured launch boundary. Pine brackets `proc_pidpath` with
two equal `proc_pidinfo` starts, requires the current executable basename to
match the sampled command token, and requires the coarse `ps lstart` second to
match that same generation. Mixed PID generations grant no ownership. The
registry consumes the
random token exactly once against a monotonic deadline and exact run tail; the
token is never persisted. Untokened polling and pre-existing processes cannot
consume or cancel matching intent. Expired, cancelled, duplicate, or mismatched
claims create no inherited association and expose no usable route.

Window closure only marks a route backgrounded. A tab move updates its pane
hint and does not end the run. Pane/tab removal is termination evidence and
detaches the route exactly once, but is not evidence of successful task
completion. Every accepted run UUID remains a process-lifetime tombstone after
live ownership is removed; delayed detector termination can update or no-op the
original run but can never create another task containing that UUID. A process
replacement, PID reuse, resume, or relaunch ends the old run and creates a new
run. After app relaunch, only an explicit user resume may
convert a runtime-marked loaded interruption into a terminated old run and a
fresh run; persisted route hints never regain live ownership. Failed observation
only makes evidence stale.
Process disappearance and legacy `.done` are termination evidence, not
authenticated success; explicit completion/failure requires later adapter
evidence from #1303.

## Persistence, privacy, and trust

Metadata is stored in one dedicated `0700` private subtree directly below the
trusted Application Support anchor, partitioned by a
hash of the canonical project path and with the canonical worktree retained in
each record. Reads are size-bounded before allocation; schema, counts, strings,
dates, identities, and paths are validated fail-closed. Schema v2 carries an
opaque per-project disk revision. Revision-less schema v1 loads carry an
in-memory SHA-256 token over the exact source bytes, so migration proceeds only
while that legacy baseline is unchanged; the digest is never persisted. Under
the advisory lock, each save
compares its loaded revision immediately before publication, so a stale registry
or second store instance cannot overwrite a newer snapshot. Missing worktrees
are retained with unavailable routes rather than deleted. An unsupported future
schema or an uninspectably oversized file quarantines its project for the process
lifetime, preserving the original bytes and blocking every publication. Writes
use generation/sequence tickets
authorized per project. The publication fence holds its lock across the final
ticket check and `renameat`. A successful publication records its new revision
inside that same fence lock; timeout generation advance atomically consumes the
receipt, so a writer stalled after rename cannot leave the registry CASing from
the old revision. A superseded writer cannot publish after a newer snapshot.
Mutations coalesce behind one current writer; cancelled
abandoned writers are tracked without helper waiters and bounded before another
writer can spawn. Failures remain dirty for a bounded three-attempt quit retry.
If the rename succeeds but directory durability cannot be confirmed, the
registry advances to the published revision while still reporting failure and
retrying; a pre-publication sync failure never advances that revision.
Quit freezes mutations and persists live tasks as a valid paused/stale/missing
snapshot; rollback restores and re-persists the exact runtime lifecycle,
availability, liveness, attention, and chronology. Files and directories are
owner-only, reject any extended ACL entry, and publication uses a same-directory
atomic replacement with durable file and directory sync.
Private components remain bound through a descriptor chain checked before and
after I/O. A private advisory lock coordinates store instances, and bounded
lock/flush deadlines prevent Quit from hanging. Symlinked or replaced storage
paths are rejected. Temporary-orphan cleanup advances a bounded directory cursor
and orders valid stale candidates by age and name, so unrelated entries cannot
indefinitely starve eligible cleanup. Each candidate's device/inode identity is
opened nonblocking and revalidated against the live pathname. Pine then retires
the opened inode through its descriptor (`ftruncate` plus mode `000`) rather
than calling pathname-based `unlink`; a concurrent pathname replacement is
never deleted or truncated. The bounded scan may therefore leave zero-byte
tombstones, preferring harmless directory entries over acting as a confused
deputy for another same-UID process. A global tombstone count and directory-entry
scan cap are checked before creating a writer temp; hitting either fails with a
storage limit instead of growing the directory without bound. Device, inode,
link count, mode, and ACL are revalidated after the final race hook and before
descriptor mutation.

Persisted records never contain prompts, terminal output, command arguments,
file contents, environment values, credentials, transcripts, raw Activity
summaries, process command lines, or vendor-private identity. Optional title
and objective are explicitly user-authored and bounded.

Task/run metadata is routing and presentation metadata only. It never upgrades
observed or inferred evidence to verified. Existing provenance identity
(`project`, canonical worktree, session, terminal, process generation, cursor,
envelope, and journal sequence), private undo authority, consumption checks,
and divergence checks remain mandatory and unchanged.

## Migration and retention

Existing `AgentSession` IDs remain run IDs, preserving all legacy joins. A new
task UUID is minted separately. Observations without detector-owned process
evidence fail closed and cannot create or attach to a task. Unknown schema
fails closed; unknown agent identifiers remain
opaque and grant no action authority. Retention is deterministic per project
and per task, and must not discard active or paused records merely to satisfy
history limits. Runtime task/run/session collections use the same hard limits;
accepted run UUID tombstones are exact and never evicted, so new-run admission
fails closed when their process-lifetime cap is reached. Only
terminal/dismissed history is pruned, while protected overflow fails closed.
Project and worktree together prevent collisions between multiple worktrees of
the same repository.

## Consequences

The cross-project inbox and notifications remain out of scope. Persisted tab
and pane IDs cannot restore a route after relaunch until the user explicitly
selects a paused task and Pine re-resolves the intended live target tab. Richer
resume policy remains tracked by #1307; adapter linkage is tracked by #1303.
