#!/usr/bin/env python3
"""Tests for check_ui_test_shards.py."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from check_ui_test_shards import (
    ShardValidationError,
    discover_test_classes,
    parse_shards,
    validate_shards,
)


class CheckUITestShardsTests(unittest.TestCase):
    def test_discovers_classes_and_counts_test_methods(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tests = Path(directory)
            (tests / "AlphaTests.swift").write_text(
                """
final class AlphaTests: PineUITestCase {
    func testFirst() {}
    func testSecond() throws {}
}
""",
                encoding="utf-8",
            )

            self.assertEqual(
                discover_test_classes(tests),
                {"AlphaTests": 2},
            )

    def test_parses_matrix_assignments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            workflow = Path(directory) / "ci.yml"
            workflow.write_text(
                """
          - shard-name: "First"
            test-classes: >-
              -only-testing:PineUITests/AlphaTests
          - shard-name: "Second"
            test-classes: >-
              -only-testing:PineUITests/BetaTests
""",
                encoding="utf-8",
            )

            self.assertEqual(
                parse_shards(workflow),
                {
                    "First": ["AlphaTests"],
                    "Second": ["BetaTests"],
                },
            )

    def test_accepts_complete_unique_balanced_assignment(self) -> None:
        report = validate_shards(
            {"AlphaTests": 3, "BetaTests": 2},
            {"First": ["AlphaTests"], "Second": ["BetaTests"]},
            max_delta=1,
        )

        self.assertEqual(report.total_tests, 5)
        self.assertEqual(report.delta, 1)

    def test_rejects_missing_unknown_duplicate_and_imbalanced_classes(
        self,
    ) -> None:
        with self.assertRaises(ShardValidationError) as context:
            validate_shards(
                {"AlphaTests": 5, "BetaTests": 1},
                {
                    "First": ["AlphaTests", "UnknownTests"],
                    "Second": ["AlphaTests"],
                    "Third": [],
                },
                max_delta=1,
            )

        message = str(context.exception)
        self.assertIn("unassigned UI test classes: BetaTests", message)
        self.assertIn("unknown UI test classes: UnknownTests", message)
        self.assertIn("multiply assigned UI test classes: AlphaTests", message)
        self.assertIn("shard test-count delta", message)


if __name__ == "__main__":
    unittest.main()
