#!/bin/bash
# Tests for normalize-xcstrings.sh
# Usage: scripts/test-normalize-xcstrings.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NORMALIZE="$SCRIPT_DIR/normalize-xcstrings.sh"
PASS=0
FAIL=0

setup_repo() {
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    git init -q
    mkdir -p Pine
    cat > Pine/Localizable.xcstrings << 'XCSTRINGS'
{
  "sourceLanguage" : "en",
  "strings" : {
    "hello" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Hello"
          }
        }
      }
    }
  },
  "version" : "1.0"
}
XCSTRINGS
    git add .
    git commit -q -m "initial"
}

cleanup() {
    cd /
    rm -rf "$TEST_DIR"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        ((FAIL++))
    fi
}

# --- Test 1: cosmetic-only changes are unstaged ---
echo "Test 1: cosmetic-only changes are unstaged"
setup_repo

# Add trailing whitespace (cosmetic change, same JSON semantics)
sed 's/"Hello"/"Hello" /' Pine/Localizable.xcstrings > Pine/Localizable.xcstrings.tmp
mv Pine/Localizable.xcstrings.tmp Pine/Localizable.xcstrings
git add Pine/Localizable.xcstrings

output=$("$NORMALIZE" 2>&1) || true
staged=$(git diff --cached --name-only | grep -c "Localizable.xcstrings" || true)
assert_eq "cosmetic changes unstaged" "0" "$staged"
assert_eq "output mentions unstaging" "1" "$(echo "$output" | grep -c 'unstaging' || true)"

cleanup

# --- Test 2: real changes are kept staged ---
echo "Test 2: real changes are kept staged"
setup_repo

# Add a new string (real change)
cat > Pine/Localizable.xcstrings << 'XCSTRINGS'
{
  "sourceLanguage" : "en",
  "strings" : {
    "hello" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Hello"
          }
        }
      }
    },
    "world" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "World"
          }
        }
      }
    }
  },
  "version" : "1.0"
}
XCSTRINGS
git add Pine/Localizable.xcstrings

"$NORMALIZE" 2>&1 || true
staged=$(git diff --cached --name-only | grep -c "Localizable.xcstrings" || true)
assert_eq "real changes stay staged" "1" "$staged"

cleanup

# --- Test 3: file not staged — script exits silently ---
echo "Test 3: file not staged — script is no-op"
setup_repo

# Modify but don't stage
echo "modified" >> Pine/Localizable.xcstrings
"$NORMALIZE" 2>&1 || true
assert_eq "exits cleanly when not staged" "0" "$?"

cleanup

# --- Test 4: --check mode returns exit code 1 for cosmetic ---
echo "Test 4: --check mode for cosmetic changes"
setup_repo

sed 's/"Hello"/"Hello" /' Pine/Localizable.xcstrings > Pine/Localizable.xcstrings.tmp
mv Pine/Localizable.xcstrings.tmp Pine/Localizable.xcstrings
git add Pine/Localizable.xcstrings

if "$NORMALIZE" --check 2>&1; then
    assert_eq "--check exits non-zero for cosmetic" "1" "0"
else
    assert_eq "--check exits non-zero for cosmetic" "1" "1"
fi

cleanup

# --- Test 5: --check mode returns exit code 0 for real changes ---
echo "Test 5: --check mode for real changes"
setup_repo

cat > Pine/Localizable.xcstrings << 'XCSTRINGS'
{
  "sourceLanguage" : "en",
  "strings" : {
    "hello" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Changed"
          }
        }
      }
    }
  },
  "version" : "1.0"
}
XCSTRINGS
git add Pine/Localizable.xcstrings

if "$NORMALIZE" --check 2>&1; then
    assert_eq "--check exits zero for real changes" "0" "0"
else
    assert_eq "--check exits zero for real changes" "0" "1"
fi

cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
