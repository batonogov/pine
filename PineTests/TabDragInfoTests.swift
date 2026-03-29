//
//  TabDragInfoTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("TabDragInfo Tests")
struct TabDragInfoTests {

    @Test func encode_producesExpectedFormat() {
        let paneUUID = UUID()
        let tabUUID = UUID()
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let info = TabDragInfo(paneID: paneUUID, tabID: tabUUID, fileURL: url)

        let encoded = info.encoded
        #expect(encoded.contains(paneUUID.uuidString))
        #expect(encoded.contains(tabUUID.uuidString))
        #expect(encoded.contains(url.absoluteString))
        #expect(encoded.components(separatedBy: "|").count == 3)
    }

    @Test func decode_validString_returnsInfo() {
        let paneUUID = UUID()
        let tabUUID = UUID()
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let string = "\(paneUUID.uuidString)|\(tabUUID.uuidString)|\(url.absoluteString)"

        let decoded = TabDragInfo.decode(from: string)
        #expect(decoded != nil)
        #expect(decoded?.paneID == paneUUID)
        #expect(decoded?.tabID == tabUUID)
        #expect(decoded?.fileURL == url)
    }

    @Test func decode_invalidString_returnsNil() {
        #expect(TabDragInfo.decode(from: "invalid") == nil)
        #expect(TabDragInfo.decode(from: "a|b") == nil)
        #expect(TabDragInfo.decode(from: "") == nil)
    }

    @Test func decode_invalidUUIDs_returnsNil() {
        #expect(TabDragInfo.decode(from: "not-uuid|not-uuid|file:///test") == nil)
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
        let string = "\(paneUUID.uuidString)|\(tabUUID.uuidString)|\(url.absoluteString)"

        let decoded = TabDragInfo.decode(from: string)
        #expect(decoded != nil)
        #expect(decoded?.fileURL == url)
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
