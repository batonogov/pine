#!/bin/bash
# Guard the macOS SourceKit lint lane and its fail-closed contract (#1546):
# statement_position is skipped silently on Linux, so the Linux lane must
# detect rule drift and the macOS lane must prove the rule actually runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
SWIFT_LINT_CONFIG="$REPO_ROOT/.swiftlint.yml"

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

[ -f "$WORKFLOW" ] || fail "missing CI workflow"
[ -f "$SWIFT_LINT_CONFIG" ] || fail "missing SwiftLint config"

# ── macOS lane block ────────────────────────────────────────────────────────
# From the lint-sourcekit job key to the next job key.
lane_block="$(sed -n '/^  lint-sourcekit:/,/^  build:/p' "$WORKFLOW")"
[ -n "$lane_block" ] || fail "lint-sourcekit lane is missing from the CI workflow"

require_in_lane() {
    local pattern="$1"
    printf '%s\n' "$lane_block" | grep -qF -- "$pattern" \
        || fail "lint-sourcekit lane is missing required invariant: $pattern"
}

require_lane_count() {
    local expected="$1"
    local pattern="$2"
    local actual
    actual="$(printf '%s\n' "$lane_block" | grep -cF -- "$pattern" || true)"
    if [ "$actual" -ne "$expected" ]; then
        fail "expected $expected occurrences of '$pattern' in the lint-sourcekit lane, found $actual"
    fi
}

require_in_lane "runs-on: macos-26"
require_in_lane "timeout-minutes: 15"
require_in_lane "SWIFTLINT_VERSION: \""
require_in_lane "SWIFTLINT_MACOS_SHA256: \""
require_in_lane "releases/download/\${SWIFTLINT_VERSION}/portable_swiftlint.zip"
require_in_lane "shasum -a 256 -c -"
require_in_lane "uses: ./.github/actions/select-xcode"
require_in_lane "swiftlint-portable/swiftlint version"
require_in_lane "parent_config: .swiftlint.yml"
require_in_lane "only_rules:"
require_in_lane "- statement_position"
require_in_lane 'warning: .*\((statement_position)\)'
require_in_lane '"$RUNNER_TEMP/smoke-lint.log"'
require_in_lane '"$RUNNER_TEMP/sourcekit-lint.log"'
require_in_lane '"$RUNNER_TEMP/sourcekit-smoke"'

# Both skip paths of SwiftLint 0.65.1 must be watched in BOTH lane steps:
# the per-rule warning and the per-file sourcekitd degradation.
require_lane_count 2 "Skipping enabled rule|sourcekitd has failed"
require_lane_count 2 "--config .swiftlint-sourcekit.yml"

if grep -qE 'continue-on-error:[[:space:]]*true' <<<"$lane_block"; then
    fail "the SourceKit lane must fail on skipped or degraded rules"
fi

# ── Linux lane drift guard ──────────────────────────────────────────────────
# The Linux lane must keep detecting rules OTHER than statement_position being
# skipped there (statement_position is expected — it lives in the macOS lane).
require_count 1 "grep -vxF statement_position" "$WORKFLOW"
require_count 4 "Skipping enabled rule" "$WORKFLOW"

# ── Pin contract: three fields, identical version in both lanes ────────────
require_count 1 'SWIFTLINT_SHA256: "' "$WORKFLOW"
require_count 1 'SWIFTLINT_MACOS_SHA256: "' "$WORKFLOW"

versions="$(grep -E '^[[:space:]]*SWIFTLINT_VERSION: "' "$WORKFLOW" \
    | sed -E 's/.*SWIFTLINT_VERSION: "([^"]+)".*/\1/')"
version_lines="$(wc -l <<<"$versions" | tr -d '[:space:]')"
unique_versions="$(sort -u <<<"$versions" | wc -l | tr -d '[:space:]')"
if [ "$version_lines" -ne 2 ] || [ "$unique_versions" -ne 1 ]; then
    fail "both lint lanes must pin the same SWIFTLINT_VERSION"
fi

# ── The rule must stay enabled in the base config ───────────────────────────
# Disabling it in .swiftlint.yml would reintroduce the silent hole the macOS
# lane exists to close.
disabled_statement_position="$(
    awk '/^disabled_rules:/{in_section=1; next}
         /^[A-Za-z_]+:/{in_section=0}
         in_section && /statement_position/{print; exit}' "$SWIFT_LINT_CONFIG"
)"
if [ -n "$disabled_statement_position" ]; then
    fail "statement_position must not be disabled in .swiftlint.yml — enforcement lives in the macOS SourceKit lane (#1546)"
fi

# ── Self-wiring: the lint job must run this guard ───────────────────────────
require_count 1 "bash scripts/tests/test-sourcekit-lint-workflow.sh" "$WORKFLOW"

echo "SourceKit lint lane satisfies the fail-closed contract (#1546)."
