# Review: PR #985 — Project Search Keyboard Navigation, Truncation Feedback, Active-Pane Routing

**Verdict: REQUEST CHANGES**

**Branch:** `ux/project-search-keyboard-routing-974` → `main`
**Closes:** #974
**CI:** Unit tests pass, SwiftLint clean. Two UI test shards still pending at time of review.

---

## Summary

PR #985 implements all five acceptance criteria from issue #974: keyboard selection model in `SearchResultsView`, truncation feedback (total + per-file caps), active-pane routing via `projectManager.activeTabManager`, Escape-to-clear-search, and 18 unit tests covering selection logic, truncation detection, flatten ordering, and pane routing.

The active-pane routing — the highest-risk area — is **correct** and has no silent primary fallback. However, there is a **blocking** localization bug (`%d` vs `%lld`) that will cause the truncation footer to display garbled strings at runtime, plus two should-fix UX issues around keyboard focus and selection-reset timing.

---

## Verdict on Active-Pane Routing: CORRECT ✅

Traced the full call chain:

1. `SearchResultsView.openMatch(_:)` → `projectManager.activeTabManager.openTabAndGoToLine(url:line:)` (`SearchResultsView.swift`, new `openMatch`)
2. `ProjectManager.activeTabManager` → `paneManager.activeEditorTabManager ?? primaryTabManager` (`ProjectManager.swift:40-42`)
3. `PaneManager.activeEditorTabManager` (`PaneManager.swift:226-234`):
   - If `tabManagers[activePaneID]` exists → returns it (active pane **is** an editor → correct pane's TM)
   - Else iterates `root.leafIDs` filtering `.editor` → returns first editor pane's TM (active is terminal → nearest editor)
   - Else `nil` → `primaryTabManager` fallback (only when **no** editor pane exists — legitimate edge case)

**No silent primary fallback** when an editor pane is focused. The `?? primaryTabManager` in `ProjectManager.activeTabManager` only triggers when the pane tree has zero editor leaves (terminals-only layout), which is the correct last resort.

The old code used `@Environment(TabManager.self) var tabManager` which always resolved to the primary TM injected by the parent. The PR correctly removes this and routes through `projectManager.activeTabManager` instead.

Tests verify all three scenarios: single editor pane, terminal active → nearest editor, split editor pane → follows active (`SearchResultsKeyboardTests.swift` → `SearchActivePaneRoutingTests`).

---

## Findings

### 🔴 BLOCKING

#### B1. `%d` format specifier in xcstrings keys — truncation messages will not render

**Files:** `Pine/Localizable.xcstrings` (new keys `"search.truncatedTotal %d %d"`, `"search.truncatedPerFile %d"`)

Swift's `String(localized:)` with `Int` interpolation generates `%lld` format specifiers in the catalog key (because `Int` is `Int64` on Apple silicon). The PR uses `%d` instead.

**Evidence — every existing `Int`-interpolated key in the codebase uses `%lld`:**

| Code (`Strings.swift`) | xcstrings key |
|---|---|
| `String(localized: "terminal.numberedName \(number)")` | `"terminal.numberedName %lld"` (line 8614) |
| `String(localized: "terminal.search.matchCount \(current) \(total)")` | `"terminal.search.matchCount %lld %lld"` (line 8854) |
| `String(localized: "validation.errorCount \(count)")` | `"validation.errorCount %lld"` (line 9817) |

There are **38** `%lld` entries and **0** bare `%d` entries in the existing xcstrings file.

**Runtime impact:** `String(localized: "search.truncatedTotal \(shown) \(max)")` looks up key `"search.truncatedTotal %lld %lld"`. The catalog has `"search.truncatedTotal %d %d"`. Keys don't match → `String(localized:)` falls back to formatting the `LocalizationValue` directly, producing a garbled string like `"search.truncatedTotal 5 1000"` instead of `"Showing 5 of 1000 matches — refine your query"`.

This defeats acceptance criterion #2 ("UI shows when results are truncated") — the message will display, but with raw key text instead of the localized message, in all 9 locales.

**Fix:** Change both keys from `%d` to `%lld`:
- `"search.truncatedTotal %d %d"` → `"search.truncatedTotal %lld %lld"`
- `"search.truncatedPerFile %d"` → `"search.truncatedPerFile %lld"`

CI doesn't catch this because no test asserts the rendered string output, and the xcstrings file is valid JSON regardless of format specifier.

---

### 🟡 SHOULD-FIX

#### S1. Keyboard navigation requires manual click-to-focus — no auto-focus on results

**File:** `Pine/SearchResultsView.swift` (new `searchResultsList`)

The `.onKeyPress(.upArrow/.downArrow/.return)` modifiers are attached to the `ScrollView` with `.focusable()`, but there is no `@FocusState` to programmatically focus the list when results appear. When the user types a query, the `.searchable()` search field retains keyboard focus. Arrow keys and Enter will be no-ops until the user clicks on the results area.

This partially defeats acceptance criterion #1 ("Arrow Up/Down moves selection; Enter opens") — the functionality exists but is not discoverable without clicking first.

**Suggested fix:** Add a `@FocusState` that activates when results transition from empty/loading to populated, or move the `.onKeyPress` handlers higher in the responder chain (e.g., onto the `SidebarSearchableContent` Group, which already has the Escape handler).

#### S2. Selection reset keyed on `totalMatchCount` — stale selection when count is unchanged

**File:** `Pine/SearchResultsView.swift` (new `.onChange(of: search.totalMatchCount)`)

```swift
.onChange(of: search.totalMatchCount) { _, _ in
    selectedIndex = search.flattenedMatches.isEmpty ? nil : 0
}
```

If two consecutive debounced searches produce the same total match count but different files/matches (e.g., query "foo" → 5 matches, then query "bar" → also 5 matches), `totalMatchCount` doesn't change → `onChange` doesn't fire → `selectedIndex` retains its previous value, potentially highlighting a different match than intended.

**Impact:** Minor — the user can press Up/Down to reselect, and an out-of-bounds index is handled safely (`flat.indices.contains(selectedIndex)` guard in the Enter handler, modulo wrapping in `nextIndex`). But it's the "stale-selection-after-refresh" pattern called out as a common bug in the review criteria.

**Suggested fix:** Observe a results-generation counter or use `search.results` (would require `Equatable` conformance on `SearchFileGroup`, or observe `search.query` to reset on every keystroke).

---

### 🔵 NIT

#### N1. O(n) flatIndex lookup per visible row

**File:** `Pine/SearchResultsView.swift` (`fileGroupView`)

```swift
let flatIndex = flat.firstIndex { $0.fileURL == group.url && $0.match.id == match.id } ?? -1
```

This is O(n) per row. With a `LazyVStack` only visible rows are computed, so in practice this is ~20 × 1000 = 20K comparisons — negligible. But it could be eliminated by precomputing a `[MatchID: Int]` lookup or threading the flat offset through the group iteration.

#### N2. Truncation footer shows only one message at a time

**File:** `Pine/SearchResultsView.swift` (`truncationMessage`)

When both `isTotalCapped` and `isPerFileCapped` are true, only the total-cap message is shown (due to `if/else if`). This is arguably the right priority (total cap is more severe), but the per-file cap is silently suppressed. Consider showing both or documenting the priority choice.

---

## Test Coverage Assessment

The tests (`SearchResultsKeyboardTests.swift`, 18 tests across 4 suites) are well-structured and test the **resolver functions** (pure logic), not SwiftUI:

| Suite | Coverage | Verdict |
|---|---|---|
| `SearchSelectionLogic.nextIndex` | Wrapping forward/backward, single element, empty, nil start, large delta | ✅ Thorough |
| Truncation detection | Below/at/above `maxResults`, empty groups, one-of-many per-file cap | ✅ Thorough |
| `flatten` | Order preservation, empty | ✅ Adequate |
| `activeEditorTabManager` | Single pane, terminal active → nearest editor, split → follows active | ✅ Covers the resolver |

**Not tested (acceptable gaps):**
- The actual `String(localized:)` output for truncation messages (this is where B1 hides)
- SwiftUI keyboard event delivery / focus behavior
- End-to-end `openMatch` → `activeTabManager.openTabAndGoToLine` integration

---

## Files Changed

| File | Change |
|---|---|
| `Pine/SearchResultsView.swift` | Selection model, keyboard nav, truncation footer, active-pane routing |
| `Pine/ProjectSearchProvider.swift` | `isTotalCapped`/`isPerFileCapped`, `FlatSearchMatch`, `SearchSelectionLogic`, static helpers |
| `Pine/SidebarView.swift` | Escape-to-clear in `SidebarSearchableContent` |
| `Pine/Strings.swift` | `searchTruncatedTotal`/`searchTruncatedPerFile` functions |
| `Pine/AccessibilityIdentifiers.swift` | `searchTruncationFooter` ID |
| `Pine/Localizable.xcstrings` | 2 new keys × 9 locales (**B1: format specifiers wrong**) |
| `PineTests/SearchResultsKeyboardTests.swift` | 18 new tests |

---

## Acceptance Criteria Checklist

| # | Criterion | Status |
|---|---|---|
| 1 | Active selection model, Arrow Up/Down, Enter, visual highlight | ✅ Implemented (⚠️ S1: focus gap) |
| 2 | Truncation feedback (total + per-file caps from provider) | ✅ Provider exposes flags, view reads them (🔴 B1: wrong format specifier) |
| 3 | Results route to active editor pane's TabManager | ✅ Correct, no silent primary fallback |
| 4 | Obvious way to return to file tree (Escape / affordance) | ✅ Escape clears query |
| 5 | Unit tests cover selection, truncation, routing resolver | ✅ 18 tests, resolver-tested |
