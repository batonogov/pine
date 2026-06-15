//
//  NavigationOverlaySnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for command overlay presentations.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Navigation Overlay Snapshots")
@MainActor
struct NavigationOverlaySnapshotTests {

    /// Harness that renders a GoToLineView inside a CommandOverlayView,
    /// simulating the overlay presentation over a plain editor background.
    private struct OverlayHarness: View {
        @State private var isPresented = true
        var body: some View {
            Color.clear.overlay {
                CommandOverlayView(isPresented: $isPresented) {
                    GoToLineView(totalLines: 1234, isPresented: $isPresented) { _, _ in }
                }
            }
        }
    }

    @Test("GoToLine overlay renders in light appearance")
    func goToLineOverlayLight() throws {
        try assertSnapshot(
            of: OverlayHarness(),
            size: NSSize(width: 400, height: 200),
            appearance: .light,
            named: "GoToLine.overlay.light"
        )
    }

    @Test("GoToLine overlay renders in dark appearance")
    func goToLineOverlayDark() throws {
        try assertSnapshot(
            of: OverlayHarness(),
            size: NSSize(width: 400, height: 200),
            appearance: .dark,
            named: "GoToLine.overlay.dark"
        )
    }
}
