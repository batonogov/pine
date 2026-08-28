//
//  GitFileStatus+Color.swift
//  Pine
//
//  SwiftUI color mapping for GitFileStatus, separated from models
//  so that GitModels.swift depends only on Foundation.
//

import SwiftUI

extension GitFileStatus {
    /// One hue per status. The pairs #1532 called ambiguous are split:
    /// `.mixed` leaves the orange it shared with `.modified`, `.conflict`
    /// leaves the red it shared with `.deleted`, and `.added` leaves the
    /// `.staged` green. Colour only reinforces the status here — the
    /// letter badge in ``GitFileStatus/statusLetter`` carries it without
    /// colour at all, and under Differentiate Without Color the filename
    /// tint is dropped entirely.
    var color: Color {
        switch self {
        case .modified:         return Color(.systemOrange)
        case .mixed:            return Color(.systemIndigo)
        case .staged:           return Color(.systemGreen)
        case .added:            return Color(.systemMint)
        case .untracked:        return Color(.systemTeal)
        case .deleted:          return Color(.systemRed)
        case .conflict:         return Color(.systemPurple)
        }
    }
}
