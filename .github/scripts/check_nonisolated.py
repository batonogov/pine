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
Swift type containing background queue work declares its isolation explicitly:

  - `nonisolated` — opt out of MainActor entirely (preferred for pure workers)
  - `@MainActor`  — keep MainActor but accept responsibility for closures

Unmarked types are rejected.

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
# `class | struct | enum | actor` keyword on the same line.
TYPE_DECL_RE = re.compile(
    r"""^
    (?P<indent>\s*)
    (?P<attrs>(?:@[\w()]+\s+|public\s+|internal\s+|private\s+|fileprivate\s+|
                 final\s+|nonisolated\s+|open\s+|@unchecked\s+|@Observable\s+
              )*)
    (?P<kind>class|struct|enum|actor)\s+
    (?P<name>[A-Za-z_][A-Za-z0-9_]*)
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
            f"{self.type_line}) uses background queue but is neither "
            f"`nonisolated` nor `@MainActor`. "
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
    """Return True iff the declaration carries an explicit isolation attribute.

    Accepts either `nonisolated` (preferred for pure background workers) or
    `@MainActor` (sentinel that the author understood the implication).
    """
    attrs = decl.attrs
    if "nonisolated" in attrs:
        return True
    if "@MainActor" in attrs:
        return True
    return False


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


def scan_file(path: Path) -> list[Violation]:
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []
    lines = source.splitlines()
    decls = find_type_declarations(source, path)

    violations: list[Violation] = []
    # Sort by body_start descending so nested declarations win attribution
    # over their enclosing scope.
    decls_by_inner_first = sorted(decls, key=lambda d: -d.body_start)

    for line_no, snippet in _all_background_lines(lines):
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


def _all_background_lines(lines: list[str]) -> Iterable[tuple[int, str]]:
    for i, line in enumerate(lines):
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
        "\nFix: add `nonisolated` (preferred) or `@MainActor` to the type "
        "declaration. See issue #693 for context.",
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
