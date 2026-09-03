//
//  BranchSwitcherSnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for BranchSwitcherView in light and dark appearances.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("BranchSwitcherView Snapshots")
@MainActor
struct BranchSwitcherSnapshotTests {

    /// Provides a GitStatusProvider populated with a deterministic branch list
    /// so snapshots do not depend on the host machine's git state.
    private func makeProvider() -> GitStatusProvider {
        let provider = GitStatusProvider()
        provider.isGitRepository = true
        provider.currentBranch = "main"
        provider.branches = [
            "main",
            "feature/snapshot-tests",
            "fix/branch-switcher",
            "chore/update-deps",
            "release/0.14.0"
        ]
        return provider
    }

    /// Wrapper that supplies the `isPresented` binding required by the view.
    private struct Harness: View {
        var provider: GitStatusProvider
        @State private var isPresented = true
        var body: some View {
            BranchSwitcherView(gitProvider: provider, isPresented: $isPresented)
                .padding(12)
        }
    }

    @Test("BranchSwitcherView renders in light appearance")
    func branchSwitcherLight() throws {
        try assertSnapshot(
            of: Harness(provider: makeProvider()),
            size: NSSize(width: 320, height: 260),
            appearance: .light,
            named: "BranchSwitcherView.light"
        )
    }

    @Test("BranchSwitcherView renders in dark appearance")
    func branchSwitcherDark() throws {
        try assertSnapshot(
            of: Harness(provider: makeProvider()),
            size: NSSize(width: 320, height: 260),
            appearance: .dark,
            named: "BranchSwitcherView.dark"
        )
    }

    // #1540 — the error footer must pair the message with a symbol so the
    // failure state is never carried by the red hue alone.
    @Test("Branch switcher error message carries a symbol cue (light)")
    func branchSwitcherErrorRowLight() throws {
        try assertSnapshot(
            of: BranchSwitcherErrorRow(message: "error: pathspec 'nope' did not match")
                .padding(12),
            size: NSSize(width: 320, height: 60),
            appearance: .light,
            named: "BranchSwitcherErrorRow.light"
        )
    }

    @Test("Branch switcher error message carries a symbol cue (dark)")
    func branchSwitcherErrorRowDark() throws {
        try assertSnapshot(
            of: BranchSwitcherErrorRow(message: "error: pathspec 'nope' did not match")
                .padding(12),
            size: NSSize(width: 320, height: 60),
            appearance: .dark,
            named: "BranchSwitcherErrorRow.dark"
        )
    }
}
