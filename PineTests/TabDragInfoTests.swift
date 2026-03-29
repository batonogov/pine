//
//  TabDragInfoTests.swift
//  PineTests
//

import Testing
import Foundation
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
}
