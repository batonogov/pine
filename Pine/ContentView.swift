//
//  ContentView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = FileTreeViewModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isTerminalVisible = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel)
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
        .onReceive(NotificationCenter.default.publisher(for: .saveFile)) { _ in
            viewModel.saveCurrentFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
            viewModel.openFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTerminal)) { _ in
            withAnimation { isTerminalVisible.toggle() }
        }
    }

    // MARK: - Область редактора (TabBar + CodeEditor)

    @ViewBuilder
    private var editorArea: some View {
        VStack(spacing: 0) {
            // Панель вкладок — показываем только когда есть открытые файлы
            if !viewModel.openTabs.isEmpty {
                EditorTabBar(viewModel: viewModel)
                    .zIndex(1) // Поверх редактора
            }

            // Содержимое редактора
            if let tab = viewModel.activeTab {
                CodeEditorView(
                    text: Binding(
                        get: { viewModel.activeTabContent },
                        set: { viewModel.activeTabContent = $0 }
                    ),
                    language: (tab.name as NSString).pathExtension.lowercased(),
                    fileName: tab.name
                )
            } else {
                ContentUnavailableView {
                    Label("No File Selected", systemImage: "doc.text")
                } description: {
                    Text("Select a file from the sidebar")
                }
            }
        }
    }

    // MARK: - Область терминала (TabBar + Terminal)

    @ViewBuilder
    private var terminalArea: some View {
        VStack(spacing: 0) {
            TerminalTabBar(viewModel: viewModel, isVisible: $isTerminalVisible)

            // Содержимое активного терминала — реальный zsh через PTY
            if let tab = viewModel.activeTerminalTab {
                TerminalContentView(session: tab.session)
                    .id(tab.id)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Запускаем терминалы при появлении view
        .onAppear { viewModel.startTerminals() }
    }
}

// MARK: - Панель вкладок редактора

struct EditorTabBar: View {
    @Bindable var viewModel: FileTreeViewModel

    var body: some View {
        // ScrollView горизонтальный — вкладки скроллятся, если их много
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(viewModel.openTabs) { tab in
                    EditorTabItem(
                        tab: tab,
                        isActive: tab.id == viewModel.activeTabID,
                        onSelect: { viewModel.activeTabID = tab.id },
                        onClose: { viewModel.closeTab(tab) }
                    )
                }
            }
        }
        .background(.bar)
        .frame(height: 30)
        .fixedSize(horizontal: false, vertical: true)
        .alert(
            "Unsaved Changes",
            isPresented: Binding(
                get: { viewModel.tabPendingClose != nil },
                set: { if !$0 { viewModel.tabPendingClose = nil } }
            )
        ) {
            Button("Save") {
                if let tab = viewModel.tabPendingClose {
                    viewModel.saveAndCloseTab(tab)
                    viewModel.tabPendingClose = nil
                }
            }
            Button("Don't Save", role: .destructive) {
                if let tab = viewModel.tabPendingClose {
                    viewModel.forceCloseTab(tab)
                    viewModel.tabPendingClose = nil
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.tabPendingClose = nil
            }
        } message: {
            if let tab = viewModel.tabPendingClose {
                Text("Do you want to save changes to \"\(tab.name)\"?")
            }
        }
    }
}

/// Одна вкладка в панели редактора.
struct EditorTabItem: View {
    let tab: EditorTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    // Показываем крестик при наведении мыши
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            // Крестик закрытия или индикатор несохранённых изменений
            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if tab.hasUnsavedChanges {
                Circle()
                    .fill(.secondary)
                    .frame(width: 8, height: 8)
            } else {
                // Невидимый placeholder для стабильной ширины
                Color.clear.frame(width: 9, height: 9)
            }

            // Иконка файла + имя
            Image(systemName: iconForFile(tab.name))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(tab.name)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.primary.opacity(0.1) : .clear)
        // Тонкий разделитель справа между вкладками
        .overlay(alignment: .trailing) {
            Divider().frame(height: 16)
        }
        .contentShape(Rectangle()) // Вся область кликабельна
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private func iconForFile(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":                      return "swift"
        case "js", "ts", "jsx", "tsx":     return "doc.text"
        case "json":                       return "curlybraces"
        case "md", "txt":                  return "doc.plaintext"
        case "html", "css":                return "globe"
        case "py":                         return "doc.text"
        default:                           return "doc"
        }
    }
}

// MARK: - Панель вкладок терминала

struct TerminalTabBar: View {
    @Bindable var viewModel: FileTreeViewModel
    @Binding var isVisible: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Крестик закрытия всей панели терминала — слева
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
                    ForEach(viewModel.terminalTabs) { tab in
                        TerminalTabItem(
                            tab: tab,
                            isActive: tab.id == viewModel.activeTerminalID,
                            // Закрытие доступно только если терминалов > 1
                            canClose: viewModel.terminalTabs.count > 1,
                            onSelect: { viewModel.activeTerminalID = tab.id },
                            onClose: { viewModel.closeTerminalTab(tab) }
                        )
                    }
                }
            }

            Spacer()

            // Кнопка "+" — добавить новый терминал
            Button {
                viewModel.addTerminalTab()
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
    @Bindable var viewModel: FileTreeViewModel

    var body: some View {
        List(selection: $viewModel.selectedFile) {
            if viewModel.rootNodes.isEmpty {
                ContentUnavailableView {
                    Label("No Folder Open", systemImage: "folder")
                } description: {
                    Text("Open a folder to get started")
                } actions: {
                    Button("Open Folder...") {
                        viewModel.openFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Section(viewModel.projectName) {
                    ForEach(viewModel.rootNodes) { node in
                        FileNodeRow(node: node, viewModel: viewModel)
                    }
                }
            }
        }
        .onChange(of: viewModel.selectedFile) { _, newFile in
            if let file = newFile {
                viewModel.selectFile(file)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Files")
        .frame(minWidth: 180, idealWidth: 220)
        .toolbar {
            ToolbarItem {
                Button {
                    viewModel.openFolder()
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
    var viewModel: FileTreeViewModel

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
                    FileNodeRow(node: child, viewModel: viewModel)
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
    ContentView()
}
