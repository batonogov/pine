---
paths:
  - "Pine/**/*.swift"
  - "PineTests/**/*.swift"
---

# Concurrency, debounce, and reentrancy

`CLAUDE.md` carries the rules that must hold before you open a file. This is
the detail behind them.

Pine uses GCD for background work, bridged to async/await via `withCheckedContinuation` at API boundaries.

**Threading rules:**
- All UI updates on main thread (SwiftUI observation + `DispatchQueue.main.async`)
- CPU-intensive work dispatched to background: syntax highlighting (`com.pine.syntax-highlight` serial queue), git operations (`DispatchQueue.global` with `DispatchGroup` for parallel branch/status/branches), project search (`TaskGroup` with sliding-window concurrency), file tree loading (`DispatchQueue.global`)
- **Never block main thread** with file I/O, regex computation, or git process execution
- Generation tokens (`HighlightGeneration`, `WorkspaceManager.loadGeneration`, `FileSystemWatcher.activeGeneration`) prevent stale async results from overwriting newer ones — always check generation before applying results
- **Background work owns its autorelease pool** (#1509). A `DispatchQueue.global()` work item runs with no pool in place, so every autoreleased Foundation/AppKit temporary it produces is parked in libobjc's thread-wide fallback pool and stays alive until the worker thread is destroyed. `runOnBackground` (`Pine/Concurrency/BackgroundDispatch.swift`) wraps its body in `autoreleasepool` on both the success and the error path — prefer it over a raw `DispatchQueue.global().async`, and wrap the body yourself where a raw dispatch is unavoidable. Verify with `OBJC_DEBUG_MISSING_POOLS=YES`: "autoreleased with no pool in place" lines are the regression signal

**Debounce values** (centralised in `UITimings.Debounce` / `UITimings.Render`):
- Syntax highlight on edit: 100ms (`Debounce.edit`)
- Syntax highlight on scroll: 50ms (`Debounce.scroll`)
- Fold range recalculation: 150ms (`Debounce.foldRecalc`)
- Project search: 300ms (`Debounce.projectSearch`)
- File system watcher: 150ms (`Debounce.fileWatcher`, `WorkspaceManager.watcherDebounce`)
- Config validator (yamllint / shellcheck / hadolint / terraform validate): 300ms (`Debounce.configValidation`, `ConfigValidator.debounceInterval`)
- Minimap redraw: 25ms with trailing coalesce (`Render.minimapRedraw`)

**Performance thresholds:**
- Viewport-only highlighting: files > 50 000 characters (`viewportHighlightThreshold`; lowered from 100KB in #637)
- Large file dialog (disable highlighting?): files > 1MB (`largeFileThreshold`)
- Partial load (first 1MB only): files > 10MB (`hugeFileThreshold`)
- Project search skips files > 1MB
- Target: <4ms main thread work per scroll frame for 120Hz ProMotion

**Reentrancy / exclusivity:**

- **Reentrancy / exclusivity** — never post a `NotificationCenter` notification inside a function that holds an `inout` (e.g. `tabs: inout [EditorTab]`) exclusive access. `NotificationCenter.post` delivers observers synchronously on the main queue; an observer that writes the same store re-enters the live access and Swift aborts the process (`_swift_reportExclusivityConflict`, Pine #1066 and the #1047/#1051/#1056/#1058 family). Safe pattern: RETURN the payload (e.g. `SaveOutcome.reload` / `ReloadedTab`) and let the caller post AFTER the `inout` scope ends — see `TabExternalChangeDetector.reloadTab` and `TabPersistence.saveTabContent`. For `.onReceive` / `@objc` observers, defer `@State`/`@Observable` mutations to the next runloop via `DispatchQueue.main.async`. The `check-no-post-under-inout.py` guard enforces the `inout`-post sub-pattern at pre-commit and CI; if you legitimately defer a post inside an `inout` function, mark the line `// reentrancy-safe`
