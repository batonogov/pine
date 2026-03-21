#!/bin/bash
# normalize-xcstrings.sh
#
# Pre-commit hook helper: unstages Localizable.xcstrings if the only
# changes are whitespace / key reordering (cosmetic Xcode build artifacts).
#
# Usage:
#   scripts/normalize-xcstrings.sh          — check & unstage if cosmetic-only
#   scripts/normalize-xcstrings.sh --check  — exit 1 if cosmetic diff is staged (CI mode)

set -euo pipefail

XCSTRINGS="Pine/Localizable.xcstrings"

# Ensure we run from repo root (git hooks do this by default,
# but be explicit for standalone usage)
cd "$(git rev-parse --show-toplevel)"

# Only act when the file is staged
if ! git diff --cached --name-only | grep -qx "$XCSTRINGS"; then
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "warning: python3 not found, skipping xcstrings normalization"
    exit 0
fi

# Compare semantic JSON (sorted keys, no whitespace differences)
# On first commit HEAD doesn't exist — HEAD_JSON will be empty,
# which differs from STAGED_JSON, so new files are left staged.
HEAD_JSON=$(git show "HEAD:$XCSTRINGS" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
json.dump(data, sys.stdout, sort_keys=True)
" 2>/dev/null || echo "")

STAGED_JSON=$(git show ":$XCSTRINGS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
json.dump(data, sys.stdout, sort_keys=True)
")

if [ "$HEAD_JSON" = "$STAGED_JSON" ]; then
    if [ "${1:-}" = "--check" ]; then
        echo "xcstrings: only cosmetic changes detected, would unstage"
        exit 1
    fi
    echo "xcstrings: unstaging cosmetic-only changes"
    git checkout HEAD -- "$XCSTRINGS"
    exit 0
fi

# Real changes — leave staged
exit 0
