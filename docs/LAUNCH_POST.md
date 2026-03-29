# Pine Launch Posts

Prepared launch materials for Hacker News and Reddit. Adapt tone and length per platform.

---

## Hacker News

### Title

Show HN: Pine -- A minimal native code editor for macOS, built with SwiftUI + AppKit

### Body

Pine is a code editor for macOS developers who want something fast and native without the overhead of Electron.

**What it does:**

- Syntax highlighting for 37 languages (Swift, TypeScript, Python, Go, Rust, C/C++, and more)
- Built-in terminal (full VT100/xterm via SwiftTerm -- vim, htop, oh-my-zsh all work)
- Git integration: file status in sidebar, diff markers in gutter, blame view, branch switching
- Code folding, minimap, bracket matching, find & replace (in-file + project-wide)
- Quick Open (Cmd+P), Go to Line (Cmd+L), symbol navigation (Cmd+R)
- Markdown preview (source, rendered, or side-by-side)
- Session restore, auto-save, auto-updates via Sparkle
- Localized in 9 languages

**Why I built it:**

I wanted a code editor that feels like a real Mac app. Most editors today are Electron wrappers -- they work, but they don't feel native. Pine is built entirely with SwiftUI and AppKit, designed for macOS 26 Liquid Glass. It opens instantly, uses system text handling, and stays out of your way.

**Tech stack:**

- SwiftUI + AppKit (NSViewRepresentable bridges for the editor and terminal)
- NSTextStorage / NSLayoutManager / NSTextContainer for the text system
- SwiftTerm for terminal emulation
- GCD for background work (syntax highlighting, git ops, file tree loading)
- JSON-based grammar files for syntax highlighting with priority-based scope resolution
- FSEvents for file system watching
- ~12k LOC app code, ~18k LOC tests (unit + UI + performance)

**Performance targets:**

- <4ms main thread work per scroll frame (120Hz ProMotion)
- Viewport-only highlighting for files >100KB
- Progressive loading for files >10MB

**Install:**

```
brew tap batonogov/tap && brew install --cask pine-editor
```

Or download from GitHub Releases.

- GitHub: https://github.com/batonogov/pine
- MIT License

I'd love feedback on what's missing or what could be better. This is a solo project and I'm actively developing it.

---

## Reddit r/macapps

### Title

Pine -- A minimal native code editor for macOS (SwiftUI + AppKit, no Electron)

### Body

I've been building a code editor for macOS that's fully native -- no Electron, no web views, just SwiftUI and AppKit with macOS 26 Liquid Glass design.

**Highlights:**

- Syntax highlighting for 37 languages
- Built-in terminal with full VT100/xterm support
- Git integration (status, diff markers, blame, branch switching)
- Code folding, minimap, Quick Open (Cmd+P), symbol navigation
- Markdown preview
- Project-wide search with .gitignore support
- Auto-save, session restore, auto-updates
- Localized in 9 languages

**Install:**

```
brew tap batonogov/tap && brew install --cask pine-editor
```

It's open source (MIT): https://github.com/batonogov/pine

I'm not trying to replace VS Code or Xcode -- Pine is for people who want a lightweight, fast editor that feels like a proper Mac app. Think CotEditor territory but with a built-in terminal and git integration.

Feedback welcome -- what features would make this useful for your workflow?

---

## Reddit r/swift

### Title

Pine -- a native macOS code editor built with SwiftUI + AppKit (open source)

### Body

I've been working on Pine, a minimal code editor for macOS built entirely with Swift. Sharing it here because the architecture might be interesting to fellow Swift developers.

**Architecture:**

- MVVM with SwiftUI views backed by AppKit via `NSViewRepresentable`
- `@Observable` macro (not ObservableObject/Published)
- Text system: NSTextStorage -> NSLayoutManager -> NSTextContainer -> custom NSTextView subclass
- Terminal: SwiftTerm (pure Swift VT100/xterm emulator)
- Concurrency: GCD for background work, bridged to async/await via `withCheckedContinuation`
- Generation tokens to prevent stale async results from overwriting newer ones
- FSEvents for file system watching
- JSON-based grammar files for syntax highlighting with regex + priority-based scope resolution

**Some interesting implementation details:**

- Viewport-only syntax highlighting for large files (>100KB) to hit <4ms per frame at 120Hz
- Two-phase file tree loading (shallow pass for immediate render, then full async load)
- SwiftUI's `toolbarTitleMenu` doesn't work on macOS 26 with Liquid Glass, so branch switching uses an AppKit workaround with `NSClickGestureRecognizer` on the subtitle NSTextField
- Code folding via bracket pair scanning with binary search for line number resolution
- ~12k LOC app, ~18k LOC tests (Swift Testing + XCUITest), CI with 6 parallel UI test shards

**Install:**

```
brew tap batonogov/tap && brew install --cask pine-editor
```

GitHub: https://github.com/batonogov/pine (MIT)

Happy to answer questions about the architecture or any of the AppKit/SwiftUI bridging patterns.

---

## Key Talking Points

Use these when responding to comments:

1. **Native, not Electron** -- SwiftUI + AppKit, system text handling, Liquid Glass UI. No browser engine, no runtime overhead.
2. **Fast** -- targets <4ms main thread per frame at 120Hz. Viewport-only highlighting, progressive file loading, async everything.
3. **Real terminal** -- SwiftTerm gives full VT100/xterm. vim, htop, oh-my-zsh all work. Not a pseudo-terminal.
4. **Tested** -- 18k LOC of tests. Unit tests (Swift Testing), UI tests (XCUITest with 6 parallel shards), performance benchmarks.
5. **Open source (MIT)** -- solo project, actively developed, contributions welcome.
6. **Not trying to be VS Code** -- it's a lightweight editor for people who want something fast and native. Think CotEditor + terminal + git.
7. **Homebrew install** -- `brew tap batonogov/tap && brew install --cask pine-editor`. One command.
8. **macOS 26 Liquid Glass** -- first-class support for the new design language.

### Comparison talking points (if asked)

| | Pine | CotEditor | Nova | Zed | VS Code |
|---|---|---|---|---|---|
| Native macOS | Yes | Yes | Yes | Yes (GPU) | No (Electron) |
| Terminal | Yes | No | Yes | Yes | Yes |
| Git integration | Yes | No | Yes | Yes | Yes (ext) |
| Open source | MIT | Apache 2.0 | No | GPL/AGPL | MIT |
| Liquid Glass | Yes | Not yet | Not yet | No | No |
| Price | Free | Free | $99 | Free | Free |
