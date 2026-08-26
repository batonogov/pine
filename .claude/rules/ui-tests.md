---
paths:
  - "PineUITests/**/*.swift"
---

# XCUITest limitations and launch configuration

Every "known issue" below has already cost someone a debugging session.

## Targets and shards

- UI test target: `PineUITests` (XCTest/XCUITest) — 41 test classes across 42 files, base class `PineUITestCase`. CI runs 7 parallel shards (Terminal, Welcome & Session, Navigation, Editor Chrome, Files & Save, Search & Panes, Security & Layout)

## Launch arguments and environment

- Launch arguments for UI testing: `--reset-state` (clears persisted sessions), `--disable-agent-detection` (disables the `ps`-polling agent detector — avoids the macOS-26 fork/spawn hang #1060), `--disable-metal` (pins the terminal to SwiftTerm's CoreGraphics renderer — Metal may be unavailable on CI virtual displays #1108), `--disable-quick-terminal` (disables the global ⌃⌥Space hotkey so it does not grab key events on CI #1113), `-ApplePersistenceIgnoreState YES` (ignores macOS saved window state), `-AppleLanguages (en)`, `-AppleLocale en_US` (force English locale so menu item names are predictable)
- Environment variable for UI testing: `PINE_OPEN_PROJECT=<path>` (opens project without file dialog — uses env var because macOS interprets bare paths in launch arguments as files to open)
- **Known issue:** XCUITest launch arguments (`-key YES`) store values as strings in NSArgumentDomain. `UserDefaults.object(forKey:) as? Bool` returns nil for strings. To set boolean UserDefaults for UI tests, use `defaults write <bundle-id> <key> -bool YES` via `Process` in setUp, and `defaults delete` in tearDown

## What XCUITest cannot do

- **Known issue:** On macOS 26, `XCUIApplication.launch()` bypasses LaunchServices, so SwiftUI `.defaultLaunchBehavior(.presented)` does not create windows. The app includes an AppKit fallback (`createWelcomeWindowViaAppKit`) that activates after 0.5s if no windows appear.
- **Known issue:** `GutterTextView` (NSTextView inside NSViewRepresentable) does not receive keyboard input from XCUITest's `typeText()`/`typeKey()`. UI tests that need to verify editor content changes should use alternative approaches (e.g., verifying menu item availability, checking tab state).
- **Known issue:** XCUITest's `typeKey()` bypasses the app's `NSEvent.addLocalMonitorForEvents` — synthetic key events go through Accessibility APIs, not the app's event queue. Keyboard shortcuts handled via local event monitors (e.g., Cmd+W for tab closing, Cmd+Shift+B for branch switcher) cannot be reliably UI-tested with `typeKey()`. Use mouse clicks on UI elements instead.
- **Known issue:** UI tests that use `Process()` to run shell commands (e.g., `git init`) need `DEVELOPER_DIR` set in the process environment, otherwise `xcrun` fails with "cannot be used within an App Sandbox".

## Driving the UI

- To interact with menu items in UI tests, use `app.menuBars.menuBarItems["File"].click()` then `app.menuItems["Item Name"].click()` with English names (locale is forced to `en`)
- Accessibility identifiers defined in `Pine/AccessibilityIdentifiers.swift` — used by both app views and UI tests
