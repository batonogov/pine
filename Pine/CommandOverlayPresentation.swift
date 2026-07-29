//
//  CommandOverlayPresentation.swift
//  Pine
//
//  Identifies the active ephemeral navigation overlay (#975).
//

/// The kind of command overlay currently presented in a project window.
///
/// Only one overlay may be active per window at a time; presenting a new
/// case replaces the previous one deterministically.
nonisolated enum CommandOverlayPresentation: String, Sendable, Equatable {
    case quickOpen
    case symbolNavigator
    case goToLine
    case commandPalette
    case agentAttention

    /// The accessibility identifier applied to the overlay container element.
    var containerIdentifier: String {
        switch self {
        case .quickOpen:
            AccessibilityID.quickOpenOverlay
        case .symbolNavigator:
            AccessibilityID.symbolNavigatorOverlay
        case .goToLine:
            AccessibilityID.goToLineOverlay
        case .commandPalette:
            AccessibilityID.commandPaletteOverlay
        case .agentAttention:
            AccessibilityID.agentAttentionOverlay
        }
    }
}
