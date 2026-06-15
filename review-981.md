# Review — PR #981: `fix(keyboard): make global shortcuts independent of keyboard layout`

**Branch:** `fix/keyboard-layout-independent-972` → `main`
**Closes:** #972
**Verdict:** ✅ **APPROVE**
**Date:** 2026-06-15

---

## Correctness verdict — keyCode constants: ✅ ALL CORRECT

Every physical key code was verified against the authoritative source: Apple's
Carbon `HIToolbox/Events.h` in the macOS SDK
(`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/.../HIToolbox.framework/.../Events.h`).

| Key | PR value | Carbon constant | Hex | Decimal | Match |
|-----|----------|-----------------|-----|---------|-------|
| F   | 3        | `kVK_ANSI_F`    | 0x03 | 3       | ✅    |
| W   | 13       | `kVK_ANSI_W`    | 0x0D | 13      | ✅    |
| B   | 11       | `kVK_ANSI_B`    | 0x0B | 11      | ✅    |
| Tab | 48       | `kVK_Tab`       | 0x30 | 48      | ✅    |

**Digit row (index → keyCode):**

| Digit | PR value | Carbon constant | Hex | Match |
|-------|----------|-----------------|-----|-------|
| 1     | 18       | `kVK_ANSI_1`    | 0x12 | ✅    |
| 2     | 19       | `kVK_ANSI_2`    | 0x13 | ✅    |
| 3     | 20       | `kVK_ANSI_3`    | 0x14 | ✅    |
| 4     | 21       | `kVK_ANSI_4`    | 0x15 | ✅    |
| 5     | 23       | `kVK_ANSI_5`    | 0x17 | ✅    |
| 6     | 22       | `kVK_ANSI_6`    | 0x16 | ✅    |
| 7     | 26       | `kVK_ANSI_7`    | 0x1A | ✅    |
| 8     | 28       | `kVK_ANSI_8`    | 0x1C | ✅    |
| 9     | 25       | `kVK_ANSI_9`    | 0x19 | ✅    |

The non-contiguous ordering (5/6 swapped, 9 before 7) is correctly encoded. The
`firstIndex(of:).map { $0 + 1 }` in `digit()` correctly maps these back to 1–9.

---

## Correct — what is already good

### 1. Root cause correctly diagnosed and fixed
`charactersIgnoringModifiers` returns locale-specific characters (e.g. `"ц"` on
Russian layout for the physical W key), which broke `Cmd+W` and `Cmd+1..9`. The
fix replaces these with physical key code comparisons, which identify a key by
its position on the keyboard and are stable across all layouts. This also
benefits AZERTY users (where digit keys produce `&é"'(-è_çà` without Shift).

### 2. All 5 `addLocalMonitorForEvents(.keyDown)` handlers audited
`PineApp.swift` — verified against the PR branch:

| Handler | Line | Before | After | Status |
|---------|------|--------|-------|--------|
| Cmd+W   | ~532 | `charactersIgnoringModifiers == "w"` | `matches(keyCode: .w, ...)` | ✅ Fixed (was broken) |
| Cmd+F   | ~552 | `event.keyCode == 3` | `matches(keyCode: .f, ...)` | ✅ Consistent (already worked) |
| Cmd+Shift+B | ~567 | `event.keyCode == 11` | `matches(keyCode: .b, ...)` | ✅ Consistent (already worked) |
| Ctrl+Tab | ~587 | `event.keyCode == 48` | unchanged | ✅ Correct (no layout bug — Tab and Ctrl are physical) |
| Cmd+1..9 | ~608 | `charactersIgnoringModifiers` digit check | `digit(from:, modifiers:)` | ✅ Fixed (was broken) |

No remaining `charactersIgnoringModifiers` calls in `PineApp.swift` (verified via
`grep` on the PR branch). The only other `keyCode ==` in the codebase is
`GutterTextView.swift:572` (`keyCode == 53` = Escape), which is also
layout-independent and correctly not touched.

### 3. Modifier-flag logic exactly preserved
The old code: `event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command`

The new code routes through `normalizedModifiers()` which does exactly the same:
`flags.intersection(.deviceIndependentFlagsMask)` — then compares with `==`.
Behavioral equivalence confirmed.

### 4. Clean separation and testability
The pure predicate `matches(keyCode:modifiers:eventKeyCode:eventModifiers:)` and
`digit(eventKeyCode:eventModifiers:modifiers:)` accept raw integers/flags, so
they can be unit-tested without constructing fragile `NSEvent` objects. The
`NSEvent` convenience overloads are thin wrappers that normalize modifiers and
extract the key code.

### 5. Out-of-scope terminal code correctly reverted
Commit `7f20aa7` reverted the `TabCloseHelper.confirmTerminalProcessStop` changes
from the earlier push `f2a82c1`. The final diff (`git diff origin/main..HEAD`) is
cleanly scoped to exactly 3 files:
- `Pine/KeyboardShortcutMatcher.swift` (new, 87 lines)
- `Pine/PineApp.swift` (33 lines changed)
- `PineTests/KeyboardShortcutMatcherTests.swift` (new, 170 lines)

No leftover terminal/process-stop code (verified via `grep` on the full diff).

### 6. SwiftLint clean
`swiftlint lint` on the new file reports **0 violations, 0 serious**. No lines
exceed the 150-char warning threshold.

### 7. Type-checks cleanly
`swiftc -typecheck` on `KeyboardShortcutMatcher.swift` passes with exit code 0.

### 8. Test coverage is comprehensive (17 tests)
Covers every shortcut predicate:

- **Key code constants** (2 tests): F=3, W=13, B=11, Tab=48; digits.count==9.
- **`matches()` match/non-match** (7 tests): Cmd+W correct match; wrong key code;
  missing modifier; Cmd+F; Cmd+Shift+B match; Cmd+Shift+B missing shift; extra
  modifier fails.
- **`digit()` decode** (6 tests): digit 1 (key 18), digit 5 (key 23, non-contiguous),
  digit 9 (key 25), all 9 digits loop, non-digit key → nil, wrong modifier → nil.
- **`normalizedModifiers()`** (2 tests): capsLock preserved, pure command preserved.

---

## Should-fix

### SF-1. `normalizedModifiers` stripping behavior is not actually tested
**Location:** `PineTests/KeyboardShortcutMatcherTests.swift`, tests
`normalizedStripsDeviceFlags` (line ~153) and `normalizedPureCommand` (line ~163).

Both tests pass values where all bits are device-independent (`.command`,
`.capsLock`), so `.intersection(.deviceIndependentFlagsMask)` returns the input
unchanged. The stripping behavior — the whole point of the function — is never
exercised. A regression that changed `normalizedModifiers` to a no-op (e.g.
`return flags` instead of `return flags.intersection(.deviceIndependentFlagsMask)`)
would pass all current tests.

**Suggested fix:** add a test that passes a raw value containing a device-specific
bit (high bits) and asserts it is stripped:

```swift
@Test("normalizedModifiers strips device-specific high bits")
func normalizedStripsHighBits() {
    // 0x10000000 contains device-specific bits outside deviceIndependentFlagsMask
    let raw = NSEvent.ModifierFlags(rawValue: 0x10000000 | NSEvent.ModifierFlags.command.rawValue)
    let normalized = KeyboardShortcutMatcher.normalizedModifiers(raw)
    #expect(normalized == .command) // high bits stripped, command preserved
}
```

This is low-risk (the function is a one-liner calling an Apple API), but the test
suite should prove the contract it documents.

---

## Nits

### N-1. `normalizedStripsDeviceFlags` test name is misleading
**Location:** `KeyboardShortcutMatcherTests.swift:~153`

The test name says "strips device-specific flags" but the body only demonstrates
that `.capsLock` (a device-independent flag) is *preserved*. Consider renaming to
`normalizedPreservesCapsLock` for accuracy, or better, add the test from SF-1
that actually demonstrates stripping.

### N-2. Ctrl+Tab handler not using the shared matcher (intentional but inconsistent)
**Location:** `PineApp.swift:~587`

The Ctrl+Tab handler still uses inline `event.keyCode == 48` and
`event.modifierFlags.intersection(.deviceIndependentFlagsMask)` instead of
`KeyboardShortcutMatcher`. The PR description explains this is deliberate (it was
already keyCode-based and has no layout bug). This is acceptable — Tab (48) and
Ctrl are physical — but for full consistency the matcher could be extended with a
`PhysicalKey.tab` constant (already defined but unused in production code). Not
blocking.

### N-3. `PhysicalKey.tab` is defined but never used
**Location:** `KeyboardShortcutMatcher.swift:~26`

`PhysicalKey.tab = 48` is defined and tested, but no production code references it
(the Ctrl+Tab handler still uses the inline literal `48`). If the decision is to
leave Ctrl+Tab as-is, the constant is dead code in production (only used in
tests). Minor — it documents intent and may be used later.

---

## Summary

| Check | Result |
|-------|--------|
| keyCode constants correct (vs Apple Events.h) | ✅ All 13 verified |
| All `charactersIgnoringModifiers` shortcuts replaced | ✅ Cmd+W, Cmd+1..9 fixed |
| All 5 event monitors audited | ✅ |
| Modifier logic preserved | ✅ Exact equivalence |
| Out-of-scope code reverted | ✅ Clean 3-file diff |
| SwiftLint clean | ✅ 0 violations |
| Type-checks | ✅ |
| Test coverage adequate | ✅ 17 tests (one gap: SF-1) |

The PR correctly fixes the layout-dependent shortcut bug (#972) with a clean,
minimal, well-tested abstraction. The highest-risk area — keyCode constants — is
verified correct against Apple's SDK headers. **Recommended to merge.**

---

## Files reviewed
- `Pine/KeyboardShortcutMatcher.swift` (new, 87 lines)
- `Pine/PineApp.swift` (lines ~528–625, the 5 event monitors)
- `PineTests/KeyboardShortcutMatcherTests.swift` (new, 170 lines)
- `Pine/GutterTextView.swift:572` (verified — keyCode 53/Esc, not a layout bug)
- `.swiftlint.yml` (verified rules against new code)

## Commands run
- `gh pr view 981`, `gh pr diff 981`
- `git fetch origin fix/keyboard-layout-independent-972`
- `git diff origin/main..origin/fix/keyboard-layout-independent-972 --stat`
- `git show origin/fix/...:Pine/PineApp.swift` (verified final state of all 5 monitors)
- `grep` on Events.h in macOS SDK (verified all keyCode constants)
- `swiftc -typecheck` on KeyboardShortcutMatcher.swift (exit 0)
- `swiftlint lint` on KeyboardShortcutMatcher.swift (0 violations)

## Not tested
- Full test suite run (`xcodebuild test`) was not executed — would require
  checking out the PR branch into the working tree, which the review constraints
  discouraged. Logic verified by code inspection + type-checking + linting.
- NSEvent convenience overloads (`matches(...in:)`, `digit(from:)`) are not
  directly tested — they are thin wrappers over the tested pure functions, which
  is an acceptable tradeoff (documented in the test file header).
