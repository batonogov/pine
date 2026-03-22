#!/usr/bin/env python3
"""Detect flaky tests from xcresult bundle.

A flaky test is one that failed on the first attempt but passed on retry.
Uses `xcrun xcresulttool get test-results tests` to extract test results.

Usage:
    python3 detect_flaky_tests.py <path-to.xcresult> [--json] [--github-summary]

Exit codes:
    0 — no flaky tests found
    1 — flaky tests detected (outputs list)
    2 — error (missing xcresult, tool failure, etc.)
"""

import json
import os
import subprocess
import sys
from dataclasses import dataclass


@dataclass
class FlakyTest:
    suite: str
    name: str
    failed_runs: int
    total_runs: int


def get_test_results(xcresult_path: str) -> dict:
    """Extract test results JSON from xcresult bundle."""
    result = subprocess.run(
        [
            "xcrun", "xcresulttool", "get", "test-results", "tests",
            "--path", xcresult_path,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"Error: xcresulttool failed: {result.stderr}", file=sys.stderr)
        sys.exit(2)
    return json.loads(result.stdout)


def find_flaky_tests(node: dict, suite_path: str = "") -> list[FlakyTest]:
    """Recursively walk test nodes to find flaky tests.

    A test is flaky if its overall result is 'Passed' but it has
    child repetitions where at least one 'Failed'.
    """
    flaky = []
    node_type = node.get("nodeType", "")
    name = node.get("name", "")
    children = node.get("children", [])

    if node_type == "Test Case":
        result = node.get("result", "")
        # A retried test has repetition children
        repetitions = [
            c for c in children
            if c.get("nodeType", "") == "Test Repetition"
        ]
        if result == "Passed" and repetitions:
            failed_runs = sum(
                1 for r in repetitions if r.get("result", "") == "Failed"
            )
            if failed_runs > 0:
                flaky.append(FlakyTest(
                    suite=suite_path,
                    name=name,
                    failed_runs=failed_runs,
                    total_runs=len(repetitions),
                ))
    else:
        current_path = f"{suite_path}/{name}" if suite_path else name
        if node_type in ("Test Plan", ""):
            current_path = suite_path
        for child in children:
            flaky.extend(find_flaky_tests(child, current_path))

    return flaky


def format_markdown(flaky_tests: list[FlakyTest]) -> str:
    """Format flaky test results as Markdown."""
    lines = [
        "### Flaky Tests Detected",
        "",
        "These tests failed initially but passed on retry:",
        "",
        "| Test Suite | Test Name | Failed Runs |",
        "|------------|-----------|-------------|",
    ]
    for test in sorted(flaky_tests, key=lambda t: (t.suite, t.name)):
        lines.append(
            f"| {test.suite} | {test.name} "
            f"| {test.failed_runs}/{test.total_runs} |"
        )
    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <xcresult-path> [--json] [--github-summary]",
              file=sys.stderr)
        sys.exit(2)

    xcresult_path = sys.argv[1]
    output_json = "--json" in sys.argv
    github_summary = "--github-summary" in sys.argv

    if not os.path.isdir(xcresult_path):
        print(f"Error: xcresult not found: {xcresult_path}", file=sys.stderr)
        sys.exit(2)

    data = get_test_results(xcresult_path)
    flaky_tests = find_flaky_tests(data)

    if not flaky_tests:
        print("No flaky tests detected.")
        return

    count = len(flaky_tests)
    print(f"Found {count} flaky test(s):")

    if output_json:
        result = [
            {
                "suite": t.suite,
                "name": t.name,
                "failed_runs": t.failed_runs,
                "total_runs": t.total_runs,
            }
            for t in flaky_tests
        ]
        print(json.dumps(result, indent=2))
    else:
        for test in flaky_tests:
            print(f"  - {test.suite}/{test.name} "
                  f"(failed {test.failed_runs}/{test.total_runs} runs)")

    if github_summary:
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY", "")
        if summary_path:
            with open(summary_path, "a") as f:
                f.write("\n" + format_markdown(flaky_tests) + "\n")

        output_path = os.environ.get("GITHUB_OUTPUT", "")
        if output_path:
            with open(output_path, "a") as f:
                f.write(f"flaky-count={count}\n")
                names = ", ".join(
                    f"{t.suite}/{t.name}" for t in flaky_tests
                )
                f.write(f"flaky-tests={names}\n")

    sys.exit(1)


if __name__ == "__main__":
    main()
