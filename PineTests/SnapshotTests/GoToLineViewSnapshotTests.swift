//
//  GoToLineViewSnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for GoToLineView in light and dark appearances.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("GoToLineView Snapshots")
@MainActor
struct GoToLineViewSnapshotTests {

    private struct Harness: View {
        @State private var isPresented = true
        var body: some View {
            GoToLineView(totalLines: 1234, isPresented: $isPresented) { _, _ in }
        }
    }

    @Test("GoToLineView renders in light appearance")
    func goToLineLight() throws {
        try assertSnapshot(
            of: Harness(),
            size: NSSize(width: 260, height: 140),
            appearance: .light,
            named: "GoToLineView.light"
        )
    }

    @Test("GoToLineView renders in dark appearance")
    func goToLineDark() throws {
        try assertSnapshot(
            of: Harness(),
            size: NSSize(width: 260, height: 140),
            appearance: .dark,
            named: "GoToLineView.dark"
        )
    }
}
