#!/bin/bash
# Guard the bounded lifecycle soak and its fail-closed evidence contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
WORKFLOW="$REPO_ROOT/.github/workflows/nightly-lifecycle-soak.yml"
SOAK_TEST="$REPO_ROOT/PinePerformanceTests/LifecycleResourceSoakTests.swift"
SUMMARY="$REPO_ROOT/.github/scripts/summarize_lifecycle_soak.py"
FIXTURE="$REPO_ROOT/PinePerformanceTests/Fixtures/codex"

fail() {
    echo "Error: $1" >&2
    exit 1
}

require_text() {
    local pattern="$1"
    local file="$2"
    grep -qF -- "$pattern" "$file" \
        || fail "missing '$pattern' in ${file#$REPO_ROOT/}"
}

for file in "$WORKFLOW" "$SOAK_TEST" "$SUMMARY" "$FIXTURE"; do
    [ -f "$file" ] || fail "missing ${file#$REPO_ROOT/}"
done

require_text "  schedule:" "$WORKFLOW"
require_text "  workflow_dispatch:" "$WORKFLOW"
require_text "default: '100'" "$WORKFLOW"
require_text "PINE_SOAK_SEED: '1443'" "$WORKFLOW"
require_text "alternating-coregraphics-automatic" "$WORKFLOW"
require_text "-only-testing:PinePerformanceTests/LifecycleResourceSoakTests/testLifecycleResourceSoak" "$WORKFLOW"
require_text "-maximum-parallel-testing-workers 1" "$WORKFLOW"
require_text "LifecycleSoakResults.xcresult" "$WORKFLOW"
require_text "LifecycleSoakArtifacts" "$WORKFLOW"
require_text "--signpost" "$WORKFLOW"
require_text "Create or Update Persistent Regression Issue" "$WORKFLOW"
require_text "[nightly-soak] Lifecycle resource regression" "$WORKFLOW"
require_text "previous" "$WORKFLOW"

if grep -qF -- "PINE_DISABLE_METAL" "$WORKFLOW"; then
    fail "the soak must leave automatic renderer cycles available"
fi

required_test_evidence=(
    "cycle.isMultiple(of: 2)"
    "fixtureFileCount = 512"
    "case coreGraphics"
    "case automatic"
    "usage.ru_maxrss"
    "idleCPUSeconds"
    "hasActiveFileWatcherForTesting"
    "AgentDetector(maxSessionHistory: 4)"
    "Fixtures/codex"
    "exerciseLSPCrashAndRestart"
    "shutdownGracefully"
    "descriptorNoiseAllowance"
    "minimumHardMemoryBytes"
)
for evidence in "${required_test_evidence[@]}"; do
    require_text "$evidence" "$SOAK_TEST"
done

require_text 'subprocess.Popen(["/bin/sleep", "30"])' "$FIXTURE"
require_text 'report is None' "$SUMMARY"
require_text 'has_regression' "$SUMMARY"

echo "Lifecycle soak workflow satisfies the bounded fail-closed contract."
