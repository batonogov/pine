#!/bin/bash
# Build Pine's branded, compressed drag-to-Applications disk image.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/create-dmg.sh [--overwrite] <Pine.app> <output.dmg>

Creates a branded UDZO disk image using only built-in macOS tools.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

OVERWRITE=false
if [ "${1:-}" = "--overwrite" ]; then
    OVERWRITE=true
    shift
fi

if [ "$#" -ne 2 ]; then
    usage >&2
    exit 64
fi

APP_ARGUMENT="$1"
OUTPUT_ARGUMENT="$2"

[ "$(uname -s)" = "Darwin" ] || die "DMG creation requires macOS"
[ -d "$APP_ARGUMENT" ] || die "app bundle not found: $APP_ARGUMENT"
[ -f "$APP_ARGUMENT/Contents/Info.plist" ] \
    || die "invalid app bundle (missing Contents/Info.plist): $APP_ARGUMENT"

case "$OUTPUT_ARGUMENT" in
    *.dmg) ;;
    *) die "output path must end in .dmg: $OUTPUT_ARGUMENT" ;;
esac

OUTPUT_PARENT="$(dirname "$OUTPUT_ARGUMENT")"
[ -d "$OUTPUT_PARENT" ] || die "output directory not found: $OUTPUT_PARENT"

APP_PATH="$(cd "$(dirname "$APP_ARGUMENT")" && pwd -P)/$(basename "$APP_ARGUMENT")"
OUTPUT_PATH="$(cd "$OUTPUT_PARENT" && pwd -P)/$(basename "$OUTPUT_ARGUMENT")"

if [ -e "$OUTPUT_PATH" ]; then
    if [ "$OVERWRITE" != true ]; then
        die "output already exists (pass --overwrite to replace it): $OUTPUT_PATH"
    fi
    rm -f "$OUTPUT_PATH"
fi

require_command awk
require_command ditto
require_command du
require_command osascript
require_command readlink
require_command sw_vers
require_command sync
require_command touch

OS_MAJOR="$(sw_vers -productVersion | awk -F . '{print $1}')"
USE_DISKUTIL_IMAGE=false
if [ "$OS_MAJOR" -ge 27 ] \
    && [ "${PINE_DMG_FORCE_LEGACY_HDIUTIL:-0}" != "1" ]; then
    require_command diskutil
    USE_DISKUTIL_IMAGE=true
else
    require_command hdiutil
fi

PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
[ -x "$PLISTBUDDY" ] || die "PlistBuddy not found: $PLISTBUDDY"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BACKGROUND_PATH="$REPO_ROOT/assets/dmg/background@2x.png"
LAYOUT_SCRIPT="$REPO_ROOT/assets/dmg/layout.applescript"

[ -f "$BACKGROUND_PATH" ] || die "DMG background not found: $BACKGROUND_PATH"
[ -f "$LAYOUT_SCRIPT" ] || die "Finder layout script not found: $LAYOUT_SCRIPT"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pine-dmg.XXXXXX")"
WRITABLE_DMG="$TEMP_ROOT/Pine-writable.dmg"
ATTACH_PLIST="$TEMP_ROOT/attach.plist"
LEGACY_SOURCE="$TEMP_ROOT/source"
ATTACHED_DEVICE=""
MOUNT_DIR=""

stage_contents() {
    local destination="$1"

    mkdir -p "$destination/.background"
    ditto "$APP_PATH" "$destination/Pine.app"
    ditto "$BACKGROUND_PATH" "$destination/.background/background@2x.png"
    if [ -e "$destination/Applications" ] \
        || [ -L "$destination/Applications" ]; then
        [ -L "$destination/Applications" ] \
            && [ "$(readlink "$destination/Applications")" = "/Applications" ] \
            || die "unexpected Applications item while staging the image"
    else
        ln -s /Applications "$destination/Applications"
    fi
}

detach_image() {
    local attempt
    local detached
    [ -n "$ATTACHED_DEVICE" ] || return 0

    for attempt in 1 2 3 4 5; do
        if [ "$USE_DISKUTIL_IMAGE" = true ]; then
            diskutil eject "$ATTACHED_DEVICE" >/dev/null 2>&1 && detached=true \
                || detached=false
        else
            hdiutil detach "$ATTACHED_DEVICE" >/dev/null 2>&1 && detached=true \
                || detached=false
        fi
        if [ "$detached" = true ]; then
            ATTACHED_DEVICE=""
            MOUNT_DIR=""
            return 0
        fi
        sleep "$attempt"
    done
    return 1
}

cleanup() {
    detach_image || true
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

CONTENT_KB="$(du -sk "$APP_PATH" "$BACKGROUND_PATH" \
    | awk '{ total += $1 } END { print total }')"
IMAGE_SIZE_MB="$(((CONTENT_KB + 32767) / 1024))"

echo "Creating writable Pine image (${IMAGE_SIZE_MB} MB)..."
if [ "$USE_DISKUTIL_IMAGE" = true ]; then
    diskutil image create blank \
        --format RAW \
        --size "${IMAGE_SIZE_MB}MiB" \
        --volumeName "Pine" \
        --fs APFS \
        "$WRITABLE_DMG" >/dev/null
    diskutil image --plist attach "$WRITABLE_DMG" > "$ATTACH_PLIST"
else
    stage_contents "$LEGACY_SOURCE"
    hdiutil create \
        -volname "Pine" \
        -fs "HFS+" \
        -fsargs "-c c=64,a=16,e=16" \
        -size "${IMAGE_SIZE_MB}m" \
        -srcfolder "$LEGACY_SOURCE" \
        -format UDRW \
        -ov \
        "$WRITABLE_DMG" >/dev/null
    hdiutil attach \
        -plist \
        -readwrite \
        -noverify \
        -noautoopen \
        "$WRITABLE_DMG" > "$ATTACH_PLIST"
fi

ATTACHED_DEVICE="$($PLISTBUDDY \
    -c 'Print :system-entities:0:dev-entry' "$ATTACH_PLIST")"
for entity_index in 0 1 2 3 4 5 6 7 8 9; do
    candidate="$($PLISTBUDDY \
        -c "Print :system-entities:${entity_index}:mount-point" \
        "$ATTACH_PLIST" 2>/dev/null || true)"
    if [ -n "$candidate" ]; then
        MOUNT_DIR="$candidate"
    fi
done

[ -n "$ATTACHED_DEVICE" ] || die "could not determine the attached device"
[ -d "$MOUNT_DIR" ] || die "could not determine the mounted volume path"

stage_contents "$MOUNT_DIR"
touch "$MOUNT_DIR/.DS_Store"
rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes"
chmod -Rf go-w "$MOUNT_DIR"
sync

echo "Applying the Finder layout..."
osascript "$LAYOUT_SCRIPT" "$(basename "$MOUNT_DIR")" "$MOUNT_DIR"

for eject_wait in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -d "$MOUNT_DIR" ] && break
    sleep 1
done
if [ -d "$MOUNT_DIR" ]; then
    die "Finder did not eject the writable image"
fi
ATTACHED_DEVICE=""
MOUNT_DIR=""

echo "Compressing the final UDZO image..."
if [ "$USE_DISKUTIL_IMAGE" = true ]; then
    diskutil image create from \
        --format UDZO \
        "$WRITABLE_DMG" \
        "$OUTPUT_PATH" >/dev/null
    diskutil image info "$OUTPUT_PATH" >/dev/null
else
    hdiutil convert "$WRITABLE_DMG" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -ov \
        -o "$OUTPUT_PATH" >/dev/null
    hdiutil verify "$OUTPUT_PATH" >/dev/null
fi

echo "Created $OUTPUT_PATH"
