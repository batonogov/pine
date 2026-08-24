"""Unit tests for detect_flaky_tests.py."""

import json
import unittest

from pathlib import Path

from detect_flaky_tests import (
    REPETITION_NODE_TYPE,
    TEST_CASE_NODE_TYPE,
    FlakyTest,
    count_test_cases,
    describe_schema_mismatch,
    find_flaky_tests,
    flaky_to_dicts,
    format_markdown,
    _parse_output_file,
)

RECORDED_PAYLOAD = (
    Path(__file__).parent / "testdata" / "retried_test_payload.json"
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
                            "nodeType": "Repetition",
                            "name": "Run 1",
                            "result": "Failed",
                        },
                        {
                            "nodeType": "Repetition",
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
                            "nodeType": "Repetition",
                            "name": "Run 1",
                            "result": "Failed",
                        },
                        {
                            "nodeType": "Repetition",
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
                                            "nodeType": "Repetition",
                                            "name": "Run 1",
                                            "result": "Failed",
                                        },
                                        {
                                            "nodeType": "Repetition",
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
                            "nodeType": "Repetition",
                            "name": "Run 1",
                            "result": "Failed",
                        },
                        {
                            "nodeType": "Repetition",
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
                            "nodeType": "Repetition",
                            "name": "Run 1",
                            "result": "Failed",
                        },
                        {
                            "nodeType": "Repetition",
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
                            "nodeType": "Repetition",
                            "name": "Run 1",
                            "result": "Passed",
                        },
                        {
                            "nodeType": "Repetition",
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


class TestRecordedRetryPayload(unittest.TestCase):
    """The regression tests for #1510, run against a real report.

    Hand-written fixtures are what let this detector stay broken: they were
    written from the same wrong assumption as the code, so they agreed with
    it. `testdata/retried_test_payload.json` is instead the verbatim output of

        xcrun xcresulttool get test-results tests --path <bundle>

    for a run where one test genuinely failed and passed on retry (only the
    machine's device id and the source path were replaced). Two independent
    defects had to be fixed before this payload produced any output: the
    node-type spelling, and the walk that never left the root object.
    """

    def setUp(self):
        with open(RECORDED_PAYLOAD) as payload:
            self.data = json.load(payload)

    def test_real_retry_is_reported(self):
        """A genuinely retried test is named, not silently dropped."""
        flaky = find_flaky_tests(self.data)
        self.assertEqual(len(flaky), 1)
        self.assertEqual(flaky[0].name, "fails once, then passes on retry")
        self.assertEqual(flaky[0].failed_runs, 1)
        self.assertEqual(flaky[0].total_runs, 2)
        self.assertIn("PineTests", flaky[0].suite)

    def test_payload_uses_the_schema_spelling(self):
        """The recorded report spells the node the way the script matches.

        If someone re-records this fixture from a toolchain that renames the
        node, this fails here rather than by quietly reporting nothing.
        """
        self.assertIn(f'"{REPETITION_NODE_TYPE}"', json.dumps(self.data))
        self.assertNotIn("Test Repetition", json.dumps(self.data))

    def test_walk_reaches_test_cases_under_test_nodes(self):
        """The root key is `testNodes`; only walking `children` finds nothing."""
        self.assertEqual(count_test_cases(self.data), 1)
        self.assertEqual(count_test_cases(self.data.get("children", [])), 0)

    def test_old_spelling_would_find_nothing(self):
        """Pins the defect itself, so the fix cannot be quietly reverted."""
        renamed = json.loads(
            json.dumps(self.data).replace(
                f'"{REPETITION_NODE_TYPE}"', '"Test Repetition"'
            )
        )
        self.assertEqual(find_flaky_tests(renamed), [])


class TestSchemaMismatch(unittest.TestCase):
    """The guard that makes a future rename loud instead of silent."""

    def test_schema_with_both_types_is_accepted(self):
        self.assertIsNone(
            describe_schema_mismatch([
                "Test Plan", TEST_CASE_NODE_TYPE, REPETITION_NODE_TYPE,
            ])
        )

    def test_renamed_repetition_is_reported(self):
        message = describe_schema_mismatch(["Test Plan", TEST_CASE_NODE_TYPE])
        self.assertIsNotNone(message)
        self.assertIn(REPETITION_NODE_TYPE, message)

    def test_renamed_test_case_is_reported(self):
        message = describe_schema_mismatch(["Test Plan", REPETITION_NODE_TYPE])
        self.assertIsNotNone(message)
        self.assertIn(TEST_CASE_NODE_TYPE, message)

    def test_unreadable_schema_does_not_fail_the_lane(self):
        """Being unable to check is not evidence of a rename."""
        self.assertIsNone(describe_schema_mismatch(None))

    def test_empty_schema_is_a_mismatch(self):
        self.assertIsNotNone(describe_schema_mismatch([]))


class TestCountTestCases(unittest.TestCase):
    """`count_test_cases` backs the "nothing was analysed" guard."""

    def test_counts_across_both_child_keys(self):
        data = {
            "testNodes": [
                {
                    "nodeType": "Test Suite",
                    "children": [
                        {"nodeType": TEST_CASE_NODE_TYPE, "name": "a"},
                        {"nodeType": TEST_CASE_NODE_TYPE, "name": "b"},
                    ],
                }
            ]
        }
        self.assertEqual(count_test_cases(data), 2)

    def test_empty_report_counts_nothing(self):
        self.assertEqual(count_test_cases({"testNodes": []}), 0)

    def test_survives_unexpected_shapes(self):
        """A malformed report must not crash the detector before it reports."""
        self.assertEqual(count_test_cases({"testNodes": [None, 3, "x"]}), 0)
        self.assertEqual(count_test_cases([]), 0)
        self.assertEqual(count_test_cases("not a node"), 0)


if __name__ == "__main__":
    unittest.main()
