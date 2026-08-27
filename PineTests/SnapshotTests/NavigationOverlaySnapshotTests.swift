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

    /// Renders a GoToLineView inside `CommandOverlayWindow.ContentWrapper` —
    /// the exact SwiftUI chrome the panel coordinator hosts in the real
    /// `NSPanel` (backdrop dim, `.regularMaterial` card, corner radius,
    /// shadow, and the wrapper's padding).
    ///
    /// The window itself is one level higher and deliberately not what this
    /// snapshot pins: `CommandOverlayWindow` presents a real `NSPanel`
    /// ordered above the owner window, and the bitmap harness rasterizes a
    /// hosted view, not sibling windows — the panel would never reach the
    /// pixels under test. Snapshots previously went through the dead
    /// `CommandOverlayView` instead (#1561), which asserted nothing about
    /// shipped UI; hosting `ContentWrapper` pins the chrome users actually
    /// see.
    private struct OverlayHarness: View {
        @State private var isPresented = true
        var body: some View {
            Color.clear.overlay {
                CommandOverlayWindow<GoToLineView>.ContentWrapper(
                    content: GoToLineView(
                        totalLines: 1234,
                        isPresented: $isPresented
                    ) { _, _ in },
                    containerIdentifier: AccessibilityID.goToLineOverlay,
                    onDismiss: { isPresented = false }
                )
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
