//
//  SidebarRenameStemTests.swift
//  PineTests
//
//  Tests for Finder-style stem-range computation and rename validation
//  used by the sidebar inline rename flow (#737).
//

import Foundation
import Testing

@testable import Pine

@Suite("SidebarRenameStem")
struct SidebarRenameStemTests {

    // MARK: - stemRange happy path

    @Test("Simple file selects stem before extension")
    func simpleFile() {
        #expect(SidebarRenameStem.stemRange(for: "foo.swift") == NSRange(location: 0, length: 3))
    }

    @Test("Hidden file with no further extension selects entire name")
    func hiddenFile() {
        let name = ".gitignore"
        let expected = NSRange(location: 0, length: (name as NSString).length)
        #expect(SidebarRenameStem.stemRange(for: name) == expected)
    }

    @Test("Hidden env file selects entire name")
    func hiddenEnv() {
        let name = ".env"
        let expected = NSRange(location: 0, length: (name as NSString).length)
        #expect(SidebarRenameStem.stemRange(for: name) == expected)
    }

    @Test("File with no extension selects entire name (Makefile)")
    func makefile() {
        #expect(SidebarRenameStem.stemRange(for: "Makefile") == NSRange(location: 0, length: 8))
    }

    @Test("Multi-extension archive selects stem up to last dot")
    func archiveTarGz() {
        // archive.tar.gz → stem = "archive.tar" (length 11), the ".gz" is the extension.
        #expect(SidebarRenameStem.stemRange(for: "archive.tar.gz") == NSRange(location: 0, length: 11))
    }

    @Test("Directory always selects entire name regardless of dots")
    func directoryWithDot() {
        let name = "my.project"
        let expected = NSRange(location: 0, length: (name as NSString).length)
        #expect(SidebarRenameStem.stemRange(for: name, isDirectory: true) == expected)
    }

    @Test("Directory without dots selects entire name")
    func plainDirectory() {
        #expect(SidebarRenameStem.stemRange(for: "src", isDirectory: true) == NSRange(location: 0, length: 3))
    }

    // MARK: - stemRange edge cases

    @Test("Empty string returns zero-length range")
    func emptyString() {
        #expect(SidebarRenameStem.stemRange(for: "") == NSRange(location: 0, length: 0))
    }

    @Test("String of only dots: trailing dot causes stem to include all but last")
    func onlyDots() {
        // "..." has last dot at index 2, so stem = (0, 2)
        #expect(SidebarRenameStem.stemRange(for: "...") == NSRange(location: 0, length: 2))
    }

    @Test("Single dot returns full range (treated as hidden file)")
    func singleDot() {
        // Last dot at location 0 → leading-dot rule → full range.
        #expect(SidebarRenameStem.stemRange(for: ".") == NSRange(location: 0, length: 1))
    }

    @Test("Trailing dot file gets stem before the dot")
    func trailingDot() {
        // "foo." last dot at location 3 → stem (0, 3)
        #expect(SidebarRenameStem.stemRange(for: "foo.") == NSRange(location: 0, length: 3))
    }

    @Test("Very long filename computes correct stem")
    func longName() {
        let stem = String(repeating: "a", count: 500)
        let name = stem + ".txt"
        let result = SidebarRenameStem.stemRange(for: name)
        #expect(result == NSRange(location: 0, length: 500))
    }

    @Test("Unicode filename selects stem in UTF-16 units")
    func unicodeName() {
        // "Привет.txt" — Cyrillic, each char is 1 UTF-16 unit; stem = 6
        let name = "Привет.txt"
        #expect(SidebarRenameStem.stemRange(for: name) == NSRange(location: 0, length: 6))
    }

    @Test("Emoji filename selects stem in UTF-16 units (surrogate pairs)")
    func emojiName() {
        // "🎉party.swift" — 🎉 is a surrogate pair (2 UTF-16 units)
        // stem = "🎉party" → 2 + 5 = 7 UTF-16 units
        let name = "🎉party.swift"
        #expect(SidebarRenameStem.stemRange(for: name) == NSRange(location: 0, length: 7))
    }

    @Test("Single-letter file with extension")
    func singleLetterFile() {
        #expect(SidebarRenameStem.stemRange(for: "a.b") == NSRange(location: 0, length: 1))
    }

    // MARK: - validationError

    @Test("Empty proposed name → empty error")
    func validationEmpty() {
        let oldURL = URL(fileURLWithPath: "/tmp/foo.txt")
        let result = SidebarRenameStem.validationError(for: "", oldURL: oldURL, existingNames: [])
        #expect(result == Strings.renameErrorEmpty)
    }

    @Test("Whitespace-only name trimmed → empty error")
    func validationWhitespace() {
        let oldURL = URL(fileURLWithPath: "/tmp/foo.txt")
        let result = SidebarRenameStem.validationError(for: "   \t  ", oldURL: oldURL, existingNames: [])
        #expect(result == Strings.renameErrorEmpty)
    }

    @Test("Slash in name → invalid characters error")
    func validationSlash() {
        let oldURL = URL(fileURLWithPath: "/tmp/foo.txt")
        let result = SidebarRenameStem.validationError(for: "bad/name.txt", oldURL: oldURL, existingNames: [])
        #expect(result == Strings.renameErrorInvalidCharacters)
    }

    @Test("Colon in name → invalid characters error")
    func validationColon() {
        let oldURL = URL(fileURLWithPath: "/tmp/foo.txt")
        let result = SidebarRenameStem.validationError(for: "bad:name.txt", oldURL: oldURL, existingNames: [])
        #expect(result == Strings.renameErrorInvalidCharacters)
    }

    @Test("Duplicate name → duplicate error")
    func validationDuplicate() {
        let oldURL = URL(fileURLWithPath: "/tmp/foo.txt")
        let result = SidebarRenameStem.validationError(
            for: "existing.txt",
            oldURL: oldURL,
            existingNames: ["existing.txt", "other.txt"]
        )
        #expect(result == Strings.renameErrorDuplicate("existing.txt"))
    }

    @Test("Same name as old URL → no error (no-op)")
    func validationSameName() {
        let oldURL = URL(fileURLWithPath: "/tmp/foo.txt")
        let result = SidebarRenameStem.validationError(
            for: "foo.txt",
            oldURL: oldURL,
            existingNames: ["foo.txt"]
        )
        #expect(result == nil)
    }

    @Test("Valid new unique name → no error")
    func validationValid() {
        let oldURL = URL(fileURLWithPath: "/tmp/foo.txt")
        let result = SidebarRenameStem.validationError(
            for: "bar.txt",
            oldURL: oldURL,
            existingNames: ["foo.txt", "baz.txt"]
        )
        #expect(result == nil)
    }

    @Test("Single dot \".\" is reserved → invalid")
    func validationSingleDot() {
        let oldURL = URL(fileURLWithPath: "/tmp/foo.txt")
        #expect(
            SidebarRenameStem.validationError(for: ".", oldURL: oldURL, existingNames: [])
                == Strings.renameErrorInvalidCharacters
        )
    }

    @Test("Double dot \"..\" is reserved → invalid")
    func validationDoubleDot() {
        let oldURL = URL(fileURLWithPath: "/tmp/foo.txt")
        #expect(
            SidebarRenameStem.validationError(for: "..", oldURL: oldURL, existingNames: [])
                == Strings.renameErrorInvalidCharacters
        )
    }

    @Test("Name containing NUL byte → invalid")
    func validationNulByte() {
        let oldURL = URL(fileURLWithPath: "/tmp/foo.txt")
        #expect(
            SidebarRenameStem.validationError(for: "bad\0name", oldURL: oldURL, existingNames: [])
                == Strings.renameErrorInvalidCharacters
        )
    }

    @Test("Hidden file name (.envrc) is valid — leading dot allowed")
    func validationHiddenFileLeadingDotValid() {
        let oldURL = URL(fileURLWithPath: "/tmp/foo.txt")
        #expect(
            SidebarRenameStem.validationError(
                for: ".envrc", oldURL: oldURL, existingNames: []
            ) == nil
        )
    }
}

// MARK: - TabManager rename URL update integration

@Suite("TabManager handleFileRenamed")
@MainActor
struct TabManagerHandleFileRenamedTests {

    @Test("Renamed file URL is updated on the open tab")
    func renameFile() {
        let manager = TabManager()
        let oldURL = URL(fileURLWithPath: "/tmp/project/old.swift")
        let newURL = URL(fileURLWithPath: "/tmp/project/new.swift")
        manager.tabs = [EditorTab(url: oldURL, content: "x")]

        manager.handleFileRenamed(oldURL: oldURL, newURL: newURL)

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].url == newURL)
    }

    @Test("Tab identity preserved across rename (not closed and reopened)")
    func renamePreservesIdentity() {
        let manager = TabManager()
        let oldURL = URL(fileURLWithPath: "/tmp/project/old.swift")
        let newURL = URL(fileURLWithPath: "/tmp/project/new.swift")
        let tab = EditorTab(url: oldURL, content: "x")
        manager.tabs = [tab]
        let originalID = manager.tabs[0].id

        manager.handleFileRenamed(oldURL: oldURL, newURL: newURL)

        #expect(manager.tabs[0].id == originalID)
    }

    @Test("Renaming a folder updates URLs of all nested open tabs")
    func renameFolderUpdatesNested() {
        let manager = TabManager()
        let oldFolder = URL(fileURLWithPath: "/tmp/project/old")
        let newFolder = URL(fileURLWithPath: "/tmp/project/new")
        let nested1 = oldFolder.appendingPathComponent("a.swift")
        let nested2 = oldFolder.appendingPathComponent("sub/b.swift")
        let unrelated = URL(fileURLWithPath: "/tmp/project/other.swift")
        manager.tabs = [
            EditorTab(url: nested1, content: ""),
            EditorTab(url: nested2, content: ""),
            EditorTab(url: unrelated, content: "")
        ]

        manager.handleFileRenamed(oldURL: oldFolder, newURL: newFolder)

        #expect(manager.tabs[0].url == newFolder.appendingPathComponent("a.swift"))
        #expect(manager.tabs[1].url == newFolder.appendingPathComponent("sub/b.swift"))
        #expect(manager.tabs[2].url == unrelated)
    }

    @Test("Rename is a no-op when no tab matches the old URL")
    func renameNoMatchingTab() {
        let manager = TabManager()
        let unrelated = URL(fileURLWithPath: "/tmp/project/other.swift")
        manager.tabs = [EditorTab(url: unrelated, content: "")]

        manager.handleFileRenamed(
            oldURL: URL(fileURLWithPath: "/tmp/project/missing.swift"),
            newURL: URL(fileURLWithPath: "/tmp/project/new.swift")
        )

        #expect(manager.tabs[0].url == unrelated)
    }

    @Test("Folder rename does not match prefix of unrelated file (boundary check)")
    func folderRenamePrefixBoundary() {
        let manager = TabManager()
        // /tmp/project/old should NOT match /tmp/project/oldish.swift
        let oldFolder = URL(fileURLWithPath: "/tmp/project/old")
        let newFolder = URL(fileURLWithPath: "/tmp/project/new")
        let lookalike = URL(fileURLWithPath: "/tmp/project/oldish.swift")
        manager.tabs = [EditorTab(url: lookalike, content: "")]

        manager.handleFileRenamed(oldURL: oldFolder, newURL: newFolder)

        #expect(manager.tabs[0].url == lookalike)
    }
}
