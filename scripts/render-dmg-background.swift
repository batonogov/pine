#!/usr/bin/env swift
import AppKit
import Foundation

private let expectedPixelSize = NSSize(width: 1320, height: 840)
private let expectedPointSize = NSSize(width: 660, height: 420)

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: render-dmg-background.swift <input.svg> <output.png>")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard FileManager.default.fileExists(atPath: inputURL.path) else {
    fail("input SVG not found: \(inputURL.path)")
}
guard let sourceImage = NSImage(contentsOf: inputURL) else {
    fail("could not decode SVG: \(inputURL.path)")
}
guard sourceImage.size == expectedPixelSize else {
    fail(
        "SVG must be 1320×840 pixels; found "
            + "\(Int(sourceImage.size.width))×\(Int(sourceImage.size.height))"
    )
}
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(expectedPixelSize.width),
    pixelsHigh: Int(expectedPixelSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("could not allocate the Retina bitmap")
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    NSGraphicsContext.restoreGraphicsState()
    fail("could not create the rendering context")
}
NSGraphicsContext.current = context
context.imageInterpolation = .high
sourceImage.draw(
    in: NSRect(origin: .zero, size: expectedPixelSize),
    from: .zero,
    operation: .copy,
    fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

// A 2× logical size writes 144-DPI metadata for Finder's 660×420-point window.
bitmap.size = expectedPointSize
guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fail("could not encode the rendered background as PNG")
}

do {
    try pngData.write(to: outputURL, options: .atomic)
} catch {
    fail("could not write \(outputURL.path): \(error.localizedDescription)")
}

print("Rendered \(outputURL.path) at 1320×840 pixels (660×420 points)")
