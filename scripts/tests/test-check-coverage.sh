#!/bin/bash
# Process-level regression tests for the fail-closed coverage gate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="$REPO_ROOT/.github/scripts/check_coverage.py"
WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/xcrun" <<'EOF'
#!/bin/bash
set -euo pipefail

if [ "$#" -lt 5 ] || \
    [ "$1" != "xccov" ] || \
    [ "$2" != "view" ] || \
    [ "$3" != "--report" ] || \
    [ "$4" != "--json" ]; then
    echo "unexpected xcrun invocation: $*" >&2
    exit 64
fi

counter_file="${FAKE_XCCOV_COUNTER:?}"
count=0
if [ -f "$counter_file" ]; then
    count="$(tr -d '[:space:]' < "$counter_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"

case "${FAKE_XCCOV_MODE:-success}" in
    success)
        cat "${FAKE_COVERAGE_JSON:?}"
        ;;
    malformed)
        echo "this is not JSON"
        ;;
    permanent-failure)
        echo "synthetic permanent xccov failure" >&2
        exit 9
        ;;
    transient-then-success)
        if [ "$count" -lt 3 ]; then
            echo "No coverage data in result bundle" >&2
            exit 1
        fi
        cat "${FAKE_COVERAGE_JSON:?}"
        ;;
    hang)
        exec sleep 5
        ;;
    *)
        echo "unknown fake mode: ${FAKE_XCCOV_MODE}" >&2
        exit 64
        ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/xcrun"

cat > "$TEST_ROOT/at-threshold.json" <<'EOF'
{
  "targets": [
    {
      "name": "Pine.app",
      "files": [
        {
          "name": "/checkout/Pine/Logic.swift",
          "coveredLines": 7,
          "executableLines": 10
        },
        {
          "name": "ContentView.swift",
          "coveredLines": 100,
          "executableLines": 100
        }
      ]
    }
  ]
}
EOF

cat > "$TEST_ROOT/below-threshold.json" <<'EOF'
{
  "targets": [
    {
      "name": "Pine.app",
      "files": [
        {
          "name": "Logic.swift",
          "coveredLines": 69,
          "executableLines": 100
        }
      ]
    }
  ]
}
EOF

cat > "$TEST_ROOT/missing-payload.json" <<'EOF'
{"actions": []}
EOF

cat > "$TEST_ROOT/missing-target.json" <<'EOF'
{
  "targets": [
    {
      "name": "PineTests.xctest",
      "files": [
        {
          "name": "Tests.swift",
          "coveredLines": 10,
          "executableLines": 10
        }
      ]
    }
  ]
}
EOF

cat > "$TEST_ROOT/zero-lines.json" <<'EOF'
{
  "targets": [
    {
      "name": "Pine.app",
      "files": [
        {
          "name": "Logic.swift",
          "coveredLines": 0,
          "executableLines": 0
        },
        {
          "name": "ContentView.swift",
          "coveredLines": 10,
          "executableLines": 10
        }
      ]
    }
  ]
}
EOF

cat > "$TEST_ROOT/invalid-lines.json" <<'EOF'
{
  "targets": [
    {
      "name": "Pine.app",
      "files": [
        {
          "name": "Logic.swift",
          "coveredLines": "7",
          "executableLines": 10
        }
      ]
    }
  ]
}
EOF

run_checker() {
    local expected_exit="$1"
    local label="$2"
    shift 2

    set +e
    CHECK_OUTPUT="$("$@" 2>&1)"
    CHECK_STATUS=$?
    set -e

    if [ "$CHECK_STATUS" -ne "$expected_exit" ]; then
        echo "✗ $label: expected exit $expected_exit, got $CHECK_STATUS"
        echo "$CHECK_OUTPUT"
        exit 1
    fi
    echo "✓ $label"
}

new_counter() {
    COUNTER_FILE="$TEST_ROOT/counter-$1"
}

fresh_bundle="$TEST_ROOT/TestResults.xcresult"
mkdir "$fresh_bundle"

new_counter "threshold"
threshold_output="$TEST_ROOT/threshold-output"
threshold_summary="$TEST_ROOT/threshold-summary"
run_checker 0 "coverage at the threshold passes" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/at-threshold.json" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --attempts 1 \
    --github-output "$threshold_output" \
    --github-summary "$threshold_summary"
grep -qF "status=pass" "$threshold_output"
grep -qF "coverage=70.0" "$threshold_output"
grep -qF "covered-lines=7" "$threshold_output"
grep -qF "executable-lines=10" "$threshold_output"
grep -qF "7 / 10 lines" "$threshold_summary"
grep -qF "1 pure SwiftUI/AppKit presentation files (100 lines)" \
    "$threshold_summary"
echo "✓ excluded views do not inflate the logic-only total"

new_counter "above"
run_checker 0 "coverage above the threshold passes" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/at-threshold.json" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 69 \
    --attempts 1

new_counter "below"
below_output="$TEST_ROOT/below-output"
below_summary="$TEST_ROOT/below-summary"
run_checker 1 "coverage below the threshold blocks the job" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/below-threshold.json" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --attempts 1 \
    --github-output "$below_output" \
    --github-summary "$below_summary"
grep -qF "status=below-threshold" "$below_output"
grep -qF "coverage=69.0" "$below_output"
grep -qF "## ❌ Code Coverage: 69.0%" "$below_summary"
echo "✓ below-threshold output is explicit and comment-ready"

missing_output="$TEST_ROOT/missing-output"
missing_summary="$TEST_ROOT/missing-summary"
new_counter "missing"
run_checker 2 "missing result bundle fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/at-threshold.json" \
    python3 "$CHECKER" "$TEST_ROOT/missing.xcresult" \
    --threshold 70 \
    --github-output "$missing_output" \
    --github-summary "$missing_summary"
grep -qF "status=error" "$missing_output"
grep -qF "coverage=" "$missing_output"
grep -qF "Code Coverage unavailable" "$missing_summary"
grep -qF "no passing result was reported" "$missing_summary"
echo "✓ infrastructure errors publish a failing status"

new_counter "permanent"
run_checker 2 "permanent xccov failure fails without retrying" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_XCCOV_MODE="permanent-failure" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/at-threshold.json" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --retry-delay 0
if [ "$(tr -d '[:space:]' < "$COUNTER_FILE")" -ne 1 ]; then
    echo "✗ permanent xccov failure was retried"
    exit 1
fi
echo "✓ permanent xccov failure is not retried"

new_counter "transient"
run_checker 0 "known transient xccov failure retries with a bound" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_XCCOV_MODE="transient-then-success" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/at-threshold.json" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --attempts 3 \
    --retry-delay 0
if [ "$(tr -d '[:space:]' < "$COUNTER_FILE")" -ne 3 ]; then
    echo "✗ transient xccov failure did not stop at the retry bound"
    exit 1
fi
echo "✓ known transient xccov failure retries exactly to the bound"

new_counter "timeout"
run_checker 2 "a hung xccov attempt fails at its own timeout" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_XCCOV_MODE="hang" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/at-threshold.json" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --timeout 0.1
if [ "$(tr -d '[:space:]' < "$COUNTER_FILE")" -ne 1 ]; then
    echo "✗ timed-out xccov attempt was retried"
    exit 1
fi
echo "✓ xccov timeout is bounded and not retried"

run_checker 2 "a non-finite timeout is rejected" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --timeout nan

run_checker 2 "a non-finite retry delay is rejected" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --retry-delay inf

new_counter "malformed"
run_checker 2 "malformed xccov JSON fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_XCCOV_MODE="malformed" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/at-threshold.json" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --attempts 1

new_counter "payload"
run_checker 2 "missing coverage payload fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/missing-payload.json" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --attempts 1

new_counter "target"
run_checker 2 "missing Pine.app coverage fails closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/missing-target.json" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --attempts 1

new_counter "zero"
run_checker 2 "zero executable logic lines fail closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/zero-lines.json" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --attempts 1

new_counter "invalid"
run_checker 2 "malformed line counts fail closed" \
    env \
    PATH="$TEST_ROOT/bin:$PATH" \
    FAKE_XCCOV_COUNTER="$COUNTER_FILE" \
    FAKE_COVERAGE_JSON="$TEST_ROOT/invalid-lines.json" \
    python3 "$CHECKER" "$fresh_bundle" \
    --threshold 70 \
    --attempts 1

coverage_step="$(
    sed -n \
        '/- name: Check Coverage Threshold/,/- name: Comment Coverage on PR/p' \
        "$WORKFLOW"
)"
if grep -qF "continue-on-error: true" <<< "$coverage_step" || \
    ! grep -qF ".github/scripts/check_coverage.py" <<< "$coverage_step"; then
    echo "✗ workflow does not wire the coverage checker as a blocking step"
    exit 1
fi
echo "✓ workflow wires the coverage checker as a blocking step"

comment_step="$(
    sed -n \
        '/- name: Comment Coverage on PR/,/^  [a-zA-Z0-9_-]*:/p' \
        "$WORKFLOW"
)"
if ! grep -qF "if: always() && github.event_name == 'pull_request'" \
    <<< "$comment_step" || \
    ! grep -qF "Code Coverage unavailable" <<< "$comment_step" || \
    ! grep -qF "did not report a passing result" <<< "$comment_step" || \
    ! grep -qF "did not publish a valid result" <<< "$comment_step"; then
    echo "✗ PR comment can leave a missing report described as passing"
    exit 1
fi
echo "✓ PR comment reports missing coverage as a failing gate"

echo "All coverage gate regression tests passed."
