//
//  SymbolNavigatorUnsupportedSnapshotTests.swift
//  PineTests
//
//  Unsupported languages retain the existing empty Symbol Navigator UI
//  while structural providers fall back behind the scenes (#1008).
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Unsupported Symbol Navigator Snapshots")
@MainActor
struct SymbolNavigatorUnsupportedSnapshotTests {
    private struct Harness: View {
        @State private var isPresented = true
        private let projectManager: ProjectManager

        init() {
            let projectManager = ProjectManager()
            let tab = EditorTab(
                url: URL(
                    fileURLWithPath:
                        "/snapshot/Notes.pine-unsupported"
                ),
                content: "plain text without declarations",
                savedContent: "plain text without declarations"
            )
            projectManager.primaryTabManager.tabs = [tab]
            projectManager.primaryTabManager.activeTabID = tab.id
            self.projectManager = projectManager
        }

        var body: some View {
            SymbolNavigatorView(isPresented: $isPresented)
                .environment(projectManager)
                .environment(\.locale, Locale(identifier: "en"))
        }
    }

    @Test("Unsupported language stays unchanged in light appearance")
    func light() throws {
        try assertSnapshot(
            of: Harness(),
            size: NSSize(width: 500, height: 360),
            appearance: .light,
            named: "SymbolNavigator.unsupported.light"
        )
    }

    @Test("Unsupported language stays unchanged in dark appearance")
    func dark() throws {
        try assertSnapshot(
            of: Harness(),
            size: NSSize(width: 500, height: 360),
            appearance: .dark,
            named: "SymbolNavigator.unsupported.dark"
        )
    }
}
