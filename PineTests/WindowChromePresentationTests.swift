//
//  WindowChromePresentationTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Window chrome presentation")
struct WindowChromePresentationTests {
    private func chrome(
        file: String?,
        repository: String = "pine",
        switcher: String = "pine"
    ) -> WindowChromePresentation {
        WindowChromePresentation(
            activeFileName: file,
            repositoryName: repository,
            switcherLabel: switcher
        )
    }

    // MARK: - The duplication this type exists to remove

    @Test("No string is ever printed twice in the title bar")
    func titleAndSwitcherNeverMatch() {
        // The invariant, stated once: whatever the inputs, the two title-bar
        // surfaces never read identically.
        let inputs: [(String?, String, String)] = [
            ("ContentView.swift", "pine", "pine"),
            (nil, "pine", "pine"),
            (nil, "pine", "pine — feat/x"),
            ("ContentView.swift", "pine", "pine — feat/x"),
            ("pine", "pine", "pine"),
            ("", "pine", "pine"),
            ("  ", "  ", "  "),
            (nil, "/", "/")
        ]
        for (file, repository, switcher) in inputs {
            let resolved = WindowChromePresentation(
                activeFileName: file,
                repositoryName: repository,
                switcherLabel: switcher
            )
            #expect(
                resolved.switcherLabel != resolved.title,
                "\(String(describing: file)) / \(repository) / \(switcher)"
            )
        }
    }

    @Test("An open file titles the window and the switcher keeps the project")
    func openFileSplitsTheTwoSurfaces() {
        let resolved = chrome(file: "ContentView.swift")
        #expect(resolved.title == "ContentView.swift")
        #expect(resolved.switcherLabel == "pine")
    }

    @Test("Without an editor tab the switcher drops its duplicate text")
    func terminalOnlyWindowSuppressesSwitcherText() {
        // A project with no restored session opens straight into a terminal
        // (#1251), so this is the first screen of a new project — the one
        // place the duplicate was most visible.
        let resolved = chrome(file: nil)
        #expect(resolved.title == "pine")
        #expect(resolved.switcherLabel == nil)
    }

    // MARK: - Worktree windows keep their distinguishing text

    @Test("A worktree keeps its branch label even with no file open")
    func worktreeBranchIsNotSuppressed() {
        // The branch is the only thing telling two windows of one repository
        // apart. It shares a word with the title but is not the same string,
        // so it must survive.
        let resolved = chrome(
            file: nil,
            repository: "pine",
            switcher: "pine — feat/multi-project"
        )
        #expect(resolved.title == "pine")
        #expect(resolved.switcherLabel == "pine — feat/multi-project")
    }

    @Test("A worktree window never surfaces its hashed service directory")
    func worktreeTitleUsesRepositoryName() {
        // The worktree root is Application Support/Pine/AgentWorktrees/<hash>;
        // the caller passes the repository name so no hash reaches the title.
        #expect(chrome(file: nil, repository: "pine").title == "pine")
    }

    // MARK: - Fallback chain

    @Test("No open tab falls back to the repository name")
    func noTabFallsBack() {
        #expect(
            chrome(file: nil, repository: "acme", switcher: "acme").title
                == "acme"
        )
    }

    @Test("An untitled buffer with a display name titles the window")
    func untitledBufferUsesItsDisplayName() {
        #expect(chrome(file: "Untitled 2").title == "Untitled 2")
    }

    @Test(
        "Blank file names fall through to the repository",
        arguments: ["", " ", "\t", "\n", "   \n\t  "]
    )
    func blankFileNameFallsBack(blank: String) {
        #expect(chrome(file: blank).title == "pine")
    }

    @Test(
        "A window is never left nameless",
        arguments: ["", " ", "/", "\n"]
    )
    func namelessWindowIsImpossible(blankRepository: String) {
        // A window with an empty title disappears from the Window menu and
        // Mission Control. Both text inputs degenerate at once here — the
        // last resort must still produce something identifiable.
        let resolved = chrome(
            file: nil,
            repository: blankRepository,
            switcher: blankRepository
        )
        #expect(resolved.title == WindowChromePresentation.fallbackTitle)
        #expect(!resolved.title.isEmpty)
    }

    @Test("A blank switcher label never renders as empty text")
    func blankSwitcherLabelBecomesIconOnly() {
        // An empty Text() would reserve layout width for nothing and reach
        // the accessibility tree as a nameless string.
        #expect(chrome(file: "main.swift", switcher: "   ").switcherLabel == nil)
    }

    @Test("A filesystem-root project does not title the window '/'")
    func filesystemRootIsNotATitle() {
        // URL(fileURLWithPath: "/").lastPathComponent is "/".
        #expect(
            chrome(file: nil, repository: "/", switcher: "/").title
                == WindowChromePresentation.fallbackTitle
        )
    }

    // MARK: - Hostile and unusual names

    @Test("Surrounding whitespace is trimmed, inner spacing is preserved")
    func trimsEdgesOnly() {
        #expect(chrome(file: "  read me.swift \n").title == "read me.swift")
    }

    @Test("Whitespace differences alone do not defeat duplicate detection")
    func duplicateDetectionComparesTrimmedText() {
        // The switcher label and the title arrive from different call sites;
        // padding on one of them must not smuggle the duplicate back in.
        #expect(
            chrome(file: nil, repository: "pine", switcher: "  pine  ")
                .switcherLabel == nil
        )
    }

    @Test(
        "Unicode file names survive verbatim",
        arguments: [
            "Ünïcödé.swift",
            "файл.swift",
            "日本語.swift",
            "🌲.swift",
            "ملف.swift",
            "e\u{0301}xotic.swift"  // combining acute, not precomposed
        ]
    )
    func unicodeIsNotMangled(name: String) {
        // No normalization, no transliteration: the title must match the name
        // the user sees in Finder.
        #expect(chrome(file: name).title == name)
    }

    @Test("Canonically equivalent spellings still count as duplicates")
    func unicodeEquivalenceIsTreatedAsDuplicate() {
        // Swift string comparison is canonical, so a precomposed title and a
        // decomposed switcher label are equal — and must not both render.
        let resolved = WindowChromePresentation(
            activeFileName: nil,
            repositoryName: "Cafe\u{0301}",     // decomposed
            switcherLabel: "Caf\u{00E9}"        // precomposed
        )
        #expect(resolved.switcherLabel == nil)
    }

    @Test(
        "Structurally odd but legal POSIX names pass through",
        arguments: [
            ".env",
            "no-extension",
            "archive.tar.gz",
            "weird name with  double  spaces.txt",
            "file:with:colons.swift",
            "-leading-dash.swift"
        ]
    )
    func oddNamesPassThrough(name: String) {
        #expect(chrome(file: name).title == name)
    }

    @Test("An embedded newline is preserved rather than silently rewritten")
    func embeddedNewlineIsPreserved() {
        // POSIX allows newlines inside file names. Trimming is an edge
        // operation only — rewriting the interior would misreport which file
        // is open.
        #expect(chrome(file: "two\nlines.swift").title == "two\nlines.swift")
    }

    @Test("A pathological file name is not truncated by this layer")
    func longNameIsNotTruncated() {
        // Layout truncation belongs to AppKit, which knows the title bar
        // width. Truncating here would bake a wrong ellipsis into the value
        // the Window menu and accessibility tree read.
        let long = String(repeating: "a", count: 4096) + ".swift"
        #expect(chrome(file: long).title == long)
    }

    @Test("A file named like its project keeps the title, hides the label")
    func fileMatchingProjectNameCollapsesToOneSurface() {
        // Opening a file called `pine` inside project `pine` is a genuine
        // coincidence: the title still reports the open file, and the
        // switcher — which would print the same word — goes icon-only.
        let resolved = chrome(file: "pine")
        #expect(resolved.title == "pine")
        #expect(resolved.switcherLabel == nil)
    }

    // MARK: - Value semantics

    @Test("Equal inputs produce equal values")
    func equatableByResolvedFields() {
        let lhs = chrome(file: "  main.swift  ")
        let rhs = chrome(file: "main.swift")
        #expect(lhs == rhs)
        #expect(lhs != chrome(file: nil))
    }
}
