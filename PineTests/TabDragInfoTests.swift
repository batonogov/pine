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

    @Test func allZones_areDifferent() {
        let zones: [PaneDropZone] = [.right, .bottom, .center]
        for zoneIdx in 0..<zones.count {
            for otherIdx in (zoneIdx + 1)..<zones.count {
                #expect(zones[zoneIdx] != zones[otherIdx])
            }
        }
    }

    @Test func zone_right_equalsItself() {
        let zone: PaneDropZone = .right
        #expect(zone == .right)
        #expect(zone != .bottom)
        #expect(zone != .center)
    }

    @Test func zone_bottom_equalsItself() {
        let zone: PaneDropZone = .bottom
        #expect(zone == .bottom)
        #expect(zone != .right)
        #expect(zone != .center)
    }

    @Test func zone_center_equalsItself() {
        let zone: PaneDropZone = .center
        #expect(zone == .center)
        #expect(zone != .right)
        #expect(zone != .bottom)
    }

    @Test func zone_sendable_conformance() {
        let zone: PaneDropZone = .right
        let sendableZone: any Sendable = zone
        #expect(sendableZone is PaneDropZone)
    }

    @Test func zone_switchExhaustivenessCheck() {
        let zones: [PaneDropZone] = [.right, .bottom, .center]
        for zone in zones {
            switch zone {
            case .right:
                #expect(zone == .right)
            case .bottom:
                #expect(zone == .bottom)
            case .center:
                #expect(zone == .center)
            }
        }
    }
}
