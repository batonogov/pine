#!/bin/bash
# Tests for reset-cosmetic-xcstrings.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/reset-cosmetic-xcstrings.sh"
PASS=0
FAIL=0
TMPDIR=""

setup_repo() {
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    mkdir -p Pine
}

cleanup() {
    cd /tmp
    [ -n "$TMPDIR" ] && rm -rf "$TMPDIR"
    TMPDIR=""
}

pass() {
    echo "  ✓ $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  ✗ $1: $2"
    FAIL=$((FAIL + 1))
}

# --- Test 1: cosmetic-only changes are reset ---
echo "Test 1: cosmetic-only changes are reset"
setup_repo
cat > Pine/Localizable.xcstrings << 'EOF'
{
  "sourceLanguage" : "en",
  "strings" : {
    "hello" : {
      "extractionState" : "manual"
    }
  },
  "version" : "1.0"
}
EOF
git add -A && git commit -q -m "init"

# Simulate Xcode reformatting (reordered keys, same semantic content)
cat > Pine/Localizable.xcstrings << 'EOF'
{
  "version" : "1.0",
  "sourceLanguage" : "en",
  "strings" : {
    "hello" : {
      "extractionState" : "manual"
    }
  }
}
EOF

bash "$SCRIPT"
if git diff --quiet -- Pine/Localizable.xcstrings; then
    pass "file was reset to HEAD"
else
    fail "file still has changes" "$(git diff --stat)"
fi
cleanup

# --- Test 2: real changes are preserved ---
echo "Test 2: real changes are preserved"
setup_repo
cat > Pine/Localizable.xcstrings << 'EOF'
{
  "sourceLanguage" : "en",
  "strings" : {
    "hello" : {
      "extractionState" : "manual"
    }
  },
  "version" : "1.0"
}
EOF
git add -A && git commit -q -m "init"

# Add a new key (real change)
cat > Pine/Localizable.xcstrings << 'EOF'
{
  "sourceLanguage" : "en",
  "strings" : {
    "hello" : {
      "extractionState" : "manual"
    },
    "goodbye" : {
      "extractionState" : "manual"
    }
  },
  "version" : "1.0"
}
EOF

bash "$SCRIPT"
if git diff --quiet -- Pine/Localizable.xcstrings; then
    fail "file was reset" "real changes should be preserved"
else
    pass "real changes preserved"
fi
cleanup

# --- Test 3: no changes — no-op ---
echo "Test 3: no changes — no-op"
setup_repo
cat > Pine/Localizable.xcstrings << 'EOF'
{
  "sourceLanguage" : "en",
  "strings" : {},
  "version" : "1.0"
}
EOF
git add -A && git commit -q -m "init"

bash "$SCRIPT"
if git diff --quiet -- Pine/Localizable.xcstrings; then
    pass "no changes, no-op"
else
    fail "unexpected changes" "$(git diff --stat)"
fi
cleanup

# --- Test 4: --check mode returns exit code 1 for cosmetic changes ---
echo "Test 4: --check mode returns exit code 1"
setup_repo
cat > Pine/Localizable.xcstrings << 'EOF'
{
  "sourceLanguage" : "en",
  "strings" : {
    "key" : {
      "extractionState" : "manual"
    }
  },
  "version" : "1.0"
}
EOF
git add -A && git commit -q -m "init"

# Reorder keys (cosmetic)
cat > Pine/Localizable.xcstrings << 'EOF'
{
  "version" : "1.0",
  "strings" : {
    "key" : {
      "extractionState" : "manual"
    }
  },
  "sourceLanguage" : "en"
}
EOF

if bash "$SCRIPT" --check > /dev/null 2>&1; then
    fail "--check should exit 1" "exited 0"
else
    pass "--check exits 1 for cosmetic changes"
fi
# File should NOT be reset in --check mode
if git diff --quiet -- Pine/Localizable.xcstrings; then
    fail "file was reset in --check mode" "should only report, not reset"
else
    pass "file not reset in --check mode"
fi
cleanup

# --- Test 5: --check mode returns 0 for real changes ---
echo "Test 5: --check mode returns 0 for real changes"
setup_repo
cat > Pine/Localizable.xcstrings << 'EOF'
{
  "sourceLanguage" : "en",
  "strings" : {},
  "version" : "1.0"
}
EOF
git add -A && git commit -q -m "init"

cat > Pine/Localizable.xcstrings << 'EOF'
{
  "sourceLanguage" : "en",
  "strings" : {
    "new_key" : {
      "extractionState" : "manual"
    }
  },
  "version" : "1.0"
}
EOF

if bash "$SCRIPT" --check > /dev/null 2>&1; then
    pass "--check exits 0 for real changes"
else
    fail "--check should exit 0" "exited 1"
fi
cleanup

# --- Test 6: not a git repo — silent exit ---
echo "Test 6: not a git repo — silent exit"
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
mkdir -p Pine
echo '{}' > Pine/Localizable.xcstrings
bash "$SCRIPT"
pass "silent exit outside git repo"
cleanup

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
