"""Regression tests for selecting the previous signed Pine release."""

from __future__ import annotations

import unittest
from pathlib import Path

from select_previous_release import (
    ReleaseSelectionError,
    parse_stable_tag,
    select_previous_release,
)


def release(
    tag: str,
    *,
    assets: list[dict] | None = None,
    draft: bool = False,
    prerelease: bool = False,
) -> dict:
    version = tag.removeprefix("v")
    if assets is None:
        assets = [{
            "name": f"Pine-{version}.dmg",
            "state": "uploaded",
            "size": 14_000_000,
        }]
    return {
        "tag_name": tag,
        "draft": draft,
        "prerelease": prerelease,
        "assets": assets,
    }


class PreviousReleaseSelectionTests(unittest.TestCase):
    def test_skips_consecutive_empty_releases(self):
        releases = [
            release("v2.3.5", assets=[]),
            release("v2.3.4", assets=[]),
            release(
                "v2.3.3",
                assets=[{"name": "appcast.xml", "state": "uploaded", "size": 10}],
            ),
            release("v2.3.2"),
        ]

        self.assertEqual(
            select_previous_release(releases, "v2.3.5"),
            "v2.3.2",
        )

    def test_rerun_never_selects_a_newer_release(self):
        releases = [release("v2.3.4"), release("v2.3.2")]

        self.assertEqual(
            select_previous_release(releases, "v2.3.3"),
            "v2.3.2",
        )

    def test_selects_highest_version_independent_of_api_order(self):
        releases = [
            release("v2.3.1"),
            release("v2.3.3"),
            release("v2.2.9"),
            release("v2.3.2"),
        ]

        self.assertEqual(
            select_previous_release(releases, "v2.4.0"),
            "v2.3.3",
        )

    def test_skips_draft_prerelease_and_malformed_tags(self):
        releases = [
            release("v2.3.4", draft=True),
            release("v2.3.3", prerelease=True),
            release("nightly"),
            release("v2.3.2"),
        ]

        self.assertEqual(
            select_previous_release(releases, "v2.3.5"),
            "v2.3.2",
        )

    def test_skips_ambiguous_mismatched_and_incomplete_dmgs(self):
        releases = [
            release(
                "v2.3.4",
                assets=[
                    {"name": "Pine-2.3.4.dmg", "state": "uploaded", "size": 10},
                    {"name": "Pine-debug.dmg", "state": "uploaded", "size": 10},
                ],
            ),
            release(
                "v2.3.3",
                assets=[
                    {"name": "Pine-2.3.2.dmg", "state": "uploaded", "size": 10},
                ],
            ),
            release(
                "v2.3.2",
                assets=[
                    {"name": "Pine-2.3.2.dmg", "state": "new", "size": 10},
                ],
            ),
            release("v2.3.1"),
        ]

        self.assertEqual(
            select_previous_release(releases, "v2.3.5"),
            "v2.3.1",
        )

    def test_fails_closed_without_a_usable_earlier_release(self):
        with self.assertRaisesRegex(ReleaseSelectionError, "before v2.3.5"):
            select_previous_release(
                [release("v2.3.4", assets=[]), release("v2.3.5")],
                "v2.3.5",
            )

    def test_rejects_invalid_current_tag(self):
        with self.assertRaisesRegex(ReleaseSelectionError, "invalid stable"):
            select_previous_release([release("v2.3.2")], "latest")

    def test_rejects_non_list_api_response(self):
        with self.assertRaisesRegex(ReleaseSelectionError, "must be a list"):
            select_previous_release({"message": "rate limited"}, "v2.3.5")

    def test_stable_tag_comparison_is_numeric(self):
        self.assertGreater(parse_stable_tag("v2.10.0"), parse_stable_tag("v2.9.9"))


class ReleaseWorkflowIntegrationTests(unittest.TestCase):
    def test_workflow_selects_and_downloads_the_validated_asset(self):
        repository = Path(__file__).resolve().parents[2]
        workflow = (repository / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("select_previous_release.py", workflow)
        self.assertIn("releases?per_page=100", workflow)
        self.assertIn('--pattern "$PREVIOUS_FILENAME"', workflow)
        self.assertNotIn("gh release list", workflow)


if __name__ == "__main__":
    unittest.main()
