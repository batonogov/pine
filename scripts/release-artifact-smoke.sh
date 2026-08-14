#!/bin/bash
# Exercise the signed candidate DMG and a real previous release before publish.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/release-artifact-smoke.sh \
  <candidate.dmg> <previous.dmg> <version> <build> \
  <appcast.xml> <Sparkle source> <output-directory>

The output directory is retained as release diagnostics. Both disk images and
the appcast must already exist; the output directory must not exist.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 \
        || die "required command not found: $1"
}

if [ "$#" -ne 7 ]; then
    usage >&2
    exit 64
fi

CANDIDATE_ARGUMENT="$1"
PREVIOUS_ARGUMENT="$2"
EXPECTED_VERSION="$3"
EXPECTED_BUILD="$4"
APPCAST_ARGUMENT="$5"
SPARKLE_SOURCE_ARGUMENT="$6"
OUTPUT_ARGUMENT="$7"

[ "$(uname -s)" = "Darwin" ] \
    || die "release artifact smoke requires macOS"
[ -f "$CANDIDATE_ARGUMENT" ] \
    || die "candidate DMG not found: $CANDIDATE_ARGUMENT"
[ -f "$PREVIOUS_ARGUMENT" ] \
    || die "previous release DMG not found: $PREVIOUS_ARGUMENT"
[ -f "$APPCAST_ARGUMENT" ] \
    || die "appcast not found: $APPCAST_ARGUMENT"
[ -d "$SPARKLE_SOURCE_ARGUMENT/Sparkle.xcodeproj" ] \
    || die "Sparkle source checkout not found: $SPARKLE_SOURCE_ARGUMENT"
[ -n "$EXPECTED_VERSION" ] || die "candidate version must not be empty"
case "$EXPECTED_BUILD" in
    ''|*[!0-9]*) die "candidate build must be numeric: $EXPECTED_BUILD" ;;
esac
[ ! -e "$OUTPUT_ARGUMENT" ] \
    || die "output already exists: $OUTPUT_ARGUMENT"

for required_command in \
    codesign curl ditto find log open ps shasum spctl sw_vers xcodebuild \
    xcrun; do
    require_command "$required_command"
done
require_command python3

PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
[ -x "$PLISTBUDDY" ] || die "PlistBuddy not found: $PLISTBUDDY"

absolute_file() {
    local argument="$1"
    local parent
    parent="$(cd "$(dirname "$argument")" && pwd -P)"
    printf '%s/%s\n' "$parent" "$(basename "$argument")"
}

absolute_directory() {
    (cd "$1" && pwd -P)
}

CANDIDATE_DMG="$(absolute_file "$CANDIDATE_ARGUMENT")"
PREVIOUS_DMG="$(absolute_file "$PREVIOUS_ARGUMENT")"
APPCAST="$(absolute_file "$APPCAST_ARGUMENT")"
SPARKLE_SOURCE="$(absolute_directory "$SPARKLE_SOURCE_ARGUMENT")"
OUTPUT_PARENT="$(cd "$(dirname "$OUTPUT_ARGUMENT")" && pwd -P)"
OUTPUT_ROOT="$OUTPUT_PARENT/$(basename "$OUTPUT_ARGUMENT")"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

LOGS="$OUTPUT_ROOT/logs"
METADATA="$OUTPUT_ROOT/metadata"
MOUNTS="$OUTPUT_ROOT/mounts"
INSTALL_ROOT="$OUTPUT_ROOT/installed"
FEED_ROOT="$OUTPUT_ROOT/feed"
USER_ROOT="$OUTPUT_ROOT/user"
FIXTURE_PROJECT="$USER_ROOT/project"
HARNESS_HOME="$USER_ROOT/harness-home"
DERIVED_DATA="$OUTPUT_ROOT/DerivedData"
SPARKLE_DERIVED_DATA="$OUTPUT_ROOT/SparkleDerivedData"
RESULT_BUNDLE="$OUTPUT_ROOT/ReleaseArtifactSmoke.xcresult"

mkdir -p \
    "$LOGS" \
    "$METADATA" \
    "$MOUNTS/candidate" \
    "$MOUNTS/previous" \
    "$INSTALL_ROOT/candidate" \
    "$INSTALL_ROOT/update" \
    "$FEED_ROOT" \
    "$FIXTURE_PROJECT" \
    "$HARNESS_HOME/Library" \
    "$HARNESS_HOME/tmp"

{
    echo "sw_vers:"
    sw_vers
    echo "xcodebuild -version:"
    xcodebuild -version
    echo "macOS SDK version:"
    xcrun --sdk macosx --show-sdk-version
    echo "macOS SDK build version:"
    xcrun --sdk macosx --show-sdk-build-version
} > "$METADATA/toolchain.txt"

OS_MAJOR="$(sw_vers -productVersion | awk -F . '{print $1}')"
USE_DISKUTIL_IMAGE=false
if [ "$OS_MAJOR" -ge 27 ] \
    && [ "${PINE_DMG_FORCE_LEGACY_HDIUTIL:-0}" != "1" ]; then
    require_command diskutil
    USE_DISKUTIL_IMAGE=true
else
    require_command hdiutil
fi

ATTACHED_DEVICES=()
SERVER_PID=""

cleanup() {
    local index
    local device

    ps -axo pid,ppid,state,etime,command > "$LOGS/processes.txt" \
        2>&1 || true
    log show \
        --last 20m \
        --style compact \
        --predicate 'process == "Pine" OR process CONTAINS[c] "sparkle"' \
        > "$LOGS/unified.log" 2>&1 || true

    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" >/dev/null 2>&1 || true
        SERVER_PID=""
    fi

    for ((index=${#ATTACHED_DEVICES[@]} - 1; index >= 0; index--)); do
        device="${ATTACHED_DEVICES[$index]}"
        if [ "$USE_DISKUTIL_IMAGE" = true ]; then
            diskutil eject "$device" >/dev/null 2>&1 || true
        else
            hdiutil detach "$device" >/dev/null 2>&1 || true
        fi
    done
}
trap cleanup EXIT INT TERM

attach_image() {
    local image="$1"
    local mount_point="$2"
    local plist="$3"
    local device

    if [ "$USE_DISKUTIL_IMAGE" = true ]; then
        diskutil image --plist attach \
            --readOnly \
            --nobrowse \
            --mountPoint "$mount_point" \
            "$image" > "$plist"
    else
        hdiutil attach \
            -plist \
            -readonly \
            -noverify \
            -noautoopen \
            -nobrowse \
            -mountpoint "$mount_point" \
            "$image" > "$plist"
    fi

    device="$($PLISTBUDDY \
        -c 'Print :system-entities:0:dev-entry' "$plist")"
    [ -n "$device" ] || die "could not determine attached device for $image"
    ATTACHED_DEVICES+=("$device")
}

verify_signed_app() {
    local app="$1"
    local label="$2"

    codesign --verify --deep --strict --verbose=2 "$app" \
        > "$LOGS/$label-codesign.log" 2>&1
    xcrun stapler validate "$app" \
        > "$LOGS/$label-stapler.log" 2>&1
    spctl --assess --type execute --verbose=4 "$app" \
        > "$LOGS/$label-gatekeeper.log" 2>&1
}

CANDIDATE_HASH="$(shasum -a 256 "$CANDIDATE_DMG" | awk '{print $1}')"
printf '%s  %s\n' "$CANDIDATE_HASH" "$(basename "$CANDIDATE_DMG")" \
    > "$METADATA/candidate-before-smoke.sha256"

attach_image \
    "$CANDIDATE_DMG" \
    "$MOUNTS/candidate" \
    "$METADATA/candidate-attach.plist"
attach_image \
    "$PREVIOUS_DMG" \
    "$MOUNTS/previous" \
    "$METADATA/previous-attach.plist"

[ -d "$MOUNTS/candidate/Pine.app" ] \
    || die "candidate Pine.app is missing from the DMG"
[ -d "$MOUNTS/previous/Pine.app" ] \
    || die "previous Pine.app is missing from the DMG"

CANDIDATE_APP="$INSTALL_ROOT/candidate/Pine.app"
UPDATE_APP="$INSTALL_ROOT/update/Pine.app"
ditto "$MOUNTS/candidate/Pine.app" "$CANDIDATE_APP"
ditto "$MOUNTS/previous/Pine.app" "$UPDATE_APP"

CANDIDATE_INFO="$CANDIDATE_APP/Contents/Info.plist"
PREVIOUS_INFO="$UPDATE_APP/Contents/Info.plist"
CANDIDATE_VERSION="$($PLISTBUDDY \
    -c 'Print :CFBundleShortVersionString' "$CANDIDATE_INFO")"
CANDIDATE_BUILD="$($PLISTBUDDY \
    -c 'Print :CFBundleVersion' "$CANDIDATE_INFO")"
PREVIOUS_VERSION="$($PLISTBUDDY \
    -c 'Print :CFBundleShortVersionString' "$PREVIOUS_INFO")"
PREVIOUS_BUILD="$($PLISTBUDDY \
    -c 'Print :CFBundleVersion' "$PREVIOUS_INFO")"

[ "$CANDIDATE_VERSION" = "$EXPECTED_VERSION" ] \
    || die "candidate version mismatch: $CANDIDATE_VERSION"
[ "$CANDIDATE_BUILD" = "$EXPECTED_BUILD" ] \
    || die "candidate build mismatch: $CANDIDATE_BUILD"
case "$PREVIOUS_BUILD" in
    ''|*[!0-9]*) die "previous build is not numeric: $PREVIOUS_BUILD" ;;
esac
[ "$PREVIOUS_BUILD" -lt "$EXPECTED_BUILD" ] \
    || die "previous build $PREVIOUS_BUILD is not older than $EXPECTED_BUILD"

verify_signed_app "$CANDIDATE_APP" candidate
verify_signed_app "$UPDATE_APP" previous

cat > "$FIXTURE_PROJECT/ReleaseSmoke.swift" <<'EOF'
import Foundation

print("Pine signed release smoke")
EOF

FEED_DMG="$FEED_ROOT/$(basename "$CANDIDATE_DMG")"
ditto "$CANDIDATE_DMG" "$FEED_DMG"
FEED_HASH="$(shasum -a 256 "$FEED_DMG" | awk '{print $1}')"
[ "$FEED_HASH" = "$CANDIDATE_HASH" ] \
    || die "local update feed does not contain the candidate DMG bytes"

PORT_FILE="$METADATA/appcast-port.txt"
python3 - "$FEED_ROOT" "$PORT_FILE" <<'PYTHON' \
    > "$LOGS/appcast-server.log" 2>&1 &
import http.server
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
port_file = pathlib.Path(sys.argv[2])
handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(
    *args, directory=root, **kwargs
)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
port_file.write_text(str(server.server_address[1]), encoding="utf-8")
server.serve_forever()
PYTHON
SERVER_PID="$!"

for _ in {1..100}; do
    [ -s "$PORT_FILE" ] && break
    kill -0 "$SERVER_PID" >/dev/null 2>&1 \
        || die "local appcast server exited before startup"
    sleep 0.1
done
[ -s "$PORT_FILE" ] || die "local appcast server did not publish its port"

APPCAST_PORT="$(cat "$PORT_FILE")"
APPCAST_URL="http://127.0.0.1:$APPCAST_PORT/appcast.xml"
DMG_URL="http://127.0.0.1:$APPCAST_PORT/$(basename "$FEED_DMG")"
PINE_APPCAST_SOURCE="$APPCAST" \
PINE_APPCAST_OUTPUT="$FEED_ROOT/appcast.xml" \
PINE_APPCAST_METADATA="$METADATA/appcast.json" \
PINE_APPCAST_DMG_URL="$DMG_URL" \
PINE_APPCAST_EXPECTED_VERSION="$EXPECTED_VERSION" \
PINE_APPCAST_EXPECTED_BUILD="$EXPECTED_BUILD" \
PINE_APPCAST_EXPECTED_LENGTH="$(wc -c < "$CANDIDATE_DMG" | tr -d ' ')" \
PINE_APPCAST_CANDIDATE_SHA256="$CANDIDATE_HASH" \
python3 <<'PYTHON'
import json
import os
import re
import xml.etree.ElementTree as ET
from pathlib import Path

source = Path(os.environ["PINE_APPCAST_SOURCE"]).read_text(encoding="utf-8")
pattern = re.compile(r'(<enclosure\b[^>]*\burl=")[^"]*(")')
rewritten, replacements = pattern.subn(
    rf'\g<1>{os.environ["PINE_APPCAST_DMG_URL"]}\g<2>',
    source,
)
if replacements != 1:
    raise SystemExit(f"expected one appcast enclosure, found {replacements}")

output = Path(os.environ["PINE_APPCAST_OUTPUT"])
output.write_text(rewritten, encoding="utf-8")
root = ET.fromstring(rewritten)
item = root.find("./channel/item")
if item is None:
    raise SystemExit("appcast item is missing")
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("appcast enclosure is missing")

def sparkle_text(name):
    element = item.find(
        f"{{http://www.andymatuschak.org/xml-namespaces/sparkle}}{name}"
    )
    return None if element is None else element.text

signature = next(
    (value for key, value in enclosure.attrib.items() if key.endswith("edSignature")),
    None,
)
metadata = {
    "candidateSHA256": os.environ["PINE_APPCAST_CANDIDATE_SHA256"],
    "candidateVersion": sparkle_text("shortVersionString"),
    "candidateBuild": sparkle_text("version"),
    "enclosureURL": enclosure.attrib.get("url"),
    "enclosureLength": enclosure.attrib.get("length"),
    "edSignaturePresent": bool(signature),
}
expected = {
    "candidateVersion": os.environ["PINE_APPCAST_EXPECTED_VERSION"],
    "candidateBuild": os.environ["PINE_APPCAST_EXPECTED_BUILD"],
    "enclosureURL": os.environ["PINE_APPCAST_DMG_URL"],
    "enclosureLength": os.environ["PINE_APPCAST_EXPECTED_LENGTH"],
}
for key, value in expected.items():
    if metadata[key] != value:
        raise SystemExit(f"appcast {key} mismatch: {metadata[key]!r} != {value!r}")
if not signature:
    raise SystemExit("appcast EdDSA signature is missing")

Path(os.environ["PINE_APPCAST_METADATA"]).write_text(
    json.dumps(metadata, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PYTHON

curl --fail --silent --show-error "$APPCAST_URL" \
    > /dev/null
curl --fail --silent --show-error "$DMG_URL" \
    | shasum -a 256 \
    | awk '{print $1}' \
    | grep -qx "$CANDIDATE_HASH" \
    || die "loopback server did not return the candidate DMG bytes"

xcodebuild build \
    -project "$SPARKLE_SOURCE/Sparkle.xcodeproj" \
    -scheme sparkle-cli \
    -configuration Release \
    -derivedDataPath "$SPARKLE_DERIVED_DATA" \
    MACOSX_DEPLOYMENT_TARGET=26.0 \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    > "$LOGS/sparkle-cli-build.log" 2>&1

SPARKLE_CLI_CANDIDATES="$METADATA/sparkle-cli-candidates.txt"
find "$SPARKLE_DERIVED_DATA/Build/Products/Release" \
    -type f \
    -path '*/sparkle.app/Contents/MacOS/sparkle' \
    -perm -111 \
    > "$SPARKLE_CLI_CANDIDATES"
[ "$(wc -l < "$SPARKLE_CLI_CANDIDATES" | tr -d ' ')" = "1" ] \
    || die "expected exactly one built sparkle-cli executable"
SPARKLE_CLI="$(cat "$SPARKLE_CLI_CANDIDATES")"

printf '%s\n' \
    "candidateVersion=$CANDIDATE_VERSION" \
    "candidateBuild=$CANDIDATE_BUILD" \
    "previousVersion=$PREVIOUS_VERSION" \
    "previousBuild=$PREVIOUS_BUILD" \
    "candidateSHA256=$CANDIDATE_HASH" \
    > "$METADATA/release-smoke.txt"

SPM_SOURCE_ROOT="$(dirname "$(dirname "$SPARKLE_SOURCE")")"
cd "$REPO_ROOT"
set +e
HOME="$HARNESS_HOME" \
CFFIXED_USER_HOME="$HARNESS_HOME" \
TMPDIR="$HARNESS_HOME/tmp" \
PINE_RELEASE_SMOKE_ENABLED=1 \
PINE_RELEASE_SMOKE_CANDIDATE_DMG="$CANDIDATE_DMG" \
PINE_RELEASE_SMOKE_CANDIDATE_APP="$CANDIDATE_APP" \
PINE_RELEASE_SMOKE_UPDATE_APP="$UPDATE_APP" \
PINE_RELEASE_SMOKE_SPARKLE_CLI="$SPARKLE_CLI" \
PINE_RELEASE_SMOKE_APPCAST_URL="$APPCAST_URL" \
PINE_RELEASE_SMOKE_EXPECTED_VERSION="$EXPECTED_VERSION" \
PINE_RELEASE_SMOKE_EXPECTED_BUILD="$EXPECTED_BUILD" \
PINE_RELEASE_SMOKE_USER_ROOT="$USER_ROOT" \
PINE_RELEASE_SMOKE_PROJECT="$FIXTURE_PROJECT" \
PINE_RELEASE_SMOKE_LOGS="$LOGS" \
xcodebuild test \
    -project Pine.xcodeproj \
    -scheme Pine \
    -destination 'platform=macOS' \
    -clonedSourcePackagesDirPath "$SPM_SOURCE_ROOT" \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO \
    -only-testing:PineUITests/ReleaseArtifactSmokeTests \
    -resultBundlePath "$RESULT_BUNDLE" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$LOGS/xcodebuild.log"
XCODEBUILD_STATUS="${PIPESTATUS[0]}"
set -e

AFTER_HASH="$(shasum -a 256 "$CANDIDATE_DMG" | awk '{print $1}')"
printf '%s  %s\n' "$AFTER_HASH" "$(basename "$CANDIDATE_DMG")" \
    > "$METADATA/candidate-after-smoke.sha256"
[ "$AFTER_HASH" = "$CANDIDATE_HASH" ] \
    || die "candidate DMG changed while the release smoke was running"
[ "$XCODEBUILD_STATUS" -eq 0 ] \
    || die "release artifact XCUITest failed with status $XCODEBUILD_STATUS"

echo "Release artifact smoke passed for Pine $EXPECTED_VERSION ($EXPECTED_BUILD)"
echo "Candidate SHA-256: $CANDIDATE_HASH"
