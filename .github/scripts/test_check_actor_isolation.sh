#!/bin/bash
# test_check_actor_isolation.sh — tests for check_actor_isolation.sh
#
# Runs the checker against test fixtures and verifies expected results.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/check_actor_isolation.sh"
FIXTURES="$SCRIPT_DIR/test-fixtures"
PASS=0
FAIL=0

assert_pass() {
    local fixture="$1"
    local desc="$2"
    if bash "$CHECKER" "$fixture" > /dev/null 2>&1; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc (expected pass, got violation)"
        ((FAIL++))
    fi
}

assert_fail() {
    local fixture="$1"
    local desc="$2"
    if bash "$CHECKER" "$fixture" > /dev/null 2>&1; then
        echo "  FAIL: $desc (expected violation, got pass)"
        ((FAIL++))
    else
        echo "  PASS: $desc"
        ((PASS++))
    fi
}

echo "Running actor isolation checker tests..."
echo ""

# Good cases — should pass (exit 0)
assert_pass "$FIXTURES/Good_Nonisolated.swift" "nonisolated class with DispatchQueue(label:) passes"
assert_pass "$FIXTURES/Good_ExplicitMainActor.swift" "explicit @MainActor class passes"
assert_pass "$FIXTURES/Good_MainQueue.swift" "class using only DispatchQueue.main passes"
assert_pass "$FIXTURES/Good_Enum.swift" "enum with DispatchQueue.global() passes"

# Bad cases — should fail (exit 1)
assert_fail "$FIXTURES/Bad_ImplicitMainActor.swift" "implicit MainActor class with DispatchQueue(label:) fails"
assert_fail "$FIXTURES/Bad_OperationQueue.swift" "implicit MainActor class with OperationQueue() fails"
assert_fail "$FIXTURES/Bad_GlobalQueue.swift" "implicit MainActor class with DispatchQueue.global() fails"

# Run against actual Pine/ directory and report (informational, don't fail test suite)
echo ""
echo "Running against Pine/ codebase..."
if bash "$CHECKER" Pine/ 2>&1; then
    echo "  Codebase check: CLEAN"
else
    echo "  Codebase check: violations found (see above)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) tests"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
