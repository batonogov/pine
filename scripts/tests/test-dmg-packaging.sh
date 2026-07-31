#!/bin/bash
# Portable regression tests for Pine's macOS DMG packager and verifier.
# macOS-only tools are replaced with small fakes so the CI lint job can cover
# both the macOS 26 hdiutil path and the macOS 27 diskutil image path on Linux.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CREATE_DMG="$REPO_ROOT/scripts/create-dmg.sh"
VERIFY_DMG="$REPO_ROOT/scripts/verify-dmg.sh"
BACKGROUND="$REPO_ROOT/assets/dmg/background@2x.png"
BACKGROUND_SOURCE="$REPO_ROOT/assets/dmg/background.svg"
RELEASE_WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
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

write_fakes() {
    cat > "$TEST_ROOT/bin/uname" <<'FAKE'
#!/bin/bash
echo Darwin
FAKE

    cat > "$TEST_ROOT/bin/sw_vers" <<'FAKE'
#!/bin/bash
[ "${1:-}" = "-productVersion" ] || exit 64
echo "${TEST_OS_VERSION:-27.0}"
FAKE

    cat > "$TEST_ROOT/bin/PlistBuddy" <<'FAKE'
#!/bin/bash
set -euo pipefail
command_text="${2:-}"
case "$command_text" in
    *dev-entry*)
        echo disk99
        ;;
    *mount-point*)
        echo "${TEST_CREATE_MOUNT:?}"
        ;;
    *CFBundleShortVersionString*)
        echo "${TEST_ACTUAL_VERSION:-1.0}"
        ;;
    *CFBundleIdentifier*)
        echo "${TEST_BUNDLE_ID:-io.github.batonogov.pine}"
        ;;
    *)
        exit 1
        ;;
esac
FAKE

    cat > "$TEST_ROOT/bin/ditto" <<'FAKE'
#!/bin/bash
set -euo pipefail
source_path="$1"
destination_path="$2"
if [ -d "$source_path" ]; then
    mkdir -p "$destination_path"
    cp -R "$source_path/." "$destination_path/"
else
    mkdir -p "$(dirname "$destination_path")"
    cp "$source_path" "$destination_path"
fi
FAKE

    cat > "$TEST_ROOT/bin/diskutil" <<'FAKE'
#!/bin/bash
set -euo pipefail
printf 'diskutil %s\n' "$*" >> "${TEST_COMMAND_LOG:?}"

if [ "${1:-}" = "image" ] && [ "${2:-}" = "create" ] \
    && [ "${3:-}" = "blank" ]; then
    for last_argument in "$@"; do :; done
    : > "$last_argument"
elif [ "${1:-}" = "image" ] && [ "${2:-}" = "--plist" ] \
    && [ "${3:-}" = "attach" ]; then
    mount_point="${TEST_CREATE_MOUNT:?}"
    previous=""
    for argument in "$@"; do
        if [ "$previous" = "--mountPoint" ]; then
            mount_point="$argument"
        fi
        previous="$argument"
    done
    mkdir -p "$mount_point"
    if [ -n "${TEST_IMAGE_ROOT:-}" ]; then
        cp -R "$TEST_IMAGE_ROOT/." "$mount_point/"
    fi
    echo plist
elif [ "${1:-}" = "eject" ]; then
    [ -d "${TEST_CREATE_MOUNT:-}" ] && rm -rf "$TEST_CREATE_MOUNT"
elif [ "${1:-}" = "image" ] && [ "${2:-}" = "create" ] \
    && [ "${3:-}" = "from" ]; then
    for last_argument in "$@"; do :; done
    : > "$last_argument"
elif [ "${1:-}" = "image" ] && [ "${2:-}" = "info" ]; then
    exit 0
else
    echo "unexpected diskutil arguments: $*" >&2
    exit 64
fi
FAKE

    cat > "$TEST_ROOT/bin/hdiutil" <<'FAKE'
#!/bin/bash
set -euo pipefail
printf 'hdiutil %s\n' "$*" >> "${TEST_COMMAND_LOG:?}"
case "${1:-}" in
    create)
        for last_argument in "$@"; do :; done
        : > "$last_argument"
        ;;
    attach)
        mount_point="${TEST_CREATE_MOUNT:?}"
        previous=""
        for argument in "$@"; do
            if [ "$previous" = "-mountpoint" ]; then
                mount_point="$argument"
            fi
            previous="$argument"
        done
        mkdir -p "$mount_point"
        if [ -n "${TEST_IMAGE_ROOT:-}" ]; then
            cp -R "$TEST_IMAGE_ROOT/." "$mount_point/"
        fi
        echo plist
        ;;
    detach)
        [ -d "${TEST_CREATE_MOUNT:-}" ] && rm -rf "$TEST_CREATE_MOUNT"
        ;;
    convert)
        output_path=""
        previous=""
        for argument in "$@"; do
            if [ "$previous" = "-o" ]; then
                output_path="$argument"
            fi
            previous="$argument"
        done
        [ -n "$output_path" ] || exit 64
        : > "$output_path"
        ;;
    verify)
        exit 0
        ;;
    *)
        echo "unexpected hdiutil arguments: $*" >&2
        exit 64
        ;;
esac
FAKE

    cat > "$TEST_ROOT/bin/osascript" <<'FAKE'
#!/bin/bash
set -euo pipefail
mount_point="$3"
printf 'finder-layout\n' > "$mount_point/.DS_Store"
mkdir -p "${TEST_CAPTURE:?}"
cp -R "$mount_point/." "$TEST_CAPTURE/"
rm -rf "$mount_point"
FAKE

    cat > "$TEST_ROOT/bin/sips" <<'FAKE'
#!/bin/bash
for last_argument in "$@"; do :; done
printf '%s:\n  pixelWidth: %s\n  pixelHeight: %s\n' \
    "$last_argument" \
    "${TEST_BACKGROUND_WIDTH:-1320}" \
    "${TEST_BACKGROUND_HEIGHT:-840}"
FAKE

    for security_tool in codesign spctl xcrun; do
        cat > "$TEST_ROOT/bin/$security_tool" <<'FAKE'
#!/bin/bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >> "${TEST_COMMAND_LOG:?}"
FAKE
    done

    chmod +x "$TEST_ROOT/bin/"*
}

setup_fixture() {
    cleanup
    TEST_ROOT="$(mktemp -d)"
    mkdir -p \
        "$TEST_ROOT/bin" \
        "$TEST_ROOT/app/Pine.app/Contents" \
        "$TEST_ROOT/image/.background" \
        "$TEST_ROOT/image/Pine.app/Contents" \
        "$TEST_ROOT/output"
    : > "$TEST_ROOT/commands.log"
    : > "$TEST_ROOT/input.dmg"
    printf 'plist\n' > "$TEST_ROOT/app/Pine.app/Contents/Info.plist"
    printf 'plist\n' > "$TEST_ROOT/image/Pine.app/Contents/Info.plist"
    printf 'finder-layout\n' > "$TEST_ROOT/image/.DS_Store"
    cp "$BACKGROUND" "$TEST_ROOT/image/.background/background@2x.png"
    ln -s /Applications "$TEST_ROOT/image/Applications"
    write_fakes
}

run_create() {
    os_version="$1"
    shift
    PATH="$TEST_ROOT/bin:$PATH" \
        PLISTBUDDY="$TEST_ROOT/bin/PlistBuddy" \
        TEST_OS_VERSION="$os_version" \
        TEST_CREATE_MOUNT="$TEST_ROOT/create-mount" \
        TEST_CAPTURE="$TEST_ROOT/capture" \
        TEST_COMMAND_LOG="$TEST_ROOT/commands.log" \
        bash "$CREATE_DMG" "$@"
}

run_verify() {
    os_version="$1"
    shift
    PATH="$TEST_ROOT/bin:$PATH" \
        PLISTBUDDY="$TEST_ROOT/bin/PlistBuddy" \
        TEST_OS_VERSION="$os_version" \
        TEST_CREATE_MOUNT="$TEST_ROOT/create-mount" \
        TEST_IMAGE_ROOT="$TEST_ROOT/image" \
        TEST_COMMAND_LOG="$TEST_ROOT/commands.log" \
        TEST_ACTUAL_VERSION="${TEST_ACTUAL_VERSION:-1.0}" \
        TEST_BUNDLE_ID="${TEST_BUNDLE_ID:-io.github.batonogov.pine}" \
        TEST_BACKGROUND_WIDTH="${TEST_BACKGROUND_WIDTH:-1320}" \
        TEST_BACKGROUND_HEIGHT="${TEST_BACKGROUND_HEIGHT:-840}" \
        bash "$VERIFY_DMG" "$@"
}

echo "Test 1: macOS 27 creates a branded image with diskutil image"
setup_fixture
if run_create 27.0 \
    "$TEST_ROOT/app/Pine.app" "$TEST_ROOT/output/Pine.dmg" \
    >/dev/null 2>&1 \
    && [ -f "$TEST_ROOT/output/Pine.dmg" ] \
    && [ -d "$TEST_ROOT/capture/Pine.app" ] \
    && [ -L "$TEST_ROOT/capture/Applications" ] \
    && [ "$(readlink "$TEST_ROOT/capture/Applications")" = "/Applications" ] \
    && [ -f "$TEST_ROOT/capture/.background/background@2x.png" ] \
    && grep -q '^diskutil image create blank ' "$TEST_ROOT/commands.log" \
    && grep -q '^diskutil image create from ' "$TEST_ROOT/commands.log"; then
    pass "macOS 27 content and compression path"
else
    fail "macOS 27 image creation"
fi

echo "Test 2: macOS 26 retains the hdiutil compatibility path"
setup_fixture
if run_create 26.0 \
    "$TEST_ROOT/app/Pine.app" "$TEST_ROOT/output/Pine.dmg" \
    >/dev/null 2>&1 \
    && grep -q '^hdiutil create ' "$TEST_ROOT/commands.log" \
    && grep -q '^hdiutil convert ' "$TEST_ROOT/commands.log" \
    && ! grep -q '^diskutil ' "$TEST_ROOT/commands.log"; then
    pass "macOS 26 hdiutil path"
else
    fail "macOS 26 compatibility path"
fi

echo "Test 3: existing output fails closed without --overwrite"
setup_fixture
: > "$TEST_ROOT/output/Pine.dmg"
if run_create 27.0 \
    "$TEST_ROOT/app/Pine.app" "$TEST_ROOT/output/Pine.dmg" \
    >"$TEST_ROOT/output.log" 2>&1; then
    fail "existing output was overwritten"
elif grep -q 'output already exists' "$TEST_ROOT/output.log"; then
    pass "existing output protected"
else
    fail "existing-output diagnostic"
fi

echo "Test 4: verifier checks layout, version, and all security tools"
setup_fixture
if run_verify 27.0 "$TEST_ROOT/input.dmg" 1.0 >/dev/null 2>&1 \
    && grep -q '^codesign --verify --deep --strict ' "$TEST_ROOT/commands.log" \
    && grep -q '^xcrun stapler validate ' "$TEST_ROOT/commands.log" \
    && grep -q '^spctl --assess --type execute ' "$TEST_ROOT/commands.log"; then
    pass "release security checks invoked"
else
    fail "release verifier happy path"
fi

echo "Test 5: local verification can explicitly skip security"
setup_fixture
if run_verify 27.0 --skip-security "$TEST_ROOT/input.dmg" 1.0 \
    >/dev/null 2>&1 \
    && ! grep -qE '^(codesign|xcrun|spctl) ' "$TEST_ROOT/commands.log"; then
    pass "explicit local security opt-out"
else
    fail "skip-security behavior"
fi

echo "Test 6: unexpected visible files are rejected"
setup_fixture
printf 'stray\n' > "$TEST_ROOT/image/README.txt"
if run_verify 27.0 --skip-security "$TEST_ROOT/input.dmg" 1.0 \
    >"$TEST_ROOT/output.log" 2>&1; then
    fail "stray visible file was accepted"
elif grep -q 'unexpected visible items' "$TEST_ROOT/output.log"; then
    pass "stray visible file rejected"
else
    fail "stray-file diagnostic"
fi

echo "Test 7: bundle version mismatches are rejected"
setup_fixture
export TEST_ACTUAL_VERSION=2.0
if run_verify 27.0 --skip-security "$TEST_ROOT/input.dmg" 1.0 \
    >"$TEST_ROOT/output.log" 2>&1; then
    fail "wrong bundle version was accepted"
elif grep -q 'version mismatch' "$TEST_ROOT/output.log"; then
    pass "wrong bundle version rejected"
else
    fail "version-mismatch diagnostic"
fi
unset TEST_ACTUAL_VERSION

echo "Test 8: non-Retina artwork is rejected"
setup_fixture
export TEST_BACKGROUND_WIDTH=660
export TEST_BACKGROUND_HEIGHT=420
if run_verify 27.0 --skip-security "$TEST_ROOT/input.dmg" 1.0 \
    >"$TEST_ROOT/output.log" 2>&1; then
    fail "non-Retina artwork was accepted"
elif grep -q 'Retina background must be 1320x840' "$TEST_ROOT/output.log"; then
    pass "non-Retina artwork rejected"
else
    fail "Retina-dimension diagnostic"
fi
unset TEST_BACKGROUND_WIDTH TEST_BACKGROUND_HEIGHT

echo "Test 9: verifier mounts with hdiutil on macOS 26"
setup_fixture
if run_verify 26.0 --skip-security "$TEST_ROOT/input.dmg" 1.0 \
    >/dev/null 2>&1 \
    && grep -q '^hdiutil attach ' "$TEST_ROOT/commands.log" \
    && ! grep -q '^diskutil ' "$TEST_ROOT/commands.log"; then
    pass "macOS 26 verifier path"
else
    fail "macOS 26 verifier compatibility"
fi

echo "Test 10: release workflow verifies the final versioned artifact"
verify_step="$(sed -n \
    '/- name: Verify branded DMG/,/- name: Download Sparkle tools/p' \
    "$RELEASE_WORKFLOW")"
if grep -q 'bash scripts/create-dmg.sh' "$RELEASE_WORKFLOW" \
    && printf '%s\n' "$verify_step" | grep -q 'bash scripts/verify-dmg.sh' \
    && ! printf '%s\n' "$verify_step" | grep -q -- '--skip-security' \
    && grep -q 'sign_update.*Pine-${VERSION}.dmg' "$RELEASE_WORKFLOW" \
    && grep -q 'shasum -a 256.*Pine-${VERSION}.dmg' "$RELEASE_WORKFLOW"; then
    pass "release artifact invariants preserved"
else
    fail "release workflow integration"
fi

echo "Test 11: editable and rendered artwork retain Retina geometry"
if grep -q 'width="1320" height="840" viewBox="0 0 660 420"' \
    "$BACKGROUND_SOURCE" \
    && python3 - "$BACKGROUND" <<'PYTHON'
import struct
import sys

with open(sys.argv[1], "rb") as image:
    header = image.read(24)

if header[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit(1)

width, height = struct.unpack(">II", header[16:24])
raise SystemExit(0 if (width, height) == (1320, 840) else 1)
PYTHON
then
    pass "Retina source and PNG geometry"
else
    fail "Retina artwork geometry"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
