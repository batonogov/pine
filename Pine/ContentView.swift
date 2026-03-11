//
//  ContentView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

// MARK: - WindowBridge

/// Настраивает NSWindow: tabbingMode, representedURL, перехват закрытия с несохранёнными изменениями.
struct WindowBridge: NSViewRepresentable {
    var representedURL: URL?
    var isDocumentEdited: Bool
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
    var coordinator: WindowBridge.Coordinator?
    private var closeInterceptor: WindowCloseInterceptor?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, closeInterceptor == nil {
            hostWindow = window
            window.tabbingMode = .preferred

            // Перехватываем закрытие окна для диалога сохранения
            let interceptor = WindowCloseInterceptor(
                originalDelegate: window.delegate,
                coordinator: coordinator
            )
            window.delegate = interceptor
            closeInterceptor = interceptor

            applyIfPossible()
        }
    }

    func applyIfPossible() {
        guard let window = hostWindow ?? self.window else { return }
        window.representedURL = pendingURL
        window.isDocumentEdited = coordinator?.isDocumentEdited ?? false
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
        alert.messageText = "Unsaved Changes"
        alert.informativeText = "Do you want to save changes before closing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
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
    @Environment(WorkspaceManager.self) var workspace
    @Environment(TerminalManager.self) var terminal
    @Environment(\.openWindow) var openWindow

    @State private var selectedNode: FileNode?
    @State private var fileContent: String = ""
    @State private var savedContent: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var lineDiffs: [GitLineDiff] = []

    private var hasUnsavedChanges: Bool {
        fileContent != savedContent
    }

    private var currentFileName: String {
        let name = fileURL?.lastPathComponent ?? "Pine"
        return hasUnsavedChanges ? "● \(name)" : name
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
        .navigationSubtitle(workspace.gitProvider.isGitRepository ? "⎇ \(workspace.gitProvider.currentBranch)" : "")
        .background(WindowBridge(
            representedURL: fileURL,
            isDocumentEdited: hasUnsavedChanges,
            onSave: { [self] in saveFile() }
        ))
        .onAppear {
            if let url = fileURL {
                loadFileFromURL(url)
            }
        }
        .onChange(of: fileURL) { _, newURL in
            if let url = newURL {
                loadFileFromURL(url)
            }
        }
        .onChange(of: selectedNode) { _, newNode in
            guard let node = newNode, !node.isDirectory else { return }
            handleFileSelection(node)
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
                Label("No File Selected", systemImage: "doc.text")
            } description: {
                Text("Select a file from the sidebar")
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
            .help("New Terminal")

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
            .help(terminal.isTerminalMaximized ? "Restore Terminal" : "Maximize Terminal")

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
            .help("Hide Terminal")
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
            if workspace.rootNodes.isEmpty {
                List {
                    ContentUnavailableView {
                        Label("No Folder Open", systemImage: "folder")
                    } description: {
                        Text("Open a folder to get started")
                    } actions: {
                        Button("Open Folder...") {
                            workspace.openFolder()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .navigationTitle("Files")
            } else {
                List(workspace.rootNodes, children: \.optionalChildren, selection: $selectedFile) { node in
                    FileNodeRow(node: node)
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
                .help("Open Folder")
            }
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
        Label(node.name, systemImage: node.isDirectory ? "folder" : iconForFile(node.name))
            .foregroundStyle(gitStatus?.color ?? .primary)
            .tag(node)
    }

    private func iconForFile(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":                          return "swift"
        case "js", "ts", "jsx", "tsx":         return "doc.text"
        case "json":                           return "curlybraces"
        case "md", "txt":                      return "doc.plaintext"
        case "html", "css":                    return "globe"
        case "py":                             return "doc.text"
        case "png", "jpg", "jpeg", "gif":      return "photo"
        default:                               return "doc"
        }
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
                            Label("\(counts.modified)", systemImage: "pencil")
                                .foregroundStyle(.orange)
                        }
                        if counts.added > 0 {
                            Label("\(counts.added)", systemImage: "plus")
                                .foregroundStyle(.green)
                        }
                        if counts.untracked > 0 {
                            Label("\(counts.untracked)", systemImage: "questionmark")
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
                    Text("Terminal")
                        .font(.system(size: 11))
                }
                .foregroundStyle(terminal.isTerminalVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(terminal.isTerminalVisible ? "Hide Terminal (⌘`)" : "Show Terminal (⌘`)")
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
