# Accessibility and Localization Release Check

Run this short manual pass for release candidates after the automated unit and
`A11y & Localization` UI matrix is green. The matrix distributes all nine
supported locales across four focused jobs, exercises a keyboard-only critical
journey, and retains double-length/representative layout screenshots plus AX
trees. Record the exact macOS and Xcode/SDK versions described in `AGENTS.md`,
plus the language, appearance, and accessibility settings used.

## Representative configurations

- English, light appearance, default accessibility settings.
- German, dark appearance, Reduce Motion enabled.
- Japanese, light appearance, Differentiate Without Color enabled.
- Russian, dark appearance, both settings enabled.
- One pass with Xcode's Double Length Pseudolanguage.

## VoiceOver and layout

1. On Welcome, verify the Open Folder and Agent Inbox buttons have localized
   names, expose the button role, and are reachable in a sensible order.
2. In a project window, open each Settings pane and check long labels, rows,
   buttons, and sliders for clipping. Confirm controls announce their current
   value and enabled state.
3. Create a terminal and verify New Tab, maximize/restore, close, and terminal
   tabs expose localized names and their default action. Start an agent in a
   terminal and confirm both the tab and the terminal itself announce the
   agent and its state, not just the tab's name.
4. Open Quick Open, Symbol Navigator, Command Palette, and Agent Inbox. Check
   the search field, selected result, empty state, and actionable rows. On an
   Inbox row, confirm the rotor offers Mark as Read / Mark as Unread and that
   it names the direction that row is going.
5. Split a pane. Confirm the divider announces as a splitter with its current
   position, that the VoiceOver adjust gesture moves it, and — with Full
   Keyboard Access on — that Tab reaches it and the arrow keys along the
   split's axis move it.
6. Go to a symbol with more than one definition. Confirm the quick pick can be
   navigated and chosen entirely from the keyboard, and that each row
   announces both the symbol and its location.
7. Read the status bar end to end. Each git count must name what it counts, and
   nothing may announce a bare number or an interpunct separator.
8. Trigger unsaved-changes, application-Quit, and update surfaces. Check the
   title, explanation, default button, cancel path, and keyboard focus order.
9. Repeat the visual pass in light and dark appearance. With Differentiate
   Without Color enabled, confirm status and selection do not rely on color
   alone; with Reduce Motion enabled, confirm transitions are immediate.

## Physical-keyboard journey

Repeat the automated keyboard-only path on physical hardware: open a file,
create a second tab, switch tabs and panes, save, create/focus a terminal,
operate its controls, and open Agent Inbox. This remains a short manual check
because macOS XCUITest accessibility events bypass Pine's local `NSEvent`
monitors for several production shortcuts.

Fail the release check for raw localization keys, unexpected English fallback,
empty required labels, clipped controls, missing actions, or focus traps.
