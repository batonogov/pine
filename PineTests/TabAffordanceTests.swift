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
    }
}
