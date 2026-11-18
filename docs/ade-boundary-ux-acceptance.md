# Comparative acceptance: component boundaries

Protocol draft for [#1762](https://github.com/batonogov/pine/issues/1762),
2026-11-16. **No comparative trial has run; no score or design approval is
claimed.** This supplies observable UX probes for
[#1735](https://github.com/batonogov/pine/issues/1735) and an evidence format for
[#1761](https://github.com/batonogov/pine/issues/1761), not another feature survey.

## Why this record is needed

The merged [T3 research](t3-code-agent-integration-2026-11-15.md) establishes
source-level mechanisms and their owners, not how easily a person understands
the boundaries between them. Its gap map and the
[CLI evidence record](cli-capability-evidence-2026-11-14.md) remain the research
inputs; do not repeat their feature inventory as a usability result.

The question here is narrower: **when ownership or evidence changes, can the
user predict the effect, see what actually happened, and continue without
relaying information between components?** A fast individual component does not
answer that question.

Use the [selected composition](pine-3.0-product-vision.md#selected-composition):
one current project, task-local results/output, explicit Request/Command modes.
Older issue language requiring an embedded editor, terminal or standalone Inbox
is superseded. Voluntary inspection through available external tools is not a
failure; forced context reconstruction or relaying is.

## Entry conditions and honest blockers

- Record the exact application/candidate, OS, provider binary, transport,
  requested/confirmed settings, fixture revision and required checks before
  starting. Use an authorized disposable project, never an existing session.
- Require an implemented flow for runtime observations. At Pine base
  `8e27073e48041e9137ae371f05651ebe5fe1cc51`, a production-source search for
  `CodexAppServerClient(` and `CodexAppServerTaskMapper(` still finds no
  constructions. This corroborates the T3 report's missing integration seam,
  not an executed test or proof that every launch path is absent.
- Real-provider execution, model calls and installations are not authorized for
  this work. No usable authorized competitor runtime was established here;
  absence of installed applications was not rechecked. Zed, herdr and a
  result-oriented baseline therefore remain **unmeasured**, not failed.
- #1723 supplies the first real task, #1756 continuation, #1754/#1755 actual
  checks/review, and #1725/#1758 result/feedback. #1795's unresolved closure
  contract prevents treating a parent turn ending as settled work.
- Concept walkthroughs may test labels and navigation only. Synthetic fault
  injection may test UI reactions only. Neither closes real-provider acceptance.

These conditions block the full comparative result, not preparation of the
following test cards. Do not close #1762 on this protocol alone.

## Boundary cards

Before each consequential action, ask once: “Which task/revision will this
affect, and what will happen?” Record the answer without coaching. Afterward,
ask “What happened, and what can you do next?” A moderator explanation counts
as assistance, not successful discovery.

Use one pinned fixture with a deterministic failing check and two specified
revisions. Freeze its requirements, expected outputs, check plan and result
action before the pilot; attach those artifacts to the run record. The examples
below name revision identities, not provider-specific expected prose.

| ID / boundary | Controlled action | Observable acceptance / evidence to retain | Correction owner |
| --- | --- | --- | --- |
| B1 Intent → execution | Enter command-shaped text in Request without submitting. Switch to Command, inspect the destination, then explicitly submit a harmless fixture command. Navigate away and back. | User can distinguish agent request from exact command execution before submission; destination task/environment and output remain identifiable afterward. No syntax-based mode switch, agent rewriting, duplicate dispatch or silent draft loss. Retain mode, submission and execution identities. | #1760, #1756, #1757 |
| B2 Question → effect | Task A asks an approval while B is selected. Open A, decline once, then present a duplicate/stale copy of the same request. | User identifies A and the consequence before answering; sees declined, expired or delivery-unknown truthfully afterward. B is unchanged. UI does not imply a saved answer reached the provider without confirmation. Retain native request, task/attempt and delivery state, not secret answer content. | #1723, #1732, #1727, #1728 |
| B3 Evidence → usable result | Produce R1 with a failing required check; later provide passing checks but no independent review. Only then supply current review. Open the result; separately invoke its result action. | No earlier stage presents Pine Ready. User distinguishes incomplete evidence from failure, and opening from running or accepting. The action identifies the checked revision/environment and any side effects. Retain candidate/evidence/action identities and whether execution occurred. | #1753–#1755, #1725 |
| B4 Feedback → revised result | On R1 attach “Keep the first change; correct only the second requirement.” Before sending, make R2 current. Send only after the UI resolves the target explicitly. Produce checked R3 and compare. | Feedback either stays attached to R1 or requires an explicit retarget; it never silently follows the newest result. User identifies what changed since the referenced result and whether R3's evidence is current, without copying reviewer findings into another session. Retain feedback target and R1/R2/R3 identities. | #1758, #1755, #1756 |
| B5 Window → background → return | Leave an unsent Command draft, close the project window while A runs, let A ask a question, then reopen via the supported route. Repeat with notifications denied. Separately test actual Quit/relaunch. | Window close does not cancel A. With notifications denied, the question remains discoverable through ordinary app navigation. Return restores task/draft/mode, not a fresh shell or automatic submission. Relaunch labels live evidence stale/unknown and requires explicit continuation; retain whether any new dispatch occurred. | #1756, #1728, #1735 |
| B6 Capability loss → recovery | Use a controlled expired-auth or unavailable-model condition; separately make the bound environment unavailable. | User finds the specific blocker and a safe next action without opening a transcript. No silent provider/model/account/cwd substitution. Recovery preserves task, draft and prior result; unsupported recovery is explicit. Retain blocker classification and chosen action, never credentials. | #1765, adapter owners, #1756 |

For B3, do not require competitors to use Pine's “Ready” vocabulary or provide
Pine's independent-review design. Record what their actual completion indicator
asserts and what check/review evidence is accessible. If equivalent verification
cannot be configured, mark the outcome **not comparable**, retain the gap, and
do not reward the tool for omitting work.

Run each applicable card with keyboard-only navigation and separately with
VoiceOver. Observe focus after task switching, question arrival, result updates
and back navigation: no background event should steal typing or silently change
the action target. Include compact windows and the supported accessibility
appearance/motion settings; record actual settings and defects, not “native”
as a proxy for passing. #1735 owns visual/craft corrections.

## Scoring without feature-count claims

For each card, record these separately:

- **Prediction / recognition:** correct unassisted, correct after assistance,
  incorrect, or not observable. Record the user's explanation, not merely a
  clicked control. Missing evidence is not a pass.
- **Forced relay:** each required manual transfer of goal, context, findings or
  identity between surfaces/sessions. Count the transfer once; navigation alone
  is not a relay. Also record repeated configuration and decision prompts.
- **Handling time:** sum non-overlapping intervals spent interacting,
  interpreting or recovering, including intervention during agent work.
  Separate passive wait for setup, agent, checks and review; keep full wall time.
  Record interval boundaries so simultaneous agent work is not double-counted.
- **Safety / continuity:** wrong target, misleading completion, duplicate
  dispatch, lost draft/context or concealed uncertainty is a boundary failure,
  even when eventually recovered. Retain recovery steps and outcome.

Pre-register #1762's existing provisional targets before the pilot: no repeated
setup/routing for configured work, zero forced context/review relay, return
orientation within 15 seconds in at least 80% of observed trials, and no
misleading Ready. Orientation means correctly identifying goal, latest result,
evidence freshness and next decision; stop the clock only when all four are
correct. These test the intended continuity and truthful-state promises.

The issue's p95 responsiveness and 30% median handling-time improvements remain
**unmeasured hypotheses**. Do not derive input latency from task duration or
claim an improvement from a concept walkthrough. Freeze any pilot revisions
and rationale before final runs; retain old thresholds beside the new ones.

Use matched task requirements and counterbalanced tool order after a recorded
familiarization exercise. Separate first-use from repeat-use. If model/provider,
verification or recovery capabilities differ, retain the confound and report
stratified observations, not one pooled winner. Retain failed/assisted attempts
in counts and time reports; never compute a speed claim from successful trials
alone. Small formative samples support findings, not population-wide claims.

## One evidence row per observation

Copy this header into the eventual #1762 trial artifact, not a release dashboard:

```text
run/card | tool+version/candidate | fixture+requirements/check plan |
provider+transport+effective settings | input/accessibility conditions |
task/attempt/request/result references | predicted effect | observed effect |
unassisted/assisted/incorrect/not-observable | relay/setup/decision counts |
handling intervals + passive waits + wall time | failure/recovery/confounds |
sanitized evidence reference | correction owner + disposition
```

Use pseudonymous participant IDs and explicit recording consent; retain only
bounded sanitized evidence. Do not commit transcripts, private paths, account
IDs or attachments. Mark fixture/source/concept/runtime provenance on every row.
For a newly authorized real trial, record its diagnostic retention/deletion
policy before capture.

Feed observed boundary defects to their existing owners and link the corrected
candidate plus rerun in #1761. Record an explicit keep/change/remove/defer
decision with evidence in #1735/#1760; a new panel is not the default remedy.
No composition is reselected here, no optional provider or T3 watch/revert
feature becomes required, and no superiority claim follows from this protocol.
