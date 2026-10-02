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

    // MARK: - The pill owns the project name; the title shows only the file

    @Test("An open file titles the window, and the title stays visible")
    func openFileTitlesTheWindow() {
        let resolved = chrome(file: "ContentView.swift")
        #expect(resolved.title == "ContentView.swift")
        #expect(resolved.showsTitle)
    }

    @Test("Without an editor tab the title hides instead of echoing the pill")
    func terminalOnlyWindowHidesTitle() {
        // A project with no restored session opens straight into a terminal
        // (#1251), so this is the first screen of a new project — the one
        // place the pill/title duplicate was most visible.
        let resolved = chrome(file: nil)
        #expect(resolved.title == "pine")
        #expect(resolved.showsTitle == false)
    }

    @Test("The hidden title still names the window for the system")
    func hiddenTitleKeepsSystemIdentity() {
        // Window menu, Mission Control, and window cycling read
        // `NSWindow.title` even when titleVisibility hides the text — the
        // string must outlive its visibility.
        #expect(chrome(file: nil, repository: "acme").title == "acme")
    }

    @Test("A blank file name counts as no file")
    func blankFileNameHidesTitle() {
        let resolved = chrome(file: "   ")
        #expect(resolved.title == "pine")
        #expect(resolved.showsTitle == false)
    }

    @Test("A file named like its project still titles the window")
    func fileMatchingProjectNameKeepsTitle() {
        // Opening a file called `pine` inside project `pine` is a genuine
        // coincidence: the title reports the open file — the duplication
        // rule applies to the fallback, not to real content.
        let resolved = chrome(file: "pine")
        #expect(resolved.title == "pine")
        #expect(resolved.showsTitle)
    }

    // MARK: - Worktree windows

    @Test("A worktree window never surfaces its hashed service directory")
    func worktreeTitleUsesRepositoryName() {
        // The worktree root is Application Support/Pine/AgentWorktrees/<hash>;
        // the caller passes the repository name so no hash reaches the title.
        let resolved = chrome(file: nil, repository: "pine")
        #expect(resolved.title == "pine")
        #expect(resolved.showsTitle == false)
    }

    // MARK: - Fallback chain

    @Test("An untitled buffer with a display name titles the window")
    func untitledBufferUsesItsDisplayName() {
        let resolved = chrome(file: "Untitled 2")
        #expect(resolved.title == "Untitled 2")
        #expect(resolved.showsTitle)
    }

    @Test(
        "Blank file names fall through to the repository",
        arguments: ["", " ", "\t", "\n", "   \n\t  "]
    )
    func blankFileNameFallsBack(blank: String) {
        let resolved = chrome(file: blank)
        #expect(resolved.title == "pine")
        #expect(resolved.showsTitle == false)
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
