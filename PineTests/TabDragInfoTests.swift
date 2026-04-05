//
//  TabDragInfoTests.swift
//  PineTests
//

import Testing
import Foundation
import CoreGraphics
import UniformTypeIdentifiers
@testable import Pine

@Suite("TabDragInfo Tests")
struct TabDragInfoTests {

    @Test func encode_producesValidJSON() {
        let paneUUID = UUID()
        let tabUUID = UUID()
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let info = TabDragInfo(paneID: paneUUID, tabID: tabUUID, fileURL: url)

        let encoded = info.encoded
        #expect(!encoded.isEmpty)
        // Should be valid JSON
        guard let data = encoded.data(using: .utf8) else {
            Issue.record("Failed to convert encoded string to data")
            return
        }
        let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        #expect(json != nil)
    }

    @Test func decode_validJSON_returnsInfo() {
        let paneUUID = UUID()
        let tabUUID = UUID()
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let info = TabDragInfo(paneID: paneUUID, tabID: tabUUID, fileURL: url)

        let decoded = TabDragInfo.decode(from: info.encoded)
        #expect(decoded != nil)
        #expect(decoded?.paneID == paneUUID)
        #expect(decoded?.tabID == tabUUID)
        #expect(decoded?.fileURL == url)
    }

    @Test func decode_invalidString_returnsNil() {
        #expect(TabDragInfo.decode(from: "invalid") == nil)
        #expect(TabDragInfo.decode(from: "{}") == nil)
        #expect(TabDragInfo.decode(from: "") == nil)
    }

    @Test func decode_invalidJSON_returnsNil() {
        #expect(TabDragInfo.decode(from: "{\"paneID\": \"not-a-uuid\"}") == nil)
    }

    @Test func roundtrip_encodeDecode() {
        let paneUUID = UUID()
        let tabUUID = UUID()
        let url = URL(fileURLWithPath: "/tmp/hello world.swift")
        let info = TabDragInfo(paneID: paneUUID, tabID: tabUUID, fileURL: url)

        let decoded = TabDragInfo.decode(from: info.encoded)
        #expect(decoded != nil)
        #expect(decoded?.paneID == paneUUID)
        #expect(decoded?.tabID == tabUUID)
        #expect(decoded?.fileURL == url)
    }

    @Test func decode_withSpecialCharsInURL_works() {
        let paneUUID = UUID()
        let tabUUID = UUID()
        let url = URL(fileURLWithPath: "/tmp/file with spaces.swift")
        let info = TabDragInfo(paneID: paneUUID, tabID: tabUUID, fileURL: url)

        let decoded = TabDragInfo.decode(from: info.encoded)
        #expect(decoded != nil)
        #expect(decoded?.fileURL == url)
    }

    @Test func paneTabDragUTType_isRegistered() {
        let utType = UTType.paneTabDrag
        #expect(utType.identifier == "com.pine.pane-tab-drag")
    }

    // MARK: - Additional encoding scenarios

    @Test func encode_withUnicodePathCharacters_roundtrips() {
        let url = URL(fileURLWithPath: "/tmp/unicode-chars.swift")
        let info = TabDragInfo(paneID: UUID(), tabID: UUID(), fileURL: url)
        let decoded = TabDragInfo.decode(from: info.encoded)
        #expect(decoded != nil)
        #expect(decoded?.fileURL == url)
    }

    @Test func encode_withDeepNestedPath_roundtrips() {
        let url = URL(fileURLWithPath: "/Users/test/Documents/projects/my-app/Sources/Models/very/deep/path/file.swift")
        let info = TabDragInfo(paneID: UUID(), tabID: UUID(), fileURL: url)
        let decoded = TabDragInfo.decode(from: info.encoded)
        #expect(decoded != nil)
        #expect(decoded?.fileURL == url)
    }

    @Test func decode_partialJSON_returnsNil() {
        let json = #"{"paneID":"00000000-0000-0000-0000-000000000000"}"#
        #expect(TabDragInfo.decode(from: json) == nil)
    }

    @Test func decode_extraFields_succeeds() {
        let paneUUID = UUID()
        let tabUUID = UUID()
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let info = TabDragInfo(paneID: paneUUID, tabID: tabUUID, fileURL: url)
        let encoded = info.encoded
        let modified = encoded.replacingOccurrences(of: "}", with: #","extra":"value"}"#)
        let decoded = TabDragInfo.decode(from: modified)
        #expect(decoded != nil)
        #expect(decoded?.paneID == paneUUID)
    }

    @Test func encode_multipleInstances_produceDifferentJSON() {
        let info1 = TabDragInfo(paneID: UUID(), tabID: UUID(), fileURL: URL(fileURLWithPath: "/a.swift"))
        let info2 = TabDragInfo(paneID: UUID(), tabID: UUID(), fileURL: URL(fileURLWithPath: "/b.swift"))
        #expect(info1.encoded != info2.encoded)
    }

    @Test func decode_nullString_returnsNil() {
        #expect(TabDragInfo.decode(from: "null") == nil)
    }

    @Test func decode_arrayJSON_returnsNil() {
        #expect(TabDragInfo.decode(from: "[]") == nil)
    }

    @Test func encode_preservesAllUUIDValues() {
        let paneUUID = UUID()
        let tabUUID = UUID()
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let info = TabDragInfo(paneID: paneUUID, tabID: tabUUID, fileURL: url)
        let encoded = info.encoded
        #expect(encoded.contains(paneUUID.uuidString.uppercased()) || encoded.contains(paneUUID.uuidString.lowercased()))
    }

    @Test func encode_includesContentType() {
        let info = TabDragInfo(
            paneID: UUID(),
            tabID: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/test.swift"),
            contentType: .editor
        )
        let encoded = info.encoded
        #expect(encoded.contains("contentType"))
        #expect(encoded.contains("editor"))
    }

    @Test func decode_terminalContentType() {
        let info = TabDragInfo(
            paneID: UUID(),
            tabID: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/test"),
            contentType: .terminal
        )
        let decoded = TabDragInfo.decode(from: info.encoded)
        #expect(decoded?.contentType == .terminal)
    }

    @Test func contentType_defaultsToEditor() {
        let paneUUID = UUID()
        let tabUUID = UUID()
        let json = """
        {"paneID":"\(paneUUID.uuidString)","tabID":"\(tabUUID.uuidString)","fileURL":"file:///tmp/test.swift"}
        """
        let decoded = TabDragInfo.decode(from: json)
        #expect(decoded?.contentType == .editor)
    }
}

@Suite("PaneDropZone Tests")
struct PaneDropZoneTests {

    @Test func equatable_sameValues_areEqual() {
        #expect(PaneDropZone.right == PaneDropZone.right)
        #expect(PaneDropZone.bottom == PaneDropZone.bottom)
        #expect(PaneDropZone.center == PaneDropZone.center)
    }

    @Test func equatable_differentValues_areNotEqual() {
        #expect(PaneDropZone.right != PaneDropZone.bottom)
        #expect(PaneDropZone.right != PaneDropZone.center)
        #expect(PaneDropZone.bottom != PaneDropZone.center)
    }

    @Test func sendable_conformance() {
        let zone: PaneDropZone = .right
        let sendableZone: any Sendable = zone
        #expect(sendableZone is PaneDropZone)
    }
}

// MARK: - PaneDropZone.zone(for:in:) Tests

@Suite("PaneDropZone.zone Tests")
struct PaneDropZoneZoneTests {
    private let size = CGSize(width: 1000, height: 800)

    // MARK: - Threshold

    @Test func edgeThreshold_isTwentyFivePercent() {
        #expect(PaneDropZone.edgeThreshold == 0.25)
    }

    // MARK: - Center zone

    @Test func centerZone_inMiddleOfView() {
        let location = CGPoint(x: 500, y: 400)
        #expect(PaneDropZone.zone(for: location, in: size) == .center)
    }

    @Test func centerZone_justInsideAllEdges() {
        // relX = 0.26, relY = 0.26 — inside all thresholds
        let location = CGPoint(x: 260, y: 210)
        #expect(PaneDropZone.zone(for: location, in: size) == .center)
    }

    // MARK: - Left zone

    @Test func leftZone_leftEdge() {
        // relX = 0.1 < 0.25, relY = 0.5 (center vertically) → left
        let location = CGPoint(x: 100, y: 400)
        #expect(PaneDropZone.zone(for: location, in: size) == .left)
    }

    @Test func leftZone_topLeftCorner_closerToLeft() {
        // relX = 0.05, relY = 0.05 — both in left and top, distToEdgeX (0.05) <= distToEdgeY (0.05) → left
        let location = CGPoint(x: 50, y: 40)
        #expect(PaneDropZone.zone(for: location, in: size) == .left)
    }

    @Test func leftZone_atOrigin() {
        // relX = 0, relY = 0 — both left and top, distToEdgeX (0) <= distToEdgeY (0) → left
        let location = CGPoint(x: 0, y: 0)
        #expect(PaneDropZone.zone(for: location, in: size) == .left)
    }

    // MARK: - Right zone

    @Test func rightZone_rightEdge() {
        // relX = 0.9 > 0.75, relY = 0.5 → right
        let location = CGPoint(x: 900, y: 400)
        #expect(PaneDropZone.zone(for: location, in: size) == .right)
    }

    @Test func rightZone_bottomRightCorner_closerToRight() {
        // relX = 0.95, relY = 0.9 — both right and bottom
        // distToEdgeX = 0.05, distToEdgeY = 0.1 → right wins (closer to edge)
        let location = CGPoint(x: 950, y: 720)
        #expect(PaneDropZone.zone(for: location, in: size) == .right)
    }

    // MARK: - Top zone

    @Test func topZone_topEdge() {
        // relX = 0.5, relY = 0.1 < 0.25 → top
        let location = CGPoint(x: 500, y: 80)
        #expect(PaneDropZone.zone(for: location, in: size) == .top)
    }

    @Test func topZone_topLeftCorner_closerToTop() {
        // relX = 0.15, relY = 0.02 — both left and top
        // distToEdgeX = 0.15, distToEdgeY = 0.02 → top wins (distToEdgeY < distToEdgeX)
        let location = CGPoint(x: 150, y: 16)
        #expect(PaneDropZone.zone(for: location, in: size) == .top)
    }

    // MARK: - Bottom zone

    @Test func bottomZone_bottomEdge() {
        // relX = 0.5, relY = 0.95 > 0.75 → bottom
        let location = CGPoint(x: 500, y: 760)
        #expect(PaneDropZone.zone(for: location, in: size) == .bottom)
    }

    @Test func bottomZone_bottomLeftCorner_closerToBottom() {
        // relX = 0.15, relY = 0.98 — both left and bottom
        // distToEdgeX = 0.15, distToEdgeY = 0.02 → bottom wins (distToEdgeY < distToEdgeX)
        let location = CGPoint(x: 150, y: 784)
        #expect(PaneDropZone.zone(for: location, in: size) == .bottom)
    }

    // MARK: - Corner disambiguation

    @Test func rightZone_winsInCorner_whenCloserToRight() {
        // relX = 0.95, relY = 0.9 — both right and bottom
        // distToEdgeX = 0.05, distToEdgeY = 0.1 → right (distToEdgeX <= distToEdgeY)
        let location = CGPoint(x: 950, y: 720)
        #expect(PaneDropZone.zone(for: location, in: size) == .right)
    }

    @Test func bottomZone_winsInCorner_whenCloserToBottom() {
        // relX = 0.8, relY = 0.98 — both right and bottom
        // distToEdgeX = 0.2, distToEdgeY = 0.02 → bottom
        let location = CGPoint(x: 800, y: 784)
        #expect(PaneDropZone.zone(for: location, in: size) == .bottom)
    }

    // MARK: - Edge cases: zero/degenerate sizes

    @Test func centerZone_zeroSize() {
        let location = CGPoint(x: 100, y: 100)
        #expect(PaneDropZone.zone(for: location, in: .zero) == .center)
    }

    @Test func centerZone_zeroWidth() {
        let zeroWidthSize = CGSize(width: 0, height: 800)
        let location = CGPoint(x: 100, y: 100)
        #expect(PaneDropZone.zone(for: location, in: zeroWidthSize) == .center)
    }

    @Test func centerZone_zeroHeight() {
        let zeroHeightSize = CGSize(width: 1000, height: 0)
        let location = CGPoint(x: 800, y: 0)
        #expect(PaneDropZone.zone(for: location, in: zeroHeightSize) == .center)
    }

    @Test func centerZone_zeroWidth_evenIfYInBottom() {
        // guard width > 0 fails → center
        let zeroWidthSize = CGSize(width: 0, height: 800)
        let location = CGPoint(x: 0, y: 700)
        #expect(PaneDropZone.zone(for: location, in: zeroWidthSize) == .center)
    }

    @Test func centerZone_zeroHeight_evenIfXInRight() {
        // guard height > 0 fails → center
        let zeroHeightSize = CGSize(width: 1000, height: 0)
        let location = CGPoint(x: 900, y: 0)
        #expect(PaneDropZone.zone(for: location, in: zeroHeightSize) == .center)
    }

    // MARK: - Boundary: exactly at threshold

    @Test func leftZone_atExactLeftThreshold() {
        // relX = 0.249 < 0.25 → left
        let location = CGPoint(x: 249, y: 400)
        #expect(PaneDropZone.zone(for: location, in: size) == .left)
    }

    @Test func centerZone_justPastLeftThreshold() {
        // relX = 0.25 (not < 0.25) → center
        let location = CGPoint(x: 250, y: 400)
        #expect(PaneDropZone.zone(for: location, in: size) == .center)
    }

    @Test func rightZone_justPastRightThreshold() {
        // relX = 0.751 > 0.75 → right
        let location = CGPoint(x: 751, y: 400)
        #expect(PaneDropZone.zone(for: location, in: size) == .right)
    }

    @Test func centerZone_atExactRightThreshold() {
        // relX = 0.75 (not > 0.75) → center
        let location = CGPoint(x: 750, y: 400)
        #expect(PaneDropZone.zone(for: location, in: size) == .center)
    }

    // MARK: - Small view

    @Test func rightZone_smallView() {
        // 100x100, threshold at 25. relX = 0.8 > 0.75 → right
        let smallSize = CGSize(width: 100, height: 100)
        let location = CGPoint(x: 80, y: 50)
        #expect(PaneDropZone.zone(for: location, in: smallSize) == .right)
    }

    @Test func bottomZone_smallView() {
        // 100x100, threshold at 25. relY = 0.8 > 0.75 → bottom
        let smallSize = CGSize(width: 100, height: 100)
        let location = CGPoint(x: 50, y: 80)
        #expect(PaneDropZone.zone(for: location, in: smallSize) == .bottom)
    }

    @Test func leftZone_smallView() {
        // 100x100, relX = 0.1 < 0.25 → left
        let smallSize = CGSize(width: 100, height: 100)
        let location = CGPoint(x: 10, y: 50)
        #expect(PaneDropZone.zone(for: location, in: smallSize) == .left)
    }

    @Test func topZone_smallView() {
        // 100x100, relY = 0.1 < 0.25 → top
        let smallSize = CGSize(width: 100, height: 100)
        let location = CGPoint(x: 50, y: 10)
        #expect(PaneDropZone.zone(for: location, in: smallSize) == .top)
    }
}

// MARK: - EditorTab.reidentified Tests

@Suite("EditorTab.reidentified Tests")
struct EditorTabReidentifiedTests {

    @Test func reidentified_generatesNewID() {
        let original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "let x = 1",
            savedContent: "let x = 1"
        )
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.id != original.id)
    }

    @Test func reidentified_preservesURL() {
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let original = EditorTab(url: url, content: "abc", savedContent: "abc")
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.url == url)
    }

    @Test func reidentified_preservesContent() {
        let original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "modified content",
            savedContent: "original content"
        )
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.content == "modified content")
        #expect(copy.savedContent == "original content")
    }

    @Test func reidentified_preservesCursorPosition() {
        var original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "let x = 1\nlet y = 2",
            savedContent: "let x = 1\nlet y = 2"
        )
        original.cursorPosition = 42
        original.cursorLine = 5
        original.cursorColumn = 10
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.cursorPosition == 42)
        #expect(copy.cursorLine == 5)
        #expect(copy.cursorColumn == 10)
    }

    @Test func reidentified_preservesScrollOffset() {
        var original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "test",
            savedContent: "test"
        )
        original.scrollOffset = 123.5
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.scrollOffset == 123.5)
    }

    @Test func reidentified_preservesFoldState() {
        var original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "test",
            savedContent: "test"
        )
        original.foldState.toggle(FoldableRange(startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 10, kind: .braces))
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.foldState.isLineHidden(2))
    }

    @Test func reidentified_preservesIsPinned() {
        var original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "test",
            savedContent: "test"
        )
        original.isPinned = true
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.isPinned == true)
    }

    @Test func reidentified_preservesSyntaxHighlightingDisabled() {
        var original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "test",
            savedContent: "test"
        )
        original.syntaxHighlightingDisabled = true
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.syntaxHighlightingDisabled == true)
    }

    @Test func reidentified_preservesIsTruncated() {
        var original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "test",
            savedContent: "test"
        )
        original.isTruncated = true
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.isTruncated == true)
    }

    @Test func reidentified_preservesEncoding() {
        var original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "test",
            savedContent: "test"
        )
        original.encoding = .utf16
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.encoding == .utf16)
    }

    @Test func reidentified_preservesPreviewMode() {
        var original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            content: "# Hello",
            savedContent: "# Hello"
        )
        original.previewMode = .split
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.previewMode == .split)
    }

    @Test func reidentified_preservesFileSizeBytes() {
        var original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "test",
            savedContent: "test"
        )
        original.fileSizeBytes = 4096
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.fileSizeBytes == 4096)
    }

    @Test func reidentified_preservesLastModDate() {
        var original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "test",
            savedContent: "test"
        )
        let date = Date(timeIntervalSince1970: 1_000_000)
        original.lastModDate = date
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.lastModDate == date)
    }

    @Test func reidentified_preservesKind() {
        let original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/image.png"),
            content: "",
            savedContent: "",
            kind: .preview
        )
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.kind == .preview)
    }

    @Test func reidentified_dirtyTab_staysDirty() {
        let original = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "modified",
            savedContent: "original"
        )
        #expect(original.isDirty)
        let copy = EditorTab.reidentified(from: original)
        #expect(copy.isDirty)
    }
}
