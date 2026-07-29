#!/bin/bash
# Guard xcodebuild options whose missing values can shift every later token.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"

active_option_lines() {
    local workflow="$1"
    local option="$2"

    printf '%s\n' "$workflow" \
        | grep -nE -- "^[[:space:]]*${option}([[:space:]]|$)" \
        || true
}

line_count() {
    printf '%s\n' "$1" | grep -c . || true
}

named_step_count() {
    local workflow="$1"
    local step_name="$2"

    printf '%s\n' "$workflow" | awk -v target="- name: $step_name" '
        {
            trimmed = $0
            sub(/^[[:space:]]*/, "", trimmed)
            if (trimmed == target) {
                count += 1
            }
        }
        END { print count + 0 }
    '
}

named_step_block() {
    local workflow="$1"
    local step_name="$2"

    printf '%s\n' "$workflow" | awk -v target="- name: $step_name" '
        {
            trimmed = $0
            sub(/^[[:space:]]*/, "", trimmed)
        }
        trimmed == target {
            capture = 1
        }
        capture && trimmed != target {
            if (trimmed ~ /^- name:/ || trimmed ~ /^- uses:/ ||
                $0 ~ /^  [[:alnum:]_-]+:$/) {
                exit
            }
        }
        capture {
            print
        }
    '
}

validate_timeout_options() {
    local workflow="$1"
    local timeout_lines
    local invalid_lines

    timeout_lines="$(active_option_lines "$workflow" '-test-timeouts-enabled')"
    if [ -z "$timeout_lines" ]; then
        echo "✗ CI workflow no longer enables per-test timeouts" >&2
        return 1
    fi

    invalid_lines="$(
        printf '%s\n' "$timeout_lines" \
            | grep -vE -- \
                '-test-timeouts-enabled[[:space:]]+YES([[:space:]]|$)' \
            || true
    )"
    if [ -n "$invalid_lines" ]; then
        echo "✗ Every -test-timeouts-enabled option must pass an explicit YES value:" >&2
        echo "$invalid_lines" >&2
        return 1
    fi
}

validate_serialized_step() {
    local workflow="$1"
    local step_name="$2"
    local label="$3"
    local step_count
    local step_block
    local parallel_lines
    local parallel_count

    step_count="$(named_step_count "$workflow" "$step_name")"
    if [ "$step_count" -ne 1 ]; then
        echo "✗ $label must appear exactly once (found $step_count)" >&2
        return 1
    fi

    step_block="$(named_step_block "$workflow" "$step_name")"
    parallel_lines="$(
        active_option_lines "$step_block" '-parallel-testing-enabled'
    )"
    parallel_count="$(line_count "$parallel_lines")"
    if [ "$parallel_count" -ne 1 ]; then
        echo "✗ $label must contain exactly one active -parallel-testing-enabled option (found $parallel_count)" >&2
        return 1
    fi

    if ! printf '%s\n' "$parallel_lines" \
        | grep -qE -- \
            '-parallel-testing-enabled[[:space:]]+NO([[:space:]]|$)'; then
        echo "✗ $label must pass an explicit NO value to -parallel-testing-enabled" >&2
        echo "$parallel_lines" >&2
        return 1
    fi
}

validate_parallel_options() {
    local workflow="$1"
    local all_parallel_lines
    local all_parallel_count

    validate_serialized_step \
        "$workflow" \
        "Unit Tests with Xcode 27" \
        "The Xcode 27 unit-test lane" \
        || return 1
    validate_serialized_step \
        "$workflow" \
        "Unit Tests" \
        "The macOS 26 unit-test lane" \
        || return 1

    all_parallel_lines="$(
        active_option_lines "$workflow" '-parallel-testing-enabled'
    )"
    all_parallel_count="$(line_count "$all_parallel_lines")"
    if [ "$all_parallel_count" -ne 2 ]; then
        echo "✗ CI workflow must contain exactly two active serialized unit-test options (found $all_parallel_count)" >&2
        echo "$all_parallel_lines" >&2
        return 1
    fi
}

validate_workflow() {
    local workflow="$1"

    validate_timeout_options "$workflow" || return 1
    validate_parallel_options "$workflow" || return 1
}

fixture_workflow() {
    local xcode_27_parallel="$1"
    local macos_26_parallel="$2"
    local extra_parallel="$3"
    local xcode_27_timeout='-test-timeouts-enabled YES \'
    local macos_26_timeout='-test-timeouts-enabled YES \'

    if [ "$#" -ge 4 ]; then
        xcode_27_timeout="$4"
    fi
    if [ "$#" -ge 5 ]; then
        macos_26_timeout="$5"
    fi

    printf '%s\n' \
        'jobs:' \
        '  xcode-27-compatibility:' \
        '    steps:' \
        '      - name: Unit Tests with Xcode 27' \
        '        run: |' \
        '          xcodebuild test \' \
        "            $xcode_27_parallel" \
        "            $xcode_27_timeout" \
        '            -resultBundlePath Xcode27TestResults.xcresult' \
        '  unit-tests:' \
        '    steps:' \
        '      - name: Unit Tests' \
        '        run: |' \
        '          xcodebuild test-without-building \' \
        "            $macos_26_parallel" \
        "            $macos_26_timeout" \
        '            -resultBundlePath TestResults.xcresult' \
        '      - name: Detect Flaky Tests' \
        '        run: python3 .github/scripts/detect_flaky_tests.py' \
        '  ui-tests:' \
        '    steps:' \
        '      - name: UI Tests' \
        '        run: |' \
        '          xcodebuild test-without-building \' \
        "            $extra_parallel" \
        '            -only-testing:PineUITests'
}

assert_fixture_passes() {
    local name="$1"
    local workflow="$2"
    local output

    if ! output="$(validate_workflow "$workflow" 2>&1)"; then
        echo "✗ Fixture '$name' should pass:" >&2
        echo "$output" >&2
        exit 1
    fi
    echo "✓ Fixture '$name' passes"
}

assert_fixture_fails() {
    local name="$1"
    local expected_diagnostic="$2"
    local workflow="$3"
    local output

    if output="$(validate_workflow "$workflow" 2>&1)"; then
        echo "✗ Fixture '$name' should fail" >&2
        exit 1
    fi
    if ! grep -qF -- "$expected_diagnostic" <<< "$output"; then
        echo "✗ Fixture '$name' failed for the wrong reason:" >&2
        echo "$output" >&2
        exit 1
    fi
    echo "✓ Fixture '$name' fails closed: $expected_diagnostic"
}

SERIALIZED='-parallel-testing-enabled NO \'
MISSING_VALUE='-parallel-testing-enabled \'
WRONG_VALUE='-parallel-testing-enabled YES \'
TIMEOUT='-test-timeouts-enabled YES \'
TIMEOUT_MISSING_VALUE='-test-timeouts-enabled \'
TIMEOUT_WRONG_VALUE='-test-timeouts-enabled NO \'

assert_fixture_passes \
    "both unit lanes explicitly serialized" \
    "$(fixture_workflow "$SERIALIZED" "$SERIALIZED" "")"
assert_fixture_passes \
    "commented lookalike outside unit lanes is ignored" \
    "$(fixture_workflow \
        "$SERIALIZED" \
        "$SERIALIZED" \
        '# -parallel-testing-enabled YES')"
assert_fixture_passes \
    "commented lookalike inside a unit lane is ignored" \
    "$(fixture_workflow \
        "$SERIALIZED
            # $WRONG_VALUE" \
        "$SERIALIZED" \
        "")"

assert_fixture_fails \
    "missing Xcode 27 serialization" \
    "The Xcode 27 unit-test lane must contain exactly one active" \
    "$(fixture_workflow "" "$SERIALIZED" "")"
assert_fixture_fails \
    "missing macOS 26 serialization" \
    "The macOS 26 unit-test lane must contain exactly one active" \
    "$(fixture_workflow "$SERIALIZED" "" "")"
assert_fixture_fails \
    "Xcode 27 serialization missing value" \
    "The Xcode 27 unit-test lane must pass an explicit NO value" \
    "$(fixture_workflow "$MISSING_VALUE" "$SERIALIZED" "")"
assert_fixture_fails \
    "macOS 26 serialization missing value" \
    "The macOS 26 unit-test lane must pass an explicit NO value" \
    "$(fixture_workflow "$SERIALIZED" "$MISSING_VALUE" "")"
assert_fixture_fails \
    "Xcode 27 serialization enabled" \
    "The Xcode 27 unit-test lane must pass an explicit NO value" \
    "$(fixture_workflow "$WRONG_VALUE" "$SERIALIZED" "")"
assert_fixture_fails \
    "macOS 26 serialization enabled" \
    "The macOS 26 unit-test lane must pass an explicit NO value" \
    "$(fixture_workflow "$SERIALIZED" "$WRONG_VALUE" "")"
assert_fixture_fails \
    "duplicate serialization in Xcode 27 unit lane" \
    "The Xcode 27 unit-test lane must contain exactly one active" \
    "$(fixture_workflow \
        "$SERIALIZED
            $SERIALIZED" \
        "$SERIALIZED" \
        "")"
assert_fixture_fails \
    "duplicate serialization in macOS 26 unit lane" \
    "The macOS 26 unit-test lane must contain exactly one active" \
    "$(fixture_workflow \
        "$SERIALIZED" \
        "$SERIALIZED
            $SERIALIZED" \
        "")"
assert_fixture_fails \
    "serialization added outside unit lanes" \
    "CI workflow must contain exactly two active serialized unit-test options" \
    "$(fixture_workflow "$SERIALIZED" "$SERIALIZED" "$SERIALIZED")"
assert_fixture_fails \
    "timeout option missing value" \
    "Every -test-timeouts-enabled option must pass an explicit YES value" \
    "$(fixture_workflow \
        "$SERIALIZED" \
        "$SERIALIZED" \
        "" \
        "$TIMEOUT_MISSING_VALUE" \
        "$TIMEOUT")"
assert_fixture_fails \
    "timeout option has wrong value" \
    "Every -test-timeouts-enabled option must pass an explicit YES value" \
    "$(fixture_workflow \
        "$SERIALIZED" \
        "$SERIALIZED" \
        "" \
        "$TIMEOUT" \
        "$TIMEOUT_WRONG_VALUE")"
assert_fixture_fails \
    "timeout options removed" \
    "CI workflow no longer enables per-test timeouts" \
    "$(fixture_workflow "$SERIALIZED" "$SERIALIZED" "" "" "")"

validate_workflow "$(< "$CI_WORKFLOW")"
echo "✓ Every xcodebuild test-timeout option passes an explicit YES value"
echo "✓ Both unit-test lanes disable parallel testing exactly once"
