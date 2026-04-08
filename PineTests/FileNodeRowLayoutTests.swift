//
//  FileNodeRowLayoutTests.swift
//  PineTests
//
//  Tests for the sidebar row layout constants that keep file/folder names
//  vertically aligned regardless of SF Symbol icon glyph width (#763).
//  Also ensures the non-editing and inline-rename branches share the same
//  layout so entering rename does not visually jump the row (regression #736).
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("FileNodeRow layout")
struct FileNodeRowLayoutTests {

    // MARK: - Layout constants

    /// Font sizes the sidebar may render at — covers `FontSizeSettings`
    /// min/default/max plus a few common in-between values. Every layout
    /// invariant must hold for the full range, not just the system default.
    private static let fontSizesUnderTest: [CGFloat] = [11, 12, 13, 14, 16, 18, 20, 24, 32]

    @Test("Icon slot width is positive and non-trivial across all font sizes")
    func iconSlotWidthIsReasonable() {
        for fontSize in Self.fontSizesUnderTest {
            let slot = FileNodeRow.iconSlotWidth(forFontSize: fontSize)
            #expect(slot > 0)
            // Must scale with font size — at least the font size itself,
            // because SF Symbol glyphs render at ~font cap height + descenders.
            #expect(slot >= fontSize)
            // But not so wide that it creates an awkward gap (≤ 2× font size).
            #expect(slot <= fontSize * 2)
        }
        // At the system default font size the slot must still satisfy the
        // historical >= 22 pt floor that fits badge-composed glyphs.
        #expect(FileNodeRow.iconSlotWidth(forFontSize: NSFont.systemFontSize) >= 22)
    }

    @Test("Icon-text spacing is non-negative and compact")
    func iconTextSpacingIsReasonable() {
        #expect(FileNodeRow.iconTextSpacing >= 0)
        #expect(FileNodeRow.iconTextSpacing <= 12)
    }

    // MARK: - SF Symbol fit guarantee (#763)
    //
    // The fixed slot width must be >= the intrinsic width of every SF Symbol
    // the sidebar ever renders; otherwise glyphs get clipped and the point of
    // the fix is lost. We measure intrinsic size via NSImage and assert.

    @Test("Slot width fits every SF Symbol used by FileIconMapper across font sizes")
    func slotFitsAllUsedSymbols() {
        // Collect a comprehensive set of icons that the sidebar may display.
        // We deliberately probe FileIconMapper across many representative
        // names (folders, files, dotfiles, configs) to exercise every branch.
        let probeNames = [
            // Folders
            ".git", ".github", "src", "node_modules", "build", "dist",
            "tests", "docs", "assets", "images", "config", "scripts",
            // Files with diverse icon mappings
            "README.md", "package.json", "Dockerfile", ".gitignore",
            ".env", ".pre-commit-config.yaml", ".secrets.baseline",
            "Makefile", "main.swift", "index.html", "styles.css",
            "script.sh", "data.yaml", "data.yml", "data.toml",
            "photo.png", "video.mp4", "archive.zip", "font.ttf",
            "LICENSE", "CHANGELOG.md", ".gitlab-ci.yml",
            "Package.swift", "Cargo.toml", "requirements.txt",
            "unknownfile.xyz"
        ]

        var symbolSet = Set<String>()
        for name in probeNames {
            symbolSet.insert(FileIconMapper.iconForFile(name))
            symbolSet.insert(FileIconMapper.iconForFolder(name))
        }
        // Sanity: we actually gathered a variety of symbols.
        #expect(symbolSet.count >= 3)

        for fontSize in Self.fontSizesUnderTest {
            let slot = FileNodeRow.iconSlotWidth(forFontSize: fontSize)
            let config = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
            for symbol in symbolSet {
                guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) else {
                    // If a symbol fails to load, fail loudly — the sidebar would
                    // render a blank icon which is strictly worse than alignment.
                    Issue.record("SF Symbol \(symbol) could not be loaded at font size \(fontSize)")
                    continue
                }
                let width = image.size.width
                #expect(
                    width <= slot,
                    "SF Symbol \(symbol) intrinsic width \(width) exceeds slot \(slot) at font size \(fontSize)"
                )
            }
        }
    }

    // MARK: - #736 regression guard
    //
    // We cannot measure a live SwiftUI layout in a unit test, but we can
    // assert that the constants used by both branches are the *same* source
    // of truth (static members on FileNodeRow). If someone later hard-codes
    // a different width in one branch, this test still passes — the real
    // guard is that there is exactly one declaration, which we enforce by
    // having only these two static constants and referencing them from both
    // branches in FileNodeRow.swift. This test documents the invariant.

    @Test("Both branches reference iconSlotWidth (regression guard for #736)")
    func bothBranchesShareSlotWidth() {
        // Real regression guard: parse FileNodeRow.swift and assert that
        // `iconSlotWidth` is referenced in BOTH the non-editing branch and
        // the inline rename branch. If a refactor accidentally drops the
        // call from one branch (re-introducing #736), this fails.
        guard let source = readPineSource(named: "FileNodeRow.swift") else {
            Issue.record("Could not read FileNodeRow.swift")
            return
        }
        // Count call-site references (exclude the declaration `static func iconSlotWidth`).
        let callOccurrences = source.components(separatedBy: "iconSlotWidth(forFontSize:").count - 1
        #expect(
            callOccurrences >= 2,
            "Expected iconSlotWidth(forFontSize:) to be called from both row branches, found \(callOccurrences)"
        )
        // Same invariant for the icon-text spacing constant.
        let spacingOccurrences = source.components(separatedBy: "iconTextSpacing").count - 1
        // Declaration + 2 call sites = 3 minimum.
        #expect(
            spacingOccurrences >= 3,
            "Expected iconTextSpacing to be referenced from both row branches, found \(spacingOccurrences)"
        )
    }

    // MARK: - Edge cases

    @Test("Very long file names do not affect layout constants")
    func longNamesIndependentOfConstants() {
        // Constants are static — long names cannot mutate them. This test
        // exists to document that the slot width is a layout concern only,
        // independent of text content length.
        let longName = String(repeating: "a", count: 500) + ".swift"
        let icon = FileIconMapper.iconForFile(longName)
        #expect(!icon.isEmpty)
        // The slot is a pure function of font size — name length cannot affect it.
        let slotA = FileNodeRow.iconSlotWidth(forFontSize: 13)
        let slotB = FileNodeRow.iconSlotWidth(forFontSize: 13)
        #expect(slotA == slotB)
        // And it scales monotonically with font size.
        #expect(FileNodeRow.iconSlotWidth(forFontSize: 24) > FileNodeRow.iconSlotWidth(forFontSize: 12))
    }

    @Test("Every string literal in FileIconMapper.swift fits the icon slot across font sizes")
    func allMapperLiteralsFitSlot() {
        guard let source = readPineSource(named: "FileIconMapper.swift") else {
            // Fail-fast: without the source file the rest of the test is meaningless.
            Issue.record("Could not read FileIconMapper.swift via #filePath traversal")
            #expect(Bool(false), "FileIconMapper.swift source unavailable; test cannot run")
            return
        }

        // Extract double-quoted string literals that look like SF Symbol names
        // (alphanumerics, dots, and no spaces). We intentionally over-match
        // and then filter by whether the symbol actually loads.
        var symbols = Set<String>()
        var current = ""
        var inside = false
        var escape = false
        for char in source {
            if escape { escape = false; if inside { current.append(char) }; continue }
            if char == "\\" { escape = true; continue }
            if char == "\"" {
                if inside {
                    // End of literal
                    if isPlausibleSymbol(current) { symbols.insert(current) }
                    current = ""
                    inside = false
                } else {
                    inside = true
                }
                continue
            }
            if inside { current.append(char) }
        }

        #expect(symbols.count >= 20, "Expected to extract many symbols, got \(symbols.count)")

        var totalTested = 0
        for fontSize in Self.fontSizesUnderTest {
            let slot = FileNodeRow.iconSlotWidth(forFontSize: fontSize)
            let config = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
            var tested = 0
            for symbol in symbols {
                guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) else {
                    continue  // Not an SF Symbol — skip (e.g. file extensions, regex)
                }
                tested += 1
                let width = image.size.width
                #expect(
                    width <= slot,
                    "SF Symbol \(symbol) intrinsic width \(width) exceeds slot \(slot) at font size \(fontSize)"
                )
            }
            #expect(tested >= 10, "Expected ≥10 SF Symbols at font size \(fontSize), validated \(tested)")
            totalTested += tested
        }
        #expect(totalTested > 0)
    }

    // MARK: - Source helpers

    /// Reads a file from `Pine/` relative to this test file's `#filePath`.
    /// Returns `nil` if the file cannot be located, so callers can fail-fast.
    private func readPineSource(named name: String) -> String? {
        let testFilePath = URL(fileURLWithPath: #filePath)
        let projectRoot = testFilePath
            .deletingLastPathComponent() // PineTests/
            .deletingLastPathComponent() // repo root
        let url = projectRoot.appendingPathComponent("Pine").appendingPathComponent(name)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func isPlausibleSymbol(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 60 else { return false }
        // SF Symbols are lowercase, dot-separated identifiers.
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." } && s.contains { $0.isLetter }
    }

    @Test("Hidden (dotfile) names map to a valid icon that fits the slot at every font size")
    func hiddenFilesFitSlot() {
        let hidden = [".env", ".gitignore", ".DS_Store", ".hidden"]
        for fontSize in Self.fontSizesUnderTest {
            let slot = FileNodeRow.iconSlotWidth(forFontSize: fontSize)
            let config = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
            for name in hidden {
                let symbol = FileIconMapper.iconForFile(name)
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
                #expect(image != nil, "Hidden file \(name) icon \(symbol) should load at \(fontSize)pt")
                if let width = image?.size.width {
                    #expect(width <= slot, "\(symbol) width \(width) > slot \(slot) at \(fontSize)pt")
                }
            }
        }
    }
}
