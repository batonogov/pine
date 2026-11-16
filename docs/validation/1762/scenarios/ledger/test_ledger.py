"""Assessor-only oracle for the three ledger tasks; never distribute with the task."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
CLIS = {
    "t1": "t1_shipments.py",
    "t2": "t2_labels.py",
    "t3": "t3_stock.py",
}
INPUTS = {
    "t1": ("input.csv",),
    "t2": ("input.csv",),
    "t3": ("first.csv", "second.csv"),
}
REFERENCE = {
    "t1": (
        "def aggregate(rows):\n"
        "    return sum(weight for _, weight in rows)\n\n\n"
    ),
    "t2": (
        "def aggregate(rows):\n"
        "    counts = {}\n"
        "    for _, label in rows:\n"
        "        counts[label] = counts.get(label, 0) + 1\n"
        "    return {label: counts[label] for label in sorted(counts)}\n\n\n"
    ),
    "t3": (
        "def aggregate(rows_a, rows_b):\n"
        "    counts = {}\n"
        "    for sku, units in rows_a + rows_b:\n"
        "        counts[sku] = counts.get(sku, 0) + units\n"
        "    return {sku: counts[sku] for sku in sorted(counts)}\n\n\n"
    ),
}
T1_HEADER = "shipment_id,weight_kg\n"
T2_HEADER = "item_id,label\n"
T3_HEADER = "sku,units\n"
FIXTURES = {
    "t1": ((ROOT / "shipments.csv").read_text(encoding="utf-8"),),
    "t2": ((ROOT / "labels.csv").read_text(encoding="utf-8"),),
    "t3": (
        (ROOT / "stock_a.csv").read_text(encoding="utf-8"),
        (ROOT / "stock_b.csv").read_text(encoding="utf-8"),
    ),
}
VALID = {
    "t1": [
        ("fixture", FIXTURES["t1"], '{"total_kg":325}'),
        ("single", (T1_HEADER + "A,1\n",), '{"total_kg":1}'),
        ("repeat-count", (T1_HEADER + "S,4\nS,5\n",), '{"total_kg":9}'),
        ("distinct-equal", (T1_HEADER + "A,7\nB,7\n",), '{"total_kg":14}'),
        ("empty", (T1_HEADER,), '{"total_kg":0}'),
        ("max", (T1_HEADER + "A,99999\n",), '{"total_kg":99999}'),
    ],
    "t2": [
        ("fixture", FIXTURES["t2"], '{"labels":{"Red":1,"blue":1,"red":2}}'),
        ("case-distinct", (T2_HEADER + "I,X\nI,x\n",), '{"labels":{"X":1,"x":1}}'),
        ("repeat-pair", (T2_HEADER + "I,red\nI,red\n",), '{"labels":{"red":2}}'),
        ("empty", (T2_HEADER,), '{"labels":{}}'),
        ("long-label", (T2_HEADER + "I," + "a" * 16 + "\n",),
         '{"labels":{"' + "a" * 16 + '":1}}'),
    ],
    "t3": [
        ("fixture", FIXTURES["t3"], '{"stock":{"K1":10,"K2":8,"K3":7,"K4":0}}'),
        ("disjoint", (T3_HEADER + "A,1\n", T3_HEADER + "B,2\n"),
         '{"stock":{"A":1,"B":2}}'),
        ("within-file-add", (T3_HEADER + "A,1\nA,2\n", T3_HEADER),
         '{"stock":{"A":3}}'),
        ("empty-both", (T3_HEADER, T3_HEADER), '{"stock":{}}'),
        ("zero-unit", (T3_HEADER + "A,0\n", T3_HEADER), '{"stock":{"A":0}}'),
        ("only-b", (T3_HEADER, T3_HEADER + "Z,9\n"), '{"stock":{"Z":9}}'),
    ],
}
INVALID = {
    "t1": [
        ("header", ("shipment,weight_kg\n",), "expected header"),
        ("three-fields", (T1_HEADER + "A,1,9\n",), "expected two fields"),
        ("one-field", (T1_HEADER + "A\n",), "expected two fields"),
        ("bad-id", (T1_HEADER + ".A,1\n",), "invalid shipment_id"),
        ("long-id", (T1_HEADER + "A" * 33 + ",1\n",), "invalid shipment_id"),
        ("zero-weight", (T1_HEADER + "A,0\n",), "out of range"),
        ("big-weight", (T1_HEADER + "A,100000\n",), "invalid weight_kg"),
        ("fractional", (T1_HEADER + "A,1.5\n",), "invalid weight_kg"),
        ("signed", (T1_HEADER + "A,-1\n",), "invalid weight_kg"),
        ("csv", (T1_HEADER + '"A,1\n',), "unexpected end of data"),
        ("encoding", (b"\xff",), "error:"),
        ("missing", (None,), "error:"),
    ],
    "t2": [
        ("header", ("item,label\n",), "expected header"),
        ("one-field", (T2_HEADER + "I\n",), "expected two fields"),
        ("three-fields", (T2_HEADER + "I,red,x\n",), "expected two fields"),
        ("bad-item", (T2_HEADER + ".I,red\n",), "invalid item_id"),
        ("empty-label", (T2_HEADER + "I,\n",), "invalid label"),
        ("long-label", (T2_HEADER + "I," + "a" * 17 + "\n",), "invalid label"),
        ("label-dot", (T2_HEADER + "I,a.b\n",), "invalid label"),
        ("csv", (T2_HEADER + '"I,red\n',), "unexpected end of data"),
        ("encoding", (b"\xff",), "error:"),
        ("missing", (None,), "error:"),
    ],
    "t3": [
        ("header-a", ("sku,qty\n", T3_HEADER), "expected header"),
        ("three-fields-b", (T3_HEADER, T3_HEADER + "A,1,2\n"), "expected two fields"),
        ("bad-sku-a", (T3_HEADER + ".A,1\n", T3_HEADER), "invalid sku"),
        ("units-range-b", (T3_HEADER, T3_HEADER + "A,1000000\n"), "invalid units"),
        ("units-signed", (T3_HEADER + "A,-1\n", T3_HEADER), "invalid units"),
        ("missing-a", (None, T3_HEADER), "error:"),
        ("encoding-b", (T3_HEADER, b"\xff"), "error:"),
    ],
}


def reference(task):
    source = (ROOT / CLIS[task]).read_text(encoding="utf-8")
    start = source.index("def aggregate(")
    end = source.index("\ndef ", start + len("def aggregate("))
    if end < 0:
        raise ValueError("seed function boundaries changed")
    return source[:start] + REFERENCE[task] + source[end + 1:]


def run(task, candidate, directory, texts):
    for name, text in zip(INPUTS[task], texts):
        path = directory / name
        if text is None:
            path.unlink(missing_ok=True)
        elif isinstance(text, (bytes, bytearray)):
            path.write_bytes(bytes(text))
        else:
            path.write_text(text, encoding="utf-8")
    command = [sys.executable, "-I", "-B", "-X", "utf8", str(candidate)]
    command += [str(directory / name) for name in INPUTS[task]]
    return subprocess.run(
        command, cwd=directory, capture_output=True, text=True, timeout=5,
    )


def assess(task, candidate):
    # Literal expected outputs do not call the candidate or reference arithmetic.
    failures = []
    with tempfile.TemporaryDirectory(prefix="pine-1762-ledger-") as name:
        directory = Path(name)
        for label, texts, total in VALID[task]:
            result = run(task, candidate, directory, texts)
            if (result.returncode, result.stdout, result.stderr) != (0, total + "\n", ""):
                failures.append(label)
        for label, texts, diagnostic in INVALID[task]:
            result = run(task, candidate, directory, texts)
            if result.returncode != 2 or result.stdout or diagnostic not in result.stderr:
                failures.append(label)
    return failures


class LedgerSelfTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="pine-1762-ledger-ref-")
        self.addCleanup(self.directory.cleanup)

    def candidate(self, task):
        path = Path(self.directory.name) / (task + ".py")
        path.write_text(reference(task), encoding="utf-8")
        return path

    def test_t1_seed_is_red(self):
        self.assertEqual(assess("t1", ROOT / CLIS["t1"]), ["fixture", "repeat-count"])

    def test_t2_seed_is_red(self):
        self.assertEqual(assess("t2", ROOT / CLIS["t2"]), ["fixture", "case-distinct"])

    def test_t3_seed_is_red(self):
        self.assertEqual(assess("t3", ROOT / CLIS["t3"]), ["fixture", "within-file-add"])

    def test_references_are_green(self):
        for task in CLIS:
            self.assertEqual(assess(task, self.candidate(task)), [])

    def test_repeated_output_is_identical(self):
        candidate = self.candidate("t3")
        directory = Path(self.directory.name)
        results = [run("t3", candidate, directory, FIXTURES["t3"]) for _ in range(3)]
        expected = (0, '{"stock":{"K1":10,"K2":8,"K3":7,"K4":0}}\n', "")
        self.assertEqual([(r.returncode, r.stdout, r.stderr) for r in results],
                         [expected] * 3)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task", choices=("t1", "t2", "t3"))
    parser.add_argument("--candidate", type=Path, help="reviewed local script to execute")
    args = parser.parse_args()
    if args.candidate:
        if not args.task:
            parser.error("--candidate requires --task")
        failures = assess(args.task, args.candidate.resolve())
        print("FAIL: " + ", ".join(failures) if failures else "PASS: " + args.task)
        sys.exit(bool(failures))
    unittest.main(argv=[sys.argv[0]], verbosity=2)
