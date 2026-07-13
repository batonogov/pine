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
/// `.done` is intentionally not given its own glyph here: the moment a
/// session goes `.done` it is detached from its tab (`session(forPID:)`
/// returns nil for done), so this view stops rendering entirely. A visible
/// "completed" indicator would require retaining the session briefly —
/// tracked as a follow-up to #1112.
struct AgentTabBadge: View {
    let session: AgentSession
    @State private var pulse = false

    private var isActive: Bool { session.state.isActive }

    var body: some View {
        Group {
            if session.state == .waitingInput {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Circle()
                    .fill(Color(nsColor: session.agentType.color))
                    .frame(width: 7, height: 7)
                    .opacity(session.state == .idle ? 0.6 : 1.0)
                    .scaleEffect(isActive && pulse ? 1.25 : 1.0)
                    .animation(isActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
                    .onAppear { if isActive { pulse = true } }
                    .onChange(of: isActive) { _, active in pulse = active }
            }
        }
        .font(.system(size: 10))
        .help("\(session.agentType.displayName) — \(session.state.displayName)")
    }
}

// MARK: - Terminal tab item (capsule style)

struct TerminalNativeTabItem: View {
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
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            isHovering ? Color.primary.opacity(0.1) : .clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .opacity(isHovering || isActive ? 1 : 0.35)
                .accessibilityIdentifier("closeTerminalTab_\(tab.stableLabel)")
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
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.terminalTab(tab.stableLabel))
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
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var searchTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .findInTerminal)) { _ in
                guard controlActiveState == .key else { return }
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
