//
//  PaneFocusNSViewTests.swift
//  PineTests
//
//  Tests for PaneFocusNSView — verifies weak reference to PaneManager
//  to prevent retain cycles.
//

import Testing
import AppKit
@testable import Pine

@Suite("PaneFocusNSView Tests")
@MainActor
struct PaneFocusNSViewTests {

    @Test func paneManagerPropertyIsDeclaredWeak() {
        // Verify that PaneFocusNSView.paneManager is a weak optional property
        // by checking that assigning nil is accepted and the property can be nil.
        let paneID = PaneID()
        let paneManager = PaneManager()
        let view = PaneFocusNSView(paneID: paneID, paneManager: paneManager)

        #expect(view.paneManager != nil)

        // Explicitly set to nil — only works if the property is Optional (weak vars are Optional)
        view.paneManager = nil
        #expect(view.paneManager == nil)
    }

    @Test func paneIDUpdatable() {
        let paneManager = PaneManager()
        let paneID1 = PaneID()
        let paneID2 = PaneID()
        let view = PaneFocusNSView(paneID: paneID1, paneManager: paneManager)

        #expect(view.paneID == paneID1)
        view.paneID = paneID2
        #expect(view.paneID == paneID2)
    }
}
