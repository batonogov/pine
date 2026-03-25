# Pine

[![CI](https://github.com/batonogov/pine/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/batonogov/pine/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/batonogov/pine)](https://github.com/batonogov/pine/releases/latest)
[![License: MIT](https://img.shields.io/github/license/batonogov/pine)](https://github.com/batonogov/pine/blob/main/LICENSE)
[![macOS](https://img.shields.io/badge/macOS-26%2B-blue)](https://github.com/batonogov/pine)
[![Homebrew Cask](https://img.shields.io/badge/homebrew-pine--editor-orange)](https://github.com/batonogov/homebrew-tap)

> A code editor that belongs on your Mac.

![Pine Editor](assets/screenshot-editor.png)

Pine is a code editor for macOS purists. Native SwiftUI + AppKit, Liquid Glass on macOS 26, zero Electron. One window, one project — just a real Mac app.

## Why Pine

Most editors keep adding layers until opening a project feels like launching a platform. Pine goes the other direction:

- **Fast.** Native binary, no browser engine, no startup lag.
- **Minimal.** One dependency ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)), no plugins, no configuration sprawl.
- **Native.** SwiftUI + AppKit, system text handling, Liquid Glass UI on macOS 26.

If VS Code feels heavy and Xcode feels like overkill for everyday editing, Pine is the middle ground.

## Features

- **Editor** — Line numbers, current-line highlight, smart indent, find bar, undo, bracket matching, and grammar-based syntax highlighting
- **Minimap** — Code overview panel with proportional scrolling and click-to-navigate
- **Syntax highlighting** — Swift, TypeScript, JavaScript, Python, Go, Rust, C, C++, SQL, Shell, HTML, CSS, JSON, YAML, Markdown, Dockerfile
- **Terminal** — Multiple tabs powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (full VT100/xterm with colors, oh-my-zsh, TUI apps)
- **Git** — File status in the sidebar, diff markers in the gutter, branch switching via title bar click or search sheet
- **Markdown preview** — Source, preview, and side-by-side split modes
- **Quick Look** — Preview images and non-text files without leaving the editor
- **File management** — New file/folder, rename, duplicate, delete, reveal in Finder from the sidebar context menu
- **Large file warning** — Prompts before opening files over 1 MB with the option to skip syntax highlighting
- **Auto-updates** — Built-in update mechanism via [Sparkle](https://sparkle-project.org)
- **Session restore** — Reopens your tabs and project state between launches
- **Localized** — English, German, Spanish, French, Japanese, Korean, Portuguese (BR), Russian, Simplified Chinese

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `Cmd+Shift+O` | Open folder |
| `Cmd+S` | Save |
| `Cmd+Option+S` | Save All |
| `Cmd+Shift+S` | Save As |
| `Cmd+Shift+D` | Duplicate tab |
| `Cmd+W` | Close tab |
| ``Cmd+` `` | Toggle terminal |
| `Cmd+T` | New terminal tab |
| `Cmd+Shift+B` | Switch branch |
| `Cmd+Shift+M` | Toggle minimap |
| `Cmd+Shift+P` | Toggle Markdown preview |
| `Cmd+/` | Toggle line comment |
| `Cmd++` / `Cmd+-` | Zoom in / out |
| `Cmd+0` | Reset font size |

## Install

```bash
brew tap batonogov/tap
brew install --cask pine-editor
```

Or download the latest `.dmg` from [Releases](https://github.com/batonogov/pine/releases).

## Build From Source

Requires macOS 26+ and Xcode 26+.

```bash
git clone https://github.com/batonogov/pine.git
cd pine
xcodebuild -project Pine.xcodeproj -scheme Pine build
```

SwiftTerm is resolved automatically via Swift Package Manager on first build.

## Built With

- SwiftUI for app structure and native macOS UI
- AppKit text system for the editor core
- JSON grammars for syntax highlighting
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal emulator

## License

MIT
