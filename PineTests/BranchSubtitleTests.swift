//
//  BranchSubtitleTests.swift
//  PineTests
//

import Testing
@testable import Pine

@MainActor
struct BranchSubtitleTests {

    // MARK: - Git repository cases (plain checkout, no agent worktree)

    @Test func gitRepo_containsBranchNameAndDropdown() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "main",
            hasActiveWorktree: false
        )
        #expect(result == "main ▾")
    }

    @Test func gitRepo_featureBranchWithSlash() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "feature/login",
            hasActiveWorktree: false
        )
        #expect(result == "feature/login ▾")
    }

    @Test func gitRepo_deeplyNestedBranch() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "feature/team/sprint-3/JIRA-1234",
            hasActiveWorktree: false
        )
        #expect(result == "feature/team/sprint-3/JIRA-1234 ▾")
    }

    @Test func gitRepo_longBranchName() {
        let long = String(repeating: "a", count: 200)
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: long,
            hasActiveWorktree: false
        )
        #expect(result == "\(long) ▾")
    }

    @Test func gitRepo_branchWithSpecialCharacters() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "fix/emoji-🐛-bug",
            hasActiveWorktree: false
        )
        #expect(result == "fix/emoji-🐛-bug ▾")
    }

    @Test func gitRepo_branchWithDots() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "release/v1.2.3",
            hasActiveWorktree: false
        )
        #expect(result == "release/v1.2.3 ▾")
    }

    @Test func gitRepo_branchWithHyphensAndUnderscores() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "fix_some-thing_else",
            hasActiveWorktree: false
        )
        #expect(result == "fix_some-thing_else ▾")
    }

    @Test func gitRepo_emptyBranchName() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "",
            hasActiveWorktree: false
        )
        #expect(result == " ▾")
    }

    @Test func gitRepo_branchWithAtSign() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "user@feature",
            hasActiveWorktree: false
        )
        #expect(result == "user@feature ▾")
    }

    @Test func gitRepo_detachedHead() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "HEAD detached at abc1234",
            hasActiveWorktree: false
        )
        #expect(result == "HEAD detached at abc1234 ▾")
    }

    // MARK: - Non-git repository cases

    @Test func notGitRepo_returnsEmptyString() {
        let result = ContentView.branchSubtitle(
            isGitRepo: false,
            branchName: "main",
            hasActiveWorktree: false
        )
        #expect(result.isEmpty)
    }

    @Test func notGitRepo_emptyBranchName_returnsEmpty() {
        let result = ContentView.branchSubtitle(
            isGitRepo: false,
            branchName: "",
            hasActiveWorktree: false
        )
        #expect(result.isEmpty)
    }

    // MARK: - Active agent worktree: the pill already says the branch

    @Test func activeWorktree_suppressesSubtitle() {
        // With a managed worktree active the switcher pill reads
        // "project — branch"; the subtitle would pronounce the same branch
        // a second time on one strip.
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "pine/agent/codex/feat",
            hasActiveWorktree: true
        )
        #expect(result.isEmpty)
    }

    @Test func activeWorktree_suppressesRegardlessOfBranchName() {
        for branch in ["main", "feature/x", "", "HEAD detached at abc1234"] {
            let result = ContentView.branchSubtitle(
                isGitRepo: true,
                branchName: branch,
                hasActiveWorktree: true
            )
            #expect(result.isEmpty, "branch '\(branch)' should be suppressed")
        }
    }

    @Test func activeWorktree_notGitRepo_stillEmpty() {
        let result = ContentView.branchSubtitle(
            isGitRepo: false,
            branchName: "main",
            hasActiveWorktree: true
        )
        #expect(result.isEmpty)
    }

    // MARK: - Format invariants

    @Test func subtitle_doesNotContainBrokenUnicodeSymbol() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "main",
            hasActiveWorktree: false
        )
        #expect(!result.contains("⎇"))
        #expect(!result.contains("√"))
    }

    @Test func subtitle_isPlainString_endsWithDropdownIndicator() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "develop",
            hasActiveWorktree: false
        )
        #expect(result.hasSuffix("▾"))
    }

    @Test func subtitle_startsWithBranchName() {
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "develop",
            hasActiveWorktree: false
        )
        #expect(result.hasPrefix("develop"))
    }

    @Test func subtitle_matchesExactFormat() {
        // Verify the exact format so BranchSubtitleClickHandler can match window.subtitle
        let result = ContentView.branchSubtitle(
            isGitRepo: true,
            branchName: "my-branch",
            hasActiveWorktree: false
        )
        #expect(result == "my-branch ▾")
    }
}
