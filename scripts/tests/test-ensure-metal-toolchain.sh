#!/bin/bash
# Regression tests for ensure-metal-toolchain.sh. The fake xcodebuild models
# Xcode 27's surprising contract: `-showComponent` may exit 0 while returning
# `{"status":"uninstalled"}`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/ensure-metal-toolchain.sh"
PASS=0
FAIL=0
TEST_ROOT=""

cleanup() {
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

setup_fake_xcodebuild() {
    TEST_ROOT="$(mktemp -d)"
    mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"

    cat > "$TEST_ROOT/bin/xcodebuild" <<'FAKE_XCODEBUILD'
#!/bin/bash
set -euo pipefail

scenario="${TEST_SCENARIO:?}"
state_dir="${TEST_STATE_DIR:?}"

if [ "$#" -eq 3 ] \
    && [ "$1" = "-showComponent" ] \
    && [ "$2" = "MetalToolchain" ] \
    && [ "$3" = "-json" ]; then
    action="show"
elif [ "$#" -eq 2 ] \
    && [ "$1" = "-downloadComponent" ] \
    && [ "$2" = "MetalToolchain" ]; then
    action="download"
else
    echo "unexpected xcodebuild arguments: $*" >&2
    exit 64
fi

case "$action" in
    show)
        case "$scenario" in
            already_installed)
                status="installed"
                ;;
            show_error_then_installed)
                if [ ! -f "$state_dir/downloaded" ]; then
                    exit 70
                fi
                status="installed"
                ;;
            malformed_then_installed)
                if [ ! -f "$state_dir/downloaded" ]; then
                    echo "not-json"
                    exit 0
                fi
                status="installed"
                ;;
            uninstalled_then_installed|download_errors_after_install)
                if [ -f "$state_dir/downloaded" ]; then
                    status="installed"
                else
                    status="uninstalled"
                fi
                ;;
            update_available_then_installed)
                if [ -f "$state_dir/downloaded" ]; then
                    status="installed"
                else
                    status="installedUpdateAvailable"
                fi
                ;;
            delayed_install)
                if [ ! -f "$state_dir/downloaded" ]; then
                    status="uninstalled"
                elif [ -f "$state_dir/post-download-status-seen" ]; then
                    status="installed"
                else
                    touch "$state_dir/post-download-status-seen"
                    status="uninstalled"
                fi
                ;;
            uninstalled_forever|download_fails)
                status="uninstalled"
                ;;
            *)
                echo "unknown test scenario: $scenario" >&2
                exit 64
                ;;
        esac

        printf '{"buildVersion":"test","status":"%s"}\n' "$status"
        ;;
    download)
        count=0
        if [ -f "$state_dir/download-count" ]; then
            count="$(cat "$state_dir/download-count")"
        fi
        echo "$((count + 1))" > "$state_dir/download-count"

        if [ "$scenario" = "download_fails" ]; then
            exit 1
        fi

        touch "$state_dir/downloaded"
        if [ "$scenario" = "download_errors_after_install" ]; then
            exit 1
        fi
        ;;
esac
FAKE_XCODEBUILD
    chmod +x "$TEST_ROOT/bin/xcodebuild"
}

run_installer() {
    PATH="$TEST_ROOT/bin:$PATH" \
        TEST_SCENARIO="$1" \
        TEST_STATE_DIR="$TEST_ROOT/state" \
        METAL_TOOLCHAIN_MAX_ATTEMPTS=3 \
        METAL_TOOLCHAIN_RETRY_DELAY_SECONDS=0 \
        bash "$SCRIPT"
}

download_count() {
    if [ -f "$TEST_ROOT/state/download-count" ]; then
        cat "$TEST_ROOT/state/download-count"
    else
        echo 0
    fi
}

echo "Test 1: installed status skips the download"
setup_fake_xcodebuild
if run_installer already_installed >/dev/null 2>&1 && [ "$(download_count)" -eq 0 ]; then
    pass "already-installed component accepted"
else
    fail "installed component should not be downloaded"
fi
cleanup

echo "Test 2: uninstalled status with exit 0 triggers the download"
setup_fake_xcodebuild
if run_installer uninstalled_then_installed >/dev/null 2>&1 && [ "$(download_count)" -eq 1 ]; then
    pass "uninstalled JSON status rejected and installed"
else
    fail "uninstalled status was treated as installed"
fi
cleanup

echo "Test 3: failed status query triggers the download"
setup_fake_xcodebuild
if run_installer show_error_then_installed >/dev/null 2>&1 && [ "$(download_count)" -eq 1 ]; then
    pass "failed status query recovered"
else
    fail "failed status query did not recover"
fi
cleanup

echo "Test 4: malformed status JSON triggers the download"
setup_fake_xcodebuild
if run_installer malformed_then_installed >/dev/null 2>&1 && [ "$(download_count)" -eq 1 ]; then
    pass "malformed status response recovered"
else
    fail "malformed status response did not recover"
fi
cleanup

echo "Test 5: successful downloads without installed status exhaust retries"
setup_fake_xcodebuild
if run_installer uninstalled_forever >/dev/null 2>&1; then
    fail "uninstalled status should fail after retries"
elif [ "$(download_count)" -eq 3 ]; then
    pass "uninstalled status exhausted all retries"
else
    fail "unexpected retry count for uninstalled status"
fi
cleanup

echo "Test 6: installed component with an update available remains usable"
setup_fake_xcodebuild
if run_installer update_available_then_installed >/dev/null 2>&1 && [ "$(download_count)" -eq 0 ]; then
    pass "installedUpdateAvailable status accepted"
else
    fail "usable installed component was downloaded again"
fi
cleanup

echo "Test 7: delayed installed status avoids a duplicate download"
setup_fake_xcodebuild
if run_installer delayed_install >/dev/null 2>&1 && [ "$(download_count)" -eq 1 ]; then
    pass "delayed installed status accepted after retry delay"
else
    fail "delayed installed status caused a duplicate download"
fi
cleanup

echo "Test 8: installed status wins over a late download error"
setup_fake_xcodebuild
if run_installer download_errors_after_install >/dev/null 2>&1 && [ "$(download_count)" -eq 1 ]; then
    pass "installed component accepted after download command error"
else
    fail "late download error masked the installed status"
fi
cleanup

echo "Test 9: failed downloads exhaust retries"
setup_fake_xcodebuild
if run_installer download_fails >/dev/null 2>&1; then
    fail "failed downloads should return non-zero"
elif [ "$(download_count)" -eq 3 ]; then
    pass "failed downloads exhausted all retries"
else
    fail "unexpected retry count for failed downloads"
fi
cleanup

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
