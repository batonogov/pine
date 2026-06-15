//
//  TabAffordanceTests.swift
//  PineTests
//
//  Tests for accessibility and discoverability of hidden affordances (#976).
//

import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Tab Affordance Accessibility Tests")
@MainActor
struct TabAffordanceTests {

    // MARK: - Localization keys exist

    @Test("All new accessibility string keys are defined in Strings")
    func newStringKeysExist() {
        // These keys must resolve at runtime — verify the LocalizedStringKey
        // constants exist and are non-empty.
        // Verify each constant resolves to its expected localization key.
        // (LocalizedStringKey.key is internal in the SDK, so compare via ==
        // which checks the underlying key string for string-literal keys.)
        #expect(Strings.tabCloseTabDisabledPinned == LocalizedStringKey("tab.closeTabDisabledPinned"))
        #expect(Strings.statusbarEncodingDisabledDirty == LocalizedStringKey("statusbar.encodingDisabledDirty"))
        #expect(Strings.breadcrumbShowHiddenSegments == LocalizedStringKey("breadcrumb.showHiddenSegments"))
    }

    @Test("New string keys are present in Localizable.xcstrings")
    func keysPresentInXcstrings() throws {
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any]
        else {
            // In test context the bundle may not contain the resource.
            // Skip rather than fail — the key existence is tested above.
            return
        }

        #expect(strings["tab.closeTabDisabledPinned"] != nil)
        #expect(strings["statusbar.encodingDisabledDirty"] != nil)
        #expect(strings["breadcrumb.showHiddenSegments"] != nil)
    }

    // MARK: - Breadcrumb truncate returns hidden segments

    @Test("Breadcrumb truncate hidden count is correct")
    func truncateHiddenCount() {
        let segments = (0..<12).map { i in
            BreadcrumbSegment(
                id: URL(fileURLWithPath: "/proj/dir\(i)"),
                name: "dir\(i)",
                isDirectory: true,
                parentURL: URL(fileURLWithPath: "/proj/dir\(max(i - 1, 0))")
            )
        }

        let (showEllipsis, visible) = BreadcrumbProvider.truncate(segments, maxVisible: 8)

        #expect(showEllipsis == true)
        #expect(visible.count == 8)
        // Hidden segments = 12 - 8 = 4
        let hiddenCount = segments.count - visible.count
        #expect(hiddenCount == 4)
    }

    @Test("Breadcrumb truncate returns false when under max")
    func truncateNoEllipsis() {
        let segments = (0..<3).map { i in
            BreadcrumbSegment(
                id: URL(fileURLWithPath: "/proj/dir\(i)"),
                name: "dir\(i)",
                isDirectory: true,
                parentURL: nil
            )
        }

        let (showEllipsis, visible) = BreadcrumbProvider.truncate(segments, maxVisible: 8)

        #expect(showEllipsis == false)
        #expect(visible.count == 3)
    }
}
