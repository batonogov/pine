//
//  StatusBarView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

// MARK: - Status Bar

struct StatusBarView: View {
    var gitProvider: GitStatusProvider
    var terminal: TerminalManager
    var tabManager: TabManager
    var progress: ProgressTracker?

    var body: some View {
        HStack(spacing: LayoutMetrics.statusBarItemSpacing) {
            if let progress, progress.isLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(verbatim: progress.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityIdentifier(AccessibilityID.progressIndicator)
            }

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
                    .font(.system(size: LayoutMetrics.captionFontSize))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        AccessibilityLabels.gitStatusDescription(
                            modified: counts.modified,
                            added: counts.added,
                            untracked: counts.untracked
                        )
                    )
                }
            }

            Spacer()

            if let activeTab = tabManager.activeTab, activeTab.kind == .text {
                // Line / Column indicator (cached in EditorTab by TabManager)
                Text(verbatim: "Ln \(activeTab.cursorLine), Col \(activeTab.cursorColumn)")
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.cursorPosition)
                    .accessibilityLabel(AccessibilityLabels.cursorPosition)
                    .accessibilityValue(
                        AccessibilityLabels.cursorPositionValue(
                            line: activeTab.cursorLine,
                            column: activeTab.cursorColumn
                        )
                    )

                statusDivider

                // Indentation style indicator (cached, recomputed on content change)
                Text(verbatim: activeTab.cachedIndentation.displayName)
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.indentationIndicator)
                    .accessibilityLabel(AccessibilityLabels.indentation)
                    .accessibilityValue(activeTab.cachedIndentation.displayName)

                statusDivider

                // Line ending indicator (cached, recomputed on content change)
                Text(verbatim: activeTab.cachedLineEnding.displayName)
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.lineEndingIndicator)
                    .accessibilityLabel(AccessibilityLabels.lineEnding)
                    .accessibilityValue(activeTab.cachedLineEnding.displayName)

                statusDivider

                // File encoding indicator with menu to change encoding
                Menu {
                    ForEach(String.Encoding.availableEncodings, id: \.rawValue) { encoding in
                        Button {
                            tabManager.reopenActiveTab(withEncoding: encoding)
                        } label: {
                            HStack {
                                Text(encoding.displayName)
                                if encoding == activeTab.encoding {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(activeTab.encoding.displayName)
                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(activeTab.isDirty)
                .accessibilityIdentifier(AccessibilityID.encodingMenu)
                .accessibilityLabel(AccessibilityLabels.encoding)
                .accessibilityValue(activeTab.encoding.displayName)

                // File size indicator (cached in EditorTab)
                if let size = activeTab.fileSizeBytes {
                    statusDivider

                    Text(verbatim: FileSizeFormatter.format(size))
                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.fileSizeIndicator)
                        .accessibilityLabel(AccessibilityLabels.fileSize)
                        .accessibilityValue(FileSizeFormatter.format(size))
                }
            }

            // Terminal toggle button
            Button {
                withAnimation(PineAnimation.quick) { terminal.isTerminalVisible.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: terminal.isTerminalVisible
                          ? "chevron.down" : "chevron.up")
                        .font(.system(size: LayoutMetrics.iconSmallFontSize, weight: .semibold))
                    Image(systemName: "terminal")
                        .font(.system(size: LayoutMetrics.captionFontSize))
                    Text(Strings.terminalLabel)
                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                }
                .foregroundStyle(terminal.isTerminalVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(terminal.isTerminalVisible ? Strings.hideTerminalShortcut : Strings.showTerminalShortcut)
            .accessibilityIdentifier(AccessibilityID.terminalToggleButton)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(AccessibilityLabels.terminalToggle)
            .accessibilityHint(AccessibilityLabels.terminalToggleHint(isVisible: terminal.isTerminalVisible))
        }
        .padding(.horizontal, LayoutMetrics.statusBarHorizontalPadding)
        .frame(height: LayoutMetrics.statusBarHeight)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AccessibilityLabels.statusBar)
        .accessibilityAddTraits(.isSummaryElement)
        .accessibilityIdentifier(AccessibilityID.statusBar)
    }

    private var statusDivider: some View {
        Text(verbatim: "·")
            .font(.system(size: LayoutMetrics.bodySmallFontSize))
            .foregroundStyle(.quaternary)
            .accessibilityHidden(true)
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
