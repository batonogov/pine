//
//  NSImageTintingTests.swift
//  PineTests
//

import AppKit
import Testing

@testable import Pine

@Suite("NSImage Tinting Tests")
struct NSImageTintingTests {

    @Test("tinted(with:) returns an image of the same size")
    func tintedReturnsSameSize() {
        let original = NSImage(size: NSSize(width: 16, height: 16))
        let tinted = original.tinted(with: .red)

        #expect(tinted.size == original.size)
    }

    @Test("tinted(with:) returns a non-template image")
    func tintedReturnsNonTemplate() {
        let original = NSImage(size: NSSize(width: 16, height: 16))
        original.isTemplate = true

        let tinted = original.tinted(with: .blue)

        #expect(tinted.isTemplate == false)
    }

    @Test("tinted(with:) returns a distinct copy, not the original")
    func tintedReturnsDistinctCopy() {
        let original = NSImage(size: NSSize(width: 16, height: 16))
        let tinted = original.tinted(with: .green)

        #expect(tinted !== original)
    }

    @Test("tinted(with:) safe cast does not crash on valid NSImage")
    func tintedSafeCastSucceeds() {
        // This test verifies the guard-let (as?) path works for normal images.
        // Before the fix, this used force cast (as!) which could crash.
        let original = NSImage(size: NSSize(width: 8, height: 8))
        let tinted = original.tinted(with: .systemPink)

        #expect(tinted.size.width == 8)
        #expect(tinted.size.height == 8)
    }
}
