//
//  TerminalBarView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

// MARK: - Terminal native tab bar (macOS window tab style)

struct TerminalNativeTabBar: View {
    var terminal: TerminalManager
    var workingDirectory: URL?

    private func closeTerminalTabWithConfirmation(_ tab: TerminalTab) {
        if tab.hasForegroundProcess {
            let alert = NSAlert()
            alert.messageText = Strings.terminalTabCloseWarningTitle
            alert.informativeText = Strings.terminalTabCloseWarningMessage
            alert.addButton(withTitle: Strings.terminalTabCloseWarningClose)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        terminal.closeTerminalTab(tab)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(terminal.terminalTabs) { tab in
                        TerminalNativeTabItem(
                            tab: tab,
                            isActive: tab.id == terminal.activeTerminalID,
                            canClose: terminal.terminalTabs.count > 1,
                            onSelect: {
                                terminal.activeTerminalID = tab.id
                                terminal.pendingFocusTabID = tab.id
                            },
                            onClose: { closeTerminalTabWithConfirmation(tab) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            // New terminal button
            Button {
                terminal.addTerminalTab(workingDirectory: workingDirectory)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(Strings.newTerminal)
            .accessibilityIdentifier(AccessibilityID.newTerminalButton)
            .accessibilityAddTraits(.isButton)

            Spacer()

            // Maximize / restore terminal
            Button {
                withAnimation(PineAnimation.quick) { terminal.isTerminalMaximized.toggle() }
            } label: {
                Image(systemName: terminal.isTerminalMaximized
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(terminal.isTerminalMaximized ? Strings.restoreTerminal : Strings.maximizeTerminal)
            .accessibilityIdentifier(AccessibilityID.maximizeTerminalButton)

            // Hide terminal button
            Button {
                withAnimation(PineAnimation.quick) {
                    terminal.isTerminalVisible = false
                    terminal.isTerminalMaximized = false
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help(Strings.hideTerminal)
            .accessibilityIdentifier(AccessibilityID.hideTerminalButton)
        }
        .frame(height: 30)
        .background(.bar)
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
                .opacity(isHovering || isActive ? 1 : 0)
            }

            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(tab.name)
                .font(.system(size: 11))
                .lineLimit(1)
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
        .accessibilityIdentifier(AccessibilityID.terminalTab(tab.name))
    }
}

// MARK: - Terminal search bar container

/// Isolated view to keep TerminalSearchBar's closures out of ContentView's type-checking scope.
struct TerminalSearchBarContainer: View {
    var terminal: TerminalManager

    var body: some View {
        if terminal.isSearchVisible {
            TerminalSearchBar(
                query: Bindable(terminal).terminalSearchQuery,
                caseSensitive: Bindable(terminal).isSearchCaseSensitive,
                matchCount: terminal.activeTerminalTab?.searchMatches.count ?? 0,
                currentMatch: terminal.activeTerminalTab?.currentMatchIndex ?? -1,
                onNext: {
                    terminal.activeTerminalTab?.nextMatch()
                },
                onPrevious: {
                    terminal.activeTerminalTab?.previousMatch()
                },
                onDismiss: {
                    terminal.isSearchVisible = false
                    terminal.terminalSearchQuery = ""
                    terminal.activeTerminalTab?.clearSearch()
                }
            )
        }
    }
}

// MARK: - Terminal search observer

/// Extracted modifier to reduce body complexity for the type-checker.
/// Handles debounced search, case-sensitivity changes, and tab switching.
struct TerminalSearchObserver: ViewModifier {
    var terminal: TerminalManager
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var searchTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .findInTerminal)) { _ in
                guard controlActiveState == .key, terminal.isTerminalVisible else { return }
                terminal.isSearchVisible = true
            }
            .onChange(of: terminal.terminalSearchQuery) { _, newQuery in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    await terminal.activeTerminalTab?.search(
                        for: newQuery,
                        caseSensitive: terminal.isSearchCaseSensitive
                    )
                }
            }
            .onChange(of: terminal.isSearchCaseSensitive) { _, _ in
                guard terminal.isSearchVisible, !terminal.terminalSearchQuery.isEmpty else { return }
                searchTask?.cancel()
                searchTask = Task {
                    await terminal.activeTerminalTab?.search(
                        for: terminal.terminalSearchQuery,
                        caseSensitive: terminal.isSearchCaseSensitive
                    )
                }
            }
            .onChange(of: terminal.activeTerminalID) { _, _ in
                guard terminal.isSearchVisible, !terminal.terminalSearchQuery.isEmpty else { return }
                searchTask?.cancel()
                searchTask = Task {
                    await terminal.activeTerminalTab?.search(
                        for: terminal.terminalSearchQuery,
                        caseSensitive: terminal.isSearchCaseSensitive
                    )
                }
            }
    }
}
