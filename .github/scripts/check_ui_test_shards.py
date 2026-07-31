#!/usr/bin/env python3
"""Validate UI test shard membership and balance.

The check fails closed when a concrete PineUITestCase subclass is missing,
listed more than once, unknown to the test target, or makes the test-count
delta between shards exceed the configured limit.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


CLASS_PATTERN = re.compile(
    r"\b(?:final\s+)?class\s+([A-Za-z0-9_]+)\s*:\s*PineUITestCase\b"
)
TEST_PATTERN = re.compile(r"^\s+func\s+(test[A-Za-z0-9_]+)\s*\(", re.MULTILINE)
SHARD_PATTERN = re.compile(r'^\s*-\s+shard-name:\s*"?([^"]+?)"?\s*$')
ASSIGNMENT_PATTERN = re.compile(
    r"-only-testing:PineUITests/([A-Za-z0-9_]+)"
)


class ShardValidationError(Exception):
    """Raised when the shard matrix cannot prove complete balanced coverage."""


@dataclass(frozen=True)
class ShardReport:
    """Validated test counts for each workflow shard."""

    class_counts: dict[str, int]
    shard_counts: dict[str, int]

    @property
    def total_tests(self) -> int:
        return sum(self.class_counts.values())

    @property
    def delta(self) -> int:
        counts = list(self.shard_counts.values())
        return max(counts) - min(counts)


def discover_test_classes(tests_directory: Path) -> dict[str, int]:
    """Return concrete PineUITestCase subclasses and their test counts."""
    class_counts: dict[str, int] = {}
    for source in sorted(tests_directory.rglob("*.swift")):
        text = source.read_text(encoding="utf-8")
        class_names = CLASS_PATTERN.findall(text)
        if not class_names:
            continue
        if len(class_names) != 1:
            raise ShardValidationError(
                f"{source} declares {len(class_names)} PineUITestCase subclasses"
            )
        class_name = class_names[0]
        if class_name in class_counts:
            raise ShardValidationError(
                f"duplicate UI test class declaration: {class_name}"
            )
        class_counts[class_name] = len(TEST_PATTERN.findall(text))

    if not class_counts:
        raise ShardValidationError(
            f"no PineUITestCase subclasses found under {tests_directory}"
        )
    return class_counts


def parse_shards(workflow: Path) -> dict[str, list[str]]:
    """Parse shard-name/test-class pairs from the UI test matrix."""
    shards: dict[str, list[str]] = {}
    current_shard: str | None = None

    for line in workflow.read_text(encoding="utf-8").splitlines():
        shard_match = SHARD_PATTERN.match(line)
        if shard_match:
            current_shard = shard_match.group(1)
            if current_shard in shards:
                raise ShardValidationError(
                    f"duplicate shard name: {current_shard}"
                )
            shards[current_shard] = []
            continue

        for class_name in ASSIGNMENT_PATTERN.findall(line):
            if current_shard is None:
                raise ShardValidationError(
                    f"UI test class {class_name} appears before a shard name"
                )
            shards[current_shard].append(class_name)

    if not shards:
        raise ShardValidationError(f"no UI test shards found in {workflow}")
    return shards


def validate_shards(
    class_counts: dict[str, int],
    shards: dict[str, list[str]],
    max_delta: int,
) -> ShardReport:
    """Validate exact membership and test-count balance."""
    assignments = [
        class_name
        for classes in shards.values()
        for class_name in classes
    ]
    assignment_counts = Counter(assignments)
    actual = set(class_counts)
    assigned = set(assignments)

    problems: list[str] = []
    missing = sorted(actual - assigned)
    if missing:
        problems.append("unassigned UI test classes: " + ", ".join(missing))

    unknown = sorted(assigned - actual)
    if unknown:
        problems.append("unknown UI test classes: " + ", ".join(unknown))

    duplicates = sorted(
        class_name
        for class_name, count in assignment_counts.items()
        if count > 1
    )
    if duplicates:
        problems.append(
            "multiply assigned UI test classes: " + ", ".join(duplicates)
        )

    shard_counts = {
        shard: sum(class_counts.get(class_name, 0) for class_name in classes)
        for shard, classes in shards.items()
    }
    if shard_counts:
        delta = max(shard_counts.values()) - min(shard_counts.values())
        if delta > max_delta:
            formatted = ", ".join(
                f"{name}={count}"
                for name, count in shard_counts.items()
            )
            problems.append(
                f"shard test-count delta {delta} exceeds {max_delta}: "
                + formatted
            )

    if problems:
        raise ShardValidationError("\n".join(problems))
    return ShardReport(class_counts, shard_counts)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests-dir", type=Path, required=True)
    parser.add_argument("--workflow", type=Path, required=True)
    parser.add_argument("--max-delta", type=int, default=3)
    args = parser.parse_args()
    if args.max_delta < 0:
        parser.error("--max-delta must be non-negative")
    return args


def main() -> int:
    args = parse_args()
    try:
        report = validate_shards(
            discover_test_classes(args.tests_dir),
            parse_shards(args.workflow),
            args.max_delta,
        )
    except (OSError, ShardValidationError) as error:
        print(f"::error::{error}")
        return 1

    counts = ", ".join(
        f"{name}={count}"
        for name, count in report.shard_counts.items()
    )
    print(
        f"Validated {len(report.class_counts)} UI test classes and "
        f"{report.total_tests} tests; delta={report.delta} ({counts})."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
