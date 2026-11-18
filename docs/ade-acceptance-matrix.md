# Pine 3.0 ADE acceptance matrix

Integration acceptance gate for [#1761](https://github.com/batonogov/pine/issues/1761).
One row per product promise: owner, reproducible scenario, the automated
test or fixture that covers it in the current base, the current evidence
state, and the explicit remaining limitation. Open blockers are recorded as
blockers, never as acceptance.

- Base: `5cd4707b148ab926ced8f7d4f878d8e4c5709056` (2026-11-16).
- Acceptance protocol: [`docs/ade-boundary-ux-acceptance.md`](ade-boundary-ux-acceptance.md) (merged from #1810).
- Scenario seed: [`docs/validation/1762/revenue/`](validation/1762/revenue/README.md) (the #1762 controlled CLI project and independent oracle).
- Negative/recovery scenario fixture: [`PineTests/Fixtures/AgentAdapters/ade-negative-scenarios-v1.json`](../PineTests/Fixtures/AgentAdapters/ade-negative-scenarios-v1.json), guarded by [`PineTests/AdeNegativeScenarioFixtureTests.swift`](../PineTests/AdeNegativeScenarioFixtureTests.swift).
- Evidence retention structure and this machine's recorded versions: [`docs/ade-evidence-record.md`](ade-evidence-record.md).
- Experience and craft sign-off placeholders: [`docs/ade-release-signoff.md`](ade-release-signoff.md).

In-flight sibling branches (not in this base yet; rows are updated as they
land, each against the integrated candidate): `feat/1811-opencode-ade`,
`work/20261116-issue-1723`, `-1732`, `-1727`, `-1753`, `-1754`, `-1755`,
`-1756`, `-1725`, `-1728`, `-1757`, `-1758`, `-1759`, `-1760`, `-1765`,
`-1722`, `-1724`.

## Evidence classifications

The audit's five states, used in every row:

| Classification | Meaning |
| --- | --- |
| **documented** | Source research / official documentation; mutable upstream material, not an observation. |
| **fixture-tested** | Deterministic in-repo test or fixture exercises the behavior; no provider binary, no user data. |
| **observed-on-binary** | The pinned provider binary's actual behavior was observed and recorded (discovery, handshake, or end-to-end). |
| **unsupported** | The capability is confirmed absent; the honest unsupported state is presented instead. |
| **unknown** | Not yet determined; a required unknown is a blocker, not a pass. |

Historical Pine 2.0 Pending rows are not current passes. A row moves to
observed-on-binary only with a recorded pinned version and the sanitized
artifact reference from `docs/ade-evidence-record.md`.

## Matrix

| Area | Owner (issue / branch in this base) | Reproducible scenario | Automated test / fixture in this base | Evidence state | Remaining limitation |
| --- | --- | --- | --- | --- | --- |
| OpenCode | #1811 / `feat/1811-opencode-ade` | Revenue seed task through boundary cards B1–B6 (`ade-boundary-ux-acceptance.md`), then the full vertical slice: request → observed activity/question → unverified result → same-session feedback, cancellation, exact-ID recovery on a pinned version | Detection/identity only: `AgentCatalogIdentityFixtureTests` + `Fixtures/AgentAdapters/identity-boundaries-v1.json`, `process-v1.json`; no structured adapter in this base | C1 documented + fixture-tested; C2–C10 **unknown** | BLOCKER: no OpenCode integration in main; TUI plugin events are not assumed to exist over ACP; every C1–C11 gate unobserved |
| Codex | #1723 / `work/20261116-issue-1723` | Same vertical slice as the second structured adapter on a pinned `codex app-server` version | `CodexAppServer*` client in `Pine/Agent/Adapters/` with protocol fixtures (`CodexAppServerWireTests`, `CodexAppServerTaskMapperTests`, `CodexAppServerConnectionTests`, `Fixtures/AgentAdapters/protocol-review-v1.json`) | documented (app-server protocol) + fixture-tested (client); **no production construction of `CodexAppServerClient(` in this base** (re-verified 2026-11-16); C2–C10 **unknown** | BLOCKER: integration seam missing; no observed-on-binary end-to-end |
| Kimi | #1732 / `work/20261116-issue-1732` | Same core outcome/feedback flow through `kimi acp`, with documented native question, cancellation, history, and attachment capabilities | None for `kimi acp` in this base | documented (T3 research + CLI capability evidence); C1–C11 **unknown** | BLOCKER: no Kimi adapter in main; native question/attachment capability unobserved |
| Claude | #1727 / `work/20261116-issue-1727` | Same core outcome/feedback flow through the owned structured channel; reporting-only terminal hooks cannot answer approvals or create verified completion | Detection/identity fixtures cover `claudeCode` (`identity-boundaries-v1.json`, `process-v1.json`) | C1 documented + fixture-tested; structured channel absent; C2–C10 **unknown** | BLOCKER: no structured Claude channel in main |
| Verification | #1724 (parent) / #1753, #1754, #1755 | Only the current required check plan plus independent review for the current candidate/environment can produce Ready | Model + capture primitives in this base: `AgentTaskLifecycleReducer.requiredEvidenceForSuccess`, code-state/environment identity, operation fingerprints, `AgentVerification*` capture files; `lifecycle-evidence-v1.json` fixture; negative fixture rows `missing/failed/timed-out/cancelled-required-check`, `reviewer-rejection`, `provider-success-without-independent-evidence`, `mutation-during-check-or-review` | fixture-tested (evidence contract, no Ready without current bound evidence); check executor **absent** | BLOCKER: no check execution or review orchestration yet (#1754/#1755); explicit timeout and tool-unavailable classifications pending |
| Corrections | #1755 / `work/20261116-issue-1755` | The unresolved third corrected revision escalates; relaunch/duplicate events cannot launch a fourth automatic attempt | In this base a `requestedChanges` reviewer fact settles failure and nothing in main re-dispatches automatically: `failedSettlementPersists`; fence rows `duplicate-events`, `reordered-events` | fixture-tested (rejection → failure, no auto-retry in base) | BLOCKER: persistent bounded correction rounds, escalation, and budget accounting pending #1755/#1756 |
| Continuity | #1756 / `work/20261116-issue-1756` | Ready/accepted → feedback → revised result stays one durable task, including supported explicit recovery after relaunch | `relaunchInvalidatesVerifiedEvidence`, `relaunchPreservesCompleteDurableRelationship`, `AgentTaskRecoveryTests` (explicit resume/new-session actions, version-locked resume) | fixture-tested (durable task, snapshots preserved, honest recovery actions) | BLOCKER: continuation UX for Ready tasks and result history pending #1756 |
| Repeat work | #1757 / `work/20261116-issue-1757` | A configured second task reuses setup/check/action definitions without manual environment reconstruction | `rememberedAgentPersistsPerProject`, worktree setup snapshot/checkpoint persistence (`AgentTaskWorktreeSetupPersistenceTests`) | fixture-tested (remembered default agent, setup journal) | BLOCKER: reusable check recipes and owned result actions pending #1757 |
| Feedback/comparison | #1758 / `work/20261116-issue-1758` | Feedback retains the original result reference; checked revisions compare without silently retargeting old comments | `AgentTaskFeedbackRecord` (bounded, content-free, durable: `feedbackRecordsAreBoundedAndDurable`), `AgentTaskComparison` (fact-only, no winner field: `AgentTaskComparisonTests`) | fixture-tested (model) | BLOCKER: revision-bound feedback UX pending #1758 |
| Context | #1759 / `work/20261116-issue-1759` | Return-to-task brief preserves explicit decisions without manual reconstruction; provider handoff has a recorded ship/defer decision (separate from release gating) | Objective/title persistence in the durable task model; `AgentCompletionBriefTests` | fixture-tested (model) | BLOCKER: brief UX pending #1759; handoff ship/defer decision not yet recorded |
| Simplicity | #1760 / `work/20261116-issue-1760` | The selected workspace implements its removal/merge decisions; no new evidence/context/action type becomes a permanent panel or repeated setup step | None (design decision; workspace scope confirmed 2026-11-16 in #1760) | documented | BLOCKER: subtraction/merge ledger and implementation pending #1760 (sign-off placeholder in `ade-release-signoff.md`) |
| Parallelism | #1728 / `work/20261116-issue-1728` | At least three independent same-repository tasks preserve routing/evidence/request isolation; documented N+1 queues or defers without another process launch | Single-task binding in this base refuses sharing: `activeEnvironmentCannotBelongToAnotherTask`, `AgentTaskEnvironmentBindings.maximumReservations`; per-run evidence fencing (`evidenceFencing`, `vendorSessionFencing`) | fixture-tested (single-task refusal, per-run fencing) | BLOCKER: three-task isolation and N+1 scheduling pending #1728 |
| Workspace | #1735 (design) + #1760 | One current project → tasks → result; no built-in source viewer/editor, file tree, terminal emulator, multi-project dashboard or standalone Inbox; explicit Request/Command input, task-local questions, feedback, comparison, and evidence work end to end; migration preserves user work | Legacy 2.x editor workspace only; ADE workspace not in this base | documented (selected composition) | BLOCKER: ADE workspace implementation pending #1735/#1760 |
| Project types | #1735 + #1757 (result action) | One complete result-action path on the revenue CLI seed (`python3 -B report.py syntheticorders.csv`, oracle `test_report.py`); web, native-app, CLI, and non-runnable design examples validated without fabricated runnable artifacts | Revenue seed + independent oracle in this base (calibration: 5/5 self-tests, Python 3.9.6, recorded in the seed README); no result executor in the app | documented (seed) + fixture-tested (oracle self-check) | BLOCKER: the in-app result-action path pending #1757; non-CLI project examples unvalidated |
| Native quality | #1735 + #1761 (gate) | Keyboard, VoiceOver announcements, Reduce Motion, focus/back navigation, compact windows, unsaved work, and restoration verified on the implemented ADE surfaces | In this base: `AccessibilityLocalizationSmokeTests` (keyboard-only journey, Reduce Motion, Differentiate Without Color, 9-locale 4-configuration CI matrix, pseudolocalized layout), `AgentAttentionKeyboardUITests`, `SessionRestoreTests`, `UnsavedChangesUITests`; manual pass `docs/accessibility-release-checklist.md` | fixture-tested (matrix definition; runs in CI, not in this local slice) | ADE surfaces absent; Increase Contrast and Reduce Transparency are manual-only (not in the automated matrix); observed-on-binary requires the candidate CI run |
| Locales/runtimes | #1761 (gate) + CI | All nine app locales (en, de, es, fr, ja, ko, pt-BR, ru, zh-Hans) and supported macOS 26/27 behavior have explicit evidence or an unresolved blocker | `LocalizationCatalogCompletenessTests`, `docs/i18n/` (9 locales), CI macOS 26/27 axes | fixture-tested (catalog completeness); observed-on-binary **pending candidate CI** | No integrated-candidate CI run exists yet; macOS 26/27 cross-runtime evidence outstanding |
| Identity/public claims | #1736, #1730, #1733 | Approved production icon/assets and accurate README/site/Help/About/screenshots match the candidate; canonical cask remains `pine-editor` | 2.x identity ships in this base; 3.0 icon/positioning not in this base | documented (2.x baseline) | BLOCKER: 3.0 icon (#1736), public surfaces (#1730), and cask decision (#1733) all pending |

## Negative and recovery scenarios

The issue's section-3 list is encoded row-for-row in
[`ade-negative-scenarios-v1.json`](../PineTests/Fixtures/AgentAdapters/ade-negative-scenarios-v1.json)
(33 rows). `AdeNegativeScenarioFixtureTests` fails if any required scenario
is silently missing, if a covered row does not cite an existing test, or if a
pending row lacks an owning branch. 28 rows are fixture-tested in this base
(cited by test), 1 row is added by this slice
(`late-completion-after-cancellation`), and 4 rows are pending owned
in-flight branches:

| Pending row | Owner |
| --- | --- |
| `unavailable-check-tools` | `work/20261116-issue-1754` |
| `provider-auth-capability-loss` | `work/20261116-issue-1765` + adapter owners |
| `crash-between-round-accounting` | `work/20261116-issue-1755`, `work/20261116-issue-1756` |
| `relaunch-exhausted-correction-budget` | `work/20261116-issue-1755` |

Routing, lifecycle, fault-injection, and resource-bound determinism is
carried by the existing fixtures and mechanisms, not by an LLM producing
identical prose: `lifecycle-evidence-v1.json` (lifecycle settlement),
`identity-boundaries-v1.json` / `process-v1.json` (detection routing),
`protocol-review-v1.json` (wire boundaries), `PersistenceFaultInjection`
(crash-window writes), and `AgentTaskPersistenceLimits` (documented
resource bounds).

## C1–C11 capability gates (audit additions)

Per the 2026-11-14 audit handoff, each required adapter must feed actual
pinned capability results through these gates. Status in this base:

| Gate | Meaning | OpenCode #1811 | Codex #1723 | Kimi #1732 | Claude #1727 |
| --- | --- | --- | --- | --- | --- |
| C1 | Discovery/launch | fixture-tested (identity corpus) | fixture-tested (client + wire) | documented | fixture-tested (identity corpus) |
| C2 | Auth/effective settings | **unknown** | **unknown** | **unknown** | **unknown** |
| C3 | Questions/permissions | **unknown** | **unknown** | **unknown** | **unknown** |
| C4 | Sessions/recovery | **unknown** | fixture-tested (version-locked resume model) | **unknown** | **unknown** |
| C5 | Enforced read-only review | **unknown** | **unknown** | **unknown** | **unknown** |
| C6 | Parallel/shared-state ownership | fixture-tested (single-task refusal) | fixture-tested (single-task refusal) | **unknown** | fixture-tested (single-task refusal) |
| C7 | Context/media | **unknown** | **unknown** | **unknown** | **unknown** |
| C8 | Environments/actions | **unknown** | **unknown** | **unknown** | **unknown** |
| C9 | Candidate-bound evidence | fixture-tested (evidence contract) | fixture-tested (evidence contract) | **unknown** | fixture-tested (evidence contract) |
| C10 | Result-first UX | **unknown** | **unknown** | **unknown** | **unknown** |
| C11 | Public compatibility | **unknown** | **unknown** | **unknown** | **unknown** |

An unavailable required core capability is a blocker, not a pass. Discovery,
handshake, and end-to-end evidence must be recorded separately per
`docs/ade-evidence-record.md`.

## Open blockers (not acceptance)

1. No structured provider adapter is integrated in this base — the OpenCode,
   Codex, Kimi, and Claude rows cannot reach observed-on-binary until
   `feat/1811-opencode-ade`, `work/20261116-issue-1723`, `-1732`, and `-1727`
   land and are re-run against the integrated candidate.
2. No check/review executor or bounded correction rounds — Verification and
   Corrections rows are blocked on #1753/#1754/#1755.
3. No ADE workspace, result actions, feedback UX, brief, or parallel
   scheduling — blocked on #1735/#1760, #1757, #1758, #1759, #1728.
4. No integrated candidate SHA or candidate CI run exists — every
   observed-on-binary cell in the matrix is outstanding until the release
   candidate is assembled and its required checks pass.

## Executed in this slice (base `5cd4707b`)

The rows executable on this base were run locally; commands, counts, and
environment are recorded in
[`docs/ade-evidence-record.md`](ade-evidence-record.md#record-base-5cd4707b-this-slice).
No row requiring an in-flight branch was faked: pending rows name their
branch. The focused fixture suite passed 4/4; the full `PineTests` run
finished with failures that are **untriaged (machine pause under swarm
load)** and must be rerun in isolation before any matrix row is claimed
green at the suite level.
