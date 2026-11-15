"""Assessor-only oracle and reference stages; never distribute with the task."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
HEADER = "event_id,kind,amount\n"
DECIMAL = '''def total(rows):
    return format(sum((amount for _, kind, amount in rows if kind == "sale"), Decimal("0.00")), ".2f")


'''
NET = '''def total(rows):
    seen = set()
    result = Decimal("0.00")
    for event_id, kind, amount in rows:
        if event_id not in seen:
            seen.add(event_id)
            result += amount if kind == "sale" else -amount
    return format(result, ".2f")


'''


def reference(stage):
    source = (ROOT / "report.py").read_text(encoding="utf-8")
    before, marker, rest = source.partition("def total(rows):\n")
    _, end, after = rest.partition("def main():\n")
    if not marker or not end:
        raise ValueError("seed function boundaries changed")
    return before + {"decimal": DECIMAL, "net": NET}[stage] + end + after


def run(candidate, directory, text=None):
    source = directory / "input.csv"
    if text is not None:
        source.write_text(text, encoding="utf-8")
    return subprocess.run(
        [sys.executable, "-I", "-B", "-X", "utf8", str(candidate), str(source)],
        cwd=directory, capture_output=True, text=True, timeout=5,
    )


def assess(candidate, stage):
    # Literal expected outputs do not call the candidate or reference arithmetic.
    cases = [
        ("precision", HEADER + "A,sale,0.10\nB,sale,0.20\n", "0.30"),
        ("empty", HEADER, "0.00"),
        ("whole", HEADER + "A,sale,10.00\n", "10.00"),
        ("large", HEADER + "A,sale,999999999.99\nB,sale,0.01\n", "1000000000.00"),
    ]
    if stage == "first":
        cases.append(("gross", (ROOT / "syntheticorders.csv").read_text(), "0.50"))
    else:
        cases.extend([
            ("net", (ROOT / "syntheticorders.csv").read_text(), "0.25"),
            ("negative", HEADER + "R,refund,1.25\n", "-1.25"),
            ("repeat-refund", HEADER + "R,refund,0.05\nR,refund,0.05\n", "-0.05"),
            ("distinct-equal-sales", HEADER + "A,sale,0.10\nB,sale,0.10\n", "0.20"),
            ("zero", HEADER + "A,sale,0.10\nR,refund,0.10\n", "0.00"),
        ])
    invalid = [
        ("header", "id,kind,amount\n", "expected header"),
        ("fields", HEADER + "A,sale\n", "expected three fields"),
        ("extra-field", HEADER + "A,sale,1.00,extra\n", "expected three fields"),
        ("event-id", HEADER + "../A,sale,1.00\n", "invalid event_id"),
        ("kind", HEADER + "A,charge,1.00\n", "invalid kind"),
        ("nan", HEADER + "A,sale,NaN\n", "invalid amount"),
        ("infinity", HEADER + "A,sale,Infinity\n", "invalid amount"),
        ("negative-input", HEADER + "A,sale,-1.00\n", "invalid amount"),
        ("fraction", HEADER + "A,sale,0.001\n", "invalid amount"),
        ("exponent", HEADER + "A,sale,1e2\n", "invalid amount"),
        ("too-large", HEADER + "A,sale,1000000000.00\n", "invalid amount"),
        ("conflict", HEADER + "A,sale,0.10\nA,sale,0.20\n", "conflicting event_id"),
        ("kind-conflict", HEADER + "A,sale,0.10\nA,refund,0.10\n", "conflicting event_id"),
        ("csv", HEADER + '"A,sale,1.00\n', "unexpected end of data"),
        ("encoding", None, "error:"),
        ("missing", None, "error:"),
    ]
    failures = []
    with tempfile.TemporaryDirectory(prefix="pine-1762-oracle-") as name:
        directory = Path(name)
        for label, text, total in cases:
            result = run(candidate, directory, text)
            expected = '{"currency":"EUR","total":"' + total + '"}\n'
            if (result.returncode, result.stdout, result.stderr) != (0, expected, ""):
                failures.append(label)
        for label, text, diagnostic in invalid:
            if label == "encoding":
                (directory / "input.csv").write_bytes(b"\xff")
            elif label == "missing":
                (directory / "input.csv").unlink()
            result = run(candidate, directory, text)
            if result.returncode != 2 or result.stdout or diagnostic not in result.stderr:
                failures.append(label)
    return failures


class BenchmarkSelfTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="pine-1762-reference-")
        self.addCleanup(self.directory.cleanup)

    def candidate(self, stage):
        path = Path(self.directory.name) / "report.py"
        path.write_text(reference(stage), encoding="utf-8")
        return path

    def test_seed_is_red(self):
        self.assertEqual(assess(ROOT / "report.py", "first"),
                         ["precision", "empty", "whole", "large", "gross"])

    def test_decimal_stage_is_green(self):
        self.assertEqual(assess(self.candidate("decimal"), "first"), [])

    def test_old_checks_miss_new_requirement(self):
        candidate = self.candidate("decimal")
        self.assertEqual(assess(candidate, "first"), [])
        self.assertEqual(assess(candidate, "final"), ["net", "negative", "repeat-refund", "zero"])

    def test_net_stage_is_green(self):
        self.assertEqual(assess(self.candidate("net"), "final"), [])

    def test_repeated_output_is_identical(self):
        candidate = self.candidate("net")
        directory = Path(self.directory.name)
        text = (ROOT / "syntheticorders.csv").read_text()
        results = [run(candidate, directory, text) for _ in range(3)]
        self.assertEqual([(r.returncode, r.stdout, r.stderr) for r in results],
                         [(0, '{"currency":"EUR","total":"0.25"}\n', "")] * 3)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, help="reviewed local script to execute")
    parser.add_argument("--stage", choices=("first", "final"), default="first")
    args = parser.parse_args()
    if args.candidate:
        failures = assess(args.candidate.resolve(), args.stage)
        print("FAIL: " + ", ".join(failures) if failures else "PASS: " + args.stage)
        sys.exit(bool(failures))
    unittest.main(argv=[sys.argv[0]], verbosity=2)
