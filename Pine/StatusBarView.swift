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
                            .font(.caption2)
                            // The severity is already in `description`; the
                            // glyph would only add an unnamed image stop.
                            .accessibilityHidden(true)
                        Text(verbatim: summary.description)
                            .font(.subheadline)
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
                        .font(.subheadline)
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
                        .font(.caption2)
                        .foregroundStyle(waitingCount > 0 ? .orange : .secondary)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                // The badge is the whole signal, and it is drawn only. How
                // many agents are waiting has to be said, not shown (#1527).
                .accessibilityLabel(Strings.agentAttentionTitle)
                .accessibilityValue(
                    Strings.agentInboxToolbarAttentionCount(waitingCount)
                )
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
                            .gitCountAccessibility(
                                label: Strings.a11yStatusBarModifiedCount(
                                    counts.modified
                                ),
                                identifier: AccessibilityID
                                    .gitStatusModifiedCount
                            )
                        }
                        if counts.added > 0 {
                            Label {
                                Text(verbatim: "\(counts.added)")
                            } icon: {
                                Image(systemName: "plus")
                            }
                            .foregroundStyle(.green)
                            .gitCountAccessibility(
                                label: Strings.a11yStatusBarAddedCount(
                                    counts.added
                                ),
                                identifier: AccessibilityID.gitStatusAddedCount
                            )
                        }
                        if counts.untracked > 0 {
                            Label {
                                Text(verbatim: "\(counts.untracked)")
                            } icon: {
                                Image(systemName: "questionmark")
                            }
                            .foregroundStyle(.teal)
                            .gitCountAccessibility(
                                label: Strings.a11yStatusBarUntrackedCount(
                                    counts.untracked
                                ),
                                identifier: AccessibilityID
                                    .gitStatusUntrackedCount
                            )
                        }
                    }
                    .font(.caption2)
                    // `children: .contain` keeps the three counts as separate
                    // stops. Combining them would read one run-on phrase and
                    // lose the per-kind identifiers UI tests navigate by.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Strings.a11yStatusBarGitSummary)
                    .accessibilityIdentifier(AccessibilityID.gitStatusSummary)
                }
            }

            Spacer()

            if let activeTab = tabManager.activeTab, activeTab.kind == .text {
                // Line / Column indicator (cached in EditorTab by TabManager)
                Text(
                    verbatim: Strings.statusbarCursorPosition(
                        line: activeTab.cursorLine,
                        column: activeTab.cursorColumn
                    )
                )
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    // "Ln" and "Col" are drawn abbreviations; VoiceOver
                    // pronounces them as words. The name stays constant so a
                    // moving cursor announces as a value change.
                    .accessibilityLabel(Strings.a11yStatusBarCursorPosition)
                    .accessibilityValue(
                        Strings.a11yStatusBarCursorPositionValue(
                            line: activeTab.cursorLine,
                            column: activeTab.cursorColumn
                        )
                    )
                    .accessibilityIdentifier(AccessibilityID.cursorPosition)

                statusDivider

                // Indentation style indicator (cached, recomputed on content change)
                Text(verbatim: activeTab.cachedIndentation.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Strings.a11yStatusBarIndentation)
                    .accessibilityValue(activeTab.cachedIndentation.displayName)
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
                        .font(.subheadline)
                        .lineLimit(1)
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
                        .font(.subheadline)
                        .lineLimit(1)
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
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Strings.a11yStatusBarFileSize)
                        .accessibilityValue(FileSizeFormatter.format(size))
                        .accessibilityIdentifier(AccessibilityID.fileSizeIndicator)
                }
            }

            // Terminal toggle button
            Button {
                onToggleTerminal?()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "terminal")
                        .font(.caption2)
                    Text(Strings.terminalLabel)
                        .font(.subheadline)
                }
                .foregroundStyle(paneManager.terminalPaneIDs.isEmpty ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.terminalToggleButton)
            .accessibilityHint(Strings.a11yTerminalToggleHint)
        }
        .padding(.horizontal, LayoutMetrics.statusBarHorizontalPadding)
        .frame(minHeight: LayoutMetrics.statusBarHeight)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.a11yStatusBarLabel)
        .accessibilityIdentifier(AccessibilityID.statusBar)
    }

    private var statusDivider: some View {
        Text(verbatim: "·")
            .font(.subheadline)
            .foregroundStyle(.quaternary)
            // A drawn gap, not content. Published, it lands between every
            // pair of indicators as an "interpunct" VoiceOver reads aloud.
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

// MARK: - Git count accessibility

private extension View {
    /// Replaces a git count's contents with one named announcement.
    ///
    /// The count has to live in the *label*: macOS drops
    /// `.accessibilityValue` on an element whose bridged role is
    /// `AXUnknown`, which is what a `Label` collapsed with
    /// `children: .ignore` becomes. Split across label and value, VoiceOver
    /// would announce the kind and silently swallow the number.
    func gitCountAccessibility(
        label: String,
        identifier: String
    ) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}
