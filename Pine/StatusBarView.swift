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
    var paneManager: PaneManager
    var tabManager: TabManager
    var terminalManager: TerminalManager? = nil
    var progress: ProgressTracker?
    var onToggleTerminal: (() -> Void)?
    /// LSP / validator diagnostics summary for the Problems indicator (#1010).
    /// `nil` hides the indicator (e.g. no project loaded).
    var diagnosticsSummary: DiagnosticsSummary?
    /// Called when the user clicks the Problems indicator to toggle the panel.
    var onToggleProblems: (() -> Void)?
    /// Called when the user clicks the agent attention bell to open the
    /// attention-list overlay (#1112).
    var onShowAttention: (() -> Void)?

    /// Active AI agent sessions across all terminal panes (#952).
    /// Empty when no agent is running → `AgentStatusBarItem` is hidden.
    private var agentSummaries: [AgentStatusSummary] {
        AgentStatusSummary.activeSummaries(in: paneManager)
    }

    var body: some View {
        // Compute once per render: StatusBarView re-renders on every cursor move,
        // and walking the pane/tab tree twice (isEmpty check + arg) is wasteful.
        let summaries = agentSummaries
        return HStack(spacing: LayoutMetrics.statusBarItemSpacing) {
            // Problems indicator (#1010): click to toggle the Problems panel.
            // Hidden when there are zero diagnostics *and* no panel is open.
            if let summary = diagnosticsSummary, summary.total > 0 {
                Button {
                    onToggleProblems?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: summary.errorCount > 0 ? "xmark.octagon.fill" : "exclamationmark.bubble.fill")
                            .font(.system(size: LayoutMetrics.captionFontSize))
                        Text(verbatim: summary.description)
                            .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    }
                    .foregroundStyle(summary.errorCount > 0 ? .red : .orange)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.problemsIndicator)
            }

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

            // Agent attention bell (#1112): amber + filled when any agent is
            // blocked waiting for input (permission prompt / reply), plain
            // when agents are merely active, hidden when none are running or
            // every agent is idle. Clicking opens the attention-list overlay.
            //
            // Stale and terminated summaries remain visible in the adjacent
            // session item, but never drive this actionable attention signal.
            let waitingCount = summaries.filter(\.needsAttention).count
            let hasActive = summaries.contains(where: \.isActivelyWorking)
            if waitingCount > 0 || hasActive {
                Button {
                    onShowAttention?()
                } label: {
                    Image(systemName: waitingCount > 0 ? "bell.badge.fill" : "bell")
                        .font(.system(size: LayoutMetrics.captionFontSize))
                        .foregroundStyle(waitingCount > 0 ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.agentAttentionBell)
            }

            if !summaries.isEmpty {
                AgentStatusBarItem(summaries: summaries) { paneID, tabID in
                    if let terminalManager {
                        _ = terminalManager.activateTerminal(
                            paneID: paneID,
                            tabID: tabID
                        )
                    } else {
                        _ = paneManager.selectTerminalTab(tabID, in: paneID)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.agentStatusBar)
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
                }
            }

            Spacer()

            if let activeTab = tabManager.activeTab, activeTab.kind == .text {
                // Line / Column indicator (cached in EditorTab by TabManager)
                Text(verbatim: "Ln \(activeTab.cursorLine), Col \(activeTab.cursorColumn)")
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.cursorPosition)

                statusDivider

                // Indentation style indicator (cached, recomputed on content change)
                Text(verbatim: activeTab.cachedIndentation.displayName)
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.indentationIndicator)

                statusDivider

                // Line ending indicator with conversion menu
                Menu {
                    ForEach([LineEnding.lf, .crlf], id: \.self) { ending in
                        Button {
                            tabManager.convertActiveTabLineEndings(to: ending)
                        } label: {
                            HStack {
                                Text(ending.displayName)
                                if ending == activeTab.cachedLineEnding {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(verbatim: activeTab.cachedLineEnding.displayName)
                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier(AccessibilityID.lineEndingIndicator)

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
                .help(activeTab.isDirty ? Strings.statusbarEncodingDisabledDirty : "")
                .accessibilityIdentifier(AccessibilityID.encodingMenu)

                // File size indicator (cached in EditorTab)
                if let size = activeTab.fileSizeBytes {
                    statusDivider

                    Text(verbatim: FileSizeFormatter.format(size))
                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.fileSizeIndicator)
                }
            }

            // Terminal toggle button
            Button {
                onToggleTerminal?()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "terminal")
                        .font(.system(size: LayoutMetrics.captionFontSize))
                    Text(Strings.terminalLabel)
                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                }
                .foregroundStyle(paneManager.terminalPaneIDs.isEmpty ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.terminalToggleButton)
        }
        .padding(.horizontal, LayoutMetrics.statusBarHorizontalPadding)
        .frame(height: LayoutMetrics.statusBarHeight)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.statusBar)
    }

    private var statusDivider: some View {
        Text(verbatim: "·")
            .font(.system(size: LayoutMetrics.bodySmallFontSize))
            .foregroundStyle(.quaternary)
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
