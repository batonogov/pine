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

    private var activeTab: EditorTab? { tabManager.activeTab }

    private var currentFileName: String {
        activeTab?.fileName ?? workspace.projectName
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(workspace: workspace, selectedFile: $selectedNode)
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
        .onAppear {
            restoreSessionIfNeeded()
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
            refreshLineDiffs()
            projectManager.saveSession()
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
        .onChange(of: controlActiveState) { _, newState in
            if newState == .key, let url = workspace.rootURL {
                registry.lastActiveProjectURL = url
            }
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
    }

    /// Branch subtitle as a plain String to avoid generating a localization key.
    private var branchSubtitle: String {
        workspace.gitProvider.isGitRepository ? "⎇ \(workspace.gitProvider.currentBranch)" : ""
    }

    // MARK: - Session restoration

    private func restoreSessionIfNeeded() {
        guard !didRestoreSession else { return }
        didRestoreSession = true

        guard let session = SessionState.load(),
              session.projectURL == workspace.rootURL else { return }
        guard tabManager.tabs.isEmpty else { return }

        for url in session.existingFileURLs {
            tabManager.openTab(url: url)
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
        // Сбрасываем выделение, чтобы повторный клик тоже сработал
        selectedNode = nil
    }

    /// Refreshes cached line diffs for the active tab.
    private func refreshLineDiffs() {
        guard let tab = tabManager.activeTab else {
            lineDiffs = []
            return
        }
        lineDiffs = workspace.gitProvider.diffForFile(at: tab.url)
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
                    onReorder: { projectManager.saveSession() }
                )
            }

            if let tab = activeTab {
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
                .id(tab.id)
            } else {
                ContentUnavailableView {
                    Label(Strings.noFileSelected, systemImage: "doc.text")
                } description: {
                    Text(Strings.selectFilePrompt)
                }
            }
        }
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
    }
}

// MARK: - Сайдбар

struct SidebarView: View {
    var workspace: WorkspaceManager
    @Binding var selectedFile: FileNode?
    @Environment(ProjectRegistry.self) var registry
    @Environment(\.openWindow) var openWindow

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
                .contextMenu {
                    if let rootURL = workspace.rootURL {
                        Button {
                            promptForNewItem(in: rootURL, isDirectory: false)
                        } label: {
                            Label(Strings.contextNewFile, systemImage: "doc.badge.plus")
                        }

                        Button {
                            promptForNewItem(in: rootURL, isDirectory: true)
                        } label: {
                            Label(Strings.contextNewFolder, systemImage: "folder.badge.plus")
                        }
                    }
                }
                .navigationTitle(workspace.projectName)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180, idealWidth: 220)
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

    /// Prompt for a name and create a file or folder in the given parent directory.
    private func promptForNewItem(in parentURL: URL, isDirectory: Bool) {
        let title = isDirectory ? Strings.contextNewFolderTitle : Strings.contextNewFileTitle

        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: Strings.dialogOK)
        alert.addButton(withTitle: Strings.dialogCancel)

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = Strings.contextNamePlaceholder
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let newURL = parentURL.appendingPathComponent(name)
        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
            } else if !FileManager.default.createFile(atPath: newURL.path, contents: nil) {
                let alert = NSAlert()
                alert.messageText = Strings.fileOperationErrorTitle
                alert.informativeText = Strings.fileCreateError(name)
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            workspace.refreshFileTree()
        } catch {
            let alert = NSAlert()
            alert.messageText = Strings.fileOperationErrorTitle
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

// MARK: - Строка файла/папки в дереве

struct FileNodeRow: View {
    var node: FileNode
    @Environment(WorkspaceManager.self) var workspace

    private var gitStatus: GitFileStatus? {
        let provider = workspace.gitProvider
        return node.isDirectory
            ? provider.statusForDirectory(at: node.url)
            : provider.statusForFile(at: node.url)
    }

    var body: some View {
        Label(node.name, systemImage: node.isDirectory
              ? FileIconMapper.iconForFolder(node.name)
              : FileIconMapper.iconForFile(node.name))
            .foregroundStyle(gitStatus?.color ?? .primary)
            .tag(node)
            .contextMenu { fileNodeContextMenu }
    }

    @ViewBuilder
    private var fileNodeContextMenu: some View {
        if node.isDirectory {
            Button {
                promptForName(title: Strings.contextNewFileTitle, placeholder: Strings.contextNamePlaceholder) { name in
                    createItem(named: name, isDirectory: false)
                }
            } label: {
                Label(Strings.contextNewFile, systemImage: "doc.badge.plus")
            }

            Button {
                promptForName(title: Strings.contextNewFolderTitle, placeholder: Strings.contextNamePlaceholder) { name in
                    createItem(named: name, isDirectory: true)
                }
            } label: {
                Label(Strings.contextNewFolder, systemImage: "folder.badge.plus")
            }

            Divider()
        }

        Button {
            promptForName(
                title: Strings.contextRenameTitle,
                placeholder: Strings.contextNamePlaceholder,
                defaultValue: node.name
            ) { newName in
                renameItem(to: newName)
            }
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

    private func createItem(named name: String, isDirectory: Bool) {
        let parentURL = node.url
        let newURL = parentURL.appendingPathComponent(name)
        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
            } else if !FileManager.default.createFile(atPath: newURL.path, contents: nil) {
                showFileError(Strings.fileCreateError(name))
                return
            }
            workspace.refreshFileTree()
        } catch {
            showFileError(error.localizedDescription)
        }
    }

    private func renameItem(to newName: String) {
        let oldURL = node.url
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            workspace.refreshFileTree()
            NotificationCenter.default.post(
                name: .fileRenamed,
                object: nil,
                userInfo: ["oldURL": oldURL, "newURL": newURL]
            )
        } catch {
            showFileError(error.localizedDescription)
        }
    }

    private func deleteItem() {
        let alert = NSAlert()
        alert.messageText = Strings.contextDeleteConfirmTitle
        alert.informativeText = Strings.contextDeleteConfirmMessage(node.name)
        alert.addButton(withTitle: Strings.contextDeleteButton)
        alert.addButton(withTitle: Strings.dialogCancel)
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return }

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
            showFileError(error.localizedDescription)
        }
    }

    /// Shows an AppKit input dialog and calls the completion with the entered name.
    private func promptForName(
        title: String,
        placeholder: String,
        defaultValue: String = "",
        completion: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: Strings.dialogOK)
        alert.addButton(withTitle: Strings.dialogCancel)

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = placeholder
        textField.stringValue = defaultValue
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        completion(name)
    }

    private func showFileError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = Strings.fileOperationErrorTitle
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

}

// MARK: - Status Bar

struct StatusBarView: View {
    var gitProvider: GitStatusProvider
    var terminal: TerminalManager

    var body: some View {
        HStack(spacing: 6) {
            if gitProvider.isGitRepository {
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
