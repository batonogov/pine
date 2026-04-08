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

    @Test func defaultPaletteEqualsBasicExceptForBrightBlackOverride() {
        // The shipped default is Terminal.app Basic for every slot EXCEPT
        // slot 8 (bright black), which is overridden with Tomorrow Night
        // `#969896` to keep zsh-autosuggestions / fish ghost text readable
        // on the dark-mode background. This is the deliberate compromise
        // between #765 (TUI parity) and #733 (ghost text contrast).
        #expect(TerminalPalette.macOSAligned != TerminalPalette.terminalAppBasic)
        #expect(TerminalPalette.macOSAligned[8] == TerminalPalette.ghostTextBrightBlack)
        for index in 0..<TerminalPalette.colorCount where index != 8 {
            #expect(
                TerminalPalette.macOSAligned[index] == TerminalPalette.terminalAppBasic[index],
                "slot \(index) drifted from Terminal.app Basic"
            )
        }
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
        // Tested against the unmodified `terminalAppBasic` reference array
        // — `macOSAligned` overrides slot 8 (see
        // `defaultPaletteEqualsBasicExceptForBrightBlackOverride`).
        let entries = TerminalPalette.terminalAppBasic
        #expect(entries.count == expected.count)
        for (index, exp) in expected.enumerated() {
            let entry = entries[index]
            #expect(entry.red == exp.0, "ANSI \(index) red mismatch")
            #expect(entry.green == exp.1, "ANSI \(index) green mismatch")
            #expect(entry.blue == exp.2, "ANSI \(index) blue mismatch")
        }
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

    @Test @MainActor func installDoesNotOverrideSemanticBackgroundForeground() {
        // Light/dark adaptive bg/fg are managed by `TerminalSession` via
        // `NSColor.textBackgroundColor` / `NSColor.textColor`. The palette
        // installer must NOT touch those slots — otherwise users in light
        // mode get a black terminal in the middle of a light UI (Apple HIG
        // violation). This test pins that contract.
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        let bgBefore = view.nativeBackgroundColor
        let fgBefore = view.nativeForegroundColor
        let caretBefore = view.caretColor
        let selectionBefore = view.selectedTextBackgroundColor

        TerminalPalette.install(on: view)

        #expect(view.nativeBackgroundColor === bgBefore || view.nativeBackgroundColor == bgBefore)
        #expect(view.nativeForegroundColor === fgBefore || view.nativeForegroundColor == fgBefore)
        #expect(view.caretColor === caretBefore || view.caretColor == caretBefore)
        #expect(
            view.selectedTextBackgroundColor === selectionBefore
            || view.selectedTextBackgroundColor == selectionBefore
        )
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

    // MARK: - Readability vs. dark-mode background
    //
    // These assertions pin the contrast characteristics users rely on every
    // day. The reference background is `darkModeBackgroundReference`
    // (`#1E1E1E`), the worst case approximation of
    // `NSColor.textBackgroundColor` in dark mode.
    //
    // Slot 8 (bright black) is held to WCAG AA (≥4.5:1) because that is the
    // ghost-text affordance regression #733 fixed. Other colored slots are
    // only required to clear 3:1 — Terminal.app Basic's deep red (#990000)
    // and deep blue (#0000B2) cannot clear AA against any dark background
    // and forcing them higher would move Pine back off-profile (#765).

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

    @Test func whiteIsReadableAgainstDarkBackground() {
        // ANSI 7 (#BFBFBF) — the default prompt foreground. Must clear
        // WCAG AAA (7:1) so shells remain comfortable for long sessions.
        let ratio = contrastRatio(
            TerminalPalette.macOSAligned[7],
            TerminalPalette.darkModeBackgroundReference
        )
        #expect(ratio >= 7.0, "white contrast \(ratio) below WCAG AAA")
    }

    @Test func brightWhiteIsReadableAgainstDarkBackground() {
        let ratio = contrastRatio(
            TerminalPalette.macOSAligned[15],
            TerminalPalette.darkModeBackgroundReference
        )
        #expect(ratio >= 7.0)
    }

    /// Restored regression test from #733. Bright black is the ghost-text
    /// color used by zsh-autosuggestions / fish; the previous #666666 hit
    /// only ~2.9 against `#1E1E1E` and was effectively invisible. Pine's
    /// override (#969896) clears WCAG AA.
    @Test func brightBlackHasReadableContrastAgainstDarkBackground() {
        let brightBlack = TerminalPalette.macOSAligned[8]
        let ratio = contrastRatio(brightBlack, TerminalPalette.darkModeBackgroundReference)
        #expect(ratio >= 4.5, "bright black contrast \(ratio) below WCAG AA")
    }

    /// Restored regression test from #733. Direct comparison against the
    /// previous unreadable baseline `#666666` to make absolutely sure
    /// nobody re-introduces it without the override.
    @Test func brightBlackContrastBeatsRegressionBaseline() {
        let brightBlack = TerminalPalette.macOSAligned[8]
        let ratio = contrastRatio(brightBlack, TerminalPalette.darkModeBackgroundReference)
        let regression = contrastRatio(
            TerminalPaletteEntry(red: 0x66, green: 0x66, blue: 0x66),
            TerminalPalette.darkModeBackgroundReference
        )
        #expect(ratio > regression + 1.0)
    }

    /// Restored regression test from #733, scoped to the slots Pine
    /// controls. Slots 1 (red #990000), 4 (blue #0000B2), 5 (magenta
    /// #B200B2) and 12 (bright blue #0000FF) are intrinsic to Terminal.app
    /// Basic and genuinely cannot clear 3:1 against `#1E1E1E` — matching
    /// Terminal.app exactly is the whole point of #765 and forcing them
    /// brighter would move Pine off-profile. Their bright variants
    /// (9 bright red, 13 bright magenta) DO clear the threshold and are
    /// what shells normally use for prompt accents.
    @Test func allReadableAnsiSlotsClearThreeToOneAgainstDarkBackground() {
        let bg = TerminalPalette.darkModeBackgroundReference
        // Deep-saturation Basic slots intentionally excluded — see comment.
        let coloredIndices: [Int] = [2, 3, 6, 7, 9, 10, 11, 13, 14, 15]
        for index in coloredIndices {
            let entry = TerminalPalette.macOSAligned[index]
            let ratio = contrastRatio(entry, bg)
            #expect(ratio >= 3.0, "ANSI \(index) contrast \(ratio) below 3:1")
        }
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
        // Every non-black slot must be strictly lighter than the dark-mode
        // reference background, otherwise that color would be invisible
        // for users on the default appearance.
        let bgL = relativeLuminance(TerminalPalette.darkModeBackgroundReference)
        for (index, entry) in TerminalPalette.macOSAligned.enumerated() {
            if index == 0 { continue } // ANSI 0 is black-on-black by convention
            #expect(
                relativeLuminance(entry) > bgL,
                "ANSI \(index) not lighter than dark-mode background"
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
