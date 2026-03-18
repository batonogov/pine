#!/usr/bin/env python3
"""Extract a version's changelog section and convert it to styled HTML.

Usage: changelog-to-html.py <version> [changelog-path]

Reads CHANGELOG.md (Release Please format), extracts the section for the
given version, and outputs a self-contained HTML page styled to look native
in Sparkle's update dialog (system fonts, light/dark mode support).
"""

from __future__ import annotations

import re
import sys
from html import escape
from pathlib import Path

REPO_URL = "https://github.com/batonogov/pine"

HTML_TEMPLATE = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<style>
  body {{
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
    font-size: 13px;
    line-height: 1.5;
    padding: 12px 16px;
    color: #1d1d1f;
    background: transparent;
  }}
  @media (prefers-color-scheme: dark) {{
    body {{ color: #f5f5f7; }}
    a {{ color: #64d2ff; }}
  }}
  h3 {{
    font-size: 14px;
    font-weight: 600;
    margin: 16px 0 6px;
  }}
  h3:first-child {{
    margin-top: 0;
  }}
  ul {{
    padding-left: 20px;
    margin: 4px 0;
  }}
  li {{
    margin: 3px 0;
  }}
  a {{
    color: #0071e3;
    text-decoration: none;
  }}
</style>
</head>
<body>
{body}
</body>
</html>"""

FALLBACK_HTML = """\
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8">
<style>
  body {{
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    font-size: 13px; padding: 12px 16px; color: #1d1d1f; background: transparent;
  }}
  @media (prefers-color-scheme: dark) {{ body {{ color: #f5f5f7; }} a {{ color: #64d2ff; }} }}
  a {{ color: #0071e3; text-decoration: none; }}
</style>
</head>
<body>
<p>See full release notes on
<a href="{repo}/releases/tag/v{version}">GitHub</a>.</p>
</body>
</html>"""


def extract_section(changelog: str, version: str) -> str | None:
    """Extract the changelog section for a specific version."""
    pattern = rf"## \[{re.escape(version)}\][^\n]*\n(.*?)(?=\n## \[|\Z)"
    match = re.search(pattern, changelog, re.DOTALL)
    if match:
        return match.group(1).strip()
    return None


def md_to_html(md: str) -> str:
    """Convert Release Please changelog Markdown to HTML.

    Handles: ### headings, * list items, [text](url) links,
    **bold**, and `code` spans.
    """
    lines = md.split("\n")
    html_parts: list[str] = []
    in_list = False

    for line in lines:
        stripped = line.strip()

        # Skip empty lines
        if not stripped:
            if in_list:
                html_parts.append("</ul>")
                in_list = False
            continue

        # ### Heading
        if stripped.startswith("### "):
            if in_list:
                html_parts.append("</ul>")
                in_list = False
            title = escape(stripped[4:])
            # Strip common emoji prefixes from Release Please
            title = re.sub(r"^⚠\s*", "", title)
            html_parts.append(f"<h3>{title}</h3>")
            continue

        # * List item
        if stripped.startswith("* "):
            if not in_list:
                html_parts.append("<ul>")
                in_list = True
            content = _inline(stripped[2:])
            html_parts.append(f"<li>{content}</li>")
            continue

        # Regular paragraph line
        if in_list:
            html_parts.append("</ul>")
            in_list = False
        html_parts.append(f"<p>{_inline(stripped)}</p>")

    if in_list:
        html_parts.append("</ul>")

    return "\n".join(html_parts)


def _inline(text: str) -> str:
    """Process inline Markdown: links, bold, code."""
    # Escape HTML first, then apply Markdown transformations
    text = escape(text)

    # [text](url) -> <a href="url">text</a>
    text = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        r'<a href="\2">\1</a>',
        text,
    )

    # **bold** -> <strong>bold</strong>
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)

    # `code` -> <code>code</code>
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)

    return text


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <version> [changelog-path]", file=sys.stderr)
        sys.exit(2)

    version = sys.argv[1].lstrip("v")
    changelog_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("CHANGELOG.md")

    if not changelog_path.exists():
        print(FALLBACK_HTML.format(repo=REPO_URL, version=version))
        return

    changelog = changelog_path.read_text(encoding="utf-8")
    section = extract_section(changelog, version)

    if not section:
        print(FALLBACK_HTML.format(repo=REPO_URL, version=version))
        return

    body = md_to_html(section)
    print(HTML_TEMPLATE.format(body=body))


if __name__ == "__main__":
    main()
