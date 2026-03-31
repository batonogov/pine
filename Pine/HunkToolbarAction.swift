//
//  HunkToolbarAction.swift
//  Pine
//
//  Actions available in the inline diff hunk toolbar (#689).
//

import Foundation

/// Actions available in the hunk viewer toolbar overlay.
enum HunkToolbarAction: String, Sendable {
    case previousHunk
    case nextHunk
    case restore
    case dismiss

    /// Accessibility identifier for UI testing.
    var accessibilityID: String {
        switch self {
        case .previousHunk: return AccessibilityID.hunkToolbarPrevious
        case .nextHunk: return AccessibilityID.hunkToolbarNext
        case .restore: return AccessibilityID.hunkToolbarRestore
        case .dismiss: return AccessibilityID.hunkToolbarDismiss
        }
    }
}
