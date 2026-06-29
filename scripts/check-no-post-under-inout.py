#!/usr/bin/env python3
"""
Static guard against the Swift runtime exclusivity-abort class of bug
caused by posting a `NotificationCenter` notification while an `inout`
parameter holds exclusive access to a store that a synchronous observer
writes back into (Pine #1066 — the 5th recurrence of the reentrancy
family after #1047 / #1051 / #1056 / #1058).

What it flags
-------------
Any `NotificationCenter(...).post(...)` that appears in the body of a
`func` whose signature contains `inout`, unless the offending line (or
the line directly above it) carries a `// reentrancy-safe` suppression
comment — the escape hatch for a post that is provably deferred
(`DispatchQueue.main.async` / `Task {}` / `Task.detached`) and so cannot
re-enter the live `inout` access.

Why inout-scoped
----------------
The dangerous access is the live `inout` (i.e. `&x`) exclusive access.
`NotificationCenter.post` delivers the observer synchronously in the
same callstack when posted on the main queue; if that observer writes
the same store, Swift's runtime exclusivity check fires
(`swift_beginAccess` → `AccessSet::insert` →
`_swift_reportExclusivityConflict` → `abort()`). The safe pattern is to
RETURN the payload and let the caller post AFTER the `inout` scope ends
— the pattern already used by `TabExternalChangeDetector.reloadTab` and,
after #1066, by `TabPersistence.saveTabContent`. This guard keeps future
code honest instead of waiting for the next crash report.

Scope / honest limitation
-------------------------
This guards the **inout-post sub-pattern** only. The sibling
**ButtonAction/@Observable sub-pattern** (#1047/#1051/#1056/#1058 — a
post synchronously from a SwiftUI `ButtonAction` whose observer then
mutates `@State`/`@Observable`) is NOT statically detectable here: all
38 menu posts look identical and most are benign. That sub-pattern is
guarded by the per-fix regression tests (`StateChangeReentrancyTests`,
`OnReceiveReentrancyTests`, `FoldObserverReentrancyTests`,
`MenuSaveReentrancyTests`) plus the convention that `.onReceive` /
`@objc` observers defer their `@State`/`@Observable` mutations.

Exit codes: 0 = clean, 1 = violations found (or usage error).
"""
import re
import sys
from pathlib import Path

POST_RE = re.compile(r"NotificationCenter\b.*?\.post\s*\(")
SUPPRESS = "reentrancy-safe"
FUNC_RE = re.compile(r"\bfunc\b")


def strip_for_braces(line: str) -> str:
    """Remove string/char literals and comments from a single line so
    braces inside them do not corrupt depth tracking.

    Block comments and multi-line (`\"\"\"`) strings that span lines are
    handled coarsely (the rest of a line after `/*` with no `*/`, or the
    opening `\"\"\"` line, are dropped). This is intentionally simple —
    it is sufficient for this codebase and any residual edge case shows
    up as a reviewable false positive, never a silent miss."""
    out = []
    i = 0
    n = len(line)
    state = "N"  # N normal, D double-quote, S single-quote
    while i < n:
        c = line[i]
        two = line[i : i + 2]
        if state == "N":
            if two == "//":
                break  # line comment to EOL
            if two == "/*":
                end = line.find("*/", i + 2)
                if end == -1:
                    break
                i = end + 2
                continue
            if c == '"':
                # collapse a triple-quote opener to end-of-line (multiline span)
                if line[i : i + 3] == '"""':
                    break
                state = "D"
                i += 1
                continue
            if c == "'":
                state = "S"
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        if state == "D":
            if c == "\\":
                i += 2
                continue
            if c == '"':
                state = "N"
                i += 1
                continue
            i += 1
            continue
        if state == "S":
            if c == "\\":
                i += 2
                continue
            if c == "'":
                state = "N"
                i += 1
                continue
            i += 1
            continue
    return "".join(out)


def scan_file(path: Path):
    """Return a list of (line_number, source) tuples for posts found in
    the body of an `inout` function without a `reentrancy-safe` marker."""
    raw_lines = path.read_text().split("\n")
    violations = []

    depth = 0                 # brace depth at the START of the current line
    armed_body_depth = -1     # depth while inside an inout-func body; -1 = unarmed
    capturing_sig = False     # accumulating a multi-line func signature
    sig_buf = []
    sig_start_depth = -1
    prev_raw = ""

    for idx, raw in enumerate(raw_lines):
        clean = strip_for_braces(raw)

        # Begin / continue accumulating a func signature.
        if not capturing_sig and FUNC_RE.search(clean):
            capturing_sig = True
            sig_buf = [clean]
            sig_start_depth = depth
        elif capturing_sig:
            sig_buf.append(clean)

        # When the signature's body brace opens, decide if the func is armed.
        if capturing_sig and clean.count("{") > 0 and depth >= sig_start_depth:
            sig_text = " ".join(sig_buf)
            if "inout" in sig_text:
                armed_body_depth = depth + 1
            capturing_sig = False
            sig_buf = []

        # Post detection on the RAW line (posts are single-line in this codebase).
        is_armed = armed_body_depth != -1 and depth >= armed_body_depth
        if (
            is_armed
            and POST_RE.search(raw)
            and SUPPRESS not in raw
            and SUPPRESS not in prev_raw
        ):
            violations.append((idx + 1, raw.strip()))

        # Advance brace depth for subsequent lines.
        depth += clean.count("{") - clean.count("}")
        if armed_body_depth != -1 and depth < armed_body_depth:
            armed_body_depth = -1

        prev_raw = raw

    return violations


def main(argv):
    if len(argv) < 2:
        print("usage: check-no-post-under-inout.py <file_or_dir> [<file_or_dir> ...]", file=sys.stderr)
        return 2

    roots = [Path(a) for a in argv[1:]]
    swift_files = []
    for root in roots:
        if root.is_file():
            if root.suffix == ".swift":
                swift_files.append(root)
        else:
            swift_files.extend(root.rglob("*.swift"))
    swift_files = sorted(set(swift_files))

    total = 0
    for path in swift_files:
        for line_no, src in scan_file(path):
            print(f"{path}:{line_no}: NotificationCenter.post inside an inout function — {src}")
            print(f"  → return the payload and post after the inout scope ends, or mark `// reentrancy-safe` if deferred.")
            total += 1

    if total:
        print(f"\ncheck-no-post-under-inout: {total} violation(s) — exclusivity-abort reentrancy risk (#1066 class).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
