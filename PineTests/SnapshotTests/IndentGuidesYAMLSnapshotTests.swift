//
//  IndentGuidesYAMLSnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for indent guide rendering on a deeply nested
//  YAML-shaped document containing blank lines inside nested blocks.
//
//  These tests guard the regression flagged in the review of PR #878:
//
//   • The renderer must align guides exactly under the leading
//     whitespace of non-blank lines (NSLayoutManager glyph path).
//   • The renderer must continue drawing inherited guides through
//     blank lines inside nested blocks (calculator fallback path).
//   • Both paths must produce pixel-snapped, crisp 1pt strokes.
//
//  Implementation note:
//    Snapshotting the full `CodeEditorView` requires a `ProjectManager`
//    + `TabManager` graph that is hard to stub deterministically. Instead
//    we build a minimal `GutterTextView` host inside an `NSScrollView`
//    and let it run the *real* `drawBackground(in:)` -> `IndentGuideRenderer.draw(...)`
//    path. This exercises the same code that ships, just without the
//    surrounding editor chrome (line numbers, status bar, syntax colors).
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("IndentGuides YAML Snapshots")
@MainActor
struct IndentGuidesYAMLSnapshotTests {

    /// A YAML-shaped fixture with three+ levels of nesting and blank
    /// lines inside nested blocks. The blank rows force the renderer
    /// to exercise the inherited-indent fallback path.
    private static let yamlFixture: String = """
    project:
      name: pine
      version: 1.25.1

      build:
        target: macos
        sdk: 26.0

        flags:
          - -O2
          - -warnings-as-errors

      tests:
        unit:
          - PineTests
          - PineUITests

        coverage:
          threshold: 70
    """

    /// SwiftUI host that wraps a `GutterTextView` populated with the
    /// fixture text and the same indent style the editor would use for
    /// a YAML file (2-space indentation).
    private struct IndentGuideHost: NSViewRepresentable {
        let text: String
        let size: NSSize

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.borderType = .noBorder
            scroll.drawsBackground = true
            scroll.backgroundColor = NSColor.textBackgroundColor

            let textContainer = NSTextContainer(
                size: NSSize(width: size.width, height: .greatestFiniteMagnitude)
            )
            textContainer.widthTracksTextView = true
            let layoutManager = NSLayoutManager()
            let storage = NSTextStorage(string: text)
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(textContainer)

            let textView = GutterTextView(
                frame: NSRect(origin: .zero, size: size),
                textContainer: textContainer
            )
            // Use a stable monospaced font so glyph advance is deterministic
            // across machines.
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.font = font

            // Mirror the editor's paragraph style so tab stops match what the
            // production code sees (relevant for the tab-based path; the YAML
            // fixture uses spaces but we set this for parity).
            let paragraph = NSMutableParagraphStyle()
            paragraph.defaultTabInterval = 28
            paragraph.tabStops = (1...20).map { i in
                NSTextTab(textAlignment: .left, location: CGFloat(i) * 28, options: [:])
            }
            textView.defaultParagraphStyle = paragraph
            textView.textStorage?.addAttributes(
                [.font: font, .paragraphStyle: paragraph],
                range: NSRange(location: 0, length: storage.length)
            )

            // 2-space indentation matches typical YAML.
            textView.indentStyle = .spaces(2)
            textView.gutterInset = 0 // No line-number gutter for snapshot stability
            textView.textContainerInset = NSSize(width: 0, height: 8)
            textView.isEditable = false
            textView.isSelectable = false

            scroll.documentView = textView
            textView.layoutManager?.ensureLayout(for: textContainer)
            return scroll
        }

        func updateNSView(_ nsView: NSScrollView, context: Context) {}
    }

    // Indent guides are 8% alpha strokes — small font hinting differences
    // between machines can shift a few sub-pixel rows. The default 0.01
    // tolerance still catches whole-line misalignment (e.g. a missing
    // guide on a blank line) without being noisy on cosmetic AA noise.
    private static let tolerance = 0.02

    @Test("Indent guides on YAML render in light appearance")
    func yamlIndentGuidesLight() throws {
        let host = IndentGuideHost(
            text: Self.yamlFixture,
            size: NSSize(width: 360, height: 280)
        )
        try assertSnapshot(
            of: host,
            size: NSSize(width: 360, height: 280),
            appearance: .light,
            named: "IndentGuidesYAML.light",
            tolerance: Self.tolerance
        )
    }

    @Test("Indent guides on YAML render in dark appearance")
    func yamlIndentGuidesDark() throws {
        let host = IndentGuideHost(
            text: Self.yamlFixture,
            size: NSSize(width: 360, height: 280)
        )
        try assertSnapshot(
            of: host,
            size: NSSize(width: 360, height: 280),
            appearance: .dark,
            named: "IndentGuidesYAML.dark",
            tolerance: Self.tolerance
        )
    }
}
