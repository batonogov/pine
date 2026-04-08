//
//  TerminalPaletteTests.swift
//  PineTests
//
//  Tests for `TerminalPalette` — Pine's Terminal.app "Basic"-aligned ANSI
//  16-color palette plus the non-ANSI background / foreground / cursor /
//  selection colors for the embedded SwiftTerm terminal (issue #765).
//

import Testing
import AppKit
import Foundation
import SwiftTerm
@testable import Pine

@Suite("TerminalPalette Tests")
struct TerminalPaletteTests {

    // MARK: - Shape

    @Test func paletteHasExactly16Entries() {
        #expect(TerminalPalette.macOSAligned.count == TerminalPalette.colorCount)
        #expect(TerminalPalette.colorCount == 16)
    }

    @Test func paletteIsNonEmpty() {
        #expect(!TerminalPalette.macOSAligned.isEmpty)
    }

    @Test func paletteEntriesAreOrderedAndDistinct() {
        let entries = TerminalPalette.macOSAligned
        // No two slots are the exact same RGB — every ANSI color is unique.
        let uniqueCount = Set(entries.map { "\($0.red),\($0.green),\($0.blue)" }).count
        #expect(uniqueCount == entries.count)
    }

    @Test func defaultPaletteIsTerminalAppBasic() {
        // The currently-shipped default must point at Terminal.app Basic,
        // not any of the alternative profiles declared for the follow-up
        // theme picker.
        #expect(TerminalPalette.macOSAligned == TerminalPalette.terminalAppBasic)
    }

    // MARK: - Reference values (Terminal.app Basic — exact RGB)

    /// Locking the palette to Apple's Basic.terminal values prevents
    /// accidental drift the next time someone "tweaks one color" without
    /// realising it affects every Pine terminal. Source of truth:
    /// `/System/Applications/Utilities/Terminal.app/Contents/Resources/Basic.terminal`.
    @Test func paletteMatchesTerminalAppBasic() {
        let expected: [(UInt8, UInt8, UInt8)] = [
            (0x00, 0x00, 0x00), // 0  black
            (0x99, 0x00, 0x00), // 1  red
            (0x00, 0xA6, 0x00), // 2  green
            (0x99, 0x99, 0x00), // 3  yellow
            (0x00, 0x00, 0xB2), // 4  blue
            (0xB2, 0x00, 0xB2), // 5  magenta
            (0x00, 0xA6, 0xB2), // 6  cyan
            (0xBF, 0xBF, 0xBF), // 7  white
            (0x66, 0x66, 0x66), // 8  bright black
            (0xE5, 0x00, 0x00), // 9  bright red
            (0x00, 0xD9, 0x00), // 10 bright green
            (0xE5, 0xE5, 0x00), // 11 bright yellow
            (0x00, 0x00, 0xFF), // 12 bright blue
            (0xE5, 0x00, 0xE5), // 13 bright magenta
            (0x00, 0xE5, 0xE5), // 14 bright cyan
            (0xE5, 0xE5, 0xE5), // 15 bright white
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

    @Test func basicNonAnsiSlotsMatchTerminalApp() {
        // Background, foreground, cursor and selection colors must also
        // match Basic.terminal so the whole terminal is consistent — not
        // just the 16 ANSI foregrounds.
        #expect(TerminalPalette.basicBackground == TerminalPaletteEntry(red: 0x00, green: 0x00, blue: 0x00))
        #expect(TerminalPalette.basicForeground == TerminalPaletteEntry(red: 0xBF, green: 0xBF, blue: 0xBF))
        #expect(TerminalPalette.basicCursor == TerminalPaletteEntry(red: 0xBF, green: 0xBF, blue: 0xBF))
        #expect(TerminalPalette.basicSelection == TerminalPaletteEntry(red: 0x41, green: 0x41, blue: 0x41))
    }

    @Test func alternativeProfilesAreWellFormed() {
        // Pro and Solarized Dark are declared for a follow-up theme picker
        // PR. They are not wired up yet, but we still assert they are
        // 16-entry value arrays so a future reviewer cannot ship a
        // half-populated palette by accident.
        #expect(TerminalPalette.terminalAppPro.count == TerminalPalette.colorCount)
        #expect(TerminalPalette.solarizedDark.count == TerminalPalette.colorCount)
        // And that they really are different schemes — otherwise somebody
        // copy-pasted Basic into the wrong slot.
        #expect(TerminalPalette.terminalAppPro != TerminalPalette.terminalAppBasic)
        #expect(TerminalPalette.solarizedDark != TerminalPalette.terminalAppBasic)
    }

    // MARK: - 8-bit → 16-bit conversion

    @Test func entryConvertsToSwiftTermColorWith257Multiplier() {
        // 0x00 → 0x0000, 0xFF → 0xFFFF, 0x80 → 0x8080, 0xBF → 0xBFBF
        let cases: [(UInt8, UInt16)] = [
            (0x00, 0x0000),
            (0xFF, 0xFFFF),
            (0x80, 0x8080),
            (0xBF, 0xBFBF),
            (0x99, 0x9999),
            (0xE5, 0xE5E5),
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

    @Test func entryAsymmetricChannelsConvertIndependently() {
        // Regression guard: make sure the multiplier isn't applied only to
        // one channel. Use a mixed-channel Basic slot (blue = #0000B2).
        let blue = TerminalPaletteEntry(red: 0x00, green: 0x00, blue: 0xB2)
        let color = blue.makeSwiftTermColor()
        #expect(color.red == 0x0000)
        #expect(color.green == 0x0000)
        #expect(color.blue == 0xB2B2)
    }

    @Test func entryConvertsToNSColorInSRGB() {
        let entry = TerminalPaletteEntry(red: 0xBF, green: 0xBF, blue: 0xBF)
        let ns = entry.makeNSColor()
        // Round-trip through sRGB component accessors — must be within a
        // tiny epsilon to account for floating point arithmetic.
        let srgb = ns.usingColorSpace(.sRGB) ?? ns
        #expect(abs(srgb.redComponent - CGFloat(0xBF) / 255.0) < 0.001)
        #expect(abs(srgb.greenComponent - CGFloat(0xBF) / 255.0) < 0.001)
        #expect(abs(srgb.blueComponent - CGFloat(0xBF) / 255.0) < 0.001)
        #expect(abs(srgb.alphaComponent - 1.0) < 0.001)
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

    @Test func swiftTermColorsAcceptsAlternativeProfiles() {
        // Alternative profiles must round-trip through swiftTermColors so
        // the follow-up theme picker can install them without extra work.
        #expect(TerminalPalette.swiftTermColors(from: TerminalPalette.terminalAppPro)?.count == 16)
        #expect(TerminalPalette.swiftTermColors(from: TerminalPalette.solarizedDark)?.count == 16)
    }

    // MARK: - install(on:) integration

    /// SwiftTerm's installed palette is internal — there is no public getter
    /// to compare colors against. The best we can do at the integration
    /// boundary is verify that `install(on:)` does not crash and that the
    /// public NSColor slots (bg/fg/cursor/selection) are what we set.
    @Test @MainActor func installDoesNotCrashOnFreshTerminalView() {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        TerminalPalette.install(on: view)
        _ = view.getTerminal()
    }

    @Test @MainActor func installSetsBasicBackgroundForegroundCursorSelection() {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        TerminalPalette.install(on: view)

        func sameSRGB(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
            guard let a = lhs.usingColorSpace(.sRGB),
                  let b = rhs.usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) < 0.001
                && abs(a.greenComponent - b.greenComponent) < 0.001
                && abs(a.blueComponent - b.blueComponent) < 0.001
        }

        #expect(sameSRGB(view.nativeBackgroundColor, TerminalPalette.basicBackground.makeNSColor()))
        #expect(sameSRGB(view.nativeForegroundColor, TerminalPalette.basicForeground.makeNSColor()))
        #expect(sameSRGB(view.caretColor, TerminalPalette.basicCursor.makeNSColor()))
        #expect(sameSRGB(view.selectedTextBackgroundColor, TerminalPalette.basicSelection.makeNSColor()))
    }

    @Test @MainActor func installIsIdempotent() {
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

    // MARK: - Readability vs. Terminal.app Basic background (#000000)
    //
    // These assertions pin the contrast characteristics that users rely on
    // every day: the regular foreground and bright variants have to remain
    // comfortably readable. We do NOT assert that every ANSI slot clears
    // WCAG AA — Terminal.app Basic's deep-red (#990000) and deep-blue
    // (#0000B2) genuinely have ~2.4 / ~1.7 ratios against black; matching
    // Terminal.app exactly is the whole point of issue #765 and forcing a
    // higher bar would move us back off-profile.

    /// WCAG relative luminance for an 8-bit sRGB triple.
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

    @Test func whiteIsReadableAgainstBasicBackground() {
        // ANSI 7 (#BFBFBF) vs. Basic background (#000000) — the default
        // prompt foreground. Must clear WCAG AAA (7:1) so shells remain
        // comfortable for long sessions.
        let ratio = contrastRatio(TerminalPalette.macOSAligned[7], TerminalPalette.basicBackground)
        #expect(ratio >= 7.0, "white contrast \(ratio) below WCAG AAA")
    }

    @Test func brightWhiteIsReadableAgainstBasicBackground() {
        let ratio = contrastRatio(TerminalPalette.macOSAligned[15], TerminalPalette.basicBackground)
        #expect(ratio >= 7.0)
    }

    @Test func brightBlackIsDistinctFromBackground() {
        // bright black (#666666) must not collapse into the background
        // (#000000), otherwise zsh-autosuggestions and fish ghost text
        // become invisible. Terminal.app's Basic profile itself yields a
        // ~3.7:1 ratio here, so we lock that as the floor.
        let ratio = contrastRatio(TerminalPalette.macOSAligned[8], TerminalPalette.basicBackground)
        #expect(ratio >= 3.0, "bright black contrast \(ratio) too close to background")
    }

    @Test func brightBlackIsDimmerThanRegularForeground() {
        // Ghost-text affordance — bright black must still *look* dim vs.
        // regular white, otherwise the dim-text convention breaks.
        #expect(
            relativeLuminance(TerminalPalette.macOSAligned[8])
            < relativeLuminance(TerminalPalette.macOSAligned[7])
        )
    }

    @Test func brightVariantsAreBrighterThanTheirBaseColors() {
        // Every bright slot (9..15) must have strictly higher luminance
        // than its normal counterpart (1..7). This catches copy-paste
        // errors where a bright entry accidentally duplicates a dim one.
        for index in 1...7 {
            let normal = TerminalPalette.macOSAligned[index]
            let bright = TerminalPalette.macOSAligned[index + 8]
            #expect(
                relativeLuminance(bright) > relativeLuminance(normal),
                "ANSI \(index + 8) (bright) not brighter than ANSI \(index)"
            )
        }
    }

    @Test func backgroundIsDarkerThanEveryForeground() {
        // Basic.terminal uses pure black as the background; every other
        // slot should be strictly lighter, otherwise that color would be
        // invisible on the default profile.
        let bgL = relativeLuminance(TerminalPalette.basicBackground)
        for (index, entry) in TerminalPalette.macOSAligned.enumerated() {
            if index == 0 { continue } // ANSI 0 is black-on-black by convention
            #expect(
                relativeLuminance(entry) > bgL,
                "ANSI \(index) not lighter than Basic background"
            )
        }
    }

    @Test @MainActor func newTerminalTabDisablesUseBrightColors() {
        // Bold-as-bright doubles brightness and is turned off so Pine
        // matches Terminal.app / Ghostty (issue #733).
        let tab = TerminalTab(name: "test")
        #expect(tab.terminalView.useBrightColors == false)
    }
}
