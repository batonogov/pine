#!/usr/bin/env python3
"""Compare performance test results against baselines and detect regressions.

Usage:
    python3 check_perf_regression.py <baselines.json> <xcresult_path>

Exit code 0: all benchmarks within threshold.
Exit code 1: at least one regression detected.

The script outputs a markdown report to stdout suitable for GITHUB_STEP_SUMMARY.
"""

import json
import subprocess
import sys
from dataclasses import dataclass


@dataclass
class RegressionResult:
    """Result of comparing one test against its baseline."""

    test_name: str
    baseline_seconds: float
    actual_seconds: float
    change_percent: float
    threshold_percent: float
    is_regression: bool
    description: str


def load_baselines(path: str) -> dict:
    """Load baselines from a JSON file.

    Expected format:
    {
        "threshold_percent": 15,
        "tests": {
            "TestClass/testMethod": {
                "baseline_seconds": 0.005,
                "description": "..."
            }
        }
    }
    """
    with open(path) as fh:
        try:
            return json.load(fh)
        except json.JSONDecodeError as exc:
            print(f"Error: invalid JSON in {path}: {exc}", file=sys.stderr)
            sys.exit(2)


def extract_test_durations(xcresult_path: str) -> dict[str, float]:
    """Extract average durations from xcresult using xcresulttool.

    Returns a dict mapping "TestClass/testMethod" to average duration in seconds.
    """
    try:
        output = subprocess.check_output(
            [
                "xcrun", "xcresulttool", "get", "test-results", "tests",
                "--path", xcresult_path,
                "--compact",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        data = json.loads(output)
    except (subprocess.CalledProcessError, json.JSONDecodeError, FileNotFoundError):
        return {}

    durations: dict[str, float] = {}
    _walk_test_nodes(data, durations)
    return durations


def _walk_test_nodes(node: object, durations: dict[str, float], parent: str = "") -> None:
    """Recursively walk test result nodes to extract durations."""
    if isinstance(node, list):
        for item in node:
            _walk_test_nodes(item, durations, parent)
        return
    if not isinstance(node, dict):
        return

    node_type = node.get("nodeType", "")
    name = node.get("name", "")

    if node_type == "Test Case" and "duration" in node:
        # Build key as "TestClass/testMethod"
        key = f"{parent}/{name}" if parent else name
        # Remove parentheses from method names: "testFoo()" -> "testFoo"
        key = key.replace("()", "")
        try:
            durations[key] = float(node["duration"])
        except (ValueError, TypeError):
            pass

    for child in node.get("children", []):
        next_parent = name if node_type == "Test Suite" else parent
        _walk_test_nodes(child, durations, next_parent)


def compare_results(
    baselines: dict, actual: dict[str, float]
) -> list[RegressionResult]:
    """Compare actual test durations against baselines.

    Only tests present in both baselines and actual are compared.
    """
    threshold = baselines.get("threshold_percent", 15)
    results: list[RegressionResult] = []

    for test_name, info in baselines.get("tests", {}).items():
        if test_name not in actual:
            continue

        baseline_val = info["baseline_seconds"]
        actual_val = actual[test_name]

        if baseline_val <= 0:
            # Zero baseline: any positive actual is a regression
            change_pct = float("inf") if actual_val > 0 else 0.0
            is_regression = actual_val > 0
        else:
            change_pct = ((actual_val - baseline_val) / baseline_val) * 100
            is_regression = change_pct > threshold

        results.append(
            RegressionResult(
                test_name=test_name,
                baseline_seconds=baseline_val,
                actual_seconds=actual_val,
                change_percent=round(change_pct, 1),
                threshold_percent=threshold,
                is_regression=is_regression,
                description=info.get("description", ""),
            )
        )

    results.sort(key=lambda r: (-r.is_regression, -r.change_percent))
    return results


def format_markdown_report(results: list[RegressionResult]) -> str:
    """Generate a markdown report from comparison results."""
    if not results:
        return "## Performance Baseline Comparison\n\nNo baseline comparisons available.\n"

    regressions = [r for r in results if r.is_regression]
    lines: list[str] = ["## Performance Baseline Comparison\n"]

    if regressions:
        lines.append(
            f"**REGRESSION DETECTED:** {len(regressions)} regression(s) "
            f"exceeded the {results[0].threshold_percent}% threshold.\n"
        )
    else:
        lines.append(
            f"All benchmarks within threshold "
            f"({results[0].threshold_percent}%).\n"
        )

    lines.append("| Test | Baseline | Actual | Change | Status |")
    lines.append("|------|----------|--------|--------|--------|")

    for r in results:
        status = "REGRESSION" if r.is_regression else "OK"
        if r.change_percent == float("inf"):
            change_str = "N/A (baseline=0)"
        else:
            sign = "+" if r.change_percent > 0 else ""
            change_str = f"{sign}{r.change_percent}%"
        lines.append(
            f"| {r.test_name} "
            f"| {r.baseline_seconds:.4f}s "
            f"| {r.actual_seconds:.4f}s "
            f"| {change_str} "
            f"| {status} |"
        )

    lines.append("")
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <baselines.json> <xcresult_path>", file=sys.stderr)
        return 2

    baselines_path = sys.argv[1]
    xcresult_path = sys.argv[2]

    baselines = load_baselines(baselines_path)
    actual = extract_test_durations(xcresult_path)

    if not actual:
        print("Warning: no test durations extracted from xcresult", file=sys.stderr)

    results = compare_results(baselines, actual)
    report = format_markdown_report(results)
    print(report)

    regressions = [r for r in results if r.is_regression]
    return 1 if regressions else 0


if __name__ == "__main__":
    sys.exit(main())
