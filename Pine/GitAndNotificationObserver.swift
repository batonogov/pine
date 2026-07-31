//
//  GitAndNotificationObserver.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

// MARK: - Blame observer

/// Refreshes blame when visibility changes.
struct BlameObserver: ViewModifier {
    let isBlameVisible: Bool
    let onRefresh: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isBlameVisible) { _, _ in onRefresh() }
    }
}

// MARK: - Terminal session state observer

// Terminal session state is now tracked per-pane (TerminalPaneState).
// The old TerminalSessionObserver has been removed.

// MARK: - Git and notification observer

/// Extracted to reduce body complexity for the type-checker.
/// Handles git status changes, file notifications, and menu command notifications.
struct GitAndNotificationObserver: ViewModifier {
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(ProjectManager.self) private var projectManager
    @Environment(\.controlActiveState) private var controlActiveState
    @Binding var lineDiffs: [GitLineDiff]
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var isSearchPresented: Bool
    /// Invoked when the Go to Line command is triggered. The presenter routes
    /// this through the shared command-overlay router (#975).
    var onPresentGoToLine: () -> Void
    var onRefreshLineDiffs: () -> Void
    var onRefreshBlame: () -> Void
    var onOpenNewProject: () -> Void
    var onHandleFileDeletion: (URL) -> Void
    var onHandleExternalChanges: (TabManager.ExternalChangeResult) -> Void
    var onNavigateToChange: (ContentView.ChangeDirection) -> Void
    var onInlineDiffAction: (InlineDiffAction) -> Void

    /// Resolves the focused editor pane's TabManager via `ProjectManager`,
    /// avoiding the primary-vs-active conflation that issue #998 describes.
    /// All command/notification handlers below target this instance, never
    /// the primary TabManager.
    private var activeTabManager: TabManager { projectManager.activeTabManager }

    func body(content: Content) -> some View {
        let contentWithFileObservers = content
            .onChange(of: workspace.gitProvider.isGitRepository) { _, isRepo in
                if isRepo {
                    onRefreshLineDiffs()
                } else {
                    lineDiffs = []
                }
            }
            .onChange(of: workspace.gitProvider.currentBranch) { _, _ in
                onRefreshLineDiffs()
                onRefreshBlame()
            }
            .onChange(of: workspace.gitProvider.fileStatuses) { _, _ in
                onRefreshLineDiffs()
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshLineDiffs)) { _ in
                guard controlActiveState == .key else { return }
                onRefreshLineDiffs()
                onRefreshBlame()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { notification in
                guard ContentView.shouldHandleTargetedCommand(
                    notificationObject: notification.object,
                    currentProject: projectManager,
                    isKeyWindow: controlActiveState == .key
                ) else { return }
                // A mouse click in the native File menu can temporarily make
                // SwiftUI report the project window as non-key while AppKit is
                // still tracking that menu. The targeted project identity
                // above preserves ownership; deferring presentation lets menu
                // tracking unwind before NSOpenPanel attaches its sheet.
                NativeCommandDelivery.deferToNextMainRunLoop {
                    onOpenNewProject()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .fileRenamed)) { notification in
                handleFileRenamed(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .fileDeleted)) { notification in
                guard let deletedURL = notification.userInfo?["url"] as? URL else { return }
                handleFileDeleted(deletedURL)
            }

        return contentWithFileObservers
            .onChange(of: workspace.externalChangeToken) { _, _ in
                // Issue #838: never gate the FSEvents path on focus. The
                // previous `controlActiveState == .key` guard meant that
                // edits made in `nano`/`vim` while Pine was inactive were
                // forever invisible — by the time the user came back the
                // token had already incremented (no further .onChange) and
                // the activation re-check below could miss the .inactive
                // → .active transition entirely. `checkExternalChanges()`
                // is cheap (one `stat()` per open tab) and silent when no
                // tab changed, so it is safe to run unconditionally.
                let result = projectManager.checkExternalChanges()
                onHandleExternalChanges(result)
            }
            .onChange(of: controlActiveState) { _, newState in
                // When the window comes back into focus, re-check for
                // external changes. Loosened from `== .key` to
                // `!= .inactive` so transitions through `.active` are
                // also caught (multi-window setups, app switcher, menu
                // bar interactions on macOS 26 with Liquid Glass) —
                // see issue #838.
                guard newState != .inactive else { return }
                let result = projectManager.checkExternalChanges()
                onHandleExternalChanges(result)
            }
            // Defense in depth: AppKit's `didBecomeActive` is the
            // authoritative source for app-level activation on macOS and
            // is not subject to SwiftUI environment-value lag. This
            // catches the "Pine was inactive when the file changed, then
            // Pine becomes active" path even when the SwiftUI
            // controlActiveState transition is delivered late or skipped.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )) { _ in
                let result = projectManager.checkExternalChanges()
                onHandleExternalChanges(result)
            }
            // …and per-window key changes. Some app-switcher paths only
            // fire window-level activation, not application-level.
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didBecomeKeyNotification
            )) { _ in
                let result = projectManager.checkExternalChanges()
                onHandleExternalChanges(result)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showProjectSearch)) { notification in
                guard ContentView.shouldHandleTargetedCommand(
                    notificationObject: notification.object,
                    currentProject: projectManager,
                    isKeyWindow: controlActiveState == .key
                ) else { return }
                handleShowProjectSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .goToLine)) { notification in
                handleGoToLine(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFileAtLine)) { notification in
                handleOpenFileAtLine(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateChange)) { notification in
                handleNavigateChange(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .inlineDiffAction)) { notification in
                handleInlineDiffAction(notification)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .agentHandoffSettingsChanged
            )) { _ in
                // Settings notifications are synchronous. Defer observable
                // reads and the project refresh until the toggle action has
                // unwound, matching the reentrancy-safe handlers below.
                DispatchQueue.main.async {
                    projectManager.synchronizeAgentHandoff()
                }
            }
    }

    // MARK: - Notification handlers (deferred to break reentrancy, #1051)
    //
    // Each handler that mutates @Binding / @State / @Observable state wraps
    // the mutation in `DispatchQueue.main.async { ... }`. A menu command
    // posts the notification synchronously inside the `ButtonAction`
    // callstack, which holds exclusive access to SwiftUI storage; mutating
    // observable state from the `.onReceive` closure synchronously forces a
    // re-evaluation that collides with that access and triggers
    // `_swift_reportExclusivityConflict` → `abort()` (issue #1051).
    //
    // Deferring lets the button-action callstack unwind first; the mutation
    // then runs on the next runloop with no overlap — same pattern as the
    // `reportStateChange` fix in #1047, applied to the SwiftUI side.
    //
    // The handlers are extracted into named methods (rather than inline
    // closures) so the `body` type-checker stays fast and so the defer
    // contract is directly unit-testable without a live SwiftUI view.

    func handleFileRenamed(_ notification: Notification) {
        guard let oldURL = notification.userInfo?["oldURL"] as? URL,
              let newURL = notification.userInfo?["newURL"] as? URL else { return }
        DispatchQueue.main.async {
            // Route through ProjectManager so the rename is reflected in
            // every pane (the same file can be open in multiple panes),
            // not just the primary TabManager.
            self.projectManager.handleFileRenamed(oldURL: oldURL, newURL: newURL)
            self.projectManager.saveSession()
        }
    }

    func handleFileDeleted(_ deletedURL: URL) {
        DispatchQueue.main.async {
            self.onHandleFileDeletion(deletedURL)
        }
    }

    func handleShowProjectSearch() {
        // Prime suspect for the Cmd+Shift+F crash: mutates two pieces of
        // state (columnVisibility @Binding + isSearchPresented @Binding)
        // and wraps one in withAnimation, maximising synchronous re-render.
        DispatchQueue.main.async {
            withAnimation(PineAnimation.quick) {
                self.columnVisibility = .all
            }
            self.isSearchPresented = true
        }
    }

    func handleGoToLine(_ notification: Notification) {
        guard ContentView.shouldHandleTargetedCommand(
            notificationObject: notification.object,
            currentProject: projectManager,
            isKeyWindow: controlActiveState == .key
        ),
              activeTabManager.activeTab != nil else { return }
        DispatchQueue.main.async {
            self.onPresentGoToLine()
        }
    }

    func handleOpenFileAtLine(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL,
              let line = notification.userInfo?["line"] as? Int else { return }
        DispatchQueue.main.async {
            // Column is parsed and passed for future use; the current
            // navigation infrastructure is line-based (issue #949).
            // Open into the focused pane so terminal ⌘-click and search
            // results land in the editor the user is looking at (#971).
            self.activeTabManager.openTabAndGoToLine(url: url, line: line)
        }
    }

    /// Kept out of the modifier closure so Xcode 27's SwiftUI type-checker
    /// does not have to solve payload parsing inside the long modifier chain
    /// (issue #1133).
    func handleNavigateChange(_ notification: Notification) {
        guard ContentView.shouldHandleTargetedCommand(
            notificationObject: notification.object,
            currentProject: projectManager,
            isKeyWindow: controlActiveState == .key
        ) else { return }
        guard let direction = Self.resolveChangeDirection(
            from: notification,
            isKeyWindow: true
        ) else { return }
        onNavigateToChange(direction)
    }

    /// Mirrors `handleNavigateChange` for the adjacent inline-diff command.
    /// Leaving this payload cast inline merely moved Xcode 27's type-checking
    /// failure to the next modifier (issue #1133).
    func handleInlineDiffAction(_ notification: Notification) {
        guard ContentView.shouldHandleTargetedCommand(
            notificationObject: notification.object,
            currentProject: projectManager,
            isKeyWindow: controlActiveState == .key
        ) else { return }
        guard let action = Self.resolveInlineDiffAction(
            from: notification,
            isKeyWindow: true
        ) else { return }
        onInlineDiffAction(action)
    }

    /// Pure resolver used by the notification handler and its regression
    /// tests. Any string other than `"next"` intentionally maps to
    /// `.previous`, preserving the command's pre-#1133 behavior.
    static func resolveChangeDirection(
        from notification: Notification,
        isKeyWindow: Bool
    ) -> ContentView.ChangeDirection? {
        guard isKeyWindow,
              let direction = notification.userInfo?["direction"] as? String else { return nil }
        return direction == "next" ? .next : .previous
    }

    /// Pure resolver for inline-diff notifications. The payload must contain
    /// an `InlineDiffAction` value; raw strings are deliberately not decoded.
    static func resolveInlineDiffAction(
        from notification: Notification,
        isKeyWindow: Bool
    ) -> InlineDiffAction? {
        guard isKeyWindow,
              let action = notification.userInfo?["action"] as? InlineDiffAction else { return nil }
        return action
    }
}

// MARK: - Window document-edited dot tracker

/// Sets `NSWindow.isDocumentEdited` based on whether any tab has unsaved changes.
/// This shows/hides the dot in the window's close button (standard macOS behavior).
struct DocumentEditedTracker: NSViewRepresentable {
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isDocumentEdited = isEdited
    }
}

// MARK: - Project search modifier

/// Extracted modifier to reduce body complexity for the type-checker.
struct ProjectSearchModifier: ViewModifier {
    var projectManager: ProjectManager
    @Binding var isSearchPresented: Bool

    func body(content: Content) -> some View {
        content
            .searchable(
                text: Bindable(projectManager.searchProvider).query,
                isPresented: $isSearchPresented,
                placement: .toolbar,
                prompt: Strings.searchPlaceholder
            )
            .onChange(of: projectManager.searchProvider.query) { _, _ in
                guard let rootURL = projectManager.rootURL else { return }
                projectManager.searchProvider.search(in: rootURL)
            }
            .onAppear {
                configureSearchToolbarItem()
            }
    }

    /// Finds the NSSearchToolbarItem in the window toolbar and sets preferred width (Finder-style).
    private func configureSearchToolbarItem() {
        DispatchQueue.main.asyncAfter(deadline: .now() + UITimings.Delay.standard) {
            guard let window = NSApp.keyWindow,
                  let toolbar = window.toolbar else { return }
            for item in toolbar.items {
                if let searchItem = item as? NSSearchToolbarItem {
                    searchItem.preferredWidthForSearchField = 180
                    break
                }
            }
        }
    }
}
