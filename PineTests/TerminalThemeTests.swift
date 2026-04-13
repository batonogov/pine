//
//  TerminalThemeTests.swift
//  PineTests
//
//  Tests for Pine's One Dark terminal palette — verifies the 16-entry palette,
//  correct hex values, and ghost text override application.
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

    @Test("macOSAligned uses One Dark as base")
    func macOSAlignedIsOneDarkBased() {
        // Slots 1..15 must match One Dark exactly
        for idx in 1..<16 {
            #expect(
                TerminalPalette.macOSAligned[idx] == TerminalPalette.oneDark[idx],
                "slot \(idx) drifted from One Dark"
            )
        }
    }

    @Test("macOSAligned slot 0 is ghost text override, not One Dark black")
    func slot0IsGhostTextOverride() {
        #expect(TerminalPalette.macOSAligned[0] == TerminalPalette.ghostTextOverride)
        #expect(TerminalPalette.macOSAligned[0] != TerminalPalette.oneDark[0])
    }

    @Test("Ghost text override is One Dark's slot 8 value (#5C6370)")
    func ghostTextOverrideIsOneDarkBrightBlack() {
        let ghost = TerminalPalette.ghostTextOverride
        #expect(ghost.red == 0x5C)
        #expect(ghost.green == 0x63)
        #expect(ghost.blue == 0x70)
        // Must match One Dark slot 8 exactly
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
