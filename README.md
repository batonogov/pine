# Pine

[![CI](https://github.com/batonogov/pine/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/batonogov/pine/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/batonogov/pine)](https://github.com/batonogov/pine/releases/latest)
[![License: MIT](https://img.shields.io/github/license/batonogov/pine)](https://github.com/batonogov/pine/blob/main/LICENSE)
[![macOS](https://img.shields.io/badge/macOS-26%2B-blue)](https://github.com/batonogov/pine)

> A minimal native code editor for macOS.

<!-- TODO: hero screenshot — full editor window with Liquid Glass, dark mode, real project open -->
<!-- Screenshots will be added by Fedor -->

Pine is a code editor for developers who want a fast, native Mac app without the overhead of Electron. Built with SwiftUI and AppKit, designed for macOS 26 Liquid Glass. Opens instantly, stays out of your way.

## Features

- **Native macOS** -- SwiftUI + AppKit, Liquid Glass UI, system text handling. No browser engine, no runtime
- **Syntax highlighting** -- 37 languages including Swift, TypeScript, Python, Go, Rust, Java, Kotlin, Ruby, C/C++, and more
- **Built-in terminal** -- Full VT100/xterm emulator via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). Multiple tabs, colors, TUI apps, oh-my-zsh
- **Git integration** -- File status in sidebar, diff markers in gutter, blame view, branch switching from title bar or search sheet
- **Symbol navigation** -- Jump to functions and classes with Cmd+Shift+J
- **Code folding** -- Fold/unfold blocks from the gutter or via menu
- **Minimap** -- Scaled code overview with syntax colors and diff markers. Click to navigate
- **Find & replace** -- In-file and project-wide search with .gitignore support
- **Quick Open** -- Fuzzy file search with Cmd+P
- **Markdown preview** -- Source, rendered, or side-by-side
- **Auto-save & session restore** -- Picks up where you left off
- **Auto-updates** -- Built-in via [Sparkle](https://sparkle-project.org)
- **Localized** -- English, German, Spanish, French, Japanese, Korean, Portuguese (BR), Russian, Simplified Chinese

<!-- TODO: 3-4 screenshots showing key features -->
<!-- - Editor with syntax highlighting + minimap -->
<!-- - Git blame + diff markers + branch switcher -->
<!-- - Terminal split view -->
<!-- - Welcome screen -->

## Install

**Homebrew** (recommended):

```bash
brew tap batonogov/tap
brew install --cask pine-editor
```

**Direct download:** grab the latest `.dmg` from [Releases](https://github.com/batonogov/pine/releases/latest).

## Build from Source

Requires macOS 26+ and Xcode 26+.

```bash
git clone https://github.com/batonogov/pine.git
cd pine
xcodebuild -project Pine.xcodeproj -scheme Pine build
```

Dependencies resolve automatically via Swift Package Manager on first build.

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `Cmd+P` | Quick Open |
| `Cmd+Shift+O` | Open folder |
| `Cmd+S` | Save |
| `Cmd+Option+S` | Save All |
| `Cmd+Shift+S` | Save As |
| `Cmd+W` | Close tab |
| `Cmd+F` | Find |
| `Cmd+Option+F` | Find & Replace |
| `Cmd+G` / `Cmd+Shift+G` | Find Next / Previous |
| `Cmd+L` | Go to Line |
| `Cmd+Shift+J` | Go to Symbol |
| `Cmd+/` | Toggle comment |
| `Cmd+Shift+B` | Switch branch |
| `Cmd+Shift+M` | Toggle minimap |
| `` Cmd+` `` | Toggle terminal |
| `Cmd+T` | New terminal tab |
| `Cmd++` / `Cmd+-` | Zoom in / out |

## Architecture

MVVM with SwiftUI views backed by AppKit via `NSViewRepresentable`. The editor core uses the native NSTextStorage/NSLayoutManager/NSTextContainer stack. Syntax highlighting runs asynchronously on a background queue with generation tokens to prevent stale results. Git operations run in parallel via GCD. Project-wide search uses Swift concurrency with sliding-window parallelism.

See [CLAUDE.md](CLAUDE.md) for the full technical reference.

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change. See the [Issues](https://github.com/batonogov/pine/issues) page.

## License

[MIT](LICENSE)
