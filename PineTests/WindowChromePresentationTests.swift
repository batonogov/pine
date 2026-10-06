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
        repository: String = "pine"
    ) -> WindowChromePresentation {
        WindowChromePresentation(
            activeFileName: file,
            repositoryName: repository
        )
    }

    // MARK: - Fallback chain (the title is pure system identity)

    @Test("An open file names the window for the system")
    func openFileTitlesTheWindow() {
        #expect(chrome(file: "ContentView.swift").title == "ContentView.swift")
    }

    @Test("With no editor tab the repository names the window")
    func terminalOnlyWindowFallsBackToRepository() {
        // A project with no restored session opens straight into a terminal
        // (#1251). Nothing reads this string off the title bar — the visible
        // title is hidden for good — but the Window menu and Mission Control
        // do.
        #expect(chrome(file: nil).title == "pine")
    }

    @Test("A file named like its project still names the window")
    func fileMatchingProjectNameKeepsTitle() {
        // Opening a file called `pine` inside project `pine` is a genuine
        // coincidence: the system title reports the open file.
        #expect(chrome(file: "pine").title == "pine")
    }

    // MARK: - Worktree windows

    @Test("A worktree window never surfaces its hashed service directory")
    func worktreeTitleUsesRepositoryName() {
        // The worktree root is Application Support/Pine/AgentWorktrees/<hash>;
        // the caller passes the repository name so no hash reaches the title.
        #expect(chrome(file: nil, repository: "pine").title == "pine")
    }

    // MARK: - Fallback chain edge cases

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
        // Mission Control — the last resort must still produce something
        // identifiable.
        let resolved = chrome(file: nil, repository: blankRepository)
        #expect(resolved.title == WindowChromePresentation.fallbackTitle)
        #expect(!resolved.title.isEmpty)
    }

    @Test("A filesystem-root project does not title the window '/'")
    func filesystemRootIsNotATitle() {
        // URL(fileURLWithPath: "/").lastPathComponent is "/".
        #expect(
            chrome(file: nil, repository: "/").title
                == WindowChromePresentation.fallbackTitle
        )
    }

    // MARK: - Hostile and unusual names

    @Test("Surrounding whitespace is trimmed, inner spacing is preserved")
    func trimsEdgesOnly() {
        #expect(chrome(file: "  read me.swift \n").title == "read me.swift")
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

    // MARK: - Value semantics

    @Test("Equal inputs produce equal values")
    func equatableByResolvedFields() {
        let lhs = chrome(file: "  main.swift  ")
        let rhs = chrome(file: "main.swift")
        #expect(lhs == rhs)
        #expect(lhs != chrome(file: nil))
    }
}
