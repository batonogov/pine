//
//  SnapshotHarness.swift
//  PineTests
//
//  Minimal zero-dependency visual snapshot harness.
//
//  Usage:
//    try assertSnapshot(of: MyView(), size: NSSize(width: 400, height: 300),
//                       appearance: .light, named: "MyView.light")
//
//  Recording mode:
//    Run tests with `PINE_RECORD_SNAPSHOTS=1` in environment to (re)write
//    reference PNGs under `PineTests/SnapshotTests/__Snapshots__/`.
//
//  Diff strategy:
//    Renders the SwiftUI view via `NSHostingView` into an `NSBitmapImageRep`
//    at the requested size under the requested `NSAppearance`, encodes to PNG,
//    and compares against the reference PNG using a per-pixel RGBA diff
//    normalized by byte count. If the mean absolute difference exceeds
//    `tolerance` the test fails and the actual PNG is written next to the
//    reference with a `.actual.png` suffix for inspection.
//
//  Design notes:
//    - Pure AppKit + CoreGraphics, no third-party dependencies, no pbxproj
//      edits (file lives under the existing `PineTests/` synchronized group).
//    - Static SwiftUI views render synchronously after `layoutSubtreeIfNeeded()`;
//      no RunLoop spin required.
//    - Reference PNGs are stored under `__Snapshots__/` and discovered via
//      `#filePath` relative lookups so tests work regardless of cwd.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

// MARK: - Public API

/// Renders `view` and compares it against a reference PNG.
///
/// - Parameters:
///   - view: The SwiftUI view under test.
///   - size: Logical size for the hosting view.
///   - appearance: `.aqua` (light) or `.darkAqua` (dark).
///   - named: Snapshot name, used as the PNG filename (without extension).
///   - tolerance: Mean absolute pixel difference allowed, in `[0, 1]`.
///                Default `0.01` tolerates trivial anti-aliasing noise.
///   - file: Source file (auto-filled) used to locate `__Snapshots__/`.
@MainActor
func assertSnapshot<V: View>(
    of view: V,
    size: NSSize,
    appearance: SnapshotAppearance,
    named: String,
    tolerance: Double = 0.01,
    sourceLocation: SourceLocation = #_sourceLocation,
    file: StaticString = #filePath
) throws {
    // Skip gracefully on headless CI runners where AppKit rendering is unavailable.
    if SnapshotHarness.isHeadless {
        return
    }

    let bitmap = try SnapshotHarness.render(view: view, size: size, appearance: appearance)
    guard let actualPNG = bitmap.representation(using: .png, properties: [:]) else {
        let message = "Failed to encode snapshot '\(named)' to PNG"
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
        return
    }

    let referenceURL = SnapshotHarness.referenceURL(for: named, testFile: file)

    // Record mode: always (over)write the reference and pass.
    if SnapshotHarness.isRecording {
        try SnapshotHarness.ensureDirectory(for: referenceURL)
        try actualPNG.write(to: referenceURL)
        return
    }

    guard FileManager.default.fileExists(atPath: referenceURL.path) else {
        // First run — write reference and fail loudly so CI can't accidentally
        // create a new baseline silently.
        try SnapshotHarness.ensureDirectory(for: referenceURL)
        try actualPNG.write(to: referenceURL)
        let message = "No reference snapshot for '\(named)'. "
            + "Wrote new baseline at \(referenceURL.path). Re-run tests to verify."
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
        return
    }

    let referenceData = try Data(contentsOf: referenceURL)
    let diff = try SnapshotHarness.meanAbsoluteDiff(actualPNG: actualPNG, referencePNG: referenceData)

    if diff > tolerance {
        // Save the actual image alongside the reference for visual inspection.
        let actualURL = referenceURL.deletingPathExtension().appendingPathExtension("actual.png")
        try? actualPNG.write(to: actualURL)
        let diffString = String(format: "%.4f", diff)
        let message = "Snapshot '\(named)' differs by \(diffString) (> tolerance \(tolerance)). "
            + "Actual written to \(actualURL.lastPathComponent). "
            + "Re-record with PINE_RECORD_SNAPSHOTS=1."
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }
}

/// Wrapper for NSAppearance to give tests a tidy call-site.
enum SnapshotAppearance {
    case light
    case dark

    var nsAppearance: NSAppearance {
        switch self {
        case .light: return NSAppearance(named: .aqua) ?? NSAppearance()
        case .dark: return NSAppearance(named: .darkAqua) ?? NSAppearance()
        }
    }

    var suffix: String {
        switch self {
        case .light: return "light"
        case .dark: return "dark"
        }
    }
}

// MARK: - Internal implementation

enum SnapshotHarness {

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["PINE_RECORD_SNAPSHOTS"] == "1"
    }

    /// Returns `true` when running on a CI runner.
    /// Snapshot tests rely on stable GPU rendering and font metrics that vary
    /// between machines, so they only run locally where developers can inspect
    /// and re-record baselines.
    static var isHeadless: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    /// Renders `view` into an `NSBitmapImageRep` at the given size/appearance.
    @MainActor
    static func render<V: View>(
        view: V,
        size: NSSize,
        appearance: SnapshotAppearance
    ) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance.nsAppearance
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        // Wrap in a window so SwiftUI's environment (key window, etc.) is populated.
        // We use a borderless window kept off-screen so nothing flashes during tests.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance.nsAppearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw SnapshotError.bitmapCreationFailed
        }
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    static func referenceURL(for name: String, testFile: StaticString) -> URL {
        // `#filePath` gives us an absolute path to the test source file.
        // Reference PNGs live in a sibling `__Snapshots__/` directory.
        let testFilePath = String(describing: testFile)
        let testFileURL = URL(fileURLWithPath: testFilePath)
        let snapshotDir = testFileURL.deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
        return snapshotDir.appendingPathComponent("\(name).png")
    }

    static func ensureDirectory(for fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Decodes both PNGs and computes mean absolute RGBA diff normalized to `[0, 1]`.
    /// Dimension mismatches short-circuit to `1.0` (maximum difference).
    static func meanAbsoluteDiff(actualPNG: Data, referencePNG: Data) throws -> Double {
        guard let actual = decodeRGBA(data: actualPNG),
              let reference = decodeRGBA(data: referencePNG) else {
            throw SnapshotError.decodeFailed
        }
        if actual.width != reference.width || actual.height != reference.height {
            return 1.0
        }
        let count = actual.pixels.count
        guard count > 0, count == reference.pixels.count else {
            return 1.0
        }
        var accumulator: UInt64 = 0
        for index in 0..<count {
            let diff = Int(actual.pixels[index]) - Int(reference.pixels[index])
            accumulator &+= UInt64(abs(diff))
        }
        // Max possible diff per byte is 255, so the normalized range is [0, 1].
        return Double(accumulator) / (Double(count) * 255.0)
    }

    private struct DecodedImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private static func decodeRGBA(data: Data) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return DecodedImage(width: width, height: height, pixels: pixels)
    }
}

enum SnapshotError: Error {
    case bitmapCreationFailed
    case decodeFailed
}
