//
//  TabDragInteractionTests.swift
//  PineTests
//
//  Deterministic coverage for tab hit and insertion-gap geometry.
//

import CoreGraphics
import Foundation
import Testing

@testable import Pine

@Suite("Tab Slot Hit Testing")
struct TabSlotHitTestingTests {
    private let slotHeight: CGFloat = 30
    private let epsilon: CGFloat = 0.001
    private let glyphFrame = CGRect(x: 58, y: 8, width: 14, height: 14)

    @Test("Close target expands the glyph by configured hit slop")
    func closeTargetUsesConfiguredGeometry() {
        let rect = TabSlotHitTesting.closeRect(for: glyphFrame)
        let expectedHitSize = TabSlotHitTesting.closeGlyphSize
            + (TabSlotHitTesting.closeHitSlop * 2)

        #expect(TabSlotHitTesting.closeGlyphSize == 14)
        #expect(TabSlotHitTesting.closeHitSlop == 4)
        #expect(rect.minX == glyphFrame.minX - TabSlotHitTesting.closeHitSlop)
        #expect(rect.midX == glyphFrame.midX)
        #expect(rect.midY == glyphFrame.midY)
        #expect(rect.width == expectedHitSize)
        #expect(rect.height == expectedHitSize)
    }

    @Test("Close target follows measured glyph in flexible tabs")
    func closeTargetFollowsMeasuredGlyph() {
        let frames = [
            CGRect(x: 10, y: 8, width: 14, height: 14),
            CGRect(x: 58, y: 8, width: 14, height: 14),
            CGRect(x: 132, y: 8, width: 14, height: 14)
        ]

        for frame in frames {
            let rect = TabSlotHitTesting.closeRect(for: frame)
            #expect(rect.midX == frame.midX)
            #expect(rect.midY == frame.midY)
        }
    }

    @Test("Points immediately inside every close boundary close")
    func insideCloseTargetBoundariesClose() {
        let rect = TabSlotHitTesting.closeRect(for: glyphFrame)
        let points = [
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX - epsilon, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.maxY - epsilon),
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX - epsilon, y: rect.maxY - epsilon)
        ]

        for point in points {
            #expect(TabSlotHitTesting.target(
                at: point,
                canClose: true,
                closeGlyphFrame: glyphFrame
            ) == .close)
        }
    }

    @Test("Points immediately outside every close boundary select")
    func outsideCloseTargetBoundariesSelect() {
        let rect = TabSlotHitTesting.closeRect(for: glyphFrame)
        let points = [
            CGPoint(x: rect.minX - epsilon, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.minY - epsilon),
            CGPoint(x: rect.midX, y: rect.maxY)
        ]

        for point in points {
            #expect(TabSlotHitTesting.target(
                at: point,
                canClose: true,
                closeGlyphFrame: glyphFrame
            ) == .select)
        }
    }

    @Test("Upper, lower, and trailing slot padding select")
    func slotPaddingSelects() {
        let closeRect = TabSlotHitTesting.closeRect(for: glyphFrame)
        let points = [
            CGPoint(x: closeRect.midX, y: epsilon),
            CGPoint(x: closeRect.midX, y: slotHeight - epsilon),
            CGPoint(x: closeRect.maxX + 20, y: slotHeight / 2)
        ]

        for point in points {
            #expect(TabSlotHitTesting.target(
                at: point,
                canClose: true,
                closeGlyphFrame: glyphFrame
            ) == .select)
        }
    }

    @Test("Tabs that cannot close always select")
    func cannotCloseAlwaysSelects() {
        let rect = TabSlotHitTesting.closeRect(for: glyphFrame)
        let points = [
            CGPoint(x: rect.midX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX - epsilon, y: rect.maxY - epsilon)
        ]

        for point in points {
            #expect(TabSlotHitTesting.target(
                at: point,
                canClose: false,
                closeGlyphFrame: glyphFrame
            ) == .select)
        }
    }

    @Test("Missing glyph measurement cannot close a tab")
    func missingGlyphMeasurementSelects() {
        #expect(TabSlotHitTesting.target(
            at: CGPoint(x: 10, y: slotHeight / 2),
            canClose: true,
            closeGlyphFrame: .null
        ) == .select)
    }
}

@Suite("Tab Strip N+1 Geometry")
struct TabStripInsertionGeometryTests {
    private let ids = [UUID(), UUID(), UUID()]

    private var frames: [UUID: CGRect] {
        [
            ids[0]: CGRect(x: 4, y: 0, width: 80, height: 30),
            ids[1]: CGRect(x: 86, y: 0, width: 120, height: 30),
            ids[2]: CGRect(x: 208, y: 0, width: 60, height: 30)
        ]
    }

    @Test("Empty strip has exactly one insertion gap")
    func emptyStrip() {
        #expect(TabStripInsertionGeometry.insertionIndex(
            atX: 500,
            orderedTabIDs: [],
            frames: [:]
        ) == 0)
        #expect(TabStripInsertionGeometry.indicatorX(
            for: 0,
            orderedTabIDs: [],
            frames: [:]
        ) == 4)
    }

    @Test(
        "Cursor resolves first, middle, and last gaps",
        arguments: [
            (CGFloat(0), 0),
            (CGFloat(60), 1),
            (CGFloat(150), 2),
            (CGFloat(500), 3)
        ]
    )
    func gapResolution(locationX: CGFloat, expectedIndex: Int) {
        #expect(TabStripInsertionGeometry.insertionIndex(
            atX: locationX,
            orderedTabIDs: ids,
            frames: frames
        ) == expectedIndex)
    }

    @Test("Indicator uses tab edges and spacing midpoints")
    func indicatorPositions() {
        #expect(TabStripInsertionGeometry.indicatorX(
            for: 0,
            orderedTabIDs: ids,
            frames: frames
        ) == 4)
        #expect(TabStripInsertionGeometry.indicatorX(
            for: 1,
            orderedTabIDs: ids,
            frames: frames
        ) == 85)
        #expect(TabStripInsertionGeometry.indicatorX(
            for: 3,
            orderedTabIDs: ids,
            frames: frames
        ) == 268)
    }

    @Test("Missing frames and out-of-range gaps are rejected")
    func invalidGeometry() {
        #expect(TabStripInsertionGeometry.insertionIndex(
            atX: 10,
            orderedTabIDs: ids,
            frames: [:]
        ) == nil)
        #expect(TabStripInsertionGeometry.indicatorX(
            for: 4,
            orderedTabIDs: ids,
            frames: frames
        ) == nil)
    }
}
