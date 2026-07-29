//
//  NativeMenuCommandState.swift
//  Pine
//
//  Shared state and shortcut projection for native File / Window commands.
//

import AppKit
import SwiftUI

/// Breaks synchronous NotificationCenter / SwiftUI ButtonAction delivery
/// before a native command mutates observable application state.
///
/// Kept as a small production seam so regression tests can pin that the
/// mutation is deferred to the next main-queue turn.
@MainActor
enum NativeCommandDelivery {
    static func deferToNextMainRunLoop(
        _ operation: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                operation()
            }
        }
    }
}

/// The exact active tab a native Close Tab command is allowed to target.
///
/// Capturing both pane and tab identity prevents an asynchronous dirty-file
/// or foreground-process decision from drifting to a newly focused tab.
nonisolated enum NativeTabCloseTarget: Equatable, Sendable {
    case editor(paneID: PaneID, tabID: UUID)
    case terminal(paneID: PaneID, tabID: UUID)
}

/// Minimal, AppKit-free projection used to resolve a native command's owning
/// project window. Keeping the identity rule pure makes multi-window routing
/// testable without mutating `NSApplication.shared.windows`.
struct NativeCommandRoutingCandidate {
    let projectManager: ProjectManager
    let isKeyWindow: Bool
    /// Closed/background windows may still be present in `NSApp.windows`
    /// while their project model is intentionally retained. They must never
    /// receive a newly delivered native command.
    let isEligibleWindow: Bool

    init(
        projectManager: ProjectManager,
        isKeyWindow: Bool,
        isEligibleWindow: Bool = true
    ) {
        self.projectManager = projectManager
        self.isKeyWindow = isKeyWindow
        self.isEligibleWindow = isEligibleWindow
    }
}

enum NativeCommandRouting {
    /// A targeted notification stays with its originating project even if
    /// another project becomes key before delivery. Untargeted commands are
    /// accepted only by the current key project window.
    static func destinationIndex(
        requestedProject: ProjectManager?,
        candidates: [NativeCommandRoutingCandidate]
    ) -> Int? {
        if let requestedProject {
            return candidates.firstIndex {
                $0.projectManager === requestedProject
                    && $0.isEligibleWindow
                    && $0.isKeyWindow
            } ?? candidates.firstIndex {
                $0.projectManager === requestedProject
                    && $0.isEligibleWindow
            }
        }
        return candidates.firstIndex {
            $0.isEligibleWindow && $0.isKeyWindow
        }
    }
}

/// Truthful, focus-sensitive enablement for native File / Window commands.
///
/// `ProjectManager.activeTabManager` intentionally falls back to an editor
/// manager while a terminal pane has focus. Native menus must not use that
/// fallback: Save, Duplicate, and Close Tab act on the focused pane only.
struct NativeMenuCommandState: Equatable {
    let activeEditorTabID: UUID?
    let closeTarget: NativeTabCloseTarget?
    let canSave: Bool
    let canSaveAll: Bool
    let canSaveAs: Bool
    let canDuplicate: Bool
    let canCloseTab: Bool
    let canCloseWindow: Bool

    @MainActor
    init(projectManager: ProjectManager?) {
        guard let projectManager else {
            activeEditorTabID = nil
            closeTarget = nil
            canSave = false
            canSaveAll = false
            canSaveAs = false
            canDuplicate = false
            canCloseTab = false
            canCloseWindow = false
            return
        }

        let paneManager = projectManager.paneManager
        let activePaneID = paneManager.activePaneID
        let focusedContent = paneManager.root.content(for: activePaneID)
        let focusedEditorTab = focusedContent == .editor
            ? paneManager.tabManager(for: activePaneID)?.activeTab
            : nil

        activeEditorTabID = focusedEditorTab?.id
        canSave = focusedEditorTab?.kind == .text
            && focusedEditorTab?.isTruncated == false
        canSaveAs = canSave
        canDuplicate = canSave && focusedEditorTab?.fileURL != nil
        let dirtyTabs = projectManager.allDirtyTabs
        canSaveAll = !dirtyTabs.isEmpty && dirtyTabs.allSatisfy {
            $0.kind == .text && !$0.isTruncated
        }
        let hasProjectWindow = projectManager.workspace.rootURL != nil
        canCloseWindow = hasProjectWindow

        switch focusedContent {
        case .editor:
            if let focusedEditorTab, !focusedEditorTab.isPinned {
                closeTarget = .editor(
                    paneID: activePaneID,
                    tabID: focusedEditorTab.id
                )
            } else {
                closeTarget = nil
            }
        case .terminal:
            if let terminalTab = paneManager
                .terminalState(for: activePaneID)?
                .activeTab {
                closeTarget = .terminal(
                    paneID: activePaneID,
                    tabID: terminalTab.id
                )
            } else {
                closeTarget = nil
            }
        case nil:
            closeTarget = nil
        }
        canCloseTab = hasProjectWindow && closeTarget != nil
    }
}

/// SwiftUI representation of a parsed user keybinding.
nonisolated struct MenuKeyboardShortcut {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    init?(_ chord: ParsedKeyChord?) {
        guard let chord,
              let key = Self.keyEquivalent(for: chord.key) else {
            return nil
        }
        self.key = key
        var modifiers: EventModifiers = []
        if chord.modifiers.contains(.command) {
            modifiers.insert(.command)
        }
        if chord.modifiers.contains(.control) {
            modifiers.insert(.control)
        }
        if chord.modifiers.contains(.option) {
            modifiers.insert(.option)
        }
        if chord.modifiers.contains(.shift) {
            modifiers.insert(.shift)
        }
        self.modifiers = modifiers
    }

    private static func keyEquivalent(for token: String) -> KeyEquivalent? {
        switch token {
        case "return": return .return
        case "tab": return .tab
        case "delete": return .delete
        case "esc": return .escape
        case "space": return .space
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        default:
            guard token.count == 1, let character = token.first else {
                return nil
            }
            return KeyEquivalent(character)
        }
    }
}

extension View {
    /// Installs only the effective shortcut. Passing `nil` deliberately leaves
    /// the item without a key equivalent, which suppresses a shadowed or
    /// rebound built-in chord in the visible menu as well as in dispatch.
    @ViewBuilder
    func effectiveKeyboardShortcut(
        _ chord: ParsedKeyChord?
    ) -> some View {
        if let shortcut = MenuKeyboardShortcut(chord) {
            keyboardShortcut(
                shortcut.key,
                modifiers: shortcut.modifiers
            )
        } else {
            self
        }
    }
}
