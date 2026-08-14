#!/bin/bash
# Regression tests for the release-smoke loopback update feed server.
#
# The server exists because http.server.HTTPServer resolves its bound address
# with socket.getfqdn(); that reverse DNS lookup stalled on a GitHub Actions
# runner and took the whole v2.3.3 release with it (Pine #1465). Test 2 pins
# exactly that: with every resolver entry point wedged, the port must still be
# published and requests must still be answered.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SERVER="$REPO_ROOT/scripts/appcast-loopback-server.py"
SMOKE_SCRIPT="$REPO_ROOT/scripts/release-artifact-smoke.sh"
PASS=0
FAIL=0
TEST_ROOT=""
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" >/dev/null 2>&1 || true
        SERVER_PID=""
    fi
    [ -n "$TEST_ROOT" ] && rm -rf "$TEST_ROOT"
    TEST_ROOT=""
}
trap cleanup EXIT

pass() {
    echo "  ✓ $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  ✗ $1"
    FAIL=$((FAIL + 1))
}

setup_fixture() {
    cleanup
    TEST_ROOT="$(mktemp -d)"
    mkdir -p "$TEST_ROOT/feed" "$TEST_ROOT/metadata"
    printf 'candidate artifact bytes\n' > "$TEST_ROOT/feed/Pine-2.0.0.dmg"
    printf '<rss></rss>\n' > "$TEST_ROOT/feed/appcast.xml"
    printf 'must-not-be-served\n' > "$TEST_ROOT/outside-the-feed.txt"
}

# Waits up to $2 tenths of a second for a non-empty $1.
wait_for_port() {
    local file="$1"
    local limit="$2"
    local waited=0

    while [ "$waited" -lt "$limit" ]; do
        [ -s "$file" ] && return 0
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

start_server() {
    python3 "$SERVER" "$TEST_ROOT/feed" "$TEST_ROOT/metadata/port.txt" \
        > "$TEST_ROOT/server.log" 2>&1 &
    SERVER_PID="$!"
}

echo "Test 1: the feed server publishes a usable port and serves feed bytes"
setup_fixture
start_server
if wait_for_port "$TEST_ROOT/metadata/port.txt" 100; then
    port="$(tr -d '[:space:]' < "$TEST_ROOT/metadata/port.txt")"
    expected="$(shasum -a 256 "$TEST_ROOT/feed/Pine-2.0.0.dmg" | awk '{print $1}')"
    served="$(curl --fail --silent --show-error --max-time 10 \
        "http://127.0.0.1:$port/Pine-2.0.0.dmg" \
        | shasum -a 256 | awk '{print $1}')"
    case "$port" in
        ''|*[!0-9]*) served="non-numeric-port" ;;
    esac
    if [ "$served" = "$expected" ] \
        && [ ! -e "$TEST_ROOT/metadata/port.txt.partial" ] \
        && curl --fail --silent --show-error --max-time 10 \
            "http://127.0.0.1:$port/appcast.xml" > /dev/null; then
        pass "port published atomically and feed bytes served intact"
    else
        cat "$TEST_ROOT/server.log"
        fail "feed server round trip"
    fi
else
    cat "$TEST_ROOT/server.log"
    fail "feed server never published a port"
fi

echo "Test 2: a wedged resolver cannot stall startup or requests (#1465)"
setup_fixture
mkdir -p "$TEST_ROOT/resolver-trap"
cat > "$TEST_ROOT/resolver-trap/sitecustomize.py" <<'PYTHON'
import socket
import time


def _wedged(*args, **kwargs):
    time.sleep(600)
    raise AssertionError("resolver must not be consulted")


socket.getfqdn = _wedged
socket.gethostbyaddr = _wedged
socket.getnameinfo = _wedged
PYTHON
PYTHONPATH="$TEST_ROOT/resolver-trap" python3 "$SERVER" \
    "$TEST_ROOT/feed" "$TEST_ROOT/metadata/port.txt" \
    > "$TEST_ROOT/server.log" 2>&1 &
SERVER_PID="$!"
if wait_for_port "$TEST_ROOT/metadata/port.txt" 50; then
    port="$(tr -d '[:space:]' < "$TEST_ROOT/metadata/port.txt")"
    if curl --fail --silent --show-error --max-time 5 \
        "http://127.0.0.1:$port/appcast.xml" > /dev/null; then
        pass "binds and serves without any name resolution"
    else
        cat "$TEST_ROOT/server.log"
        fail "request stalled on the resolver"
    fi
else
    cat "$TEST_ROOT/server.log"
    fail "startup stalled on the resolver"
fi

echo "Test 3: a stale port file fails closed instead of misdirecting the gate"
setup_fixture
printf '1\n' > "$TEST_ROOT/metadata/port.txt"
if python3 "$SERVER" "$TEST_ROOT/feed" "$TEST_ROOT/metadata/port.txt" \
    > "$TEST_ROOT/server.log" 2>&1; then
    fail "stale port file was accepted"
elif [ "$(tr -d '[:space:]' < "$TEST_ROOT/metadata/port.txt")" = "1" ] \
    && grep -q 'port file already exists' "$TEST_ROOT/server.log"; then
    pass "stale port file rejected without overwriting it"
else
    cat "$TEST_ROOT/server.log"
    fail "stale port file diagnostic"
fi

echo "Test 4: wrong argument count is a usage error"
setup_fixture
status=0
python3 "$SERVER" "$TEST_ROOT/feed" > "$TEST_ROOT/server.log" 2>&1 || status=$?
if [ "$status" -eq 64 ] && grep -q 'usage:' "$TEST_ROOT/server.log"; then
    pass "usage error reported for missing arguments"
else
    cat "$TEST_ROOT/server.log"
    fail "usage error handling (status $status)"
fi

echo "Test 5: a missing feed root is rejected before any port is published"
setup_fixture
status=0
python3 "$SERVER" "$TEST_ROOT/feed/absent" "$TEST_ROOT/metadata/port.txt" \
    > "$TEST_ROOT/server.log" 2>&1 || status=$?
if [ "$status" -eq 66 ] \
    && [ ! -e "$TEST_ROOT/metadata/port.txt" ] \
    && grep -q 'feed root is not a directory' "$TEST_ROOT/server.log"; then
    pass "missing feed root rejected with no port published"
else
    cat "$TEST_ROOT/server.log"
    fail "missing feed root handling (status $status)"
fi

echo "Test 6: the feed server does not serve paths outside the feed root"
setup_fixture
start_server
if wait_for_port "$TEST_ROOT/metadata/port.txt" 100; then
    port="$(tr -d '[:space:]' < "$TEST_ROOT/metadata/port.txt")"
    escape="$(curl --silent --show-error --path-as-is --max-time 10 \
        "http://127.0.0.1:$port/../outside-the-feed.txt" || true)"
    if ! printf '%s' "$escape" | grep -q 'must-not-be-served'; then
        pass "path traversal out of the feed root refused"
    else
        fail "feed server served a file outside its root"
    fi
else
    cat "$TEST_ROOT/server.log"
    fail "feed server never published a port"
fi

echo "Test 7: the release gate uses the shared server and a real startup budget"
if grep -q 'scripts/appcast-loopback-server.py' "$SMOKE_SCRIPT" \
    && grep -q 'PINE_RELEASE_SMOKE_SERVER_TIMEOUT:-30' "$SMOKE_SCRIPT" \
    && ! grep -q 'ThreadingHTTPServer' "$SMOKE_SCRIPT"; then
    pass "release gate wired to the shared loopback server"
else
    fail "release gate integration"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
