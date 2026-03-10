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
    @Environment(ProjectManager.self) var projectManager
    @Environment(\.openWindow) var openWindow

    @State private var selectedNode: FileNode?
    @State private var fileContent: String = ""
    @State private var savedContent: String = ""
    @State private var isTerminalVisible = false
    @State private var terminalTabs: [TerminalTab] = [TerminalTab(name: "Terminal")]
    @State private var activeTerminalID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var hasUnsavedChanges: Bool {
        fileContent != savedContent
    }

    private var currentFileName: String {
        let name = fileURL?.lastPathComponent ?? "Pine"
        return hasUnsavedChanges ? "● \(name)" : name
    }

    private var activeTerminalTab: TerminalTab? {
        guard let id = activeTerminalID else { return nil }
        return terminalTabs.first(where: { $0.id == id })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(projectManager: projectManager, selectedFile: $selectedNode)
        } detail: {
            if isTerminalVisible {
                VSplitView {
                    editorArea
                        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                    terminalArea
                        .frame(maxWidth: .infinity, minHeight: 100, idealHeight: 150, maxHeight: .infinity)
                }
            } else {
                editorArea
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle(currentFileName)
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
            projectManager.openFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTerminal)) { _ in
            withAnimation { isTerminalVisible.toggle() }
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
        } catch {
            let errorText = "// Error: \(error.localizedDescription)"
            fileContent = errorText
            savedContent = errorText
        }
    }

    private func saveFile() {
        guard let url = fileURL else { return }
        do {
            try fileContent.write(to: url, atomically: true, encoding: .utf8)
            savedContent = fileContent
            NSApp.keyWindow?.isDocumentEdited = false
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
                fileName: currentFileName
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
            TerminalTabBar(
                terminalTabs: terminalTabs,
                activeTerminalID: $activeTerminalID,
                isVisible: $isTerminalVisible,
                onAdd: { addTerminalTab() },
                onClose: { tab in closeTerminalTab(tab) }
            )

            if let tab = activeTerminalTab {
                TerminalContentView(session: tab.session)
                    .id(tab.id)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { startTerminals() }
    }

    // MARK: - Управление терминалами

    private func startTerminals() {
        for tab in terminalTabs where !tab.session.isRunning {
            tab.session.start(workingDirectory: projectManager.rootURL)
        }
        if activeTerminalID == nil {
            activeTerminalID = terminalTabs.first?.id
        }
    }

    private func addTerminalTab() {
        let number = terminalTabs.count + 1
        let tab = TerminalTab(name: "Terminal \(number)")
        tab.session.start(workingDirectory: projectManager.rootURL)
        terminalTabs.append(tab)
        activeTerminalID = tab.id
    }

    private func closeTerminalTab(_ tab: TerminalTab) {
        tab.session.stop()
        terminalTabs.removeAll { $0.id == tab.id }
        if activeTerminalID == tab.id {
            activeTerminalID = terminalTabs.last?.id
        }
    }
}

// MARK: - Панель вкладок терминала

struct TerminalTabBar: View {
    let terminalTabs: [TerminalTab]
    @Binding var activeTerminalID: UUID?
    @Binding var isVisible: Bool
    let onAdd: () -> Void
    let onClose: (TerminalTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Крестик закрытия панели терминала
            Button {
                withAnimation { isVisible = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .help("Hide Terminal")

            // Вкладки терминалов
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(terminalTabs) { tab in
                        TerminalTabItem(
                            tab: tab,
                            isActive: tab.id == activeTerminalID,
                            canClose: terminalTabs.count > 1,
                            onSelect: { activeTerminalID = tab.id },
                            onClose: { onClose(tab) }
                        )
                    }
                }
            }

            Spacer()

            // Кнопка "+" — добавить новый терминал
            Button {
                onAdd()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .help("New Terminal")
        }
        .frame(height: 28)
        .background(.bar)
    }
}

/// Одна вкладка терминала.
struct TerminalTabItem: View {
    let tab: TerminalTab
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovering || isActive ? 1 : 0)
            }

            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(tab.name)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.primary.opacity(0.1) : .clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Сайдбар

struct SidebarView: View {
    var projectManager: ProjectManager
    @Binding var selectedFile: FileNode?

    var body: some View {
        List(selection: $selectedFile) {
            if projectManager.rootNodes.isEmpty {
                ContentUnavailableView {
                    Label("No Folder Open", systemImage: "folder")
                } description: {
                    Text("Open a folder to get started")
                } actions: {
                    Button("Open Folder...") {
                        projectManager.openFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Section(projectManager.projectName) {
                    ForEach(projectManager.rootNodes) { node in
                        FileNodeRow(node: node)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Files")
        .frame(minWidth: 180, idealWidth: 220)
        .toolbar {
            ToolbarItem {
                Button {
                    projectManager.openFolder()
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

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { !(node.children?.isEmpty ?? true) || expandedState },
                    set: { isExpanded in
                        expandedState = isExpanded
                        if isExpanded { node.loadChildren() }
                    }
                )
            ) {
                ForEach(node.children ?? []) { child in
                    FileNodeRow(node: child)
                }
            } label: {
                Label(node.name, systemImage: "folder")
                    .foregroundStyle(.primary)
            }
        } else {
            Label(node.name, systemImage: iconForFile(node.name))
                .tag(node)
        }
    }

    @State private var expandedState = false

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

#Preview {
    @Previewable @State var url: URL? = nil
    ContentView(fileURL: $url)
        .environment(ProjectManager())
}
