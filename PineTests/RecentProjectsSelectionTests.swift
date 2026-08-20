//
//  RecentProjectsSelectionTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

struct RecentProjectsSelectionTests {
    private let projects = ["alpha", "beta", "gamma"].map {
        URL(fileURLWithPath: "/Users/tester/Projects/\($0)")
    }

    @Test("Normalization selects the first visible project")
    func initialSelection() {
        var selection = RecentProjectsSelection()

        selection.normalize(for: projects)

        #expect(selection.selectedURL == projects[0])
    }

    @Test("Filtering preserves a visible selection")
    func filteringPreservesVisibleSelection() {
        var selection = RecentProjectsSelection(selectedURL: projects[1])

        selection.normalize(for: [projects[1], projects[2]])

        #expect(selection.selectedURL == projects[1])
    }

    @Test("Filtering selects the first result when selection disappears")
    func filteringNormalizesHiddenSelection() {
        var selection = RecentProjectsSelection(selectedURL: projects[0])

        selection.normalize(for: [projects[1], projects[2]])

        #expect(selection.selectedURL == projects[1])
    }

    @Test("An empty filter result clears selection")
    func emptyResultsClearSelection() {
        var selection = RecentProjectsSelection(selectedURL: projects[0])

        selection.normalize(for: [])

        #expect(selection.selectedURL == nil)
    }

    @Test("Arrow navigation clamps at list boundaries")
    func arrowNavigationClamps() {
        var selection = RecentProjectsSelection(selectedURL: projects[0])

        selection.move(.up, in: projects)
        #expect(selection.selectedURL == projects[0])
        selection.move(.down, in: projects)
        #expect(selection.selectedURL == projects[1])
        selection.move(.down, in: projects)
        selection.move(.down, in: projects)
        #expect(selection.selectedURL == projects[2])
    }

    @Test("Home and End select list boundaries")
    func homeAndEnd() {
        var selection = RecentProjectsSelection(selectedURL: projects[1])

        selection.move(.end, in: projects)
        #expect(selection.selectedURL == projects[2])
        selection.move(.home, in: projects)
        #expect(selection.selectedURL == projects[0])
    }

    @Test("Removing selection chooses the next row")
    func removalSelectsNextRow() {
        var selection = RecentProjectsSelection(selectedURL: projects[1])

        selection.normalizeAfterRemoving(
            projects[1],
            from: projects,
            remainingProjects: [projects[0], projects[2]]
        )

        #expect(selection.selectedURL == projects[2])
    }

    @Test("Removing the final selection chooses the preceding row")
    func removingFinalRowSelectsPrevious() {
        var selection = RecentProjectsSelection(selectedURL: projects[2])

        selection.normalizeAfterRemoving(
            projects[2],
            from: projects,
            remainingProjects: [projects[0], projects[1]]
        )

        #expect(selection.selectedURL == projects[1])
    }

    @Test("Removing an unselected row preserves selection")
    func removingUnselectedRowPreservesSelection() {
        var selection = RecentProjectsSelection(selectedURL: projects[2])

        selection.normalizeAfterRemoving(
            projects[0],
            from: projects,
            remainingProjects: [projects[1], projects[2]]
        )

        #expect(selection.selectedURL == projects[2])
    }
}
