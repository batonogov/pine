# Review — PR #986: ux(navigation): replace document-modal sheets with lightweight command overlays

**Closes:** #975  
**Branch:** `ux/navigation-command-overlays-975`  
**Commit reviewed:** `3ef2c3c` (via `FETCH_HEAD`; local `main` at parent `65ab725`)  
**Verdict: REQUEST CHANGES** — one blocking issue (10 UI tests will fail in CI)

---

## Summary

The PR replaces `.sheet` presentations for Quick Open, Symbol Navigator, and Go to Line with a new `CommandOverlayView` — a SwiftUI `.overlay` with a translucent backdrop, click-to-dismiss, and Escape support. Go to Line's invalid-input feedback is upgraded from a red outline to a visible message + VoiceOver announcement. Snapshot baselines (light + dark) are committed. All 9 locales covered for 4 new strings.

The core UX change is well-executed. Keyboard behavior is **fully preserved** (detailed verdict below). The blocker is an oversight: existing UI tests that locate these views via `app.sheets` were not updated.

---

## Verdict on Keyboard Behavior: ✅ PRESERVED

This was the highest-risk concern. Verified from source:

1. **QuickOpenView / SymbolNavigatorView** — both use `QuickOpenSearchField` (`Pine/QuickOpenView.swift:163`), an `NSTextField`-based `NSViewRepresentable` that intercepts arrow keys / Return / Escape via `control(_:textView:doCommandBy:)` (`Pine/QuickOpenView.swift:228–251`). This is AppKit-level key dispatch that is **presentation-context-independent** — it works identically in a sheet window or a SwiftUI overlay in the main window. The field becomes first responder via `field.window?.makeFirstResponder(field)`; since the overlay lives in the main window, `field.window` is non-nil.

2. **GoToLineView** — SwiftUI `TextField` with `.onSubmit { submit() }` for Enter and `.onExitCommand { isPresented = false }` for Escape (`Pine/GoToLineView.swift:31, 44`). No arrow-key navigation needed (single field). Works in overlay context.

3. **Escape from overlay** — `CommandOverlayView` has `.onExitCommand { isPresented = false }` (`Pine/CommandOverlayView.swift:48–52`). When focus is inside the inner content, the innermost `onExitCommand` fires first; both inner and outer handlers set `isPresented = false`. Escape always dismisses.

4. **`.accessibilityAddTraits(.isModal)`** — this is a **VoiceOver-only** trait. It tells VoiceOver to trap navigation inside the element. It does **not** intercept or swallow keyboard events for non-VoiceOver users. Arrow keys, Enter, and Escape go to the first responder regardless. No risk here.

---

## Findings

### 🔴 BLOCKING

#### B1. Existing UI tests use `app.sheets.firstMatch` — all will fail after `.sheet` → `.overlay` change

`CommandOverlayView` is a SwiftUI `.overlay`, not an `NSPanel`/sheet. In the accessibility tree it appears as a regular view (with identifier `"commandOverlay"`), **not** as an `XCUIElement` sheet. `app.sheets.firstMatch` returns an empty query, `waitForExistence` times out, and every test fails.

**Affected files and tests (10 total, all in CI Shard 3 "Navigation"):**

`PineUITests/GoToLineTabOverflowExternalChangesUITests.swift` — the `openGoToLine()` helper at line 38–46:
```swift
let sheet = app.sheets.firstMatch
XCTAssertTrue(waitForExistence(sheet, timeout: 5), "Go to Line sheet should appear")
return sheet
```
Breaks: `testGoToLineOpensViaEditMenu`, `testGoToLineDismissesOnEscape`, `testGoToLineShowsLineRangeHint`, `testGoToLineAcceptsValidInput`, `testGoToLineRejectsInvalidInput` (5 tests).

`PineUITests/QuickOpenUITests.swift` — 5 occurrences of `app.sheets.firstMatch` (lines 47, 60, 85, 111, 152):
Breaks: `testQuickOpenOpensViaMenu`, `testQuickOpenDismissesOnEscape`, `testTypingFiltersResults`, `testClickOpensFile`, `testEmptyProjectShowsNoResults` (5 tests).

**Why this blocks:** CLAUDE.md states "All UI tests always run (no conditional skip)" and "Branch protection: requires all checks to pass." Shard 3 will go red.

**Fix:** The PR already added `AccessibilityID.commandOverlay = "commandOverlay"` to `CommandOverlayView`. Update the UI tests to locate the overlay via `app.otherElements["commandOverlay"]` instead of `app.sheets.firstMatch`. For Go to Line, the inner view retains `AccessibilityID.goToLineSheet` (`"goToLineSheet"`) as well. Example:

```swift
// Before
let sheet = app.sheets.firstMatch
XCTAssertTrue(waitForExistence(sheet, timeout: 5))

// After
let overlay = app.otherElements["commandOverlay"]
XCTAssertTrue(waitForExistence(overlay, timeout: 5))
```

---

### 🟡 SHOULD-FIX

#### S1. `CommandOverlayViewTests.swift` unit tests are near-no-op

`PineTests/CommandOverlayViewTests.swift`:

- **`backdropDismisses()` (line 23)** — constructs the view, then manually sets `binding.wrappedValue = false` and asserts the source changed. This tests `Binding` mechanics, not the overlay. The comment acknowledges "actual tap simulation requires UI testing." Low value but not harmful.
- **`localizedStringsResolve()` (line 66)** — calls `NSLocalizedString(...)` and asserts the result is non-empty. But `NSLocalizedString` returns the **key itself** when no translation is found, so a non-empty result does not prove the key exists in the catalog. This test cannot fail.
- **`invalidWhenExceedsTotal` / `validWhenInRange` (lines 49, 57)** — re-test `GoToLineParser`, already covered exhaustively in `PineTests/GoToLineTests.swift`. Redundant.

Consider replacing these with a `GoToLineView` rendering test that verifies `invalidEnteredLine` is set correctly when `submit()` receives an out-of-range input, or at minimum remove the misleading `localizedStringsResolve` test.

---

### 🔵 NIT

#### N1. Overlay is window-centered, not "anchored to editor"

Issue #975 says "anchored to editor." The `navigationOverlay` is applied to the entire `NavigationSplitView` (`Pine/ContentView.swift:94`) and content is centered via `ZStack` default `.center` alignment. This dims the sidebar too. This matches the standard command-palette pattern (VS Code Quick Open, Spotlight) and is arguably better UX, but it technically deviates from the literal issue wording. If strict editor-anchoring is desired, apply `.overlay` to `editorArea` instead.

#### N2. `AccessibilityID.goToLineSheet` retains "Sheet" name

`Pine/AccessibilityIdentifiers.swift:73` — the identifier value is still `"goToLineSheet"` despite now being an overlay. Renaming would break existing references (including the UI tests once updated per B1). Not worth changing; just noting the naming drift.

#### N3. Snapshot harness renders overlay over `Color.clear`, not a realistic editor backdrop

`NavigationOverlaySnapshotTests.OverlayHarness` uses `Color.clear` as the background. `CommandOverlayView` uses `.regularMaterial` which composites onto whatever is behind it. Over `Color.clear` (pre-filled with `windowBackgroundColor` by the harness), the material renders slightly differently than over a real editor with syntax-highlighted text. The snapshot is deterministic and stable, just not pixel-identical to production rendering. Acceptable for CI gating.

---

## ✅ What's Done Well (with evidence)

1. **All three `.sheet` calls removed.** Verified: the only remaining `.sheet` modifiers in `ContentView.swift` are for `showRecoveryDialog` (line 121) and `isBranchSwitcherPresented` (line 135) — both out of scope. No `.sheet` for Quick Open, Symbol Navigator, or Go to Line remains (`git grep '\.sheet' FETCH_HEAD -- Pine/*.swift`).

2. **Non-modal behavior confirmed.** Backdrop dismisses on tap (`CommandOverlayView.swift:28–32`), Escape works via `.onExitCommand` (line 48). The document remains visible behind the translucent `Color.primary.opacity(0.15)` backdrop.

3. **Go to Line a11y upgraded** from red-outline-only to: visible error message (`feedbackLabel`, `GoToLineView.swift:67–78`), VoiceOver announcement (`announceAccessibility`, line 81–87), accessibility label + hint on the field (lines 25–26), and `accessibilityElement(children: .contain)` on the container (line 43). The `goToLineInvalidMessage` identifier is on the error label.

4. **Snapshot baselines committed.** Both `GoToLine.overlay.light.png` and `GoToLine.overlay.dark.png` are present (5456 bytes each, non-trivial PNGs). Harness stubs data sources: `GoToLineView(totalLines: 1234, ...)` with no real git/fs dependency, `CommandOverlayView` with a simple binding.

5. **Localization complete.** All 4 new keys (`"Enter a line number from 1 to %lld"`, `"Enter a valid line number"`, `"Go to line"`, `"Line %1$lld is out of range (1–%2$lld)"`) have translations for all 9 locales (de, en, es, fr, ja, ko, pt-BR, ru, zh-Hans). Format preserves Xcode's non-standard `"key" : {` spacing (space before colon). Diff is additions-only.

6. **No TODOs / FIXMEs / half-done work** in any changed file.

---

## Checklist vs. Issue #975 Acceptance Criteria

| Criterion | Status | Evidence |
|---|---|---|
| Quick Open, Symbol Nav, Go to Line as non-modal overlays (not `.sheet`) | ✅ | `ContentView.swift:94, 261–289`; all three use `CommandOverlayView` |
| Anchored to editor | ⚠️ | Window-centered, not editor-pane-anchored (see N1) |
| Keyboard preserved (arrows, Enter, Escape) | ✅ | See keyboard verdict above |
| Go to Line invalid input has accessible feedback (not only red outline) | ✅ | `GoToLineView.swift:67–87` — visible label + announcement + a11y hint |
| Snapshot coverage (light + dark) | ✅ | `NavigationOverlaySnapshotTests.swift` + 2 committed PNGs |

---

## Commands Run

```
gh pr view 986
gh pr diff 986
git fetch origin ux/navigation-command-overlays-975
git show FETCH_HEAD:<file>   (CommandOverlayView, ContentView, GoToLineView,
                               QuickOpenView, SymbolNavigatorView, GoToLineParser,
                               PineAnimation, AccessibilityIdentifiers,
                               Localizable.xcstrings, CI workflow,
                               CommandOverlayViewTests, NavigationOverlaySnapshotTests,
                               SnapshotHarness, GoToLineTests,
                               GoToLineTabOverflowExternalChangesUITests,
                               QuickOpenUITests)
git grep / git cat-file for verification
```

No files were edited. No merges, pushes, or builds were performed.
