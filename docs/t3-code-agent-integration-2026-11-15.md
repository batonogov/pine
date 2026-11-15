# T3 Code agent integration: mechanisms Pine should borrow

Research for [#1798](https://github.com/batonogov/pine/issues/1798), dated
2026-11-15. This is an implementation map, not a claim of tested competitor
performance or delivered Pine integration.

## Decision in one minute

**Borrow the complete control loop, not the Electron application.** T3 connects
real agent runtimes to a durable application workflow through bidirectional
adapters. It does not need to interpret a terminal screen to answer a permission
request, stop a turn, or continue a particular conversation.

Pine already has useful protocol, authority, persistence, environment-binding,
and evidence primitives. At the inspected Pine revision, however,
`CodexAppServerClient` and `CodexAppServerTaskMapper` are constructed only in
tests, not by a production task controller. The first missing product slice is
**connecting those pieces to one real, authorized Codex task**, not designing a
second generic framework.

Adopt exact session/request routing, explicit capabilities, separate process and
logical lifetimes, and failure-oriented replay tests. Adapt durable command
receipts to Pine's existing storage and privacy contract. Do **not** copy T3's
automatic restart continuation, transcript retention, broad permission grants,
or workspace restoration policies without a separate Pine-specific decision.

**UI scope follows the later maintainer decisions, not older issue bodies:**
[#1760 removes built-in code presentation][scope-code] and
[the embedded terminal][scope-terminal], replacing them with task-local
[Request and explicit Command modes][scope-input]. Preserve owned execution,
questions, bounded diagnostic output and result comparison; do not reinstate an
editor, terminal emulator or standalone Inbox to implement an adapter. The
earlier full-terminal wording in #1798 is superseded by these recorded decisions.

**Product ambition:** do not stop at T3 feature parity with a native skin. The
intended advantage is less human supervision between intent, a checked usable
revision and the next decision, delivered with coherent native Mac interaction
and visual craft. #1762 must measure handling time, interruptions, recovery and
outcome quality; #1735 owns the implemented interaction/craft standard. This
report does not establish market leadership, a performance lead or a finished
design. More adapters and more permanent controls are not substitutes.

## Revisions, method, and limits

| Item | Evidence |
| --- | --- |
| T3 source | [`843893e58c3f8fcc1ecce970411e439d1fa69002`][t3-revision], detached checkout; source and selected tests inspected, none executed |
| Pine baseline | [`e174179fb7d09eeb7ea33d81ef0ef346df26ea3a`][pine-revision], fetched `origin/main`; working tree initially clean |
| Documentation | T3 architecture/provider guides supplied orientation; claims below are tied to implementation unless explicitly labeled documentation-only |
| Runtime observation | Local prerequisites only, observed 2026-11-15T05:22:30Z; no T3 agent session, login, prompt, paid generation, approval, or recovery experiment |
| Machine | macOS 27.2.1, build 26B131, arm64; Node v26.13.1 |
| Probe blocker | No `t3` executable or T3 Code app in `/Applications` or `~/Applications`; no `pnpm`, `vp`, or installed dependencies in the research checkout |

T3 pins Node 26.13.1 and pnpm 12.14.0; its root `prepare` runs
`vp config --no-agent` ([manifest][t3-manifest]). Node is available, but a runnable
T3 environment is not. Dependency/bootstrap scripts were not executed and no
application was installed. The real launch → question/denial → continuation →
disconnect/recovery probe is therefore **blocked on preparing a reviewed,
isolated T3 installation**, not passed. A bare Codex handshake would not close
that gap. macOS 26 behavior, T3 UI usability, and both products' end-to-end
integration remain unmeasured here.

Evidence labels used below:

- **S:** inspected source or test assertions; not proof the tests pass.
- **D:** upstream documentation claim only.
- **R:** runtime observation. Here R covers prerequisites only, not agent behavior.
- **Partial / planned / absent:** scoped to the pinned Pine source and named
  workflow, not every pending PR or external branch. No feature below is labeled
  implemented-and-runtime-verified by this research.

## How the agent cycle actually works

### 1. Send is a command with an identity, not a terminal write

In [client commands][t3-commands], `startThreadTurn` allocates a stable `commandId`
and retains the supplied `messageId`. A first message can use `launchThread` with a workspace strategy;
an existing thread uses `message.dispatch`. `dispatchMessage` bounds retries
after socket loss and resends the **same command**, rather than inventing another
user message.

[ThreadMessageIntake.dispatchCommand][t3-intake] claims attachments and delegates
to `ThreadManagementService.dispatch`, then `Orchestrator.dispatch`.
The [orchestrator][t3-orchestrator] makes decisions against stored state;
[EventSink.commitCommand][t3-sink] commits events, projections, an effect-outbox
entry, and a command receipt together, publishing after the transaction.
[EffectWorker][t3-worker] executes `provider-turn.start` through
`ProviderTurnStartService.start`.

**Useful boundary:** an accepted command means intent was saved, not that the
agent received the prompt. Receipt deduplication at the application boundary does
not establish exactly-once delivery across a crash inside an external provider.

### 2. An adapter owns protocol differences

[ProviderAdapterV2][t3-contract] separates a driver from a configured/account-owning
instance. `openSession` returns a runtime exposing `ensureThread`, `resumeThread`,
`startTurn`, `steerTurn`, `interruptTurn`, `respondToRuntimeRequest`,
`readThreadSnapshot`, `rollbackThread`, and `forkThread`, with capabilities and
unsupported errors. Events identify provider sessions, threads, turns, tools,
requests, and subagents separately.

Concrete integration shapes are visible in source:

| Agent | Integration inspected (S) |
| --- | --- |
| Codex | `CodexAdapterV2` uses `effect-codex-app-server`; `makeCodexAppServerSpawnCommand` supervises the native process and the [client][t3-codex-client] uses child stdio. One instance can serve multiple threads; routing is explicit, not “one process equals one task.” |
| Claude Code | [ClaudeAdapterV2][t3-claude] wraps `@anthropic-ai/claude-agent-sdk`, including native executable selection, query creation, `resume`, permission mode and `canUseTool`. It is not merely parsing `claude` terminal output. |
| ACP | The [shared ACP adapter][t3-acp] owns runtime launch, prompt/cancel, permission requests and session restoration, with explicit provider differences. ACP is a reusable transport, not a promise of feature parity. |
| OpenCode V2 | A [dedicated adapter][t3-opencode] uses the OpenCode server/client API, permissions and forms. Per-thread MCP names/rules separate access in a shared instance; unsupported forms are declined with an explanation, not silently accepted. |

`ProviderTurnStartService` resolves the runtime policy, ensures or resumes the
specific native thread and dispatches through the runtime
([implementation][t3-start]). The adapter, not a universal UI assumption, handles
settings and protocol timing. Codex `startNativeTurn`, for example, reads
`config/read` for the task cwd before starting the native turn.

**For Pine:** reuse native CLI configuration and account ownership; expose
requested versus confirmed settings through #1765. Do not port T3's process
sharing or directory-scoped MCP policy before Pine needs it. Hooks and MCP may
execute during native startup; a handshake is neither account proof nor a
security sandbox.

The return path is explicit too: `ProviderSessionManager.startEventPump`
consumes the runtime event stream, persists session updates, ingests
session-scoped requests/background artifacts, and publishes other events to
run subscribers ([pump][t3-event-pump]). `RunExecutionService.routeEvent` and
`ingestDelivered` bind those events to their owning run/attempt before
`ProviderEventIngestor.ingestNormalized` writes domain events through the event
sink and projections ([run ingestion][t3-run-ingestion],
[normalizer][t3-ingestor]). Committed domain state then reaches subscribed
clients through the event sink's stream.

Not every visible byte is durable state: `command_output.delta` bypasses domain
persistence and subscribers for the separate live-output channel, so output
floods do not hold up lifecycle/request events. Final command items take the
domain path. The [ingestor test][t3-ingestor-tests] named “normalizes provider
events through the real event log and projection store” asserts the return-path
event, projection and sequence behavior; it was read, not executed here.

### 3. Permissions and questions have different delivery semantics

In [CodexAdapterV2][t3-codex], a blocking `item/tool/requestUserInput` creates a
runtime request and waits on a `Deferred`. `respondToRuntimeRequest` resolves the
exact pending request and returns answers under native question IDs. Command
and patch approvals use the same bidirectional pattern with native decisions.

At the application boundary, the orchestrator records the user's resolution
before the side effect. [RuntimeRequestService.respond][t3-requests] re-reads it,
requires `resolved` and a matching live provider session, then calls the adapter.
A saved resolution is therefore not proof the live callback received it.

There is also a **nonblocking question** path: an async Codex `agentMessage`
becomes a request with `responseMode: "message"`. Its answer becomes a later
message, not a reply to a nonexistent JSON-RPC request. The orchestrator's
`responseCapability.type === "message"` branch handles this distinction.

This matters for recovery: [ProviderRuntimeRecoveryService][t3-recovery] can
preserve message-answerable questions and convert certain lost live questions
to that path, while expiring other process-bound requests. That is a deliberate
semantic change, not restoration of the original live callback.

**For Pine:** first ship exact blocking question/approval round trips, denial,
and honest uncertain delivery. Add any asynchronous/recovered-question path only
when the pinned provider supports it and the UI discloses the changed delivery.
Do not resurrect an expired permission or transfer grants to a new attempt.

### 4. Parent completion does not erase children or the process

Codex tracks running commands, dynamic tools, image work, and native subagents.
`hasPendingBackgroundWork` and `hasPendingBackgroundWorkForThread` prevent idle
release from discarding known work. `turn/completed` is processed by
`finalizeCodexTurn`, including interruption state; child completion can enqueue
a continuation after the parent's turn has already ended
([adapter][t3-codex], [session manager][t3-sessions]).

This is not equivalent to Pine's **Ready**. T3 run completion, checkpoint
finalization, thread settlement, and a human accepting a result are distinct
concepts; none supplies Pine-observed checks plus independent-review evidence
bound to the exact candidate.

**For Pine:** retain `parentSettlementUnknown` until aggregate closure can be
proven. #1795 supplies logical settlement metadata; it does not by itself supply
production evidence of child/tool/question closure.

### 5. Changes and continuation stay attached to their workspace

[ThreadLaunchService][t3-launch] carries explicit root/new/existing-worktree
strategies. Start and restore operations use workspace leases/reservations.
[RunFinalizationService.finalize][t3-finalize] captures a checkpoint separately
from display refresh. PR discovery checks the current branch and newer active
run so an old lookup cannot attach to unrelated later work.

[CheckpointRollbackService][t3-rollback] rejects unsafe shared-workspace file
restore, asks the provider to roll back its conversation, then restores files.
It is not one atomic transaction across Git and the provider: partial failure
still needs recovery. A checkpoint is not an independent verification result.
The [architecture guide][t3-overview] documents hidden Git refs (D); this report
does not certify their capture/restore fidelity.

**For Pine:** adopt exact task → environment → candidate identity now. Defer
automatic checkpoint/revert UI: it introduces destructive semantics beyond
#1798 and needs dirty/untracked-data preservation and honest partial recovery.

### 6. Reconnect and server restart are different

Client socket-loss retries preserve command IDs. The event sink supports replay
and snapshots; [ProjectionMaintenance][t3-maintenance] prunes covered old events,
so the database projections, not an indefinitely replayable event log, are
essential durable state.

Provider process loss is handled separately: recovery cancels or expires
process-bound work, stops persisted sessions, and can enqueue
`provider-runtime.continue` when `continueAfterRestart` allows it. This is
**new continuation**, not proof the old process survived.

**Do not copy that policy into Pine.** Pine restores metadata as unknown/stale;
launching a new agent or native resume requires explicit user action and a new
attempt. Reconciliation of an already-live authenticated channel is a separate
operation. Do not automatically resend a prompt or lost approval response.

### 7. PR follow-through and review guides are real adjacent mechanisms

[PullRequestWatchReactor][t3-watch] sweeps every two minutes, groups reads,
limits repeated failures, and dispatches wake messages for relevant PR changes.
This removes manual relaying of CI failures/comments, but adds forge access,
background execution, stale-head handling and spending/notification policy.

[PullRequestReviewGuideService][t3-guide] prepares a detached scratch checkout,
generates a guide, and stores it with the PR head SHA. It helps a person inspect
a change; it is **not** Pine's independent review approval or Ready gate.

Evaluate watch/guide value under #1762; neither becomes a required 3.0
implementation just because T3 has it. #1759 retains the separate ship/defer
decision for cross-provider handoff.

## Pine gap map at the pinned baseline

All T3 behavior in this table is **S**, not runtime-verified. Pine's evidence
below is also source/test inspection; existing fixture assertions are not new
test results. The [compatibility catalog](agent-compatibility.md) correctly calls
current first-party support **Detected**, not structured.

| Capability | Pine source status and evidence | Decision / owner |
| --- | --- | --- |
| Bidirectional transport | **Partial:** [client and connection][pine-client] implement owned-stdio initialization, correlated calls, bounds, loss fencing and response replay authority. No production construction of the client/mapper was found; call sites are in `PineTests`. | **Adapt:** connect existing seams in #1723; do not create another transport. |
| Shared lifecycle/capabilities | **Partial:** [adapter protocols][pine-protocols] provide negotiated ingress and start/stop, not T3's full control API. [Reducer][pine-reducer] separates execution/evidence and rejects false Ready. | **Adapt:** extend only operations required by the first slice in #1722/#1723, using #1765's actual capabilities. |
| Worktree before implementation | **Partial:** [environment bindings][pine-environment] reserve and adopt a validated linked tree; explicitly do not create it. | **Adopt invariant:** #1796 creates/reconciles the one reserved tree before #1723 launch; never fall back to the main checkout. |
| Questions/permissions | **Partial:** [mapper][pine-mapper] scopes requests to connection/thread/turn; [approval policy][pine-approval] limits one-shot responses. No complete production task/UI round trip here. | **Adapt:** #1723 with #1765; preserve native IDs, deny and unsupported states; do not imitate broad grants. |
| Durable delivery intent | **Partial:** [metadata store][pine-store] and registry preserve bounded tasks/launch intent. No production Codex dispatch receipt/controller path found. | **Adapt minimal intent/result record:** #1723 first dispatch; #1756 continuation, under #1722 storage semantics. No second store or mandatory event-sourcing migration. |
| Logical versus physical settlement | **Partial:** mapper returns `parentSettlementUnknown`; reducer `isSettled` still requires terminated liveness and `endedAt`. | #1795 is prerequisite metadata; #1723 must prove aggregate closure before production settlement. Never fabricate process exit. |
| Effective model/account configuration | **Partial:** Codex account observation/authority primitives exist, but not a verified production settings-selection flow. | #1765 → provider implementation in #1723; no global account mutation or silent billing fallback. |
| Same-task next turn and recovery | **Planned integration:** primitive loss handling stops the client; task restoration preserves stale metadata, not a live conversation. No production `thread/resume`/next-turn controller found. | #1756 + #1723; exact provider identity, explicit resume, no “latest conversation” fallback. |
| Diff/result linkage | **Partial:** Git/editor features and [content identities](ade-content-identities.md) exist; no complete structured Codex task → result/checkpoint/PR pipeline found in inspected callers. | #1753/#1725 for identity/result; #1758 for revision-bound comparison. Defer checkpoint revert and automatic PR watching. |
| Independent checks and review | **Partial foundations / planned execution:** reducer requires bound facts; this does not implement their runners or reviewer delivery. | #1794 → #1754 checks; #1755 review; #1761 proves the integrated result. T3 completion/guide cannot substitute. |

### Pine search and test trail

Search production and tests separately, at the pinned baseline:

```sh
rg -n 'CodexAppServerClient\(|CodexAppServerTaskMapper\(' Pine PineTests
rg -n 'thread/resume|turn/start|parentSettlementUnknown' Pine/Agent
rg -n 'AgentTaskEnvironmentBindings\(|bindEnvironment\(|recordEvidence\(' Pine
```

The first search finds constructions in tests only. Relevant existing tests:
`CodexAppServerClientTests` (pipe loss does not restart another provider),
`CodexAppServerTaskMapperTests` (buffered questions/parent completion, exact
ownership, cancellation and duplicates), `CodexAppServerReplayAuthorityTests`,
`CodexAppServerApprovalPolicyTests`, `AgentTaskEnvironmentBindingTests`,
`AgentTaskLifecycleEvidenceTests`, and `AgentHistoryPersistenceTests`.
They are useful starting points, not evidence that the production journey works.

## Failure cases worth importing into our acceptance matrix

These T3 tests were **read, not run**. Some create synthetic transcripts in the
test itself; replay-shaped data is not automatically a recording of a real
binary. Preserve that provenance distinction in Pine fixtures.

| Case | Concrete T3 test/source | Pine acceptance owner and safety requirement |
| --- | --- | --- |
| Lost send acknowledgement / duplicate delivery | [client command tests][t3-command-tests]: retries lost dispatch with the same command ID; caps repeated socket loss | #1723/#1756: duplicate application command cannot launch a second turn; uncertain provider delivery is reconciled, never blindly resent |
| Denial and stale request | [runtime-request tests][t3-request-tests]: passes `decline` and feedback only for resolved requests; rejects expired requests | #1723: denial reaches exact native request once; stale/foreign request cannot authorize anything |
| Native question identity / async question after completion | [Codex adapter tests][t3-codex-tests]: native question ID round trip; async question remains actionable after turn completion | #1723: prove blocking control first; unsupported async semantics remain explicit; no revived live callback |
| Stop before native start / late child or descendant | Codex adapter tests: waits for native start before interrupting queued turn; contains descendants; wakes parent on a late native child | #1723/#1795: cancellation stays requested until confirmed; child event routes to original owner; no false Ready |
| Process exit / hung process | Codex adapter tests: process-exit suite and bounded stop of an app-server ignoring SIGTERM | #1723: retain cleanup ownership and unknown delivery; no successful outcome from exit |
| Restart with pending question / background subtree | [recovery tests][t3-recovery-tests]: expires orphaned requests, preserves async questions, cancels in-flight subtree without reopening it | #1756: preserve task/history, invalidate live evidence, require explicit launch/resume; do not adopt automatic restart continuation |
| Unsafe workspace restore | [restore safety tests][t3-restore-tests]: preserves overlapping-workspace files for nested/ancestor/provider/sibling owners | #1728/#1725: protect other tasks and dirty data; any future revert needs its own authorization and recovery contract |
| Stale PR lookup / display refresh failure | [finalization tests][t3-finalize-tests]: newer turn replaces old PR lookup; display refresh does not block checkpoint finalization | #1725/#1758: old asynchronous result cannot overwrite current revision or task context |

For real-runtime evidence under #1761, record the binary version, transport,
effective settings, authorized environment and sanitized event classification.
Do not commit raw conversations, account identifiers, credentials or private
paths. Synthetic negative cases supplement, not replace, pinned-binary probes.

## Minimal implementation sequence, using existing issues

1. **Environment and intent — #1796 → #1723, #1722.** Persist the exact task/attempt
   and launch intent; create/reconcile only its reserved tree; revalidate binding
   and native executable immediately before launching one owned Codex process.
   Acceptance: double submit and timeout-after-create produce at most one
   environment; no model starts in an unbound/main checkout; ambiguous effects
   preserve artifacts and block. Removes manual worktree routing without giving
   a task blanket command/publication authority.
2. **Real structured task and decisions — #1723 + #1765.** Compose existing
   client/mapper/registry with a production task controller and contextual
   decision surface. Prove one prompt, streamed state, a real question and
   approval, denial, cancellation and process-loss behavior on the pinned binary.
   Include a minimal task-bound change summary: capture the validated
   environment/candidate identity using #1753, report actual affected paths or
   counts with explicit unknown state, and bind the summary to that attempt.
   An old event cannot attribute changes to a newer task/revision. Keep any
   code/diff inspection outside the removed built-in editor UI; the summary is
   not a checkpoint, review or verification pass.
   Extend the event allowlist only for demonstrated required capabilities;
   retain bounded ingress and exact source authority. User need not hunt through
   terminal output; unsupported controls never default to “proceed.”
3. **Honest settlement and continuation — #1795 → #1723/#1756.** Prove aggregate
   closure, settle logically without killing a reusable process, and send a
   subsequent authorized message to the exact conversation as a new attempt.
   Persist dispatch ambiguity at the existing task boundary. Acceptance: late
   children/approvals cannot settle a newer attempt; restart restores unknown/
   stale state and starts nothing; explicit resume failure keeps the task.
   Removes context reconstruction without storing full transcripts or granting
   new execution authority on restoration.
4. **Usable, checked revision — #1753, #1794 → #1754/#1755 → #1725/#1758.**
   Bind actual changes to the task, execute authorized required checks, run an
   independent read-only review, and offer the project-appropriate result action.
   Acceptance: edits during checks invalidate evidence; missing review cannot
   produce Ready; opening a result neither executes nor accepts it. Removes
   manual reviewer relaying while keeping consequential actions explicit.
5. **Prove before broadening — #1761/#1762.** Exercise first-use and repeat-use
   journeys, failure/restart cases, Request/Command input, task-local output,
   result comparison and accessibility.
   Record human intervention and recovery costs separately from agent runtime.
   Then apply the shared contract to Kimi #1732 and Claude #1727, respecting
   capability differences. No fourth required provider is introduced.

Steps 1–3 are the first integration slice; step 4 is what earns Pine's checked
result promise. #1759 still owns handoff evaluation. PR watching, generated
review guides and checkpoint/revert are **deferred candidates**, not new release
gates or implementation tasks created by this report.

## License and reuse

At the pinned revision T3 Code's root [license][t3-license] is MIT,
copyright © 2026 T3 Tools Inc. Copies or substantial portions of its software
must retain the copyright and permission notice; check per-package/third-party
notices before copying code. MIT permission does not by itself grant trademark
or artwork rights.

This change copies no T3 implementation or fixtures and adds no dependency.
Reimplement selected mechanisms idiomatically within Pine's existing Swift
boundaries; record provenance and include required notices if substantial code
is later reused. Learning from the design is not permission to bypass Pine's
authorization, privacy or verification contract.

[t3-revision]: https://github.com/pingdotgg/t3code/tree/843893e58c3f8fcc1ecce970411e439d1fa69002
[pine-revision]: https://github.com/batonogov/pine/tree/e174179fb7d09eeb7ea33d81ef0ef346df26ea3a
[t3-manifest]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/package.json
[t3-license]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/LICENSE
[t3-commands]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/packages/client-runtime/src/operations/commands.ts
[t3-command-tests]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/packages/client-runtime/src/operations/commands.test.ts#L311-L459
[t3-intake]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/ThreadMessageIntake.ts
[t3-orchestrator]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/Orchestrator.ts
[t3-sink]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/EventSink.ts#L763-L869
[t3-worker]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/EffectWorker.ts
[t3-contract]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/packages/provider-core/src/server/ProviderAdapter.ts
[t3-codex]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts
[t3-codex-client]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/packages/effect-codex-app-server/src/client.ts
[t3-claude]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts#L1469-L1595
[t3-acp]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/packages/provider-acp/src/server/adapter.ts
[t3-opencode]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/packages/provider-opencode/src/server/v2/adapter.ts
[t3-start]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/ProviderTurnStartService.ts
[t3-requests]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/RuntimeRequestService.ts#L78-L123
[t3-event-pump]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/ProviderSessionManager.ts#L2744-L2866
[t3-run-ingestion]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/RunExecutionService.ts#L1517-L1574
[t3-ingestor]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/ProviderEventIngestor.ts#L733-L783
[t3-ingestor-tests]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/ProviderEventIngestor.test.ts#L521-L601
[t3-request-tests]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/RuntimeRequestService.test.ts
[t3-recovery]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/ProviderRuntimeRecoveryService.ts
[t3-recovery-tests]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/ProviderRuntimeRecoveryService.test.ts
[t3-sessions]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/ProviderSessionManager.ts
[t3-launch]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/ThreadLaunchService.ts
[t3-finalize]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/RunFinalizationService.ts
[t3-finalize-tests]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/RunFinalizationService.test.ts
[t3-rollback]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/CheckpointRollbackService.ts#L303-L345
[t3-restore-tests]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/CheckpointRestoreSafety.test.ts
[t3-overview]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/docs/internals/overview.md
[t3-maintenance]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/ProjectionMaintenance.ts
[t3-watch]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/PullRequestWatchReactor.ts
[t3-guide]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/pullRequest/PullRequestReviewGuideService.ts#L300-L425
[t3-codex-tests]: https://github.com/pingdotgg/t3code/blob/843893e58c3f8fcc1ecce970411e439d1fa69002/apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.test.ts
[pine-client]: https://github.com/batonogov/pine/blob/e174179fb7d09eeb7ea33d81ef0ef346df26ea3a/Pine/Agent/Adapters/CodexAppServerClient.swift
[pine-protocols]: https://github.com/batonogov/pine/blob/e174179fb7d09eeb7ea33d81ef0ef346df26ea3a/Pine/Agent/Adapters/AdapterProtocols.swift
[pine-reducer]: https://github.com/batonogov/pine/blob/e174179fb7d09eeb7ea33d81ef0ef346df26ea3a/Pine/Agent/AgentTaskLifecycleReducer.swift
[pine-environment]: https://github.com/batonogov/pine/blob/e174179fb7d09eeb7ea33d81ef0ef346df26ea3a/Pine/Agent/AgentTaskEnvironmentBinding.swift
[pine-mapper]: https://github.com/batonogov/pine/blob/e174179fb7d09eeb7ea33d81ef0ef346df26ea3a/Pine/Agent/Adapters/CodexAppServerTaskMapper.swift
[pine-approval]: https://github.com/batonogov/pine/blob/e174179fb7d09eeb7ea33d81ef0ef346df26ea3a/Pine/Agent/Adapters/CodexAppServerApprovalPolicy.swift
[pine-store]: https://github.com/batonogov/pine/blob/e174179fb7d09eeb7ea33d81ef0ef346df26ea3a/Pine/Agent/AgentTaskMetadataStore.swift
[scope-code]: https://github.com/batonogov/pine/issues/1760#issuecomment-6865382550
[scope-terminal]: https://github.com/batonogov/pine/issues/1760#issuecomment-6865403291
[scope-input]: https://github.com/batonogov/pine/issues/1760#issuecomment-6865414122
