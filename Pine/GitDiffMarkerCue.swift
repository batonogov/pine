//
//  GitDiffMarkerCue.swift
//  Pine
//
//  Shared rendering language for the git diff markers drawn by the editor
//  gutter (`LineNumberView`) and the minimap (`MinimapView`) — #1540.
//

import AppKit

/// How git diff markers differentiate their kind (#1540).
///
/// By default the marker hue is the only channel separating `.added` from
/// `.modified` (a solid bar each; `.deleted` already has its triangle). When
/// the user enables the system Differentiate Without Color preference, the
/// marker *shape* takes over: a solid bar for added, a hollow bar for
/// modified, a triangle for deleted — every kind readable without colour.
enum GitDiffMarkerCue: Equatable {
    /// Hue differentiates the kinds (historic rendering).
    case colorOnly
    /// Shape differentiates the kinds (Differentiate Without Color).
    case shape

    /// Marker glyph a surface draws for a diff kind.
    enum Shape: Equatable {
        /// Filled rectangle along the edge.
        case bar
        /// Stroked (hollow) rectangle — same geometry as `.bar`.
        case outlinedBar
        /// Filled triangle pointing into the editor.
        case triangle
    }

    static func resolve(differentiateWithoutColor: Bool) -> Self {
        differentiateWithoutColor ? .shape : .colorOnly
    }

    /// The shape a surface draws for a diff kind under this cue.
    func shape(for kind: GitLineDiff.Kind) -> Shape {
        switch (self, kind) {
        case (_, .deleted):
            return .triangle
        case (.shape, .modified):
            return .outlinedBar
        default:
            return .bar
        }
    }

    /// VoiceOver-facing description of the cue the drawn markers use.
    /// Empty when no markers are present so clean files stay quiet.
    static func accessibilityValue(hasMarkers: Bool, cue: Self) -> String {
        guard hasMarkers else { return "" }
        switch cue {
        case .colorOnly:
            return Strings.a11yDiffMarkersColorCueValue
        case .shape:
            return Strings.a11yDiffMarkersShapeCueValue
        }
    }
}
