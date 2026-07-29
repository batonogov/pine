//
//  GlobalTabSwitcherKeyController.swift
//  Pine
//
//  Window-owned keyboard lifecycle for the visual MRU switcher.
//

import AppKit

/// A single, atomically-resolved switcher target. Keeping the window and pane
/// manager together prevents a key-window change between two delegate reads
/// from pairing the wrong window with a project.
@MainActor
struct GlobalTabSwitcherTarget {
    let window: NSWindow
    let paneManager: PaneManager
}

@MainActor
protocol GlobalTabSwitcherKeyControllerDelegate: AnyObject {
    var globalTabSwitcherTarget: GlobalTabSwitcherTarget? { get }
}

/// Drives one Control-Tab gesture from its first key-down through release.
///
/// Key-down remains in AppDelegate's single precedence-ordered local monitor:
/// user keybindings must get first refusal. This controller installs the
/// companion flags-changed monitor plus lifecycle observers, then pins the
/// gesture to the project window that started it.
@MainActor
final class GlobalTabSwitcherKeyController {
    weak var delegate: GlobalTabSwitcherKeyControllerDelegate?

    private let notificationCenter: NotificationCenter
    private let observesSystemEvents: Bool
    private weak var ownerWindow: NSWindow?
    private weak var ownerPaneManager: PaneManager?
    private var isInstalled = false

    // Monitor/observer tokens are only marked unsafe for nonisolated deinit.
    // All installation and callbacks happen on the main thread.
    nonisolated(unsafe) private var flagsChangedMonitor: Any?
    nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = .default,
        observesSystemEvents: Bool = true
    ) {
        self.notificationCenter = notificationCenter
        self.observesSystemEvents = observesSystemEvents
    }

    deinit {
        if let flagsChangedMonitor {
            NSEvent.removeMonitor(flagsChangedMonitor)
        }
        for observer in lifecycleObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    /// Installs the release monitor and cancellation observers once.
    func install() {
        guard !isInstalled else { return }
        isInstalled = true

        if observesSystemEvents {
            flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.flagsChanged]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    _ = self?.handleModifierFlagsChanged(event.modifierFlags)
                }
                return event
            }
        }

        let applicationObserver = notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.discardOwnedSession()
            }
        }
        lifecycleObservers.append(applicationObserver)

        for name in [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification
        ] {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // Extract only a Sendable identity before entering the main
                // actor; moving Notification itself across the boundary is a
                // Swift 6 data-race error.
                let windowIdentifier = (notification.object as? NSWindow)
                    .map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    self?.discardIfOwnerWindow(
                        identifiedBy: windowIdentifier
                    )
                }
            }
            lifecycleObservers.append(observer)
        }
    }

    /// Handles Control-Tab and Escape after user keybindings decline the
    /// event. Returns `true` only when the visual switcher consumed it.
    func handleKeyDownEvent(_ event: NSEvent) -> Bool {
        guard isInstalled else { return false }

        if event.keyCode == UInt16(KeyboardShortcutMatcher.PhysicalKey.tab) {
            let modifiers = KeyboardShortcutMatcher.normalizedModifiers(
                event.modifierFlags
            )
            if modifiers == .control {
                return handleControlTab(reverse: false)
            }
            if modifiers == [.control, .shift] {
                return handleControlTab(reverse: true)
            }
            return false
        }

        // Escape is consumed only for the gesture's pinned owner.
        guard event.keyCode == 53,
              ownerPaneManager?.isGlobalTabSwitcherActive == true else {
            return false
        }
        cancelOwnedSession()
        return true
    }

    /// Testable semantic entry point for a forward/reverse Control-Tab press.
    @discardableResult
    func handleControlTab(reverse: Bool) -> Bool {
        guard isInstalled else { return false }
        guard let target = delegate?.globalTabSwitcherTarget else {
            // If focus left every project window before its lifecycle
            // notification reached us, never leave an invisible owner armed.
            discardOwnedSession()
            return false
        }

        if let ownerPaneManager {
            // A gesture never migrates between project windows. Discard the
            // old owner's preview without sending focus back into its outgoing
            // window, then allow the new key window to start its own session.
            if ownerWindow !== target.window
                || ownerPaneManager !== target.paneManager {
                discardOwnedSession()
            } else if ownerPaneManager.isGlobalTabSwitcherActive {
                ownerPaneManager.advanceGlobalTabSwitcher(
                    offset: reverse ? -1 : 1
                )
                return true
            } else {
                clearOwner()
            }
        }

        guard target.paneManager.beginGlobalTabSwitcherSession(
            initialOffset: reverse ? -1 : 1
        ) else {
            return false
        }
        ownerWindow = target.window
        ownerPaneManager = target.paneManager
        return true
    }

    /// Commits the pinned owner's selection when Control is released.
    @discardableResult
    func handleModifierFlagsChanged(
        _ modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard ownerPaneManager?.isGlobalTabSwitcherActive == true else {
            clearOwner()
            return false
        }
        guard ownerWindow != nil else {
            // A weak owner can disappear before a delayed lifecycle
            // notification is delivered. Never commit focus into a window
            // that no longer exists.
            discardOwnedSession()
            return false
        }
        guard !modifierFlags.contains(.control) else { return false }
        commitOwnedSession()
        return true
    }

    func cancelOwnedSession() {
        let owner = ownerPaneManager
        clearOwner()
        owner?.cancelGlobalTabSwitcher()
    }

    private func discardOwnedSession() {
        let owner = ownerPaneManager
        clearOwner()
        owner?.discardGlobalTabSwitcherSession()
    }

    private func commitOwnedSession() {
        let owner = ownerPaneManager
        clearOwner()
        owner?.commitGlobalTabSwitcher()
    }

    private func discardIfOwnerWindow(
        identifiedBy windowIdentifier: ObjectIdentifier?
    ) {
        guard let ownerWindow,
              let windowIdentifier,
              ObjectIdentifier(ownerWindow) == windowIdentifier else {
            return
        }
        discardOwnedSession()
    }

    private func clearOwner() {
        ownerWindow = nil
        ownerPaneManager = nil
    }
}
