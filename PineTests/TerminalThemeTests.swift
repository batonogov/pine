//
//  TerminalThemeTests.swift
//  PineTests
//
//  Tests for Pine's One Dark terminal palette — verifies the 16-entry palette
//  and correct hex values.
//

import Foundation
import Testing
@testable import Pine

// MARK: - One Dark palette shape

@Suite("One Dark palette")
struct OneDarkPaletteTests {

    @Test("One Dark palette has exactly 16 entries")
    func oneDarkHas16Entries() {
        #expect(TerminalPalette.oneDark.count == 16)
    }

    @Test("macOSAligned is exactly One Dark, no slot substitutions")
    func macOSAlignedIsOneDark() {
        // Pine's SwiftTerm fork keeps bright foreground indexes addressable
        // (#1650), so the former slot-0 ghost-text substitution is gone:
        // every slot, including 0, matches One Dark.
        #expect(TerminalPalette.macOSAligned == TerminalPalette.oneDark)
    }

    @Test("Ghost text color is One Dark's slot 8 value (#5C6370)")
    func ghostTextUsesSlot8() {
        // zsh-autosuggestions ghost text (fg=8) reads the real bright-black
        // slot now that the 8 -> 0 collapse is fixed (#1650).
        let ghost = TerminalPalette.macOSAligned[8]
        #expect(ghost.red == 0x5C)
        #expect(ghost.green == 0x63)
        #expect(ghost.blue == 0x70)
        #expect(ghost == TerminalPalette.oneDark[8])
    }
}

// MARK: - One Dark canonical hex values

@Suite("One Dark hex values")
struct OneDarkHexValueTests {

    @Test("Slot 0 (black) is #282C34")
    func black() {
        let entry = TerminalPalette.oneDark[0]
        #expect(entry.red == 0x28)
        #expect(entry.green == 0x2C)
        #expect(entry.blue == 0x34)
    }

    @Test("Slot 1 (red) is #E06C75")
    func red() {
        let entry = TerminalPalette.oneDark[1]
        #expect(entry.red == 0xE0)
        #expect(entry.green == 0x6C)
        #expect(entry.blue == 0x75)
    }

    @Test("Slot 2 (green) is #98C379")
    func green() {
        let entry = TerminalPalette.oneDark[2]
        #expect(entry.red == 0x98)
        #expect(entry.green == 0xC3)
        #expect(entry.blue == 0x79)
    }

    @Test("Slot 3 (yellow) is #E5C07B")
    func yellow() {
        let entry = TerminalPalette.oneDark[3]
        #expect(entry.red == 0xE5)
        #expect(entry.green == 0xC0)
        #expect(entry.blue == 0x7B)
    }

    @Test("Slot 4 (blue) is #61AFEF")
    func blue() {
        let entry = TerminalPalette.oneDark[4]
        #expect(entry.red == 0x61)
        #expect(entry.green == 0xAF)
        #expect(entry.blue == 0xEF)
    }

    @Test("Slot 5 (magenta) is #C678DD")
    func magenta() {
        let entry = TerminalPalette.oneDark[5]
        #expect(entry.red == 0xC6)
        #expect(entry.green == 0x78)
        #expect(entry.blue == 0xDD)
    }

    @Test("Slot 6 (cyan) is #56B6C2")
    func cyan() {
        let entry = TerminalPalette.oneDark[6]
        #expect(entry.red == 0x56)
        #expect(entry.green == 0xB6)
        #expect(entry.blue == 0xC2)
    }

    @Test("Slot 7 (white) is #ABB2BF")
    func white() {
        let entry = TerminalPalette.oneDark[7]
        #expect(entry.red == 0xAB)
        #expect(entry.green == 0xB2)
        #expect(entry.blue == 0xBF)
    }

    @Test("Slot 8 (bright black) is #5C6370")
    func brightBlack() {
        let entry = TerminalPalette.oneDark[8]
        #expect(entry.red == 0x5C)
        #expect(entry.green == 0x63)
        #expect(entry.blue == 0x70)
    }

    @Test("Bright colors 9-14 match their normal counterparts (canonical One Dark)")
    func brightColorsMatchNormal() {
        // One Dark intentionally uses the same values for normal and bright
        // (except slot 15 bright white which is #FFFFFF).
        for idx in 1...6 {
            #expect(
                TerminalPalette.oneDark[idx + 8] == TerminalPalette.oneDark[idx],
                "bright slot \(idx + 8) should equal normal slot \(idx)"
            )
        }
    }

    @Test("Slot 15 (bright white) is #FFFFFF")
    func brightWhite() {
        let entry = TerminalPalette.oneDark[15]
        #expect(entry.red == 0xFF)
        #expect(entry.green == 0xFF)
        #expect(entry.blue == 0xFF)
    }
}

// MARK: - SwiftTerm color conversion for One Dark palette

@Suite("One Dark swiftTermColors")
struct OneDarkSwiftTermColorsTests {

    @Test("swiftTermColors succeeds for macOSAligned (One Dark based)")
    func swiftTermColorsSucceeds() {
        let colors = TerminalPalette.swiftTermColors()
        #expect(colors != nil)
        #expect(colors?.count == 16)
    }

    @Test("swiftTermColors succeeds for raw One Dark palette")
    func swiftTermColorsForRawOneDark() {
        let colors = TerminalPalette.swiftTermColors(from: TerminalPalette.oneDark)
        #expect(colors != nil)
        #expect(colors?.count == 16)
    }
}

// MARK: - Ghost text (slot 8) guard across all bundled themes

@Suite("Terminal theme ghost text")
struct TerminalThemeGhostTextTests {

    private func relativeLuminance(_ entry: TerminalPaletteEntry) -> Double {
        func channel(_ raw: UInt8) -> Double {
            let v = Double(raw) / 255.0
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = channel(entry.red)
        let g = channel(entry.green)
        let b = channel(entry.blue)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func contrastRatio(_ a: TerminalPaletteEntry, _ b: TerminalPaletteEntry) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Every bundled theme must keep ghost text (zsh-autosuggestions `fg=8`,
    /// which reads ANSI slot 8 since the SwiftTerm fork fixed the bright-index
    /// collapse in #1650) distinguishable from the theme background.
    ///
    /// The regression class this locks: Solarized dark shipped slot 8 == base03,
    /// byte-identical to its background (1.0:1 — strictly invisible), and Nord
    /// light sat at ~1.2:1. Ghost text is a non-essential hint and is dim by
    /// design, so the bar is a modest 1.5:1 — enough to be seen, below body
    /// text. Themes are expected to do better (Pine's own slot 8 clears 2:1).
    @Test("Slot 8 is readable against the background in every bundled theme")
    func slot8IsReadableInEveryTheme() {
        for theme in TerminalTheme.builtIn {
            for (schemeName, scheme) in [("light", theme.light), ("dark", theme.dark)] {
                let slot8 = scheme.ansiColors[8]
                #expect(
                    slot8 != scheme.background,
                    "\(theme.id) \(schemeName): slot 8 must not equal the background"
                )
                let ratio = contrastRatio(slot8, scheme.background)
                #expect(
                    ratio >= 1.5,
                    "\(theme.id) \(schemeName): slot 8 ghost-text contrast \(ratio) below 1.5:1"
                )
            }
        }
    }

    /// The Solarized fix is pinned exactly: bright black is base01 (#586E75)
    /// in both variants, not the background-colored base03/base3.
    @Test("Solarized slot 8 is base01 in both variants")
    func solarizedSlot8IsBase01() {
        let base01 = TerminalPaletteEntry(red: 0x58, green: 0x6E, blue: 0x75)
        #expect(TerminalTheme.solarized.dark.ansiColors[8] == base01)
        #expect(TerminalTheme.solarized.light.ansiColors[8] == base01)
        #expect(TerminalTheme.solarized.dark.ansiColors[8] != TerminalTheme.solarized.dark.background)
        #expect(TerminalTheme.solarized.light.ansiColors[8] != TerminalTheme.solarized.light.background)
    }
}
