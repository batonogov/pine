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

/// Saves terminal state to session when visibility, tab count, or active tab changes.
struct TerminalSessionObserver: ViewModifier {
    let terminal: TerminalManager
    let onSave: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: terminal.isTerminalVisible) { _, _ in onSave() }
            .onChange(of: terminal.isTerminalMaximized) { _, _ in onSave() }
            .onChange(of: terminal.terminalTabs.count) { _, _ in onSave() }
            .onChange(of: terminal.activeTerminalID) { _, _ in onSave() }
    }
}

// MARK: - Git and notification observer

/// Extracted to reduce body complexity for the type-checker.
/// Handles git status changes, file notifications, and menu command notifications.
struct GitAndNotificationObserver: ViewModifier {
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(TabManager.self) private var tabManager
    @Environment(ProjectManager.self) private var projectManager
    @Environment(\.controlActiveState) private var controlActiveState
    @Binding var lineDiffs: [GitLineDiff]
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var isSearchPresented: Bool
    @Binding var showGoToLine: Bool
    var onRefreshLineDiffs: () -> Void
    var onRefreshBlame: () -> Void
    var onCloseTab: (EditorTab) -> Void
    var onOpenNewProject: () -> Void
    var onHandleFileDeletion: (URL) -> Void
    var onHandleExternalChanges: (TabManager.ExternalChangeResult) -> Void
    var onNavigateToChange: (ContentView.ChangeDirection) -> Void

    func body(content: Content) -> some View {
        content
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
            .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { _ in
                guard controlActiveState == .key,
                      let tab = tabManager.activeTab else { return }
                onCloseTab(tab)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
                guard controlActiveState == .key else { return }
                onOpenNewProject()
            }
            .onReceive(NotificationCenter.default.publisher(for: .fileRenamed)) { notification in
                guard let oldURL = notification.userInfo?["oldURL"] as? URL,
                      let newURL = notification.userInfo?["newURL"] as? URL else { return }
                tabManager.handleFileRenamed(oldURL: oldURL, newURL: newURL)
                projectManager.saveSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: .fileDeleted)) { notification in
                guard let deletedURL = notification.userInfo?["url"] as? URL else { return }
                onHandleFileDeletion(deletedURL)
            }
            .onChange(of: workspace.externalChangeToken) { _, _ in
                guard controlActiveState == .key else { return }
                let result = tabManager.checkExternalChanges()
                onHandleExternalChanges(result)
            }
            .onChange(of: controlActiveState) { _, newState in
                // When the window becomes key, check for external changes that
                // may have been missed while the window was inactive (issue #438).
                guard newState == .key else { return }
                let result = tabManager.checkExternalChanges()
                onHandleExternalChanges(result)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showProjectSearch)) { _ in
                withAnimation(PineAnimation.quick) {
                    columnVisibility = .all
                }
                isSearchPresented = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .goToLine)) { _ in
                guard controlActiveState == .key,
                      tabManager.activeTab != nil else { return }
                showGoToLine = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateChange)) { notification in
                guard controlActiveState == .key,
                      let direction = notification.userInfo?["direction"] as? String else { return }
                onNavigateToChange(direction == "next" ? .next : .previous)
            }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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
