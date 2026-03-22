"""Unit tests for detect_flaky_tests.py."""

import json
import unittest

from detect_flaky_tests import (
    FlakyTest,
    find_flaky_tests,
    flaky_to_dicts,
    format_markdown,
    _parse_output_file,
)


class TestFindFlakyTests(unittest.TestCase):
    """Tests for the find_flaky_tests function."""

    def test_no_tests(self):
        """Empty test results should return no flaky tests."""
        data = {"testNodes": []}
        self.assertEqual(find_flaky_tests(data), [])

    def test_all_passing_no_retries(self):
        """Tests that pass on first attempt are not flaky."""
        data = {
            "nodeType": "Test Suite",
            "name": "PineTests",
            "children": [
                {
                    "nodeType": "Test Case",
                    "name": "testExample",
                    "result": "Passed",
                    "children": [],
                }
            ],
        }
        self.assertEqual(find_flaky_tests(data), [])

    def test_failed_test_not_flaky(self):
        """A test that fails all attempts is not flaky — it's a real failure."""
        data = {
            "nodeType": "Test Suite",
            "name": "PineTests",
            "children": [
                {
                    "nodeType": "Test Case",
                    "name": "testBroken",
                    "result": "Failed",
                    "children": [
                        {
                            "nodeType": "Test Repetition",
                            "name": "Run 1",
                            "result": "Failed",
                        },
                        {
                            "nodeType": "Test Repetition",
                            "name": "Run 2",
                            "result": "Failed",
                        },
                    ],
                }
            ],
        }
        self.assertEqual(find_flaky_tests(data), [])

    def test_flaky_test_detected(self):
        """A test that fails then passes on retry is flaky."""
        data = {
            "nodeType": "Test Suite",
            "name": "PineTests",
            "children": [
                {
                    "nodeType": "Test Case",
                    "name": "testFlaky",
                    "result": "Passed",
                    "children": [
                        {
                            "nodeType": "Test Repetition",
                            "name": "Run 1",
                            "result": "Failed",
                        },
                        {
                            "nodeType": "Test Repetition",
                            "name": "Run 2",
                            "result": "Passed",
                        },
                    ],
                }
            ],
        }
        result = find_flaky_tests(data)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].name, "testFlaky")
        self.assertEqual(result[0].suite, "PineTests")
        self.assertEqual(result[0].failed_runs, 1)
        self.assertEqual(result[0].total_runs, 2)

    def test_nested_suites(self):
        """Flaky tests in nested suites should include full suite path."""
        data = {
            "nodeType": "Test Plan",
            "name": "Test Scheme Action",
            "children": [
                {
                    "nodeType": "Test Suite",
                    "name": "PineUITests",
                    "children": [
                        {
                            "nodeType": "Test Suite",
                            "name": "WelcomeWindowTests",
                            "children": [
                                {
                                    "nodeType": "Test Case",
                                    "name": "testWindowAppears",
                                    "result": "Passed",
                                    "children": [
                                        {
                                            "nodeType": "Test Repetition",
                                            "name": "Run 1",
                                            "result": "Failed",
                                        },
                                        {
                                            "nodeType": "Test Repetition",
                                            "name": "Run 2",
                                            "result": "Passed",
                                        },
                                    ],
                                },
                            ],
                        },
                    ],
                },
            ],
        }
        result = find_flaky_tests(data)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].suite, "PineUITests/WelcomeWindowTests")
        self.assertEqual(result[0].name, "testWindowAppears")

    def test_mixed_flaky_and_stable(self):
        """Only flaky tests should be returned, not stable ones."""
        data = {
            "nodeType": "Test Suite",
            "name": "Tests",
            "children": [
                {
                    "nodeType": "Test Case",
                    "name": "testStable",
                    "result": "Passed",
                    "children": [],
                },
                {
                    "nodeType": "Test Case",
                    "name": "testFlaky",
                    "result": "Passed",
                    "children": [
                        {
                            "nodeType": "Test Repetition",
                            "name": "Run 1",
                            "result": "Failed",
                        },
                        {
                            "nodeType": "Test Repetition",
                            "name": "Run 2",
                            "result": "Passed",
                        },
                    ],
                },
                {
                    "nodeType": "Test Case",
                    "name": "testBroken",
                    "result": "Failed",
                    "children": [
                        {
                            "nodeType": "Test Repetition",
                            "name": "Run 1",
                            "result": "Failed",
                        },
                        {
                            "nodeType": "Test Repetition",
                            "name": "Run 2",
                            "result": "Failed",
                        },
                    ],
                },
            ],
        }
        result = find_flaky_tests(data)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].name, "testFlaky")

    def test_passed_with_all_passing_repetitions(self):
        """A test that passes all repetitions is not flaky."""
        data = {
            "nodeType": "Test Suite",
            "name": "Tests",
            "children": [
                {
                    "nodeType": "Test Case",
                    "name": "testReliable",
                    "result": "Passed",
                    "children": [
                        {
                            "nodeType": "Test Repetition",
                            "name": "Run 1",
                            "result": "Passed",
                        },
                        {
                            "nodeType": "Test Repetition",
                            "name": "Run 2",
                            "result": "Passed",
                        },
                    ],
                }
            ],
        }
        self.assertEqual(find_flaky_tests(data), [])


class TestFormatMarkdown(unittest.TestCase):
    """Tests for the format_markdown function."""

    def test_single_flaky(self):
        """Single flaky test should produce a valid markdown table."""
        flaky = [FlakyTest(suite="Suite", name="testA", failed_runs=1, total_runs=2)]
        md = format_markdown(flaky)
        self.assertIn("Flaky Tests Detected", md)
        self.assertIn("| Suite | testA | 1/2 |", md)

    def test_sorted_output(self):
        """Flaky tests should be sorted by suite then name."""
        flaky = [
            FlakyTest(suite="B", name="testZ", failed_runs=1, total_runs=2),
            FlakyTest(suite="A", name="testA", failed_runs=1, total_runs=2),
        ]
        md = format_markdown(flaky)
        idx_a = md.index("testA")
        idx_z = md.index("testZ")
        self.assertLess(idx_a, idx_z)


class TestFlakyToDicts(unittest.TestCase):
    """Tests for the flaky_to_dicts function."""

    def test_empty(self):
        """Empty list should return empty list."""
        self.assertEqual(flaky_to_dicts([]), [])

    def test_conversion(self):
        """FlakyTest should convert to dict correctly."""
        flaky = [FlakyTest(suite="S", name="t", failed_runs=1, total_runs=2)]
        result = flaky_to_dicts(flaky)
        self.assertEqual(result, [
            {"suite": "S", "name": "t", "failed_runs": 1, "total_runs": 2}
        ])

    def test_json_serializable(self):
        """Output should be JSON-serializable."""
        flaky = [FlakyTest(suite="A", name="b", failed_runs=2, total_runs=3)]
        data = flaky_to_dicts(flaky)
        serialized = json.dumps(data)
        self.assertEqual(json.loads(serialized), data)


class TestParseOutputFile(unittest.TestCase):
    """Tests for the _parse_output_file function."""

    def test_no_flag(self):
        """No --output-file should return empty string."""
        self.assertEqual(_parse_output_file(["script", "path"]), "")

    def test_with_flag(self):
        """--output-file should return the next argument."""
        self.assertEqual(
            _parse_output_file(["script", "--output-file", "out.json"]),
            "out.json",
        )

    def test_flag_at_end(self):
        """--output-file at end without value should return empty string."""
        self.assertEqual(_parse_output_file(["script", "--output-file"]), "")


if __name__ == "__main__":
    unittest.main()
