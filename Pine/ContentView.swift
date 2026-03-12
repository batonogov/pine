//
//  ContentView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

// MARK: - WindowBridge

/// Настраивает NSWindow: tabbingMode, representedURL, tab title, перехват закрытия с несохранёнными изменениями.
struct WindowBridge: NSViewRepresentable {
    var representedURL: URL?
    var isDocumentEdited: Bool
    var tabTitle: String?
    var onSave: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowBridgeView {
        let view = WindowBridgeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: WindowBridgeView, context: Context) {
        context.coordinator.isDocumentEdited = isDocumentEdited
        context.coordinator.onSave = onSave
        nsView.pendingURL = representedURL
        nsView.pendingTabTitle = tabTitle
        nsView.applyIfPossible()
    }

    class Coordinator {
        var isDocumentEdited = false
        var onSave: (() -> Void)?
    }
}

class WindowBridgeView: NSView {
    weak var hostWindow: NSWindow?
    var pendingURL: URL?
    var pendingTabTitle: String?
    var coordinator: WindowBridge.Coordinator?
    private var closeInterceptor: WindowCloseInterceptor?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, closeInterceptor == nil {
            hostWindow = window
            window.tabbingMode = .preferred
            window.tabbingIdentifier = AppDelegate.editorTabbingID

            // Перехватываем закрытие окна для диалога сохранения
            let interceptor = WindowCloseInterceptor(
                originalDelegate: window.delegate,
                coordinator: coordinator
            )
            window.delegate = interceptor
            closeInterceptor = interceptor

            applyIfPossible()

            // Immediately merge into an existing tab group to prevent the
            // window from flashing as a standalone window before becoming a tab.
            // The debounced merge in AppDelegate handles session reordering.
            if let primaryWindow = NSApplication.shared.windows.first(where: {
                $0 !== window
                    && $0.tabbingIdentifier == AppDelegate.editorTabbingID
                    && $0.isVisible
            }) {
                window.alphaValue = 0
                primaryWindow.addTabbedWindow(window, ordered: .above)
                window.alphaValue = 1
            }

            // Signal for session reordering (debounced merge handles tab order)
            NotificationCenter.default.post(name: .editorWindowReady, object: nil)
        }
    }

    func applyIfPossible() {
        guard let window = hostWindow ?? self.window else { return }
        window.representedURL = pendingURL
        window.isDocumentEdited = coordinator?.isDocumentEdited ?? false
        // Set tab caption independently from the window title.
        // This allows navigationTitle to control the title bar (project name)
        // while each tab shows its own file name.
        window.tab.title = pendingTabTitle ?? ""
    }
}

/// Proxy-delegate: перехватывает windowShouldClose для диалога сохранения,
/// остальные методы пробрасывает оригинальному SwiftUI-delegate.
class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    weak var originalDelegate: NSWindowDelegate?
    weak var coordinator: WindowBridge.Coordinator?

    init(originalDelegate: NSWindowDelegate?, coordinator: WindowBridge.Coordinator?) {
        self.originalDelegate = originalDelegate
        self.coordinator = coordinator
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let coordinator, coordinator.isDocumentEdited else {
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

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
            coordinator.onSave?()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // Пробрасываем все остальные delegate-методы оригинальному SwiftUI delegate
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        return originalDelegate
    }
}

// MARK: - Главный ContentView

struct ContentView: View {
    @Binding var fileURL: URL?
    @Environment(ProjectManager.self) var projectManager
    @Environment(WorkspaceManager.self) var workspace
    @Environment(TerminalManager.self) var terminal
    @Environment(\.openWindow) var openWindow

    @State private var selectedNode: FileNode?
    @State private var fileContent: String = ""
    @State private var savedContent: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var lineDiffs: [GitLineDiff] = []
    /// When true, the next fileURL change skips reloading from disk (used during rename).
    @State private var suppressNextReload = false
    /// Global flag — only the first ContentView instance restores the session.
    private static var didRestoreSession = false

    private var hasUnsavedChanges: Bool {
        fileContent != savedContent
    }

    private var currentFileName: String {
        fileURL?.lastPathComponent ?? workspace.projectName
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
        .background(WindowBridge(
            representedURL: fileURL,
            isDocumentEdited: hasUnsavedChanges,
            tabTitle: fileURL?.lastPathComponent,
            onSave: { [self] in saveFile() }
        ))
        .onAppear {
            if let url = fileURL {
                // SwiftUI may restore windows with a non-nil fileURL (Codable persistence).
                // In that case restoreSessionIfNeeded() won't run, so we need to
                // load the project directory here to populate the sidebar.
                restoreProjectDirectoryIfNeeded()
                loadFileFromURL(url)
                // New window tabs get fileURL as initial state (onChange won't fire),
                // so save session here to capture the newly opened tab.
                Task { @MainActor in
                    projectManager.saveSession()
                }
            }
            restoreSessionIfNeeded()
        }
        .onChange(of: fileURL) { _, newURL in
            if suppressNextReload {
                suppressNextReload = false
                return
            }
            if let url = newURL {
                loadFileFromURL(url)
            }
            // Save session after window representedURL updates
            Task { @MainActor in
                projectManager.saveSession()
            }
        }
        .onChange(of: selectedNode) { _, newNode in
            guard let node = newNode, !node.isDirectory else { return }
            handleFileSelection(node)
        }
        .onChange(of: workspace.rootURL) { _, _ in
            // Clear stale gutter markers from the previous project immediately.
            lineDiffs = []
            // saveSession() filters files by current rootURL,
            // so stale tabs from the old project are excluded.
            projectManager.saveSession()
        }
        .onChange(of: workspace.gitProvider.isGitRepository) { _, isRepo in
            // After async project load finishes, git state becomes available.
            // Recalculate gutter diffs for the already-open file.
            // When switching to a non-git project, clear stale markers.
            if isRepo, let url = fileURL {
                lineDiffs = workspace.gitProvider.diffForFile(at: url)
            } else {
                lineDiffs = []
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveFile)) { _ in
            saveFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
            workspace.openFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTerminal)) { _ in
            withAnimation { terminal.isTerminalVisible.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchBranch)) { _ in
            // Branch switching is now handled via toolbarTitleMenu
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileRenamed)) { notification in
            guard let oldURL = notification.userInfo?["oldURL"] as? URL,
                  let newURL = notification.userInfo?["newURL"] as? URL,
                  let currentURL = fileURL else { return }
            // Exact match (file itself renamed) or child of renamed directory
            if currentURL == oldURL {
                suppressNextReload = true
                fileURL = newURL
            } else if currentURL.path.hasPrefix(oldURL.path + "/") {
                let relativePath = String(currentURL.path.dropFirst(oldURL.path.count + 1))
                suppressNextReload = true
                fileURL = newURL.appendingPathComponent(relativePath)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileDeleted)) { notification in
            guard let deletedURL = notification.userInfo?["url"] as? URL,
                  let currentURL = fileURL else { return }
            // Exact match or child of deleted directory
            let isAffected = currentURL == deletedURL
                || currentURL.path.hasPrefix(deletedURL.path + "/")
            guard isAffected else { return }

            if hasUnsavedChanges {
                let alert = NSAlert()
                alert.messageText = Strings.fileDeletedTitle
                alert.informativeText = Strings.fileDeletedMessage
                alert.addButton(withTitle: Strings.fileDeletedSaveAs)
                alert.addButton(withTitle: Strings.dialogDontSave)
                alert.alertStyle = .warning

                if alert.runModal() == .alertFirstButtonReturn {
                    // Save As… — only clear the tab if user actually saved
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = currentURL.lastPathComponent
                    guard panel.runModal() == .OK, let saveURL = panel.url else { return }
                    do {
                        try fileContent.write(to: saveURL, atomically: true, encoding: .utf8)
                    } catch {
                        let errAlert = NSAlert()
                        errAlert.messageText = Strings.fileOperationErrorTitle
                        errAlert.informativeText = error.localizedDescription
                        errAlert.alertStyle = .warning
                        errAlert.runModal()
                        return
                    }
                }
            }
            fileURL = nil
            fileContent = ""
            savedContent = ""
            lineDiffs = []
        }
    }

    /// Branch subtitle as a plain String to avoid generating a localization key.
    private var branchSubtitle: String {
        workspace.gitProvider.isGitRepository ? "⎇ \(workspace.gitProvider.currentBranch)" : ""
    }

    // MARK: - Session restoration

    /// When SwiftUI auto-restores windows with non-nil fileURL,
    /// restoreSessionIfNeeded() is skipped (guard fileURL == nil fails).
    /// This method ensures the project directory is still loaded for the sidebar.
    private func restoreProjectDirectoryIfNeeded() {
        guard workspace.rootURL == nil,
              let session = SessionState.load() else { return }
        workspace.loadDirectory(url: session.projectURL)
    }

    private func restoreSessionIfNeeded() {
        guard !Self.didRestoreSession else { return }
        Self.didRestoreSession = true

        guard fileURL == nil,
              let session = SessionState.load() else { return }

        // loadDirectory sets rootURL/projectName synchronously,
        // then dispatches heavy I/O (file tree + git) to a background queue.
        if workspace.rootURL == nil {
            workspace.loadDirectory(url: session.projectURL)
        }

        let fileURLs = session.existingFileURLs
        guard !fileURLs.isEmpty else { return }

        // Open the first file in the current (empty) window
        fileURL = fileURLs.first

        // Open remaining files in new window tabs.
        // The debounced merge in AppDelegate handles grouping them.
        for url in fileURLs.dropFirst() {
            openWindow(value: url)
        }
    }

    // MARK: - Управление файлами

    private func handleFileSelection(_ node: FileNode) {
        if fileURL == nil {
            // Пустое окно — загружаем файл сюда
            fileURL = node.url
            return
        }

        if fileURL == node.url {
            // Этот файл уже открыт в текущем табе
            return
        }

        // Проверяем, открыт ли файл в другом табе — переключаемся на него
        if let existingWindow = NSApplication.shared.windows.first(where: {
            $0.representedURL == node.url && $0.isVisible
        }) {
            existingWindow.makeKeyAndOrderFront(nil)
            // Сбрасываем выделение в текущем окне
            selectedNode = nil
            return
        }

        // Открываем в новом табе
        openWindow(value: node.url)
        // Сбрасываем выделение, чтобы повторный клик тоже сработал
        selectedNode = nil
    }

    private func loadFileFromURL(_ url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            fileContent = content
            savedContent = content
            lineDiffs = workspace.gitProvider.diffForFile(at: url)
        } catch {
            let errorText = "// Error: \(error.localizedDescription)"
            fileContent = errorText
            savedContent = errorText
            lineDiffs = []
        }
    }

    private func saveFile() {
        guard let url = fileURL else { return }
        do {
            try fileContent.write(to: url, atomically: true, encoding: .utf8)
            savedContent = fileContent
            NSApp.keyWindow?.isDocumentEdited = false
            // Refresh git status after save
            workspace.gitProvider.refresh()
            lineDiffs = workspace.gitProvider.diffForFile(at: url)
        } catch {
            print("Error saving file: \(error.localizedDescription)")
        }
    }

    // MARK: - Область редактора

    @ViewBuilder
    private var editorArea: some View {
        if fileURL != nil {
            CodeEditorView(
                text: $fileContent,
                language: (currentFileName as NSString).pathExtension.lowercased(),
                fileName: currentFileName,
                lineDiffs: lineDiffs
            )
        } else {
            ContentUnavailableView {
                Label(Strings.noFileSelected, systemImage: "doc.text")
            } description: {
                Text(Strings.selectFilePrompt)
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
                            workspace.openFolder()
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
                    workspace.openFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help(Strings.openFolderTooltip)
            }
        }
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
    @Previewable @State var url: URL?
    let projectManager = ProjectManager()
    ContentView(fileURL: $url)
        .environment(projectManager)
        .environment(projectManager.workspace)
        .environment(projectManager.terminal)
}
