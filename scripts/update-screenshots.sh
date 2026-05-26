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
#   - Uses `xcresulttool get test-results tests/activities` (Xcode 16+) to
#     enumerate attachments by name and extract payloads directly.

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

# --- Extract named screenshots via xcresulttool get test-results --------------
# Uses `xcresulttool get test-results tests` to enumerate test cases,
# then `xcresulttool get test-results activities --test-id <id>` to get
# attachment name + payloadId mappings, and copies payloads directly from
# the bundle's Data directory. Avoids `export attachments` which fails
# silently on some Xcode 26 CI runners.
extract_named_screenshots() {
  local found_any=false

  while IFS=$'\t' read -r att_name payload_id; do
    [ -z "$att_name" ] && continue
    [ -z "$payload_id" ] && continue
    if [[ ! "$att_name" =~ ^screenshot-[a-zA-Z0-9_-]+$ ]]; then
      echo "  Skipping attachment with invalid name: $att_name" >&2
      continue
    fi
    local src=""
    if [ -f "$RESULT_PATH/Data/$payload_id" ]; then
      src="$RESULT_PATH/Data/$payload_id"
    else
      src=$(find "$RESULT_PATH/Data" -name "$payload_id" -type f -print -quit 2>/dev/null)
    fi
    if [ -z "$src" ]; then
      echo "  Warning: payload not found for $att_name (id=$payload_id)" >&2
      continue
    fi
    cp "$src" "$ASSETS_DIR/${att_name}.png"
    echo "  Extracted ${att_name}.png"
    found_any=true
  done < <(python3 - "$XCRESULTTOOL" "$RESULT_PATH" <<'PY'
import json, subprocess, sys

xcresulttool = sys.argv[1]
bundle_path = sys.argv[2]

def get_json(args):
    r = subprocess.run([xcresulttool] + args, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  xcresulttool error: {r.stderr}", file=sys.stderr)
        return None
    return json.loads(r.stdout)

def find_test_ids(node):
    results = []
    node_type = node.get("nodeType", "")
    name = node.get("name", "")
    if node_type == "Test Case" and name.startswith("testCapture"):
        tid = node.get("nodeIdentifierURL", "") or node.get("nodeIdentifier", "")
        if tid:
            results.append(tid)
    for child in node.get("children", []):
        results.extend(find_test_ids(child))
    return results

def walk_activities(node):
    for att in node.get("attachments", []):
        att_name = att.get("name", "")
        payload_id = att.get("payloadId", "")
        if att_name.startswith("screenshot-") and payload_id:
            print(f"{att_name}\t{payload_id}")
    for child in node.get("childActivities", []):
        walk_activities(child)

data = get_json(["get", "test-results", "tests", "--path", bundle_path])
if not data:
    sys.exit(1)

test_ids = find_test_ids(data)
if not test_ids:
    print("  No screenshot test cases found in xcresult bundle.", file=sys.stderr)
    sys.exit(1)

for tid in test_ids:
    act_data = get_json(["get", "test-results", "activities",
                         "--path", bundle_path, "--test-id", tid])
    if not act_data:
        continue
    walk_activities(act_data)
PY
  )

  [ "$found_any" = true ] && return 0
  return 1
}

echo "Extracting named screenshots via xcresulttool..."
if extract_named_screenshots; then
  echo "Extraction complete."
else
  echo "Error: failed to extract named screenshots." >&2
  exit 1
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
