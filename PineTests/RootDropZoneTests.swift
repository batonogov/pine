//
//  RootDropZoneTests.swift
//  PineTests
//

import Testing
import CoreGraphics
@testable import Pine

@Suite("RootDropZone Tests")
struct RootDropZoneTests {

    let size = CGSize(width: 1000, height: 800)

    @Test func detectTopZone() {
        let zone = RootDropZone.detect(location: CGPoint(x: 500, y: 40), in: size)
        #expect(zone == .top)
    }

    @Test func detectBottomZone() {
        let zone = RootDropZone.detect(location: CGPoint(x: 500, y: 760), in: size)
        #expect(zone == .bottom)
    }

    @Test func detectLeftZone() {
        let zone = RootDropZone.detect(location: CGPoint(x: 50, y: 400), in: size)
        #expect(zone == .left)
    }

    @Test func detectRightZone() {
        let zone = RootDropZone.detect(location: CGPoint(x: 950, y: 400), in: size)
        #expect(zone == .right)
    }

    @Test func detectNoZone_center() {
        let zone = RootDropZone.detect(location: CGPoint(x: 500, y: 400), in: size)
        #expect(zone == nil)
    }

    @Test func cornerResolution_topLeft_closerToLeft() {
        // x=30 is 3% from left, y=50 is 6.25% from top — left wins
        let zone = RootDropZone.detect(location: CGPoint(x: 30, y: 50), in: size)
        #expect(zone == .left)
    }

    @Test func cornerResolution_topLeft_closerToTop() {
        // x=60 is 6% from left, y=20 is 2.5% from top — top wins
        let zone = RootDropZone.detect(location: CGPoint(x: 60, y: 20), in: size)
        #expect(zone == .top)
    }

    @Test func exactBoundary_10percent() {
        // x=100 is exactly 10% of 1000 — should be the boundary
        let zoneAt = RootDropZone.detect(location: CGPoint(x: 100, y: 400), in: size)
        #expect(zoneAt == nil) // at 10% boundary, not inside
        let zoneInside = RootDropZone.detect(location: CGPoint(x: 99, y: 400), in: size)
        #expect(zoneInside == .left)
    }

    @Test func zeroSize_returnsNil() {
        let zone = RootDropZone.detect(location: CGPoint(x: 50, y: 50), in: .zero)
        #expect(zone == nil)
    }
}
