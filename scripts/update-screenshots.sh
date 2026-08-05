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
#   - Set `PINE_SCREENSHOT_DERIVED_DATA_PATH` to isolate local build artifacts.
#   - Set `PINE_SCREENSHOT_CODE_SIGNING_ALLOWED=YES` when a local UI-test
#     runner must be signed to launch; CI remains unsigned by default.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RESULT_PATH="$REPO_ROOT/build/screenshots.xcresult"
ASSETS_DIR="$REPO_ROOT/assets"
DERIVED_DATA_PATH="${PINE_SCREENSHOT_DERIVED_DATA_PATH:-}"
CODE_SIGNING_ALLOWED="${PINE_SCREENSHOT_CODE_SIGNING_ALLOWED:-NO}"
## Names that ScreenshotTests is expected to produce. The first group is
## REQUIRED — the workflow fails if any of these are missing or empty after
## extraction. The second group is optional (newer captures that are not yet
## committed to the repo); they are extracted when present but absence does
## not fail the build.
REQUIRED_NAMES=(
  "screenshot-welcome"
  "screenshot-agent-inbox"
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
xcodebuild_args=(
  test
  -project "$REPO_ROOT/Pine.xcodeproj"
  -scheme Pine
  -destination 'platform=macOS'
  -only-testing:PineUITests/ScreenshotTests
  -resultBundlePath "$RESULT_PATH"
)
if [ -n "$DERIVED_DATA_PATH" ]; then
  xcodebuild_args+=(-derivedDataPath "$DERIVED_DATA_PATH")
fi
if [ "$CODE_SIGNING_ALLOWED" = "NO" ]; then
  xcodebuild_args+=(CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild "${xcodebuild_args[@]}" \
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
  # Pass the known canonical screenshot names to the extractor so it can map
  # Xcode 26's suffixed attachment names back to the names the workflow
  # expects (e.g. screenshot-editor_0_<UUID>.png -> screenshot-editor).
  # Computed once here (before the loop) because the process substitution
  # feeding the `while read` is set up at loop entry, not per iteration.
  local canon_arg
  canon_arg=$(IFS=,; printf '%s' "${REQUIRED_NAMES[*]},${OPTIONAL_NAMES[*]}")

  while IFS=$'\t' read -r att_name payload_id; do
    [ -z "$att_name" ] && continue
    [ -z "$payload_id" ] && continue
    if [[ ! "$att_name" =~ ^screenshot-[a-zA-Z0-9_-]+$ ]]; then
      echo "  Skipping attachment with invalid name: $att_name" >&2
      continue
    fi
    # Validate payload_id — Xcode 26 payload ids look like "0~<base64>=="
    # and include '~' and '='. Allow those alongside alphanumerics, dots,
    # dashes, and underscores.
    if [[ ! "$payload_id" =~ ^[a-zA-Z0-9._~=-]+$ ]]; then
      echo "  Skipping attachment with invalid payload_id: $payload_id" >&2
      continue
    fi
    # Payloads are stored under Data/ with a "data." prefix on Xcode 26
    # (e.g. Data/data.<payload_id>). Fall back to the unprefixed path for
    # older bundle formats just in case.
    local src="$RESULT_PATH/Data/data.$payload_id"
    if [ ! -f "$src" ]; then
      src="$RESULT_PATH/Data/$payload_id"
    fi
    if [ ! -f "$src" ]; then
      echo "  Warning: payload not found at $RESULT_PATH/Data/data.$payload_id" >&2
      continue
    fi
    cp -- "$src" "$ASSETS_DIR/${att_name}.png"
    echo "  Extracted ${att_name}.png"
    found_any=true
  done < <(python3 - "$XCRESULTTOOL" "$RESULT_PATH" "$canon_arg" <<'PY'
import json, os, subprocess, sys

xcresulttool = sys.argv[1]
bundle_path = sys.argv[2]
# Known screenshot base names (passed in from the bash arrays), used to map
# Xcode 26's suffixed attachment names back to the canonical file names the
# workflow expects.
canonical_names = sys.argv[3].split(",") if len(sys.argv) > 3 else []

def get_json(args):
    r = subprocess.run([xcresulttool] + args, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  xcresulttool error: {r.stderr}", file=sys.stderr)
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError as e:
        print(f"  Failed to parse xcresulttool output as JSON: {e}", file=sys.stderr)
        print(f"  Output preview: {r.stdout[:200]}", file=sys.stderr)
        return None

def find_test_ids(node):
    results = []
    node_type = node.get("nodeType", "")
    name = node.get("name", "")
    if node_type == "Test Case" and name.startswith("testCapture"):
        # xcresulttool uses nodeIdentifierURL as test identifier for --test-id;
        # fall back to nodeIdentifier for older Xcode versions
        tid = node.get("nodeIdentifierURL", "") or node.get("nodeIdentifier", "")
        if tid:
            results.append(tid)
    for child in node.get("children", []):
        results.extend(find_test_ids(child))
    return results

def canonical_name(raw):
    # Xcode 26 stores attachment names like
    #   "screenshot-editor_0_<UUID>.png"
    # rather than the bare "screenshot-editor" the workflow expects. Map the
    # raw name back to a known canonical name so the required-names guardrail
    # and the commit step keep working unchanged.
    base = raw[:-4] if raw.endswith(".png") else raw
    for c in canonical_names:
        if base == c or base.startswith(c + "_"):
            return c
    return None

def walk_activities(node):
    # Attachments live under testRuns[*].activities[*].attachments (with
    # optional nested childActivities). The top-level activities JSON has a
    # "testRuns" array rather than direct attachments, so this walker is
    # seeded with each run's activities list — see call site below.
    if isinstance(node, dict):
        for att in node.get("attachments", []):
            att_name = att.get("name", "")
            payload_id = att.get("payloadId", "")
            if not att_name or not payload_id:
                continue
            canon = canonical_name(att_name)
            if canon:
                print(f"{canon}\t{payload_id}")
            else:
                print(f"  Skipping non-canonical attachment: {att_name}", file=sys.stderr)
        for child in node.get("childActivities", []):
            walk_activities(child)
    elif isinstance(node, list):
        for item in node:
            walk_activities(item)

data = get_json(["get", "test-results", "tests", "--path", bundle_path])
if not data:
    sys.exit(1)

# On Xcode 26 the test tree is rooted at top-level "testNodes" — the whole
# document has no "children" key — so seed find_test_ids with each testNodes
# entry rather than with the document root. (The previous implementation
# walked the non-existent root "children" and silently found zero tests,
# which is what made this workflow fail on every release since v1.26.3.)
test_ids = []
for root in data.get("testNodes", []):
    test_ids.extend(find_test_ids(root))
if not test_ids:
    print("  No screenshot test cases found in xcresult bundle.", file=sys.stderr)
    # Diagnostic: show first 5 files in Data/ to help debug extraction failures
    data_dir = bundle_path + "/Data"
    if os.path.isdir(data_dir):
        all_entries = os.listdir(data_dir)
        entries = sorted(all_entries)[:5]
        print(f"  Diagnostic: Data/ directory has {len(all_entries)} entries, first 5: {entries}", file=sys.stderr)
    else:
        print(f"  Diagnostic: Data/ directory does not exist at {data_dir}", file=sys.stderr)
    sys.exit(1)

for tid in test_ids:
    act_data = get_json(["get", "test-results", "activities",
                         "--path", bundle_path, "--test-id", tid])
    if not act_data:
        continue
    for run in act_data.get("testRuns", []):
        walk_activities(run.get("activities", []))
PY
  )

  [ "$found_any" = true ] && return 0
  echo "  No attachments were extracted from any test case." >&2
  echo "  Diagnostic: listing first 5 files in Data/ directory:" >&2
  ls "$RESULT_PATH/Data/" 2>/dev/null | head -5 >&2 || echo "  (Data/ directory not found or empty)" >&2
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
