# Pine 3 subtraction ledger — #1760

Source audit: `8e27073e48041e9137ae371f05651ebe5fe1cc51`
(parent of branch base `5cd4707b148ab926ced8f7d4f878d8e4c5709056`),
November 16, 2026.
The [maintainer decisions](https://github.com/batonogov/pine/issues/1760)
supersede the issue body's earlier editor/terminal/Inbox preservation wording.
This is an implementation inventory, not usage research, final design approval,
or end-to-end acceptance. The browser prototype is historical, not delivered UI.

## Bounded candidate: process-exit notifications ([#1834](https://github.com/batonogov/pine/issues/1834))

**Remove**, not hide: the process-ended event, its delivery/title branches,
Settings toggle, and nine-language catalog entry. All nine preference explanations
state that process exit alone does not trigger an alert. Process-only observations
produce no notification, even after stale evidence or repeated polling.
Started/working notifications were not found in the resolver.

**Global-silence consequence.** Every checked-in compatibility record
(`Agent/Adapters/FirstPartyAgentCompatibility.swift`) declares `processTerminationOnly`, and
the unknown-agent fallback does too, so `boundedAccuracy` resolves
process-only for every production task and `eventKind` returns nil for
**every** transition: as of this candidate the app fires no agent notification
at all — no waiting, failure, or completion — and the three surviving
Settings toggles control nothing until the first verified-accuracy adapter
lands (#1753/#1754, #1811 — the first structured adapter is the concrete
unblock). Keeping the exit banner would violate the confirmed
decision that process exit alone does not warrant attention, so the silence
is the only consistent state; it is recorded here for explicit acceptance,
not as a side effect.

Keep process observation, termination, task/history persistence, cancellation,
route identity, and attention delivery infrastructure. Ignore the obsolete
`agentNotifications.event.processEnded` preference; do not delete or reinterpret
it, delivered-event IDs, or user records. An old preference cannot enable a
retired category. No process is stopped, restarted, or replayed by this change.

Regression coverage: `AgentNotificationTests` covers silent exit, stale exit,
repeat observation, capability/evidence downgrade, both obsolete preference values,
master-disable preservation, retained delivery IDs and retained history.
Notification retry, authorization and deduplication tests now
use authenticated waiting-state fixtures, not the removed exit event.
`AgentDetectionCoordinatorTests` and `AgentTaskLifecycleEvidenceTests` retain
their lifecycle/history assertions while expecting no exit banner.

Edge recorded for #1753/#1754: a process that dies while `waitingInput`
settles `.unverified` with no attention (the resolver requires
`run.liveness == .live`), so it produces no notification and no badge;
process death while waiting must map to a failed/actionable state when
verified adapters land.

This does **not** complete notification redesign: the legacy `.completed`
transition still means reported completion, not a verified usable result.
Replacing that category with exact-candidate Ready notifications belongs with
result/evidence owners #1753/#1754 and workspace/acceptance #1735/#1761.
Do not rename it Ready or promote process exit to a result.

## Current app versus approved disposition

All rows except the bounded candidate above remain implemented or require
replacement integration. “Remove” below is authorization, not a delivery claim.
Paths are relative to `Pine/`; owners are integration coordination, not new issues.

| User job / current surface | Selected disposition and rationale | Current implementation / owner | Migration and retained coverage required |
| --- | --- | --- | --- |
| Observe progress / Activity | Merge into task; remove standalone destination | `Agent/AgentActivityView.swift`, `ContentView.swift`, `ContentView+Helpers.swift`; #1735 | Preserve observations, ownership, pending questions and diagnostics; task routing/accessibility tests |
| Return to runs / History | Merge into task history | `Agent/AgentHistoryView.swift`, `ContentView+Helpers.swift`; #1756/#1735 | Explicit fallback for unbound legacy records; keep provenance, revisions and recovery tests |
| Respond / Inbox, toolbar badge, menu | Merge attention into current project's task list; remove separate Inbox | `Agent/AgentInboxView.swift`, `ContentView.swift`, `ContentView+Helpers.swift`, `PineAppMenuCommands.swift`; #1735/#1761 | Preserve unread/questions, routing and announcements; no cross-project dashboard resurrection |
| Choose environment / Worktree Manager | Contextual task details; remove manager | `Agent/AgentWorktreesView.swift`, `ContentView+Helpers.swift`; #1723/#1728/#1735 | Keep validated ownership, branches/worktrees/records and manual recovery; no duplicate creation |
| Interrupted by process exit / Notifications | Remove category in this candidate; no agent notification fires at all until the first verified-accuracy adapter (#1753/#1754) | `Agent/AgentNotificationModels.swift`, controller/settings | Ignore obsolete key; keep all lifecycle/history evidence; actionable-event tests exercise the resolver via injected verified accuracy and stay the reachability contract |
| Edit or inspect source / file tree, editor status bar | Remove built-in code viewing/editing, file tree and editor status bar | `CodeEditorView.swift`, `PaneLeafView.swift`, `ContentView.swift`, `StatusBarView.swift`; #1735/#1756 | **Blocked on explicit unsaved-work migration/export**, including missing paths and dirty buffers; never simply delete tabs |
| Inspect code / minimap, blame, folding, symbol picker | Remove dedicated implementations, UI, commands and preferences | `MinimapView.swift`, `GitBlameInfo.swift`, `FoldState.swift`, `SymbolNavigatorView.swift`; #1760/#1735 | Ignore obsolete state without content edits; retain shared Git/rendering used by independent consumers |
| Find source / Quick Open, project search, in-file find, Go to Line | Remove dedicated controls and shortcuts | `QuickOpenView.swift`, `SearchResultsView.swift`, `GoToLineView.swift`, menu/overlay routing; #1760/#1735 | Do not repurpose customized shortcuts; preserve source-location positioning while independently consumed |
| Code intelligence / LSP, diagnostics | Remove LSP and LSP-only Problems paths | `LSP/`, `LSP/ProblemsPanelView.swift`; #1760/#1735 | Preserve project/user server configuration; audit shared diagnostics before deletion; reconcile obsolete release gates |
| Validate or format on save | Remove built-in validators and format-on-save | `ConfigValidator.swift`, `Tabs/TabPersistence.swift`, formatter infrastructure; #1757/#1754 | Ordinary save unchanged; keep tool/project configs, no auto-import execution; content-changing commands invalidate evidence |
| Arrange tools / arbitrary pane grid | Remove free-form layout composition | `PaneManager.swift`, `PaneTreeView.swift`; #1735/#1756 | Preserve open/dirty documents, session references and ownership; switching a visible tool never stops a process |
| Execute commands / embedded terminal, global Quick Terminal | Remove emulator UI, global hotkey and dedicated settings | `TerminalContentView.swift`, `QuickTerminal/`, `Settings/TerminalSettingsView.swift`; #1735/#1754/#1757 | **Blocked on live-session handling and replacement command interaction**; retain owned execution, cancellation, bounded output and explicit TTY limitations |
| Choose branch / branch switcher | Remove picker and title/menu controls; branch identity contextual | `BranchSwitcherView.swift`, `StatusBarView.swift`, `ContentView.swift`; #1723/#1753/#1735 | Keep Git/environment primitives; detect external branch changes and invalidate stale evidence |
| Compose projects / permanent project switcher | Remove multi-project composition; one current project | `ProjectSwitcherView.swift`, `ProjectWindowSession.swift`; #1735/#1756 | Preserve each project's history/draft and deliberate running-work transitions; independent-window policy remains undecided |
| Configure shortcuts / Pine remapping | Remove Pine-specific loading/UI/override dispatch | `Extensibility/UserKeybinding*.swift`, `Settings/KeyBindingsTasksSettingsView.swift`; #1760 | Keep config files and explain obsolescence, standard shortcuts/VoiceOver; no silent reassignment |
| Reuse commands / legacy tasks.json menu | Remove legacy mechanism after deliberate import path exists | `Extensibility/`, Tasks menu; #1757/#1754 | Preserve tasks.json and exact semantics; never auto-execute imports; keep shared runner/process primitives |
| Start project / Welcome | Remove standalone destination after recovery/selection replacement | `WelcomeView.swift`, `PineApp.swift`; #1735/#1756 | Restore last project or usable folder selection; cancellation/missing paths recover; preserve AppKit window fallback |
| Open another project / recent-project list | Keep in Open Project, not a permanent switcher | `PineAppMenuCommands.swift`; #1735/#1756 | Missing-path recovery and preservation of drafts/history/running work |
| Read documentation/results / Markdown | Keep rendered documents; source editing is not thereby retained | `MarkdownPreviewView.swift`; #1758/#1735 | Keep document code-block rendering where needed; no arbitrary split/editor requirement |
| Request or literal command / new task input | Keep both, one input with explicit mode | #1735/#1749/#1754/#1757 | No syntax inference or silent shell rewriting; visible mode, keyboard/VoiceOver, environment binding, stop/output/errors |
| Try, compare, refine / result/evidence/brief/feedback | Keep result primary; contextual disclosures, not peer dashboards | `Agent/AgentCompletionBriefView.swift`, #1753–#1759/#1735 | Exact revision/evidence identity; try requires action/authorization; opening is not acceptance/execution |
| Choose execution capability / provider settings | Contextual How to run; preserve real differences/recovery | `Agent/AgentHandoffSettingsView.swift`; #1765 | Do not invent universal model/account/effort support; saved-history compatibility for Empryo retirement #1766 |
| Read UI / languages, accessibility | Keep all nine locales and native accessibility | `Localizable.xcstrings`, `Pine.help/`; all surface owners | Retire only owned obsolete strings, retain navigation/VoiceOver/Reduce Motion verification |
| Update app / automatic updates | Keep capability and preferences | `CheckForUpdatesView.swift`, `PineApp.swift`; existing update owner | No distribution, release automation, channel or signing changes authorized |
| Return after interruption / restoration | Keep and verify; no automatic execution | `SessionState.swift`, `ProjectRegistry.swift`; #1756/#1761 | Normal/crash/corrupt/moved-path recovery, drafts/modes, no resubmit/replay, stale evidence; legacy work export |
| Close window while working / background tasks | Keep while app runs | `ProjectRegistry.swift`, process owners; #1749/#1756/#1761 | Window close ≠ cancel ≠ Quit; audit retention, reopening, questions, stop access and durability |
| Speculative handoff/fan-out/mods/fleet panels | Defer absent validated core need | #1759/#1762 | No new release gate or permanent dashboard inferred from proposals |

## Integration and verification boundaries

- Result/input owners (#1735, #1749, #1753–#1758) own replacement composition,
  not this subtraction patch. No result/input models or execution primitives
  are changed here.
- Shared files with capability/settings owners: `Agent/AgentHandoffSettingsView.swift`,
  `Strings.swift`, `Localizable.xcstrings`. Public-copy owner #1730 also touches
  README, landing catalogs/HTML and all Help locales; combine only the changed
  process-notification sentences, not whole files.
- No usage-frequency or measured simplicity advantage is claimed from source
  existence. #1762 still needs comparative task/recovery evidence; #1761 owns
  end-to-end native acceptance. Removing one notification category and one
  setting is not completion of #1760.
- Local verification (2026-11-16, macOS 27.2.1/26B131, Xcode 27.2/27B52,
  SDK 27.2/26B118, SwiftLint 0.65.1): SwiftLint 0 violations (951 files);
  full scheme-Pine build succeeded; focused run of
  `AgentNotificationTests` + `AgentDetectionCoordinatorTests` +
  `AgentTaskLifecycleEvidenceTests` + `AgentNotificationPresentationTests`
  passed 145/145. Full `PineTests`: 1308 tests in 451 suites with 15 issues
  (2 pre-existing known issues; 13 failures, none in this diff's files except
  one `AgentNotificationTests` retry test that passed in the focused run).
  Under the swarm's machine load (250–410, up to 7 concurrent Pine test
  apps), the failures were 60 s/15 s/5 s/3 s timeout patterns across
  `AgentAdapterRegistryTests`, `UserTaskArgvRunnerTests`,
  `AgentVerificationIdentityTests`, `TerminalPTYProcessTreeTests`,
  window/LSP/worktree lifecycle suites. Equivalent-condition base run
  (temp worktree `…/T/opencode/pine-1760-base` at `5cd4707b`, separate
  derived data) failed the same `AgentWorktreeManagerModelTests`
  "Every initialized submodule…" test with the identical assertion — a
  host-locale (ru-RU) failure, pre-existing on base. A candidate-only rerun
  of the 11 affected types left the locale failure plus 5 non-deterministic
  PTY-fixture timeouts (a different PTY test set than the full run). A
  quiet-window candidate-vs-base PTY comparison was started and cancelled
  under a maintainer pause before executing. `PineUITests` not run locally
  by rule (CI runs the UI shards). Pending on a free machine: one clean full
  `PineTests` rerun; the known locale failure and the 2 known issues are
  expected to remain. No provider calls or process lifecycle suites are
  needed merely to inspect this candidate.
