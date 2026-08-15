#!/usr/bin/env python3
"""Select the newest usable release older than the current Pine tag.

GitHub creates the Release Please release before the signed artifacts are
uploaded. A failed publication can therefore leave a stable-looking release
with no DMG. Release smoke tests must skip those incomplete releases instead
of letting one failed publication block every later release.

The GitHub releases API response is read from stdin. The selected tag is
written to stdout.
"""

from __future__ import annotations

import json
import re
import sys
from typing import Any


TAG_PATTERN = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


class ReleaseSelectionError(ValueError):
    """The release list cannot provide a safe previous DMG."""


def parse_stable_tag(tag: str) -> tuple[int, int, int]:
    """Return a comparable version tuple for a stable Pine release tag."""
    match = TAG_PATTERN.fullmatch(tag)
    if match is None:
        raise ReleaseSelectionError(f"invalid stable Pine tag: {tag!r}")
    return tuple(int(component) for component in match.groups())


def _usable_dmg(release: dict[str, Any], tag: str) -> bool:
    """Whether release has one complete DMG whose name matches its tag."""
    assets = release.get("assets")
    if not isinstance(assets, list):
        return False

    pine_dmgs = [
        asset
        for asset in assets
        if isinstance(asset, dict)
        and isinstance(asset.get("name"), str)
        and asset["name"].startswith("Pine-")
        and asset["name"].endswith(".dmg")
    ]
    if len(pine_dmgs) != 1:
        return False

    asset = pine_dmgs[0]
    expected_name = f"Pine-{tag.removeprefix('v')}.dmg"
    return (
        asset["name"] == expected_name
        and asset.get("state") == "uploaded"
        and isinstance(asset.get("size"), int)
        and asset["size"] > 0
    )


def select_previous_release(
    releases: object,
    current_tag: str,
) -> str:
    """Select the highest usable stable version strictly below current_tag."""
    current_version = parse_stable_tag(current_tag)
    if not isinstance(releases, list):
        raise ReleaseSelectionError("GitHub releases response must be a list")

    candidates: list[tuple[tuple[int, int, int], str]] = []
    for release in releases:
        if not isinstance(release, dict):
            continue
        if release.get("draft") is True or release.get("prerelease") is True:
            continue

        tag = release.get("tag_name")
        if not isinstance(tag, str):
            continue
        try:
            version = parse_stable_tag(tag)
        except ReleaseSelectionError:
            continue
        if version >= current_version or not _usable_dmg(release, tag):
            continue
        candidates.append((version, tag))

    if not candidates:
        raise ReleaseSelectionError(
            "no earlier stable release with one uploaded Pine DMG exists "
            f"before {current_tag}"
        )
    return max(candidates)[1]


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "Usage: select_previous_release.py <current-tag>",
            file=sys.stderr,
        )
        return 64

    try:
        releases = json.load(sys.stdin)
        selected = select_previous_release(releases, sys.argv[1])
    except (json.JSONDecodeError, ReleaseSelectionError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1

    print(selected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
