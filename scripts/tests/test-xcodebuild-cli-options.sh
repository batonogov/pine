#!/bin/bash
# Guard xcodebuild options whose missing values can shift every later token.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"

timeout_lines="$(
    grep -nF -- '-test-timeouts-enabled' "$CI_WORKFLOW" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        || true
)"

if [ -z "$timeout_lines" ]; then
    echo "✗ CI workflow no longer enables per-test timeouts"
    exit 1
fi

invalid_lines="$(
    printf '%s\n' "$timeout_lines" \
        | grep -vE -- '-test-timeouts-enabled[[:space:]]+YES([[:space:]]|$)' \
        || true
)"

if [ -n "$invalid_lines" ]; then
    echo "✗ Every -test-timeouts-enabled option must pass an explicit YES value:"
    echo "$invalid_lines"
    exit 1
fi

echo "✓ All xcodebuild test-timeout options pass an explicit YES value"
