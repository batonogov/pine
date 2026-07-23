#!/usr/bin/env python3
"""Extract and enforce Pine's logic-only code-coverage threshold.

The check is deliberately fail-closed. Missing result bundles, xccov
failures, malformed reports, missing application coverage, and reports with
zero executable logic lines are infrastructure failures rather than a reason
to skip the coverage gate.
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


THRESHOLD_FAILURE = 1
INFRASTRUCTURE_FAILURE = 2
TRANSIENT_XCCOV_DIAGNOSTICS = ("no coverage data in result bundle",)

# Pure SwiftUI/AppKit presentation files are exercised by the UI-test shards
# and intentionally remain outside the logic-only unit-test threshold.
EXCLUDED_VIEWS = frozenset(
    {
        "AccessibilityIdentifiers.swift",
        "BranchSubtitleClickHandler.swift",
        "BranchSwitcherView.swift",
        "CodeEditorView.swift",
        "ContentView.swift",
        "ContentView+Helpers.swift",
        "EditorTabBar.swift",
        "FileNodeRow.swift",
        "GitAndNotificationObserver.swift",
        "MarkdownPreviewView.swift",
        "PaneLeafView.swift",
        "PaneTreeView.swift",
        "QuickLookPreviewView.swift",
        "QuickOpenView.swift",
        "RecoveryDialogView.swift",
        "RepresentedFileTracker.swift",
        "SearchResultsView.swift",
        "SidebarFileTree.swift",
        "SidebarView.swift",
        "StatusBarView.swift",
        "TerminalBarView.swift",
        "TerminalPaneContent.swift",
        "TerminalPaneTabBar.swift",
        "TerminalSearchBar.swift",
        "WelcomeView.swift",
    }
)


class CoverageError(Exception):
    """Raised when coverage cannot be proven from the current result bundle."""


@dataclass(frozen=True)
class FileCoverage:
    """Line coverage for one source file."""

    name: str
    covered_lines: int
    executable_lines: int

    @property
    def percentage(self) -> float:
        if self.executable_lines == 0:
            return 0.0
        return self.covered_lines / self.executable_lines * 100


@dataclass(frozen=True)
class CoverageSummary:
    """Validated logic-only coverage totals and per-file details."""

    covered_lines: int
    executable_lines: int
    included_files: tuple[FileCoverage, ...]
    excluded_files: tuple[FileCoverage, ...]

    @property
    def percentage(self) -> float:
        return self.covered_lines / self.executable_lines * 100


def _nonnegative_line_count(value: Any, field: str, filename: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise CoverageError(
            f"{filename} has invalid {field}: expected a non-negative integer"
        )
    return value


def summarize_coverage(
    report: Any,
    target_name: str = "Pine.app",
) -> CoverageSummary:
    """Validate an xccov JSON report and calculate logic-only totals."""
    if not isinstance(report, dict):
        raise CoverageError("xccov returned a non-object JSON root")

    targets = report.get("targets")
    if not isinstance(targets, list) or not targets:
        raise CoverageError("xccov report contains no coverage targets")

    matching_targets = [
        target
        for target in targets
        if isinstance(target, dict) and target.get("name") == target_name
    ]
    if not matching_targets:
        raise CoverageError(f"xccov report is missing target {target_name}")
    if len(matching_targets) > 1:
        raise CoverageError(f"xccov report contains duplicate target {target_name}")

    files = matching_targets[0].get("files")
    if not isinstance(files, list) or not files:
        raise CoverageError(f"target {target_name} contains no file coverage")

    included: list[FileCoverage] = []
    excluded: list[FileCoverage] = []
    for index, file_report in enumerate(files):
        if not isinstance(file_report, dict):
            raise CoverageError(
                f"target {target_name} contains a non-object file entry "
                f"at index {index}"
            )

        raw_name = file_report.get("name")
        if not isinstance(raw_name, str) or not raw_name.strip():
            raise CoverageError(
                f"target {target_name} contains a file entry without a name"
            )
        name = Path(raw_name).name
        covered = _nonnegative_line_count(
            file_report.get("coveredLines"),
            "coveredLines",
            name,
        )
        executable = _nonnegative_line_count(
            file_report.get("executableLines"),
            "executableLines",
            name,
        )
        if covered > executable:
            raise CoverageError(
                f"{name} reports more covered lines than executable lines"
            )

        file_coverage = FileCoverage(name, covered, executable)
        if name in EXCLUDED_VIEWS:
            excluded.append(file_coverage)
        else:
            included.append(file_coverage)

    covered_lines = sum(file.covered_lines for file in included)
    executable_lines = sum(file.executable_lines for file in included)
    if executable_lines == 0:
        raise CoverageError(
            f"target {target_name} reports zero executable logic lines"
        )

    return CoverageSummary(
        covered_lines=covered_lines,
        executable_lines=executable_lines,
        included_files=tuple(included),
        excluded_files=tuple(excluded),
    )


def _is_transient_xccov_failure(diagnostic: str) -> bool:
    lowered = diagnostic.lower()
    return any(
        marker in lowered for marker in TRANSIENT_XCCOV_DIAGNOSTICS
    )


def load_coverage_report(
    result_bundle: Path,
    attempts: int,
    retry_delay: float,
    timeout: float,
) -> Any:
    """Run xccov with bounded retries for its known transient diagnostic."""
    if not result_bundle.is_dir():
        raise CoverageError(f"result bundle does not exist: {result_bundle}")

    last_diagnostic = "no diagnostic output"
    for attempt in range(1, attempts + 1):
        try:
            process = subprocess.run(
                [
                    "xcrun",
                    "xccov",
                    "view",
                    "--report",
                    "--json",
                    str(result_bundle),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            raise CoverageError(
                f"xccov timed out after {format_percentage(timeout)} seconds"
            ) from error
        except OSError as error:
            raise CoverageError(f"unable to launch xccov: {error}") from error

        if process.returncode == 0:
            try:
                return json.loads(process.stdout)
            except json.JSONDecodeError as error:
                raise CoverageError(
                    f"xccov returned malformed JSON: {error}"
                ) from error

        last_diagnostic = (
            process.stderr.strip()
            or process.stdout.strip()
            or "no diagnostic output"
        )
        should_retry = (
            attempt < attempts
            and _is_transient_xccov_failure(last_diagnostic)
        )
        if not should_retry:
            raise CoverageError(
                f"xccov exited with code {process.returncode}: "
                f"{last_diagnostic}"
            )
        if retry_delay:
            time.sleep(retry_delay)

    raise CoverageError(
        f"xccov failed after {attempts} attempts: {last_diagnostic}"
    )


def format_percentage(value: float) -> str:
    """Render enough precision to keep threshold-edge results unambiguous."""
    rendered = f"{value:.4f}".rstrip("0").rstrip(".")
    return rendered if "." in rendered else f"{rendered}.0"


def _single_line(value: str) -> str:
    return " ".join(value.splitlines()).strip()


def append_github_output(path: Path, values: dict[str, str]) -> None:
    """Append single-line step outputs for later workflow steps."""
    with path.open("a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={_single_line(value)}\n")


def _coverage_markdown(
    summary: CoverageSummary,
    threshold: float,
    passed: bool,
) -> str:
    percentage = format_percentage(summary.percentage)
    icon = "✅" if passed else "❌"
    lines = [
        f"## {icon} Code Coverage: {percentage}%",
        "",
        (
            f"Logic-only coverage: **{summary.covered_lines} / "
            f"{summary.executable_lines} lines**"
        ),
        f"Required threshold: **{format_percentage(threshold)}%**",
        "",
    ]

    measurable = [
        file for file in summary.included_files if file.executable_lines > 0
    ]
    measurable.sort(key=lambda file: (file.percentage, file.name))
    if measurable:
        lines.extend(
            [
                "### Lowest Coverage Files (logic only)",
                "",
                "| File | Coverage | Lines |",
                "|------|---------:|------:|",
            ]
        )
        for file in measurable[:10]:
            lines.append(
                f"| {file.name} | {format_percentage(file.percentage)}% | "
                f"{file.covered_lines}/{file.executable_lines} |"
            )

        lines.extend(
            [
                "",
                "### Highest Coverage Files",
                "",
                "| File | Coverage | Lines |",
                "|------|---------:|------:|",
            ]
        )
        for file in measurable[-10:]:
            lines.append(
                f"| {file.name} | {format_percentage(file.percentage)}% | "
                f"{file.covered_lines}/{file.executable_lines} |"
            )

    if summary.excluded_files:
        excluded_lines = sum(
            file.executable_lines for file in summary.excluded_files
        )
        lines.extend(
            [
                "",
                (
                    f"_Excluded from threshold: {len(summary.excluded_files)} "
                    "pure SwiftUI/AppKit presentation files "
                    f"({excluded_lines} lines), covered by UI tests._"
                ),
            ]
        )

    lines.append("")
    return "\n".join(lines)


def append_summary(path: Path, markdown: str) -> None:
    with path.open("a", encoding="utf-8") as summary_file:
        summary_file.write(markdown)


def _publish_error(args: argparse.Namespace, message: str) -> None:
    values = {
        "status": "error",
        "coverage": "",
        "covered-lines": "",
        "executable-lines": "",
        "message": message,
    }
    if args.github_output:
        try:
            append_github_output(args.github_output, values)
        except OSError as error:
            print(f"::warning::Unable to write GITHUB_OUTPUT: {error}")

    if args.github_summary:
        markdown = "\n".join(
            [
                "## ❌ Code Coverage unavailable",
                "",
                f"Coverage infrastructure failure: {_single_line(message)}",
                "",
                "The coverage gate failed closed; no passing result was reported.",
                "",
            ]
        )
        try:
            append_summary(args.github_summary, markdown)
        except OSError as error:
            print(f"::warning::Unable to write GITHUB_STEP_SUMMARY: {error}")


def _positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return parsed


def _nonnegative_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed < 0:
        raise argparse.ArgumentTypeError(
            "must be a finite non-negative number"
        )
    return parsed


def _positive_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError(
            "must be a finite number greater than zero"
        )
    return parsed


def _threshold(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or not 0 <= parsed <= 100:
        raise argparse.ArgumentTypeError("must be between 0 and 100")
    return parsed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_bundle", type=Path)
    parser.add_argument("--threshold", type=_threshold, required=True)
    parser.add_argument("--target", default="Pine.app")
    parser.add_argument("--attempts", type=_positive_integer, default=3)
    parser.add_argument(
        "--retry-delay",
        type=_nonnegative_float,
        default=1.0,
    )
    parser.add_argument(
        "--timeout",
        type=_positive_float,
        default=60.0,
        help="Maximum seconds for one xccov attempt.",
    )
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--github-summary", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        report = load_coverage_report(
            args.result_bundle,
            attempts=args.attempts,
            retry_delay=args.retry_delay,
            timeout=args.timeout,
        )
        summary = summarize_coverage(report, target_name=args.target)
    except CoverageError as error:
        message = str(error)
        _publish_error(args, message)
        print(f"::error::Coverage infrastructure failure: {message}")
        return INFRASTRUCTURE_FAILURE

    passed = summary.percentage >= args.threshold
    percentage = format_percentage(summary.percentage)
    status = "pass" if passed else "below-threshold"
    message = (
        "Coverage is at or above the required threshold."
        if passed
        else "Coverage is below the required threshold."
    )
    outputs = {
        "status": status,
        "coverage": percentage,
        "covered-lines": str(summary.covered_lines),
        "executable-lines": str(summary.executable_lines),
        "message": message,
    }
    if args.github_output:
        try:
            append_github_output(args.github_output, outputs)
        except OSError as error:
            _publish_error(args, f"unable to write GITHUB_OUTPUT: {error}")
            print(f"::error::Unable to publish coverage outputs: {error}")
            return INFRASTRUCTURE_FAILURE

    if args.github_summary:
        try:
            append_summary(
                args.github_summary,
                _coverage_markdown(summary, args.threshold, passed),
            )
        except OSError as error:
            print(f"::warning::Unable to write GITHUB_STEP_SUMMARY: {error}")

    print(
        f"Coverage: {percentage}% "
        f"({summary.covered_lines}/{summary.executable_lines} logic lines); "
        f"threshold: {format_percentage(args.threshold)}%"
    )
    if not passed:
        print(
            f"::error::Coverage {percentage}% is below "
            f"{format_percentage(args.threshold)}% threshold"
        )
        return THRESHOLD_FAILURE
    return 0


if __name__ == "__main__":
    sys.exit(main())
