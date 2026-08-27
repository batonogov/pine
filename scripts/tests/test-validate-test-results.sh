#!/bin/bash
# Process-level regression tests for validate_test_results.py.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VALIDATOR="$REPO_ROOT/.github/scripts/validate_test_results.py"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/xcrun" <<'EOF'
#!/bin/bash
set -euo pipefail

if [ "${FAKE_XCRESULTTOOL_MODE:-success}" = "failure" ]; then
    echo "synthetic xcresulttool failure" >&2
    exit 9
fi

cat "$FAKE_XCRESULT_JSON"
EOF
chmod +x "$TEST_ROOT/bin/xcrun"

cat > "$TEST_ROOT/passing.json" <<'EOF'
{
  "nodeType": "Test Plan",
  "testNodes": [
    {
      "nodeType": "Test Suite",
      "name": "PineTests",
      "children": [
        {
          "nodeType": "Test Case",
          "name": "passes",
          "result": "Passed",
          "children": []
        },
        {
          "nodeType": "Test Case",
          "name": "skips",
          "result": "Skipped",
          "children": []
        },
        {
          "nodeType": "Test Case",
          "name": "passesOnRetry",
          "result": "Passed",
          "children": [
            {
              "nodeType": "Repetition",
              "name": "Run 1",
              "result": "Failed"
            },
            {
              "nodeType": "Repetition",
              "name": "Run 2",
              "result": "Passed"
            }
          ]
        }
      ]
    }
  ]
}
EOF

cat > "$TEST_ROOT/all-skipped.json" <<'EOF'
{
  "nodeType": "Test Plan",
  "testNodes": [
    {
      "nodeType": "Test Case",
      "name": "skipped",
      "result": "Skipped",
      "children": []
    }
  ]
}
EOF

cat > "$TEST_ROOT/unknown-result.json" <<'EOF'
{
  "nodeType": "Test Plan",
  "testNodes": [
    {
      "nodeType": "Test Case",
      "name": "unknown",
      "result": "Not Run",
      "children": []
    }
  ]
}
EOF

cat > "$TEST_ROOT/empty.json" <<'EOF'
{"nodeType": "Test Plan", "children": []}
EOF

cat > "$TEST_ROOT/invalid.json" <<'EOF'
this is not JSON
EOF

cat > "$TEST_ROOT/failing.json" <<'EOF'
{
  "nodeType": "Test Plan",
  "children": [
    {
      "nodeType": "Test Case",
      "name": "fails",
      "result": "Failed",
      "children": []
    }
  ]
}
EOF

run_validator() {
    local expected_exit="$1"
    local label="$2"
    shift 2

    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e

    if [ "$status" -ne "$expected_exit" ]; then
        echo "✗ $label: expected exit $expected_exit, got $status"
        echo "$output"
        exit 1
    fi
    echo "✓ $label"
}

fresh_bundle="$TEST_ROOT/fresh.xcresult"
# GNU date +%s rounds to the nearest second, so it can report a whole second
# slightly ahead of the bundle mtime set milliseconds later, tripping the
# freshness check this suite exercises. Bias the synthetic start one second
# into the past; the stale-bundle case pins start_time 3600s ahead and keeps
# failing closed (#1576).
start_time="$(( $(date +%s) - 1 ))"
mkdir "$fresh_bundle"

run_validator 0 "successful run reports every result category" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/passing.json" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 0 \
    --started-at "$start_time"

set +e
summary_output="$(
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/passing.json" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 0 \
    --started-at "$start_time" 2>&1
)"
summary_status=$?
set -e
if [ "$summary_status" -ne 0 ] || \
    ! grep -qF \
        "executed=2 passed=2 failed=0 skipped=1 retried=1" \
        <<< "$summary_output"; then
    echo "✗ successful run did not emit the expected explicit summary"
    echo "$summary_output"
    exit 1
fi
echo "✓ successful run emits an explicit summary"

github_summary="$TEST_ROOT/github-summary.md"
run_validator 0 "GitHub summary output succeeds" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/passing.json" \
    GITHUB_STEP_SUMMARY="$github_summary" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 0 \
    --started-at "$start_time" \
    --github-summary
if ! grep -qF "| 2 | 2 | 0 | 1 | 1 |" "$github_summary"; then
    echo "✗ GitHub summary did not contain the expected counts"
    cat "$github_summary"
    exit 1
fi
echo "✓ GitHub summary contains every result category"

run_validator 65 "summary write failure does not mask xcodebuild failure" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/passing.json" \
    GITHUB_STEP_SUMMARY="$TEST_ROOT" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 65 \
    --started-at "$start_time" \
    --github-summary

run_validator 65 "xcodebuild failure is preserved despite zero final failures" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/passing.json" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 65 \
    --started-at "$start_time"

run_validator 2 "missing result bundle fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/passing.json" \
    python3 "$VALIDATOR" "$TEST_ROOT/missing.xcresult" \
    --xcodebuild-exit 0 \
    --started-at "$start_time"

run_validator 2 "empty result bundle fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/empty.json" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 0 \
    --started-at "$start_time"

run_validator 2 "all-skipped bundle fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/all-skipped.json" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 0 \
    --started-at "$start_time"

run_validator 2 "unknown terminal result fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/unknown-result.json" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 0 \
    --started-at "$start_time"

run_validator 2 "xcresulttool failure fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULTTOOL_MODE=failure \
    FAKE_XCRESULT_JSON="$TEST_ROOT/passing.json" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 0 \
    --started-at "$start_time"

run_validator 2 "malformed xcresulttool JSON fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/invalid.json" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 0 \
    --started-at "$start_time"

run_validator 2 "final test failure fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/failing.json" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 0 \
    --started-at "$start_time"

future_start="$((start_time + 3600))"
run_validator 2 "stale result bundle fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCRESULT_JSON="$TEST_ROOT/passing.json" \
    python3 "$VALIDATOR" "$fresh_bundle" \
    --xcodebuild-exit 0 \
    --started-at "$future_start"

echo "All validate_test_results.py regression tests passed."
