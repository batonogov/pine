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
    _walk_test_nodes,
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

    def test_load_invalid_json(self):
        """Should exit on invalid JSON."""
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as fh:
            fh.write("not valid json {{{")
            path = fh.name
        try:
            with self.assertRaises(SystemExit) as cm:
                load_baselines(path)
            self.assertEqual(cm.exception.code, 2)
        finally:
            os.unlink(path)


class TestWalkTestNodes(unittest.TestCase):
    """Tests for _walk_test_nodes xcresult JSON parser."""

    def test_single_test_case(self):
        """Should extract duration from a simple test case node."""
        node = {
            "nodeType": "Test Suite",
            "name": "MyTests",
            "children": [
                {
                    "nodeType": "Test Case",
                    "name": "testFoo()",
                    "duration": "0.123",
                }
            ],
        }
        durations = {}
        _walk_test_nodes(node, durations)
        self.assertIn("MyTests/testFoo", durations)
        self.assertAlmostEqual(durations["MyTests/testFoo"], 0.123)

    def test_nested_suites(self):
        """Should use innermost Test Suite as parent."""
        node = {
            "nodeType": "Test Suite",
            "name": "All Tests",
            "children": [
                {
                    "nodeType": "Test Suite",
                    "name": "InnerSuite",
                    "children": [
                        {
                            "nodeType": "Test Case",
                            "name": "testBar()",
                            "duration": "0.456",
                        }
                    ],
                }
            ],
        }
        durations = {}
        _walk_test_nodes(node, durations)
        self.assertIn("InnerSuite/testBar", durations)

    def test_list_root(self):
        """Should handle JSON array as root node."""
        nodes = [
            {
                "nodeType": "Test Suite",
                "name": "Suite1",
                "children": [
                    {
                        "nodeType": "Test Case",
                        "name": "testA()",
                        "duration": "0.01",
                    }
                ],
            },
            {
                "nodeType": "Test Suite",
                "name": "Suite2",
                "children": [
                    {
                        "nodeType": "Test Case",
                        "name": "testB()",
                        "duration": "0.02",
                    }
                ],
            },
        ]
        durations = {}
        _walk_test_nodes(nodes, durations)
        self.assertIn("Suite1/testA", durations)
        self.assertIn("Suite2/testB", durations)

    def test_non_dict_node(self):
        """Should gracefully handle non-dict, non-list input."""
        durations = {}
        _walk_test_nodes("invalid", durations)
        self.assertEqual(durations, {})

    def test_none_node(self):
        """Should handle None input."""
        durations = {}
        _walk_test_nodes(None, durations)
        self.assertEqual(durations, {})

    def test_missing_duration(self):
        """Test case without duration should be skipped."""
        node = {
            "nodeType": "Test Suite",
            "name": "Tests",
            "children": [
                {
                    "nodeType": "Test Case",
                    "name": "testNoDuration()",
                }
            ],
        }
        durations = {}
        _walk_test_nodes(node, durations)
        self.assertEqual(durations, {})

    def test_invalid_duration_value(self):
        """Non-numeric duration should be skipped."""
        node = {
            "nodeType": "Test Suite",
            "name": "Tests",
            "children": [
                {
                    "nodeType": "Test Case",
                    "name": "testBad()",
                    "duration": "not-a-number",
                }
            ],
        }
        durations = {}
        _walk_test_nodes(node, durations)
        self.assertEqual(durations, {})

    def test_empty_children(self):
        """Node with empty children should not fail."""
        node = {
            "nodeType": "Test Suite",
            "name": "Empty",
            "children": [],
        }
        durations = {}
        _walk_test_nodes(node, durations)
        self.assertEqual(durations, {})

    def test_no_children_key(self):
        """Node without children key should not fail."""
        node = {
            "nodeType": "Test Suite",
            "name": "NoChildren",
        }
        durations = {}
        _walk_test_nodes(node, durations)
        self.assertEqual(durations, {})


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

    def test_inf_change_percent(self):
        """Infinite change percent (baseline=0) should show N/A."""
        results = [
            RegressionResult(
                test_name="A/test1",
                baseline_seconds=0.0,
                actual_seconds=0.001,
                change_percent=float("inf"),
                threshold_percent=15,
                is_regression=True,
                description="zero baseline",
            )
        ]
        report = format_markdown_report(results)
        self.assertIn("N/A (baseline=0)", report)
        self.assertNotIn("inf%", report)

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
