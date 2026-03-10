# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pine is a minimal native macOS code editor built with SwiftUI + AppKit, zero external dependencies. Targets macOS 26 (Tahoe) with Liquid Glass UI.

## Build & Run

- **Xcode 26+** required, macOS 26+ deployment target
- Open `Pine.xcodeproj` in Xcode, build and run (Cmd+R)
- CLI build: `xcodebuild -project Pine.xcodeproj -scheme Pine build`
- No Swift Package Manager, no third-party dependencies
- No test targets yet

## Architecture

**Pattern:** MVVM with SwiftUI views backed by AppKit via `NSViewRepresentable`.

**State management:** `FileTreeViewModel` (@Observable) is the central state object managing file tree, editor tabs, and terminal tabs. It communicates with views via SwiftUI observation and with menu commands via NotificationCenter.

**AppKit bridges:**
- `CodeEditorView` — wraps NSScrollView + custom `GutterTextView` (NSTextView subclass) + `LineNumberView` for the code editor
- `TerminalContentView` — wraps custom `TerminalTextView` (NSTextView subclass) that intercepts all keyboard input and forwards to PTY

**Text system stack:** NSTextStorage → NSLayoutManager → NSTextContainer → GutterTextView (shifts text right for line number gutter)

**Terminal:** Uses `openpty()` (Darwin/BSD) to spawn `/bin/zsh` with a pseudo-terminal. `TerminalSession` manages the PTY lifecycle, ANSI stripping, and output parsing.

**Syntax highlighting:** `SyntaxHighlighter` singleton loads JSON grammar files from `Pine/Grammars/` at startup. Each grammar defines regex rules with scopes (comment, string, keyword, etc.) and a priority system prevents nested matches (comments > strings > keywords).

## Key Files

- `PineApp.swift` — @main entry point, keyboard shortcuts (Cmd+S, Cmd+Shift+O, Cmd+`)
- `ContentView.swift` — NavigationSplitView layout: sidebar (file tree) + detail (editor tabs + terminal)
- `FileTreeViewModel.swift` — Central state: file tree, editor tabs, terminal tabs, file I/O
- `FileNode.swift` — Recursive tree model for filesystem
- `CodeEditorView.swift` — NSViewRepresentable editor with GutterTextView and LineNumberView
- `SyntaxHighlighter.swift` — Grammar loading, regex compilation, theme colors, highlighting application
- `LineNumberGutter.swift` — Line number rendering (enumerates only visible line fragments)
- `TerminalSession.swift` — PTY management, process lifecycle, output parsing
- `TerminalContentView.swift` — Terminal NSViewRepresentable with custom key handling

## Conventions

- Uses `@Observable` macro (Swift 5.9+), not ObservableObject/Published
- Models are either structs (EditorTab) or @Observable classes (FileNode, TerminalTab) depending on identity semantics
- Grammar files are JSON in `Pine/Grammars/` — add new languages by adding a new JSON file following the existing format
- Keyboard shortcuts flow through NotificationCenter (PineApp → ContentView → FileTreeViewModel)
- All UI colors are currently hardcoded dark theme values (migration to semantic colors planned)

## GitHub Issues

When creating issues, always:
- Add appropriate labels from the repo's label set (e.g. `enhancement`, `bug`, `editor`, `UX`, `priority: high/medium/low`, etc.)
- Use a clear, concise title
- Include **Summary**, **Motivation**, and **Implementation ideas** sections in the body
