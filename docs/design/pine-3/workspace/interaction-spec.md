# Pine 3 workspace — end-to-end interaction specification

Status: design exploration for issue [#1735](https://github.com/batonogov/pine/issues/1735).
This spec describes behavior, not pixels. It is written against the composition
candidates in [composition-comparison.md](composition-comparison.md); sections marked
**[A]** describe the recommended composition in detail, **[A/C]** or **[B]** note where
the alternative compositions behave differently. Every state named here maps to the
merged ADE lifecycle model (`AgentTaskLifecycleReducer`, #1722) — the UI never invents
state the model cannot express.

## 1. State vocabulary

The spec uses only these dimensions, with the model's meanings
(`Pine/Agent/AgentTaskModels.swift`, `Pine/Agent/AgentTaskLifecycleReducer.swift`):

| Dimension | Model values | UI wording rule |
|---|---|---|
| Execution (`AgentTaskExecutionState`) | `working`, `blocked`, `idle`, `unknown` | `working` = “Working”. `blocked` = “Needs input”. `idle` = “Idle” (a live session with nothing outstanding — **not** completion). `unknown` = “Status unclear” with the honest reason (e.g. “Pine restarted; state not yet re-established”). |
| Attempt outcome (`AgentTaskOutcome`, per settled run) | `success`, `failure`, `cancellation`, `superseded`, `unverified` | `success` is never shown as such on its own — it becomes the Ready projection below. `failure` = “Checks failed” / “Review found issues” (names the vetoing evidence). `cancellation` = “Cancelled”. `unverified` = “Ended without full verification” — explicitly *not* success. |
| Verification (`AgentTaskVerificationState`) | `none`, `pending`, `verified`, `stale` | `none` = “No checks recorded”. `pending` = re-verification of a settled success — “Running checks…” / “Review in progress” while the required evidence re-runs. `verified` = part of Ready. `stale` = “Evidence stale” with the named repeat work (e.g. “Code changed after the last check — re-run checks and review”). |
| Acceptance (`AgentTaskAcceptanceState`) | `notAccepted`, `accepted` | Acceptance is a user fact, shown only after it happens (“Accepted” + the accepted snapshot identity). The merged contract admits it on a settled `success` **or** `unverified` attempt (refused for `failure`, `cancellation`, and dismissed tasks); it never upgrades the recorded outcome or the verification state, so on a not-Ready result it carries the caption “Accepting does not upgrade verification”. |
| Attention (`AgentTaskAttention`) + `isUnread` | `none`, `waitingInput`, `completed`, `failed` | Drives the Inbox queue and the sidebar badge. `waitingInput` = a concrete question or decision is open. `completed`/`failed` with unread = queue entries. |
| Ready (derived, `AgentTaskReadiness`) | `isReady` + `gaps` | Ready exists **only** when the settled attempt succeeded, verification is `verified`, and every required evidence fact (independent check, reviewer outcome) passes bound to the current code-state and environment identity. Any gap is named, not hidden: `attemptInProgress`, `noSettledAttempt`, `unverifiedOutcome`, `failedAttempt`, `cancelledAttempt`, `supersededAttempt`, `staleEvidence(kind)`, `missingEvidence(kind)`, `failingEvidence(kind)`, `verificationNotCurrent`, `codeStateUnknown`, `environmentUnknown`, `environmentChanged`. |

The model's task-level `lifecycle` (`active`/`paused`/`completed`/`dismissed`)
is registry bookkeeping derived from the dimensions above; it is never rendered
as a UI state of its own. Likewise, **first verification in flight** is not
expressible in `verificationState`: the merged model reaches `pending` only via
re-verification of a settled success (`recordVerificationPending`), so the UI
derives the in-flight phase from the #1724 verification layer's orchestration
state (D9).

Rules that bind every surface:

- **No state is decorative.** A glyph, word, or color must correspond to one of the
  values above. A green check means a *Pine-observed* passing fact, never an
  agent-reported one.
- **Unknown fails closed.** Missing or contradictory evidence renders `unknown`
  wording, never a plausible positive.
- **Stale is a state, not an error.** Relaunch and relevant edits make verification
  `stale`; the UI says exactly what must be repeated (the gaps), and preserves the
  identifiable reviewed/accepted snapshots.
- **Viewing is not acting.** Opening a task or result changes viewed/unread only —
  never acceptance, never execution, never authorization.

## 2. The journey

### 2.1 Open a project **[A]**

1. From the Welcome window (or Finder / `⌘O`), the project window opens on the
   **project overview** — or on the *last surface* the user was in, per session
   restoration (D3). New or recently added projects default to the overview.
2. The sidebar shows Inbox (with an attention badge when the queue is non-empty),
   the project list, and — under the selected project — its tasks, nested.
3. The overview shows, top to bottom: project identity (name, one-line description);
   the **new-task composer** (dominant element); **Needs your attention** (the open
   questions/decisions in this project, each with its source task and a
   “Review question” action); **Your work** (current tasks as rows/cards with state
   word, last-updated time, and a thumbnail *only when a genuine artifact exists*).
4. **Empty project** (no tasks): the composer is the only prominent element, with a
   single line “No tasks yet. Describe what you'd like to change.” No placeholder
   cards, no sample content.
5. **Keyboard:** sidebar arrow-key navigation with type-to-select (the 2.x
   `SidebarTreeNavigation` conventions: Up/Down rows, Left/Right collapse/expand,
   Home/End, type-ahead). `⌘N` focuses the composer from anywhere in the project.

### 2.2 Create a task **[A]**

1. In the composer, the user writes the goal in their own words. The placeholder is
   “What would you like to change?”
2. The provider picker shows the **remembered agent** for this project by default
   (the last Pine-owned launch's agent); choosing a different provider is optional,
   never a repeated mandatory step. The provider name appears here and in task
   details — never as the task's identity. The task is identified by its goal.
3. The attachment control is **capability-gated**: visible only when the selected
   adapter's profile supports attachments for this surface. When hidden, no control
   and no promise.
4. `⏎` (or the send button) creates and starts the task. This is an explicit action;
   creating a task is not consent for publishing, destructive operations, or
   permission expansion — the task's environment and grants are established by Pine,
   and ambiguous environments fail closed.
5. On start: the task appears under the project in the sidebar with a `working`
   glyph; the content column moves to the **task workspace**; focus lands on the
   task title. If the provider cannot start (missing CLI, failed launch), the task
   row shows `unknown` with “Could not start — <reason>” and a retry; no silent retry.
6. **Concurrent work (#1728):** when the project's documented concurrency limit `N`
   is reached, a new task shows “Queued — <k> running” honestly; it does not start
   until a slot is free. No fleet dashboard, no invented ordering promises.

### 2.3 Work in progress, and questions **[A]**

Task workspace layout (working state):

- **Header:** goal as title; the task's one-line description as subtitle; on the
  right, the truthful execution state (“Working” with the animated glyph, or
  “Needs input”) and a stop/cancel control. Provider identity (“Codex”) is a
  small secondary chip here and in the overflow menu.
- **Tabs:** `Overview` · `Changes` · `Code` · `Terminal`. (The first tab renames to
  `Result` when the task becomes Ready — D4.)
- **Overview tab (working):** left — the latest preview *when the project genuinely
  supplies one*, explicitly marked “This revision has not been checked yet”; right
  rail — (a) the last real agent signal (e.g. “Editing pages/itinerary.tsx”), (b)
  Pine's fixed phases with real status: implementation (in progress / done),
  checks (queued / running / done), independent review (queued / running / done)
  — the checks/review phase status is the #1724 verification layer's
  orchestration state, not `verificationState` (which reaches `pending` only on
  re-verification of a settled success),
  (c) a collapsed **Activity** disclosure holding the raw provider stream.
  When the project has no preview capability, the left shows “No preview for this
  project type” with a one-line reason — no image, no button.
- **Changes tab:** the live diff of the task's worktree (added/modified/deleted,
  2.x diff presentation). Manual editing from here is preserved (section 5).
- **Code tab:** the existing editor over the task's worktree files, fully featured.
- **Terminal tab:** the **real CLI agent PTY** (SwiftTerm), full fidelity, with
  scrollback. The user may type into it directly; Pine never injects text into the
  agent's terminal. This tab is the manual workflow's anchor.
- **Questions (`blocked`):** when the model reaches `blocked` (a live, authenticated,
  unresolved question or approval), the question card appears in the Overview tab —
  and in the project's “Needs your attention”, and in the Inbox. The card shows the
  concrete question, its source, any recommendation with its consequence (a
  Needs-decision escalation per the vision's review loop), and the answer affordance.
  Answering is one-shot and idempotent; a lost answer stays “unknown” until
  reconciled — the UI never shows an answered question as open, nor an unanswered one
  as answered. After answering, execution returns to `working` (or settles).
- **What is never shown here:** progress percentages, invented plan steps,
  “live preview” for projects that cannot render one, or any state derived from
  terminal silence. Quiet during progress: no notification stream for intermediate
  activity; only `blocked` and settlement change attention.

### 2.4 Checks and review **[A]**

These are Pine-observed, not agent-reported:

1. When the agent claims completion, the attempt is **not** settled as success yet.
   The header's “Running checks…” / “Review in progress” phase is sourced from the
   #1724 verification layer's orchestration state, **not** from `verificationState`
   — in the merged model `.pending` is produced only by re-verification of a
   settled success (`recordVerificationPending`), so first verification in flight
   is not expressible there (D9). The reachable model states in this window: run
   still live → `executionState` `.working`/`.idle` + readiness gap
   `attemptInProgress`; run ended with the claim only → outcome `.unverified`,
   `verificationState` `.none`, gaps `unverifiedOutcome` + `missingEvidence(kind)`.
   Checks run in the validated task environment with recorded results.
2. The independent review is a separate read-only reviewer session against the exact
   candidate and explicit criteria; reviewer-caused changes invalidate that review.
   Review feedback returns automatically to the implementer; one correction round is
   one revision returned for re-review. After three unresolved revisions, Pine
   escalates to Needs decision (`waitingInput` with a concrete question) — no fourth
   automatic attempt; the counter persists across relaunch.
3. Settlement: with the claim plus all required passing evidence bound to one
   code-state identity, the attempt settles `success` and, if verification is current,
   the task is **Ready**. Without it, the attempt settles `unverified` and the UI says
   so (“Ended without full verification — <named gaps>”), with the repeat work
   offered. A current-bound failing check or review vetoes the claim: the UI names it
   (“Checks failed: <which>”, “Review found issues: <which>”).
4. **Manual edits or environment changes** at any point invalidate verification and
   acceptance (fail closed): the evidence row moves to the stale state (section 3)
   with the exact wording “Evidence stale — code changed after the last check.
   Re-run checks and review to restore Ready.” Acceptance never silently inherits.

### 2.5 Result: inspection **[A]**

When Ready:

1. The task's first tab renames `Overview` → `Result`; the sidebar glyph and header
   state become “Ready”. The Inbox gets a `completed` entry. **No automatic
   tab-switching while the user is working elsewhere** — the Ready state is badged,
   not hijacking (D2).
2. The Result surface (full content width), top to bottom:
   - **Header:** goal title + `Ready` chip; one-line summary of what changed.
   - **Toolbar row:** the **concrete result action** for the project type (section 4)
     with its side-effect caption, and the overflow menu (which includes
     Accept — D2).
   - **Evidence row:** “Checks passed · Review passed” (left) and “<n> limitation(s)
     ›” (right) — a disclosure into the full provenance list: per check, the command
     (bounded, redacted as appropriate), time, and the code-state revision it was
     bound to; for the review, the criteria and time; then the stated limitations,
     plainly. The revision binding is what makes “checked” mean something — the
     provenance list states which exact revision each fact covers.
   - **Artifact:** the project-appropriate presentation — rendered preview, built app
     reference, example output, the document, or (non-runnable) the changes summary
     with diff access.
   - **What changed:** a short factual summary of the changes made, with “View
     changes” opening the diff.
   - **Feedback composer** at the bottom: “What would you like to change?”
3. **Viewing semantics:** opening the result changes viewed/unread only. It does not
   start a server, launch anything, or accept.
4. **Non-Ready results:** every non-Ready settlement has an equivalent surface —
   the same layout with the evidence row in the matching section-3 row state
   (unchecked / pending / failed / stale), the header carrying the outcome word
   (“Cancelled.”, “Ended without full verification”), and the trial action
   **absent** (a result that is not Ready has no trial button; the actions shown
   are the repeat work and inspection). A settled `unverified` result additionally
   offers **Accept** with the caption “Accepting does not upgrade verification” —
   the merged acceptance contract admits it on `unverified` as well. Section 3
   lists each.

### 2.6 Try the result **[A]**

The trial action is concrete, authorized, and side-effect-disclosing (section 4 for
the per-type table). Common rules:

1. The action is a **separate user action** — never a side effect of viewing.
2. Before executing, Pine revalidates the task environment and the current grant
   (identities captured earlier do not count). If revalidation fails, the action
   shows the honest failure (“Environment no longer valid — <reason>”) instead of
   running.
3. Side effects are stated in the caption *and* in a confirmation when the side
   effect is non-trivial (e.g. “Send request — POST to <target>; may create data”).
   Local, reversible actions (opening a preview, running a declared example) run
   directly with the caption.
4. Running states: the button reflects reality — “Open preview” → “Preview running —
   Stop” (web); “Run example” shows the exact command and streams into the task's
   terminal under the grant; failures render a bounded diagnostics card, never a
   crash and never a silent retry.
5. Trial **does not** publish, merge, install into the user's normal environment, or
   imply acceptance. Acceptance is the separate action in the overflow menu and the
   evidence disclosure (D2), and it records the snapshot identity it accepts.

### 2.7 Feedback **[A]**

1. The result (and task) composer continues **the same CLI session** through its
   supported adapter — not a new conversation, not a resend of the original prompt.
2. **Input during an active turn** follows actual provider capability: when the
   adapter supports queued input, a sent message shows a “Queued” chip until the turn
   ends; when it does not, the send control is disabled with the honest reason
   (“Available when the current turn ends”). Nothing is silently dropped or silently
   resent (D6).
3. Attachments remain capability-gated and explicit; the composer remembers nothing
   beyond the bounded task feedback record (redacted references, never the text, per
   the persistence contract).
4. Feedback that changes the work re-enters the 2.3–2.5 loop: execution `working`
   again, prior evidence marked stale where relevant, the task's identity and
   history preserved.

### 2.8 Return, relaunch, restore **[A]**

1. **Return:** breadcrumb (`Atlas › Plan a weekend`) and the sidebar carry the user
   back to the overview or another task; the previous surface's scroll position,
   expanded disclosures, and tab selection are restored on return. Unread state is
   independent of which surface is open.
2. **Relaunch (app quit and reopened):** restoration loads durable metadata and
   normalizes fail-closed before anything is shown — execution evidence degrades to
   `unknown` (“Status unclear — Pine restarted”), verification `verified`/`pending`
   degrades to `stale`, acceptance snapshots survive, reviewed snapshots survive.
   The UI never presents a restored task as if it were still live.
3. **Resume is explicit:** where the provider supports it, the task offers “Resume
   with <provider>” as an explicit user action that **creates a new attempt** — a
   fresh process resuming a conversation is never presented as the original live
   process. No automatic reconciliation, no re-armed claims, no auto-started
   correction loops.
4. **Preview lifecycle:** a running preview is tied to the task environment; closing
   the window stops it (stated in the preview caption), and relaunch never silently
   restarts it.

## 3. State coverage

Every UI state in the workspace and its model basis. Wording is the spec'd user-facing
text (English; all strings ship localized, section 6).

### Task header / sidebar states

| UI state | Model basis | Notes |
|---|---|---|
| Working | `executionState == .working` | Animated glyph; static “Working” under Reduce Motion. Last real agent signal shown, never a percentage. |
| Needs input | `executionState == .blocked` (and `attention == .waitingInput`) | Question card visible in workspace, project overview, and Inbox. |
| Idle | `executionState == .idle` | “Idle — session live, nothing outstanding.” Not completion; no result implied. |
| Status unclear | `executionState == .unknown` | With honest reason: “Pine restarted”, “Provider signal lost”, “Evidence contradictory”. Never rendered as idle or working. |
| Queued | Concurrency limit `N` reached (#1728); no run recorded yet | “Queued — <k> running.” Shown before the attempt starts — a scheduling reason over `executionState == .unknown`, not a model state. |
| Ready | `readiness().isReady == true` | Derived only; never stored. |
| Not ready — in progress | gap `attemptInProgress` (run live, unsettled) / `noSettledAttempt` (no recorded run yet) | The “Checks in progress” / “Review in progress” wording is derived from #1724 orchestration state, not from `verificationState` (`.pending` is re-verification only). `noSettledAttempt` shows the `unknown` start-failure wording of section 2.2 instead. |
| Not ready — unchecked | gap `missingEvidence(.independentCheck)` / `missingEvidence(.reviewerOutcome)` | “No checks recorded yet” / “Review not yet run”, with the repeat work offered. |
| Not ready — unverified | gap `unverifiedOutcome` | “Ended without full verification — <named gaps>.” |
| Not ready — failed | gap `failedAttempt` | “Checks failed: <kind>” / “Review found issues: <criteria>.” `readiness()` returns exactly `[.failedAttempt]` for a `.failure` outcome — the named kind comes from the vetoing bound fact in `task.evidence`, not from a readiness gap. |
| Not ready — cancelled | gap `cancelledAttempt` | “Cancelled.” Work preserved; continue is offered. |
| Not ready — superseded | gap `supersededAttempt` (latest run settled `.superseded`) | “Replaced by a new attempt” — the previous run ended without settling and a resume or newer attempt took its terminal; the replacement owns the task’s state. Transient: it resolves as the new attempt is observed. |
| Stale | `verificationState == .stale`; readiness gaps always include `verificationNotCurrent`, plus `staleEvidence(kind)` / `environmentChanged` / `codeStateUnknown` / `environmentUnknown` | “Evidence stale — <why>. Re-run checks and review to restore Ready.” Accepted/reviewed snapshots remain identifiable. |
| Accepted | `acceptanceState == .accepted` + `acceptedSnapshot` | “Accepted — <snapshot identity, bounded>.” Only ever after the explicit action; the merged contract admits it on a settled `success` **or** `unverified` result (refused for `failure`, `cancellation`, and dismissed tasks) and never upgrades the outcome or the verification state — on a not-Ready result it is captioned “Accepting does not upgrade verification”. |

### Result evidence row states (see
[composition-a-evidence-states.svg](assets/composition-a-evidence-states.svg))

| Row state | Model basis | Left side | Right side |
|---|---|---|---|
| Verified | Ready projection true | “✓ Checks passed · Review passed” | “<n> limitation ›” disclosure |
| Pending | `verificationState == .pending` (re-verification of a settled success; first verification in flight renders this row from #1724 orchestration state, D9) | “Running checks · Review queued” (or “Review in progress”) | “<n> limitation ›” |
| Unchecked | `verificationState == .none` + `missingEvidence(kind)` | “No checks recorded yet” | “Run checks” (repeat work) |
| Stale | `verificationState == .stale` + `staleEvidence(kind)`/`environmentChanged` | “Evidence stale — code changed after the last check” | “Reverify ›” + “Acceptance does not carry over” in the disclosure |
| Failed | `failingEvidence(kind)` / `failedAttempt` | “Checks failed · Review found issues” | “View failures ›” |

Provenance discoverability: the row is a disclosure; expanded, it lists each fact's
kind, time, and the code-state revision (and environment identity) it is bound to,
then the stated limitations. The expanded list is where “which exact revision was
checked” is answered — the compact row never implies more than it states.

**`pending` is re-verification only.** In the merged model `verificationState ==
.pending` is produced solely by `recordVerificationPending` against a settled
`.success` attempt, so the row above is the re-verification shape. First
verification in flight shows the same row text, sourced from #1724 orchestration
state, while `verificationState` is still `.none` (D9).

### Preview / artifact states

| State | Basis | Rendering |
|---|---|---|
| Preview available, unchecked | Project supplies renderable artifact; verification not `verified` | Preview shown with the permanent mark “This revision has not been checked yet.” |
| Preview available, checked | Ready, bound preview | Preview + “Checked revision · <bounded identity>.” |
| Preview running (after trial) | Dev server started under grant | “Preview running — Stop.” |
| Preview failed | Start failure | Diagnostics card; “Retry” offered; no silent retry. |
| No preview for this project type | Project cannot supply one | “No preview for this project type — <reason>.” No image, no button. |

## 4. Result actions by project type

“Result” is the common section name. There is **no universal trial button**; each
action is labeled with what it actually does, validated before it is exposed, and
absent when the project cannot support it. The agent may *suggest* a command, URL, or
build path; Pine validates the environment, target, and authority before exposing
execution. Arbitrary terminal text must never become a trusted executable button.

| Project type | Action | What it actually does | Preconditions / validation | Side-effect disclosure | Unavailable / failed states |
|---|---|---|---|---|---|
| Website / web app | **Open preview** | Starts the declared local dev server in the task environment and opens its page in the browser | Declared dev-server entry validated; environment revalidated; grant current | Caption: “Starts a local preview server.” Opening the task alone never starts it. | “No preview for this project type” when nothing is declared; start failure → diagnostics card + Retry. Button becomes “Preview running — Stop.” |
| macOS app | **Run application** | Launches the task's identified built application in its validated environment | Build identified and present (or offered as a separate “Build” step); environment revalidated | Caption: “Launches the built app in the task environment.” | “Build not found — Run the build to continue” as a separate action; launch failure → diagnostics card. |
| CLI utility | **Run example** | Shows the exact command and arguments and runs it in the task terminal under the current grant | Command validated against the project's declared examples; grant current | Caption shows the exact command (`atlas --demo week`). | “No declared example” → the action is absent (View changes remains); run failure → bounded output card. |
| Backend / API | **Send request** | Sends a prepared request to the identified endpoint | Target, method, and relevant side effects shown **first** in a confirmation; service reachable in the task environment | Confirmation names target, method, and side effects (“may create data in <env>”). | “Service not started — Start the service” as a separate state/action; request failure → response diagnostics. |
| Library | **Open example** | Opens a prepared usage example; execution is a separate action where supported | Example file identified in the task worktree | Caption: “Opens the example. Running it is separate.” | No example identified → absent; run (where supported) is its own validated action. |
| Documentation | **Open document** | Displays the document or its rendered form without executing embedded commands | Document identified; rendered via 2.x markdown support | None beyond display. | Absent when no document is the result. |
| Internal logic / race fix / dependency change | **View changes** | Presents the explanation, the diff, and the check evidence; no runnable artifact is required | None beyond the diff | None. | This is the *default presentation* for non-runnable results — its absence of a trial action is the honest state, not a missing feature. |

Rules binding all rows:

- Viewing, running, and accepting are separate actions.
- Trial does not publish, merge, install into the user's normal environment, or imply
  acceptance.
- Agent-reported success alone does not produce Ready; the action set is a function of
  the project type **and** the current evidence state (section 3), so a stale or failed
  result never shows a trial action.
- A project-owned description of an action is untrusted input until validated.

## 5. Manual workflow preservation

The manual workflow is preserved, not emulated:

1. **Terminal.** The task's Terminal tab is the real SwiftTerm PTY of the agent
   session: full TUI support, scrollback, `⌘`+click path/URL behavior (2.x
   terminal-link rules), direct user input. It is one tab (or `⌘4`, D7) from any
   result surface. Terminal text remains non-authoritative: nothing in it becomes a
   trusted button.
2. **Code.** The Code tab is the existing editor (GutterTextView) over the task's
   worktree: full editing, LSP intelligence, find & replace, format on save.
3. **Diff.** The Changes tab is the existing diff presentation for the task's changes.
4. **Unsaved work.** Manual edits create ordinary dirty documents: close/quit
   confirmation, save flows, and unsaved-work protection are exactly the 2.x
   document lifecycle. Pine never discards, overwrites, or silently reverts manual
   work — including when the agent or a re-verification runs: if the worktree is
   dirty in a way relevant to evidence, verification is invalidated (fail closed) and
   the evidence row says so, instead of the edit being lost or the evidence kept.
5. **Side-by-side.** The task workspace can split (existing pane model) so code or
   the terminal sits beside the task's Overview/Result surface; focus and layout are
   preserved when returning (session persistence covers the pane tree).
6. **Direct access without a task.** The file tree, editor, and terminal remain
   available in ordinary project windows exactly as in 2.x; ADE surfaces never make
   the manual path indirect.

## 6. Accessibility and platform requirements

Per surface, in the recommended composition. All requirements are release gates per
the vision's quality gates, not polish.

### Keyboard

| Surface | Requirements |
|---|---|
| Sidebar | Arrow-key row navigation, Left/Right collapse/expand (2.x `SidebarTreeNavigation`), Home/End, Page Up/Down, type-to-select; selection and focus distinct; `⌘N` focuses the composer; `⌘W` closes the task tab, not the window, per 2.x. |
| Project overview | Tab order: composer → attention rows → work rows. `⏎` in the composer creates the task. Attention-row “Review question” is reachable and activatable by `⏎`/Space. |
| Task workspace | Tab strip is a standard segmented control: `⌘1`–`⌘4` jump Overview/Result · Changes · Code · Terminal (D7); arrows move within the tab; stop/cancel is `⌘.` (cancel is always reachable). |
| Result surface | The trial action is a toolbar item reachable by Tab and activatable by `⏎`/Space; the evidence row disclosure is a button (`⌘⌥E` to toggle, D7); the overflow menu is the standard `⌥`-free macOS toolbar overflow, also in the Task menu. |
| Navigation | `⌘[` back / `⌘]` forward (document-style, A); the push-stack surfaces (C) use the system back control with the same keys. |
| Terminal tab | Unmodified 2.x keyboard behavior — the spec adds nothing, changes nothing. |

### VoiceOver

- State words are spoken as words, not colors or glyphs: “Working”, “Needs
  input”, “Ready”, “Evidence stale — code changed after the last check”.
- The evidence row is one element with its full state in the label (“Checks passed,
  Review passed, 1 limitation, disclosure”); the expanded provenance list announces
  each fact's kind, time, and bound revision.
- Previews are labeled with their check state: “Preview, this revision has not been
  checked yet” vs “Preview, checked revision”.
- Lifecycle transitions (working → blocked → Ready → stale) post AX announcements so
  state changes are heard without re-navigation.
- The stop/cancel control is always labeled; cancellation is confirmable by VoiceOver
  without a mouse.

### Reduce Motion

- All purposeful transitions (surface moves, the result sheet in B, push/pop in C)
  collapse to immediate change with equivalent behavior — nothing is gated behind
  motion.
- The `working` arc becomes the static “Working” text; the “Preview updating” pulse
  becomes static text; no looping animation anywhere.
- No reduced-motion degradation of *content*: state words, disclosures, and actions
  are identical.

### Focus restoration

- After creating a task: focus on the task title (announced), sidebar selection on the
  new row.
- After answering a question: focus returns to the question card's resolution state;
  if the task settles, focus moves to the header state.
- After a trial action: focus stays in the task window (the preview opens in the
  browser; the app does not steal it back).
- After feedback send: focus returns to the composer with it cleared (or “Queued”
  chip focused if queued).
- After relaunch: the last selected task (or overview) is restored with its tab,
  scroll position, and expanded disclosures; focus lands on the restored surface's
  title.
- Terminal focus: entering the Terminal tab moves focus into the PTY; leaving it
  restores focus to the prior control on return.

### Localization

- All new strings ship in all 9 app locales (`en`, `de`, `es`, `fr`, `ja`, `ko`,
  `pt-BR`, `ru`, `zh-Hans`) via `Localizable.xcstrings` (targeted insertion).
- State words are chosen short and translatable (“Needs input”, “Evidence
  stale”); layout must not truncate or reflow badly at the longest-locale lengths —
  the evidence row wraps to a second line rather than clipping, and the sidebar
  status words truncate to glyph-only with the full word in the tooltip/label.
- No idioms, no provider-specific wording in strings, no hard-coded times or counts
  in strings that localize.
- Bounded identifiers (revision fingerprints, snapshot identities) are rendered
  truncated in every locale with the full value in the provenance disclosure.

### Compact windows

- Minimum window size keeps the content column ≥ ~520 pt at the recommended
  composition; below it, the sidebar is collapsible (`⌥⌘S` and the toolbar toggle —
  native macOS sidebar behavior), collapsing to an icon rail (Inbox, project glyph,
  task glyphs with status).
- Overview card grid: 2 columns → 1 column below ~900 pt content width; thumbnails
  scale, never crop text.
- Evidence row wraps before clipping; the trial action caption wraps under the button.
- Task workspace right rail: at compact width the rail moves below the preview
  (stacked), not hidden — the Activity disclosure is the only thing that collapses.
- All surfaces remain fully functional at minimum size; nothing requires a wide
  window to be usable.

## 7. What is never promised

The capability-limitation language, stated for the UI as a whole:

- **No universal progress.** No percentages, no invented plan steps, no “90% done”.
  Progress is real agent signals and Pine's own phases, or the honest “Working”.
- **No fabricated artifacts.** No preview, screenshot, or “live view” for project
  types that cannot supply one; the absence is stated, not decorated.
- **No fabricated trial.** No preview/launch/run button exists without a validated
  project mechanism, validated environment, and current grant. Non-runnable results
  simply present changes.
- **No implied acceptance.** Viewing never accepts; running never accepts; acceptance
  is one explicit action against a named snapshot.
- **No silent input.** Feedback during an active turn is queued with a visible
  “Queued” chip or unavailable with a visible reason — never silently dropped, never
  silently resent.
- **No automatic resume.** Relaunch never restarts an agent, a correction loop, or a
  preview; resume is explicit and creates a new attempt.
- **No authority from text.** Terminal output and agent suggestions are
  non-authoritative until Pine validates environment, target, and grant.
- **No hidden uncertainty.** Missing, stale, or contradictory evidence renders
  “Status unclear” with the reason, never a plausible positive.
- **No infinite retry.** Failures surface with bounded diagnostics and an explicit
  retry where the retry is meaningful.
