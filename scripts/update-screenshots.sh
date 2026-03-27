#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RESULT_PATH="$REPO_ROOT/build/screenshots.xcresult"

# Clean previous result bundle
rm -rf "$RESULT_PATH"

echo "Running screenshot tests..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
  -project "$REPO_ROOT/Pine.xcodeproj" \
  -scheme Pine \
  -destination 'platform=macOS' \
  -only-testing:PineUITests/ScreenshotTests \
  -resultBundlePath "$RESULT_PATH" \
  || true

if [ ! -d "$RESULT_PATH" ]; then
  echo "Error: xcresult bundle not found at $RESULT_PATH"
  exit 1
fi

echo "Extracting screenshots..."

# Get the test plan run summaries from xcresult
GRAPH=$(xcrun xcresulttool get --path "$RESULT_PATH" --format json 2>/dev/null)

# Extract all attachment IDs and names from the xcresult graph
# Walk: actions -> actionResult -> testsRef -> summaries -> testableSummaries -> tests -> subtests -> ...
TESTS_REF_ID=$(echo "$GRAPH" | python3 -c "
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
")

if [ -z "$TESTS_REF_ID" ]; then
  echo "Error: could not find testsRef in xcresult"
  exit 1
fi

# Get the test plan run summaries
TESTS_SUMMARY=$(xcrun xcresulttool get --path "$RESULT_PATH" --format json --id "$TESTS_REF_ID" 2>/dev/null)

# Extract attachment references (id + name) from test summaries
ATTACHMENTS=$(echo "$TESTS_SUMMARY" | python3 -c "
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
")

if [ -z "$ATTACHMENTS" ]; then
  echo "Error: no screenshot attachments found in test results"
  exit 1
fi

ASSETS_DIR="$REPO_ROOT/assets"
mkdir -p "$ASSETS_DIR"

COUNT=0
while IFS='|' read -r ATT_ID ATT_NAME; do
  OUTPUT_FILE="$ASSETS_DIR/${ATT_NAME}.png"
  echo "  Extracting $ATT_NAME -> $OUTPUT_FILE"
  xcrun xcresulttool export --path "$RESULT_PATH" --id "$ATT_ID" --output-path "$OUTPUT_FILE" --type file 2>/dev/null
  COUNT=$((COUNT + 1))
done <<< "$ATTACHMENTS"

echo "Done! $COUNT screenshots saved to assets/"
