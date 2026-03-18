#!/usr/bin/env python3
"""Tests for changelog-to-html.py."""

from __future__ import annotations

import subprocess
import sys
import textwrap
import unittest
from pathlib import Path

# Import the module under test
sys.path.insert(0, str(Path(__file__).parent))
from changelog_to_html import extract_section, md_to_html, _inline  # noqa: E402

SAMPLE_CHANGELOG = textwrap.dedent("""\
    # Changelog

    ## [1.2.1](https://github.com/batonogov/pine/compare/v1.2.0...v1.2.1) (2026-03-18)


    ### Bug Fixes

    * show abbreviated path (~/) in Welcome recent projects ([#185](https://github.com/batonogov/pine/issues/185)) ([2e24b80](https://github.com/batonogov/pine/commit/2e24b80))

    ## [1.2.0](https://github.com/batonogov/pine/compare/v1.1.0...v1.2.0) (2026-03-18)


    ### Features

    * integrate Sparkle for in-app auto-updates ([#152](https://github.com/batonogov/pine/issues/152)) ([8f2f477](https://github.com/batonogov/pine/commit/8f2f477))
    * polish project window chrome ([#181](https://github.com/batonogov/pine/issues/181)) ([fd3a51a](https://github.com/batonogov/pine/commit/fd3a51a))


    ### Bug Fixes

    * prevent symlink traversal ([#183](https://github.com/batonogov/pine/issues/183)) ([c93b86a](https://github.com/batonogov/pine/commit/c93b86a))

    ## [1.0.0](https://github.com/batonogov/pine/compare/v0.12.8...v1.0.0) (2026-03-17)


    ### ⚠ BREAKING CHANGES

    * prepare for 1.0.0 release ([#137](https://github.com/batonogov/pine/issues/137))

    ### Miscellaneous

    * prepare for 1.0.0 release ([#137](https://github.com/batonogov/pine/issues/137)) ([40b56da](https://github.com/batonogov/pine/commit/40b56da))
""")


class TestExtractSection(unittest.TestCase):
    def test_extracts_single_item_section(self):
        section = extract_section(SAMPLE_CHANGELOG, "1.2.1")
        assert section is not None
        assert "show abbreviated path" in section
        assert "integrate Sparkle" not in section

    def test_extracts_multi_item_section(self):
        section = extract_section(SAMPLE_CHANGELOG, "1.2.0")
        assert section is not None
        assert "integrate Sparkle" in section
        assert "polish project window" in section
        assert "prevent symlink" in section
        assert "show abbreviated path" not in section

    def test_extracts_last_section(self):
        section = extract_section(SAMPLE_CHANGELOG, "1.0.0")
        assert section is not None
        assert "prepare for 1.0.0" in section

    def test_returns_none_for_missing_version(self):
        section = extract_section(SAMPLE_CHANGELOG, "9.9.9")
        assert section is None

    def test_extracts_section_with_empty_subsections(self):
        changelog = "## [2.0.0](url) (date)\n\n\n### Features\n\n* feat one\n"
        section = extract_section(changelog, "2.0.0")
        assert section is not None
        assert "feat one" in section


class TestMdToHtml(unittest.TestCase):
    def test_heading(self):
        html = md_to_html("### Bug Fixes")
        assert "<h3>Bug Fixes</h3>" in html

    def test_list_items(self):
        md = "### Features\n\n* item one\n* item two"
        html = md_to_html(md)
        assert "<ul>" in html
        assert "<li>item one</li>" in html
        assert "<li>item two</li>" in html
        assert "</ul>" in html

    def test_list_closed_before_next_heading(self):
        md = "### A\n\n* item\n\n### B"
        html = md_to_html(md)
        # The </ul> should appear before <h3>B</h3>
        ul_close = html.index("</ul>")
        h3_b = html.index("<h3>B</h3>")
        assert ul_close < h3_b

    def test_breaking_changes_emoji_stripped(self):
        html = md_to_html("### ⚠ BREAKING CHANGES")
        assert "⚠" not in html
        assert "BREAKING CHANGES" in html

    def test_empty_input(self):
        html = md_to_html("")
        assert html == ""


class TestMdToHtmlShellSafety(unittest.TestCase):
    """Ensure output is safe when interpolated in shell heredocs."""

    def test_dollar_signs_preserved(self):
        # $ is not an HTML special char — it passes through escape() as-is.
        # This is safe because the HTML is written to a file and read by
        # Python (not interpolated in a shell heredoc).
        md = "### Bug Fixes\n\n* fix $HOME expansion in path"
        html = md_to_html(md)
        assert "fix $HOME expansion in path" in html

    def test_backticks_converted_to_code_tags(self):
        md = "### Features\n\n* add `$PATH` helper"
        html = md_to_html(md)
        # Backticks should become <code> tags, no raw backticks in output
        assert "`" not in html
        assert "<code>" in html

    def test_backslash_preserved(self):
        md = "### Bug Fixes\n\n* fix path\\separator issue"
        html = md_to_html(md)
        assert "path\\separator" in html



    def test_link(self):
        result = _inline("[text](https://example.com)")
        assert '<a href="https://example.com">text</a>' in result

    def test_bold(self):
        result = _inline("**bold**")
        assert "<strong>bold</strong>" in result

    def test_code(self):
        result = _inline("`code`")
        assert "<code>code</code>" in result

    def test_html_escaped(self):
        result = _inline("<script>alert('xss')</script>")
        assert "<script>" not in result
        assert "&lt;script&gt;" in result

    def test_combined(self):
        result = _inline("fix **bug** in [pine](https://x.com) with `code`")
        assert "<strong>bug</strong>" in result
        assert '<a href="https://x.com">pine</a>' in result
        assert "<code>code</code>" in result


class TestCLI(unittest.TestCase):
    """Integration tests running the script as a subprocess."""

    SCRIPT = str(Path(__file__).parent / "changelog_to_html.py")
    CHANGELOG = str(Path(__file__).resolve().parent.parent.parent / "CHANGELOG.md")

    def test_valid_version_outputs_html(self):
        result = subprocess.run(
            [sys.executable, self.SCRIPT, "1.2.1", self.CHANGELOG],
            capture_output=True, text=True,
        )
        assert result.returncode == 0
        assert "<!DOCTYPE html>" in result.stdout
        assert '<html lang="en">' in result.stdout
        assert "show abbreviated path" in result.stdout

    def test_missing_version_outputs_fallback(self):
        result = subprocess.run(
            [sys.executable, self.SCRIPT, "9.9.9", self.CHANGELOG],
            capture_output=True, text=True,
        )
        assert result.returncode == 0
        assert "GitHub" in result.stdout
        assert "9.9.9" in result.stdout

    def test_missing_changelog_outputs_fallback(self):
        result = subprocess.run(
            [sys.executable, self.SCRIPT, "1.0.0", "/nonexistent/CHANGELOG.md"],
            capture_output=True, text=True,
        )
        assert result.returncode == 0
        assert "GitHub" in result.stdout

    def test_no_args_exits_with_error(self):
        result = subprocess.run(
            [sys.executable, self.SCRIPT],
            capture_output=True, text=True,
        )
        assert result.returncode == 2


if __name__ == "__main__":
    unittest.main()
