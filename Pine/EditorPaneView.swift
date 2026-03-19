//
//  EditorPaneView.swift
//  Pine
//
//  Reusable editor pane: tab bar + code editor / preview.
//  Used by both primary and secondary split panes in ContentView.
//

import SwiftUI

struct EditorPaneView: View {
    let tabs: [EditorTab]
    let activeTab: EditorTab?
    let activeTabID: UUID?
    let isFocused: Bool
    let lineDiffs: [GitLineDiff]
    let isMinimapVisible: Bool
    let goToLineOffset: Int?

    let onSelectTab: (UUID) -> Void
    let onCloseTab: (EditorTab) -> Void
    let onContentChange: (String) -> Void
    let onStateChange: (Int, CGFloat) -> Void
    let onReorder: ([EditorTab]) -> Void
    let onTogglePreview: () -> Void
    let onSplitRight: (() -> Void)?
    let onOpenInSplit: ((URL) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if !tabs.isEmpty {
                EditorTabBar(
                    tabs: tabs,
                    activeTabID: activeTabID,
                    onSelectTab: onSelectTab,
                    onCloseTab: onCloseTab,
                    onReorder: onReorder,
                    isMarkdownFile: activeTab?.isMarkdownFile ?? false,
                    previewMode: activeTab?.previewMode ?? .source,
                    onTogglePreview: onTogglePreview,
                    onSplitRight: onSplitRight,
                    onOpenInSplit: onOpenInSplit
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
        .overlay(alignment: .top) {
            if isFocused {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private func codeEditorView(for tab: EditorTab) -> some View {
        CodeEditorView(
            text: Binding(
                get: { tab.content },
                set: { onContentChange($0) }
            ),
            contentVersion: tab.contentVersion,
            language: tab.language,
            fileName: tab.fileName,
            lineDiffs: lineDiffs,
            isMinimapVisible: isMinimapVisible,
            syntaxHighlightingDisabled: tab.syntaxHighlightingDisabled,
            initialCursorPosition: goToLineOffset ?? tab.cursorPosition,
            initialScrollOffset: goToLineOffset != nil ? 0 : tab.scrollOffset,
            onStateChange: { cursor, scroll in
                onStateChange(cursor, scroll)
            },
            fontSize: FontSizeSettings.shared.fontSize
        )
        .accessibilityIdentifier(AccessibilityID.codeEditor)
    }
}
