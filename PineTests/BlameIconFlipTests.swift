//
//  BlameIconFlipTests.swift
//  PineTests
//

import AppKit
import Testing
@testable import Pine

/// Tests that SF Symbol icons render correctly in flipped coordinate contexts
/// (like GutterTextView which has isFlipped = true).
struct BlameIconFlipTests {

    /// NSView subclass with isFlipped = true, like GutterTextView.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
        var imageToDraw: NSImage?
        var useRespectFlipped = false

        override func draw(_ dirtyRect: NSRect) {
            imageToDraw?.draw(
                in: bounds, from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: useRespectFlipped, hints: nil
            )
        }
    }

    /// NSView subclass with isFlipped = false (default).
    private final class NormalView: NSView {
        var imageToDraw: NSImage?

        override func draw(_ dirtyRect: NSRect) {
            imageToDraw?.draw(
                in: bounds, from: .zero, operation: .sourceOver, fraction: 1
            )
        }
    }

    /// Renders a view into a bitmap using AppKit's native rendering pipeline.
    private func renderView(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Returns the average alpha of the top quarter vs bottom quarter of a bitmap.
    private func verticalAlphaDistribution(
        _ rep: NSBitmapImageRep
    ) -> (topAlpha: CGFloat, bottomAlpha: CGFloat) {
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let quarterH = h / 4
        var topTotal: CGFloat = 0
        var bottomTotal: CGFloat = 0
        var topCount = 0
        var bottomCount = 0
        for y in 0..<quarterH {
            for x in 0..<w {
                if let color = rep.colorAt(x: x, y: y) {
                    topTotal += color.alphaComponent
                    topCount += 1
                }
            }
        }
        for y in (h - quarterH)..<h {
            for x in 0..<w {
                if let color = rep.colorAt(x: x, y: y) {
                    bottomTotal += color.alphaComponent
                    bottomCount += 1
                }
            }
        }
        let topAvg = topCount > 0 ? topTotal / CGFloat(topCount) : 0
        let bottomAvg = bottomCount > 0 ? bottomTotal / CGFloat(bottomCount) : 0
        return (topAvg, bottomAvg)
    }

    // MARK: - Tests

    @Test func respectFlippedDrawsCorrectlyInFlippedView() throws {
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let symbol = try #require(
            NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        )

        let viewSize = NSSize(width: 30, height: 30)

        // Reference: normal image in normal (unflipped) view
        let normalView = NormalView(frame: NSRect(origin: .zero, size: viewSize))
        normalView.imageToDraw = symbol
        let reference = try renderView(normalView)
        let refDist = verticalAlphaDistribution(reference)

        // Fixed: image drawn with respectFlipped:true in flipped view
        let flippedView = FlippedView(frame: NSRect(origin: .zero, size: viewSize))
        flippedView.imageToDraw = symbol
        flippedView.useRespectFlipped = true
        let fixedResult = try renderView(flippedView)
        let fixedDist = verticalAlphaDistribution(fixedResult)

        // Both should have the same vertical alpha distribution
        let refTopHeavier = refDist.topAlpha > refDist.bottomAlpha
        let fixedTopHeavier = fixedDist.topAlpha > fixedDist.bottomAlpha
        #expect(refTopHeavier == fixedTopHeavier,
                "respectFlipped:true in flipped view should match normal image orientation")
    }

    @Test func withoutRespectFlippedImageIsInvertedInFlippedView() throws {
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let symbol = try #require(
            NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        )

        let viewSize = NSSize(width: 30, height: 30)

        // Reference: normal image in normal view
        let normalView = NormalView(frame: NSRect(origin: .zero, size: viewSize))
        normalView.imageToDraw = symbol
        let reference = try renderView(normalView)
        let refDist = verticalAlphaDistribution(reference)

        // Bug: image drawn WITHOUT respectFlipped in flipped view — should be inverted
        let flippedView = FlippedView(frame: NSRect(origin: .zero, size: viewSize))
        flippedView.imageToDraw = symbol
        flippedView.useRespectFlipped = false
        let brokenResult = try renderView(flippedView)
        let brokenDist = verticalAlphaDistribution(brokenResult)

        let refTopHeavier = refDist.topAlpha > refDist.bottomAlpha
        let brokenTopHeavier = brokenDist.topAlpha > brokenDist.bottomAlpha
        #expect(refTopHeavier != brokenTopHeavier,
                "Without respectFlipped, image in flipped view should be inverted")
    }
}
