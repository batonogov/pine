#!/bin/bash
# Guard the scheduled sanitizer manifest and its fail-closed workflow contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
WORKFLOW="$REPO_ROOT/.github/workflows/nightly-sanitizers.yml"
MANIFEST="$REPO_ROOT/.github/sanitizer-test-manifest.txt"
POLICY="$REPO_ROOT/.github/SANITIZER_TESTING.md"

fail() {
    echo "Error: $1" >&2
    exit 1
}

require_count() {
    local expected="$1"
    local pattern="$2"
    local file="$3"
    local actual
    actual="$(grep -cF -- "$pattern" "$file" || true)"
    if [ "$actual" -ne "$expected" ]; then
        fail "expected $expected occurrences of '$pattern' in ${file#$REPO_ROOT/}, found $actual"
    fi
}

[ -f "$WORKFLOW" ] || fail "missing nightly sanitizer workflow"
[ -f "$MANIFEST" ] || fail "missing sanitizer test manifest"
[ -f "$POLICY" ] || fail "missing sanitizer policy"

require_count 1 "  address-sanitizer:" "$WORKFLOW"
require_count 1 "  thread-sanitizer:" "$WORKFLOW"
require_count 1 "  schedule:" "$WORKFLOW"
require_count 1 "  workflow_dispatch:" "$WORKFLOW"
require_count 1 "-enableAddressSanitizer YES" "$WORKFLOW"
require_count 1 "-enableThreadSanitizer YES" "$WORKFLOW"
require_count 2 ".github/sanitizer-test-manifest.txt" "$WORKFLOW"
require_count 2 ".github/scripts/validate_test_results.py" "$WORKFLOW"
require_count 2 "-enableCodeCoverage NO" "$WORKFLOW"
require_count 2 "-parallel-testing-enabled NO" "$WORKFLOW"
require_count 2 "-test-timeouts-enabled YES" "$WORKFLOW"
require_count 2 'test_exit=${PIPESTATUS[0]}' "$WORKFLOW"
require_count 2 "        if: always()" "$WORKFLOW"
require_count 2 "if-no-files-found: warn" "$WORKFLOW"
require_count 2 "abort_on_error=1:halt_on_error=1:log_path=" "$WORKFLOW"

if grep -q -- '-retry-tests-on-failure' "$WORKFLOW"; then
    fail "sanitizer findings must never be retried"
fi
if grep -qE 'continue-on-error:[[:space:]]*true' "$WORKFLOW"; then
    fail "sanitizer jobs must fail when their test command fails"
fi

suites="$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$MANIFEST")"
suite_count="$(printf '%s\n' "$suites" | grep -c . || true)"
if [ "$suite_count" -lt 10 ] || [ "$suite_count" -gt 20 ]; then
    fail "manifest must contain 10-20 bounded representative suites (found $suite_count)"
fi

duplicates="$(printf '%s\n' "$suites" | sort | uniq -d)"
[ -z "$duplicates" ] || fail "manifest contains duplicate suites: $duplicates"

required_suites=(
    PineTests/UserTaskRunnerTests
    PineTests/TerminalMetalRendererTests
    PineTests/AgentDetectionCoordinatorTests
    PineTests/AgentTaskRegistryTests
    PineTests/FileSystemWatcherTests
    PineTests/LSPProcessTransportTests
    PineTests/ProjectRegistryTests
    PineTests/TerminationSaveCoordinatorSecurityTests
)
for required in "${required_suites[@]}"; do
    if ! grep -qxF -- "$required" <<< "$suites"; then
        fail "manifest is missing representative suite $required"
    fi
done

while IFS= read -r suite; do
    if ! grep -qE '^PineTests/[A-Za-z0-9_]+Tests$' <<< "$suite"; then
        fail "invalid manifest entry: $suite"
    fi
    type_name="${suite#PineTests/}"
    if ! grep -RqsE --include='*.swift' \
        "struct[[:space:]]+$type_name" "$REPO_ROOT/PineTests"; then
        fail "manifest suite does not exist: $suite"
    fi
done <<< "$suites"

grep -qF "30 consecutive scheduled runs" "$POLICY" \
    || fail "policy must define the consecutive-run promotion threshold"
grep -qF "95% infrastructure completion" "$POLICY" \
    || fail "policy must define the infrastructure stability threshold"
grep -qF "No suppressions are currently used" "$POLICY" \
    || fail "policy must document the suppression baseline"

echo "Sanitizer workflow and $suite_count-suite manifest satisfy the fail-closed contract."
