import unittest

from summarize_lifecycle_soak import render


class LifecycleSoakSummaryTests(unittest.TestCase):
    def test_clean_report_is_not_a_regression(self):
        report = {
            "seed": 1443,
            "requestedCycles": 100,
            "completedCycles": 100,
            "peakResidentBytes": 20 * 1_048_576,
            "baseline": {"residentBytes": 10 * 1_048_576},
            "final": {
                "residentBytes": 12 * 1_048_576,
                "descriptorCount": 8,
                "pseudoTerminalCount": 0,
                "children": [],
            },
            "idleCPUSeconds": 0.01,
            "hardFailures": [],
            "trendWarnings": [],
            "samples": [
                {
                    "cpuSeconds": 0.125,
                    "rendererRequested": "coregraphics",
                    "rendererEffective": "coregraphics",
                    "rendererRecreationSucceeded": False,
                },
                {
                    "cpuSeconds": 0.25,
                    "rendererRequested": "automatic",
                    "rendererEffective": "metal",
                    "rendererRecreationSucceeded": True,
                },
            ],
        }

        summary, has_regression, has_trend = render(report, "success")

        self.assertFalse(has_regression)
        self.assertFalse(has_trend)
        self.assertIn("100 / 100", summary)
        self.assertIn("12.0 MiB", summary)
        self.assertIn("Lifecycle CPU seconds | 0.375", summary)
        self.assertIn("Automatic renderer cycles | 1", summary)
        self.assertIn("Effective Metal cycles | 1", summary)
        self.assertIn("Successful Metal recreations | 1", summary)

    def test_hard_failures_and_job_failure_are_regressions(self):
        report = {
            "hardFailures": ["retained child"],
            "trendWarnings": ["memory drift"],
        }

        summary, has_regression, has_trend = render(report, "failure")

        self.assertTrue(has_regression)
        self.assertTrue(has_trend)
        self.assertIn("retained child", summary)
        self.assertIn("memory drift", summary)

    def test_missing_report_fails_closed(self):
        summary, has_regression, has_trend = render(None, "success")

        self.assertTrue(has_regression)
        self.assertFalse(has_trend)
        self.assertIn("Report | missing", summary)

    def test_incomplete_report_fails_closed_after_runner_restart(self):
        report = {
            "requestedCycles": 100,
            "completedCycles": 17,
            "final": None,
            "hardFailures": [],
            "trendWarnings": [],
        }

        summary, has_regression, _ = render(report, "success")

        self.assertTrue(has_regression)
        self.assertIn("Incomplete run", summary)


if __name__ == "__main__":
    unittest.main()
