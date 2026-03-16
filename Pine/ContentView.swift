//
//  ContentView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

// MARK: - Главный ContentView

struct ContentView: View {
    @Environment(ProjectManager.self) var projectManager
    @Environment(WorkspaceManager.self) var workspace
    @Environment(TerminalManager.self) var terminal
    @Environment(TabManager.self) var tabManager
    @Environment(ProjectRegistry.self) var registry
    @Environment(\.openWindow) var openWindow

    @Environment(\.controlActiveState) var controlActiveState

    @State private var selectedNode: FileNode?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var lineDiffs: [GitLineDiff] = []
    @State private var didRestoreSession = false
    @State private var showBranchSwitcher = false

    private var activeTab: EditorTab? { tabManager.activeTab }

    private var currentFileName: String {
        activeTab?.fileName ?? workspace.projectName
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(workspace: workspace, selectedFile: $selectedNode)
                .accessibilityIdentifier(AccessibilityID.sidebar)
        } detail: {
            VStack(spacing: 0) {
                if terminal.isTerminalVisible {
                    if terminal.isTerminalMaximized {
                        terminalArea
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VSplitView {
                            editorArea
                                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                            terminalArea
                                .frame(maxWidth: .infinity, minHeight: 100, idealHeight: 150, maxHeight: .infinity)
                        }
                        .frame(maxHeight: .infinity)
                    }
                } else {
                    editorArea
                        .frame(maxHeight: .infinity)
                }
                StatusBarView(
                    gitProvider: workspace.gitProvider,
                    terminal: terminal
                )
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle(workspace.projectName)
        .navigationSubtitle(branchSubtitle)
        .task {
            restoreSessionIfNeeded()
            syncSidebarSelection()
        }
        .onChange(of: selectedNode) { _, newNode in
            guard let node = newNode, !node.isDirectory else { return }
            handleFileSelection(node)
        }
        .onChange(of: workspace.rootURL) { _, _ in
            lineDiffs = []
            projectManager.saveSession()
        }
        .onChange(of: tabManager.activeTabID) { _, _ in
            syncSidebarSelection()
            refreshLineDiffs()
            projectManager.saveSession()
        }
        .onChange(of: workspace.rootNodes) { _, _ in
            restoreSessionIfNeeded()
            syncSidebarSelection()
        }
        .onChange(of: tabManager.tabs.count) { _, _ in
            projectManager.saveSession()
        }
        .onChange(of: workspace.gitProvider.isGitRepository) { _, isRepo in
            if isRepo {
                refreshLineDiffs()
            } else {
                lineDiffs = []
            }
        }
        .onChange(of: workspace.gitProvider.currentBranch) { _, _ in
            refreshLineDiffs()
        }
        .onChange(of: workspace.gitProvider.fileStatuses) { _, _ in
            refreshLineDiffs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshLineDiffs)) { _ in
            guard controlActiveState == .key else { return }
            refreshLineDiffs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { _ in
            guard controlActiveState == .key,
                  let tab = tabManager.activeTab else { return }
            closeTabWithConfirmation(tab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
            guard controlActiveState == .key else { return }
            openNewProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileRenamed)) { notification in
            guard let oldURL = notification.userInfo?["oldURL"] as? URL,
                  let newURL = notification.userInfo?["newURL"] as? URL else { return }
            tabManager.handleFileRenamed(oldURL: oldURL, newURL: newURL)
            projectManager.saveSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileDeleted)) { notification in
            guard let deletedURL = notification.userInfo?["url"] as? URL else { return }
            handleFileDeletion(deletedURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchBranch)) { _ in
            guard controlActiveState == .key,
                  workspace.gitProvider.isGitRepository else { return }
            showBranchSwitcher = true
        }
        .sheet(isPresented: $showBranchSwitcher) {
            BranchSwitcherView(
                gitProvider: workspace.gitProvider,
                isPresented: $showBranchSwitcher
            )
        }
        .onChange(of: workspace.externalChangeToken) { _, _ in
            guard controlActiveState == .key else { return }
            let conflicts = tabManager.checkExternalChanges()
            handleExternalConflicts(conflicts)
        }
    }

    /// Branch subtitle as a plain String to avoid generating a localization key.
    private var branchSubtitle: String {
        workspace.gitProvider.isGitRepository ? "⎇ \(workspace.gitProvider.currentBranch)" : ""
    }

    // MARK: - Session restoration

    private func restoreSessionIfNeeded() {
        guard !didRestoreSession else { return }
        didRestoreSession = true

        guard let rootURL = workspace.rootURL else {
            didRestoreSession = false // Allow retry when rootURL becomes available
            return
        }

        guard let session = SessionState.load(for: rootURL) else { return }
        guard tabManager.tabs.isEmpty else { return }

        for url in session.existingFileURLs {
            tabManager.openTab(url: url)
        }

        // Restore preview modes for markdown tabs
        if let previewModes = session.previewModes {
            for index in tabManager.tabs.indices {
                let path = tabManager.tabs[index].url.path
                if let rawMode = previewModes[path],
                   let mode = MarkdownPreviewMode(rawValue: rawMode) {
                    tabManager.tabs[index].previewMode = mode
                }
            }
        }

        if let activeURL = session.activeFileURL,
           let tab = tabManager.tab(for: activeURL) {
            tabManager.activeTabID = tab.id
        }
    }

    // MARK: - Открытие нового проекта

    /// Opens a new project via folder picker, opening it in a new window.
    private func openNewProject() {
        guard let url = registry.openProjectViaPanel() else { return }
        openWindow(value: url)
    }

    // MARK: - Управление файлами

    private func handleFileSelection(_ node: FileNode) {
        tabManager.openTab(url: node.url)
    }

    /// Syncs sidebar selection to match the active editor tab.
    private func syncSidebarSelection() {
        guard let url = tabManager.activeTab?.url else {
            selectedNode = nil
            return
        }
        // Already pointing at the right node — skip tree traversal
        if selectedNode?.url == url { return }
        selectedNode = findNode(url: url, in: workspace.rootNodes)
    }

    /// Recursively searches the file tree for a node with the given URL.
    private func findNode(url: URL, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.url == url { return node }
            if let children = node.children,
               let found = findNode(url: url, in: children) {
                return found
            }
        }
        return nil
    }

    /// Refreshes cached line diffs for the active tab.
    private func refreshLineDiffs() {
        guard let tab = tabManager.activeTab else {
            lineDiffs = []
            return
        }
        lineDiffs = workspace.gitProvider.diffForFile(at: tab.url)
    }

    /// Switches to the given branch via toolbarTitleMenu, showing an alert on error.
    private func switchBranch(_ branch: String) {
        guard branch != workspace.gitProvider.currentBranch else { return }
        let result = workspace.gitProvider.checkoutBranch(branch)
        if !result.success {
            let alert = NSAlert()
            alert.messageText = Strings.branchSwitchErrorTitle
            alert.informativeText = result.error
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Closes a tab with unsaved-changes protection.
    /// Used by both the tab bar close button and Cmd+W.
    private func closeTabWithConfirmation(_ tab: EditorTab) {
        if tab.isDirty {
            let alert = NSAlert()
            alert.messageText = Strings.unsavedChangesTitle
            alert.informativeText = Strings.unsavedChangesMessage
            alert.addButton(withTitle: Strings.dialogSave)
            alert.addButton(withTitle: Strings.dialogDontSave)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                guard tabManager.saveTab(at: index) else { return }
                workspace.gitProvider.refresh()
                tabManager.closeTab(id: tab.id)
            case .alertSecondButtonReturn:
                tabManager.closeTab(id: tab.id)
            default:
                return
            }
        } else {
            tabManager.closeTab(id: tab.id)
        }
    }

    private func handleExternalConflicts(_ conflicts: [TabManager.ExternalConflict]) {
        let modified = conflicts.filter { $0.kind == .modified }
        let deleted = conflicts.filter { $0.kind == .deleted }

        // Single grouped alert for all externally modified dirty tabs
        if !modified.isEmpty {
            let names = modified.map(\.url.lastPathComponent).joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = Strings.externalModifyTitle
            alert.informativeText = Strings.externalModifyMessage(names)
            alert.addButton(withTitle: Strings.externalModifyReload)
            alert.addButton(withTitle: Strings.externalModifyKeep)
            alert.alertStyle = .warning

            if alert.runModal() == .alertFirstButtonReturn {
                for conflict in modified {
                    tabManager.reloadTab(url: conflict.url)
                }
            }
        }

        // Handle deleted files via existing flow
        for conflict in deleted {
            handleFileDeletion(conflict.url)
        }
    }

    private func handleFileDeletion(_ deletedURL: URL) {
        let affected = tabManager.tabsAffectedByDeletion(url: deletedURL)
        guard !affected.isEmpty else { return }

        let dirtyTabs = affected.filter { $0.isDirty }
        if !dirtyTabs.isEmpty {
            let alert = NSAlert()
            alert.messageText = Strings.fileDeletedTitle
            alert.informativeText = Strings.fileDeletedMessage
            alert.addButton(withTitle: Strings.fileDeletedSaveAs)
            alert.addButton(withTitle: Strings.dialogDontSave)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                // Save As… for each dirty tab — abort entirely on cancel/error
                for tab in dirtyTabs {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = tab.fileName
                    guard panel.runModal() == .OK, let saveURL = panel.url else { return }
                    do {
                        try tab.content.write(to: saveURL, atomically: true, encoding: .utf8)
                    } catch {
                        let errAlert = NSAlert()
                        errAlert.messageText = Strings.fileOperationErrorTitle
                        errAlert.informativeText = error.localizedDescription
                        errAlert.alertStyle = .warning
                        errAlert.runModal()
                        return
                    }
                }
            case .alertSecondButtonReturn:
                break // Don't save — proceed to close
            default:
                return // Cancel — keep tabs open
            }
        }

        tabManager.closeTabsForDeletedFile(url: deletedURL)
    }

    // MARK: - Область редактора

    @ViewBuilder
    private var editorArea: some View {
        VStack(spacing: 0) {
            if !tabManager.tabs.isEmpty {
                EditorTabBar(
                    tabManager: tabManager,
                    onCloseTab: { tab in closeTabWithConfirmation(tab) },
                    onReorder: { projectManager.saveSession() },
                    isMarkdownFile: activeTab?.isMarkdownFile ?? false,
                    previewMode: activeTab?.previewMode ?? .source,
                    onTogglePreview: { tabManager.togglePreviewMode() }
                )
            }

            if let tab = activeTab {
                Group {
                    if tab.kind == .preview {
                        QuickLookPreviewView(url: tab.url)
                            .accessibilityIdentifier(AccessibilityID.quickLookPreview)
                    } else if tab.isMarkdownFile {
                        switch tab.previewMode {
                        case .source:
                            codeEditorView(for: tab)
                        case .preview:
                            MarkdownPreviewView(content: tab.content)
                                .accessibilityIdentifier(AccessibilityID.markdownPreviewView)
                        case .split:
                            HSplitView {
                                codeEditorView(for: tab)
                                    .frame(minWidth: 200)
                                MarkdownPreviewView(content: tab.content)
                                    .accessibilityIdentifier(AccessibilityID.markdownPreviewView)
                                    .frame(minWidth: 200)
                            }
                        }
                    } else {
                        codeEditorView(for: tab)
                    }
                }
                .id(tab.id)
            } else {
                ContentUnavailableView {
                    Label(Strings.noFileSelected, systemImage: "doc.text")
                } description: {
                    Text(Strings.selectFilePrompt)
                }
                .accessibilityIdentifier(AccessibilityID.editorPlaceholder)
            }
        }
    }

    @ViewBuilder
    private func codeEditorView(for tab: EditorTab) -> some View {
        CodeEditorView(
            text: Binding(
                get: { tab.content },
                set: { tabManager.updateContent($0) }
            ),
            language: tab.language,
            fileName: tab.fileName,
            lineDiffs: lineDiffs,
            initialCursorPosition: tab.cursorPosition,
            initialScrollOffset: tab.scrollOffset,
            onStateChange: { cursor, scroll in
                tabManager.updateEditorState(cursorPosition: cursor, scrollOffset: scroll)
            }
        )
        .accessibilityIdentifier(AccessibilityID.codeEditor)
    }

    // MARK: - Область терминала

    @ViewBuilder
    private var terminalArea: some View {
        VStack(spacing: 0) {
            // Tab bar, стилизованный под нативные macOS window tabs
            TerminalNativeTabBar(terminal: terminal, workingDirectory: workspace.rootURL)

            TerminalContentView(terminal: terminal)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { terminal.startTerminals(workingDirectory: workspace.rootURL) }
    }
}

// MARK: - Панель вкладок терминала (стиль нативных macOS window tabs)

struct TerminalNativeTabBar: View {
    var terminal: TerminalManager
    var workingDirectory: URL?

    var body: some View {
        HStack(spacing: 0) {
            // Вкладки терминалов
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(terminal.terminalTabs) { tab in
                        TerminalNativeTabItem(
                            tab: tab,
                            isActive: tab.id == terminal.activeTerminalID,
                            canClose: terminal.terminalTabs.count > 1,
                            onSelect: { terminal.activeTerminalID = tab.id },
                            onClose: { terminal.closeTerminalTab(tab) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            // Кнопка "+" — новый терминал
            Button {
                terminal.addTerminalTab(workingDirectory: workingDirectory)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(Strings.newTerminal)
            .accessibilityIdentifier(AccessibilityID.newTerminalButton)
            .accessibilityAddTraits(.isButton)

            Spacer()

            // Развернуть / свернуть терминал на весь экран
            Button {
                withAnimation { terminal.isTerminalMaximized.toggle() }
            } label: {
                Image(systemName: terminal.isTerminalMaximized
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(terminal.isTerminalMaximized ? Strings.restoreTerminal : Strings.maximizeTerminal)
            .accessibilityIdentifier(AccessibilityID.maximizeTerminalButton)

            // Кнопка скрытия терминала
            Button {
                withAnimation {
                    terminal.isTerminalVisible = false
                    terminal.isTerminalMaximized = false
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help(Strings.hideTerminal)
            .accessibilityIdentifier(AccessibilityID.hideTerminalButton)
        }
        .frame(height: 30)
        .background(.bar)
    }
}

/// Вкладка терминала в стиле macOS window tab (capsule).
struct TerminalNativeTabItem: View {
    let tab: TerminalTab
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            // Кнопка закрытия — видна при hover или активной вкладке
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            isHovering ? Color.primary.opacity(0.1) : .clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .opacity(isHovering || isActive ? 1 : 0)
            }

            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(tab.name)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            isActive
                ? Color.primary.opacity(0.12)
                : isHovering ? Color.primary.opacity(0.05) : .clear,
            in: Capsule()
        )
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(AccessibilityID.terminalTab(tab.name))
    }
}

// MARK: - Sidebar edit state

/// Tracks inline rename / new-item state for the sidebar file tree.
@Observable
final class SidebarEditState {
    var renamingURL: URL?
    var editingText: String = ""
    var isNewlyCreated: Bool = false

    func startRename(for node: FileNode) {
        renamingURL = node.url
        editingText = node.name
        isNewlyCreated = false
    }

    func startNewItem(url: URL) {
        renamingURL = url
        editingText = url.lastPathComponent
        isNewlyCreated = true
    }

    func clear() {
        renamingURL = nil
        editingText = ""
        isNewlyCreated = false
    }

    /// Creates a file or folder with a unique "untitled" name, then starts inline rename.
    func createNewItem(in parentURL: URL, isDirectory: Bool, workspace: WorkspaceManager) {
        let baseName = isDirectory ? "untitled folder" : "untitled"
        let name = Self.uniqueName(baseName, in: parentURL)
        let newURL = parentURL.appendingPathComponent(name)

        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
            } else if !FileManager.default.createFile(atPath: newURL.path, contents: nil) {
                Self.showFileError(Strings.fileCreateError(name))
                return
            }
            workspace.refreshFileTree()
            startNewItem(url: newURL)
        } catch {
            Self.showFileError(error.localizedDescription)
        }
    }

    /// Duplicates a file or folder with Finder-style naming, then starts inline rename.
    func duplicateItem(
        at url: URL,
        isDirectory: Bool,
        workspace: WorkspaceManager,
        tabManager: TabManager
    ) {
        guard let copyURL = Self.finderCopyURL(for: url) else { return }

        do {
            try FileManager.default.copyItem(at: url, to: copyURL)
            workspace.refreshFileTree()
            // Start inline rename — same pattern as createNewItem.
            // isNewlyCreated is false so cancelling rename keeps the copy.
            renamingURL = copyURL
            editingText = copyURL.lastPathComponent
            isNewlyCreated = false
            if !isDirectory {
                tabManager.openTab(url: copyURL)
            }
        } catch {
            Self.showFileError(error.localizedDescription)
        }
    }

    /// Returns a unique name by appending a counter if the name already exists.
    static func uniqueName(_ baseName: String, in parentURL: URL) -> String {
        var name = baseName
        var counter = 2
        while FileManager.default.fileExists(atPath: parentURL.appendingPathComponent(name).path) {
            name = "\(baseName) \(counter)"
            counter += 1
        }
        return name
    }

    /// Generates a Finder-style copy URL: "name copy", "name copy 2", etc.
    static func finderCopyURL(for url: URL) -> URL? {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let baseName = ext.isEmpty
            ? url.lastPathComponent
            : String(url.lastPathComponent.dropLast(ext.count + 1))

        let fm = FileManager.default
        for counter in 0... {
            let copyName: String
            if counter == 0 {
                copyName = ext.isEmpty
                    ? "\(baseName) copy"
                    : "\(baseName) copy.\(ext)"
            } else {
                copyName = ext.isEmpty
                    ? "\(baseName) copy \(counter + 1)"
                    : "\(baseName) copy \(counter + 1).\(ext)"
            }
            let candidate = directory.appendingPathComponent(copyName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Shows an AppKit error alert for file operations.
    static func showFileError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = Strings.fileOperationErrorTitle
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Сайдбар

struct SidebarView: View {
    var workspace: WorkspaceManager
    @Binding var selectedFile: FileNode?
    @Environment(ProjectRegistry.self) var registry
    @Environment(\.openWindow) var openWindow
    @State private var editState = SidebarEditState()

    var body: some View {
        Group {
            if workspace.rootURL == nil {
                List {
                    ContentUnavailableView {
                        Label(Strings.noFolderOpen, systemImage: "folder")
                    } description: {
                        Text(Strings.openFolderPrompt)
                    } actions: {
                        Button(Strings.openFolderButton) {
                            openNewProject()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .navigationTitle(Strings.filesTitle)
            } else {
                List(workspace.rootNodes, children: \.optionalChildren, selection: $selectedFile) { node in
                    FileNodeRow(node: node)
                }
                .environment(editState)
                .contextMenu {
                    if let rootURL = workspace.rootURL {
                        Button {
                            editState.createNewItem(in: rootURL, isDirectory: false, workspace: workspace)
                        } label: {
                            Label(Strings.contextNewFile, systemImage: "doc.badge.plus")
                        }

                        Button {
                            editState.createNewItem(in: rootURL, isDirectory: true, workspace: workspace)
                        } label: {
                            Label(Strings.contextNewFolder, systemImage: "folder.badge.plus")
                        }
                    }
                }
                .navigationTitle(workspace.projectName)
                .onChange(of: editState.renamingURL) { _, newURL in
                    if newURL != nil {
                        // Defer to avoid modifying state during view update
                        DispatchQueue.main.async {
                            selectedFile = nil
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 250)
        .toolbar {
            ToolbarItem {
                Button {
                    openNewProject()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help(Strings.openFolderTooltip)
            }
        }
    }

    /// Opens a new project via folder picker in a new window.
    private func openNewProject() {
        guard let url = registry.openProjectViaPanel() else { return }
        openWindow(value: url)
    }

}

// MARK: - Строка файла/папки в дереве

struct FileNodeRow: View {
    var node: FileNode
    @Environment(WorkspaceManager.self) var workspace
    @Environment(TabManager.self) var tabManager
    @Environment(SidebarEditState.self) var editState
    @FocusState private var isTextFieldFocused: Bool

    private var isEditing: Bool {
        guard let renamingURL = editState.renamingURL else { return false }
        // Compare by path to ignore trailing-slash differences between
        // URLs built via appendingPathComponent (no slash) and URLs
        // returned by contentsOfDirectory (trailing slash for directories).
        return renamingURL.path == node.url.path
    }

    private var gitStatus: GitFileStatus? {
        let provider = workspace.gitProvider
        return node.isDirectory
            ? provider.statusForDirectory(at: node.url)
            : provider.statusForFile(at: node.url)
    }

    private var iconName: String {
        node.isDirectory
            ? FileIconMapper.iconForFolder(node.name)
            : FileIconMapper.iconForFile(node.name)
    }

    var body: some View {
        Group {
            if isEditing {
                inlineEditor
            } else {
                Label(node.name, systemImage: iconName)
                    .foregroundStyle(gitStatus?.color ?? .primary)
            }
        }
        .tag(node)
        .accessibilityIdentifier(AccessibilityID.fileNode(node.name))
        .contextMenu { fileNodeContextMenu }
    }

    // MARK: - Inline editor

    @ViewBuilder
    private var inlineEditor: some View {
        @Bindable var state = editState
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
            TextField("", text: $state.editingText)
                .textFieldStyle(.plain)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
                .focused($isTextFieldFocused)
                .onAppear {
                    DispatchQueue.main.async {
                        isTextFieldFocused = true
                    }
                }
                .onChange(of: isTextFieldFocused) { _, focused in
                    // Guard against double-commit: onSubmit clears editState,
                    // then focus loss fires — skip if already committed.
                    guard !focused, editState.renamingURL?.path == node.url.path else { return }
                    commitRename()
                }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var fileNodeContextMenu: some View {
        if node.isDirectory {
            Button {
                createNewItem(isDirectory: false)
            } label: {
                Label(Strings.contextNewFile, systemImage: "doc.badge.plus")
            }

            Button {
                createNewItem(isDirectory: true)
            } label: {
                Label(Strings.contextNewFolder, systemImage: "folder.badge.plus")
            }

            Divider()
        }

        Button {
            duplicateItem()
        } label: {
            Label(Strings.contextDuplicate, systemImage: "plus.square.on.square")
        }

        Button {
            editState.startRename(for: node)
        } label: {
            Label(Strings.contextRename, systemImage: "pencil")
        }

        Button(role: .destructive) {
            deleteItem()
        } label: {
            Label(Strings.contextDelete, systemImage: "trash")
        }

        Divider()

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        } label: {
            Label(Strings.contextRevealInFinder, systemImage: "arrow.right.circle")
        }
    }

    // MARK: - File operations

    private func createNewItem(isDirectory: Bool) {
        editState.createNewItem(in: node.url, isDirectory: isDirectory, workspace: workspace)
    }

    private func duplicateItem() {
        editState.duplicateItem(
            at: node.url,
            isDirectory: node.isDirectory,
            workspace: workspace,
            tabManager: tabManager
        )
    }

    private func commitRename() {
        guard editState.renamingURL?.path == node.url.path else { return }

        let newName = editState.editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            cancelRename()
            return
        }

        let oldURL = node.url
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
        let wasNewlyCreated = editState.isNewlyCreated

        // Name unchanged — accept as-is
        if newURL == oldURL {
            editState.clear()
            if wasNewlyCreated && !node.isDirectory {
                tabManager.openTab(url: oldURL)
            }
            return
        }

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            editState.clear()
            workspace.refreshFileTree()
            NotificationCenter.default.post(
                name: .fileRenamed,
                object: nil,
                userInfo: ["oldURL": oldURL, "newURL": newURL]
            )
            // Auto-open newly created files in an editor tab
            if wasNewlyCreated && !node.isDirectory {
                tabManager.openTab(url: newURL)
            }
        } catch {
            // Keep editing so the user can try a different name
            SidebarEditState.showFileError(error.localizedDescription)
        }
    }

    private func cancelRename() {
        let wasNewlyCreated = editState.isNewlyCreated
        let url = editState.renamingURL
        editState.clear()

        // Delete placeholder item if creation was cancelled
        if wasNewlyCreated, let url {
            try? FileManager.default.removeItem(at: url)
            workspace.refreshFileTree()
        }
    }

    private func deleteItem() {
        let deletedURL = node.url
        do {
            try FileManager.default.trashItem(at: deletedURL, resultingItemURL: nil)
            workspace.refreshFileTree()
            NotificationCenter.default.post(
                name: .fileDeleted,
                object: nil,
                userInfo: ["url": deletedURL]
            )
        } catch {
            SidebarEditState.showFileError(error.localizedDescription)
        }
    }
}

// MARK: - Status Bar

struct StatusBarView: View {
    var gitProvider: GitStatusProvider
    var terminal: TerminalManager
    @State private var showBranchPopover = false

    var body: some View {
        HStack(spacing: 6) {
            if gitProvider.isGitRepository {
                // Branch switcher button
                Button {
                    showBranchPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                        Text(gitProvider.currentBranch)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.branchSwitcherButton)
                .popover(isPresented: $showBranchPopover, arrowEdge: .top) {
                    BranchSwitcherView(
                        gitProvider: gitProvider,
                        isPresented: $showBranchPopover
                    )
                }

                // Git file change summary
                if !gitProvider.fileStatuses.isEmpty {
                    let counts = gitStatusCounts
                    HStack(spacing: 8) {
                        if counts.modified > 0 {
                            Label {
                                Text(verbatim: "\(counts.modified)")
                            } icon: {
                                Image(systemName: "pencil")
                            }
                            .foregroundStyle(.orange)
                        }
                        if counts.added > 0 {
                            Label {
                                Text(verbatim: "\(counts.added)")
                            } icon: {
                                Image(systemName: "plus")
                            }
                            .foregroundStyle(.green)
                        }
                        if counts.untracked > 0 {
                            Label {
                                Text(verbatim: "\(counts.untracked)")
                            } icon: {
                                Image(systemName: "questionmark")
                            }
                            .foregroundStyle(.teal)
                        }
                    }
                    .font(.system(size: 10))
                }
            }

            Spacer()

            // Кнопка показа/скрытия терминала
            Button {
                withAnimation { terminal.isTerminalVisible.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: terminal.isTerminalVisible
                          ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                    Text(Strings.terminalLabel)
                        .font(.system(size: 11))
                }
                .foregroundStyle(terminal.isTerminalVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(terminal.isTerminalVisible ? Strings.hideTerminalShortcut : Strings.showTerminalShortcut)
            .accessibilityIdentifier(AccessibilityID.terminalToggleButton)
            .accessibilityAddTraits(.isButton)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: 22)
        .background(.bar)
    }

    private var gitStatusCounts: (modified: Int, added: Int, untracked: Int) {
        var m = 0, a = 0, u = 0
        for (_, status) in gitProvider.fileStatuses {
            switch status {
            case .modified, .mixed: m += 1
            case .staged, .added:   a += 1
            case .untracked:        u += 1
            default: break
            }
        }
        return (m, a, u)
    }
}

#Preview {
    let projectManager = ProjectManager()
    let registry = ProjectRegistry()
    ContentView()
        .environment(projectManager)
        .environment(projectManager.workspace)
        .environment(projectManager.terminal)
        .environment(projectManager.tabManager)
        .environment(registry)
}
