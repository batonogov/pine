//
//  SearchResultsKeyboardTests.swift
//  PineTests
//
//  Created by Claude on 15.06.2026.
//

import Foundation
import Testing

@testable import Pine

// MARK: - Selection index logic (independent of SwiftUI)

@Suite("Search Results Keyboard Navigation Tests")
struct SearchResultsKeyboardTests {

    // MARK: - Selection clamping (#1526 — wrapping hid the selection off-screen)

    @Test("next index clamps at the last row instead of wrapping")
    func nextIndexClampsForward() {
        // At the last index, Down stays put — it must not jump back to the top.
        #expect(SearchSelectionLogic.nextIndex(current: 4, delta: 1, total: 5) == 4)
        // Normal forward
        #expect(SearchSelectionLogic.nextIndex(current: 2, delta: 1, total: 5) == 3)
        // Overshoot clamps to the last row
        #expect(SearchSelectionLogic.nextIndex(current: 3, delta: 2, total: 5) == 4)
    }

    @Test("previous index clamps at the first row instead of wrapping")
    func previousIndexClampsBackward() {
        // At index 0, Up stays put — it must not jump to the last row.
        #expect(SearchSelectionLogic.nextIndex(current: 0, delta: -1, total: 5) == 0)
        // Normal backward
        #expect(SearchSelectionLogic.nextIndex(current: 3, delta: -1, total: 5) == 2)
        // Overshoot clamps to the first row
        #expect(SearchSelectionLogic.nextIndex(current: 1, delta: -3, total: 5) == 0)
    }

    @Test("next index handles single element")
    func nextIndexSingleElement() {
        #expect(SearchSelectionLogic.nextIndex(current: 0, delta: 1, total: 1) == 0)
        #expect(SearchSelectionLogic.nextIndex(current: 0, delta: -1, total: 1) == 0)
    }

    @Test("next index returns nil for empty results")
    func nextIndexEmpty() {
        #expect(SearchSelectionLogic.nextIndex(current: nil, delta: 1, total: 0) == nil)
        #expect(SearchSelectionLogic.nextIndex(current: 0, delta: 1, total: 0) == nil)
    }

    @Test("next index starts at 0 when current is nil")
    func nextIndexStartsAtZero() {
        #expect(SearchSelectionLogic.nextIndex(current: nil, delta: 5, total: 5) == 0)
        #expect(SearchSelectionLogic.nextIndex(current: nil, delta: -1, total: 5) == 0)
    }

    @Test("next index with delta larger than total clamps to the bounds")
    func nextIndexLargeDelta() {
        #expect(SearchSelectionLogic.nextIndex(current: 2, delta: 7, total: 5) == 4)
        #expect(SearchSelectionLogic.nextIndex(current: 1, delta: -7, total: 5) == 0)
    }

    @Test("a selection past the end of a shrunken list clamps into range")
    func nextIndexClampsIntoShrunkenList() {
        // The result set can shrink under the selection while the user holds
        // an arrow key; the index must land inside the new list, not past it.
        #expect(SearchSelectionLogic.nextIndex(current: 9, delta: 1, total: 3) == 2)
        #expect(SearchSelectionLogic.nextIndex(current: 9, delta: -1, total: 3) == 2)
    }
}

// MARK: - Truncation flag tests

@Suite("Search Truncation Detection Tests")
struct SearchTruncationTests {

    @Test("detectTotalCap returns false below maxResults")
    func totalCapBelowMax() {
        #expect(!ProjectSearchProvider.detectTotalCap(matchCount: 999))
        #expect(!ProjectSearchProvider.detectTotalCap(matchCount: 0))
        #expect(!ProjectSearchProvider.detectTotalCap(matchCount: 500))
    }

    @Test("detectTotalCap returns true at or above maxResults")
    func totalCapAtOrAboveMax() {
        #expect(ProjectSearchProvider.detectTotalCap(matchCount: ProjectSearchProvider.maxResults))
        #expect(ProjectSearchProvider.detectTotalCap(matchCount: ProjectSearchProvider.maxResults + 1))
        #expect(ProjectSearchProvider.detectTotalCap(matchCount: 5000))
    }

    @Test("detectPerFileCap returns false when no group hits cap")
    func perFileCapNotHit() {
        let groups = [
            SearchFileGroup(url: URL(fileURLWithPath: "/a.swift"), relativePath: "a.swift",
                            matches: [SearchMatch(lineNumber: 1, lineContent: "x", matchRangeStart: 0, matchRangeLength: 1)]),
            SearchFileGroup(url: URL(fileURLWithPath: "/b.swift"), relativePath: "b.swift",
                            matches: []),
        ]
        #expect(!ProjectSearchProvider.detectPerFileCap(in: groups))
    }

    @Test("detectPerFileCap returns true when a group hits cap")
    func perFileCapHit() {
        let matches = (1...ProjectSearchProvider.maxResultsPerFile).map { i in
            SearchMatch(lineNumber: i, lineContent: "match", matchRangeStart: 0, matchRangeLength: 4)
        }
        let groups = [
            SearchFileGroup(url: URL(fileURLWithPath: "/a.swift"), relativePath: "a.swift", matches: matches),
        ]
        #expect(ProjectSearchProvider.detectPerFileCap(in: groups))
    }

    @Test("detectPerFileCap returns false for empty groups")
    func perFileCapEmpty() {
        #expect(!ProjectSearchProvider.detectPerFileCap(in: []))
    }

    @Test("detectPerFileCap returns true when only one of many groups is capped")
    func perFileCapOneOfMany() {
        let cappedMatches = (1...ProjectSearchProvider.maxResultsPerFile).map { i in
            SearchMatch(lineNumber: i, lineContent: "match", matchRangeStart: 0, matchRangeLength: 4)
        }
        let groups = [
            SearchFileGroup(url: URL(fileURLWithPath: "/a.swift"), relativePath: "a.swift",
                            matches: [SearchMatch(lineNumber: 1, lineContent: "x", matchRangeStart: 0, matchRangeLength: 1)]),
            SearchFileGroup(url: URL(fileURLWithPath: "/b.swift"), relativePath: "b.swift", matches: cappedMatches),
        ]
        #expect(ProjectSearchProvider.detectPerFileCap(in: groups))
    }
}

// MARK: - Flattened matches tests

@Suite("Search Flattened Matches Tests")
struct SearchFlattenedMatchesTests {

    @Test("flatten preserves order across groups")
    func flattenPreservesOrder() {
        let groups = [
            SearchFileGroup(url: URL(fileURLWithPath: "/a.swift"), relativePath: "a.swift", matches: [
                SearchMatch(lineNumber: 1, lineContent: "x", matchRangeStart: 0, matchRangeLength: 1),
                SearchMatch(lineNumber: 5, lineContent: "y", matchRangeStart: 0, matchRangeLength: 1),
            ]),
            SearchFileGroup(url: URL(fileURLWithPath: "/b.swift"), relativePath: "b.swift", matches: [
                SearchMatch(lineNumber: 3, lineContent: "z", matchRangeStart: 0, matchRangeLength: 1),
            ]),
        ]

        let flat = ProjectSearchProvider.flatten(groups)
        #expect(flat.count == 3)
        #expect(flat[0].fileURL.lastPathComponent == "a.swift")
        #expect(flat[0].match.lineNumber == 1)
        #expect(flat[1].match.lineNumber == 5)
        #expect(flat[2].fileURL.lastPathComponent == "b.swift")
        #expect(flat[2].match.lineNumber == 3)
    }

    @Test("flatten returns empty for empty groups")
    func flattenEmpty() {
        #expect(ProjectSearchProvider.flatten([]).isEmpty)
    }
}

// MARK: - Active-pane routing resolver tests

@Suite("Search Active Pane Routing Tests")
@MainActor
struct SearchActivePaneRoutingTests {

    @Test("resolveActiveTabManager returns active editor TabManager")
    func resolvesActiveEditorPane() {
        let primary = TabManager()
        let paneManager = PaneManager(existingTabManager: primary)

        // Single editor pane — activeEditorTabManager returns primary
        let resolved = paneManager.activeEditorTabManager
        #expect(resolved === primary)
    }

    @Test("activeTabManager on ProjectManager falls back to primary")
    func fallsBackToPrimary() {
        let pm = ProjectManager()
        // Default state: single editor pane with primaryTabManager
        #expect(pm.activeTabManager === pm.paneManager.activeEditorTabManager)
    }

    @Test("activeEditorTabManager returns nearest editor when active is terminal")
    func nearestEditorWhenTerminalActive() throws {
        let primary = TabManager()
        let paneManager = PaneManager(existingTabManager: primary)

        guard let editorLeafID = paneManager.root.firstLeafID else {
            Issue.record("Expected editor leaf")
            return
        }

        // Create a terminal pane next to the editor
        guard let terminalID = paneManager.createTerminalPane(
            relativeTo: editorLeafID,
            axis: .vertical,
            workingDirectory: nil
        ) else {
            Issue.record("Expected terminal pane creation")
            return
        }

        // Set active pane to the terminal
        paneManager.activePaneID = terminalID

        // activeEditorTabManager should still resolve to the editor pane's TabManager
        let resolved = paneManager.activeEditorTabManager
        #expect(resolved === primary)
    }

    @Test("activeEditorTabManager follows active pane when it is an editor")
    func followsActiveEditorPane() throws {
        let primary = TabManager()
        let paneManager = PaneManager(existingTabManager: primary)

        guard let editorLeafID = paneManager.root.firstLeafID else {
            Issue.record("Expected editor leaf")
            return
        }
        guard let newEditorID = paneManager.splitPane(
            editorLeafID,
            axis: .horizontal
        ) else {
            Issue.record("Expected split pane creation")
            return
        }

        // Each editor pane gets its own TabManager
        guard let newTabManager = paneManager.tabManager(for: newEditorID) else {
            Issue.record("Expected TabManager for new pane")
            return
        }

        // Make the new pane active
        paneManager.activePaneID = newEditorID

        // activeEditorTabManager should return the NEW pane's TabManager, not primary
        let resolved = paneManager.activeEditorTabManager
        #expect(resolved === newTabManager)
        #expect(resolved !== primary)
    }
}
