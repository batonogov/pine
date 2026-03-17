# Pine

> A fast, minimal, native macOS code editor.

![Pine Editor](assets/screenshot-editor.png)

![Pine Welcome](assets/screenshot-welcome.png)

![Pine Terminal](assets/screenshot-terminal.png)

Pine is a code editor for macOS 26+ built with SwiftUI and AppKit. One window, one project: open a folder, edit code, run commands, check git.

No Electron. No extension marketplace. No settings to dig through. Just a native Mac app that stays out of your way.

## Why Pine

Most editors keep adding layers until opening a project feels like launching a platform. Pine goes the other direction:

- **Fast.** Native binary, no browser engine, no startup lag.
- **Minimal.** One dependency ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)), no plugins, no configuration sprawl.
- **Native.** SwiftUI + AppKit, system text handling, Liquid Glass UI on macOS 26.

If VS Code feels heavy and Xcode feels like overkill for everyday editing, Pine is the middle ground.

## Features

- **Editor** — Line numbers, current-line highlight, smart indent, find bar, undo, and grammar-based syntax highlighting
- **Syntax highlighting** — Swift, TypeScript, JavaScript, Python, Go, Rust, Shell, HTML, CSS, JSON, YAML, Markdown, Dockerfile
- **Terminal** — Multiple tabs powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (full VT100/xterm with colors, oh-my-zsh, TUI apps)
- **Git** — File status in the sidebar, diff markers in the gutter, branch switching via title bar click or search sheet
- **Markdown preview** — Source, preview, and side-by-side split modes
- **Quick Look** — Preview images and non-text files without leaving the editor
- **File management** — New file/folder, rename, duplicate, delete, reveal in Finder from the sidebar context menu
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
| Cmd+\` | Toggle terminal |
| `Cmd+Shift+B` | Switch branch |
| `Cmd+Shift+P` | Toggle Markdown preview |

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
