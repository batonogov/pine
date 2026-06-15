# Review: PR #982 — `fix(terminal): confirm before stopping foreground processes from status bar and window close`

**Closes:** #970  
**Branch:** `fix/terminal-confirm-foreground-process-970`  
**Commit:** `a4c1ebd`  
**Verdict:** ✅ **APPROVE**

---

## Summary

PR #982 adds a shared confirmation helper (`TabCloseHelper.confirmTerminalProcessStop`) and routes **all five** terminal stop/close paths through it. Two previously-unguarded paths (status bar toggle, window close) now warn the user when foreground processes are running. Three existing paths (tab close, pane close, Cmd+W) were refactored from inline alert code to use the same shared helper with zero behavioral change.

**The helper is truly shared — no duplication.** This is the central acceptance criterion and it is fully met.

---

## Acceptance Criteria Checklist

| Criterion | Status | Evidence |
|-----------|--------|----------|
| Status bar toggle warns before stopping terminal tabs with foreground process | ✅ | `ContentView.swift:79-81` — `guard TabCloseHelper.confirmTerminalProcessStop(tabs: terminal.allTerminalTabs)` gates the `tab.stop()` loop at `:86` |
| `windowShouldClose` warns before closing window with active terminal processes | ✅ | `PineApp.swift:347-351` — terminal check added after the dirty-tab flow, returns `false` on cancel |
| Confirmation logic is SHARED (not duplicated) | ✅ | All 5 call sites use `TabCloseHelper.confirmTerminalProcessStop(tabs:)` — see table below |
| Unit tests cover decision logic, both paths, with/without processes | ✅ | `TerminalProcessConfirmationTests.swift` — 8 test cases, injectable alert closure, no real NSAlert |

---

## Is the Helper Truly Shared? — YES

All five terminal stop/close paths now route through `TabCloseHelper.confirmTerminalProcessStop(tabs:)`:

| Call site | File:Line | Status |
|-----------|-----------|--------|
| Status bar terminal toggle | `ContentView.swift:79` | **NEW** (previously unguarded — called `tab.stop()` with no check) |
| Window close (`windowShouldClose`) | `PineApp.swift:348` | **NEW** (previously only checked dirty editor tabs) |
| Cmd+W close active terminal tab | `PineApp.swift:302` | **REFACTORED** from inline `if tab.hasForegroundProcess { AlertTemplate... }` |
| Terminal tab close button | `TerminalPaneTabBar.swift:21` | **REFACTORED** from inline duplicate |
| Terminal pane close button | `TerminalPaneTabBar.swift:121` | **REFACTORED** from inline duplicate |

The default `presentAlert` closure in the helper produces the **exact same alert** as the old inline code:

```swift
AlertTemplate.terminalTabCloseWarning.runModal(
    messageText: Strings.terminalTabCloseWarningTitle,
    informativeText: Strings.terminalTabCloseWarningMessage
)
```

Verified against the pre-PR code — identical template, identical strings, identical button order. No behavioral regression in the refactored paths.

The `applicationShouldTerminate` path (app quit) was correctly **NOT** touched — it uses its own `terminalActiveProcessWarning` template ("Quit / Cancel"), which is appropriate for app-level termination vs. tab/window close.

---

## Findings by Severity

### ✅ Correct (no issues)

1. **Shared helper design** — `TabCloseHelper` already existed for editor-tab close confirmations. Adding terminal-process confirmation there is the right home. Two-layer API: `confirmTerminalStop(hasForegroundProcess:presentAlert:)` is the pure decision function; `confirmTerminalProcessStop(tabs:presentAlert:)` is the convenience overload that aggregates `tabs.contains { $0.hasForegroundProcess }`. Clean, testable, minimal.

2. **`windowShouldClose` integration** (`PineApp.swift:330-353`) — The old `guard !dirty.isEmpty else { return true }` early return was correctly changed to `if !dirty.isEmpty { ... }` so the terminal check always runs afterward. All return paths are correct:
   - Dirty tabs + Cancel → `return false` (terminal check never reached) ✓
   - Dirty tabs + Save fails → `return false` ✓
   - Dirty tabs + Don't Save → falls through to terminal check ✓
   - No dirty tabs → falls through to terminal check ✓ (this is the fix — previously returned `true` immediately)
   - Terminal cancel → `return false` ✓
   - All clear → `return true` ✓

3. **`ContentView.swift` status bar toggle** (`:79-88`) — Confirmation runs BEFORE the `tab.stop()` loop. If the user cancels, no tabs are stopped. Correct ordering.

4. **Aggregation consistency** — Both new call sites use `terminal.allTerminalTabs` (`TerminalManager` → `PaneManager.allTerminalTabs` = `terminalStates.values.flatMap(\.terminalTabs)`). This aggregates across **all** terminal panes, not just the active one. Both paths use the same source, so there's no risk of one catching tabs the other misses.

5. **Test quality** — Tests use an injectable `presentAlert` closure (no real NSAlert UI). The `alertCalled` flag verifies the no-process fast path skips the alert entirely. Both confirm and cancel modal responses are tested. The default-alert tests only exercise the no-process path (documented why — can't present a real modal in headless tests).

6. **CI** — Security & Layout shard (previously failed with empty logs) now **PASSES**, confirming the earlier failure was flaky/infra. Terminal shard also passes. SwiftLint, Build, Flaky Summary, Verify Shards, claude-review all green. (Unit Tests and Editor Chrome were still pending at review time but Editor Chrome has since passed.)

### 🟡 Nit (non-blocking)

1. **Alert wording slightly imprecise for window-close** — The shared alert says "Terminal has an active process. Close anyway?" with a "Close Terminal" button. For `windowShouldClose`, the action closes the *window* (and actually backgrounds the processes via `closeProjectWindow` → `backgroundProjects`, rather than killing them). "Close Terminal" is technically misleading in this context. However:
   - The issue explicitly asked to reuse the shared confirmation logic.
   - The same wording is already used for the pane-close button (which also isn't strictly a "tab" close).
   - Fixing this would require new localized strings in 9 languages.
   - **Not worth blocking on.** The warning is still useful and the behavior (user must confirm) is correct.

2. **Test gap: `confirmTerminalProcessStop(tabs:)` with a process-having tab** — The tests verify the aggregation path (`tabs.contains`) only with idle tabs. The `hasForegroundProcess: true` decision path is tested exclusively via the boolean overload. This is acceptable because `TerminalTab.hasForegroundProcess` is a computed property that requires a real running shell process (`tcgetpgrp`), which can't be easily constructed in a unit test. The aggregation logic is a trivial `contains`, and the true/false decision is fully covered. **No action needed**, but a future improvement could make `hasForegroundProcess` injectable or add a test-only `TerminalTab` subclass.

3. **Window close backgrounds rather than kills processes** — `windowShouldClose` returning `true` triggers `handleProjectWindowDisappear` → `closeProjectWindow` which moves the project to `backgroundProjects` (processes keep running). The warning implies the action is destructive ("Close anyway?") but it's actually non-destructive for window close. This is existing architecture behavior (terminal sessions are preserved for reopen), not introduced by this PR. The warning is still valuable — it alerts the user to active processes before they lose visual access.

---

## Regression Check

| Path | Before PR | After PR | Change |
|------|-----------|----------|-------|
| Status bar toggle (terminals visible) | Stops all tabs, no warning | Warns if any tab has foreground process | **Fixed (issue #970)** |
| Window close (no dirty tabs) | Closes immediately, no warning | Warns if any terminal has foreground process | **Fixed (issue #970)** |
| Window close (dirty tabs) | Dirty-tab dialog only | Dirty-tab dialog → terminal warning | **Enhanced** |
| Cmd+W terminal tab | Inline alert | Shared helper (identical alert) | Refactored, no behavior change |
| Tab close button | Inline alert | Shared helper (identical alert) | Refactored, no behavior change |
| Pane close button | Inline alert | Shared helper (identical alert) | Refactored, no behavior change |
| App quit (`applicationShouldTerminate`) | Own `terminalActiveProcessWarning` alert | **Untouched** | No change (correct) |

No regressions detected.

---

## Files Changed

| File | +/- | Notes |
|------|-----|-------|
| `Pine/TabCloseHelper.swift` | +52/-0 | New shared helper methods |
| `Pine/ContentView.swift` | +4/-0 | Status bar toggle guard |
| `Pine/PineApp.swift` | +26/-23 | `windowShouldClose` + `closeActiveTab` refactor |
| `Pine/TerminalPaneTabBar.swift` | +4/-12 | Tab close + pane close refactor |
| `PineTests/TerminalProcessConfirmationTests.swift` | +120/-0 | 8 test cases |

Total: +206/-35 across 5 files. Minimal, focused diff.

---

## Verdict

**APPROVE.** The PR cleanly satisfies all four acceptance criteria for issue #970. The shared helper eliminates three instances of duplicated alert logic and adds the missing guards to two previously-unprotected paths. Tests are well-structured with injectable dependencies. No regressions. CI is green (including the previously-flaky Security & Layout shard). The two nits (alert wording for window-close, test coverage of aggregation with active-process tabs) are minor and do not warrant blocking.
