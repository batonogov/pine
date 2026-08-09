#!/bin/bash
# Guards the contract between screenshot extraction and the workflow commit
# allowlist. A required capture that is extracted but not staged leaves the
# public marketing surface stale even though the workflow succeeds (#1370).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
EXTRACTOR="$REPO_ROOT/scripts/update-screenshots.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/screenshots.yml"

required_names=$(
  sed -n '/^REQUIRED_NAMES=(/,/^)/p' "$EXTRACTOR" \
    | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p'
)
committed_names=$(
  sed -n '/^[[:space:]]*NAMED=(/,/^[[:space:]]*)/p' "$WORKFLOW" \
    | sed -n 's|^[[:space:]]*assets/\([^"]*\)\.png.*|\1|p'
)

if [ -z "$required_names" ]; then
  echo "Error: no REQUIRED_NAMES found in $EXTRACTOR" >&2
  exit 1
fi

if [ -z "$committed_names" ]; then
  echo "Error: no NAMED screenshot allowlist found in $WORKFLOW" >&2
  exit 1
fi

missing=()
while IFS= read -r name; do
  if ! awk -v expected="$name" '$0 == expected { found = 1 } END { exit !found }' \
      <<< "$committed_names"; then
    missing+=("$name")
  fi
done <<< "$required_names"

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Error: required screenshots omitted from workflow commit allowlist: ${missing[*]}" >&2
  exit 1
fi

echo "Screenshot workflow commits every required capture."
