# Pine — Risk Audit

**Date:** 2026-06-15  
**Scope:** Read-only inspection of concurrency, known-issue workarounds, performance thresholds, external tools, session persistence, tooling, test coverage, dependencies, and release pipeline.  
**Method:** Static analysis of source files, CI/release workflows, and Package.resolved. No files were modified.

---

## Summary

Pine is a mature, well-tested codebase (209 unit test files, 30 UI test files, comprehensive CI). The concurrency model is thoughtful — generation tokens, atomic apply patterns, and structured concurrency are used consistently. The risks below are primarily **fragility** risks (workarounds for macOS 26 bugs, `nonisolated(unsafe)` patterns, private API access) rather than active bugs. The most actionable items are the main-thread-blocking `runGit` calls, the format-on-save stall window, and the documentation/code threshold mismatch.

---

## High Severity

### H1. Synchronous `runGit` calls on the main thread

**Files:**
- `Pine/GitStatusProvider.swift:209` — `runSingleRefresh()` calls `Self.runGit(["rev-parse", "--show-toplevel"], at: url)` synchronously on the MainActor
- `Pine/GitStatusProvider.swift:276–285` — `diffForFile(at:)` calls `Self.runGit` twice synchronously (HEAD check + diff)
- `Pine/GitStatusProvider.swift:40–47` — `setup(repositoryURL:)` runs git detection + `fetchAllInParallel` synchronously

**Why it matters:** `GitCommand.run` spawns a `Process` and blocks until exit. On the MainActor this stalls the UI. The <4ms/scroll-frame target is violated for any project where `git rev-parse` or `git diff` takes >4ms (large repos, network-mounted filesystems, FileVault-on HDD). `diffForFile(at:)` and `setup(repositoryURL:)` are public API — any new call site can reintroduce a main-thread stall. The async variants (`diffForFileAsync`, `setupAsync`) exist and are used by `PaneLeafView`, but the sync versions remain callable.

### H2. Format-on-save blocks the main thread up to 5 seconds

**File:** `Pine/ExternalFileFormatter.swift:206–218`

```swift
let group = DispatchGroup()
group.enter()
DispatchQueue.global(qos: .userInitiated).async {
    result = self.processRunner(...)
    group.leave()
}
group.wait()  // <-- blocks calling (main) thread
```

**Why it matters:** `ExternalFileFormatter.format()` is called from `TabPersistence.saveTabContent` which runs on the MainActor. The `DispatchGroup.wait()` blocks the main thread for the entire process duration (default timeout: 5s). If `terraform`, `tofmt`, `shfmt`, or `prettier` is slow (large file, cold cache, NFS), the UI freezes for up to 5 seconds per save. The comment says "blocks it briefly" but 5s is not brief.

### H3. Sparkle version mismatch between dependency and release tooling

**Files:**
- `Package.resolved` — Sparkle **2.9.3** (revision `d46d456107fe`)
- `.github/workflows/release.yml:100` — downloads Sparkle **2.9.0** tools for `sign_update`

**Why it matters:** The runtime framework (2.9.3) and the signing tool (2.9.0) are different minor versions. While EdDSA signing is stable across Sparkle 2.x, this mismatch could cause issues if a future 2.9.x update changes the signature format or if the app's Sparkle framework uses update-checking behavior that differs from what the 2.9.0 signing tool expects. The fix is trivial: align `SPARKLE_VERSION` in release.yml with the Package.resolved pin.

### H4. UI test shard imbalance exceeds ±3 target

**Evidence (test counts via `grep -r "func test"`):**

| Shard | CI comment claims | Actual count |
|-------|-------------------|-------------|
| Terminal | 28 | **30** (20+4+6) |
| Welcome & Session | 25 | 25 |
| Navigation | 23 | 23 |
| Editor Chrome | 24 | 24 |
| Files & Save | 27 | 27 |
| Search & Panes | 24 | 24 |
| Security & Layout | 24 | 24 |

**Actual delta: 30 − 23 = 7** (exceeds the ±3 requirement documented in `.github/workflows/ci.yml`). The `verify-ui-shards` job only checks that all test classes are assigned to a shard — it does **not** verify balance. Shard 1 (Terminal) is the bottleneck: it takes 30/24 = 1.25× longer than the median shard, increasing CI wall-clock time.

---

## Medium Severity

### M1. `nonisolated(unsafe)` mutable variables in process execution

**File:** `Pine/ExternalFileFormatter.swift:63, 80–81`

```swift
nonisolated(unsafe) var timedOutValue = false    // protected by NSLock
nonisolated(unsafe) var outData = Data()          // written from one GCD block
nonisolated(unsafe) var errData = Data()          // written from another GCD block
```

**Why it matters:** These are technically safe: `timedOutValue` uses `NSLock`, and `outData`/`errData` each have a single writer with `readGroup.wait()` providing happens-before ordering. However, `nonisolated(unsafe)` opts out of Swift 6's compile-time checking — any future refactoring (e.g., adding a third pipe reader, or removing the `readGroup.wait()`) silently introduces a data race with no compiler diagnostic.

### M2. `DispatchQueue.main.sync` in async highlight bridge

**File:** `Pine/Syntax/SyntaxHighlightAsync.swift:298, 315`

```swift
if Thread.isMainThread {
    box.engine.applyMatches(...)
} else {
    DispatchQueue.main.sync {     // synchronous hop to main
        box.engine.applyMatches(...)
    }
}
```

**Why it matters:** This is called from `highlightQueue.addOperation` (a background OperationQueue), so it correctly blocks a background thread on main. No deadlock occurs because the caller is an OperationQueue thread, not the main thread itself. However, `DispatchQueue.main.sync` from a background thread is an anti-pattern — it blocks a cooperative-threading thread pool slot while waiting for the main run loop. If the main thread is busy (e.g., processing a scroll event), this adds latency to highlight application. Using `DispatchQueue.main.async` with a completion handler or `MainActor.run` in the async entry point would be less blocking.

### M3. Six `NSEvent.addLocalMonitorForEvents` keyboard interceptors

**File:** `Pine/PineApp.swift:133–194` (inside `applicationDidFinishLaunching`)

Six monitors intercept: Cmd+W, Cmd+F (terminal), Cmd+Shift+B, Ctrl+Tab/Ctrl+Shift+Tab, Cmd+1..9.

**Why it matters:**
- These bypass SwiftUI's `.keyboardShortcut` system, so they are **invisible to XCUITest's `typeKey()`** (documented known issue in CLAUDE.md). Keyboard shortcuts relying on these monitors cannot be UI-tested.
- Each monitor receives **every** keyDown event app-wide — the per-event overhead is small but cumulative.
- If Apple fixes the underlying SwiftUI keyboardShortcut limitations (e.g., Tab key support, menu-item ordering), these monitors become dead code that shadows the fixed SwiftUI path.

### M4. AppKit window-creation fallback for macOS 26 LaunchServices bypass

**File:** `Pine/PineApp.swift:~401–427` (`createWelcomeWindowViaAppKit`, `ensureWelcomeVisible`)

**Why it matters:** Creates a Welcome window via `NSHostingController` + `NSWindow` when SwiftUI's `Window` scene fails to instantiate on macOS 26. The fallback:
- Hardcodes window size (600×400) and style mask — must be kept in sync with the SwiftUI `Window` declaration.
- Instantiates `WelcomeView` a second time, creating a second `ProjectRegistry` reference path.
- Uses a 0.5s `DispatchQueue.main.asyncAfter` delay — if SwiftUI's window appears between 0ms and 500ms, there's a brief double-window flash.

This is inherently fragile: it's a workaround for a platform bug. If the bug is fixed in a macOS update, the fallback code silently activates and creates duplicate windows.

### M5. `viewportHighlightThreshold` documentation/code mismatch

**Files:**
- `Pine/CodeEditorView.swift:73` — `static let viewportHighlightThreshold = 50_000` (chars)
- `CLAUDE.md` — "Viewport-only highlighting: files > 100KB"

**Why it matters:** The threshold is 50,000 **characters** (≈50KB for ASCII, more for multibyte), not 100KB as documented. This makes it harder for contributors to reason about performance behavior from the docs. The 50K value is actually more conservative than documented — viewport highlighting kicks in earlier.

### M6. SwiftTerm private/internal API access

**File:** `Pine/TerminalSession.swift`

The code accesses SwiftTerm internals that are not part of the stable public API:
- `terminalView.process.childfd` (line ~430, ~445) — raw PTY file descriptor
- `terminalView.process.running` (line ~440)
- `terminalView.process.shellPid` (line ~445)
- `terminalView.process.send(data:)` (line ~475)

**Why it matters:** SwiftTerm 1.13.0 exposes these as `public` but they are implementation details, not API contract. A SwiftTerm update (or even a patch release) could rename, restructure, or remove `LocalProcessTerminalView.process`, breaking Pine's terminal features (foreground-process detection, SIGWINCH, send-text) with no compile error (if the property type changes) or a cryptic runtime crash.

### M7. `check_nonisolated.py` documented false negatives

**File:** `.github/scripts/check_nonisolated.py` (docstring lines 1–50)

The script explicitly documents that it **cannot** detect:
- `DispatchWorkItem { ... }` captures without `.global()` on the same line
- `Thread { ... }.start()` and manual thread APIs
- Queues injected via dependency injection
- Background queues in `/* block comments */` or triple-quoted strings
- Free functions (no enclosing type)

**Why it matters:** The script prevents the most common crash pattern (`@MainActor` type scheduling work on `DispatchQueue.global()`), but a developer could inadvertently introduce a new concurrency bug via any of the undetected patterns. The `nonisolated-check:ignore` comments (4 instances, tracked in issue #720) are manual overrides that bypass even the basic check.

---

## Low Severity

### L1. Session persistence: terminal scrollback lost on restore

**File:** `CLAUDE.md` (documented), `Pine/SessionState.swift:72–77`

Terminal pane tab counts and active indices are persisted, but terminal processes are recreated fresh on restore. Scrollback history, CWD, and any running foreground processes are lost.

**Why it matters:** This is documented and intentional (PTY state cannot be serialized). But users who rely on Pine as their daily terminal may lose context after an app restart. Session restore creates new shell processes in the project root, not the last CWD.

### L2. SessionState pane layout serialized as `Data?`

**File:** `Pine/SessionState.swift:54` — `var paneLayoutData: Data?`

The pane tree is encoded as JSON `Data` using `PaneNode`'s custom `Codable`. Any change to `PaneNode`'s `CodingKeys` or `NodeType` enum will break decoding of old sessions. The `load(for:)` method catches decode errors and falls back to `loadLegacy`, but a partial decode change (e.g., adding a new `PaneContent` case) could silently produce a default layout instead of restoring the saved one.

**Why it matters:** Low probability — the Codable implementation is stable and uses explicit string keys. But there's no version field inside the pane layout JSON itself (the outer `SessionState` doesn't version this blob independently of `MigrationManager.schemaVersionKey`).

### L3. `MigrationManager` at version 1 with only one migration

**File:** `Pine/MigrationManager.swift:86–104`

The only migration (v0→v1) cleans stale recent projects. If a future change adds a new UserDefaults key that needs migration, the developer must remember to both bump `latestVersion` and register a new migration. The `assert(latestVersion == lastMigration.to)` guard catches this at debug runtime, but not in release builds.

### L4. SwiftLint disables complexity and length checks

**File:** `.swiftlint.yml`

Disabled rules: `cyclomatic_complexity`, `function_body_length`, `type_body_length`, `file_length`.

**Why it matters:** `CodeEditorView+Coordinator.swift` is 1100+ lines with methods exceeding 100 lines. Without complexity guards, deeply nested methods can accumulate undetected. This is a style/maintainability risk, not a correctness risk.

### L5. `ExternalToolResolver` caches tool paths for resolver lifetime

**File:** `Pine/ExternalToolResolver.swift:60–90`

Tool resolution results are cached per `ExternalToolResolver` instance. If a user installs `terraform` or `shfmt` while Pine is running, the formatter won't find it until Pine is restarted (because the formatter holds a resolver created at init time with `toolPath: nil`).

**Why it matters:** Low impact — installing a formatter tool while the editor is open is rare. But a user who installs `terraform` and then enables format-on-save without restarting will be confused that formatting doesn't work.

### L6. `PBXFileSystemSynchronizedRootGroup` — resource files still need manual adds

**File:** `Pine.xcodeproj/project.pbxproj` (objectVersion 77)

`.swift` files in `Pine/`, `PineTests/`, `PineUITests/` are auto-discovered. But non-Swift resources (JSON grammars, asset catalogs, Info.plist) and build-phase scripts (SwiftLint build phase) still require manual `project.pbxproj` edits. CLAUDE.md states "No manual project.pbxproj edits needed" which is true for `.swift` files only.

### L7. Release secrets surface is large

**File:** `.github/workflows/release.yml`

Required secrets: `CERTIFICATE_P12`, `CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_ID_PASSWORD`, `APPLE_TEAM_ID`, `TAP_GITHUB_TOKEN`, `SPARKLE_PRIVATE_KEY`, `RELEASE_PLEASE_TOKEN`.

**Why it matters:** 8 secrets is a broad attack surface. `APPLE_ID_PASSWORD` (app-specific password) and `CERTIFICATE_P12` + `CERTIFICATE_PASSWORD` (Developer ID signing identity) are particularly sensitive — compromise allows malicious notarized app distribution. Actions are pinned by SHA (good), but the keychain is created on the runner with `openssl rand -hex 20` and deleted in `if: always()` cleanup (good). The risk is in secret management at the GitHub/org level, not in the workflow itself.

---

## Cross-Cutting Observations

### Generation Token Correctness ✅

Generation tokens are used correctly and consistently:
- **`HighlightGeneration`** (`Pine/Syntax/SyntaxHighlightEngine.swift:11–25`): NSLock-protected counter, checked before applying results in all three async paths (full, incremental, viewport).
- **`WorkspaceManager.loadGeneration`**: Bumped on every `loadDirectory`/`refreshFileTree`/`refreshFileTreeAsync`, checked in every `MainActor.run` block.
- **`FileSystemWatcher.activeGeneration`**: Bumped in `stopOnQueue()`, checked via `isActive(generation:)` in the debounced callback.
- **`ProjectSearchProvider.searchTask?.cancel()`**: Task cancellation is used instead of a numeric token — equally valid for structured concurrency.

No missing generation checks were found.

### ProjectSearchProvider TaskGroup Sliding Window ✅

`Pine/ProjectSearchProvider.swift:120–170` — The sliding-window concurrency pattern correctly:
- Seeds `maxConcurrency` initial tasks
- Feeds new tasks one-for-one as results arrive
- Checks `Task.isCancelled` at every yield point
- Breaks early when `totalMatches >= maxResults`
- Sorts results deterministically after collection

### Action Pinning ✅

All third-party GitHub Actions are pinned by full commit SHA with version comments (e.g., `actions/checkout@de0fac2e...# v6`). This is supply-chain best practice.

### `runOnBackground` Bridge ✅

`Pine/Concurrency/BackgroundDispatch.swift` — The `withCheckedContinuation` + `DispatchQueue.global` bridge is used correctly with `@Sendable` closures. It replaces the boilerplate that previously caused GCD/cooperative-threading starvation (issue #837).

---

## Recommended Follow-Ups

1. **Deprecate or make internal** the sync `diffForFile(at:)` and `setup(repositoryURL:)` methods in `GitStatusProvider` — they are footguns for main-thread blocking. (H1)
2. **Move format-on-save** to an async/await path that doesn't block the main thread (e.g., `Task.detached` + `await MainActor.run` for the result application). (H2)
3. **Align Sparkle version** in release.yml with Package.resolved. (H3)
4. **Rebalance UI test shards** — move 2–3 tests from Shard 1 (Terminal) to Shard 3 (Navigation) or Shard 4 (Editor Chrome). Add a balance check to `verify-ui-shards`. (H4)
5. **Update CLAUDE.md** `viewportHighlightThreshold` from "100KB" to "50,000 characters". (M5)
6. **Pin Sparkle, SwiftTerm, and swift-markdown** with version comments in the `Package.resolved` or a dependency manifest so version updates are deliberate, not accidental `xcodebuild` auto-updates.
