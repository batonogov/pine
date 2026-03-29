#!/usr/bin/env bash
# record-demo.sh — Automated demo recording for Pine editor
# Records a screen capture of Pine showcasing key features,
# then converts to GIF for README embedding.
#
# Prerequisites:
#   - macOS 14+ with screen recording permission granted to Terminal
#   - Pine.app installed or built (xcodebuild archive)
#   - ffmpeg: brew install ffmpeg
#   - gifski (optional, higher quality): brew install gifski
#   - cliclick: brew install cliclick
#
# Usage:
#   ./scripts/record-demo.sh [--no-record] [--gif-only] [--output DIR]
#
# Flags:
#   --no-record   Skip recording, only convert existing capture to GIF
#   --gif-only    Alias for --no-record
#   --output DIR  Output directory (default: ./demo-output)

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

DEMO_PROJECT="${DEMO_PROJECT:-$(mktemp -d /tmp/pine-demo.XXXXXX)}"
OUTPUT_DIR="./demo-output"
VIDEO_FILE=""
GIF_FILE=""
RECORD=true
FPS=15
GIF_WIDTH=960
MAX_GIF_SIZE_MB=10
CAPTURE_PID=""

# ─── Parse arguments ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-record|--gif-only)
            RECORD=false
            shift
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

mkdir -p "$OUTPUT_DIR"
VIDEO_FILE="$OUTPUT_DIR/pine-demo.mov"
GIF_FILE="$OUTPUT_DIR/pine-demo.gif"

# ─── Helpers ─────────────────────────────────────────────────────────────────

cleanup() {
    echo "Cleaning up..."
    # Stop screen recording if still running
    if [[ -n "$CAPTURE_PID" ]] && kill -0 "$CAPTURE_PID" 2>/dev/null; then
        kill "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
    fi
    # Quit Pine
    osascript -e 'tell application "Pine" to quit' 2>/dev/null || true
    # Clean up temp demo project
    if [[ "$DEMO_PROJECT" == /tmp/pine-demo.* ]]; then
        rm -rf "$DEMO_PROJECT"
    fi
}
trap cleanup EXIT

check_deps() {
    local missing=()
    command -v ffmpeg >/dev/null || missing+=("ffmpeg")
    command -v cliclick >/dev/null || missing+=("cliclick")
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing dependencies: ${missing[*]}"
        echo "Install with: brew install ${missing[*]}"
        exit 1
    fi
}

wait_for_window() {
    local app_name="$1"
    local timeout="${2:-10}"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local count
        count=$(osascript -e "tell application \"System Events\" to count windows of process \"$app_name\"" 2>/dev/null || echo "0")
        if [[ "$count" -gt 0 ]]; then
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    echo "Timed out waiting for $app_name window" >&2
    return 1
}

type_text() {
    # Type text character by character with a natural delay
    local text="$1"
    local delay="${2:-50}" # milliseconds between keystrokes
    cliclick -e "$delay" "t:$text"
}

press_key() {
    # Press a key combo, e.g., "cmd+s", "cmd+shift+b"
    cliclick "kp:$1"
}

# ─── Prepare demo project ───────────────────────────────────────────────────

setup_demo_project() {
    echo "Setting up demo project at $DEMO_PROJECT..."

    mkdir -p "$DEMO_PROJECT/src"

    # Swift file with syntax highlighting showcase
    cat > "$DEMO_PROJECT/src/App.swift" << 'SWIFT'
import SwiftUI

@main
struct DemoApp: App {
    @State private var counter = 0

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("Hello, Pine!")
                    .font(.largeTitle)
                    .foregroundStyle(.primary)

                Button("Count: \(counter)") {
                    counter += 1
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}
SWIFT

    # Python file for multi-language showcase
    cat > "$DEMO_PROJECT/src/server.py" << 'PYTHON'
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class APIHandler(BaseHTTPRequestHandler):
    """Simple REST API handler for demo purposes."""

    def do_GET(self):
        response = {"status": "ok", "message": "Pine Editor Demo"}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(response).encode())

if __name__ == "__main__":
    server = HTTPServer(("localhost", 8080), APIHandler)
    print("Server running on http://localhost:8080")
    server.serve_forever()
PYTHON

    # JavaScript file
    cat > "$DEMO_PROJECT/src/index.js" << 'JS'
// Pine Editor — Feature Demo
const features = [
    "Syntax Highlighting",
    "Integrated Terminal",
    "Git Integration",
    "Minimap",
    "Symbol Navigation",
    "Code Folding",
];

function showFeatures() {
    features.forEach((feature, i) => {
        console.log(`${i + 1}. ${feature}`);
    });
}

showFeatures();
JS

    # README for the demo project
    cat > "$DEMO_PROJECT/README.md" << 'MD'
# Demo Project

This is a sample project used to showcase **Pine** editor features.

## Features Shown
- Fast launch and project opening
- Multi-language syntax highlighting
- Integrated terminal
- File tree navigation
- Minimap and code folding
MD

    # Initialize git repo for git features demo
    (
        cd "$DEMO_PROJECT"
        git init -q
        git add -A
        git commit -q -m "Initial commit"
        # Create a branch for branch switching demo
        git checkout -q -b feature/demo
        echo "// Added in feature branch" >> src/App.swift
        git add -A
        git commit -q -m "Add feature branch changes"
        git checkout -q main
    )

    echo "Demo project ready."
}

# ─── Record screen ───────────────────────────────────────────────────────────

start_recording() {
    echo "Starting screen recording -> $VIDEO_FILE"
    # Use screencapture for native macOS recording (records main display)
    screencapture -v -C -G 3 "$VIDEO_FILE" &
    CAPTURE_PID=$!
    sleep 1 # Let recording initialize
}

stop_recording() {
    echo "Stopping screen recording..."
    if [[ -n "$CAPTURE_PID" ]] && kill -0 "$CAPTURE_PID" 2>/dev/null; then
        # screencapture -v stops on Ctrl+C / SIGINT
        kill -INT "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
        CAPTURE_PID=""
    fi
    sleep 1
    echo "Recording saved to $VIDEO_FILE"
}

# ─── Demo actions ────────────────────────────────────────────────────────────

run_demo() {
    echo "Running demo sequence..."

    # Scene 1: Launch Pine and open project
    echo "  Scene 1: Launch Pine..."
    open -a "Pine"
    wait_for_window "Pine" 15
    sleep 2

    # Open the demo project via Cmd+Shift+O
    echo "  Scene 1: Open demo project..."
    cliclick "kd:cmd" "kp:shift" "kp:o" "ku:cmd"
    sleep 1
    # Type the project path in the open dialog
    cliclick "kd:cmd,shift" "kp:g" "ku:cmd,shift"
    sleep 0.5
    type_text "$DEMO_PROJECT"
    cliclick "kp:return"
    sleep 0.5
    cliclick "kp:return"
    sleep 2

    # Scene 2: Browse file tree — click on files
    echo "  Scene 2: Browse files..."
    # Click on src/App.swift in sidebar (coordinates will vary — adjust as needed)
    sleep 1

    # Scene 3: Show syntax highlighting — open different file types
    echo "  Scene 3: Syntax highlighting..."
    # Use Quick Open (Cmd+P) to open files
    cliclick "kd:cmd" "kp:p" "ku:cmd"
    sleep 0.5
    type_text "server.py"
    sleep 0.5
    cliclick "kp:return"
    sleep 2

    cliclick "kd:cmd" "kp:p" "ku:cmd"
    sleep 0.5
    type_text "index.js"
    sleep 0.5
    cliclick "kp:return"
    sleep 2

    # Scene 4: Toggle terminal
    echo "  Scene 4: Integrated terminal..."
    cliclick "kd:cmd" "kp:\`" "ku:cmd"
    sleep 1
    type_text "echo 'Hello from Pine Terminal!'"
    cliclick "kp:return"
    sleep 2

    # Scene 5: Symbol navigation (Cmd+Shift+J)
    echo "  Scene 5: Symbol navigation..."
    cliclick "kd:cmd" "kp:p" "ku:cmd"
    sleep 0.5
    type_text "App.swift"
    sleep 0.5
    cliclick "kp:return"
    sleep 1

    # Scene 6: Branch switching (Cmd+Shift+B)
    echo "  Scene 6: Branch switching..."
    cliclick "kd:cmd,shift" "kp:b" "ku:cmd,shift"
    sleep 1
    type_text "feature"
    sleep 1
    cliclick "kp:return"
    sleep 2

    # Scene 7: Go to line (Cmd+L)
    echo "  Scene 7: Go to line..."
    cliclick "kd:cmd" "kp:l" "ku:cmd"
    sleep 0.5
    type_text "10"
    cliclick "kp:return"
    sleep 1

    # Scene 8: Find and replace (Cmd+F)
    echo "  Scene 8: Find in file..."
    cliclick "kd:cmd" "kp:f" "ku:cmd"
    sleep 0.5
    type_text "counter"
    sleep 2
    cliclick "kp:escape"
    sleep 1

    echo "Demo sequence complete."
}

# ─── Convert to GIF ─────────────────────────────────────────────────────────

convert_to_gif() {
    if [[ ! -f "$VIDEO_FILE" ]]; then
        echo "Video file not found: $VIDEO_FILE" >&2
        exit 1
    fi

    echo "Converting $VIDEO_FILE to GIF..."

    if command -v gifski >/dev/null; then
        # Higher quality with gifski
        local frames_dir
        frames_dir=$(mktemp -d)
        ffmpeg -y -i "$VIDEO_FILE" -vf "fps=$FPS,scale=$GIF_WIDTH:-1" "$frames_dir/frame%04d.png"
        gifski --fps "$FPS" --width "$GIF_WIDTH" --quality 90 -o "$GIF_FILE" "$frames_dir"/frame*.png
        rm -rf "$frames_dir"
    else
        # ffmpeg-only fallback
        ffmpeg -y -i "$VIDEO_FILE" \
            -vf "fps=$FPS,scale=$GIF_WIDTH:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3" \
            "$GIF_FILE"
    fi

    local size_mb
    size_mb=$(du -m "$GIF_FILE" | awk '{print $1}')
    echo "GIF created: $GIF_FILE (${size_mb}MB)"

    if [[ "$size_mb" -gt "$MAX_GIF_SIZE_MB" ]]; then
        echo "WARNING: GIF is larger than ${MAX_GIF_SIZE_MB}MB. Consider:"
        echo "  - Reducing FPS (current: $FPS)"
        echo "  - Reducing width (current: $GIF_WIDTH)"
        echo "  - Trimming video duration"
        echo "  - Using gifski for better compression"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    check_deps

    if [[ "$RECORD" == true ]]; then
        setup_demo_project
        start_recording
        run_demo
        stop_recording
    fi

    convert_to_gif

    echo ""
    echo "Done! Output files:"
    echo "  Video: $VIDEO_FILE"
    echo "  GIF:   $GIF_FILE"
    echo ""
    echo "To embed in README:"
    echo '  ![Pine Demo](assets/pine-demo.gif)'
}

main
