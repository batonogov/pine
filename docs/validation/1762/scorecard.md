# #1762 scorecard — pre-trial skeleton

**No trial has run.** This is the row template, the pre-registered thresholds
and the reporting rules for the live cohort trial (external, maintainer-run,
5–8 opt-in developers, opt-in recordings). One row per tool × participant ×
scenario run, using the
[evidence-row fields from #1810](../../ade-boundary-ux-acceptance.md#one-evidence-row-per-observation).
Do not commit transcripts, private paths, account IDs or attachments; keep
pseudonymous participant IDs and explicit recording consent.

## Required baselines

Zed (required), herdr (required), and one result-oriented baseline from
Conductor / Orca / Codex desktop (required). Status 2026-11-16: all three
carry **named concrete access blockers** on the trial machine — see
[baseline-access.md](baseline-access.md). Acceptance is a measured baseline
**or** a named concrete blocker; a blocker stands until an installation with
an authorized working session records its exact version. A blocked baseline
contributes documented-claim evidence only (labeled **source**, never
**runtime**).

## Pre-trial thresholds — hypotheses

Recorded from the issue before any trial. These are **targets, not measured
facts**; every row below is a HYPOTHESIS.

| ID | Threshold (issue wording) | Status |
| --- | --- | --- |
| T1 | A configured repeat task needs no repeated provider/setup configuration or manual worktree routing | HYPOTHESIS |
| T2 | A two-revision result loop requires zero manual context copy/paste or manual relay of reviewer findings | HYPOTHESIS |
| T3 | On returning, a user can identify goal, latest result, evidence freshness, and next decision within 15 seconds in at least 80% of observed trials | HYPOTHESIS |
| T4 | Local input/focus/navigation remains responsive under the documented three-task load; p95 input-to-feedback below 100 ms on a recorded reference Mac, excluding network/agent work | HYPOTHESIS |
| T5 | No misleading Ready in the acceptance fault matrix; every generated attention item is a usable result or a concrete decision, with no duplicates | HYPOTHESIS |
| T6 | After familiarization, at least 30% lower median human-handling time for the revise-and-return scenarios than the best tested baseline, with no loss of outcome quality or verification | HYPOTHESIS |

**Pilot-refinement rule:** a pilot may refine a threshold before the final
trial only by recording the revision + reason and retaining the old threshold
beside the new one. Thresholds are **never** moved after results to claim
success. T1, T2, T3, and T5 were already pre-registered by
#1810; T4 and T6 remain unmeasured hypotheses there — keep the two records
consistent.

## Row template (scorecard columns)

| Column | Definition / notes |
| --- | --- |
| run | pseudonymous participant ID + tool + exact version/candidate + scenario (SC1–SC6 / F1–F6) + run order |
| fixture / requirements | fixture identity + SHA-256 + packet version + check plan, pinned before the run |
| provider / transport / settings | actual binary, adapter transport, requested vs effective model/effort, enabled capabilities (issue CLI audit) |
| completion / quality | completed / failed / blocked + outcome quality against the oracle/requirements — never against a completion message |
| handling time — **kept separate, never summed** | cold setup \| warm task creation \| agent execution \| required verification \| human handling, per the revenue seed's measurement definitions; missing review/check coverage is recorded as a gap, not credited as speed |
| context copying | manual cross-session transfers of task context or reviewer findings, each counted; repeated provider/setup/environment decisions counted separately (feeds T1, T2) |
| interruptions | controlled interruption performed (SC4/F5); whether task/draft/mode state survived |
| recovery | F1–F6 only: blocker found without transcript (yes/no/time); recovery to a safe next action (steps, transcript consulted); silent substitution (must be no); task/draft/prior result preserved |
| responsiveness | p95 input-to-feedback samples under three-task load (T4) — recorded separately from task duration; never derived from it |
| learnability | first-use vs repeat-use, failed attempts, assistance given, the user's own words about learning cost |
| stated preference | participant's stated preference + reasons (verbatim, anonymized) |
| removed/merged concepts | workspace concepts removed or merged that the participant noticed during the run (feeds #1735); speculative handoff/variants/extensions seen in a prototype **do not** become required implementation |
| repeated user decisions | decisions the user had to make again that a configured tool should remember (feeds T1) |
| evidence classification | fixture (offline oracle) / source (documented claim) / concept (walkthrough) / runtime (observed live) — per #1810; mark provenance on every row |
| failures / confounds | failed attempts, learning, provider/model differences, caches, machine contention, observer intervention — retained visible |

## Small-sample reporting rules

- Formative cohort of 5–8: report **counts/ranges and qualitative
  findings** only, except that T6 may include **descriptive within-sample
  medians**, each reported with its sample size and range. No significance
  testing, statistical inference or population-wide claims at this sample
  size, including from T6 medians.
- Failed attempts and learning stay in the counts and time reports; never
  compute a speed claim from successful trials alone.
- Counterbalance tool order across participants (record the schedule); report
  first-use and repeat-use separately.
- Provider/model differences are recorded confounds and reported stratified,
  never pooled into one winner.
- Publication set: task scripts (packets + fixtures + oracles), evidence
  classifications, anonymized observations.
- **No public claim describes a measured/implemented strength that was not
  tested or implemented; no untested universal superiority claim.** A
  competitor feature not selected for 3.0 stays an explicit gap/tradeoff.
- No production telemetry by default, no hidden analytics, no artificial
  retention mechanics; participation and recordings are opt-in with explicit
  consent.

## Design-decision trace — measured findings → owning issues

Each failed scenario maps to one primary owner plus linked issues; the
corrected candidate and its rerun are recorded in #1761.

| Measured finding class | Owning issue(s) | Notes |
| --- | --- | --- |
| Workspace composition, layout, unfamiliar-first-encounter friction | #1735 | keep/change/remove/defer decision with evidence; a new panel is not the default remedy (#1760 simplicity audit) |
| Request/Command mode, task-local result identity | #1760, #1756, #1757 | #1810 B1 |
| Question/approval delivery, duplicates/stale copies | #1723, #1732, #1727, #1728 | #1810 B2; F4 |
| Evidence, checks, review, Ready state | #1753–#1755, #1725 | #1810 B3; T5 |
| Feedback → revised-result targeting | #1758, #1755, #1756 | #1810 B4; SC2 |
| Window / background / return / relaunch continuity | #1756, #1728, #1735 | #1810 B5; SC4, F5 |
| Capability loss, recovery, adapter behavior | #1765 + adapter owners, #1756 | #1810 B6; F1–F3, F6 |
| Provider handoff, multi-provider routing | #1811 (OpenCode → Codex → Kimi → Claude delivery), #1765 | SC6; record binary/transport/capabilities per side |
| All measured outcomes, integrated evidence record | #1761 | links corrected candidate + rerun |
| Competitor feature not selected | explicit gap/tradeoff record in #1762 | not an implementation requirement |
