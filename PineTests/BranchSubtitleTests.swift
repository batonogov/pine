//
//  BranchSubtitleTests.swift
//  PineTests
//

import Testing
@testable import Pine

@MainActor
struct BranchSubtitleTests {

    // MARK: - Git repository cases

    @Test func gitRepo_containsBranchNameAndDropdown() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "main")
        #expect(result == "main ▾")
    }

    @Test func gitRepo_featureBranchWithSlash() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "feature/login")
        #expect(result == "feature/login ▾")
    }

    @Test func gitRepo_deeplyNestedBranch() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "feature/team/sprint-3/JIRA-1234")
        #expect(result == "feature/team/sprint-3/JIRA-1234 ▾")
    }

    @Test func gitRepo_longBranchName() {
        let long = String(repeating: "a", count: 200)
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: long)
        #expect(result == "\(long) ▾")
    }

    @Test func gitRepo_branchWithSpecialCharacters() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "fix/emoji-🐛-bug")
        #expect(result == "fix/emoji-🐛-bug ▾")
    }

    @Test func gitRepo_branchWithDots() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "release/v1.2.3")
        #expect(result == "release/v1.2.3 ▾")
    }

    @Test func gitRepo_branchWithHyphensAndUnderscores() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "fix_some-thing_else")
        #expect(result == "fix_some-thing_else ▾")
    }

    @Test func gitRepo_emptyBranchName() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "")
        #expect(result == " ▾")
    }

    @Test func gitRepo_branchWithAtSign() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "user@feature")
        #expect(result == "user@feature ▾")
    }

    @Test func gitRepo_detachedHead() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "HEAD detached at abc1234")
        #expect(result == "HEAD detached at abc1234 ▾")
    }

    // MARK: - Non-git repository cases

    @Test func notGitRepo_returnsEmptyString() {
        let result = ContentView.branchSubtitle(isGitRepo: false, branchName: "main")
        #expect(result.isEmpty)
    }

    @Test func notGitRepo_emptyBranchName_returnsEmpty() {
        let result = ContentView.branchSubtitle(isGitRepo: false, branchName: "")
        #expect(result.isEmpty)
    }

    // MARK: - Format invariants

    @Test func subtitle_doesNotContainBrokenUnicodeSymbol() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "main")
        #expect(!result.contains("⎇"))
        #expect(!result.contains("√"))
    }

    @Test func subtitle_isPlainString_endsWithDropdownIndicator() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "develop")
        #expect(result.hasSuffix("▾"))
    }

    @Test func subtitle_startsWithBranchName() {
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "develop")
        #expect(result.hasPrefix("develop"))
    }

    @Test func subtitle_matchesExactFormat() {
        // Verify the exact format so BranchSubtitleClickHandler can match window.subtitle
        let result = ContentView.branchSubtitle(isGitRepo: true, branchName: "my-branch")
        #expect(result == "my-branch ▾")
    }
}
