//
//  SidebarProjectHeaderTests.swift
//  PineTests
//
//  Visibility policy for the sidebar's project header and the toolbar
//  capsule that stands in for it when the sidebar is collapsed.
//

import SwiftUI
import Testing

@testable import Pine

@Suite("Sidebar Project Header Visibility")
struct SidebarProjectHeaderVisibilityTests {

    @Test("the header appears once the workspace holds a project root")
    func headerAppearsWithProjectRoot() {
        #expect(
            ContentView.showsSidebarProjectHeader(
                rootURL: URL(fileURLWithPath: "/tmp/project")
            )
        )
    }

    @Test("no project root means no header; the empty state offers Open Folder")
    func headerHiddenWithoutProjectRoot() {
        #expect(ContentView.showsSidebarProjectHeader(rootURL: nil) == false)
    }
}

@Suite("Toolbar Switcher Fallback Visibility")
struct ToolbarSwitcherFallbackVisibilityTests {

    @Test("the toolbar capsule appears only with a collapsed sidebar")
    func capsuleAppearsWhenSidebarCollapsed() {
        #expect(
            ContentView.showsToolbarProjectSwitcher(
                columnVisibility: .detailOnly
            )
        )
    }

    @Test("a visible sidebar owns the switcher, so the capsule stays away")
    func capsuleHiddenWhenSidebarVisible() {
        #expect(
            ContentView.showsToolbarProjectSwitcher(
                columnVisibility: .all
            ) == false
        )
        #expect(
            ContentView.showsToolbarProjectSwitcher(
                columnVisibility: .doubleColumn
            ) == false
        )
    }
}
