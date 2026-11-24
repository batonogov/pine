# #1762 cohort trial runbook — maintainer procedure

**No trial has run.** This is the exact procedure to run the live cohort trial
this kit defines: 5–8 opt-in developers, opt-in recordings, maintainer-run,
counterbalanced tool order. Scenario details, fixtures and thresholds are
owned by the kit files, not by this runbook:
[scenarios/](scenarios/README.md), [scorecard.md](scorecard.md),
[baseline-access.md](baseline-access.md), and the
[#1810 protocol](../../ade-boundary-ux-acceptance.md). Every threshold below
remains a pre-registered HYPOTHESIS until measured rows exist.

## 1. Inputs the maintainer must provide

| Input | Requirement |
| --- | --- |
| Machines | One trial Mac per participant, dedicated to that participant for the whole trial (matched conditions, no contention); re-record OS/hardware and exact versions at run time. The T4 reference Mac is the machine recorded in [baseline-access.md](baseline-access.md) (macOS 27.2.1, M4 Pro, 48 GiB); use macOS 26/27 as available. |
| Baseline installs — three required | For each, per the [baseline-access.md](baseline-access.md) table: (a) install + an authorized working session + record the exact version there → a **runtime** baseline; or (b) keep the named concrete blocker (2026-11-16: all three blocked: "not installed, installation not authorized") → **source-only** evidence, comparison limited to documented claims, and the resulting confound stated in #1761. Zed: app + agent session (Zed account or external-model config). herdr: app + runtime. Result-oriented: one of Conductor / Orca / Codex desktop, app + paid/authorized account. |
| Pine candidate | The 3.0 milestone state at run time: a specific branch + SHA, built locally with the AGENTS.md `xcodebuild` commands (deployment target 26.0), never a release build. Record branch, SHA, build date and derived-data path in the run record. |
| Provider accounts | Authorized working sessions for the #1811 delivery order OpenCode → Codex → Kimi → Claude; record the actual binary, adapter transport, requested vs effective model/effort and enabled capabilities on every row. |
| Cohort | 5–8 opt-in developers with varied familiarity with agent tools; pseudonymous participant IDs; explicit recording consent, and the diagnostic retention/deletion policy recorded **before** capture (#1810). No production telemetry, no hidden analytics. |
| Facilitator | One facilitator (a person, not an agent) who prepares packets, performs hidden-oracle runs and scores rows; ~30 min prep per session, ~15 min scoring after each session. |
| Time budget (planning estimate) | Per tool per participant: ≈6–7 h of active work over 3 sessions of ≈2.5 h. Per participant: 4 tools → ≈24–28 h over ~12 sessions. Cohort of 8: ≈200 participant-hours plus facilitator overhead ≈ 4–6 calendar weeks with one facilitator. The pilot calibrates this estimate; record any revision and reason. |

## 2. Pre-trial checklist (once; record everything in the run record)

1. Resolve or keep each required baseline per §1; update
   [baseline-access.md](baseline-access.md) rows with the exact version and
   date, or keep the named blocker.
2. Re-record machine conditions: OS/hardware, every tool/app/provider version.
3. Fresh isolated fixture copy per trial and per participant. Record the
   SHA-256 of the fixture files (four revenue, nine ledger) at run time.
4. Verify the offline runners on the trial machine:
   `python3 -B test_report.py` in revenue/ (expect 5/5 self-tests, exit 0) and
   `python3 -B test_ledger.py` in scenarios/ledger/ (expect 5/5, exit 0), plus
   the documented RED seed runs (exit 1, known failing cases).
5. Freeze T1–T6 from [scorecard.md](scorecard.md) into the run record. A
   pilot may refine a threshold only by recording the revision + reason and
   keeping the old threshold beside the new one — never after results.
6. Build the counterbalance schedule (Latin square over the four tools) and
   record it; first-use is always the participant's first session with a tool,
   repeat-use is separate.
7. Facilitator prepares per-participant packets (revenue Packet 1; ledger
   T1–T3 packets). Oracles (`test_report.py` / `test_ledger.py`) and
   facilitator answers never enter participant materials or model context.
8. Build the Pine candidate (§1) and verify a working session per provider on
   the reference Mac.
9. Record recording consent + the retention/deletion policy before any
   capture.

## 3. Sessions and scenario assignments

Per tool per participant: 3 sessions of ≈2.5 h, same machine, no coaching,
tool order per the counterbalance schedule. Scenario content per
[scenarios/README.md](scenarios/README.md). **Pilot first:** the first two
participants (one familiar, one less familiar with agent tools) complete the
full battery; after the pilot, revise thresholds per the rule in §2.5 and the
session plan/estimate per §1, recording revision + reason in the run record.

| Session | Content |
| --- | --- |
| 1 — first-use | 15 min recorded familiarization → SC1 → SC2 → SC3 |
| 2 | SC4 (incl. the 5-min neutral task) → SC5 (T1→T2→T3, recorded order) → SC6 where the tool supports explicit handoff (Pine: OpenCode → Codex per #1811; record its absence as a capability difference, never simulate one) |
| 3 — repeat-use | F probes the tool can induce — baseline F1 (expired account), F3 (denied action), F5 (lost session); F2, F4, F6 where supported, otherwise marked **not comparable** → configured repeat task (fresh seed copy, new task identity; count setup/provider/routing again, feeds T1) |

Pine-only additions: the T4 responsiveness probe (§4) and the #1810 boundary
cards B1–B6 where the candidate supports them. Baselines: run the same
scenarios only where genuinely supported; where equivalent verification cannot
be configured, mark the outcome **not comparable**, retain the gap, and do not
reward the tool for omitting work (#1810 B3). Include at least two
participants who run one full session keyboard-only and one full session with
VoiceOver (minimum for the accessible/manual-workflow criterion; the pilot may
expand it); record actual settings and defects, not "native" as a proxy.

## 4. Measurement

- One [scorecard.md](scorecard.md) row per tool × participant × scenario run,
  using its columns verbatim: run; fixture/requirements; provider/transport/
  settings; completion/quality; handling time **split** (cold setup | warm
  creation | agent execution | required verification | human handling — never
  summed); context copying; interruptions; recovery (F rows); responsiveness;
  learnability; stated preference; removed/merged concepts; repeated user
  decisions; evidence classification; failures/confounds.
- The facilitator, not an agent, runs the hidden oracles: RED before
  participant work and GREEN on the checked candidate afterward (revenue per
  stage; ledger per task). Participant-authored regression checks are scored
  separately; verification equivalence is assessed against the whole hidden
  gate, not just the stored CSVs.
- A **usable result** is the first successful explicit CLI trial of the
  identified checked candidate with its expected output; a provider completion
  message never counts.
- T4 probe (Pine, reference Mac, under the SC5 three-task load): ≥30 scripted
  input samples (task switches, result reopen, focus changes); capture screen
  + event timestamps; compute p95 input-to-feedback excluding network/agent
  work. Record method, samples and machine; never derive latency from task
  duration.
- Accessibility/manual workflows: the keyboard-only and VoiceOver sessions
  above count toward the issue's accessible-workflow criterion; assistance
  given is recorded and never a pass.

## 5. Pass/fail (pre-registered from the issue before any trial)

| ID | Threshold (issue wording) | Status |
| --- | --- | --- |
| T1 | A configured repeat task needs no repeated provider/setup configuration or manual worktree routing | HYPOTHESIS |
| T2 | A two-revision result loop requires zero manual context copy/paste or manual relay of reviewer findings | HYPOTHESIS |
| T3 | On returning, a user can identify goal, latest result, evidence freshness, and next decision within 15 s in at least 80% of observed trials | HYPOTHESIS |
| T4 | p95 input-to-feedback below 100 ms under the documented three-task load on the recorded reference Mac, excluding network/agent work | HYPOTHESIS |
| T5 | No misleading Ready in the acceptance fault matrix; every generated attention item is a usable result or a concrete decision, with no duplicates | HYPOTHESIS |
| T6 | After familiarization, at least 30% lower median human-handling time for the revise-and-return scenarios (SC2, SC4) than the best tested baseline, with no loss of outcome quality or verification | HYPOTHESIS |

A threshold counts as met only with measured scorecard rows behind it, under
the small-sample reporting rules in [scorecard.md](scorecard.md) (counts/
ranges, no significance testing, failed attempts retained, provider
differences stratified, T6 medians with sample size and range). Acceptance
criterion 4 is met per baseline by either a measured runtime baseline **or**
the named concrete access blocker — a blocker stands until an installation
with an authorized working session records its exact version.

## 6. After the trial

1. Fill every scorecard row (pseudonymous; no transcripts, private paths,
   account IDs or attachments committed).
2. Publish the publication set: task scripts (packets + fixtures + oracles),
   evidence classifications, anonymized observations.
3. Trace each failed scenario through the scorecard's design-decision table to
   its owning issue; #1735 keeps a keep/change/remove/defer decision with
   evidence; #1761 records the integrated evidence including corrected
   candidate + rerun.
4. State source-only baselines and all confounds in #1761. No public claim
   beyond measured/implemented strengths; unselected competitor features stay
   explicit gaps/tradeoffs.
5. #1762 closes only on the measured scorecard — not on this protocol or the
   pre-trial kit.
