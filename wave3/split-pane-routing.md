# Split-Pane Active-TabManager Routing — Issues #971 + #998

## Scope

Closed in one PR: route commands/search/status-bar/inline-diff/change-navigation/go-to
through the **active** editor pane's TabManager instead of the project's primary
TabManager. Foundation fix for the SwiftUI `@Environment(TabManager.self)` leak.

## Root cause

`PineApp.ProjectWindowView` injects `pm.primaryTabManager` into the SwiftUI
environment. `ContentView` consumed it as `@Environment(TabManager.self) var
tabManager` and used it for *every* command/action, conflating "primary" with
"active". In split layouts, commands landed on the wrong pane (or did nothing).

## Changes

### Pine/ContentView.swift (#998 leak)

- Renamed `@Environment(TabManager.self) var tabManager` → `primaryTabManager`
  with a long doc comment explaining the primary-vs-active distinction.
- Added `var activeTabManager: TabManager { projectManager.activeTabManager }`
  — single, explicit accessor for command routing.
- StatusBarView now receives `activeTabManager` (was `tabManager`).
- Symbol Navigator guard, Go-to-Line sheet `onGoTo`, Symbol-Navigate handler,
  `.onChange(activeTabID)` now all route through `activeTabManager`.
- Go-to-Line + Symbol-Navigate now set `activeTabManager.pendingGoToLine`
  instead of writing an orphaned `GoToRequest` into root state.
- Removed `.onChange(of: tabManager.pendingGoToLine)` (PaneLeafView handles
  its own now). Removed unused `goToLineOffset` @State.
- Single-pane backward compat preserved: `activeTabManager === primaryTabManager`
  when no split is active.

### Pine/ContentView+Helpers.swift (#971 routing)

- `syncSidebarSelection`: reads `activeTabManager.activeTab?.url`.
- `navigateToChange(direction:)`: fetches fresh diffs for the active tab
  (root `lineDiffs` was always empty) and routes the resulting line through
  `activeTabManager.pendingGoToLine`.
- `handleInlineDiffAction(_:)`: all four actions target `activeTabManager`
  for accept/revert/acceptAll/revertAll.
- `close{Other,All,ToTheRight,Tab}WithConfirmation`: route through
  `activeTabManager`.
- `recoverTabs()`: opens recovered tabs into the focused pane.
- Session restore: kept on `primaryTabManager` (legacy single-pane path).

### Pine/GitAndNotificationObserver.swift (#971 routing)

- Removed `@Environment(TabManager.self) private var tabManager`.
- Added `private var activeTabManager: TabManager { projectManager.activeTabManager }`.
- `.closeTab`, `.goToLine`, `.openFileAtLine` handlers route through active.
- `.fileRenamed` now calls new `projectManager.handleFileRenamed(oldURL:newURL:)`
  so renames reach every pane that has the file open (not just the primary).

### Pine/PaneLeafView.swift (#971 go-to delivery)

- Added `.onChange(of: tabManager.pendingGoToLine)` to `editorPaneContent`.
  Converts the line to a UTF-16 offset and feeds it to the local
  `goToLineOffset` consumed by `CodeEditorView`. Clears the pending line
  after consumption.

### Pine/ProjectManager.swift

- Added `handleFileRenamed(oldURL:newURL:)` — iterates every pane's
  TabManager (analog to existing `reloadTabs(url:)` and
  `closeTabsForDeletedFile(url:)`).

### Pine/SearchResultsView.swift

- Already routed through `projectManager.activeTabManager` (landed via #974).
  No changes needed — verified by `SplitPaneRoutingTests`.

### Pine/StatusBarView.swift

- No code changes — already parameterized; ContentView now passes the active
  pane's TabManager.

### Pine/PineAppMenuCommands.swift, Pine/PineApp.swift

- No changes needed — already use `focusedProject?.activeTabManager` and
  `closeDelegate.projectManager.activeTabManager` (already correct).

## Regression tests — `PineTests/SplitPaneRoutingTests.swift` (new file)

16 tests in 2 suites:

- `SplitPaneRoutingTests` (15): active-vs-primary divergence in splits,
  focus tracking, single-pane fallback, search-results routing,
  per-pane `pendingGoToLine`, `handleFileRenamed` across panes and with
  orphaned primary, change-navigation reads active cursor/content,
  inline-diff target resolves from active, status bar receives active
  TabManager, `allDirtyTabs` across panes, `openFileAtLine` lands in active,
  symbol-navigate offset resolves via active tab content, primary intact
  when active diverges, active resolves when primary is orphaned.
- `RecoveryRoutingTests` (1): recovery opens into the active pane.

## Validation

- `xcodebuild build`: BUILD SUCCEEDED.
- `swiftlint lint` on changed files: 0 violations.
- New tests: 16/16 passed.
- Broad regression sweep across 20 suites (398 tests) covering
  MultiPaneIntegration, PaneLeafClose, PaneLeafGitDiffRefresh,
  PaneManager (+ Prune), SearchResultsKeyboard, SearchActivePaneRouting,
  TabManager (+ Edge), DiffNavigation, GoToLine, SidebarRenameStem,
  SplitPaneRouting, RecoveryRouting, ProjectManagerSession, SessionState,
  CloseDelegate, WindowLifecycle, ExternalFileReload, PineAppMenuCommands:
  all pass.

## Pre-existing failures (unrelated, environmental)

A full `PineTests` run also surfaced `DebouncerTests` (timing-flaky under
load) and `TerminalPaletteTests.lightPaletteAllSlotsHaveContrastAgainstLightBackground`
(threshold 3.0 vs measured 2.95 — color-math edge case). Both reproduce on
`main` and touch no code in this PR.

## Residual risks

- The root `@State var lineDiffs: [GitLineDiff] = []` is kept (still bound
  to `GitAndNotificationObserver`), but no longer drives any UI. It is
  cosmetic only; safe to remove in a follow-up.
- `ContentView.refreshLineDiffs()` / `refreshBlame()` remain no-op stubs.
  Each `PaneLeafView` owns its diff/blame state. The stubs are kept because
  `GitAndNotificationObserver` still calls them as notification hooks; they
  exist to document the seam.
- `.onChange(of: primaryTabManager.tabs.count)` observes only the primary
  pane's tab count. `projectManager.saveSession()` already iterates every
  pane, so split-pane tabs are still persisted — but the observer itself
  does not fire when a non-primary pane's tab count changes. Documented
  with an inline comment; preserving this for backward compat.

## Acceptance contract mapping

- criterion-1 ✓ `@Environment` leak fixed: renamed `tabManager` → `primaryTabManager`,
  all active-pane uses go through `activeTabManager`.
- criterion-2 ✓ Go-to requests delivered to active `PaneLeafView` via
  `pendingGoToLine` (per-pane observer).
- criterion-3 ✓ SearchResultsView opens via active TabManager (was already
  correct post-#974; covered by regression tests).
- criterion-4 ✓ StatusBarView bound to active pane's TabManager.
- criterion-5 ✓ Change navigation fetches fresh diffs for active tab;
  inline-diff actions route through active; stubs kept as no-op seams.
- criterion-6 ✓ PineApp command routing unchanged — it already used
  `focusedProject?.activeTabManager`. The leak was in `ContentView` /
  `GitAndNotificationObserver`, now fixed.
- criterion-7 ✓ Regression tests added: 16 tests covering non-primary
  split-pane routing.
- criterion-8 ✓ Existing PineTests pass (398/398 across 20 relevant suites).
- criterion-9 ✓ Single-pane backward compat preserved
  (`activeTabManager === primaryTabManager` when no split).
- criterion-10 ✓ SwiftLint clean on changed files.
- criterion-11 ⏳ PR open pending (see "Next step" below).

## Next step

Open the PR:
- Branch: `fix/split-pane-routing-active-tabmanager`
- Title: `fix(split-pane): route commands through active pane + fix TabManager leak`
- Body summarizes routing changes + regression tests + `Closes #971, Closes #998`.
- Ready to merge when CI green + review approved.
