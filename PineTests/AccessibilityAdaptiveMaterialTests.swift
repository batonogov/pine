//
//  AccessibilityAdaptiveMaterialTests.swift
//  PineTests
//
//  Reduce Transparency half of #1533. Materials never consult the setting on
//  their own, so every overlay painted with `.regularMaterial` or `.bar`
//  stayed translucent for exactly the users who asked the system not to do
//  that. The `adaptiveMaterialBackground` / `adaptiveMaterialFill` modifiers
//  choose the paint in `body`, and these tests prove both branches paint
//  what they claim: the assertions render the adaptive view next to the
//  plain view each branch is supposed to equal, on the same host in the
//  same run, so no absolute pixel value is ever pinned.
//
//  The transparency-allowed branch must be pixel-identical to the direct
//  `background(_: Material)` call it replaces — that is what keeps every
//  recorded snapshot baseline valid across the migration.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("AccessibilityAdaptiveMaterial (#1533)", .serialized)
@MainActor
struct AccessibilityAdaptiveMaterialTests {

    private static let probeSize = NSSize(width: 64, height: 64)
    private static let tolerance = 0.01

    /// `\.accessibilityReduceTransparency` is get-only, so a test cannot
    /// override it. The underscored key is its public, settable backing
    /// storage (see the SwiftUICore swiftinterface), the same mechanism
    /// previews use to stage accessibility settings.
    @Test("with Reduce Transparency on, the background paints its opaque fallback")
    func backgroundFallbackBranch() throws {
        guard !SnapshotHarness.isHeadless else { return }
        let adaptive = Color.clear
            .adaptiveMaterialBackground(.regularMaterial, fallback: .red)
            .environment(\._accessibilityReduceTransparency, true)
        let plain = Color.red
        let diff = try renderedDiff(adaptive, plain)
        #expect(
            diff < Self.tolerance,
            "Reduce Transparency was on but the background did not paint its fallback (diff \(diff))"
        )
    }

    @Test("with Reduce Transparency off, the background still paints its material")
    func backgroundMaterialBranch() throws {
        guard !SnapshotHarness.isHeadless else { return }
        let adaptive = Color.clear
            .adaptiveMaterialBackground(.regularMaterial)
            .environment(\._accessibilityReduceTransparency, false)
        let plain = Color.clear.background(.regularMaterial)
        let diff = try renderedDiff(adaptive, plain)
        #expect(
            diff < Self.tolerance,
            "Transparency was allowed but the background did not paint its material (diff \(diff))"
        )
    }

    @Test("with Reduce Transparency off, the clipped background paints its material")
    func clippedBackgroundMaterialBranch() throws {
        guard !SnapshotHarness.isHeadless else { return }
        let clip = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let adaptive = Color.clear
            .adaptiveMaterialBackground(.regularMaterial, in: clip)
            .environment(\._accessibilityReduceTransparency, false)
        let plain = Color.clear.background(.regularMaterial, in: clip)
        let diff = try renderedDiff(adaptive, plain)
        #expect(
            diff < Self.tolerance,
            "Transparency was allowed but the clipped background did not paint its material (diff \(diff))"
        )
    }

    @Test("with Reduce Transparency on, the clipped background fills the shape with its fallback")
    func clippedBackgroundFallbackBranch() throws {
        guard !SnapshotHarness.isHeadless else { return }
        let clip = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let adaptive = Color.clear
            .adaptiveMaterialBackground(.regularMaterial, in: clip, fallback: .red)
            .environment(\._accessibilityReduceTransparency, true)
        let plain = Color.clear.background(Color.red, in: clip)
        let diff = try renderedDiff(adaptive, plain)
        #expect(
            diff < Self.tolerance,
            "Reduce Transparency was on but the clipped background did not paint its fallback (diff \(diff))"
        )
    }

    @Test("with Reduce Transparency off, the shape fill paints its material")
    func fillMaterialBranch() throws {
        guard !SnapshotHarness.isHeadless else { return }
        let adaptive = RoundedRectangle(cornerRadius: 12, style: .continuous)
            .adaptiveMaterialFill(.regularMaterial)
            .environment(\._accessibilityReduceTransparency, false)
        let plain = RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.regularMaterial)
        let diff = try renderedDiff(adaptive, plain)
        #expect(
            diff < Self.tolerance,
            "Transparency was allowed but the fill did not paint its material (diff \(diff))"
        )
    }

    @Test("with Reduce Transparency on, the shape fill paints its opaque fallback")
    func fillFallbackBranch() throws {
        guard !SnapshotHarness.isHeadless else { return }
        let adaptive = RoundedRectangle(cornerRadius: 12, style: .continuous)
            .adaptiveMaterialFill(.regularMaterial, fallback: .red)
            .environment(\._accessibilityReduceTransparency, true)
        let plain = RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.red)
        let diff = try renderedDiff(adaptive, plain)
        #expect(
            diff < Self.tolerance,
            "Reduce Transparency was on but the fill did not paint its fallback (diff \(diff))"
        )
    }

    @Test("the opacity argument applies to the material, matching a literal opacity call")
    func backgroundOpacityBranch() throws {
        guard !SnapshotHarness.isHeadless else { return }
        let adaptive = Color.clear
            .adaptiveMaterialBackground(.bar, opacity: 0.5)
            .environment(\._accessibilityReduceTransparency, false)
        let plain = Color.clear.background(.bar.opacity(0.5))
        let diff = try renderedDiff(adaptive, plain)
        #expect(
            diff < Self.tolerance,
            "Transparency was allowed but the dimmed background did not paint its material (diff \(diff))"
        )
    }

    /// Renders both views on the same host and returns their mean absolute
    /// pixel difference. Relative comparison only — the point is that two
    /// paints are identical, never what a material looks like in absolute
    /// terms (that drifts across macOS versions, #1620).
    private func renderedDiff<V1: View, V2: View>(
        _ first: V1,
        _ second: V2
    ) throws -> Double {
        let firstBitmap = try SnapshotHarness.render(
            view: first, size: Self.probeSize, appearance: .light
        )
        let secondBitmap = try SnapshotHarness.render(
            view: second, size: Self.probeSize, appearance: .light
        )
        let firstPNG = try #require(
            firstBitmap.representation(using: .png, properties: [:])
        )
        let secondPNG = try #require(
            secondBitmap.representation(using: .png, properties: [:])
        )
        return try SnapshotHarness.meanAbsoluteDiff(
            actualPNG: firstPNG, referencePNG: secondPNG
        )
    }
}

@Suite("Material backgrounds consult Reduce Transparency (#1533)")
struct MaterialBackgroundGuardTests {

    /// A bare material literal as a `ShapeStyle` — `.background(.bar)`,
    /// `.fill(.regularMaterial, …)` — bypasses the Reduce Transparency
    /// fallback. The adaptive modifiers exist so this decision cannot be
    /// skipped at a call site, so a bare literal outside the defining file
    /// is a bug.
    @Test("no bare material shape style outside AccessibilityAdaptiveMaterial.swift")
    func noBareMaterialShapeStyles() throws {
        let pattern = /\.(background|fill)\(\s*\.(?:bar|regularMaterial|thickMaterial|thinMaterial|ultraThinMaterial|ultraThickMaterial)\b/
        var offenders: [String] = []
        for url in try ProductionSourceScan.productionSwiftFileURLs()
        where url.lastPathComponent != "AccessibilityAdaptiveMaterial.swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains(pattern) {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(
            offenders.isEmpty,
            """
            Bare material backgrounds that ignore Reduce Transparency: \
            \(offenders.sorted()). Use `adaptiveMaterialBackground` / \
            `adaptiveMaterialFill` from AccessibilityAdaptiveMaterial.swift (#1533).
            """
        )
    }
}
