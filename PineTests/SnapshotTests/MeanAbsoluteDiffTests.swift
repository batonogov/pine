//
//  MeanAbsoluteDiffTests.swift
//  PineTests
//
//  Unit tests for SnapshotHarness.meanAbsoluteDiff pixel comparison.
//

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import Pine

@Suite("meanAbsoluteDiff")
struct MeanAbsoluteDiffTests {

    // MARK: - Helpers

    /// Creates a single-color PNG of the given size.
    private func makePNG(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            pixels[i] = red
            pixels[i + 1] = green
            pixels[i + 2] = blue
            pixels[i + 3] = alpha
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return Data()
        }
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return Data()
        }
        guard let image = context.makeImage() else {
            return Data()
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: - Tests

    @Test("Identical images produce diff of 0.0")
    func identicalImages() throws {
        let png = makePNG(width: 10, height: 10, red: 128, green: 64, blue: 200)
        let diff = try SnapshotHarness.meanAbsoluteDiff(actualPNG: png, referencePNG: png)
        #expect(diff == 0.0)
    }

    @Test("Completely different images produce expected diff")
    func completelyDifferent() throws {
        let black = makePNG(width: 4, height: 4, red: 0, green: 0, blue: 0, alpha: 255)
        let white = makePNG(width: 4, height: 4, red: 255, green: 255, blue: 255, alpha: 255)
        let diff = try SnapshotHarness.meanAbsoluteDiff(actualPNG: black, referencePNG: white)
        // RGB channels differ by 255 each, alpha is same → 3/4 of bytes differ maximally.
        // Expected: (255*3 + 0) / (4 * 255) = 0.75
        #expect(diff > 0.7)
        #expect(diff <= 1.0)
    }

    @Test("Different sizes return 1.0")
    func differentSizes() throws {
        let small = makePNG(width: 4, height: 4, red: 0, green: 0, blue: 0)
        let large = makePNG(width: 8, height: 8, red: 0, green: 0, blue: 0)
        let diff = try SnapshotHarness.meanAbsoluteDiff(actualPNG: small, referencePNG: large)
        #expect(diff == 1.0)
    }

    @Test("Different width same height returns 1.0")
    func differentWidth() throws {
        let narrow = makePNG(width: 2, height: 4, red: 100, green: 100, blue: 100)
        let wide = makePNG(width: 6, height: 4, red: 100, green: 100, blue: 100)
        let diff = try SnapshotHarness.meanAbsoluteDiff(actualPNG: narrow, referencePNG: wide)
        #expect(diff == 1.0)
    }

    @Test("Invalid PNG data throws decodeFailed")
    func invalidData() throws {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        let valid = makePNG(width: 2, height: 2, red: 0, green: 0, blue: 0)
        #expect(throws: SnapshotError.decodeFailed) {
            try SnapshotHarness.meanAbsoluteDiff(actualPNG: garbage, referencePNG: valid)
        }
    }

    @Test("Slight color difference produces small diff")
    func slightDifference() throws {
        let base = makePNG(width: 4, height: 4, red: 100, green: 100, blue: 100)
        let shifted = makePNG(width: 4, height: 4, red: 101, green: 100, blue: 100)
        let diff = try SnapshotHarness.meanAbsoluteDiff(actualPNG: base, referencePNG: shifted)
        // Only the red channel differs by 1 out of 255 in 1/4 of bytes.
        #expect(diff > 0.0)
        #expect(diff < 0.01)
    }
}
