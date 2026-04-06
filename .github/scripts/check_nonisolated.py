#!/usr/bin/env python3
"""Check that Swift types using background DispatchQueue/OperationQueue are
explicitly isolated.

Background: Pine sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which makes
every unannotated class/struct/enum implicitly `@MainActor`. Closures passed to
`DispatchQueue.global().async`, `DispatchQueue(label:).async` or
`OperationQueue().addOperation` capture and inherit that isolation. At runtime
the Swift concurrency runtime asserts the executor matches MainActor and
crashes with `dispatch_assert_queue_fail` (SIGTRAP).

Several historical crashes (#613, #693, ConfigValidator, FileNode, PreviewItem,
SyntaxHighlighter) had this exact root cause. This script enforces that any
Swift class/struct/enum/extension containing background queue work declares
its isolation explicitly with `nonisolated`. `@MainActor` is rejected: it is
the *cause* of these crashes, not a fix — a `@MainActor` type that schedules
work on `DispatchQueue.global()` is exactly the bug pattern that crashed
InlineDiffProvider, SyntaxHighlighter, and FileNode. The only accepted opt-out
is explicit `nonisolated`.

`actor` types are excluded from this check: actors have their own serial
executor, and closures handed to `DispatchQueue.global().async` do NOT inherit
actor isolation, so the MainActor-mismatch crash does not apply.

Unmarked class/struct/enum/extension declarations are rejected.

Known limitations (NOT detected — false negatives possible):

  - `DispatchWorkItem { ... }` constructed without `.global()` on the same
    line. The script only matches the queue construction site, not work-item
    captures.
  - `Thread { ... }.start()` and other manual thread-spawning APIs.
  - Queues injected via dependency injection (`init(queue: DispatchQueue)`)
    where the queue identity is not visible at the call site.
  - Background queue references inside Swift multi-line string literals
    (triple-quoted strings) — the comment/string stripper is single-line only.
  - Background queue references inside `/* ... */` block comments — only
    `//` line comments are stripped.
  - Background queue references inside top-level free functions. Free
    functions have no enclosing type owner and are intentionally out of scope.

Usage:
    python3 check_nonisolated.py [path ...]
        path defaults to "Pine/" relative to CWD.

Exit codes:
    0 — success, no violations
    1 — violations found
    2 — usage error
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

# Patterns that create background dispatch contexts whose closures inherit the
# enclosing actor isolation. `.main` queues are explicitly excluded.
BG_QUEUE_PATTERNS = [
    re.compile(r"\bDispatchQueue\.global\b"),
    re.compile(r"\bDispatchQueue\s*\(\s*label\s*:"),
    re.compile(r"\bOperationQueue\s*\(\s*\)"),
]

# Type-declaration regex. Captures any combination of attributes preceding the
# `class | struct | enum | extension` keyword on the same line. `actor` types
# are intentionally excluded — see module docstring for why.
#
# Generic parameter clauses (`class Foo<T: Sendable>`) and qualified extension
# names (`extension Foo.Bar`) are tolerated by the `name` group, which accepts
# dotted identifiers; anything after the name (generics, inheritance list,
# where clause, opening brace) is left for the body-range scanner.
TYPE_DECL_RE = re.compile(
    r"""^
    (?P<indent>\s*)
    (?P<attrs>(?:@[\w()]+\s+|public\s+|internal\s+|private\s+|fileprivate\s+|
                 final\s+|nonisolated\s+|open\s+|@unchecked\s+|@Observable\s+
              )*)
    (?P<kind>class|struct|enum|extension)\s+
    (?P<name>[A-Za-z_][A-Za-z0-9_.]*)
    """,
    re.VERBOSE,
)

# Separate matcher for `actor` declarations. Used solely so the body-range
# scanner can recognise an actor and skip flagging background queues inside
# it (closures handed to `DispatchQueue.global().async` do not inherit actor
# isolation, so the MainActor crash pattern is not reachable).
ACTOR_DECL_RE = re.compile(
    r"""^\s*
    (?:@[\w()]+\s+|public\s+|internal\s+|private\s+|fileprivate\s+|
       final\s+|nonisolated\s+|open\s+|@unchecked\s+
    )*
    actor\s+[A-Za-z_][A-Za-z0-9_]*
    """,
    re.VERBOSE,
)


@dataclass(frozen=True)
class TypeDecl:
    """A Swift type declaration discovered in a file."""

    file: Path
    name: str
    kind: str
    line: int            # 1-based line number of the declaration
    attrs: str           # Attribute prefix as written, e.g. "@MainActor @Observable final "
    body_start: int      # 0-based index of the opening `{` line
    body_end: int        # 0-based index of the closing `}` line (inclusive)


@dataclass(frozen=True)
class Violation:
    file: Path
    type_name: str
    type_kind: str
    type_line: int
    queue_line: int
    queue_snippet: str

    def format(self) -> str:
        return (
            f"{self.file}:{self.queue_line}: "
            f"{self.type_kind} '{self.type_name}' (declared at line "
            f"{self.type_line}) uses background queue but is not "
            f"`nonisolated`. "
            f"Snippet: {self.queue_snippet.strip()}"
        )


# ----------------------------- core logic ---------------------------------- #

def find_type_declarations(source: str, file: Path) -> list[TypeDecl]:
    """Parse top-level and nested type declarations and locate their bodies.

    The body is located by tracking `{` / `}` braces from the declaration line.
    Strings, comments, and character literals are not stripped — Swift type
    declarations rarely contain raw braces in attributes, so this is robust
    enough for grep-style enforcement.
    """
    lines = source.splitlines()
    decls: list[TypeDecl] = []

    for idx, line in enumerate(lines):
        # Strip line comments — many declarations have trailing `// ...`.
        code = _strip_line_comment(line)
        m = TYPE_DECL_RE.match(code)
        if not m:
            continue
        # Skip declarations that are actually inside a string. Cheap heuristic.
        # The regex anchors to start-of-line ignoring whitespace, so type
        # decls inside string literals (rare) would still match — accept the
        # false positive cost.

        body_start, body_end = _find_body_range(lines, idx)
        if body_start == -1:
            # Forward declaration / extension shorthand without a body — skip.
            continue

        # Collect attributes from preceding lines. Swift commonly writes
        # `@MainActor` / `@Observable` / `nonisolated` on their own line above
        # the type declaration. Walk upward over lines that are pure attribute
        # statements until we hit code or a blank line.
        leading_attrs = _collect_leading_attributes(lines, idx)
        attrs = leading_attrs + (m.group("attrs") or "")

        decls.append(
            TypeDecl(
                file=file,
                name=m.group("name"),
                kind=m.group("kind"),
                line=idx + 1,
                attrs=attrs,
                body_start=body_start,
                body_end=body_end,
            )
        )

    return decls


# Lines that are pure attribute prefixes belonging to the next declaration.
# Examples:
#   @MainActor
#   @Observable
#   @available(macOS 26, *)
#   nonisolated
ATTR_LINE_RE = re.compile(
    r"^\s*(?:@[\w]+(?:\s*\([^)]*\))?|nonisolated)\s*$"
)


def _collect_leading_attributes(lines: list[str], decl_idx: int) -> str:
    """Walk upward from decl_idx-1 collecting attribute-only lines.

    Stops at the first line that is blank, a comment, or non-attribute code.
    Returns the concatenated attributes (with trailing space) so that the
    `is_explicitly_isolated` substring check sees them.
    """
    collected: list[str] = []
    j = decl_idx - 1
    while j >= 0:
        raw = lines[j]
        stripped = raw.strip()
        if stripped == "":
            break
        if stripped.startswith("//"):
            # Documentation comment / single-line comment — keep walking, it
            # may sit between an attribute and the declaration.
            j -= 1
            continue
        if ATTR_LINE_RE.match(raw):
            collected.append(stripped)
            j -= 1
            continue
        break
    if not collected:
        return ""
    # Reverse so order matches source for readability in error messages.
    return " ".join(reversed(collected)) + " "


def _strip_line_comment(line: str) -> str:
    """Remove `//` comment tail. Naive — does not parse strings."""
    # Avoid stripping `//` inside string literals by checking for unescaped
    # quote count up to the slash position. Cheap and good enough.
    in_str = False
    i = 0
    while i < len(line) - 1:
        ch = line[i]
        if ch == "\\":
            i += 2
            continue
        if ch == '"':
            in_str = not in_str
        elif not in_str and ch == "/" and line[i + 1] == "/":
            return line[:i]
        i += 1
    return line


def _find_body_range(lines: list[str], decl_idx: int) -> tuple[int, int]:
    """Return (open_line_idx, close_line_idx) of the body following decl_idx.

    Returns (-1, -1) when no body is found (e.g. protocol conformance only).
    """
    depth = 0
    started = False
    for j in range(decl_idx, len(lines)):
        for ch in lines[j]:
            if ch == "{":
                depth += 1
                started = True
            elif ch == "}":
                depth -= 1
                if started and depth == 0:
                    return decl_idx, j
        # Avoid runaway scan if the declaration line ends with `{` then never
        # closes — Swift parser would have caught it. Continue.
    return -1, -1


def is_explicitly_isolated(decl: TypeDecl) -> bool:
    """Return True iff the declaration carries an explicit `nonisolated` opt-out.

    `@MainActor` is intentionally NOT accepted: it is the *cause* of the
    crashes this script exists to prevent. A `@MainActor` class that schedules
    work on `DispatchQueue.global()` is exactly the bug pattern. The only
    accepted opt-out is `nonisolated`, which detaches the type from MainActor
    so its background closures do not inherit a main-queue executor.
    """
    return "nonisolated" in decl.attrs


def find_background_queues(lines: list[str], start: int, end: int) -> list[tuple[int, str]]:
    """Return [(line_number_1based, snippet)] of background queue uses in the
    closed range [start, end]."""
    hits: list[tuple[int, str]] = []
    for i in range(start, end + 1):
        line = lines[i]
        for pat in BG_QUEUE_PATTERNS:
            if pat.search(line):
                hits.append((i + 1, line))
                break
    return hits


def _find_actor_body_ranges(lines: list[str]) -> list[tuple[int, int]]:
    """Return [(body_start, body_end)] for every `actor` declaration in the
    source. Closures inside an actor never inherit MainActor isolation, so the
    scan must skip background queues that fall inside one of these ranges."""
    ranges: list[tuple[int, int]] = []
    for idx, line in enumerate(lines):
        code = _strip_line_comment(line)
        if ACTOR_DECL_RE.match(code):
            body_start, body_end = _find_body_range(lines, idx)
            if body_start != -1:
                ranges.append((body_start, body_end))
    return ranges


def _line_in_any_range(line_idx: int, ranges: list[tuple[int, int]]) -> bool:
    for start, end in ranges:
        if start <= line_idx <= end:
            return True
    return False


def scan_file(path: Path) -> list[Violation]:
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []
    lines = source.splitlines()
    decls = find_type_declarations(source, path)
    actor_ranges = _find_actor_body_ranges(lines)

    violations: list[Violation] = []
    # Sort by body_start descending so nested declarations win attribution
    # over their enclosing scope.
    decls_by_inner_first = sorted(decls, key=lambda d: -d.body_start)

    for line_no, snippet in _all_background_lines(lines):
        if _line_in_any_range(line_no - 1, actor_ranges):
            # Inside an `actor` body — closures do not inherit MainActor.
            continue
        owner = _owning_decl(decls_by_inner_first, line_no - 1)
        if owner is None:
            # Top-level free function or extension closure — out of scope.
            continue
        if is_explicitly_isolated(owner):
            continue
        violations.append(
            Violation(
                file=path,
                type_name=owner.name,
                type_kind=owner.kind,
                type_line=owner.line,
                queue_line=line_no,
                queue_snippet=snippet,
            )
        )
    return violations


IGNORE_DIRECTIVE = "nonisolated-check:ignore"


def _all_background_lines(lines: list[str]) -> Iterable[tuple[int, str]]:
    """Yield (line_number_1based, raw_line) for every background queue use.

    Lines carrying the `// nonisolated-check:ignore` directive are skipped.
    Use sparingly — each ignore is a known bug-pattern site that should be
    tracked in an issue and refactored to use a `nonisolated` worker.
    """
    for i, line in enumerate(lines):
        # Accept the directive either on the same line (trailing comment) or
        # on the immediately preceding line (header comment).
        if IGNORE_DIRECTIVE in line:
            continue
        if i > 0 and IGNORE_DIRECTIVE in lines[i - 1]:
            continue
        code = _strip_line_comment(line)
        for pat in BG_QUEUE_PATTERNS:
            if pat.search(code):
                yield i + 1, line
                break


def _owning_decl(decls_inner_first: list[TypeDecl], line_idx: int) -> TypeDecl | None:
    for d in decls_inner_first:
        if d.body_start <= line_idx <= d.body_end:
            return d
    return None


def scan_paths(paths: Iterable[Path]) -> list[Violation]:
    violations: list[Violation] = []
    for path in paths:
        if path.is_dir():
            for swift in sorted(path.rglob("*.swift")):
                violations.extend(scan_file(swift))
        elif path.suffix == ".swift":
            violations.extend(scan_file(path))
    return violations


def main(argv: list[str]) -> int:
    raw_paths = argv[1:] if len(argv) > 1 else ["Pine"]
    paths = [Path(p) for p in raw_paths]
    for p in paths:
        if not p.exists():
            print(f"error: path not found: {p}", file=sys.stderr)
            return 2

    violations = scan_paths(paths)
    if not violations:
        print(f"check_nonisolated: OK ({sum(1 for _ in _iter_swift(paths))} files scanned)")
        return 0

    print(
        "check_nonisolated: found "
        f"{len(violations)} violation(s):\n",
        file=sys.stderr,
    )
    for v in violations:
        print("  - " + v.format(), file=sys.stderr)
    print(
        "\nFix: add `nonisolated` to the type declaration. `@MainActor` is "
        "NOT accepted — it is the cause of the crash, not the fix. See "
        "issue #693 for context.",
        file=sys.stderr,
    )
    return 1


def _iter_swift(paths: Iterable[Path]) -> Iterable[Path]:
    for p in paths:
        if p.is_dir():
            yield from p.rglob("*.swift")
        elif p.suffix == ".swift":
            yield p


if __name__ == "__main__":
    sys.exit(main(sys.argv))
