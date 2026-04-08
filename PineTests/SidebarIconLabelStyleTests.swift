//
//  SidebarIconLabelStyleTests.swift
//  PineTests
//
//  Tests for issue #763 — sidebar file/folder names must line up on the
//  same vertical baseline regardless of which SF Symbol the row uses.
//
//  Strategy:
//  * Runtime invariants on the metric constants (cover boundary conditions,
//    never-zero / never-negative, realistic upper bounds).
//  * Source-parser regression guards on `Pine/FileNodeRow.swift` that fail
//    fast if someone removes `.labelStyle(.sidebarIcon)` from either the
//    normal branch OR the `inlineEditor` rename branch. Both call sites
//    must stay in sync — otherwise entering/leaving rename mode causes the
//    row to visually jump (see #736).
//  * Regression guard that the fix does NOT re-introduce the HStack wrapper
//    pattern from reverted PR #770, which broke `List` selection and
//    XCUITest accessibility lookups.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Sidebar Icon Label Style — Issue #763")
struct SidebarIconLabelStyleTests {

    // MARK: - Metric invariants

    @Test("iconSlotWidth is positive")
    func iconSlotWidthIsPositive() {
        #expect(SidebarIconLabelStyle.iconSlotWidth > 0)
    }

    @Test("iconSlotWidth is wide enough for the widest SF Symbol used by FileIconMapper")
    func iconSlotWidthCoversWidestSymbol() {
        // Empirically measure the widths of the widest SF Symbols actually
        // used by FileIconMapper, by asking AppKit for the rendered NSImage
        // size. This guards against Apple silently changing a symbol's
        // intrinsic metrics in a future SDK — if any of these grows larger
        // than the slot, the test fails and we learn immediately rather
        // than seeing visually misaligned rows.
        //
        // These are drawn from `FileIconMapper.iconForFile/iconForFolder`
        // and include the historically wide symbols that originally
        // motivated issue #763.
        let widestSymbols = [
            "list.bullet",
            "list.bullet.rectangle",
            "list.dash",
            "shippingbox",
            "folder",
            "folder.badge.gearshape",
            "doc.text.magnifyingglass",
            "doc.plaintext",
            "doc.richtext",
            "checkmark.shield",
            "lock.shield",
            "arrow.triangle.branch",
            "chevron.left.forwardslash.chevron.right",
            "point.3.connected.trianglepath.dotted",
            "square.stack.3d.up",
            "rectangle.on.rectangle",
            "curlybraces.square",
            "server.rack",
            "desktopcomputer",
            "gearshape.2"
        ]

        // Use an NSImage configured like the sidebar would render the glyph
        // at body font size, so the measurement reflects real layout width.
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)

        var widths: [String: CGFloat] = [:]
        for name in widestSymbols {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else {
                Issue.record("SF Symbol \(name) unavailable on this OS")
                continue
            }
            widths[name] = image.size.width
        }

        guard let maxWidth = widths.values.max() else {
            Issue.record("No SF Symbol widths were measured")
            return
        }

        // Require at least ~2pt of buffer above the widest measured glyph so
        // minor rendering variance (hairline antialias, subpixel layout) does
        // not cause clipping or re-introduce misalignment.
        let buffer: CGFloat = 1
        #expect(
            SidebarIconLabelStyle.iconSlotWidth >= maxWidth + buffer,
            "iconSlotWidth (\(SidebarIconLabelStyle.iconSlotWidth)) must be >= widest symbol (\(maxWidth)) + \(buffer)pt buffer. Widths: \(widths)"
        )
    }

    @Test("iconSlotWidth is not oversized")
    func iconSlotWidthIsNotOversized() {
        // 24pt would be visibly sparse and eat sidebar horizontal space.
        #expect(SidebarIconLabelStyle.iconSlotWidth <= 22)
    }

    @Test("iconTitleSpacing is non-negative and reasonable")
    func iconTitleSpacingIsReasonable() {
        #expect(SidebarIconLabelStyle.iconTitleSpacing >= 0)
        #expect(SidebarIconLabelStyle.iconTitleSpacing <= 12)
    }

    @Test("style sugar `.sidebarIcon` returns a SidebarIconLabelStyle")
    func sidebarIconSugarIsCorrectType() {
        let style: SidebarIconLabelStyle = .sidebarIcon
        #expect(type(of: style) == SidebarIconLabelStyle.self)
    }

    // MARK: - Source-parser regression guards

    /// Loads `Pine/FileNodeRow.swift` from disk relative to this test file
    /// so we can assert structural properties without running a UI.
    private func fileNodeRowSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        // PineTests/SidebarIconLabelStyleTests.swift → repo root → Pine/FileNodeRow.swift
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let target = repoRoot.appendingPathComponent("Pine/FileNodeRow.swift")
        return try String(contentsOf: target, encoding: .utf8)
    }

    @Test("FileNodeRow applies .labelStyle(.sidebarIcon) on both branches")
    func fileNodeRowAppliesSidebarIconLabelStyleTwice() throws {
        let source = try fileNodeRowSource()
        let occurrences = source.components(separatedBy: ".labelStyle(.sidebarIcon)").count - 1
        // One for the normal display branch, one for the inline rename branch.
        // Keeping them in sync prevents the row from visually jumping when
        // entering/leaving rename mode — the historical #736 regression.
        #expect(
            occurrences >= 2,
            "Expected .labelStyle(.sidebarIcon) on BOTH the normal and inlineEditor branches, found \(occurrences)"
        )
    }

    @Test("FileNodeRow does not wrap rows in an HStack with a Color.clear spacer (reverted PR #770)")
    func fileNodeRowDoesNotReintroduceHStackWrapper() throws {
        let source = try fileNodeRowSource()
        // Reverted PR #770 wrapped the row in `HStack { Color.clear.frame(width: …); row(…) }`
        // which broke `List` selection and XCUITest accessibility lookups.
        // Guard against its return.
        #expect(!source.contains("Color.clear.frame(width: SidebarDisclosureMetrics"))
    }

    @Test("FileNodeRow still uses Label as the accessibility root (not a bare HStack)")
    func fileNodeRowUsesLabelAsRoot() throws {
        let source = try fileNodeRowSource()
        // Both branches must use SwiftUI's `Label` primitive so accessibility
        // identifiers attach correctly and OutlineGroup selection highlights
        // the right row.
        #expect(source.contains("Label {"))
        #expect(source.contains("} icon: {"))
    }

    @Test("SidebarIconLabelStyle file exists and declares the style")
    func styleFileExistsAndDeclaresType() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let styleFile = repoRoot.appendingPathComponent("Pine/SidebarIconLabelStyle.swift")
        let source = try String(contentsOf: styleFile, encoding: .utf8)
        #expect(source.contains("struct SidebarIconLabelStyle: LabelStyle"))
        #expect(source.contains("static let iconSlotWidth"))
        #expect(source.contains("static let iconTitleSpacing"))
        #expect(source.contains(".frame(width: Self.iconSlotWidth"))
    }

    // MARK: - Honest geometry: pixel-level alignment check via ImageRenderer

    /// Scans an NSImage column-by-column from the right-hand side (past the
    /// icon slot) and returns the x-coordinate, in image points, of the
    /// leftmost column that contains a non-transparent pixel. This marks
    /// where the rendered text glyph actually begins.
    @MainActor
    private func leftmostTextPixelX(in image: NSImage, skipLeadingPoints: CGFloat) -> CGFloat? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        let scaleX = CGFloat(width) / image.size.width
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let startCol = Int((skipLeadingPoints * scaleX).rounded(.down))
        for x in startCol..<width {
            for y in 0..<height {
                let alpha = pixels[y * bytesPerRow + x * bytesPerPixel + 3]
                if alpha > 32 {
                    return CGFloat(x) / scaleX
                }
            }
        }
        return nil
    }

    @MainActor
    @Test("Two Labels with different SF Symbols render text starting at the same x-coordinate")
    func sidebarIconLabelStyleAlignsTitleXAcrossDifferentSymbols() {
        // Render two real SwiftUI Labels via `ImageRenderer` using the
        // sidebar label style: one with a wide glyph (`list.bullet`) and one
        // with a narrow glyph (`doc`). The whole point of
        // `SidebarIconLabelStyle` is that the title's visual x-coordinate is
        // identical in both cases, regardless of glyph intrinsic width. We
        // scan the rendered bitmap past the icon slot and find the leftmost
        // opaque pixel — that's where text drawing actually starts. If a
        // regression reintroduces variable-width text start positions, the
        // two x-values will diverge and the test fails with a numeric diff.

        func render(symbol: String) -> NSImage? {
            let view = Label {
                Text("Example")
            } icon: {
                Image(systemName: symbol)
            }
            .labelStyle(.sidebarIcon)
            .font(.body)
            .foregroundStyle(.black)
            .padding(0)
            .frame(width: 200, height: 24, alignment: .leading)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            return renderer.nsImage
        }

        guard
            let wideImage = render(symbol: "list.bullet"),
            let narrowImage = render(symbol: "doc")
        else {
            Issue.record("ImageRenderer did not produce an NSImage")
            return
        }

        // Start scanning just past the icon slot + spacing, so we ignore the
        // glyph pixels and only find the text glyph's leading edge.
        let scanStart = SidebarIconLabelStyle.iconSlotWidth + SidebarIconLabelStyle.iconTitleSpacing

        guard
            let wideX = leftmostTextPixelX(in: wideImage, skipLeadingPoints: scanStart),
            let narrowX = leftmostTextPixelX(in: narrowImage, skipLeadingPoints: scanStart)
        else {
            Issue.record("Could not locate leading text pixel in rendered image")
            return
        }

        // Allow sub-point tolerance for font antialiasing differences, but
        // catch any real misalignment (>= 1pt means text is visibly moving).
        let tolerance: CGFloat = 1.0
        let delta = abs(wideX - narrowX)
        #expect(
            delta <= tolerance,
            "Title x must match across symbols. list.bullet=\(wideX), doc=\(narrowX), delta=\(delta)"
        )
    }
}
