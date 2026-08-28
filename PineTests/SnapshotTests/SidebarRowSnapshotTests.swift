//
//  SidebarRowSnapshotTests.swift
//  PineTests
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Sidebar row snapshots")
@MainActor
struct SidebarRowSnapshotTests {
    private static let size = NSSize(width: 250, height: 28)

    @Test("Interaction states render distinctly in light and dark")
    func interactionStates() throws {
        for snapshot in Self.snapshots {
            for appearance in [SnapshotAppearance.light, .dark] {
                try assertSnapshot(
                    of: Harness(snapshot: snapshot),
                    size: Self.size,
                    appearance: appearance,
                    named: "SidebarRow.\(snapshot.name).\(appearance.suffix)"
                )
            }
        }
    }

    @Test("Git status rows render a distinct badge in light and dark")
    func gitStatusRows() throws {
        // #1532: modified, conflicted, and untracked cover the ambiguous
        // pairs and the "?" case the issue names.
        let statuses: [(name: String, status: GitFileStatus)] = [
            ("git-modified", .modified),
            ("git-conflict", .conflict),
            ("git-untracked", .untracked),
        ]
        for status in statuses {
            for appearance in [SnapshotAppearance.light, .dark] {
                try assertSnapshot(
                    of: Harness(
                        snapshot: Snapshot(
                            name: status.name,
                            state: SidebarRowVisualState(),
                            gitStatus: status.status
                        )
                    ),
                    size: Self.size,
                    appearance: appearance,
                    named: "SidebarRow.\(status.name).\(appearance.suffix)"
                )
            }
        }
    }

    private static let snapshots: [Snapshot] = [
        Snapshot(
            name: "selected-unfocused",
            state: SidebarRowVisualState(isSelected: true)
        ),
        Snapshot(
            name: "selected-focused",
            state: SidebarRowVisualState(
                isSelected: true,
                isKeyboardFocused: true
            )
        ),
        Snapshot(
            name: "hovered",
            state: SidebarRowVisualState(isHovered: true)
        ),
        Snapshot(
            name: "active",
            state: SidebarRowVisualState(isActiveFile: true)
        ),
        Snapshot(
            name: "preview",
            state: SidebarRowVisualState(
                isActiveFile: true,
                isTransientPreview: true
            )
        ),
        Snapshot(
            name: "expanded",
            state: SidebarRowVisualState(isExpanded: true),
            isDirectory: true
        ),
        Snapshot(
            name: "missing",
            state: SidebarRowVisualState(isMissing: true)
        ),
    ]

    private struct Snapshot {
        let name: String
        let state: SidebarRowVisualState
        var isDirectory = false
        var gitStatus: GitFileStatus?
    }

    private struct Harness: View {
        let snapshot: Snapshot

        var body: some View {
            SidebarRowChrome(
                state: snapshot.state,
                rowHeight: SidebarRowMetrics.minRowHeight
            ) {
                SidebarRowLabel(
                    name: snapshot.isDirectory ? "Sources" : "main.swift",
                    iconName: snapshot.isDirectory ? "folder" : "swift",
                    iconColor: snapshot.isDirectory ? .blue : .orange,
                    textColor: snapshot.gitStatus?.color ?? .primary,
                    isDirectory: snapshot.isDirectory,
                    state: snapshot.state,
                    gitStatus: snapshot.gitStatus
                )
                .font(.system(size: 13))
            }
            .padding(.vertical, 4)
        }
    }
}
