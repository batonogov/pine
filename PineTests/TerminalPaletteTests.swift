//
//  TerminalPaletteTests.swift
//  PineTests
//
//  Tests for `TerminalPalette` — Pine's centralised macOS-aligned ANSI
//  16-color palette for the embedded SwiftTerm terminal (issue #733).
//

import Testing
import AppKit
import SwiftTerm
@testable import Pine

@Suite("TerminalPalette Tests")
struct TerminalPaletteTests {

    // MARK: - Shape

    @Test func paletteHasExactly16Entries() {
        #expect(TerminalPalette.macOSAligned.count == TerminalPalette.colorCount)
        #expect(TerminalPalette.colorCount == 16)
    }

    @Test func paletteEntriesAreOrderedAndDistinct() {
        let entries = TerminalPalette.macOSAligned
        // No two slots are the exact same RGB — every ANSI color is unique.
        let uniqueCount = Set(entries.map { "\($0.red),\($0.green),\($0.blue)" }).count
        #expect(uniqueCount == entries.count)
    }

    // MARK: - Reference values (Ghostty default — exact RGB)

    /// Locking the palette to its reference values prevents accidental
    /// drift the next time someone "tweaks one color" without realising it
    /// affects every Pine terminal.
    @Test func paletteMatchesGhosttyDefault() {
        let expected: [(UInt8, UInt8, UInt8)] = [
            (0x1D, 0x1F, 0x21), // 0  black
            (0xCC, 0x66, 0x66), // 1  red
            (0xB5, 0xBD, 0x68), // 2  green
            (0xF0, 0xC6, 0x74), // 3  yellow
            (0x81, 0xA2, 0xBE), // 4  blue
            (0xB2, 0x94, 0xBB), // 5  magenta
            (0x8A, 0xBE, 0xB7), // 6  cyan
            (0xC5, 0xC8, 0xC6), // 7  white
            (0x66, 0x66, 0x66), // 8  bright black
            (0xD5, 0x4E, 0x53), // 9  bright red
            (0xB9, 0xCA, 0x4A), // 10 bright green
            (0xE7, 0xC5, 0x47), // 11 bright yellow
            (0x7A, 0xA6, 0xDA), // 12 bright blue
            (0xC3, 0x97, 0xD8), // 13 bright magenta
            (0x70, 0xC0, 0xB1), // 14 bright cyan
            (0xEA, 0xEA, 0xEA), // 15 bright white
        ]
        let entries = TerminalPalette.macOSAligned
        #expect(entries.count == expected.count)
        for (index, exp) in expected.enumerated() {
            let entry = entries[index]
            #expect(entry.red == exp.0, "ANSI \(index) red mismatch")
            #expect(entry.green == exp.1, "ANSI \(index) green mismatch")
            #expect(entry.blue == exp.2, "ANSI \(index) blue mismatch")
        }
    }

    // MARK: - 8-bit → 16-bit conversion

    @Test func entryConvertsToSwiftTermColorWith257Multiplier() {
        // 0x00 → 0x0000, 0xFF → 0xFFFF, 0x80 → 0x8080, 0x1D → 0x1D1D
        let cases: [(UInt8, UInt16)] = [
            (0x00, 0x0000),
            (0xFF, 0xFFFF),
            (0x80, 0x8080),
            (0x1D, 0x1D1D),
            (0xCC, 0xCCCC),
        ]
        for (eight, sixteen) in cases {
            let entry = TerminalPaletteEntry(red: eight, green: eight, blue: eight)
            let color = entry.makeSwiftTermColor()
            #expect(color.red == sixteen)
            #expect(color.green == sixteen)
            #expect(color.blue == sixteen)
        }
    }

    @Test func entryEdgeBoundariesDoNotOverflow() {
        // Maximum value 255 must map cleanly to 0xFFFF without truncation /
        // wrap-around. UInt8 cannot exceed 255 by construction, but verify the
        // arithmetic stays inside UInt16.
        let entry = TerminalPaletteEntry(red: 255, green: 255, blue: 255)
        let color = entry.makeSwiftTermColor()
        #expect(color.red == 0xFFFF)
        #expect(color.green == 0xFFFF)
        #expect(color.blue == 0xFFFF)

        let zero = TerminalPaletteEntry(red: 0, green: 0, blue: 0)
        let zc = zero.makeSwiftTermColor()
        #expect(zc.red == 0)
        #expect(zc.green == 0)
        #expect(zc.blue == 0)
    }

    // MARK: - swiftTermColors() guard

    @Test func swiftTermColorsReturnsSixteenColorsForDefaultPalette() {
        let colors = TerminalPalette.swiftTermColors()
        #expect(colors != nil)
        #expect(colors?.count == 16)
    }

    @Test func swiftTermColorsRejectsTooFewEntries() {
        let truncated = Array(TerminalPalette.macOSAligned.prefix(8))
        #expect(TerminalPalette.swiftTermColors(from: truncated) == nil)
    }

    @Test func swiftTermColorsRejectsTooManyEntries() {
        let extra = TerminalPalette.macOSAligned + [
            TerminalPaletteEntry(red: 1, green: 2, blue: 3),
        ]
        #expect(TerminalPalette.swiftTermColors(from: extra) == nil)
    }

    @Test func swiftTermColorsRejectsEmptyPalette() {
        #expect(TerminalPalette.swiftTermColors(from: []) == nil)
    }

    // MARK: - install(on:) integration

    /// SwiftTerm's installed palette is internal — there is no public getter
    /// to compare colors against. The best we can do at the integration
    /// boundary is verify that `install(on:)` does not crash and that the
    /// view remains usable. The exact RGB content is fully covered by the
    /// pure-Swift tests above (`paletteMatchesGhosttyDefault`,
    /// `entryConvertsToSwiftTermColorWith257Multiplier`).
    @Test @MainActor func installDoesNotCrashOnFreshTerminalView() {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        TerminalPalette.install(on: view)
        // View must still expose its terminal after install.
        _ = view.getTerminal()
    }

    @Test @MainActor func installIsIdempotent() {
        // Installing twice must leave the terminal in a healthy state —
        // no accumulation, no crash, palette helper still returns colors.
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        TerminalPalette.install(on: view)
        TerminalPalette.install(on: view)
        _ = view.getTerminal()
        #expect(TerminalPalette.swiftTermColors()?.count == 16)
    }

    @Test @MainActor func newTerminalTabInstallsPaletteWithoutCrashing() {
        // Smoke test: TerminalTab.init must call into TerminalPalette.install
        // without throwing or producing a nil terminal. Exact RGB values are
        // verified by the pure-Swift tests above.
        let tab = TerminalTab(name: "palette-test")
        _ = tab.terminalView.getTerminal()
    }

    @Test @MainActor func newTerminalTabDisablesUseBrightColors() {
        // Bold-as-bright doubles brightness and was a major source of the
        // visual mismatch with Ghostty / Terminal.app (issue #733).
        let tab = TerminalTab(name: "test")
        #expect(tab.terminalView.useBrightColors == false)
    }
}
