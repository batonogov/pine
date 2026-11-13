# Pine 3.0 — ADE product vision

Status: working product direction; not an implementation or compatibility promise.
Scope reference: [Pine 3.0 — ADE milestone](https://github.com/batonogov/pine/milestone/16).

## Explore the direction

**Describe it. Try it. Refine it.** The
[interactive concept on the landing page](https://batonogov.github.io/pine/#future)
explores project → task → result → contextual feedback. Code and terminal are
available when needed rather than occupying the foreground.

The Web, Go, Python, and DevOps examples are a Russian-language design study
with simulated agents, commands, and checks, not the downloadable application.
[Source and captures](design/pine-3/prototype/README.md) record one composition;
[design validation #1735](https://github.com/batonogov/pine/issues/1735) remains open.

## ADE positioning

Pine 3.0 is the ADE release. Pine becomes a native macOS Agentic Development
Environment: a workspace built around directing coding agents through durable
tasks, not an editor with a chat panel attached. ADE is the product category we
want to own, and outcome-first delegation is our interpretation of it.

Where orchestration-centric ADEs optimize for agent throughput and supervision,
Pine optimizes for verified results and clear decisions. The user should not have
to understand agent topology, terminal routing, or worktree mechanics to get a
result they can try.

The ADE product pillars are:

- **Durable tasks are the unit of work.** A task owns its goal, bounded context
  references, environment, terminal, files, feedback, reviewed states, checks,
  and result across navigation and relaunches without persisting transcripts or
  secrets by default.
- **Reliable agent lifecycle is core infrastructure.** Execution, verification,
  attention, unread, and user acceptance are distinct dimensions. Working,
  blocked, idle, and unknown are execution states; unverified is an outcome, and
  Ready is derived only from current required evidence. Process exit or an
  agent's claim alone never establishes success.
- **Task-owned environments replace terminal management.** Agents manage
  worktrees; Pine discovers, validates, binds, and revalidates the authorized
  environment before implementation, checks, review, or result execution.
  Worktrees provide routing and ownership boundaries, not a security sandbox.
- **Attention replaces supervision.** The Inbox is the attention queue for Ready
  and Needs decision. Intermediate activity stays inside the task, and results
  remain directly accessible in their project context rather than requiring a
  fleet-monitoring dashboard.
- **Verified outcomes are the differentiator.** Every Ready result carries
  Pine-observed checks and independent-review evidence bound to the exact code
  and environment, stated limitations, and a project-appropriate way to try it.
- **Agents are interchangeable execution tools.** Agent-agnostic adapters and
  task-scoped programmatic control APIs prevent Pine from becoming a
  provider-specific chat client. Authenticated structured provider events are
  preferred; terminal text never acquires execution authority.
- **The native Mac workspace remains first-class.** Editor, diffs, and real
  terminals are always available for inspection and intervention, but are not
  mandatory steps in every task.

## Product promise

Give Pine a task. Come back to a result you can try, with clear evidence of what
was checked, or a concrete decision that needs you.

The Pine 3.0 direction is an outcome-first native macOS ADE for making software
with agents. It is not an agent dashboard, a replacement vendor chat, or a
workflow-construction tool. The editor and real terminal remain first-class
tools, available without an agent and directly accessible when the user wants to
inspect or intervene. Task-first describes delegation, not a mandatory task
dashboard or a replacement for the project workspace. Results open in their
project context beside the code; the Inbox is a shortcut to attention, not a
required stop.

## Baseline: what Pine 2.x already ships

Public surfaces describe two things and never blur them:

- **Shipped now (Pine 2.x):** a native SwiftUI + AppKit code editor; a full
  VT100/xterm built-in terminal; CLI-agent detection with badges, activity, and
  privacy-bounded notifications; a cross-project Agent Inbox that routes back to
  the exact live session; isolated agent worktrees; LSP code intelligence; Git
  integration; and session persistence with restoration.
- **Direction (Pine 3.0, this document):** durable tasks, validated
  task-owned environments, reliable agent lifecycle signals, Ready evidence
  from Pine-observed checks and independent review, the Inbox as an attention
  queue, and bounded parallel tasks.

Until each ADE capability ships, copy on every public surface identifies it as
Pine 3.0 direction, not current functionality. No surface mocks unimplemented
ADE screens as shipped, and screenshots show the released UI only.

## Design standard

Build with the coherence, restraint, and platform fit expected of an Apple-made
Mac application. This is a decision-making standard, not a visual imitation.

- Start with the user's work, not providers, process trees, or agent topology.
- Choose useful defaults; reveal specialist controls when they become relevant.
- Use native navigation, keyboard behavior, accessibility, and system conventions.
- Preserve context and work across navigation, failures, and relaunches.
- Make consequential actions understandable and reversible where possible.
- Be quiet during progress and precise when attention is needed.
- Never hide uncertainty behind a reassuring icon or an agent's claim.

## Primary experience

1. Create a task in the current or selected project. Describe the desired outcome
   and add references if the selected agent supports them. Offer a remembered
   agent default when available; choosing a provider is not a mandatory repeated
   step.
2. Pine starts the task using a supported adapter. Agents manage their working
   environment; Pine reserves the expected task/repository identity, discovers
   and validates the environment without issuing duplicate creation, and binds
   it before implementation or verification. Ambiguous environments fail closed.
3. Implementation and required checks happen within the task. Pine executes the
   declared checks in the validated environment and records their actual results.
   A separate, read-only reviewer session then reviews the exact candidate
   against explicit criteria. The user does not have to assemble or manage a team.
4. Review feedback returns automatically to the implementer. One correction round
   is one implementer revision returned for re-review. After three unresolved
   revisions, Pine escalates to Needs decision without a fourth automatic
   attempt; the counter persists across relaunch. Missing permissions, missing
   capabilities, failures, and unresolved decisions are never reported as success.
5. The Inbox surfaces either Ready or Needs decision. Intermediate activity stays
   inside the task and can be inspected without becoming a notification stream.
6. The user tries the result through a distinct authorized action and continues
   with an ordinary message or explicitly supplied visual reference where
   supported. Opening a result changes viewed/unread only; it does not accept the
   result, execute commands, or authorize Git operations.

## Result, not transcript

A Ready result presents, in this order:

- The requested outcome and the changes made to achieve it.
- A project-appropriate way to try it: preview, native build, CLI example,
  backend request, or library tests, using the task environment.
- Verification and independent-review evidence, with limitations stated plainly.
- Changes since the user's last review or acceptance.
- Optional deeper access to files, diff, commands, and terminal.

Ready means the agreed Pine-observed verification and independent-review
requirements were satisfied for this exact result. It does not mean the software
is defect-free or that the user's product judgment has been replaced by passing
tests.

Needs decision presents the specific blocker or question, a recommendation, and
its consequence. If no safe recommendation exists, say so. Preserve the work
and allow a free-form reply instead of forcing a predefined choice. Resolved or
stale requests cannot be answered later.

## Trust and control

- Execution state, verification state, attention state, unread state, and user
  acceptance are distinct. Process exit alone never establishes Ready.
- `working` means a current attempt has an unresolved active turn. `blocked`
  means a current live authenticated attempt has an unresolved question or
  approval. `idle` means a current live session has no active turn or outstanding
  request; it is not task completion. `unknown` means current evidence is absent,
  stale, contradictory, or unsupported.
- `unverified` means an attempt has ended or reported completion without all
  required independent evidence. Observed process completion, agent-reported
  completion, Pine-observed checks, reviewer outcome, Ready, unread, and user
  acceptance remain separate facts.
- Structured provider events are preferred when Pine can authenticate and bind
  their transport. Process identity and terminal evidence are fallbacks, not
  interchangeable proof; terminal text never acquires execution authority.
- Pine executes required checks using argument arrays and bounded supervision,
  recording commands, environment/tool versions, start/end code-state
  fingerprints, exit status or timeout/cancellation, and bounded redacted
  diagnostics. Provider- or reviewer-reported test success is not a substitute.
- Evidence uses a conservative code-state fingerprint and environment identity
  covering relevant tracked, dirty, untracked, and ignored inputs, symlinks,
  submodules, generated files, toolchain versions, and configuration. A commit ID
  alone does not identify a dirty tree. Provider-supplied paths and hashes remain
  untrusted until recomputed beneath the authorized no-follow root.
- Checks and review record pre- and post-operation fingerprints. Subsequent
  changes, ambiguous relevance, environment changes, or relaunch make evidence
  stale and remove Ready until required checks and review cover the new state.
  Reviewed and accepted snapshots remain identifiable; later edits do not
  silently inherit acceptance.
- Invalidation and new-attempt state become durable before dependent positive
  evidence. A crash between metadata and journal writes fails closed rather than
  restoring Ready.
- Stale evidence alone is not a question for the user. Repeat verification only
  under a specific persisted task/command grant that is revalidated immediately
  before execution; escalate only when a real blocker or decision needs attention.
- Independent review uses a separate reviewer session and explicit criteria. The
  reviewer is read-only with respect to the candidate; reviewer-caused changes
  invalidate that review. Another model may be useful but is not, by itself,
  proof of independence or correctness.
- Task-scoped control APIs are bound to the task and its authorized environment.
  Reading terminal output does not turn untrusted text into execution authority.
  User-launched terminal hooks are reporting-only unless a separately reviewed
  control contract exists.
- Approval responses are one-shot and idempotent. Lost responses remain unknown
  until reconciled. Cancellation remains requested until confirmed or reconciled;
  late completion after cancellation never produces Ready, and queued prompts
  are not automatically resent.
- Ordered replay is used only when the provider documents real lifecycle
  sequencing and replay cursors. Otherwise Pine reconciles current state using
  scoped event/request identity without manufacturing sequences from arrival
  order. Provider history cursors are not streaming replay authority.
- Application restoration restores metadata and marks live evidence stale.
  Automatic reconciliation is limited to an already-live process and revalidated
  authenticated channel. Starting a new agent or native provider resume requires
  explicit user action and creates a new Pine attempt; a fresh process resuming
  a conversation is not presented as the original live process.
- Pine registry checkpoints remain one-shot, same-registry source handoffs and
  are never persisted as provider resume data.
- Persist bounded redacted metadata or references, not transcripts, prompts,
  file contents, visual attachments, environment values, raw hook payloads, or
  credentials by default. Define retention, provider transmission, notification
  content, and log exclusions for every new evidence field.
- Trying a project command requires a distinct user action, immediate
  environment/grant revalidation, bounded execution, and disclosure of possible
  side effects. Correct worktree routing does not authorize deployment,
  publication, external-service mutation, or credential access.
- Routine local work follows project rules without mandatory Git ceremonies.
  Publishing, destructive operations, and permission expansion require explicit
  authority; creating a task is not blanket consent for those actions.
- Keep recovery and retry limits even without user-facing budget configuration.
  Do not retry indefinitely or bypass permissions to make progress.

## Inspiration without imitation

agterm's public site suggests useful patterns: agent-accessible control APIs,
companions such as previews and logs, and continuity of sessions. Public ADE
implementations such as herdr, Orca, and Paradev also demonstrate the value of
explicit lifecycle evidence, native session resume, and transition-based
attention. These are inspiration, not verified compatibility claims or automatic
Pine commitments.

For Pine, preview, logs, and terminals should belong to the task. Programmatic
control should remove manual setup rather than expose a layout-programming
language as the main experience. A grid of busy terminals is not the product's
primary value or its default home. Terminal scraping and prompt markers must not
become authoritative verification when an authenticated structured provider
interface is available.

## First complete release slice

Prove Codex app-server end to end before broadening compatibility:

- One task, one implementer, and a separate read-only reviewer session.
- Selected-project task creation with a remembered default agent.
- Validated single-task environment discovery and binding.
- Pine-observed required checks and bounded automatic correction.
- Evidence bound to the checked state, with visible invalidation after edits.
- One complete explicitly authorized try-the-result path for a selected project
  type.
- Natural-language continuation and truthful failure/relaunch recovery.

Kimi Code CLI through `kimi acp` is the required second structured adapter;
Claude Code is the third. Shared provider contract tests must demonstrate the
same task, attention, review, Ready, recovery, and evidence semantics while
documenting real capability differences.

Then demonstrate at least three independent same-repository tasks with validated
routing and a documented concurrency limit `N`, including honest `N+1` queueing
or deferral, without a fleet-management UI. Broaden delegation, detected-only
adapter coverage, and project-specific result surfaces deliberately.

Do not lead with an agent marketplace, team builder, remote execution platform,
mandatory manual review process, budget settings, or a wall of live terminals.
Do not claim massive parallelism, sandboxing, conflict-free isolation, or broad
compatibility before those properties are demonstrated.

## Public surfaces

The same message ships to the README, the landing page and all 9 locales,
SEO/Open Graph/X metadata, the GitHub About description and topics, the in-app
Help in all 9 locales, and this document. Each surface keeps current 2.x
capabilities described as shipped and ADE capabilities described as Pine 3.0
direction, using durable wording: no agent counts, adapter totals, or release
dates.

## Release quality gates

- A user can complete the primary path without understanding worktrees,
  terminal routing, or agent orchestration.
- Failures, cancellation, missing permissions, stale evidence, and
  crash-inconsistent persistence cannot produce a misleading Ready state.
- Trying a result uses the intended task environment and a current explicit grant,
  not the original project accidentally left open elsewhere.
- Relaunch preserves task context and states honestly what can be resumed without
  automatically starting an agent or correction loop.
- Keyboard navigation, VoiceOver and state announcements, localization across all
  9 app locales, and native window behavior on supported macOS versions are
  release requirements, not post-launch polish.
- README, the landing page and all 9 locales, SEO/social metadata, GitHub About,
  product vision, all 9 in-app Help locales, and screenshots distinguish current
  Pine 2.x capabilities from Pine 3.0 direction until each capability ships.
- The canonical Homebrew command remains `pine-editor` unless a separate review
  approves and verifies a safe `pine-ade` installed-base migration.

Judge progress by completed user outcomes: time to a result the user can try,
unnecessary interruptions, successful recovery, and misleading Ready reports.
More running agents, more generated code, more supported adapters, and more
visible activity are not success metrics.
