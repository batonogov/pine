---
paths:
  - "PineTests/SnapshotTests/**"
---

# Snapshot testing

Pine uses a minimal zero-dependency visual snapshot harness for SwiftUI views. Reference PNGs live under `PineTests/SnapshotTests/__Snapshots__/`. No third-party packages, no pbxproj edits.

- **Harness:** `PineTests/SnapshotTests/SnapshotHarness.swift` — renders a SwiftUI view via `NSHostingView` into an `NSBitmapImageRep` under a given `NSAppearance` (`.light` / `.dark`), encodes to PNG, and compares against the reference using a mean-absolute per-pixel RGBA diff normalized to `[0, 1]`. Default tolerance is `0.01` to absorb trivial anti-aliasing noise.
- **Backing scale independence:** the bitmap is allocated explicitly at 1× the logical size (`pixelsWide == Int(size.width)`) so output is identical on Retina (2×) developer machines and on macOS CI runners' 1× virtual displays. Without this, baselines recorded on a Retina Mac differ in pixel dimensions from CI output and the diff short-circuits to `1.0` (dimension mismatch). The bitmap is also pre-filled with `NSColor.windowBackgroundColor` under the requested appearance so semi-transparent system colors (e.g. `.secondary` text in dark mode) composite onto a realistic backdrop instead of a transparent canvas.
- **Writing a test:** import the harness (it lives in the `PineTests` target) and call `try assertSnapshot(of: MyView(), size: NSSize(width: W, height: H), appearance: .light, named: "MyView.light")`. Cover both `.light` and `.dark` for every view. Use local `Harness` wrapper views for SwiftUI bindings.
- **Stability:** stub out any data source that can vary between machines (e.g. populate `ProjectRegistry.recentProjects` and `GitStatusProvider.branches` manually). Never snapshot a view that depends on real git state, real filesystem contents, or network.
- **Running:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -skipPackagePluginValidation -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/WelcomeViewSnapshotTests` (one suite at a time).
- **Updating snapshots:** run tests with `PINE_RECORD_SNAPSHOTS=1` in the test environment (set it via the Pine scheme's Test action, or pass as the final positional `KEY=VALUE` arg to `xcodebuild test`). In record mode the harness always overwrites the reference PNG and passes. Review the PNG diff in the PR before merging.
- **First run:** if no reference exists the harness writes a baseline and fails the test so new baselines can never sneak in silently. A failing test also writes an `<name>.actual.png` alongside the reference for visual inspection.
- **Current coverage:** 21 view suites / 107 reference PNGs — navigation overlays (including the GoToLine overlay hosted in the production `CommandOverlayWindow` chrome), agent surfaces, settings panes, editor chrome, and the welcome screen; light and dark renders per view, with several suites pinning additional states. Remaining scope from issue #796 (editor gutter, sidebar file tree, minimap, diagnostic popover, inline diff) is tracked as follow-ups — the tab bar is now partially covered via `EditorTabItem` snapshots.
