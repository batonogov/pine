//
//  GitFileStatusIndicatorTests.swift
//  PineTests
//
//  #1532 — the sidebar's git status must be perceivable without colour:
//  every status carries a distinct letter badge and a distinct hue, and
//  the accessibility row announces the status as its value.
//

import SwiftUI
import Testing

@testable import Pine

@Suite("Git file status indicator (#1532)")
struct GitFileStatusIndicatorTests {
    private static let allStatuses: [GitFileStatus] = [
        .untracked,
        .modified,
        .staged,
        .added,
        .deleted,
        .conflict,
        .mixed,
    ]

    // MARK: - Letter badges

    @Test("Every status carries a distinct, non-empty letter badge")
    func lettersAreDistinct() {
        let letters = Self.allStatuses.map(\.statusLetter)
        #expect(Set(letters).count == Self.allStatuses.count)
        #expect(letters.allSatisfy { !$0.isEmpty })
        #expect(letters.allSatisfy { $0.allSatisfy(\.isLetter) })
    }

    @Test("The pairs the colour palette used to merge are distinguishable")
    func formerlyAmbiguousPairsDifferWithoutColour() {
        // .modified and .mixed shared orange; .deleted and .conflict shared
        // red; .staged and .added were two near-identical greens (#1532).
        #expect(
            GitFileStatus.modified.statusLetter != GitFileStatus.mixed.statusLetter
        )
        #expect(
            GitFileStatus.modified.color != GitFileStatus.mixed.color
        )
        #expect(
            GitFileStatus.deleted.statusLetter != GitFileStatus.conflict.statusLetter
        )
        #expect(
            GitFileStatus.deleted.color != GitFileStatus.conflict.color
        )
        #expect(
            GitFileStatus.staged.statusLetter != GitFileStatus.added.statusLetter
        )
        #expect(
            GitFileStatus.staged.color != GitFileStatus.added.color
        )
    }

    @Test("Every hue is unique — colour alone never merges two statuses")
    func coloursAreDistinct() {
        let colours = Self.allStatuses.map(\.color)
        #expect(Set(colours).count == Self.allStatuses.count)
    }

    @Test("Letters follow porcelain where it is unambiguous")
    func documentedLetters() {
        #expect(GitFileStatus.modified.statusLetter == "M")
        #expect(GitFileStatus.added.statusLetter == "A")
        #expect(GitFileStatus.deleted.statusLetter == "D")
        #expect(GitFileStatus.conflict.statusLetter == "C")
        #expect(GitFileStatus.mixed.statusLetter == "MM")
        // Deliberate deviations, documented on the property:
        // staged-edit is porcelain "M " too, untracked is porcelain "?".
        #expect(GitFileStatus.staged.statusLetter == "S")
        #expect(GitFileStatus.untracked.statusLetter == "U")
    }

    // MARK: - Accessibility names

    @Test("Every status announces a distinct, non-empty localized name")
    func accessibilityNamesAreDistinct() {
        let names = Self.allStatuses.map(\.accessibilityStatusName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == Self.allStatuses.count)
    }

    @Test("Accessibility names are wired to the a11y.gitStatus catalog keys")
    func accessibilityNamesAreWired() {
        #expect(
            GitFileStatus.modified.accessibilityStatusName
                == Strings.a11yGitStatusModified
        )
        #expect(
            GitFileStatus.added.accessibilityStatusName
                == Strings.a11yGitStatusAdded
        )
        #expect(
            GitFileStatus.untracked.accessibilityStatusName
                == Strings.a11yGitStatusUntracked
        )
        #expect(
            GitFileStatus.staged.accessibilityStatusName
                == Strings.a11yGitStatusStaged
        )
        #expect(
            GitFileStatus.deleted.accessibilityStatusName
                == Strings.a11yGitStatusDeleted
        )
        #expect(
            GitFileStatus.conflict.accessibilityStatusName
                == Strings.a11yGitStatusConflict
        )
        #expect(
            GitFileStatus.mixed.accessibilityStatusName
                == Strings.a11yGitStatusMixed
        )
    }

    // MARK: - Differentiate Without Color

    @Test("Differentiate Without Color drops the filename tint")
    func differentiateWithoutColorDropsTheTint() {
        let tint = GitFileStatus.modified.color
        // The colour-only part of a status row is the filename tint (#1532);
        // the letter badge carries the status when the tint is dropped.
        #expect(
            SidebarRowLabel.effectiveNameColor(
                base: tint,
                gitStatus: .modified,
                differentiateWithoutColor: false
            ) == tint
        )
        #expect(
            SidebarRowLabel.effectiveNameColor(
                base: tint,
                gitStatus: .modified,
                differentiateWithoutColor: true
            ) == .primary
        )
        // Rows without a git status keep their base colour in both modes.
        #expect(
            SidebarRowLabel.effectiveNameColor(
                base: .blue,
                gitStatus: nil,
                differentiateWithoutColor: true
            ) == .blue
        )
    }

    // MARK: - Row accessibility value

    @Test("A file without git status keeps a nil value")
    func fileWithoutStatusHasNoValue() {
        #expect(
            SidebarRowAccessibilityValue.compose(
                isFolder: false,
                isExpanded: false,
                gitStatus: nil
            ) == nil
        )
    }

    @Test("A file's value is its git status alone")
    func fileValueIsTheStatus() {
        #expect(
            SidebarRowAccessibilityValue.compose(
                isFolder: false,
                isExpanded: false,
                gitStatus: .untracked
            ) == Strings.a11yGitStatusUntracked
        )
    }

    @Test("A folder keeps its disclosure value, with or without a status")
    func folderKeepsDisclosureValue() {
        #expect(
            SidebarRowAccessibilityValue.compose(
                isFolder: true,
                isExpanded: true,
                gitStatus: nil
            ) == Strings.a11ySidebarDisclosureExpanded
        )
        #expect(
            SidebarRowAccessibilityValue.compose(
                isFolder: true,
                isExpanded: false,
                gitStatus: nil
            ) == Strings.a11ySidebarDisclosureCollapsed
        )
    }

    @Test("A folder with a git status announces both facts")
    func folderWithStatusJoinsBoth() {
        #expect(
            SidebarRowAccessibilityValue.compose(
                isFolder: true,
                isExpanded: true,
                gitStatus: .modified
            )
            == Strings.a11ySidebarDisclosureExpanded + ", "
                + Strings.a11yGitStatusModified
        )
    }
}
