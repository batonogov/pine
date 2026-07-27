//
//  GlobalTabSwitcherKeyController.swift
//  Pine
//
//  Keyboard controller for the visual MRU tab switcher (issue #1239).
//
//  Owns the three NSEvent monitors that drive the Control-Tab overlay session:
//    1. key-down (Control-Tab)         → begin or advance the session
//    2. flags-changed (Control release) → commit the highlighted selection
//    3. key-down (Escape)              → cancel and restore the original tab
//
//  The MRU model itself lives on `PaneManager`; this controller only orchestrates
//  session begin / advance / commit / cancel in response to physical key events.
//  It resolves the key window's `ProjectManager` (via its `CloseDelegate`) so
//  the overlay targets the project the user is actually looking at.
//
//  Why a dedicated monitor (instead of folding into the existing key-down
//  handler): Control-release detection needs `flagsChanged`, which the existing
//  single key-down monitor does not watch. Keeping the lifecycle in one object
//  also makes it unit-testable via injected closures.
//

import AppKit

/// Resolves the `PaneManager` for the current key window, plus a way to drive
/// the session directly. Abstracted so the controller is testable without a
/// live `NSWindow` / `CloseDelegate`.
@MainActor
protocol GlobalTabSwitcherKeyControllerDelegate: AnyObject {
    /// The pane manager whose session should be driven, or `nil` when no
    /// eligible project window is key.
    var paneManagerForTabSwitcher: PaneManager? { get }
}

/// Owns the NSEvent monitors that drive the Control-Tab overlay.
///
/// Installed once at app launch (`install()`) and torn down on `deinit`. All
/// real work is dispatched to the resolved `PaneManager` so this class holds no
/// state of its own beyond the monitor tokens.
@MainActor
final class GlobalTabSwitcherKeyController {
    weak var delegate: GlobalTabSwitcherKeyControllerDelegate?

    // Monitor tokens. `nonisolated(unsafe)` only so `deinit` (which is
    // nonisolated even on a @MainActor class) can remove them; every real
    // read/write happens on the main thread inside the monitor closures.
    nonisolated(unsafe) private var keyDownMonitor: Any?
    nonisolated(unsafe) private var flagsChangedMonitor: Any?

    /// Whether the monitors are currently installed. Used to make `install()`
    /// idempotent and to guard `deinit`.
    private var isInstalled = false

    deinit {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        if let flagsChangedMonitor {
            NSEvent.removeMonitor(flagsChangedMonitor)
        }
    }

    /// Installs the key-down and flags-changed monitors. Idempotent.
    func install() {
        guard !isInstalled else { return }
        isInstalled = true

        // Key-down: Control-Tab begins/advances; Escape cancels. We watch
        // .keyDown broadly and filter inside, so a single monitor owns both.
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }

        // Flags-changed: commit when Control is released. This is the canonical
        // macOS Cmd-Tab / Control-Tab "release to switch" gesture.
        flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event) ?? event
        }
    }

    // MARK: - Event handling

    /// Physical key code for Tab (layout-independent).
    private static let tabKeyCode: UInt16 = 48
    /// Physical key code for Escape.
    private static let escapeKeyCode: UInt16 = 53

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let paneManager = delegate?.paneManagerForTabSwitcher else {
            return event
        }

        // Escape cancels an active session (and otherwise falls through).
        if event.keyCode == Self.escapeKeyCode, paneManager.isGlobalTabSwitcherActive {
            paneManager.cancelGlobalTabSwitcher()
            return nil
        }

        // Control-Tab (forward) and Shift-Control-Tab (reverse).
        guard event.keyCode == Self.tabKeyCode else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isControl = modifiers.contains(.control)
        guard isControl else { return event }
        let reverse = modifiers.contains(.shift)

        if paneManager.isGlobalTabSwitcherActive {
            // Subsequent press while held: cycle without moving real focus.
            paneManager.advanceGlobalTabSwitcher(offset: reverse ? -1 : 1)
        } else {
            // First press: open the overlay, then advance once so the very
            // first Control-Tab surfaces the second-most-recent tab (the most
            // recent is the one the user is already on).
            if paneManager.beginGlobalTabSwitcherSession() {
                paneManager.advanceGlobalTabSwitcher(offset: reverse ? -1 : 1)
            }
        }
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        guard let paneManager = delegate?.paneManagerForTabSwitcher,
              paneManager.isGlobalTabSwitcherActive else {
            return event
        }
        // Commit when Control is no longer held. Checking
        // `event.modifierFlags.contains(.control)` is the reliable signal that
        // the Control key has just been released (the event reports the
        // *new* modifier state).
        if !event.modifierFlags.contains(.control) {
            paneManager.commitGlobalTabSwitcher()
        }
        return event
    }
}
