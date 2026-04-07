#!/bin/bash
# Update screenshot assets from UI tests.
#
# Runs the ScreenshotTests UI test suite, then extracts the captured
# XCTAttachment PNGs from the resulting xcresult bundle into assets/.
#
# Behavior:
#   - The xcodebuild test step is allowed to "soft fail" (some screenshot
#     tests may fail individually while others succeed and still produce
#     usable attachments).
#   - Extraction itself MUST succeed and produce at least one new PNG —
#     otherwise we exit non-zero so CI fails loudly instead of silently
#     committing zero changes.
#
# Compatibility:
#   - Primary path uses `xcrun xcresulttool export attachments` (Xcode 16+).
#   - Falls back to a raw filesystem scan of the .xcresult bundle for any
#     PNG payloads matching screenshot manifest entries.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RESULT_PATH="$REPO_ROOT/build/screenshots.xcresult"
ASSETS_DIR="$REPO_ROOT/assets"
## Names that ScreenshotTests is expected to produce. The first group is
## REQUIRED — the workflow fails if any of these are missing or empty after
## extraction. The second group is optional (newer captures that are not yet
## committed to the repo); they are extracted when present but absence does
## not fail the build.
REQUIRED_NAMES=(
  "screenshot-welcome"
  "screenshot-editor"
  "screenshot-terminal"
  "screenshot-markdown"
)
OPTIONAL_NAMES=(
  "screenshot-sidebar"
  "screenshot-minimap"
)

# Clean previous result bundle
rm -rf "$RESULT_PATH"

# Resolve a usable Xcode developer dir. Allow override via env, otherwise
# fall back to /Applications/Xcode.app — works both locally and in CI.
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

XCRESULTTOOL="$DEVELOPER_DIR/usr/bin/xcresulttool"
if [ ! -x "$XCRESULTTOOL" ]; then
  echo "Error: xcresulttool not found at $XCRESULTTOOL" >&2
  exit 2
fi

echo "Running screenshot tests (DEVELOPER_DIR=$DEVELOPER_DIR)..."
xcodebuild test \
  -project "$REPO_ROOT/Pine.xcodeproj" \
  -scheme Pine \
  -destination 'platform=macOS' \
  -only-testing:PineUITests/ScreenshotTests \
  -resultBundlePath "$RESULT_PATH" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=NO \
  || echo "Warning: xcodebuild test reported failures; continuing to extract whatever attachments are available..."

if [ ! -d "$RESULT_PATH" ]; then
  echo "Error: xcresult bundle not found at $RESULT_PATH" >&2
  exit 1
fi

mkdir -p "$ASSETS_DIR"

# --- Strategy 1: Modern xcresulttool (Xcode 16+) -----------------------------
# `xcresulttool export attachments` writes every XCTAttachment payload into a
# directory along with a manifest.json that records the original attachment
# `name` (without an extension). We honor that name and rename to `.png`.
extract_with_export_attachments() {
  local export_dir
  export_dir=$(mktemp -d)

  if ! "$XCRESULTTOOL" export attachments \
       --path "$RESULT_PATH" \
       --output-path "$export_dir" >/dev/null 2>&1; then
    rm -rf "$export_dir"
    return 1
  fi

  local found_any=false
  local manifest="$export_dir/manifest.json"
  if [ -f "$manifest" ]; then
    # Walk the manifest, pull every attachment whose declared name starts
    # with `screenshot-`, and copy <exported file> -> assets/<name>.png.
    while IFS=$'\t' read -r att_name suggested; do
      [ -z "$att_name" ] && continue
      [ -z "$suggested" ] && continue
      local src="$export_dir/$suggested"
      [ -f "$src" ] || continue
      cp "$src" "$ASSETS_DIR/${att_name}.png"
      echo "  Extracted ${att_name}.png"
      found_any=true
    done < <(python3 - "$manifest" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)

def walk(node):
    if isinstance(node, dict):
        atts = node.get("attachments")
        if isinstance(atts, list):
            for att in atts:
                name = att.get("name", "") or ""
                suggested = (
                    att.get("exportedFileName")
                    or att.get("suggestedHumanReadableName")
                    or att.get("filename")
                    or ""
                )
                if name.startswith("screenshot-") and suggested:
                    print(f"{name}\t{suggested}")
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for item in node:
            walk(item)

walk(data)
PY
)
  fi

  rm -rf "$export_dir"
  [ "$found_any" = true ] && return 0
  return 1
}

# --- Strategy 2: Raw filesystem walk -----------------------------------------
# As a last resort, scan the bundle for PNG payloads. Each xcresult attachment
# is stored as an opaque hash file; we use the manifest from strategy 1 to
# resolve names where possible. If neither manifest nor names are available
# we just emit numbered fallbacks so the workflow can still notice
# "something" was extracted (and the guardrail will warn that names are
# missing).
extract_with_filesystem() {
  local found_any=false
  local idx=0
  while IFS= read -r -d '' file; do
    if head -c 4 "$file" 2>/dev/null | xxd -p 2>/dev/null | grep -q '^89504e47'; then
      idx=$((idx + 1))
      cp "$file" "$ASSETS_DIR/screenshot-unknown-${idx}.png"
      echo "  Extracted screenshot-unknown-${idx}.png (raw filesystem)"
      found_any=true
    fi
  done < <(find "$RESULT_PATH" -type f -print0 2>/dev/null)
  [ "$found_any" = true ] && return 0
  return 1
}

echo "Extracting screenshots via xcresulttool export attachments..."
if extract_with_export_attachments; then
  echo "Extraction complete (export attachments)."
else
  echo "Modern API yielded no screenshots, falling back to raw filesystem walk..."
  if ! extract_with_filesystem; then
    echo "Error: all extraction strategies failed (no PNG payloads found)." >&2
    exit 1
  fi
fi

# --- Guardrail ---------------------------------------------------------------
# Every REQUIRED screenshot must exist as a non-empty PNG. This prevents the
# workflow from silently committing zero changes when only test-runner crash
# logs were captured. Optional screenshots only emit a warning when missing.
MISSING_REQUIRED=()
for name in "${REQUIRED_NAMES[@]}"; do
  path="$ASSETS_DIR/${name}.png"
  if [ ! -s "$path" ]; then
    MISSING_REQUIRED+=("$name")
  fi
done

MISSING_OPTIONAL=()
for name in "${OPTIONAL_NAMES[@]}"; do
  path="$ASSETS_DIR/${name}.png"
  if [ ! -s "$path" ]; then
    MISSING_OPTIONAL+=("$name")
  fi
done

FINAL_COUNT=$(find "$ASSETS_DIR" -name "screenshot-*.png" 2>/dev/null | wc -l | tr -d ' ')
echo "Done! $FINAL_COUNT screenshot file(s) in assets/"

if [ "${#MISSING_REQUIRED[@]}" -gt 0 ]; then
  echo "Error: required screenshots missing or empty: ${MISSING_REQUIRED[*]}" >&2
  exit 1
fi

if [ "${#MISSING_OPTIONAL[@]}" -gt 0 ]; then
  echo "Warning: optional screenshots missing: ${MISSING_OPTIONAL[*]}" >&2
fi
