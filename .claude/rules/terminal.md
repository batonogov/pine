---
paths:
  - "Pine/Terminal/**"
  - "Pine/QuickTerminal/**"
  - "PineTests/Terminal*"
  - "PineUITests/Terminal*"
---

# Terminal, renderer, and quick terminal

- **Quick terminal:** a system-wide ⌃⌥Space hotkey (`Carbon RegisterEventHotKey`, no Accessibility permission required, works in the App Sandbox) toggles a floating drop-down terminal over any application (#1113). The session is keep-alive — scrollback survives toggles; Esc and ⌘W hide it. The working directory resolves to an open Pine project (current implementation picks `openProjects.keys.first` — Dictionary order, not the key window; key-window resolution is a follow-up), else the most-recent project, else `$HOME`. Disable with `--disable-quick-terminal` or `PINE_DISABLE_QUICK_TERMINAL` (used by UI tests). Agent detection (#950) does NOT cover the quick-terminal tab (it lives outside the pane tree) — a follow-up wires it in. A menu item, Settings UI (custom hotkey, screen edge, height), and per-pane quick terminals are follow-ups — v1 ships the hotkey + window only.

- **Known issue:** Pine's terminal opts into SwiftTerm's Metal renderer (`setUseMetal(true)`) once the view lands in a window, replacing the layer-backed CoreGraphics raster with a GPU swapchain and eliminating the entire black-screen class (#64, #661, #871, #918, #923, #966, #1094, #1108). On failure (headless CI VM, old GPU, virtual display without a Metal device) it silently falls back to CoreGraphics. UI tests pass `--disable-metal` to pin CoreGraphics on macOS-26 virtual displays; production users can opt out with `--disable-metal` or `PINE_DISABLE_METAL`.

- **Terminal rendering compatibility:** manually reproduce rendering bugs once through the default path (Metal when available; record any fallback-to-CoreGraphics log) and once after relaunching with `--disable-metal` or `PINE_DISABLE_METAL=1` to force CoreGraphics. Record the effective renderer, Mac model/chip, display configuration, and whether the result differs on macOS 26 versus the current macOS 27 beta
