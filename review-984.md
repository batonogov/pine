# Review: PR #984 — `ux(tabs-status-breadcrumb): make hidden affordances and disabled actions clearer`

**Closes:** #976
**Branch:** `ux/tabs-breadcrumb-affordances-976` → `main`
**Verdict:** ✅ **APPROVE** (with minor notes)

---

## Verdict by Acceptance Criterion

### 1. ✅ Tab close button invisible hit target — **ADDRESSED**

| File | Before | After |
|------|--------|-------|
| `EditorTabBar.swift:477` | `.opacity(... ? 1 : 0.01)` | `.opacity(... ? 1 : 0.35)` |
| `TerminalBarView.swift:39` | `.opacity(... ? 1 : 0)` | `.opacity(... ? 1 : 0.35)` |

The `0.01` opacity (effectively invisible) is gone. `0.35` is subtly visible at idle and becomes fully opaque (`1`) on hover, active, or dirty. Good discoverability/noise balance. Verified no remaining `0.01` opacity or `opacity(0)` on interactive elements anywhere in `Pine/*.swift`.

### 2. ✅ Pinned-tab context menu — **ADDRESSED**

`EditorTabBar.swift:359-365`:
```swift
Button(role: .destructive) {
    onClose()
} label: {
    Label(Strings.menuCloseTab, systemImage: "xmark")
}
.disabled(tab.isPinned)
.help(tab.isPinned ? Strings.tabCloseTabDisabledPinned : "")
```

"Close Tab" is **no longer silently removed** for pinned tabs. It stays visible but disabled, with a help tooltip: *"Tab is pinned — unpin to close."* The menu item is retained and explained — exactly per the acceptance criterion.

### 3. ✅ Status bar encoding disabled — **ADDRESSED**

`StatusBarView.swift:134`:
```swift
.disabled(activeTab.isDirty)
.help(activeTab.isDirty ? Strings.statusbarEncodingDisabledDirty : "")
```

Real `.help()` tooltip: *"Save or revert the file to change encoding."* — not just a visual cue.

### 4. ✅ Breadcrumb ellipsis + siblings — **ADDRESSED**

`BreadcrumbPathBar.swift:34-57`: The passive `Text("…")` is now an interactive `Menu` that lists hidden ancestor segments. Each segment opens in Finder via `NSWorkspace.shared.activateFileViewerSelecting`. The menu has an `.accessibilityLabel(Strings.breadcrumbShowHiddenSegments)`.

`BreadcrumbPathBar.swift:96-107`: The `.disabled(sibling.isDirectory)` modifier is **removed**. Directory siblings are now clickable and open in Finder instead of being greyed-out with no explanation.

---

## Correct (evidence-based)

- **Opacity change is clean and consistent.** Both editor and terminal close buttons use the same `0.35` idle value. No leftover invisible hit targets found via `git grep`.
- **Pinned menu logic is sound.** `.disabled(tab.isPinned)` prevents the action; `.help()` conditionally shows the explanation only for pinned tabs (empty string for unpinned = no tooltip).
- **Breadcrumb hidden segments calculation is correct.** `BreadcrumbProvider.truncate` returns `suffix(maxVisible)` as visible; `dropLast(visible.count)` yields the hidden ancestors. Verified with the `truncateHiddenCount` test (12 segments → 8 visible, 4 hidden).
- **`BreadcrumbSegment.url` is a valid computed property** (`var url: URL { id }`), so `segment.url` and `sibling.url` compile and resolve correctly.
- **Localization format is correct.** All 3 new keys use Xcode's `"key" : "value"` format (space before colon). The diff shows **pure additions** (0 deletions to existing content) — no `json.dump` re-serialization noise.
- **All 9 locales present** for each new key: `en, de, es, fr, ja, ko, pt-BR, ru, zh-Hans` (verified via JSON parse).
- **SwiftLint: 0 violations** across all 6 changed/new files.
- **Tests compile and pass.** All 4 tests in `TabAffordanceTests` passed (`** TEST SUCCEEDED **`). The `LocalizedStringKey ==` comparison (used instead of internal `.key`) is valid — `LocalizedStringKey` conforms to `Equatable` and compares the format string key for non-interpolated literals.

---

## Notes (non-blocking)

### Note 1 — `keysPresentInXcstrings` test is a silent no-op

`TabAffordanceTests.swift:35-55` loads `Localizable.xcstrings` via `Bundle.main.url(forResource:withExtension:)`. However, Xcode **compiles** `.xcstrings` into binary `.strings` files inside `.lproj` directories during build. At test runtime, no `.xcstrings` resource exists in `Bundle.main`, so the `guard` fails and the test **silently returns** (passes without asserting anything). The test ran in 0.001s — consistent with early-exit, not JSON parsing of a multi-thousand-line file.

This is not a blocker because `newStringKeysExist` covers the key-existence check via `LocalizedStringKey ==` comparison. But `keysPresentInXcstrings` gives false confidence. Options: remove it, or load the source `.xcstrings` from the test bundle via a test resource copy, or assert against compiled `.strings` via `NSLocalizedString`.

### Note 2 — `accessibilityRepresentation` still hides close for pinned tabs

`EditorTabBar.swift:423-428`:
```swift
.accessibilityRepresentation {
    HStack {
        Button(tab.fileName, action: onSelect)...
        if !tab.isPinned {
            Button("Close", action: onClose)...
        }
    }
}
```

The context menu now shows Close Tab (disabled) for pinned tabs, but the a11y tree omits the close button entirely for pinned tabs. This is likely intentional (a pinned tab has no close affordance for VoiceOver users), but it's a slight inconsistency worth confirming — the visual menu and the a11y tree now disagree on whether a "close" concept exists for pinned tabs.

### Note 3 — PR description inaccuracy for TerminalBarView

The PR summary states terminal idle opacity changed from `0.01` to `0.35`. In reality it was `0` (fully invisible), not `0.01`. Only `EditorTabBar` had `0.01`. Cosmetic doc issue only — the code change itself is correct.

### Note 4 — "Reveals collapsed ancestors" via Finder, not in-place

The breadcrumb ellipsis reveals hidden segments by opening them in **Finder** (`NSWorkspace.shared.activateFileViewerSelecting`), not by expanding them back into the breadcrumb bar itself. This satisfies the acceptance criterion (which uses `and/or`), and is a reasonable UX choice. Just flagging that "reveals" here means "opens externally," not "expands inline."

---

## Summary

All 4 acceptance criteria are genuinely addressed with minimal, focused changes. The diff is 308 additions / 13 deletions across 7 files. No regressions, no build errors, SwiftLint clean, tests pass, localization complete and properly formatted. The notes above are all non-blocking improvements.

**Files reviewed:**
- `Pine/EditorTabBar.swift` — opacity fix + pinned menu
- `Pine/TerminalBarView.swift` — opacity fix
- `Pine/StatusBarView.swift` — encoding tooltip
- `Pine/BreadcrumbPathBar.swift` — interactive ellipsis + siblings
- `Pine/Strings.swift` — 3 new keys
- `Pine/Localizable.xcstrings` — 3 keys × 9 locales
- `PineTests/TabAffordanceTests.swift` — 4 test cases
