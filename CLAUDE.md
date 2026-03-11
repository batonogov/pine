# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pine is a minimal native macOS code editor built with SwiftUI + AppKit. Targets macOS 26 (Tahoe) with Liquid Glass UI. The only external dependency is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal emulator.

## Build & Run

- **Xcode 26+** required, macOS 26+ deployment target
- Open `Pine.xcodeproj` in Xcode, build and run (Cmd+R)
- CLI build: `xcodebuild -project Pine.xcodeproj -scheme Pine build` (requires `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`)
- Type-check a single file (no sudo needed): `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -typecheck -target arm64-apple-macos26.0 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk <file.swift>`
- **Dependency:** SwiftTerm added via Xcode SPM (File > Add Package Dependencies > `https://github.com/migueldeicaza/SwiftTerm.git`)
- No other third-party dependencies
- **SwiftLint:** `brew install swiftlint` — runs as a build phase; config in `.swiftlint.yml`
- **Tests:** `xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS'`
- Test target: `PineTests` (Swift Testing framework) — covers git parsing, grammar models, file tree

## Architecture

**Pattern:** MVVM with SwiftUI views backed by AppKit via `NSViewRepresentable`.

**State management:** `ProjectManager` (@Observable) is the central state object managing file tree, editor tabs, terminal tabs, and git status. It communicates with views via SwiftUI observation and with menu commands via NotificationCenter.

**AppKit bridges:**
- `CodeEditorView` — wraps NSScrollView + custom `GutterTextView` (NSTextView subclass) + `LineNumberView` for the code editor
- `TerminalContentView` — wraps SwiftTerm's `LocalProcessTerminalView` (NSView) for the terminal

**Text system stack:** NSTextStorage → NSLayoutManager → NSTextContainer → GutterTextView (shifts text right for line number gutter)

**Terminal:** Uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — a full VT100/xterm terminal emulator in pure Swift. `TerminalTab` wraps `LocalProcessTerminalView` which handles PTY creation, escape sequence parsing, keyboard input, and rendering. Supports colors, cursor positioning, TUI apps (vim, htop), oh-my-zsh, and all standard terminal features. Terminal tabs use a custom tab bar with shared state across editor windows.

**Git integration:** `GitStatusProvider` runs `git status` and `git diff` to show file status indicators in the sidebar and diff markers (added/modified/deleted) in the editor gutter. Branch switching is available in the UI.

**Syntax highlighting:** `SyntaxHighlighter` singleton loads JSON grammar files from `Pine/Grammars/` at startup. Each grammar defines regex rules with scopes (comment, string, keyword, etc.) and a priority system prevents nested matches (comments > strings > keywords).

## Key Files

- `PineApp.swift` — @main entry point, keyboard shortcuts (Cmd+S, Cmd+Shift+O, Cmd+`)
- `ContentView.swift` — NavigationSplitView layout: sidebar (file tree) + detail (editor tabs + terminal)
- `ProjectManager.swift` — Central state: file tree, terminal tabs, git provider, project I/O
- `FileNode.swift` — Recursive tree model for filesystem
- `CodeEditorView.swift` — NSViewRepresentable editor with GutterTextView and LineNumberView
- `SyntaxHighlighter.swift` — Grammar loading, regex compilation, theme colors, highlighting application
- `LineNumberGutter.swift` — Line number rendering (enumerates only visible line fragments)
- `TerminalSession.swift` — SwiftTerm integration: TerminalTab, TerminalContentView (NSViewRepresentable), TerminalTabDelegate
- `GitStatusProvider.swift` — Git status/diff parsing for sidebar indicators and gutter markers
- `PineTests/` — Unit tests: GitStatusParserTests, GitDiffParserTests, FileNodeTests, GrammarModelTests

## Release & CI

- GitHub Actions workflow (`.github/workflows/release.yml`) triggers on `v*` tags
- Pipeline: build → code sign → notarize → create DMG → GitHub Release → update Homebrew Tap
- Secrets: `CERTIFICATE_P12`, `CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_ID_PASSWORD`, `APPLE_TEAM_ID`, `TAP_GITHUB_TOKEN`
- To release: `git tag v0.X.0 && git push origin v0.X.0` — CI handles the rest
- Homebrew: `brew tap batonogov/tap && brew install --cask pine-editor`

## Conventions

- Uses `@Observable` macro (Swift 5.9+), not ObservableObject/Published
- Models are either structs (EditorTab) or @Observable classes (FileNode, TerminalTab) depending on identity semantics
- Grammar files are JSON in `Pine/Grammars/` — add new languages by adding a new JSON file following the existing format
- Keyboard shortcuts flow through NotificationCenter (PineApp → ContentView → ProjectManager)
- UI uses semantic system colors (migrated from hardcoded dark theme values)
- macOS 26 SDK renamed `NSColor(sRGBRed:)` → `NSColor(srgbRed:)` (lowercase)
- Editor features: auto-indent on newline, current line highlight, git diff gutter markers
- Editor tabs use native macOS window tabs (not custom tab bar)

## GitHub Issues

When creating issues, always:
- Add appropriate labels from the repo's label set (e.g. `enhancement`, `bug`, `editor`, `UX`, `priority: high/medium/low`, etc.)
- Use a clear, concise title
- Include **Summary**, **Motivation**, and **Implementation ideas** sections in the body
