//
//  AccessibilityAdaptiveMaterialTests.swift
//  PineTests
//
//  Reduce Transparency half of #1533. Materials never consult the setting on
//  their own, so every overlay painted with `.regularMaterial` or `.bar`
//  stayed translucent for exactly the users who asked the system not to do
//  that. `AccessibilityAdaptiveMaterial` makes the decision in
//  `resolve(in:)`, and these tests prove both branches paint what they claim:
//  the assertions render the style next to the plain style each branch is
//  supposed to equal, on the same host in the same run, so no absolute pixel
//  value is ever pinned.
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
    @Test("with Reduce Transparency on, the style paints its opaque fallback")
    func fallbackBranch() throws {
        guard !SnapshotHarness.isHeadless else { return }
        let adaptive = Rectangle()
            .fill(AccessibilityAdaptiveMaterial(.regularMaterial, fallback: .red))
            .environment(\._accessibilityReduceTransparency, true)
        let plain = Rectangle().fill(Color.red)
        let diff = try renderedDiff(adaptive, plain)
        #expect(
            diff < Self.tolerance,
            "Reduce Transparency was on but the style did not paint its fallback (diff \(diff))"
        )
    }

    @Test("with Reduce Transparency off, the style still paints its material")
    func materialBranch() throws {
        guard !SnapshotHarness.isHeadless else { return }
        let adaptive = Rectangle()
            .fill(AccessibilityAdaptiveMaterial(.regularMaterial))
            .environment(\._accessibilityReduceTransparency, false)
        let plain = Rectangle().fill(.regularMaterial)
        let diff = try renderedDiff(adaptive, plain)
        #expect(
            diff < Self.tolerance,
            "Transparency was allowed but the style did not paint its material (diff \(diff))"
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
    /// fallback. The adaptive styles exist so this decision cannot be skipped
    /// at a call site, so a bare literal outside the defining file is a bug.
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
            \(offenders.sorted()). Use `.adaptiveRegularMaterial` / \
            `.adaptiveBar` from AccessibilityAdaptiveMaterial.swift (#1533).
            """
        )
    }
}
