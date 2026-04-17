"""Unit tests for check_perf_regression.py."""

import json
import os
import tempfile
import unittest

from check_perf_regression import (
    load_baselines,
    compare_results,
    format_markdown_report,
    RegressionResult,
)


class TestLoadBaselines(unittest.TestCase):
    """Tests for loading baseline JSON."""

    def test_load_valid_baselines(self):
        """Should parse a valid baselines file."""
        data = {
            "threshold_percent": 15,
            "tests": {
                "FoldRangeCalculatorPerformanceTests/testManyBlocks": {
                    "baseline_seconds": 0.005,
                    "description": "500 flat brace blocks",
                }
            },
        }
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as fh:
            json.dump(data, fh)
            path = fh.name
        try:
            baselines = load_baselines(path)
            self.assertEqual(baselines["threshold_percent"], 15)
            key = "FoldRangeCalculatorPerformanceTests/testManyBlocks"
            self.assertIn(key, baselines["tests"])
            self.assertAlmostEqual(
                baselines["tests"][key]["baseline_seconds"], 0.005
            )
        finally:
            os.unlink(path)

    def test_load_missing_file(self):
        """Should raise FileNotFoundError for missing file."""
        with self.assertRaises(FileNotFoundError):
            load_baselines("/nonexistent/baselines.json")

    def test_load_empty_tests(self):
        """Should handle empty tests dict."""
        data = {"threshold_percent": 15, "tests": {}}
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as fh:
            json.dump(data, fh)
            path = fh.name
        try:
            baselines = load_baselines(path)
            self.assertEqual(baselines["tests"], {})
        finally:
            os.unlink(path)


class TestCompareResults(unittest.TestCase):
    """Tests for comparing actual results against baselines."""

    def _baselines(self, threshold=15, tests=None):
        return {
            "threshold_percent": threshold,
            "tests": tests or {},
        }

    def test_no_regression(self):
        """Result within threshold should not be flagged."""
        baselines = self._baselines(
            tests={
                "TestClass/testFoo": {
                    "baseline_seconds": 0.010,
                    "description": "test foo",
                }
            }
        )
        actual = {"TestClass/testFoo": 0.011}  # 10% over — within 15%
        results = compare_results(baselines, actual)
        self.assertEqual(len(results), 1)
        self.assertFalse(results[0].is_regression)

    def test_regression_detected(self):
        """Result exceeding threshold should be flagged."""
        baselines = self._baselines(
            threshold=15,
            tests={
                "TestClass/testFoo": {
                    "baseline_seconds": 0.010,
                    "description": "test foo",
                }
            },
        )
        actual = {"TestClass/testFoo": 0.012}  # 20% over — exceeds 15%
        results = compare_results(baselines, actual)
        self.assertEqual(len(results), 1)
        self.assertTrue(results[0].is_regression)
        self.assertAlmostEqual(results[0].change_percent, 20.0)

    def test_faster_result(self):
        """Faster result should not be a regression."""
        baselines = self._baselines(
            tests={
                "TestClass/testFoo": {
                    "baseline_seconds": 0.010,
                    "description": "test foo",
                }
            }
        )
        actual = {"TestClass/testFoo": 0.005}  # 50% faster
        results = compare_results(baselines, actual)
        self.assertEqual(len(results), 1)
        self.assertFalse(results[0].is_regression)
        self.assertAlmostEqual(results[0].change_percent, -50.0)

    def test_missing_actual_result(self):
        """Test in baselines but not in actual should be skipped."""
        baselines = self._baselines(
            tests={
                "TestClass/testFoo": {
                    "baseline_seconds": 0.010,
                    "description": "test foo",
                }
            }
        )
        actual = {}
        results = compare_results(baselines, actual)
        self.assertEqual(len(results), 0)

    def test_extra_actual_result(self):
        """Test in actual but not in baselines should be ignored."""
        baselines = self._baselines(tests={})
        actual = {"TestClass/testFoo": 0.010}
        results = compare_results(baselines, actual)
        self.assertEqual(len(results), 0)

    def test_multiple_tests_mixed(self):
        """Mixed results: one regression, one pass."""
        baselines = self._baselines(
            threshold=10,
            tests={
                "A/test1": {
                    "baseline_seconds": 0.100,
                    "description": "test 1",
                },
                "A/test2": {
                    "baseline_seconds": 0.200,
                    "description": "test 2",
                },
            },
        )
        actual = {
            "A/test1": 0.105,  # 5% — within 10%
            "A/test2": 0.250,  # 25% — exceeds 10%
        }
        results = compare_results(baselines, actual)
        regressions = [r for r in results if r.is_regression]
        passes = [r for r in results if not r.is_regression]
        self.assertEqual(len(regressions), 1)
        self.assertEqual(regressions[0].test_name, "A/test2")
        self.assertEqual(len(passes), 1)

    def test_exact_threshold(self):
        """Result exactly at threshold should not be flagged."""
        baselines = self._baselines(
            threshold=15,
            tests={
                "A/test1": {
                    "baseline_seconds": 0.100,
                    "description": "test",
                }
            },
        )
        actual = {"A/test1": 0.115}  # exactly 15%
        results = compare_results(baselines, actual)
        self.assertFalse(results[0].is_regression)

    def test_zero_baseline(self):
        """Zero baseline should not cause division by zero."""
        baselines = self._baselines(
            tests={
                "A/test1": {
                    "baseline_seconds": 0.0,
                    "description": "instant test",
                }
            }
        )
        actual = {"A/test1": 0.001}
        results = compare_results(baselines, actual)
        self.assertEqual(len(results), 1)
        # With zero baseline, any positive value is a regression
        self.assertTrue(results[0].is_regression)


class TestFormatMarkdownReport(unittest.TestCase):
    """Tests for markdown report generation."""

    def test_no_results(self):
        """Empty results should produce a minimal report."""
        report = format_markdown_report([])
        self.assertIn("No baseline comparisons", report)

    def test_all_passing(self):
        """All passing should show success."""
        results = [
            RegressionResult(
                test_name="A/test1",
                baseline_seconds=0.010,
                actual_seconds=0.011,
                change_percent=10.0,
                threshold_percent=15,
                is_regression=False,
                description="test 1",
            )
        ]
        report = format_markdown_report(results)
        self.assertIn("All benchmarks within threshold", report)
        self.assertIn("A/test1", report)

    def test_with_regression(self):
        """Regression should show warning."""
        results = [
            RegressionResult(
                test_name="A/test1",
                baseline_seconds=0.010,
                actual_seconds=0.015,
                change_percent=50.0,
                threshold_percent=15,
                is_regression=True,
                description="test 1",
            )
        ]
        report = format_markdown_report(results)
        self.assertIn("REGRESSION", report)
        self.assertIn("A/test1", report)
        self.assertIn("50.0%", report)

    def test_mixed_results(self):
        """Mixed results show both passing and failing."""
        results = [
            RegressionResult(
                test_name="A/test1",
                baseline_seconds=0.010,
                actual_seconds=0.011,
                change_percent=10.0,
                threshold_percent=15,
                is_regression=False,
                description="pass",
            ),
            RegressionResult(
                test_name="A/test2",
                baseline_seconds=0.010,
                actual_seconds=0.015,
                change_percent=50.0,
                threshold_percent=15,
                is_regression=True,
                description="fail",
            ),
        ]
        report = format_markdown_report(results)
        self.assertIn("REGRESSION", report)
        self.assertIn("1 regression", report)


class TestRegressionResult(unittest.TestCase):
    """Tests for RegressionResult dataclass."""

    def test_fields(self):
        """Should store all fields correctly."""
        r = RegressionResult(
            test_name="Foo/bar",
            baseline_seconds=0.5,
            actual_seconds=0.6,
            change_percent=20.0,
            threshold_percent=15,
            is_regression=True,
            description="desc",
        )
        self.assertEqual(r.test_name, "Foo/bar")
        self.assertAlmostEqual(r.baseline_seconds, 0.5)
        self.assertAlmostEqual(r.actual_seconds, 0.6)
        self.assertTrue(r.is_regression)


if __name__ == "__main__":
    unittest.main()
