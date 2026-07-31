#!/bin/bash
# Fail-closed structural, version, signature, notarization, and Gatekeeper checks.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/verify-dmg.sh [--skip-security] <Pine.dmg> <expected-version>

The release workflow must not pass --skip-security. That option exists only
for locally built, unsigned debug apps.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

SKIP_SECURITY=false
if [ "${1:-}" = "--skip-security" ]; then
    SKIP_SECURITY=true
    shift
fi

if [ "$#" -ne 2 ]; then
    usage >&2
    exit 64
fi

DMG_ARGUMENT="$1"
EXPECTED_VERSION="$2"

[ "$(uname -s)" = "Darwin" ] || die "DMG verification requires macOS"
[ -f "$DMG_ARGUMENT" ] || die "disk image not found: $DMG_ARGUMENT"
[ -n "$EXPECTED_VERSION" ] || die "expected version must not be empty"

require_command awk
require_command basename
require_command ditto
require_command find
require_command sips
require_command sort
require_command sw_vers

OS_MAJOR="$(sw_vers -productVersion | awk -F . '{print $1}')"
USE_DISKUTIL_IMAGE=false
if [ "$OS_MAJOR" -ge 27 ] \
    && [ "${PINE_DMG_FORCE_LEGACY_HDIUTIL:-0}" != "1" ]; then
    require_command diskutil
    USE_DISKUTIL_IMAGE=true
else
    require_command hdiutil
fi

if [ "$SKIP_SECURITY" != true ]; then
    require_command codesign
    require_command spctl
    require_command xcrun
fi

PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
[ -x "$PLISTBUDDY" ] || die "PlistBuddy not found: $PLISTBUDDY"

DMG_PATH="$(cd "$(dirname "$DMG_ARGUMENT")" && pwd -P)/$(basename "$DMG_ARGUMENT")"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pine-dmg-verify.XXXXXX")"
MOUNT_DIR="$TEMP_ROOT/mount"
EXTRACTED_APP="$TEMP_ROOT/extracted/Pine.app"
ATTACH_PLIST="$TEMP_ROOT/attach.plist"
ATTACHED_DEVICE=""

cleanup() {
    if [ -n "$ATTACHED_DEVICE" ]; then
        if [ "$USE_DISKUTIL_IMAGE" = true ]; then
            diskutil eject "$ATTACHED_DEVICE" >/dev/null 2>&1 || true
        else
            hdiutil detach "$ATTACHED_DEVICE" >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$MOUNT_DIR" "$(dirname "$EXTRACTED_APP")"
if [ "$USE_DISKUTIL_IMAGE" = true ]; then
    diskutil image --plist attach \
        --readOnly \
        --nobrowse \
        --mountPoint "$MOUNT_DIR" \
        "$DMG_PATH" > "$ATTACH_PLIST"
else
    hdiutil attach \
        -plist \
        -readonly \
        -noverify \
        -noautoopen \
        -nobrowse \
        -mountpoint "$MOUNT_DIR" \
        "$DMG_PATH" > "$ATTACH_PLIST"
fi
ATTACHED_DEVICE="$($PLISTBUDDY \
    -c 'Print :system-entities:0:dev-entry' "$ATTACH_PLIST")"
[ -n "$ATTACHED_DEVICE" ] || die "could not determine the attached device"

[ -d "$MOUNT_DIR/Pine.app" ] || die "Pine.app is missing from the image root"
[ -L "$MOUNT_DIR/Applications" ] || die "Applications is not a symbolic link"
[ "$(readlink "$MOUNT_DIR/Applications")" = "/Applications" ] \
    || die "Applications link does not target /Applications"
[ -f "$MOUNT_DIR/.background/background@2x.png" ] \
    || die "hidden Retina background is missing"
[ -s "$MOUNT_DIR/.DS_Store" ] || die "Finder layout metadata is missing or empty"

BACKGROUND_INFO="$(sips \
    -g pixelWidth \
    -g pixelHeight \
    "$MOUNT_DIR/.background/background@2x.png")"
BACKGROUND_WIDTH="$(printf '%s\n' "$BACKGROUND_INFO" \
    | awk '/pixelWidth:/ { print $2 }')"
BACKGROUND_HEIGHT="$(printf '%s\n' "$BACKGROUND_INFO" \
    | awk '/pixelHeight:/ { print $2 }')"
[ "$BACKGROUND_WIDTH" = "1320" ] && [ "$BACKGROUND_HEIGHT" = "840" ] \
    || die "Retina background must be 1320x840, found ${BACKGROUND_WIDTH}x${BACKGROUND_HEIGHT}"

VISIBLE_ITEMS="$(find "$MOUNT_DIR" -mindepth 1 -maxdepth 1 ! -name '.*' \
    -exec basename {} \; | LC_ALL=C sort)"
EXPECTED_ITEMS="$(printf '%s\n' Applications Pine.app)"
if [ "$VISIBLE_ITEMS" != "$EXPECTED_ITEMS" ]; then
    echo "Expected visible image items:" >&2
    printf '%s\n' "$EXPECTED_ITEMS" >&2
    echo "Actual visible image items:" >&2
    printf '%s\n' "$VISIBLE_ITEMS" >&2
    die "disk image contains unexpected visible items"
fi

INFO_PLIST="$MOUNT_DIR/Pine.app/Contents/Info.plist"
[ -f "$INFO_PLIST" ] || die "Pine.app Info.plist is missing"
ACTUAL_VERSION="$($PLISTBUDDY -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
[ "$ACTUAL_VERSION" = "$EXPECTED_VERSION" ] \
    || die "version mismatch: expected $EXPECTED_VERSION, found $ACTUAL_VERSION"

BUNDLE_ID="$($PLISTBUDDY -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
[ "$BUNDLE_ID" = "io.github.batonogov.pine" ] \
    || die "bundle identifier mismatch: $BUNDLE_ID"

ditto "$MOUNT_DIR/Pine.app" "$EXTRACTED_APP"

if [ "$SKIP_SECURITY" != true ]; then
    codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
    xcrun stapler validate "$EXTRACTED_APP"
    spctl --assess --type execute --verbose=4 "$EXTRACTED_APP"
else
    echo "Warning: skipping signature, stapler, and Gatekeeper checks" >&2
fi

echo "Verified Pine ${EXPECTED_VERSION}: layout, contents, and app checks passed"
