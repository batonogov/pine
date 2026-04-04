//
//  EditorAreaView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Editor area

struct EditorAreaView: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(ProjectManager.self) private var projectManager
    @Environment(PaneManager.self) private var paneManager
    @Environment(ProjectRegistry.self) private var registry
    @Binding var lineDiffs: [GitLineDiff]
    @Binding var isDragTargeted: Bool
    @Binding var goToLineOffset: GoToRequest?
    var isBlameVisible: Bool
    var blameLines: [GitBlameLine]
    var isMinimapVisible: Bool
    var isWordWrapEnabled: Bool
    var diffHunks: [DiffHunk] = []
    var onCloseTab: (EditorTab) -> Void
    var onCloseOtherTabs: ((UUID) -> Void)?
    var onCloseTabsToTheRight: ((UUID) -> Void)?
    var onCloseAllTabs: (() -> Void)?
    var onSaveSession: () -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var dropZone: PaneDropZone?
    @State private var viewSize: CGSize = .zero

    @State private var configValidator = ConfigValidator()

    private var activeTab: EditorTab? { tabManager.activeTab }

    var body: some View {
        VStack(spacing: 0) {
            if !tabManager.tabs.isEmpty {
                EditorTabBar(
                    tabManager: tabManager,
                    onCloseTab: { tab in onCloseTab(tab) },
                    onCloseOtherTabs: onCloseOtherTabs,
                    onCloseTabsToTheRight: onCloseTabsToTheRight,
                    onCloseAllTabs: onCloseAllTabs,
                    onReorder: { onSaveSession() },
                    isMarkdownFile: activeTab?.isMarkdownFile ?? false,
                    previewMode: activeTab?.previewMode ?? .source,
                    onTogglePreview: { tabManager.togglePreviewMode() },
                    isAutoSaving: tabManager.isAutoSaving,
                    projectRootURL: workspace.rootURL
                )
            }

            if let tab = activeTab, let rootURL = workspace.rootURL {
                BreadcrumbPathBar(
                    fileURL: tab.url,
                    projectRoot: rootURL,
                    onOpenFile: { url in tabManager.openTab(url: url) }
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
                .contentTransition(.identity)

            } else {
                ContentUnavailableView {
                    Label(Strings.noFileSelected, systemImage: "doc.text")
                } description: {
                    Text(Strings.selectFilePrompt)
                }
                .accessibilityIdentifier(AccessibilityID.editorPlaceholder)
            }
        }
        .overlay {
            if isDragTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.blue, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .preference(key: EditorAreaSizeKey.self, value: geometry.size)
            }
        }
        .onPreferenceChange(EditorAreaSizeKey.self) { viewSize = $0 }
        .overlay {
            PaneDropOverlay(dropZone: dropZone)
        }
        .onDrop(of: [.fileURL, .paneTabDrag], delegate: EditorAreaUnifiedDropDelegate(
            paneManager: paneManager,
            dropZone: $dropZone,
            isDragTargeted: $isDragTargeted,
            viewSize: viewSize,
            onFileDrop: { providers in handleFileDrop(providers: providers) }
        ))
    }

    @ViewBuilder
    private func codeEditorView(for tab: EditorTab) -> some View {
        CodeEditorView(
            text: Binding(
                get: { tab.content },
                set: { tabManager.updateContent($0) }
            ),
            contentVersion: tab.contentVersion,
            language: tab.language,
            fileName: tab.fileName,
            lineDiffs: lineDiffs,
            diffHunks: diffHunks,
            validationDiagnostics: configValidator.diagnostics,
            isBlameVisible: isBlameVisible,
            blameLines: blameLines,
            foldState: Binding(
                get: { tab.foldState },
                set: { tabManager.updateFoldState($0) }
            ),
            isMinimapVisible: isMinimapVisible,
            isWordWrapEnabled: isWordWrapEnabled,
            syntaxHighlightingDisabled: tab.syntaxHighlightingDisabled,
            initialCursorPosition: goToLineOffset?.offset ?? tab.cursorPosition,
            initialScrollOffset: goToLineOffset != nil ? 0 : tab.scrollOffset,
            onStateChange: { cursor, scroll in
                tabManager.updateEditorState(cursorPosition: cursor, scrollOffset: scroll)
            },
            onHighlightCacheUpdate: { result in
                tabManager.updateHighlightCache(result)
            },
            cachedHighlightResult: tab.cachedHighlightResult,
            goToOffset: goToLineOffset,
            indentStyle: tab.cachedIndentation,
            fontSize: FontSizeSettings.shared.fontSize
        )
        .id(tab.id)
        .accessibilityIdentifier(AccessibilityID.codeEditor)
        .onAppear {
            goToLineOffset = nil
            configValidator.validate(url: tab.url, content: tab.content)
        }
        .onDisappear {
            configValidator.clear()
        }
        .onChange(of: tab.content) { _, newValue in
            configValidator.validate(url: tab.url, content: newValue)
        }
    }

    // MARK: - Drag & Drop

    /// Handles file URLs dropped onto the editor area.
    /// Files are opened as tabs; directories open as new project windows.
    private func handleFileDrop(providers: [NSItemProvider]) {
        for provider in providers {
            Task {
                guard let url = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) as? URL else { return }

                let classified = DropHandler.classifyURLs([url])

                await MainActor.run {
                    // Open directories as new project windows
                    for dir in classified.directories {
                        let canonical = dir.resolvingSymlinksInPath()
                        guard registry.projectManager(for: canonical) != nil else { continue }
                        openWindow(value: canonical)
                    }
                    // Open files as tabs in current project
                    DropHandler.openFilesAsTabs(classified.files, in: tabManager)
                }
            }
        }
    }
}

// MARK: - Single Pane Split Drop Delegate

/// Preference key for tracking the editor area size.
private struct EditorAreaSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Unified drop delegate for the single-pane editor area.
/// Handles both file drops from Finder (.fileURL) and pane tab drags (.paneTabDrag)
/// in a single handler to avoid two `.onDrop` modifiers conflicting.
struct EditorAreaUnifiedDropDelegate: DropDelegate {
    let paneManager: PaneManager
    @Binding var dropZone: PaneDropZone?
    @Binding var isDragTargeted: Bool
    let viewSize: CGSize
    let onFileDrop: ([NSItemProvider]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.paneTabDrag]) || info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        if info.hasItemsConforming(to: [.paneTabDrag]) {
            updateDropZone(info: info)
        } else {
            isDragTargeted = true
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if info.hasItemsConforming(to: [.paneTabDrag]) {
            updateDropZone(info: info)
        }
        return DropProposal(operation: info.hasItemsConforming(to: [.paneTabDrag]) ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        dropZone = nil
        isDragTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isDragTargeted = false

        // Pane tab drag takes priority
        if info.hasItemsConforming(to: [.paneTabDrag]) {
            return handlePaneTabDrop(info: info)
        }

        // File drop from Finder
        if info.hasItemsConforming(to: [.fileURL]) {
            onFileDrop(info.itemProviders(for: [.fileURL]))
            return true
        }

        return false
    }

    // MARK: - Pane tab drop

    private func handlePaneTabDrop(info: DropInfo) -> Bool {
        guard let zone = dropZone else { return false }
        dropZone = nil

        // Use synchronous shared drag state instead of async NSItemProvider
        guard let dragInfo = paneManager.activeDrag else { return false }
        paneManager.activeDrag = nil

        guard let firstLeafID = paneManager.root.firstLeafID else { return false }
        let sourcePaneID = PaneID(id: dragInfo.paneID)

        switch zone {
        case .right:
            paneManager.splitPane(
                firstLeafID,
                axis: .horizontal,
                tabURL: dragInfo.fileURL,
                sourcePane: sourcePaneID
            )
        case .bottom:
            paneManager.splitPane(
                firstLeafID,
                axis: .vertical,
                tabURL: dragInfo.fileURL,
                sourcePane: sourcePaneID
            )
        case .center:
            break
        }
        return true
    }

    private func updateDropZone(info: DropInfo) {
        dropZone = PaneDropZone.zone(for: info.location, in: viewSize)
    }
}
