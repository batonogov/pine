//
//  EditorTabItemSnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for EditorTabItem in light and dark appearances.
//  Covers active/inactive, dirty, and pinned states.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("EditorTabItem Snapshots")
@MainActor
struct EditorTabItemSnapshotTests {

    /// Creates a deterministic EditorTab for snapshot tests.
    private func makeTab(
        fileName: String = "main.swift",
        isDirty: Bool = false,
        isPinned: Bool = false
    ) -> EditorTab {
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/test/\(fileName)"),
            content: isDirty ? "modified" : "original",
            savedContent: "original"
        )
        tab.isPinned = isPinned
        return tab
    }

    /// Wrapper view that provides the tab item in isolation.
    private struct Harness: View {
        let tab: EditorTab
        let isActive: Bool
        let constrainedWidth: CGFloat

        var body: some View {
            EditorTabItem(
                tab: tab,
                isActive: isActive,
                onSelect: {},
                onClose: {},
                constrainedWidth: constrainedWidth
            )
            .padding(8)
        }
    }

    private static let tabSize = NSSize(width: 200, height: 40)

    // MARK: - Active tab

    @Test("Active tab renders in light appearance")
    func activeTabLight() throws {
        let tab = makeTab()
        try assertSnapshot(
            of: Harness(tab: tab, isActive: true, constrainedWidth: 180),
            size: Self.tabSize,
            appearance: .light,
            named: "EditorTabItem.active.light"
        )
    }

    @Test("Active tab renders in dark appearance")
    func activeTabDark() throws {
        let tab = makeTab()
        try assertSnapshot(
            of: Harness(tab: tab, isActive: true, constrainedWidth: 180),
            size: Self.tabSize,
            appearance: .dark,
            named: "EditorTabItem.active.dark"
        )
    }

    // MARK: - Inactive tab

    @Test("Inactive tab renders in light appearance")
    func inactiveTabLight() throws {
        let tab = makeTab()
        try assertSnapshot(
            of: Harness(tab: tab, isActive: false, constrainedWidth: 180),
            size: Self.tabSize,
            appearance: .light,
            named: "EditorTabItem.inactive.light"
        )
    }

    @Test("Inactive tab renders in dark appearance")
    func inactiveTabDark() throws {
        let tab = makeTab()
        try assertSnapshot(
            of: Harness(tab: tab, isActive: false, constrainedWidth: 180),
            size: Self.tabSize,
            appearance: .dark,
            named: "EditorTabItem.inactive.dark"
        )
    }

    // MARK: - Dirty tab

    @Test("Dirty active tab renders in light appearance")
    func dirtyTabLight() throws {
        let tab = makeTab(isDirty: true)
        try assertSnapshot(
            of: Harness(tab: tab, isActive: true, constrainedWidth: 180),
            size: Self.tabSize,
            appearance: .light,
            named: "EditorTabItem.dirty.light"
        )
    }

    @Test("Dirty active tab renders in dark appearance")
    func dirtyTabDark() throws {
        let tab = makeTab(isDirty: true)
        try assertSnapshot(
            of: Harness(tab: tab, isActive: true, constrainedWidth: 180),
            size: Self.tabSize,
            appearance: .dark,
            named: "EditorTabItem.dirty.dark"
        )
    }

    // MARK: - Dirty inactive tab

    @Test("Dirty inactive tab renders in light appearance")
    func dirtyInactiveTabLight() throws {
        let tab = makeTab(isDirty: true)
        try assertSnapshot(
            of: Harness(tab: tab, isActive: false, constrainedWidth: 180),
            size: Self.tabSize,
            appearance: .light,
            named: "EditorTabItem.dirtyInactive.light"
        )
    }

    @Test("Dirty inactive tab renders in dark appearance")
    func dirtyInactiveTabDark() throws {
        let tab = makeTab(isDirty: true)
        try assertSnapshot(
            of: Harness(tab: tab, isActive: false, constrainedWidth: 180),
            size: Self.tabSize,
            appearance: .dark,
            named: "EditorTabItem.dirtyInactive.dark"
        )
    }

    // MARK: - Pinned tab (active)

    @Test("Pinned active tab renders in light appearance")
    func pinnedTabLight() throws {
        let tab = makeTab(isPinned: true)
        try assertSnapshot(
            of: Harness(tab: tab, isActive: true, constrainedWidth: 40),
            size: NSSize(width: 60, height: 40),
            appearance: .light,
            named: "EditorTabItem.pinned.light"
        )
    }

    @Test("Pinned active tab renders in dark appearance")
    func pinnedTabDark() throws {
        let tab = makeTab(isPinned: true)
        try assertSnapshot(
            of: Harness(tab: tab, isActive: true, constrainedWidth: 40),
            size: NSSize(width: 60, height: 40),
            appearance: .dark,
            named: "EditorTabItem.pinned.dark"
        )
    }

    // MARK: - Pinned tab (inactive)

    @Test("Pinned inactive tab renders in light appearance")
    func pinnedInactiveTabLight() throws {
        let tab = makeTab(isPinned: true)
        try assertSnapshot(
            of: Harness(tab: tab, isActive: false, constrainedWidth: 40),
            size: NSSize(width: 60, height: 40),
            appearance: .light,
            named: "EditorTabItem.pinnedInactive.light"
        )
    }

    @Test("Pinned inactive tab renders in dark appearance")
    func pinnedInactiveTabDark() throws {
        let tab = makeTab(isPinned: true)
        try assertSnapshot(
            of: Harness(tab: tab, isActive: false, constrainedWidth: 40),
            size: NSSize(width: 60, height: 40),
            appearance: .dark,
            named: "EditorTabItem.pinnedInactive.dark"
        )
    }
}
