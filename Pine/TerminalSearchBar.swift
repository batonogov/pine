//
//  TerminalSearchBar.swift
//  Pine
//
//  Search overlay bar shown at the top of the terminal panel when Cmd+F is pressed.
//

import SwiftUI

/// A compact search bar overlaid at the top of the terminal area.
/// Shows a text field for the query, previous/next navigation buttons,
/// and a close button. Dismissed by pressing Esc or clicking the close button.
struct TerminalSearchBar: View {
    @Binding var query: String
    @Binding var caseSensitive: Bool
    var matchCount: Int
    var currentMatch: Int
    /// Non-nil while ⌘F is asking AppKit for first responder in the query
    /// field. See ``TerminalPaneState/searchFocusRequestID``.
    var focusRequestID: UUID?
    var onFocusResult: (UUID, Bool) -> Void
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: MenuIcons.find)
                .foregroundStyle(.secondary)
                .imageScale(.small)

            // AppKit-backed: SwiftUI focus does not take first responder
            // away from SwiftTerm's sibling NSView, and Return / Shift+Return
            // / Escape have to reach the field editor to work at all (#1523).
            TerminalSearchField(
                text: $query,
                focusRequestID: focusRequestID,
                onCommand: { command in
                    switch command {
                    case .findNext: onNext()
                    case .findPrevious: onPrevious()
                    case .dismiss: onDismiss()
                    }
                },
                onFocusResult: onFocusResult
            )
            .frame(minWidth: 120)

            if !query.isEmpty {
                matchLabel
            }

            Button {
                caseSensitive.toggle()
            } label: {
                Text("Aa")
                    .font(.system(size: 11, weight: caseSensitive ? .bold : .regular, design: .default))
                    .foregroundStyle(caseSensitive ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
            .help(Strings.terminalSearchCaseSensitiveTooltip)
            .accessibilityIdentifier(AccessibilityID.terminalSearchCaseSensitive)

            Divider().frame(height: 16)

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            .help(Strings.terminalSearchPreviousTooltip)
            .accessibilityIdentifier(AccessibilityID.terminalSearchPrevious)

            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            .help(Strings.terminalSearchNextTooltip)
            .accessibilityIdentifier(AccessibilityID.terminalSearchNext)

            Divider().frame(height: 16)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help(Strings.terminalSearchCloseTooltip)
            .accessibilityIdentifier(AccessibilityID.terminalSearchClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .accessibilityIdentifier(AccessibilityID.terminalSearchBar)
    }

    @ViewBuilder
    private var matchLabel: some View {
        if matchCount == 0 {
            Text(Strings.terminalSearchNoMatches)
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            Text(Strings.terminalSearchMatchCount(current: currentMatch + 1, total: matchCount))
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
