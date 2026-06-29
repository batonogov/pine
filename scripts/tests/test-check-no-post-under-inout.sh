#!/bin/bash
# Tests for check-no-post-under-inout.py
# Pins the contract of the static guard that prevents the Swift runtime
# exclusivity-abort reentrancy class (Pine #1066): a NotificationCenter
# post inside an `inout` function is flagged unless marked deferred.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-no-post-under-inout.py"
PASS=0
FAIL=0

pass() {
    echo "  ✓ $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  ✗ $1"
    FAIL=$((FAIL + 1))
}

TMP=""

cleanup() {
    [ -n "$TMP" ] && rm -rf "$TMP"
    TMP=""
}
trap cleanup EXIT

# --- Test 1: synchronous post under inout is FLAGGED ---
echo "Test 1: synchronous post under inout is flagged"
TMP=$(mktemp -d)
cat > "$TMP/Bad.swift" <<'EOF'
enum Bad {
    static func save(tabs: inout [String]) {
        NotificationCenter.default.post(name: Notification.Name("x"), object: nil)
    }
}
EOF
if python3 "$SCRIPT" "$TMP" >/dev/null 2>&1; then
    fail "violation not detected"
else
    pass "violation detected (exit non-zero)"
fi
rm -rf "$TMP"; TMP=""

# --- Test 2: post OUTSIDE the inout scope is clean ---
echo "Test 2: post outside the inout scope is clean"
TMP=$(mktemp -d)
cat > "$TMP/Good.swift" <<'EOF'
enum Good {
    static func save(tabs: inout [String]) -> String {
        tabs[0] = "ok"
        return tabs[0]
    }
    static func caller() {
        NotificationCenter.default.post(name: Notification.Name("x"), object: nil)
    }
}
EOF
if python3 "$SCRIPT" "$TMP" >/dev/null 2>&1; then
    pass "no false positive (post is outside inout scope)"
else
    fail "false positive on caller-side post"
fi
rm -rf "$TMP"; TMP=""

# --- Test 3: deferred post with reentrancy-safe marker is clean ---
echo "Test 3: deferred post with reentrancy-safe marker is clean"
TMP=$(mktemp -d)
cat > "$TMP/Deferred.swift" <<'EOF'
enum Deferred {
    static func save(tabs: inout [String]) {
        DispatchQueue.main.async {
            // reentrancy-safe
            NotificationCenter.default.post(name: Notification.Name("x"), object: nil)
        }
    }
}
EOF
if python3 "$SCRIPT" "$TMP" >/dev/null 2>&1; then
    pass "deferred post with reentrancy-safe marker accepted"
else
    fail "false positive on deferred (suppressed) post"
fi
rm -rf "$TMP"; TMP=""

# --- Test 4: multi-line inout signature is flagged ---
echo "Test 4: multi-line inout signature is flagged"
TMP=$(mktemp -d)
cat > "$TMP/Multi.swift" <<'EOF'
enum Multi {
    static func save(
        at index: Int,
        tabs: inout [String],
        extra: Int
    ) {
        NotificationCenter.default.post(name: Notification.Name("y"), object: nil)
    }
}
EOF
if python3 "$SCRIPT" "$TMP" >/dev/null 2>&1; then
    fail "multi-line inout violation not detected"
else
    pass "multi-line inout signature violation detected"
fi
rm -rf "$TMP"; TMP=""

# --- Test 5: the real production tree is clean (regression baseline) ---
echo "Test 5: production Pine/ tree is clean"
if python3 "$SCRIPT" "$SCRIPT_DIR/../Pine" >/dev/null 2>&1; then
    pass "Pine/ has no inout-post reentrancy violations"
else
    fail "Pine/ has inout-post violations — guard would block CI"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
