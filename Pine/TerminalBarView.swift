//
//  TerminalBarView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

// MARK: - Terminal native tab bar (macOS window tab style)

// Legacy terminal tab bar removed — terminal panes use TerminalPaneTabBar instead.

// MARK: - Agent badge (issue #951)

/// Colored badge displayed on a terminal tab when an AI agent is detected.
/// Shows:
/// - amber `exclamationmark.circle.fill` when the agent is blocked waiting
///   for input (permission prompt / reply) — the per-tab "needs attention"
///   signal (#1112, cf. agterm's blocked status);
/// - otherwise the agent's colored dot, pulsing for active states
///   (`.thinking` / `.executing`) (#1048).
///
/// Stale evidence replaces the logical-state glyph with a clock. A newly
/// terminated session is retained by the polling coordinator for one
/// polling interval and shown with an xmark before the badge is removed.
struct AgentTabBadge: View {
    let session: AgentSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var userFacingState: AgentState {
        Self.userFacingState(for: session)
    }

    private var isActive: Bool {
        session.liveness == .live && userFacingState.isActive
    }

    static func userFacingState(
        for session: AgentSession,
        accuracyPolicy: AgentLifecycleAccuracyPolicy = .production
    ) -> AgentState {
        session.state.userFacing(
            stableIdentifier: session.agentType.stableIdentifier,
            evidenceAccuracy: session.lifecycleAccuracy,
            policy: accuracyPolicy
        )
    }

    nonisolated static func shouldPulse(
        isActive: Bool,
        reduceMotion: Bool
    ) -> Bool {
        isActive && !reduceMotion
    }

    var body: some View {
        Group {
            if let livenessGlyph = session.liveness.glyphName {
                Image(systemName: livenessGlyph)
                    .foregroundStyle(
                        session.liveness == .stale ? .orange : .secondary
                    )
            } else if userFacingState == .waitingInput {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Circle()
                    .fill(Color(nsColor: session.agentType.color))
                    .frame(width: 7, height: 7)
                    .opacity(userFacingState == .idle ? 0.6 : 1.0)
                    .scaleEffect(
                        Self.shouldPulse(
                            isActive: isActive && pulse,
                            reduceMotion: reduceMotion
                        ) ? 1.25 : 1.0
                    )
                    .animation(
                        Self.shouldPulse(
                            isActive: isActive,
                            reduceMotion: reduceMotion
                        )
                            ? .easeInOut(duration: 0.8)
                                .repeatForever(autoreverses: true)
                            : nil,
                        value: pulse
                    )
                    .onAppear {
                        pulse = Self.shouldPulse(
                            isActive: isActive,
                            reduceMotion: reduceMotion
                        )
                    }
                    .onChange(of: isActive) { _, active in
                        pulse = Self.shouldPulse(
                            isActive: active,
                            reduceMotion: reduceMotion
                        )
                    }
                    .onChange(of: reduceMotion) { _, shouldReduce in
                        pulse = Self.shouldPulse(
                            isActive: isActive,
                            reduceMotion: shouldReduce
                        )
                    }
            }
        }
        .font(.system(size: 10))
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        let state = "\(session.agentType.displayName) — \(userFacingState.displayName)"
        guard session.liveness != .live else { return state }
        return "\(state) — \(session.liveness.displayName)"
    }
}

// MARK: - Terminal tab item (capsule style)

struct TerminalAgentResumeAction: Identifiable {
    let id: UUID
    let title: String
    let action: () -> Void
}

struct TerminalNativeTabItem: View {
    let tab: TerminalTab
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var onMoveLeading: (() -> Void)?
    var onMoveTrailing: (() -> Void)?
    var onMoveToPreviousPane: (() -> Void)?
    var onMoveToNextPane: (() -> Void)?
    var agentResumeActions: [TerminalAgentResumeAction] = []

    @State private var isHovering = false
    @State private var closeGlyphFrame = CGRect.null

    var body: some View {
        HStack(spacing: 4) {
            if canClose {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(
                        width: TabSlotHitTesting.closeGlyphSize,
                        height: TabSlotHitTesting.closeGlyphSize
                    )
                    .background(
                        isHovering ? Color.primary.opacity(0.1) : .clear,
                        in: Circle()
                    )
                    .opacity(isHovering || isActive ? 1 : 0.35)
                    .allowsHitTesting(false)
                    .reportsTabCloseGlyphFrame()
            }

            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(tab.name)
                .font(.system(size: 11))
                .lineLimit(1)

            if let session = tab.agentSession {
                AgentTabBadge(session: session)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            isActive
                ? Color.primary.opacity(0.12)
                : isHovering ? Color.primary.opacity(0.05) : .clear,
            in: Capsule()
        )
        .frame(height: LayoutMetrics.tabBarHeight)
        .coordinateSpace(name: TabSlotHitTesting.coordinateSpaceName)
        .contentShape(.interaction, Rectangle())
        .contentShape(.dragPreview, Capsule())
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    switch TabSlotHitTesting.target(
                        at: value.location,
                        canClose: canClose,
                        closeGlyphFrame: closeGlyphFrame
                    ) {
                    case .select:
                        onSelect()
                    case .close:
                        onClose()
                    }
                }
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(Strings.tabMoveLeading) {
                onMoveLeading?()
            }
            .disabled(onMoveLeading == nil)

            Button(Strings.tabMoveTrailing) {
                onMoveTrailing?()
            }
            .disabled(onMoveTrailing == nil)

            Button(Strings.tabMoveToPreviousPane) {
                onMoveToPreviousPane?()
            }
            .disabled(onMoveToPreviousPane == nil)

            Button(Strings.tabMoveToNextPane) {
                onMoveToNextPane?()
            }
            .disabled(onMoveToNextPane == nil)

            if !agentResumeActions.isEmpty {
                Divider()
                Menu(Strings.agentResumeTask) {
                    ForEach(agentResumeActions) { resume in
                        Button(resume.title, action: resume.action)
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                onClose()
            } label: {
                Label(Strings.a11yCloseTabLabel, systemImage: "xmark")
            }
            .disabled(!canClose)
        }
        .onPreferenceChange(TabCloseGlyphFramePreferenceKey.self) { frame in
            closeGlyphFrame = frame
        }
        .accessibilityRepresentation {
            HStack {
                Button(tab.name, action: onSelect)
                    .accessibilityIdentifier(AccessibilityID.terminalTab(tab.stableLabel))
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                    .accessibilityActions {
                        if let onMoveLeading {
                            Button(Strings.tabMoveLeading, action: onMoveLeading)
                        }
                        if let onMoveTrailing {
                            Button(Strings.tabMoveTrailing, action: onMoveTrailing)
                        }
                        if let onMoveToPreviousPane {
                            Button(
                                Strings.tabMoveToPreviousPane,
                                action: onMoveToPreviousPane
                            )
                        }
                        if let onMoveToNextPane {
                            Button(
                                Strings.tabMoveToNextPane,
                                action: onMoveToNextPane
                            )
                        }
                    }
                if canClose {
                    Button(Strings.a11yCloseTabLabel, action: onClose)
                        .accessibilityHint(Strings.a11yCloseTabHint)
                        .accessibilityIdentifier("closeTerminalTab_\(tab.stableLabel)")
                }
            }
        }
    }
}

// MARK: - Terminal search bar container

/// Isolated view to keep TerminalSearchBar's closures out of ContentView's type-checking scope.
struct TerminalSearchBarContainer: View {
    var terminalState: TerminalPaneState

    var body: some View {
        if terminalState.isSearchVisible {
            TerminalSearchBar(
                query: Bindable(terminalState).terminalSearchQuery,
                caseSensitive: Bindable(terminalState).isSearchCaseSensitive,
                matchCount: terminalState.activeTab?.searchMatches.count ?? 0,
                currentMatch: terminalState.activeTab?.currentMatchIndex ?? -1,
                onNext: {
                    terminalState.activeTab?.nextMatch()
                },
                onPrevious: {
                    terminalState.activeTab?.previousMatch()
                },
                onDismiss: {
                    terminalState.isSearchVisible = false
                    terminalState.terminalSearchQuery = ""
                    terminalState.activeTab?.clearSearch()
                }
            )
        }
    }
}

// MARK: - Terminal search observer

/// Extracted modifier to reduce body complexity for the type-checker.
/// Handles debounced search, case-sensitivity changes, and tab switching.
struct TerminalSearchObserver: ViewModifier {
    var terminalState: TerminalPaneState
    let paneID: PaneID
    @Environment(ProjectManager.self) private var projectManager
    @Environment(PaneManager.self) private var paneManager
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var searchTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .findInTerminal)) { notification in
                guard paneManager.activePaneID == paneID,
                      ContentView.shouldHandleTargetedCommand(
                    notificationObject: notification.object,
                    currentProject: projectManager,
                    isKeyWindow: controlActiveState == .key
                ) else { return }
                // Defer to break reentrancy (#1051): `.findInTerminal` is posted
                // synchronously from the Terminal menu ButtonAction callstack
                // (PineAppMenuCommands.swift). Mutating the @Observable
                // `terminalState.isSearchVisible` synchronously here would
                // collide with the button-action's exclusive access to SwiftUI
                // storage and trigger the exclusivity abort — same class of
                // bug fixed across the other .onReceive handlers in this PR.
                DispatchQueue.main.async {
                    terminalState.isSearchVisible = true
                }
            }
            .onChange(of: terminalState.terminalSearchQuery) { _, newQuery in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    await terminalState.activeTab?.search(
                        for: newQuery,
                        caseSensitive: terminalState.isSearchCaseSensitive
                    )
                }
            }
            .onChange(of: terminalState.isSearchCaseSensitive) { _, _ in
                guard terminalState.isSearchVisible,
                      !terminalState.terminalSearchQuery.isEmpty else { return }
                searchTask?.cancel()
                searchTask = Task {
                    await terminalState.activeTab?.search(
                        for: terminalState.terminalSearchQuery,
                        caseSensitive: terminalState.isSearchCaseSensitive
                    )
                }
            }
            .onChange(of: terminalState.activeTerminalID) { _, _ in
                guard terminalState.isSearchVisible,
                      !terminalState.terminalSearchQuery.isEmpty else { return }
                searchTask?.cancel()
                searchTask = Task {
                    await terminalState.activeTab?.search(
                        for: terminalState.terminalSearchQuery,
                        caseSensitive: terminalState.isSearchCaseSensitive
                    )
                }
            }
    }
}
