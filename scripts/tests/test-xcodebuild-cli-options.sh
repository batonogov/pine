#!/bin/bash
# Guard xcodebuild options whose argument requirements differ across Xcode
# releases. Xcode 27 consumes the next token when -test-timeouts-enabled has
# no explicit YES/NO value, which can turn a result-bundle path into an
# "unknown build action".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CI_WORKFLOW="$SCRIPT_DIR/.github/workflows/ci.yml"

timeout_lines="$(
    grep -nF -- '-test-timeouts-enabled' "$CI_WORKFLOW" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        || true
)"
if [ -z "$timeout_lines" ]; then
    echo "✗ CI workflow no longer exercises test timeouts"
    exit 1
fi

timeout_count="$(printf '%s\n' "$timeout_lines" | wc -l | tr -d '[:space:]')"
if [ "$timeout_count" -ne 2 ]; then
    echo "✗ Expected timeout options in the Xcode 26 and Xcode 27 unit-test lanes; found $timeout_count"
    echo "$timeout_lines"
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
