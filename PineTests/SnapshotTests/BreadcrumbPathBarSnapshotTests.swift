//
//  BreadcrumbPathBarSnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for BreadcrumbPathBar in light and dark appearances.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("BreadcrumbPathBar Snapshots")
@MainActor
struct BreadcrumbPathBarSnapshotTests {

    private static let barSize = NSSize(width: 500, height: 28)

    /// Wrapper for snapshot isolation — BreadcrumbPathBar does not
    /// use any Environment dependencies, just URL parameters.
    private struct Harness: View {
        let fileURL: URL
        let projectRoot: URL

        var body: some View {
            BreadcrumbPathBar(
                fileURL: fileURL,
                projectRoot: projectRoot,
                onOpenFile: { _ in }
            )
        }
    }

    @Test("BreadcrumbPathBar renders in light appearance")
    func breadcrumbLight() throws {
        let view = Harness(
            fileURL: URL(fileURLWithPath: "/Projects/pine/Pine/Views/ContentView.swift"),
            projectRoot: URL(fileURLWithPath: "/Projects/pine")
        )
        try assertSnapshot(
            of: view,
            size: Self.barSize,
            appearance: .light,
            named: "BreadcrumbPathBar.light"
        )
    }

    @Test("BreadcrumbPathBar renders in dark appearance")
    func breadcrumbDark() throws {
        let view = Harness(
            fileURL: URL(fileURLWithPath: "/Projects/pine/Pine/Views/ContentView.swift"),
            projectRoot: URL(fileURLWithPath: "/Projects/pine")
        )
        try assertSnapshot(
            of: view,
            size: Self.barSize,
            appearance: .dark,
            named: "BreadcrumbPathBar.dark"
        )
    }

    @Test("BreadcrumbPathBar with deep path renders in light appearance")
    func deepPathLight() throws {
        let view = Harness(
            fileURL: URL(fileURLWithPath: "/Projects/pine/Pine/Views/Editor/Gutter/LineNumberView.swift"),
            projectRoot: URL(fileURLWithPath: "/Projects/pine")
        )
        try assertSnapshot(
            of: view,
            size: Self.barSize,
            appearance: .light,
            named: "BreadcrumbPathBar.deep.light"
        )
    }

    @Test("BreadcrumbPathBar with deep path renders in dark appearance")
    func deepPathDark() throws {
        let view = Harness(
            fileURL: URL(fileURLWithPath: "/Projects/pine/Pine/Views/Editor/Gutter/LineNumberView.swift"),
            projectRoot: URL(fileURLWithPath: "/Projects/pine")
        )
        try assertSnapshot(
            of: view,
            size: Self.barSize,
            appearance: .dark,
            named: "BreadcrumbPathBar.deep.dark"
        )
    }
}
