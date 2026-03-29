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
    @Environment(ProjectRegistry.self) private var registry
    @Binding var lineDiffs: [GitLineDiff]
    @Binding var isDragTargeted: Bool
    @Binding var goToLineOffset: GoToRequest?
    var isBlameVisible: Bool
    var blameLines: [GitBlameLine]
    var isMinimapVisible: Bool
    var isWordWrapEnabled: Bool
    var onCloseTab: (EditorTab) -> Void
    var onCloseOtherTabs: ((UUID) -> Void)?
    var onCloseTabsToTheRight: ((UUID) -> Void)?
    var onCloseAllTabs: (() -> Void)?
    var onSaveSession: () -> Void

    @Environment(\.openWindow) private var openWindow

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
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleFileDrop(providers: providers)
            return true
        }
        .overlay {
            if isDragTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.blue, lineWidth: 2)
                    .allowsHitTesting(false)
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
            contentVersion: tab.contentVersion,
            language: tab.language,
            fileName: tab.fileName,
            lineDiffs: lineDiffs,
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
        .onAppear { goToLineOffset = nil }
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
