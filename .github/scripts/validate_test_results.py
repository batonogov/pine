#!/usr/bin/env python3
"""Validate that an xcodebuild invocation really executed and passed tests.

The validator is deliberately fail-closed. A successful validation requires:

* a result bundle created during the current invocation;
* xcresulttool output that can be parsed;
* at least one executed test with a recognized terminal result;
* no final test failures; and
* a zero xcodebuild exit status.

When xcodebuild fails, its original exit status is preserved even if the
result bundle contains no final test failures.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


VALIDATION_ERROR = 2


class ResultValidationError(Exception):
    """Raised when an xcresult bundle cannot prove a successful test run."""


@dataclass(frozen=True)
class TestSummary:
    """Terminal test-case counts from an xcresult test tree."""

    executed: int = 0
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    retried: int = 0
    unknown: int = 0

    def __add__(self, other: "TestSummary") -> "TestSummary":
        return TestSummary(
            executed=self.executed + other.executed,
            passed=self.passed + other.passed,
            failed=self.failed + other.failed,
            skipped=self.skipped + other.skipped,
            retried=self.retried + other.retried,
            unknown=self.unknown + other.unknown,
        )


def summarize_test_results(node: Any) -> TestSummary:
    """Recursively summarize test cases without counting retry attempts twice."""
    if isinstance(node, list):
        summary = TestSummary()
        for child in node:
            summary += summarize_test_results(child)
        return summary

    if not isinstance(node, dict):
        return TestSummary()

    if node.get("nodeType") == "Test Case":
        result = node.get("result")
        repetitions = [
            child
            for child in node.get("children", [])
            if isinstance(child, dict)
            and child.get("nodeType") == "Repetition"
        ]
        retried = int(len(repetitions) > 1)

        if result in {"Passed", "Expected Failure"}:
            return TestSummary(executed=1, passed=1, retried=retried)
        if result == "Failed":
            return TestSummary(executed=1, failed=1, retried=retried)
        if result == "Skipped":
            return TestSummary(skipped=1, retried=retried)
        return TestSummary(executed=1, retried=retried, unknown=1)

    summary = TestSummary()
    for key in ("children", "testNodes"):
        children = node.get(key, [])
        if isinstance(children, list):
            summary += summarize_test_results(children)
    return summary


def load_test_results(result_bundle: Path) -> dict[str, Any]:
    """Run xcresulttool and return the parsed test tree."""
    process = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "tests",
            "--path",
            str(result_bundle),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if process.returncode != 0:
        detail = process.stderr.strip() or "no diagnostic output"
        raise ResultValidationError(
            f"xcresulttool exited with code {process.returncode}: {detail}"
        )

    try:
        data = json.loads(process.stdout)
    except json.JSONDecodeError as error:
        raise ResultValidationError(
            f"xcresulttool returned invalid JSON: {error}"
        ) from error

    if not isinstance(data, dict):
        raise ResultValidationError("xcresulttool returned a non-object root")
    return data


def validate_bundle(
    result_bundle: Path,
    started_at: float,
) -> TestSummary:
    """Validate bundle freshness and terminal test results."""
    if not result_bundle.is_dir():
        raise ResultValidationError(
            f"result bundle does not exist: {result_bundle}"
        )

    modified_at = result_bundle.stat().st_mtime
    if modified_at < started_at:
        raise ResultValidationError(
            "result bundle predates the current xcodebuild invocation "
            f"(mtime={modified_at:.6f}, started_at={started_at:.6f})"
        )

    summary = summarize_test_results(load_test_results(result_bundle))
    if summary.executed == 0:
        raise ResultValidationError("result bundle reports zero executed tests")
    if summary.unknown:
        raise ResultValidationError(
            f"result bundle contains {summary.unknown} test(s) "
            "with an unrecognized terminal result"
        )
    return summary


def format_summary(summary: TestSummary) -> str:
    """Return a compact, log-friendly result summary."""
    return (
        f"executed={summary.executed} "
        f"passed={summary.passed} "
        f"failed={summary.failed} "
        f"skipped={summary.skipped} "
        f"retried={summary.retried}"
    )


def append_github_summary(summary: TestSummary) -> None:
    """Append a stable Markdown table when GitHub exposes a summary file."""
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return

    rows = [
        "### Unit test results",
        "",
        "| Executed | Passed | Failed | Skipped | Retried |",
        "|---------:|-------:|-------:|--------:|--------:|",
        (
            f"| {summary.executed} | {summary.passed} | "
            f"{summary.failed} | {summary.skipped} | {summary.retried} |"
        ),
        "",
    ]
    try:
        with open(summary_path, "a", encoding="utf-8") as summary_file:
            summary_file.write("\n".join(rows))
    except OSError as error:
        # Reporting must never replace the xcodebuild/validation exit status.
        print(f"::warning::Unable to write GITHUB_STEP_SUMMARY: {error}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_bundle", type=Path)
    parser.add_argument(
        "--xcodebuild-exit",
        type=int,
        required=True,
        help="Original xcodebuild exit status (0-255).",
    )
    parser.add_argument(
        "--started-at",
        type=float,
        required=True,
        help="Unix timestamp captured immediately before xcodebuild.",
    )
    parser.add_argument(
        "--github-summary",
        action="store_true",
        help="Append counts to GITHUB_STEP_SUMMARY when it is set.",
    )
    args = parser.parse_args()
    if not 0 <= args.xcodebuild_exit <= 255:
        parser.error("--xcodebuild-exit must be between 0 and 255")
    return args


def main() -> int:
    args = parse_args()

    try:
        summary = validate_bundle(args.result_bundle, args.started_at)
    except (OSError, ResultValidationError) as error:
        print(f"::error::Unable to validate unit-test execution: {error}")
        return args.xcodebuild_exit or VALIDATION_ERROR

    print(f"Unit test summary: {format_summary(summary)}")
    if args.github_summary:
        append_github_summary(summary)

    if args.xcodebuild_exit:
        print(
            "::error::xcodebuild exited with code "
            f"{args.xcodebuild_exit}; preserving the original failure"
        )
        return args.xcodebuild_exit

    if summary.failed:
        print(
            f"::error::Result bundle contains {summary.failed} "
            "final test failure(s)"
        )
        return VALIDATION_ERROR

    return 0


if __name__ == "__main__":
    sys.exit(main())
