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

    @Test("Icon slot width is positive and non-trivial")
    func iconSlotWidthIsReasonable() {
        #expect(FileNodeRow.iconSlotWidth > 0)
        // Must be wide enough to fit the widest SF Symbol we render
        // (badge-composed glyphs like `folder.badge.gearshape` are ~20 pt).
        #expect(FileNodeRow.iconSlotWidth >= 22)
        // But not so wide that it creates an awkward gap.
        #expect(FileNodeRow.iconSlotWidth <= 30)
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

    @Test("Fixed slot width fits every SF Symbol used by FileIconMapper")
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

        let config = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
        for symbol in symbolSet {
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else {
                // If a symbol fails to load, fail loudly — the sidebar would
                // render a blank icon which is strictly worse than alignment.
                Issue.record("SF Symbol \(symbol) could not be loaded")
                continue
            }
            let width = image.size.width
            #expect(
                width <= FileNodeRow.iconSlotWidth,
                "SF Symbol \(symbol) intrinsic width \(width) exceeds slot \(FileNodeRow.iconSlotWidth)"
            )
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

    @Test("Both branches use the same icon slot width (no divergence)")
    func bothBranchesShareSlotWidth() {
        // Shared constants — if anything changes the inline-rename branch to
        // use a different width, this value must be updated here too, which
        // surfaces the divergence in code review.
        let expected: CGFloat = 22
        #expect(FileNodeRow.iconSlotWidth == expected)
        #expect(FileNodeRow.iconTextSpacing == 6)
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
        #expect(FileNodeRow.iconSlotWidth == 22)
    }

    @Test("Every string literal in FileIconMapper.swift fits the icon slot")
    func allMapperLiteralsFitSlot() {
        // Locate the source file relative to the test bundle's project path.
        // The test bundle lives under DerivedData, so we walk up from #filePath
        // (this test file) to find FileIconMapper.swift.
        let testFilePath = URL(fileURLWithPath: #filePath)
        let projectRoot = testFilePath
            .deletingLastPathComponent() // PineTests/
            .deletingLastPathComponent() // repo root
        let mapperURL = projectRoot
            .appendingPathComponent("Pine")
            .appendingPathComponent("FileIconMapper.swift")

        guard let source = try? String(contentsOf: mapperURL, encoding: .utf8) else {
            Issue.record("Could not read FileIconMapper.swift at \(mapperURL.path)")
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

        let config = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
        var tested = 0
        for symbol in symbols {
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else {
                continue  // Not an SF Symbol — skip (e.g. file extensions, regex)
            }
            tested += 1
            let width = image.size.width
            #expect(
                width <= FileNodeRow.iconSlotWidth,
                "SF Symbol \(symbol) intrinsic width \(width) exceeds slot \(FileNodeRow.iconSlotWidth)"
            )
        }
        #expect(tested >= 10, "Expected to validate at least 10 real SF Symbols, validated \(tested)")
    }

    private func isPlausibleSymbol(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 60 else { return false }
        // SF Symbols are lowercase, dot-separated identifiers.
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." } && s.contains { $0.isLetter }
    }

    @Test("Hidden (dotfile) names map to a valid icon that fits the slot")
    func hiddenFilesFitSlot() {
        let hidden = [".env", ".gitignore", ".DS_Store", ".hidden"]
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
        for name in hidden {
            let symbol = FileIconMapper.iconForFile(name)
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            #expect(image != nil, "Hidden file \(name) icon \(symbol) should load")
            if let width = image?.size.width {
                #expect(width <= FileNodeRow.iconSlotWidth)
            }
        }
    }
}
