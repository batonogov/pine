#!/bin/bash
# Update screenshot assets from UI tests.
# Continues extraction even if some tests fail (no set -e on test step).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RESULT_PATH="$REPO_ROOT/build/screenshots.xcresult"
ASSETS_DIR="$REPO_ROOT/assets"

# Clean previous result bundle and old screenshots
rm -rf "$RESULT_PATH"

echo "Running screenshot tests..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
  -project "$REPO_ROOT/Pine.xcodeproj" \
  -scheme Pine \
  -destination 'platform=macOS' \
  -only-testing:PineUITests/ScreenshotTests \
  -resultBundlePath "$RESULT_PATH" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=NO \
  || echo "Warning: some tests failed, continuing with extraction of available screenshots..."

if [ ! -d "$RESULT_PATH" ]; then
  echo "Error: xcresult bundle not found at $RESULT_PATH"
  exit 1
fi

echo "Extracting screenshots..."
mkdir -p "$ASSETS_DIR"

# --- Strategy 1: New xcresulttool API (Xcode 16+ / macOS 26) ---
# `xcrun xcresulttool get test-results attachments` exports all attachments directly.
extract_with_new_api() {
  local export_dir
  export_dir=$(mktemp -d)

  if ! xcrun xcresulttool get test-results attachments \
       --path "$RESULT_PATH" \
       --output-path "$export_dir" 2>/dev/null; then
    rm -rf "$export_dir"
    return 1
  fi

  # Copy screenshot-*.png files
  local found_any=false
  while IFS= read -r -d '' file; do
    cp "$file" "$ASSETS_DIR/$(basename "$file")"
    echo "  Extracted $(basename "$file")"
    found_any=true
  done < <(find "$export_dir" -name "screenshot-*.png" -print0 2>/dev/null)

  # If no screenshot-* named files, try all PNGs
  if [ "$found_any" = false ]; then
    while IFS= read -r -d '' file; do
      cp "$file" "$ASSETS_DIR/$(basename "$file")"
      echo "  Extracted $(basename "$file")"
      found_any=true
    done < <(find "$export_dir" -name "*.png" -print0 2>/dev/null)
  fi

  rm -rf "$export_dir"
  [ "$found_any" = true ] && return 0
  return 1
}

# --- Strategy 2: Legacy xcresulttool JSON API (Xcode 15 and earlier) ---
extract_with_legacy_api() {
  local graph
  graph=$(xcrun xcresulttool get --path "$RESULT_PATH" --format json 2>/dev/null) || return 1

  local tests_ref_id
  tests_ref_id=$(echo "$graph" | python3 -c "
import json, sys
data = json.load(sys.stdin)
actions = data.get('actions', {}).get('_values', [])
for action in actions:
    result = action.get('actionResult', {})
    tests_ref = result.get('testsRef', {})
    ref_id = tests_ref.get('id', {}).get('_value', '')
    if ref_id:
        print(ref_id)
        break
" 2>/dev/null) || return 1

  if [ -z "$tests_ref_id" ]; then
    return 1
  fi

  local tests_summary
  tests_summary=$(xcrun xcresulttool get --path "$RESULT_PATH" --format json --id "$tests_ref_id" 2>/dev/null) || return 1

  local attachments
  attachments=$(echo "$tests_summary" | python3 -c "
import json, sys

def find_attachments(obj, results=None):
    if results is None:
        results = []
    if isinstance(obj, dict):
        if 'attachments' in obj:
            atts = obj['attachments'].get('_values', [])
            for att in atts:
                name = att.get('name', {}).get('_value', '')
                payload_ref = att.get('payloadRef', {})
                att_id = payload_ref.get('id', {}).get('_value', '')
                if name.startswith('screenshot-') and att_id:
                    results.append(f'{att_id}|{name}')
        for v in obj.values():
            find_attachments(v, results)
    elif isinstance(obj, list):
        for item in obj:
            find_attachments(item, results)
    return results

data = json.load(sys.stdin)
for line in find_attachments(data):
    print(line)
" 2>/dev/null) || return 1

  if [ -z "$attachments" ]; then
    return 1
  fi

  local count=0
  while IFS='|' read -r att_id att_name; do
    local output_file="$ASSETS_DIR/${att_name}.png"
    echo "  Extracting $att_name -> $output_file"
    xcrun xcresulttool export --path "$RESULT_PATH" --id "$att_id" --output-path "$output_file" --type file 2>/dev/null
    count=$((count + 1))
  done <<< "$attachments"

  [ "$count" -gt 0 ] && return 0
  return 1
}

# --- Strategy 3: Direct filesystem search inside xcresult bundle ---
# xcresult bundles are directories; attachments are stored as data files.
extract_with_filesystem() {
  local found_any=false

  # Look for files with PNG magic bytes (89 50 4E 47) inside the bundle
  while IFS= read -r -d '' file; do
    if head -c 4 "$file" 2>/dev/null | xxd -p 2>/dev/null | grep -q '^89504e47'; then
      local fname
      fname=$(basename "$file")
      cp "$file" "$ASSETS_DIR/screenshot-${fname}.png"
      echo "  Extracted screenshot-${fname}.png (from bundle)"
      found_any=true
    fi
  done < <(find "$RESULT_PATH" -type f -print0 2>/dev/null)

  [ "$found_any" = true ] && return 0
  return 1
}

# Try strategies in order
echo "Trying new xcresulttool API..."
if extract_with_new_api; then
  echo "Extraction complete (new API)."
else
  echo "New API not available, trying legacy API..."
  if extract_with_legacy_api; then
    echo "Extraction complete (legacy API)."
  else
    echo "Legacy API failed, trying direct filesystem extraction..."
    if extract_with_filesystem; then
      echo "Extraction complete (filesystem)."
    else
      echo "Error: all extraction strategies failed."
      exit 1
    fi
  fi
fi

# Count final results
FINAL_COUNT=$(find "$ASSETS_DIR" -name "screenshot-*.png" 2>/dev/null | wc -l | tr -d ' ')
echo "Done! $FINAL_COUNT screenshot(s) in assets/"
