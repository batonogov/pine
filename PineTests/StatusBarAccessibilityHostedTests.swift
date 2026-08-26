//
//  StatusBarAccessibilityHostedTests.swift
//  PineTests
//
//  What the status bar sounds like (#1533).
//
//  Every assertion here reads the accessibility tree the hosted bar publishes,
//  never the view code. That distinction is the whole point of this suite:
//  the git summary's defect was that `Text(verbatim: "3")` reaches VoiceOver
//  as the word "three" and nothing else, and a test that checked the view had
//  a `Text` with "3" in it would have agreed with the defect.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Status bar hosted accessibility (#1533)", .serialized)
@MainActor
struct StatusBarAccessibilityHostedTests {

    private static let barSize = NSSize(width: 900, height: 28)

    // MARK: - Git summary

    /// The regression this suite exists for. Three counts with three distinct
    /// values, so a label that names the wrong kind cannot pass by accident.
    @Test("the git summary names every count instead of speaking bare numbers")
    func gitSummaryNamesItsCounts() throws {
        let hosted = hostBar(modified: 3, added: 1, untracked: 5)
        defer { hosted.tearDown() }

        let spoken = AccessibilityTreeProbe.labels(under: hosted.root)
        let bare = spoken.filter { phrase in
            !phrase.isEmpty && phrase.allSatisfy(\.isNumber)
        }

        #expect(
            bare.isEmpty,
            """
            VoiceOver reads \(bare) out of the status bar with no word \
            attached. A bare "3" is the git modified count, and there is \
            nothing in the announcement that says so.
            """
        )
    }

    /// Naming the counts is only half of it — the names have to be attached to
    /// the right numbers. Distinct counts make a copy-paste swap fail here.
    @Test("each git count is announced with its own kind")
    func gitCountsKeepTheirOwnNames() throws {
        let hosted = hostBar(modified: 3, added: 1, untracked: 5)
        defer { hosted.tearDown() }

        let summary = try #require(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.gitStatusSummary
            ),
            "the git summary publishes no container element"
        )
        let byIdentifier = [
            AccessibilityID.gitStatusModifiedCount: "3",
            AccessibilityID.gitStatusAddedCount: "1",
            AccessibilityID.gitStatusUntrackedCount: "5",
        ]

        for (identifier, count) in byIdentifier {
            let element = try #require(
                AccessibilityTreeProbe.element(
                    under: summary,
                    identifier: identifier
                ),
                "\(identifier) is missing from the published tree"
            )
            let announced = try #require(
                AccessibilityTreeProbe.label(of: element),
                "\(identifier) publishes no label"
            )
            #expect(
                announced.contains(count),
                "\(identifier) announces \"\(announced)\", not the count \(count)"
            )
            let namesTheKind = announced.contains { $0.isLetter }
            #expect(
                namesTheKind,
                """
                \(identifier) announces "\(announced)" — digits only, so \
                VoiceOver still never says which kind of change it is
                """
            )
        }
    }

    /// The three names must differ from one another. A single format applied
    /// to all three counts would satisfy every assertion above.
    @Test("the three git counts are announced with three different names")
    func gitCountNamesAreDistinct() throws {
        let hosted = hostBar(modified: 3, added: 1, untracked: 5)
        defer { hosted.tearDown() }

        let names = try [
            AccessibilityID.gitStatusModifiedCount,
            AccessibilityID.gitStatusAddedCount,
            AccessibilityID.gitStatusUntrackedCount,
        ].map { identifier -> String in
            let element = try #require(
                AccessibilityTreeProbe.element(
                    under: hosted.root,
                    identifier: identifier
                )
            )
            let announced = try #require(
                AccessibilityTreeProbe.label(of: element)
            )
            return announced.filter { !$0.isNumber }
        }

        #expect(
            Set(names).count == names.count,
            "the git counts share the wording \(names)"
        )
    }

    /// A count of zero is not rendered at all, so it must not be announced.
    @Test("a kind with no changes is not announced")
    func absentGitKindsAreNotAnnounced() throws {
        let hosted = hostBar(modified: 2, added: 0, untracked: 0)
        defer { hosted.tearDown() }

        #expect(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.gitStatusModifiedCount
            ) != nil
        )
        #expect(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.gitStatusAddedCount
            ) == nil,
            "an added count of zero is invisible but still announced"
        )
        #expect(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.gitStatusUntrackedCount
            ) == nil
        )
    }

    // MARK: - Separators

    /// `·` is a drawn gap. Read aloud between every indicator it is noise.
    @Test("the interpunct separators are absent from the published tree")
    func separatorsAreNotPublished() throws {
        let hosted = hostBar(modified: 3, added: 1, untracked: 5)
        defer { hosted.tearDown() }

        let spoken = AccessibilityTreeProbe.labels(under: hosted.root)
        let separators = spoken.filter { $0.contains("·") }

        #expect(
            separators.isEmpty,
            """
            VoiceOver reads \(separators.count) interpunct separator(s) out \
            of the status bar: \(separators)
            """
        )
    }

    // MARK: - Named indicators

    @Test("the cursor indicator is named and spells out line and column")
    func cursorPositionIsNamedAndSpelled() throws {
        let hosted = hostBar(
            modified: 0,
            added: 0,
            untracked: 0,
            cursorLine: 42,
            cursorColumn: 7
        )
        defer { hosted.tearDown() }

        let element = try #require(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.cursorPosition
            ),
            "the cursor indicator is not in the published tree"
        )
        let name = try #require(
            AccessibilityTreeProbe.label(of: element),
            "the cursor indicator has no name — VoiceOver reads only its text"
        )
        let announced = try #require(
            AccessibilityTreeProbe.value(of: element),
            "the cursor indicator publishes no value"
        )

        let namedInWords = name.contains { $0.isLetter }
        #expect(namedInWords)
        #expect(
            !name.contains("42") && !name.contains("Ln"),
            """
            the cursor indicator's name is "\(name)" — a name has to stay \
            the same as the cursor moves, or VoiceOver has nothing stable to \
            announce the change against
            """
        )
        #expect(announced.contains("42"), "the line number is not announced")
        #expect(announced.contains("7"), "the column number is not announced")
        #expect(
            !announced.contains("Ln"),
            """
            the cursor value still reads the drawn abbreviation "Ln", which \
            VoiceOver pronounces as a word rather than "line"
            """
        )
    }

    /// Requiring a non-empty label is not enough, and the mutation run proved
    /// it: with `.accessibilityLabel` deleted, SwiftUI falls back to echoing
    /// the reading itself, so the element still has *a* label — "2 KB" — and a
    /// naive test passes on the exact defect. A name has to be a name: it says
    /// what is being measured, so it carries no digits and is not a copy of
    /// the value.
    @Test("the indentation and file size indicators are named, not echoed")
    func secondaryIndicatorsAreNamed() throws {
        let hosted = hostBar(modified: 0, added: 0, untracked: 0)
        defer { hosted.tearDown() }

        for identifier in [
            AccessibilityID.indentationIndicator,
            AccessibilityID.fileSizeIndicator,
        ] {
            let element = try #require(
                AccessibilityTreeProbe.element(
                    under: hosted.root,
                    identifier: identifier
                ),
                "\(identifier) is not in the published tree"
            )
            let name = try #require(
                AccessibilityTreeProbe.label(of: element),
                """
                \(identifier) publishes no name, so VoiceOver announces its \
                bare contents with no clue what they measure
                """
            )
            let reading = try #require(
                AccessibilityTreeProbe.value(of: element),
                "\(identifier) publishes a name but no reading"
            )

            let namedInWords = name.contains { $0.isLetter }
            let namedInDigits = name.contains { $0.isNumber }
            #expect(namedInWords, "\(identifier) is named \"\(name)\"")
            #expect(
                !namedInDigits,
                """
                \(identifier) is named "\(name)". A name carrying the reading \
                is the reading echoed back, not a name — it changes as the \
                value changes and never says what is being measured.
                """
            )
            #expect(
                name != reading,
                "\(identifier) announces \"\(name)\" twice"
            )
            #expect(!reading.isEmpty)
        }
    }

    // MARK: - Fixture

    private func hostBar(
        modified: Int,
        added: Int,
        untracked: Int,
        cursorLine: Int = 2,
        cursorColumn: Int = 8
    ) -> AccessibilityTreeProbe.Hosted {
        let tabs = tabManager(
            cursorLine: cursorLine,
            cursorColumn: cursorColumn
        )
        return AccessibilityTreeProbe.host(
            StatusBarView(
                gitProvider: gitProvider(
                    modified: modified,
                    added: added,
                    untracked: untracked
                ),
                paneManager: PaneManager(existingTabManager: tabs),
                tabManager: tabs
            ),
            size: Self.barSize
        )
    }

    private func tabManager(cursorLine: Int, cursorColumn: Int) -> TabManager {
        let manager = TabManager()
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/test/main.swift"),
            content: "let x = 1\nlet y = 2\n",
            savedContent: "let x = 1\nlet y = 2\n"
        )
        tab.cursorLine = cursorLine
        tab.cursorColumn = cursorColumn
        tab.fileSizeBytes = 2_048
        tab.recomputeContentCaches()
        manager.tabs = [tab]
        manager.activeTabID = tab.id
        return manager
    }

    private func gitProvider(
        modified: Int,
        added: Int,
        untracked: Int
    ) -> GitStatusProvider {
        let provider = GitStatusProvider()
        provider.isGitRepository = true
        provider.currentBranch = "main"
        var statuses: [String: GitFileStatus] = [:]
        for index in 0..<modified {
            statuses["/test/modified\(index).swift"] = .modified
        }
        for index in 0..<added {
            statuses["/test/added\(index).swift"] = .added
        }
        for index in 0..<untracked {
            statuses["/test/untracked\(index).txt"] = .untracked
        }
        provider.fileStatuses = statuses
        return provider
    }
}
