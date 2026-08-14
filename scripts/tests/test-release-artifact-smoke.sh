#!/bin/bash
# Portable regression tests for the signed release artifact smoke orchestrator.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SMOKE_SCRIPT="$REPO_ROOT/scripts/release-artifact-smoke.sh"
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
if [ "$#" -eq 0 ]; then
    printf 'ProductName:\tmacOS\nProductVersion:\t%s\nBuildVersion:\tTEST\n' \
        "${TEST_OS_VERSION:-26.0}"
elif [ "${1:-}" = "-productVersion" ]; then
    echo "${TEST_OS_VERSION:-26.0}"
else
    exit 64
fi
FAKE

    cat > "$TEST_ROOT/bin/PlistBuddy" <<'FAKE'
#!/bin/bash
set -euo pipefail
command_text="${2:-}"
plist_path="${3:-}"
case "$command_text" in
    *dev-entry*)
        case "$plist_path" in
            *candidate*) echo disk-candidate ;;
            *) echo disk-previous ;;
        esac
        ;;
    *CFBundleShortVersionString*)
        case "$plist_path" in
            *candidate*) echo "${TEST_CANDIDATE_VERSION:?}" ;;
            *) echo "${TEST_PREVIOUS_VERSION:?}" ;;
        esac
        ;;
    *CFBundleVersion*)
        case "$plist_path" in
            *candidate*) echo "${TEST_CANDIDATE_BUILD:?}" ;;
            *) echo "${TEST_PREVIOUS_BUILD:?}" ;;
        esac
        ;;
    *)
        echo "unexpected PlistBuddy command: $*" >&2
        exit 64
        ;;
esac
FAKE

    cat > "$TEST_ROOT/bin/hdiutil" <<'FAKE'
#!/bin/bash
set -euo pipefail
printf 'hdiutil %s\n' "$*" >> "${TEST_COMMAND_LOG:?}"
case "${1:-}" in
    attach)
        mount_point=""
        image=""
        previous=""
        for argument in "$@"; do
            if [ "$previous" = "-mountpoint" ]; then
                mount_point="$argument"
            fi
            image="$argument"
            previous="$argument"
        done
        [ -n "$mount_point" ] || exit 64
        case "$(basename "$image")" in
            candidate.dmg) image_root="${TEST_CANDIDATE_IMAGE:?}" ;;
            previous.dmg) image_root="${TEST_PREVIOUS_IMAGE:?}" ;;
            *) exit 64 ;;
        esac
        mkdir -p "$mount_point"
        cp -R "$image_root/." "$mount_point/"
        echo plist
        ;;
    detach)
        ;;
    *)
        exit 64
        ;;
esac
FAKE

    cat > "$TEST_ROOT/bin/diskutil" <<'FAKE'
#!/bin/bash
set -euo pipefail
printf 'diskutil %s\n' "$*" >> "${TEST_COMMAND_LOG:?}"
if [ "${1:-}" = "image" ] && [ "${2:-}" = "--plist" ] \
    && [ "${3:-}" = "attach" ]; then
    mount_point=""
    image=""
    previous=""
    for argument in "$@"; do
        if [ "$previous" = "--mountPoint" ]; then
            mount_point="$argument"
        fi
        image="$argument"
        previous="$argument"
    done
    case "$(basename "$image")" in
        candidate.dmg) image_root="${TEST_CANDIDATE_IMAGE:?}" ;;
        previous.dmg) image_root="${TEST_PREVIOUS_IMAGE:?}" ;;
        *) exit 64 ;;
    esac
    mkdir -p "$mount_point"
    cp -R "$image_root/." "$mount_point/"
    echo plist
elif [ "${1:-}" = "eject" ]; then
    :
else
    exit 64
fi
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

    for security_tool in codesign spctl xcrun; do
        cat > "$TEST_ROOT/bin/$security_tool" <<'FAKE'
#!/bin/bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >> "${TEST_COMMAND_LOG:?}"
if [ "$(basename "$0")" = "xcrun" ]; then
    case "$*" in
        *--show-sdk-version*) echo 26.0 ;;
        *--show-sdk-build-version*) echo TESTSDK ;;
    esac
fi
FAKE
    done

    cat > "$TEST_ROOT/bin/xcodebuild" <<'FAKE'
#!/bin/bash
set -euo pipefail
printf 'xcodebuild %s\n' "$*" >> "${TEST_COMMAND_LOG:?}"
if [ "${1:-}" = "-version" ]; then
    printf 'Xcode 26.0\nBuild version TEST\n'
    exit 0
fi
derived_data=""
result_bundle=""
previous=""
for argument in "$@"; do
    if [ "$previous" = "-derivedDataPath" ]; then
        derived_data="$argument"
    elif [ "$previous" = "-resultBundlePath" ]; then
        result_bundle="$argument"
    fi
    previous="$argument"
done

if printf '%s\n' "$*" | grep -q -- '-scheme sparkle-cli'; then
    printf '%s\n' "$*" | grep -q 'MACOSX_DEPLOYMENT_TARGET=26.0' \
        || exit 67
    executable="$derived_data/Build/Products/Release/sparkle.app/Contents/MacOS/sparkle"
    mkdir -p "$(dirname "$executable")"
    printf '#!/bin/bash\nexit 0\n' > "$executable"
    chmod +x "$executable"
    exit 0
fi

for variable in \
    PINE_RELEASE_SMOKE_CANDIDATE_APP \
    PINE_RELEASE_SMOKE_UPDATE_APP \
    PINE_RELEASE_SMOKE_APPCAST_URL \
    PINE_RELEASE_SMOKE_CANDIDATE_DMG \
    PINE_RELEASE_SMOKE_USER_ROOT; do
    [ -n "${!variable:-}" ] || {
        echo "missing test environment: $variable" >&2
        exit 65
    }
done
[ -n "$result_bundle" ] || exit 66
mkdir -p "$result_bundle"
printf 'fake xcresult\n' > "$result_bundle/Info.plist"
if [ "${TEST_MUTATE_CANDIDATE:-0}" = "1" ]; then
    printf 'mutated\n' >> "$PINE_RELEASE_SMOKE_CANDIDATE_DMG"
fi
exit "${TEST_XCODEBUILD_STATUS:-0}"
FAKE

    cat > "$TEST_ROOT/bin/log" <<'FAKE'
#!/bin/bash
echo 'fake unified log'
FAKE

    cat > "$TEST_ROOT/bin/open" <<'FAKE'
#!/bin/bash
exit 0
FAKE

    chmod +x "$TEST_ROOT/bin/"*
}

setup_fixture() {
    cleanup
    TEST_ROOT="$(mktemp -d)"
    mkdir -p \
        "$TEST_ROOT/bin" \
        "$TEST_ROOT/candidate-image/Pine.app/Contents" \
        "$TEST_ROOT/previous-image/Pine.app/Contents" \
        "$TEST_ROOT/Sparkle/Sparkle.xcodeproj"
    printf 'candidate artifact bytes\n' > "$TEST_ROOT/candidate.dmg"
    printf 'previous artifact bytes\n' > "$TEST_ROOT/previous.dmg"
    printf 'candidate plist\n' \
        > "$TEST_ROOT/candidate-image/Pine.app/Contents/Info.plist"
    printf 'previous plist\n' \
        > "$TEST_ROOT/previous-image/Pine.app/Contents/Info.plist"
    : > "$TEST_ROOT/commands.log"

    candidate_length="$(wc -c < "$TEST_ROOT/candidate.dmg" | tr -d ' ')"
    cat > "$TEST_ROOT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:version>200</sparkle:version>
      <sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>
      <enclosure url="https://example.invalid/Pine-2.0.0.dmg"
        sparkle:edSignature="public-signature"
        length="$candidate_length"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF
    write_fakes
}

run_smoke() {
    PATH="$TEST_ROOT/bin:$PATH" \
    PLISTBUDDY="$TEST_ROOT/bin/PlistBuddy" \
    TEST_OS_VERSION="${TEST_OS_VERSION:-26.0}" \
    TEST_COMMAND_LOG="$TEST_ROOT/commands.log" \
    TEST_CANDIDATE_IMAGE="$TEST_ROOT/candidate-image" \
    TEST_PREVIOUS_IMAGE="$TEST_ROOT/previous-image" \
    TEST_CANDIDATE_VERSION=2.0.0 \
    TEST_CANDIDATE_BUILD=200 \
    TEST_PREVIOUS_VERSION=1.9.0 \
    TEST_PREVIOUS_BUILD=150 \
    TEST_XCODEBUILD_STATUS="${TEST_XCODEBUILD_STATUS:-0}" \
    TEST_MUTATE_CANDIDATE="${TEST_MUTATE_CANDIDATE:-0}" \
    SPARKLE_PRIVATE_KEY="must-not-appear-in-diagnostics" \
    bash "$SMOKE_SCRIPT" \
        "$TEST_ROOT/candidate.dmg" \
        "$TEST_ROOT/previous.dmg" \
        2.0.0 \
        200 \
        "$TEST_ROOT/appcast.xml" \
        "$TEST_ROOT/Sparkle" \
        "$TEST_ROOT/output"
}

echo "Test 1: candidate and previous signed artifacts reach the release gate"
setup_fixture
if run_smoke > "$TEST_ROOT/run.log" 2>&1 \
    && [ -d "$TEST_ROOT/output/ReleaseArtifactSmoke.xcresult" ] \
    && grep -q 'candidateVersion=2.0.0' \
        "$TEST_ROOT/output/metadata/release-smoke.txt" \
    && grep -q 'previousVersion=1.9.0' \
        "$TEST_ROOT/output/metadata/release-smoke.txt" \
    && grep -q -- '-only-testing:PineUITests/ReleaseArtifactSmokeTests' \
        "$TEST_ROOT/commands.log" \
    && [ "$(grep -c '^codesign --verify' "$TEST_ROOT/commands.log")" -eq 2 ] \
    && ! grep -R -q 'must-not-appear-in-diagnostics' "$TEST_ROOT/output"; then
    pass "signed candidate lifecycle and update orchestration"
else
    cat "$TEST_ROOT/run.log"
    fail "happy-path orchestration"
fi

echo "Test 2: xcodebuild failure preserves diagnostics and fails closed"
setup_fixture
export TEST_XCODEBUILD_STATUS=42
if run_smoke > "$TEST_ROOT/run.log" 2>&1; then
    fail "xcodebuild failure was accepted"
elif [ -d "$TEST_ROOT/output/ReleaseArtifactSmoke.xcresult" ] \
    && [ -f "$TEST_ROOT/output/logs/processes.txt" ] \
    && grep -q 'failed with status 42' "$TEST_ROOT/run.log"; then
    pass "test failure and diagnostics retained"
else
    cat "$TEST_ROOT/run.log"
    fail "xcodebuild failure handling"
fi
unset TEST_XCODEBUILD_STATUS

echo "Test 3: candidate bytes are immutable across the gate"
setup_fixture
export TEST_MUTATE_CANDIDATE=1
if run_smoke > "$TEST_ROOT/run.log" 2>&1; then
    fail "mutated candidate was accepted"
elif grep -q 'candidate DMG changed' "$TEST_ROOT/run.log"; then
    pass "candidate mutation rejected"
else
    cat "$TEST_ROOT/run.log"
    fail "candidate mutation diagnostic"
fi
unset TEST_MUTATE_CANDIDATE

echo "Test 4: appcast signature metadata is required"
setup_fixture
sed -i.bak 's/sparkle:edSignature=/sparkle:missingSignature=/' \
    "$TEST_ROOT/appcast.xml"
if run_smoke > "$TEST_ROOT/run.log" 2>&1; then
    fail "unsigned appcast was accepted"
elif grep -q 'EdDSA signature is missing' "$TEST_ROOT/run.log"; then
    pass "unsigned appcast rejected"
else
    cat "$TEST_ROOT/run.log"
    fail "appcast signature diagnostic"
fi

echo "Test 5: macOS 27 uses diskutil image for both release DMGs"
setup_fixture
export TEST_OS_VERSION=27.0
if run_smoke > "$TEST_ROOT/run.log" 2>&1 \
    && [ "$(grep -c '^diskutil image --plist attach ' "$TEST_ROOT/commands.log")" -eq 2 ] \
    && ! grep -q '^hdiutil ' "$TEST_ROOT/commands.log"; then
    pass "macOS 27 disk image compatibility path"
else
    cat "$TEST_ROOT/run.log"
    fail "macOS 27 disk image path"
fi
unset TEST_OS_VERSION

echo "Test 6: release workflow tests before upload and verifies published bytes"
smoke_line="$(grep -n 'name: Run signed release artifact smoke' \
    "$RELEASE_WORKFLOW" | cut -d: -f1 || true)"
upload_line="$(grep -n 'name: Upload DMG to GitHub Release' \
    "$RELEASE_WORKFLOW" | cut -d: -f1 || true)"
if [ -n "$smoke_line" ] \
    && [ -n "$upload_line" ] \
    && [ "$smoke_line" -lt "$upload_line" ] \
    && grep -q 'release-artifact-smoke.sh' "$RELEASE_WORKFLOW" \
    && grep -q 'candidate-before-publication.sha256' "$RELEASE_WORKFLOW" \
    && grep -q 'candidate-after-publication.sha256' "$RELEASE_WORKFLOW" \
    && grep -q 'name: Upload release smoke diagnostics' "$RELEASE_WORKFLOW"; then
    pass "release workflow gate and publication hash checks"
else
    fail "release workflow integration"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
