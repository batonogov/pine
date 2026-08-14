#!/usr/bin/env python3
"""Render Pine lifecycle-soak JSON as a CI summary and regression signal."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def mib(value: int | None) -> str:
    if value is None:
        return "n/a"
    return f"{value / 1_048_576:.1f} MiB"


def render(report: dict | None, test_outcome: str) -> tuple[str, bool, bool]:
    hard_failures = list((report or {}).get("hardFailures", []))
    trend_warnings = list((report or {}).get("trendWarnings", []))
    incomplete = bool(
        report is not None
        and (
            report.get("completedCycles") != report.get("requestedCycles")
            or report.get("final") is None
        )
    )
    has_regression = (
        test_outcome != "success"
        or report is None
        or bool(hard_failures)
        or incomplete
    )
    has_trend = bool(trend_warnings)

    lines = [
        "## Lifecycle resource soak",
        "",
        "| Metric | Value |",
        "|---|---:|",
        f"| Test outcome | {test_outcome} |",
    ]
    if report is None:
        lines.append("| Report | missing |")
    else:
        baseline = report.get("baseline") or {}
        final = report.get("final") or {}
        samples = report.get("samples") or []
        lifecycle_cpu = sum(
            sample.get("cpuSeconds", 0)
            for sample in samples
            if isinstance(sample.get("cpuSeconds", 0), (int, float))
        )
        automatic_cycles = sum(
            sample.get("rendererRequested") == "automatic"
            for sample in samples
        )
        metal_cycles = sum(
            sample.get("rendererEffective") == "metal"
            for sample in samples
        )
        recreated_cycles = sum(
            sample.get("rendererRecreationSucceeded") is True
            for sample in samples
        )
        lines.extend([
            f"| Fixed seed | {report.get('seed', 'n/a')} |",
            (
                "| Completed cycles | "
                f"{report.get('completedCycles', 0)} / "
                f"{report.get('requestedCycles', 0)} |"
            ),
            f"| Peak resident memory | {mib(report.get('peakResidentBytes'))} |",
            f"| Baseline resident memory | {mib(baseline.get('residentBytes'))} |",
            f"| Settled resident memory | {mib(final.get('residentBytes'))} |",
            f"| Lifecycle CPU seconds | {lifecycle_cpu:.3f} |",
            f"| Automatic renderer cycles | {automatic_cycles} |",
            f"| Effective Metal cycles | {metal_cycles} |",
            f"| Successful Metal recreations | {recreated_cycles} |",
            f"| Settled descriptors | {final.get('descriptorCount', 'n/a')} |",
            f"| Settled PTYs | {final.get('pseudoTerminalCount', 'n/a')} |",
            f"| Settled children | {len(final.get('children', []))} |",
            f"| Idle CPU seconds | {report.get('idleCPUSeconds', 'n/a')} |",
            f"| Hard failures | {len(hard_failures)} |",
            f"| Trend warnings | {len(trend_warnings)} |",
        ])

    if hard_failures:
        lines.extend(["", "### Hard leak failures", ""])
        lines.extend(f"- {failure}" for failure in hard_failures[:20])
    if incomplete:
        lines.extend([
            "",
            "### Incomplete run",
            "",
            "The test process did not finish every configured cycle and steady-state sample.",
        ])
    if trend_warnings:
        lines.extend(["", "### Noisy trends", ""])
        lines.extend(f"- {warning}" for warning in trend_warnings[:20])
    if report is None:
        lines.extend([
            "",
            "The structured report was not produced; inspect the xcresult and job log.",
        ])

    return "\n".join(lines) + "\n", has_regression, has_trend


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument(
        "--test-outcome",
        choices=("success", "failure", "cancelled", "skipped"),
        required=True,
    )
    parser.add_argument("--github-output", type=Path)
    arguments = parser.parse_args()

    report = None
    if arguments.report.is_file():
        report = json.loads(arguments.report.read_text(encoding="utf-8"))
    summary, has_regression, has_trend = render(report, arguments.test_outcome)
    print(summary, end="")

    if arguments.github_output:
        with arguments.github_output.open("a", encoding="utf-8") as output:
            output.write(f"has_regression={str(has_regression).lower()}\n")
            output.write(f"has_trend={str(has_trend).lower()}\n")
            output.write(f"report_present={str(report is not None).lower()}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
