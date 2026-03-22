#!/bin/bash
# reset-cosmetic-xcstrings.sh
#
# Run Script build phase: resets Localizable.xcstrings to HEAD if the only
# changes are whitespace / key reordering (cosmetic Xcode build artifacts).
# This keeps `git status` clean after every build.
#
# Usage:
#   scripts/reset-cosmetic-xcstrings.sh          — reset if cosmetic-only
#   scripts/reset-cosmetic-xcstrings.sh --check  — exit 1 if cosmetic diff exists (CI mode)

set -euo pipefail

XCSTRINGS="Pine/Localizable.xcstrings"

# Ensure we run from repo root
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo "${SOURCE_ROOT:-.}")"

# Not a git repo — skip silently (e.g. archived source)
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exit 0
fi

# File not modified — nothing to do
if git diff --quiet -- "$XCSTRINGS" 2>/dev/null; then
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "warning: python3 not found, skipping xcstrings normalization"
    exit 0
fi

# Compare semantic JSON: sort keys, ignore whitespace
HEAD_JSON=$(git show "HEAD:$XCSTRINGS" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
json.dump(data, sys.stdout, sort_keys=True)
" 2>/dev/null || echo "")

WORKING_JSON=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
json.dump(data, sys.stdout, sort_keys=True)
" < "$XCSTRINGS" 2>/dev/null || echo "")

if [ -z "$HEAD_JSON" ] || [ -z "$WORKING_JSON" ]; then
    # Can't parse — leave as is
    exit 0
fi

if [ "$HEAD_JSON" = "$WORKING_JSON" ]; then
    if [ "${1:-}" = "--check" ]; then
        echo "xcstrings: only cosmetic changes detected"
        exit 1
    fi
    echo "xcstrings: resetting cosmetic-only changes"
    git checkout HEAD -- "$XCSTRINGS"
fi

exit 0
