#!/bin/bash
# Guard the real SourceKit-LSP smoke workflow and its fail-closed contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
WORKFLOW="$REPO_ROOT/.github/workflows/nightly-sourcekit-lsp.yml"
POLICY="$REPO_ROOT/.github/SOURCEKIT_LSP_SMOKE.md"
SMOKE_TEST="$REPO_ROOT/PineTests/SourceKitLSPIntegrationTests.swift"
SCHEME="$REPO_ROOT/Pine.xcodeproj/xcshareddata/xcschemes/Pine.xcscheme"

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

[ -f "$WORKFLOW" ] || fail "missing SourceKit-LSP workflow"
[ -f "$POLICY" ] || fail "missing SourceKit-LSP policy"
[ -f "$SCHEME" ] || fail "missing shared Pine scheme"

require_count 1 "  schedule:" "$WORKFLOW"
require_count 1 "  workflow_dispatch:" "$WORKFLOW"
require_count 1 "PINE_RUN_SOURCEKIT_LSP_SMOKE: \"1\"" "$WORKFLOW"
require_count 1 "xcrun --find sourcekit-lsp" "$WORKFLOW"
require_count 1 '"$DEVELOPER_DIR"/*' "$WORKFLOW"
require_count 1 "-only-testing:PineTests/SourceKitLSPIntegrationTests" "$WORKFLOW"
require_count 1 ".github/scripts/validate_test_results.py" "$WORKFLOW"
require_count 1 'test_exit=${PIPESTATUS[0]}' "$WORKFLOW"
require_count 1 "PINE_SOURCEKIT_LSP_ARTIFACTS_DIR:" "$WORKFLOW"
require_count 4 "SourceKitLSPArtifacts" "$WORKFLOW"
require_count 2 "SourceKitLSPResults.xcresult" "$WORKFLOW"
require_count 1 "        if: always()" "$WORKFLOW"
require_count 1 "retention-days: 14" "$WORKFLOW"
require_count 1 "-parallel-testing-enabled NO" "$WORKFLOW"
require_count 1 "-test-timeouts-enabled YES" "$WORKFLOW"

if grep -q -- '-retry-tests-on-failure' "$WORKFLOW"; then
    fail "the real-server smoke must preserve its initial failure"
fi
if grep -qE 'continue-on-error:[[:space:]]*true' "$WORKFLOW"; then
    fail "the real-server smoke must fail on test or toolchain errors"
fi
if [ "$(grep -c -- '-only-testing:' "$WORKFLOW" || true)" -ne 1 ]; then
    fail "the scheduled lane must run only the SourceKit-LSP smoke suite"
fi

require_count 1 'key = "PINE_RUN_SOURCEKIT_LSP_SMOKE"' "$SCHEME"
require_count 1 'value = "$(PINE_RUN_SOURCEKIT_LSP_SMOKE)"' "$SCHEME"
require_count 1 'key = "PINE_SOURCEKIT_LSP_EXECUTABLE"' "$SCHEME"
require_count 1 'value = "$(PINE_SOURCEKIT_LSP_EXECUTABLE)"' "$SCHEME"
require_count 1 'key = "PINE_SOURCEKIT_LSP_ARTIFACTS_DIR"' "$SCHEME"
require_count 1 'value = "$(PINE_SOURCEKIT_LSP_ARTIFACTS_DIR)"' "$SCHEME"

required_test_evidence=(
    'client.didChange('
    'step: "publishDiagnostics after didChange"'
    'case .failure:'
    'case .cancellation:'
    'case .timeout:'
    'waitForProcessExit('
    'PINE_SOURCEKIT_LSP_EXECUTABLE'
    'PINE_SOURCEKIT_LSP_ARTIFACTS_DIR'
    'result["HOME"] = isolatedHome'
    'result["XDG_CONFIG_HOME"]'
    'result["XDG_CACHE_HOME"]'
    'result["SWIFTPM_CONFIG_DIR"]'
)
for evidence in "${required_test_evidence[@]}"; do
    grep -qF -- "$evidence" "$SMOKE_TEST" \
        || fail "smoke suite is missing required evidence: $evidence"
done

grep -qF "30 consecutive scheduled runs" "$POLICY" \
    || fail "policy must define a consecutive-run promotion threshold"
grep -qF "95% infrastructure completion" "$POLICY" \
    || fail "policy must define an infrastructure stability threshold"
grep -qF "leaked SourceKit-LSP processes" "$POLICY" \
    || fail "policy must reject leaked language-server processes"

echo "SourceKit-LSP workflow and real-server smoke satisfy the fail-closed contract."
