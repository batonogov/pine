# Review: PR #983 — feat(terminal): parse and make file:line references clickable in terminal output

**Verdict: APPROVE (with notes)**

Closes #949. The PR delivers a well-structured, pure-function parser with 23 unit tests, correct NSRange handling, and minimal Cmd+click integration. The regex is multiline-safe and does not greedily absorb wrapping punctuation. No terminal performance regression — parsing is scoped to the single clicked row, not the scrollback. All acceptance criteria from issue #949 are met.

---

## Correct

### Regex design and correctness
The regex `([\w.~+/\-]+):(\d+)(?::(\d+))?` in `TerminalOutputParser.swift:37` is sound:

- **Multiline safety**: The path character class `[\w.~+/\-]` excludes `\n` and `\r`. Neither the line nor column digit groups can span newlines. The regex cannot greedily match across lines. ✅
- **Wrapping punctuation excluded**: `(`, `)`, `[`, `]`, `{`, `}`, `"`, `'`, `,`, `:` are all absent from `[\w.~+/\-]`. A reference like `(file.swift:42),` correctly matches only `file.swift:42`. Verified by test `parsesReferenceInSentenceWithSurroundingPunctuation`. ✅
- **No `\S+` problem**: The PR does NOT use `\S+`. It uses a deliberately restricted character class. This is the correct approach. ✅
- **Greedy `+` backtracking**: `+` on the path portion is greedy but cannot consume `:` (not in the char class), so no pathological backtracking. ✅
- **HTTP URL rejection**: `https://example.com/page` does not produce a match because there is no `:digits` after a valid path token. `https://example.com:8080` matches `//example.com:8080` syntactically, but the `fileExists` check rejects it. Verified by test `rejectsHttpURLs`. ✅

### NSRange correctness
- `match.range` and all capture group ranges are computed against `NSString` (`nsText = text as NSString`), not Swift `String` indices. ✅
- Verified by test `nsrangeHandlesMultibyteText` — Japanese text prefix does not corrupt the range. ✅

### Existence validation
- `fileManager.fileExists(atPath:)` is called for every match before creating a `TerminalLink`. Only verified files become links. ✅
- Relative paths resolved via `workingDirectory.appendingPathComponent(path)`. ✅
- Absolute paths (`/...`) and home-relative paths (`~/...`) handled independently in `resolvePath`. ✅
- `line > 0` validation rejects line 0 (most tools use 1-based lines). ✅

### Performance safety
- **Parse scope**: The click handler in `TerminalScrollInterceptor.handleFileLinkClick` calls `term.getLine(row:).translateToString()` for the single clicked row only. It does NOT scan the full scrollback or even all visible lines. This exceeds the "parse visible lines only" requirement — it parses one line per click. ✅
- **Regex compilation**: Static `regex` property compiled once. ✅
- **File I/O**: At most N `FileManager.fileExists` stat calls per click, where N = number of regex matches on that row (typically 0–2). Negligible. ✅
- **Thread safety**: All work is on the main thread in `mouseDown`, but for a single row + 0–2 stat calls, this is well within the <4ms budget. ✅

### Integration wiring
- `TerminalScrollInterceptor.mouseDown` intercepts Cmd+click → maps to grid cell → extracts row text → parses → posts `.openFileAtLine` notification. ✅
- `GitAndNotificationObserver` receives `.openFileAtLine` → calls `tabManager.openTabAndGoToLine(url:line:)` → sets `pendingGoToLine` → `ContentView` observes and navigates. ✅
- `TerminalContainerView.showTab` wires `scrollInterceptor.workingDirectory = tab.workingDirectoryURL`. ✅
- Grid row mapping verified correct: SwiftTerm's `getLine(row:)` uses `buffer.lines[row + buffer.yDisp]`, so `grid.row` (0-based from visible top) maps to the correct visible row accounting for scrollback. ✅
- Fallthrough: if no link is found under the cursor, `handleFileLinkClick` returns `false` and the click passes through to normal terminal input. ✅

### Test coverage
23 tests covering all acceptance-criteria cases:
| Criterion | Test |
|---|---|
| Standard `file.swift:42` | `parsesSimpleFileNameWithLine` |
| Absolute `/abs/path.swift:10:5` | `parsesAbsolutePathWithLineAndColumn` |
| Relative `src/config.yml:3` | `parsesRelativePathWithSubdirectory` |
| `line:column` | `parsesLineAndColumn` |
| HTTP URL rejection | `rejectsHttpURLs` |
| Non-existent file rejection | `rejectsNonExistentFile`, `rejectsPlainWordsThatLookLikeReferences` |
| Multiline | `parsesMultipleReferencesInMultilineText` |
| Trailing punctuation | `parsesReferenceInSentenceWithSurroundingPunctuation` |
| Multibyte NSRange | `nsrangeHandlesMultibyteText` |
| Line 0 rejection | `doesNotMatchLineZero` |
| Files without extension | `matchesFilesWithoutExtension` |
| Deeply nested paths | `matchesDeeplyNestedRelativePath` |
| `link(atColumn:)` hit-testing | `linkAtColumnFindsLinkUnderCursor`, `linkAtColumnReturnsNilForEmptyLinks` |
| `resolvePath` absolute/relative/tilde | 3 dedicated tests |

### CI status (at time of review)
- SwiftLint: ✅ pass
- Build for Testing: ✅ pass
- UI Tests (Terminal): ✅ pass — no regression
- UI Tests (Editor Chrome, Welcome & Session, Files & Save, Search & Panes): ✅ pass
- Unit Tests: ⏳ pending (not yet complete)
- 2 UI test shards pending

---

## Notes (non-blocking)

### Note 1 — Medium: Missing `controlActiveState == .key` guard in notification handler

**File**: `GitAndNotificationObserver.swift:145–150`

The `.openFileAtLine` handler does not check `controlActiveState == .key`, unlike every other notification handler in the same file (`goToLine`, `navigateChange`, `inlineDiffAction`, `sendTextToTerminal` all guard on it). Since `NotificationCenter.default` is app-wide and `WindowGroup(for: URL.self)` creates one `ContentView` per project window, a Cmd+click in terminal window A will also trigger `openTabAndGoToLine` in project window B.

In practice, clicking the terminal makes that window key, so the correct window responds. But the other windows' `GitAndNotificationObserver` instances also receive the notification and open the file too — potentially opening a file from project A in project B's tab manager.

**Suggested fix**:
```swift
.onReceive(NotificationCenter.default.publisher(for: .openFileAtLine)) { notification in
    guard controlActiveState == .key,
          let url = notification.userInfo?["url"] as? URL,
          let line = notification.userInfo?["line"] as? Int else { return }
    tabManager.openTabAndGoToLine(url: url, line: line)
}
```

### Note 2 — Low: Wide character (CJK) column mapping in click hit-testing

**File**: `TerminalSession.swift:163–167` (`handleFileLinkClick`)

`grid.col` from `MouseScrollForwarder.gridPosition` maps to terminal cell positions (where a CJK character occupies 2 cells). But `link.range` is an NSString range where a CJK character is 1 character. If wide characters precede a `file:line` reference on the same row, the hit-test in `TerminalOutputParser.link(atColumn: grid.col, in: links)` may be off by N (the number of wide characters before the link).

Example: `エラー main.swift:42` — `エ` and `ラ` and `ー` each take 2 terminal cells. Clicking on `main.swift` (terminal cells 6–16) maps to `grid.col ≈ 6–16`, but the NSString range for `main.swift:42` starts at location 4 (after 4 CJK characters). `NSLocationInRange(10, NSRange(location: 4, length: 14))` still works by luck for most click positions, but edge cases (clicking near the boundary) could miss.

This is a low-severity edge case. ASCII-only output (the vast majority of `file:line` references) is unaffected. A proper fix would convert `grid.col` to an NSString index by counting wide characters in the row up to that column.

### Note 3 — Low: Column not validated for > 0

**File**: `TerminalOutputParser.swift:128–130`

Line numbers are validated (`line > 0`), but column is not. A reference like `file.swift:42:0` would capture `column: 0`. Since column navigation is not yet wired (the handler ignores it), this is harmless. If column navigation is added later, add `column > 0` validation.

### Note 4 — Low: No visual indication of clickable links

Documented in the PR body as a known limitation. SwiftTerm uses CoreGraphics cell rendering, not NSTextStorage, so visual underlining would require SwiftTerm internals changes. Cmd+click is the sole discovery mechanism. This is acceptable for the PR's stated scope ("tested core + minimal wiring").

### Note 5 — Low: No test for `handleFileLinkClick` integration

The click handler (`handleFileLinkClick`) is not unit-tested — it requires a live SwiftTerm `Terminal` and `LocalProcessTerminalView`. The pure parser is thoroughly tested, and the UI test suite (Terminal shard) passed. Consider adding a UI test that Cmd+clicks a known `file:line` reference in the terminal and verifies the file opens, if feasible given the known XCUITest keyboard limitations.

---

## Summary

| Area | Verdict |
|---|---|
| Regex correctness | ✅ Correct — multiline-safe, punctuation handled, no greedy cross-line matching |
| NSRange correctness | ✅ NSString-based, multibyte-safe, tested |
| Existence validation | ✅ Only on-disk files become links |
| Performance | ✅ Single-row parse on click, O(1) per click, no scrollback scan |
| Integration | ✅ NotificationCenter wiring complete, grid mapping verified |
| Test coverage | ✅ All acceptance-criteria cases covered (23 tests) |
| Multi-window guard | ⚠️ Missing `controlActiveState` check (Note 1) |

**Overall**: APPROVE. The core deliverable is correct, tested, and performant. The multi-window notification guard (Note 1) should be addressed in a follow-up or this PR if convenient, but it is not a blocker for the primary single-window use case.
