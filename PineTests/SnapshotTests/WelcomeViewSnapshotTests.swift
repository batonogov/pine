//
//  WelcomeViewSnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for WelcomeView in light and dark appearances.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("WelcomeView Snapshots")
@MainActor
struct WelcomeViewSnapshotTests {

    /// Builds a registry with a deterministic (fake) list of recent projects so the
    /// snapshot is stable across machines and CI runs.
    private func makeRegistry() -> ProjectRegistry {
        let registry = ProjectRegistry()
        registry.recentProjects = [
            URL(fileURLWithPath: "/Users/tester/Projects/pine"),
            URL(fileURLWithPath: "/Users/tester/Projects/hello-world"),
            URL(fileURLWithPath: "/Users/tester/Projects/snapshot-demo")
        ]
        return registry
    }

    @Test("WelcomeView renders in light appearance")
    func welcomeLight() throws {
        let view = WelcomeView(registry: makeRegistry())
        try assertSnapshot(
            of: view,
            size: NSSize(width: 720, height: 460),
            appearance: .light,
            named: "WelcomeView.light"
        )
    }

    @Test("WelcomeView renders in dark appearance")
    func welcomeDark() throws {
        let view = WelcomeView(registry: makeRegistry())
        try assertSnapshot(
            of: view,
            size: NSSize(width: 720, height: 460),
            appearance: .dark,
            named: "WelcomeView.dark"
        )
    }
}
