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

xcode_27_block="$(
    sed -n \
        '/- name: Unit Tests with Xcode 27/,/^  unit-tests:/p' \
        "$CI_WORKFLOW"
)"
all_parallel_lines="$(
    grep -nF -- '-parallel-testing-enabled' "$CI_WORKFLOW" || true
)"
xcode_27_parallel_lines="$(
    printf '%s\n' "$xcode_27_block" \
        | grep -F -- '-parallel-testing-enabled' \
        || true
)"

if [ "$(printf '%s\n' "$all_parallel_lines" | grep -c . || true)" -ne 1 ] \
    || [ "$(printf '%s\n' "$xcode_27_parallel_lines" | grep -c . || true)" -ne 1 ] \
    || ! printf '%s\n' "$xcode_27_parallel_lines" \
        | grep -qF -- '-parallel-testing-enabled NO'; then
    echo "✗ The Xcode 27 unit-test lane must be the only serialized lane and pass an explicit NO value"
    echo "$all_parallel_lines"
    exit 1
fi

echo "✓ Only the Xcode 27 unit-test lane disables parallel testing"
