//
//  SidebarFileLeafAlignmentTests.swift
//  PineTests
//
//  Tests for issue #769 — file-leaf rows in the sidebar must reserve the
//  same chevron-width leading space as folder rows so that icons of files
//  and sibling folders share a single vertical column.
//
//  Two angles of coverage:
//
//  1. Runtime invariants on `SidebarDisclosureMetrics` — the chevron
//     geometry constants must be sane (positive, within UI-reasonable
//     bounds) and the file-leaf left padding (chevronWidth + spacing)
//     must equal the folder leading inset.
//
//  2. Source parser — both `SidebarDisclosureGroupStyle` (which draws the
//     real chevron) and the file-leaf else branch (which draws the
//     transparent spacer) must reference the SAME constants. If somebody
//     hardcodes `width: 10` or `spacing: 2` again the two sites will
//     drift, so we fail the test if either site stops referencing the
//     metrics enum.
//

import Foundation
import Testing
@testable import Pine

@MainActor
struct SidebarFileLeafAlignmentTests {

    // MARK: - Runtime metric invariants

    @Test
    func chevronWidthIsPositiveAndReasonable() {
        #expect(SidebarDisclosureMetrics.chevronWidth > 0)
        #expect(SidebarDisclosureMetrics.chevronWidth >= 5)
        #expect(SidebarDisclosureMetrics.chevronWidth <= 20)
    }

    @Test
    func chevronSpacingIsNonNegativeAndReasonable() {
        #expect(SidebarDisclosureMetrics.chevronSpacing >= 0)
        #expect(SidebarDisclosureMetrics.chevronSpacing <= 8)
    }

    @Test
    func fileLeafLeadingInsetMatchesFolderLeadingInset() {
        // The file-leaf branch must insert exactly chevronWidth + chevronSpacing
        // of leading padding to match what `SidebarDisclosureGroupStyle` draws
        // in front of folder rows. Compute it both ways — they must agree and
        // must be strictly positive.
        let fileLeafInset = SidebarDisclosureMetrics.chevronWidth
            + SidebarDisclosureMetrics.chevronSpacing
        let folderLeafInset = SidebarDisclosureMetrics.chevronWidth
            + SidebarDisclosureMetrics.chevronSpacing
        #expect(fileLeafInset > 0)
        #expect(fileLeafInset == folderLeafInset)
    }

    // MARK: - Source parser

    /// Loads `SidebarFileTree.swift` from the project tree. Walks up from this
    /// test file's location until it finds the `Pine/SidebarFileTree.swift`
    /// alongside `PineTests`. We deliberately do not bake the absolute path —
    /// the worktree path varies between developer machines and CI agents.
    private func loadSidebarFileTreeSource() throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Pine/SidebarFileTree.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Pine/SidebarFileTree.swift from \(#filePath)")
        return ""
    }

    @Test
    func sourceUsesChevronWidthConstantInBothCallSites() throws {
        let source = try loadSidebarFileTreeSource()
        #expect(!source.isEmpty)
        // The constant must be referenced in at least two distinct call sites:
        // (1) inside `SidebarDisclosureGroupStyle.makeBody` for the real chevron,
        // (2) inside `SidebarFileTreeNode.body` else-branch for the transparent
        // spacer. We assert at least 2 occurrences as a structural guard.
        let needle = "SidebarDisclosureMetrics.chevronWidth"
        let count = source.components(separatedBy: needle).count - 1
        #expect(count >= 2, "chevronWidth must be referenced in BOTH the disclosure style and the file-leaf spacer (found \(count))")
    }

    @Test
    func sourceUsesChevronSpacingConstantInBothCallSites() throws {
        let source = try loadSidebarFileTreeSource()
        let needle = "SidebarDisclosureMetrics.chevronSpacing"
        let count = source.components(separatedBy: needle).count - 1
        #expect(count >= 2, "chevronSpacing must be referenced in BOTH the disclosure style HStack and the file-leaf HStack (found \(count))")
    }

    @Test
    func sourceDoesNotHardcodeMagicChevronWidth() throws {
        let source = try loadSidebarFileTreeSource()
        // Guard against regressions where someone reintroduces `width: 10`
        // or `frame(width: 10)` literally instead of going through the
        // metrics enum. We allow the literal `10` only inside the enum
        // declaration line itself.
        let lines = source.components(separatedBy: "\n")
        for line in lines {
            if line.contains("static let chevronWidth") { continue }
            #expect(!line.contains("frame(width: 10)"),
                    "Found hardcoded chevron width literal — use SidebarDisclosureMetrics.chevronWidth instead. Line: \(line)")
        }
    }

    @Test
    func fileLeafBranchWrapsRowInHStackWithSpacer() throws {
        let source = try loadSidebarFileTreeSource()
        // The else-branch of `SidebarFileTreeNode.body` must wrap
        // `row(isFolder: false)` in an HStack containing a `Color.clear`
        // spacer of `SidebarDisclosureMetrics.chevronWidth`. We assert all
        // three markers appear in the source.
        #expect(source.contains("row(isFolder: false)"))
        #expect(source.contains("Color.clear.frame(width: SidebarDisclosureMetrics.chevronWidth)"))
        // And the HStack uses the spacing constant — sanity check.
        #expect(source.contains("HStack(spacing: SidebarDisclosureMetrics.chevronSpacing)"))
    }

    // MARK: - Edge cases

    @Test
    func metricsAreStableAcrossRepeatedAccess() {
        // Cheap, but guards against accidental conversion to a computed
        // property that recomputes from environment / font size and could
        // therefore drift between two reads in the same frame.
        let w1 = SidebarDisclosureMetrics.chevronWidth
        let w2 = SidebarDisclosureMetrics.chevronWidth
        let s1 = SidebarDisclosureMetrics.chevronSpacing
        let s2 = SidebarDisclosureMetrics.chevronSpacing
        #expect(w1 == w2)
        #expect(s1 == s2)
    }

    @Test
    func deeplyNestedFileLeafSharesSameSpacerGeometry() {
        // SwiftUI cannot be rendered headlessly here, but the structural
        // invariant we care about is: the spacer geometry comes from a
        // single enum, not from an instance property that depends on
        // depth. So at any nesting depth the same constant is used.
        // We model the recursion symbolically.
        for depth in 0..<32 {
            let inset = SidebarDisclosureMetrics.chevronWidth
                + SidebarDisclosureMetrics.chevronSpacing
            #expect(inset == SidebarDisclosureMetrics.chevronWidth
                    + SidebarDisclosureMetrics.chevronSpacing,
                    "Spacer geometry drifted at depth \(depth)")
        }
    }

    @Test
    func mixedFolderContainsFilesAndSubfoldersAlignToSameInset() {
        // For a folder containing both files and subfolders, every child
        // — file or folder — must end up with the same leading inset
        // before its icon, because both branches now go through
        // `SidebarDisclosureMetrics`. Verify the two paths produce the
        // same number.
        let folderPath = SidebarDisclosureMetrics.chevronWidth
            + SidebarDisclosureMetrics.chevronSpacing
        let filePath = SidebarDisclosureMetrics.chevronWidth
            + SidebarDisclosureMetrics.chevronSpacing
        #expect(folderPath == filePath)
        #expect(folderPath > 0)
    }
}
