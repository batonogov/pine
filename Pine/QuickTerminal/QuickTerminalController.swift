//
//  QuickTerminalController.swift
//  Pine
//
//  Owns the single global quick-terminal session: a keep-alive
//  `QuickTerminalWindow` hosting one `TerminalTab` inside a
//  `TerminalContainerView`. Toggled by a system-wide hotkey (#1113).
//
//  The session reuses the in-window terminal stack (`TerminalPaneState` +
//  `TerminalTab` + `TerminalContainerView`), so agent detection (#950),
//  file:line links (#949), and search (#308) work identically.
//

import AppKit
import SwiftUI

/// Drop-down geometry: the panel fills the screen width and covers this
/// fraction of the screen height, anchored to the top edge (iTerm2 /
/// Quake-style).
private enum QuickTerminalLayout {
    static let heightFraction: CGFloat = 0.4
}

@MainActor
@Observable
final class QuickTerminalController {
    /// Per-pane state reused as the quick terminal's tab container. Holds
    /// exactly one `TerminalTab` for the quick-terminal session.
    let paneState = TerminalPaneState()

    /// `true` while the quick-terminal window is on screen.
    private(set) var isVisible = false

    /// Project registry used to resolve the working directory (frontmost
    /// open project → recent project → home). Weakly held; the registry
    /// outlives the coordinator (owned by AppDelegate).
    weak var registry: ProjectRegistry?

    private var window: QuickTerminalWindow?

    // MARK: - Public

    /// Shows the quick terminal if hidden, hides it if visible. Bound to the
    /// global hotkey and the menu command.
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        ensureWindow()
        repositionDropDown()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    /// Stops the terminal session and closes the window. Called at app
    /// termination so the PTY child does not outlive Pine, matching
    /// `registry.destroyAllProjects()` for project windows (#1113 review).
    func shutdown() {
        for tab in paneState.terminalTabs { tab.stop() }
        window?.close()
        window = nil
        isVisible = false
    }

    // MARK: - Window lifecycle

    /// Lazily creates the keep-alive window and its terminal session. Called
    /// on the first `show()`; subsequent shows reuse the same window + shell
    /// (scrollback survives between toggles).
    private func ensureWindow() {
        guard window == nil else { return }

        // Seed the terminal tab if this is the first show. The tab starts its
        // PTY lazily from `TerminalContainerView.layout()` once the view has
        // real bounds (issue #661 guard).
        if paneState.terminalTabs.isEmpty {
            paneState.addTab(workingDirectory: resolveCwd())
        }

        let rect = dropDownRect()
        let win = QuickTerminalWindow(contentRect: rect)
        win.onHide = { [weak self] in self?.hide() }

        // Host the same NSView the in-window terminal panes use. Setting it
        // as contentView triggers `viewDidMoveToWindow` → observer install +
        // `layout()` → `showTab(activeTab)` → `startIfNeeded()`.
        let container = TerminalContainerView(frame: rect)
        container.terminalPaneState = paneState
        win.contentView = container
        // Explicit `showTab` matches the in-window pattern
        // (`TerminalContentView.updateNSView`) and makes the PTY-spawn path
        // robust against future changes to `TerminalContainerView.layout()`'s
        // contract — `layout()`'s else-branch already calls `showTab`, but
        // only when the container has real bounds on that specific pass.
        container.showTab(paneState.activeTab)

        window = win
    }

    /// Recomputes the drop-down frame against the current screen so the
    /// panel tracks display changes (retina ↔ external, resolution change).
    private func repositionDropDown() {
        guard let window else { return }
        window.setFrame(dropDownRect(), display: true)
    }

    /// Full screen width, `heightFraction` of the screen height, top-anchored.
    private func dropDownRect() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 600)
        let height = (screenFrame.height * QuickTerminalLayout.heightFraction).rounded()
        return NSRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - height,
            width: screenFrame.width,
            height: height
        )
    }

    /// Working directory for the quick terminal: the root of the frontmost
    /// open Pine project, else the most-recent project, else `$HOME`.
    private func resolveCwd() -> URL? {
        if let frontmost = registry?.openProjects.keys.first {
            return frontmost
        }
        if let recent = registry?.recentProjects.first {
            return recent
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}
