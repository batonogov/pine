# Recommendation and open decisions — Pine 3 workspace

Status: design recommendation for issue [#1735](https://github.com/batonogov/pine/issues/1735).
Companion documents: [composition-comparison.md](composition-comparison.md) (the
candidates), [interaction-spec.md](interaction-spec.md) (the behavior).

## Recommendation: Composition A — Project canvas, refined

**Adopt Composition A** (sidebar + document-style content: project overview → task
workspace → result), refined as specified in
[composition-a-overview.svg](assets/composition-a-overview.svg),
[composition-a-task-working.svg](assets/composition-a-task-working.svg),
[composition-a-result.svg](assets/composition-a-result.svg), and
[composition-a-evidence-states.svg](assets/composition-a-evidence-states.svg).

### Why A wins

1. **It is the issue's interaction model, made concrete.** The issue's working model
   — compact sidebar; project overview with a prominent composer; task workspace with
   truthful state and stable identity; result with concrete actions, compact
   evidence, and separate acceptance — is A's structure. Choosing A means the spec
   and the selection agree; choosing B or C would require re-deriving the same
   journey through a different spatial grammar.
2. **It most directly satisfies the behavioral-expression criterion.** The window
   *is* the project/task/result hierarchy: the sidebar owns project and task
   identity permanently, the content column changes with the work (overview →
   working → Ready → stale), and the header state words are 1:1 with the lifecycle
   model. In B the result is pulled from a badge over a terminal; in C the project
   home is demoted behind a queue. A is the only candidate where “start work, return
   to it, answer questions, inspect results, give feedback” is the *shape of the
   window itself*.
3. **It reuses what already exists.** The Inbox (2.x), the editor, the real terminal,
   the pane splits, session restoration, and the warm-white/forest-green visual
   language all fold into A without architectural rework. C's strongest idea (the
   queue as home) is already A's Inbox surface; B's strongest idea (the terminal as
   truth) is already A's Terminal tab, one keystroke from any surface.
4. **It is the direction already iterated with the maintainer.** The archive mockups
   (project overview, task in progress, result v1 → v2) are A. A refines them
   (numbered in the comparison doc) rather than discarding two rounds of iteration.
5. **Its risks are named and bounded.** Dashboard drift (overview grid), sidebar
   growth, tab depth, and build surface area — each has a stated mitigation in
   [composition-comparison.md](composition-comparison.md). B and C carry structural
   risks A can mitigate locally: a terminal-dominant home contradicts the
   outcome-first identity, and a rail-less stack sacrifices the workspace
   place-sense the issue asks for.

### What A does not do

- It does not make the terminal the default home (that remains B, offered through
  the Terminal tab and split layouts for power users).
- It does not turn the window into a queue (the queue is the Inbox, one click away).
- It does not freeze the archive's inconsistencies: the seven refinements in the
  comparison doc supersede the mockups where they conflict.

## Validation plan (required before design sign-off)

This wave is docs/design; the spec's acceptance criteria that require running UI are
validated in the implementation wave as follows, and are recorded here so sign-off
is scoped honestly:

1. **Interactive prototype.** A throwaway SwiftUI prototype of A's three screens
   (overview, working, Ready/stale result) wired to a scripted lifecycle model —
   not production code — to confirm navigation, tab behavior, evidence-row
   disclosure, and the Reduce-Motion equivalents. This is what “compare in concrete
   designs” requires beyond the vector mockups.
2. **State coverage pass.** Every row of the [state coverage
   table](interaction-spec.md#3-state-coverage) rendered from the real
   `AgentTaskLifecycleReducer` projection (test fixtures driving the reducer),
   including `unknown`, `stale`, `superseded`, and the relaunch-normalized states —
   the mockups cannot cover these; the prototype must.
3. **Result-action pass.** The four required project types (web, native app, CLI,
   non-runnable) each exercised end to end in the prototype against the
   [result-actions table](interaction-spec.md#4-result-actions-by-project-type),
   confirming no trial button exists for the unsupported cases.
4. **Accessibility pass.** Keyboard-only full journey; VoiceOver audit of the state
   words, evidence row, and transitions; Reduce Motion equivalence; focus restoration
   per the [spec](interaction-spec.md#6-accessibility-and-platform-requirements);
   minimum-window-size pass; 9-locale pass with longest-locale layout checks.
5. **Manual-workflow pass.** Real terminal input, manual edits with unsaved work,
   side-by-side layout, and return-with-preserved-focus per section 5 of the spec.

Until 1–5 are done, A is a *recommended design*, not a signed-off one.

## Open decisions for maintainer sign-off

Each lists the options, the recommendation, and what it blocks. None of these,
as recommended, changes the lifecycle model or the contracts of #1722–#1725;
they are spatial and interaction choices (D9 records a model gap and recommends
no contract change).

### D1 — Main-window composition

- **Options:** A (Project canvas) · B (Terminal canvas) · C (Attention flow).
- **Recommendation:** A, per the justification above. B and C remain documented
  alternatives; B's terminal-first behavior is available inside A's Terminal tab and
  splits, C's queue is A's Inbox surface.
- **Blocks:** the implementation wave's window architecture.

### D2 — Acceptance discoverability and placement

- **Options:** (a) toolbar overflow + Task menu only; (b) evidence-disclosure row
  only; (c) both (a) and (b), no always-visible button.
- **Recommendation:** (c). Acceptance is a separate, non-primary action (per the
  issue), but it must be findable from the result without hunting: the overflow
  “Accept result” and the evidence disclosure's “Accept result” share one command
  (Task ▸ Accept result). A dedicated visible button is deferred until the
  accessibility pass shows whether (c) is discoverable enough — the spec's
  validation plan item 4 covers this explicitly.
- **Blocks:** the result surface's toolbar/menu wiring.

### D3 — Home surface on project open

- **Options:** (a) always project overview; (b) always last task; (c) restore the
  last surface (session persistence), new projects default to overview.
- **Recommendation:** (c), consistent with 2.x session persistence and the
  stable-identity requirement.
- **Blocks:** window restoration behavior.

### D4 — The Overview/Result tab

- **Options:** (a) one tab that renames `Overview` → `Result` at Ready; (b) two
  permanent tabs.
- **Recommendation:** (a). A second tab that duplicates the artifact adds a level
  without new content; the rename is itself the Ready signal. The rename is an
  AX-announced state change.
- **Blocks:** tab strip and its accessibility treatment.

### D5 — Landing of the conserved raster archive

**Open dependency.** The archive — three app-icon directions (Fold, Aperture,
Assembly) plus the four exploratory workspace mockups and their index README —
lives in **closed, unmerged PR #1737**; none of it is on main today. This
package cites it by pinned commit (`9f545492`), so the citation stays valid
however the archive lands.

- **Options:** (a) re-land the archive as its own PR (the original was closed
  unmerged); (b) include the archive files in this design PR.
- **Recommendation:** (a). This package is complete either way; keeping the
  archive's landing independent preserves its scope (icons, tracked with #1736,
  plus the raster workspace concepts) and avoids coupling two decisions.
  Whether the archive lands before, with, or after this design package is a
  maintainer merge-order decision, not a dependency of this package.
- **Blocks:** nothing in this package; only link style if (b) is chosen.

### D6 — Input during an active turn

- **Options:** (a) always disable the composer with a reason until the turn ends;
  (b) queue with a visible “Queued” chip where the adapter supports it, disable
  with a reason where it does not.
- **Recommendation:** (b) — it matches actual provider capabilities and never
  promises universal interruption. This is capability-dependent per adapter and
  must be validated per provider in the adapter wave (#1723).
- **Blocks:** composer state machine and the adapter capability surface.

### D7 — Keyboard shortcuts for the task tab strip and evidence row

- **Options:** (a) `⌘1`–`⌘4` for Overview/Result · Changes · Code · Terminal and
  `⌘⌥E` for the evidence row; (b) no dedicated shortcuts, standard Tab/arrow only.
- **Recommendation:** (a), with the conflict audit against 2.x shortcuts done in
  the implementation wave (⌘1–⌘4 are free in 2.x; `⌘.` for cancel is fixed).
  Terminal behavior remains unmodified either way.
- **Blocks:** menu command wiring.

### D8 — Compact-window sidebar behavior

- **Options:** (a) manual collapse only (`⌥⌘S` / toolbar toggle) down to an icon
  rail; (b) automatic collapse below a content-width threshold, with manual
  override; (c) hide the sidebar entirely below the minimum size.
- **Recommendation:** (a) first — native macOS sidebar behavior, predictable, and
  the icon rail keeps Inbox/project/task identity visible. (b) can be layered later
  if the minimum-size pass shows the rail + content is too tight; (c) is rejected
  because it removes task identity from the window.
- **Blocks:** window minimum size and the icon-rail variant design.

### D9 — First-verification in flight is not expressible in the merged model

- **Model gap:** `verificationState == .pending` is produced only by
  `recordVerificationPending` against a settled `.success` attempt — that is,
  re-verification. First verification in flight (checks/review running while the
  attempt is live or has just ended) cannot be expressed in the merged lifecycle
  model.
- **Options:** (a) the UI derives the in-flight phase from the #1724
  verification layer's orchestration state (this spec's direction); (b) extend
  the lifecycle model with an expressible first-verification-in-flight state.
- **Recommendation:** (a) for this design package — it keeps the spec 1:1 with
  the merged model; (b) is a lifecycle-contract change belonging to the #1722
  owners and out of scope here.
- **Blocks:** nothing in this package; only the wording of spec sections 2.3,
  2.4, and 3 if (b) is adopted later.

## Sign-off checklist

For design sign-off of this package (docs wave):

- [ ] Compositions A/B/C compared in concrete vector designs (this package).
- [ ] Recommended composition recorded (A, refined).
- [ ] End-to-end journey specified against the merged lifecycle model, with
      truthful capability limitations.
- [ ] Result actions specified for web, native app, CLI, backend/API, library,
      documentation, and non-runnable results; no fabricated trial.
- [ ] Accessibility requirements specified per surface.
- [ ] Manual-workflow preservation specified.
- [ ] Open decisions D1–D9 recorded with recommendations.
- [ ] Maintenance note: when A is implemented, this package's mockups are
      superseded by approved implementation screenshots and
      recommendation.md should point to them; the archive PNGs remain historical.

For design sign-off of the *experience* (implementation wave), the validation plan
above must also be complete and its results recorded against each acceptance
criterion of #1735.
