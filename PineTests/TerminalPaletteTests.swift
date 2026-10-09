//
//  TerminalPaletteTests.swift
//  PineTests
//
//  Tests for `TerminalPalette` — Pine's One Dark-based ANSI 16-color palette
//  plus the non-ANSI background / foreground / cursor / selection colors for
//  the embedded SwiftTerm terminal (issues #765, #816, #1650).
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

    @Test func defaultPaletteIsExactlyOneDark() {
        // Since Pine's SwiftTerm fork keeps bright foreground indexes
        // addressable (#1650), no slot substitution is needed anymore:
        // the shipped default is One Dark for ALL 16 slots, and slot 0 is
        // One Dark's canonical black (#282C34) rather than the former
        // ghost-text grey substitute.
        #expect(TerminalPalette.macOSAligned == TerminalPalette.oneDark)
        #expect(
            TerminalPalette.macOSAligned[0]
            == TerminalPaletteEntry(red: 0x28, green: 0x2C, blue: 0x34),
            "slot 0 must be One Dark's true black"
        )
    }

    // MARK: - Reference values (Terminal.app Basic — exact RGB, kept for tests)

    @Test func terminalAppBasicReferenceIsPreserved() {
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
        let entries = TerminalPalette.terminalAppBasic
        #expect(entries.count == expected.count)
        for (index, exp) in expected.enumerated() {
            let entry = entries[index]
            #expect(entry.red == exp.0, "ANSI \(index) red mismatch")
            #expect(entry.green == exp.1, "ANSI \(index) green mismatch")
            #expect(entry.blue == exp.2, "ANSI \(index) blue mismatch")
        }
    }

    // MARK: - 8-bit -> 16-bit conversion

    @Test func entryConvertsToSwiftTermColorWith257Multiplier() {
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
        let blue = TerminalPaletteEntry(red: 0x00, green: 0x00, blue: 0xB2)
        let color = blue.makeSwiftTermColor()
        #expect(color.red == 0x0000)
        #expect(color.green == 0x0000)
        #expect(color.blue == 0xB2B2)
    }

    @Test func entryConvertsToNSColorInSRGB() {
        let entry = TerminalPaletteEntry(red: 0xBF, green: 0xBF, blue: 0xBF)
        let ns = entry.makeNSColor()
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

    @Test func swiftTermColorsAcceptsTerminalAppBasicReference() {
        #expect(TerminalPalette.swiftTermColors(from: TerminalPalette.terminalAppBasic)?.count == 16)
    }

    // MARK: - install(on:) integration

    @Test @MainActor func installDoesNotCrashOnFreshTerminalView() {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        TerminalPalette.install(on: view)
        _ = view.getTerminal()
    }

    @Test @MainActor func installDoesNotOverrideSemanticBackgroundForeground() {
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

    @Test @MainActor func feedingAnsi256GhostTextSequenceDoesNotCrashAfterInstall() {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        TerminalPalette.install(on: view)
        let terminal = view.getTerminal()
        terminal.feed(text: "\u{1B}[38;5;8mghost\u{1B}[0m")
        terminal.feed(text: "\u{1B}[90mghost\u{1B}[0m")
    }

    @Test @MainActor func newTerminalTabInstallsPaletteWithoutCrashing() {
        let tab = TerminalTab(name: "palette-test")
        _ = tab.terminalView.getTerminal()
    }

    // MARK: - Readability vs. dark-mode background

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
        // One Dark slot 7 (#ABB2BF)
        let ratio = contrastRatio(
            TerminalPalette.macOSAligned[7],
            TerminalPalette.darkModeBackgroundReference
        )
        #expect(ratio >= 5.0, "white contrast \(ratio) below 5:1")
    }

    @Test func brightWhiteIsReadableAgainstDarkBackground() {
        let ratio = contrastRatio(
            TerminalPalette.macOSAligned[15],
            TerminalPalette.darkModeBackgroundReference
        )
        #expect(ratio >= 7.0)
    }

    /// Ghost text (zsh-autosuggestions `fg=8`) reads the real bright-black
    /// slot 8 now that Pine's SwiftTerm fork no longer collapses bright
    /// foreground indexes onto the base palette (#1650). Slot 8 must stay
    /// readable against the dark-mode background.
    @Test func slot8HasReadableGhostTextContrast() {
        let slot8 = TerminalPalette.macOSAligned[8]
        let ratio = contrastRatio(slot8, TerminalPalette.darkModeBackgroundReference)
        // Ghost text is intentionally dim — 2.0:1 is sufficient for
        // non-essential hint text on One Dark background (#282C34).
        #expect(ratio >= 2.0, "slot 8 (ghost text) contrast \(ratio) below 2.0:1")
    }

    @Test func slot8IsDimmerThanRegularForeground() {
        #expect(
            relativeLuminance(TerminalPalette.macOSAligned[8])
            < relativeLuminance(TerminalPalette.macOSAligned[7])
        )
    }

    @Test func backgroundIsDarkerThanEveryForeground() {
        let bgL = relativeLuminance(TerminalPalette.darkModeBackgroundReference)
        for (index, entry) in TerminalPalette.macOSAligned.enumerated() {
            // Slot 0 IS One Dark's canonical black, which equals the One Dark
            // background (#282C34): slot-0 text on the default background is
            // invisible by design, as in every One Dark terminal. p10k-style
            // black text sits on bright backgrounds, where it reads correctly.
            if index == 0 {
                #expect(entry == TerminalPalette.darkModeBackgroundReference)
                continue
            }
            #expect(
                relativeLuminance(entry) > bgL,
                "ANSI \(index) not lighter than dark-mode background"
            )
        }
    }

    /// One Dark colors all have good contrast against dark backgrounds.
    /// Every slot in macOSAligned must clear 3:1, except slot 0 (which equals
    /// the background by design) and slot 8 (dim ghost text).
    @Test func allAnsiSlotsClearThreeToOneAgainstDarkBackground() {
        let bg = TerminalPalette.darkModeBackgroundReference
        for index in 0..<16 {
            let entry = TerminalPalette.macOSAligned[index]
            let ratio = contrastRatio(entry, bg)
            // Slot 0 is the canonical One Dark black — identical to the
            // background. Slot 8 carries ghost text / comment colors
            // (#5C6370) — lower threshold acceptable for non-essential dim
            // text on One Dark background (#282C34). All other slots must
            // clear 3:1.
            if index == 0 { continue }
            let threshold: Double = index == 8 ? 2.0 : 3.0
            #expect(ratio >= threshold, "ANSI \(index) contrast \(ratio) below \(threshold):1")
        }
    }

    @Test @MainActor func newTerminalTabDisablesUseBrightColors() {
        let tab = TerminalTab(name: "test")
        #expect(tab.terminalView.useBrightColors == false)
    }

    /// Pine's SwiftTerm fork decouples the bright-index collapse from
    /// `useBrightColors` (#1650). Every terminal tab must opt out of the
    /// collapse so slots 8-15 stay addressable for foreground text.
    @Test @MainActor func newTerminalTabDisablesBrightColorCollapse() {
        let tab = TerminalTab(name: "test")
        #expect(tab.terminalView.useBrightColors == false)
        #expect(tab.terminalView.collapseBrightColorsToBase == false)
    }

    // MARK: - Light palette shape

    @Test func lightPaletteHasExactly16Entries() {
        #expect(TerminalPalette.lightPalette.count == TerminalPalette.colorCount)
    }

    @Test func lightPaletteIsNonEmpty() {
        #expect(!TerminalPalette.lightPalette.isEmpty)
    }

    @Test func lightPaletteSlot0IsCatppuccinLatteBlack() {
        // Slot 0 is Catppuccin Latte's canonical terminal black (Subtext 1,
        // #5C5F77) — no ghost-text substitution anymore (#1650).
        #expect(
            TerminalPalette.lightPalette[0]
            == TerminalPaletteEntry(red: 0x5C, green: 0x5F, blue: 0x77)
        )
        // Ghost text reads the real bright-black slot 8 (Subtext 0, #6C6F85),
        // which must stay brighter than slot 0.
        #expect(
            TerminalPalette.lightPalette[8]
            == TerminalPaletteEntry(red: 0x6C, green: 0x6F, blue: 0x85)
        )
        #expect(
            relativeLuminance(TerminalPalette.lightPalette[8])
            > relativeLuminance(TerminalPalette.lightPalette[0])
        )
    }

    // MARK: - Light palette reference values

    @Test func lightPalettePineReferenceIsPreserved() {
        let expected: [(UInt8, UInt8, UInt8)] = [
            (0x5C, 0x5F, 0x77), // 0  black (Catppuccin Latte Subtext 1)
            (0xD2, 0x0F, 0x39), // 1  red
            (0x3F, 0x9E, 0x2B), // 2  green (contrast adjusted)
            (0xC0, 0x7A, 0x19), // 3  yellow (contrast adjusted)
            (0x1E, 0x66, 0xF5), // 4  blue
            (0xCC, 0x67, 0xB1), // 5  magenta (contrast adjusted)
            (0x17, 0x92, 0x99), // 6  cyan
            (0x7C, 0x7F, 0x89), // 7  white (contrast adjusted)
            (0x6C, 0x6F, 0x85), // 8  bright black
            (0xD2, 0x0F, 0x39), // 9  bright red
            (0x3F, 0x9E, 0x2B), // 10 bright green (contrast adjusted)
            (0xC0, 0x7A, 0x19), // 11 bright yellow (contrast adjusted)
            (0x1E, 0x66, 0xF5), // 12 bright blue
            (0xCC, 0x67, 0xB1), // 13 bright magenta (contrast adjusted)
            (0x17, 0x92, 0x99), // 14 bright cyan
            (0x87, 0x8A, 0x93), // 15 bright white (contrast adjusted)
        ]
        let entries = TerminalPalette.lightPalette
        #expect(entries.count == expected.count)
        for (index, exp) in expected.enumerated() {
            let entry = entries[index]
            #expect(entry.red == exp.0, "Light ANSI \(index) red mismatch")
            #expect(entry.green == exp.1, "Light ANSI \(index) green mismatch")
            #expect(entry.blue == exp.2, "Light ANSI \(index) blue mismatch")
        }
    }

    @Test func lightPalettePreservesNormalBrightRelationships() {
        let pairedSlots = [(1, 9), (2, 10), (3, 11), (4, 12), (5, 13), (6, 14)]
        for (normal, bright) in pairedSlots {
            #expect(
                TerminalPalette.lightPalette[normal] == TerminalPalette.lightPalette[bright],
                "Light ANSI slots \(normal) and \(bright) must remain paired"
            )
        }

        #expect(
            relativeLuminance(TerminalPalette.lightPalette[15])
            > relativeLuminance(TerminalPalette.lightPalette[7]),
            "Light ANSI bright white must remain brighter than white"
        )
    }

    // MARK: - Light palette readability

    @Test func lightPaletteAllColorsAreDarkerThanBackground() {
        let bgL = relativeLuminance(TerminalPalette.lightModeBackgroundReference)
        for (index, entry) in TerminalPalette.lightPalette.enumerated() {
            #expect(
                relativeLuminance(entry) < bgL,
                "Light ANSI \(index) not darker than light-mode background"
            )
        }
    }

    @Test func lightPaletteAllSlotsHaveContrastAgainstLightBackground() {
        let bg = TerminalPalette.lightModeBackgroundReference
        for index in 0..<16 {
            let entry = TerminalPalette.lightPalette[index]
            let ratio = contrastRatio(entry, bg)
            // Slot 8 carries dim ghost text (#6C6F85) — 2.0:1 is enough for
            // non-essential hint text; every other slot must clear 3:1.
            let threshold: Double = index == 8 ? 2.0 : 3.0
            #expect(
                ratio >= threshold,
                "Light ANSI \(index) contrast \(ratio) below \(threshold):1"
            )
        }
    }

    // MARK: - swiftTermColors() accepts light palette

    @Test func swiftTermColorsAcceptsLightPalette() {
        #expect(TerminalPalette.swiftTermColors(from: TerminalPalette.lightPalette)?.count == 16)
    }

    // MARK: - install(palette:on:) integration

    @Test @MainActor func installWithExplicitLightPaletteDoesNotCrash() {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        TerminalPalette.install(palette: TerminalPalette.lightPalette, on: view)
        _ = view.getTerminal()
    }

    @Test @MainActor func installWithExplicitDarkPaletteDoesNotCrash() {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        TerminalPalette.install(palette: TerminalPalette.macOSAligned, on: view)
        _ = view.getTerminal()
    }

    @Test @MainActor func installWithNilPaletteFallsBackToCurrentAppearance() {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        TerminalPalette.install(palette: nil, on: view)
        _ = view.getTerminal()
    }

    // MARK: - currentPalette / currentBackgroundColor

    @Test @MainActor func currentPaletteReturnsSixteenEntries() {
        let palette = TerminalPalette.currentPalette()
        #expect(palette.count == TerminalPalette.colorCount)
    }

    @Test @MainActor func currentBackgroundColorReturnsOpaqueColor() {
        let color = TerminalPalette.currentBackgroundColor()
        #expect(color.alphaComponent == 1.0)
    }

    @Test @MainActor func currentBackgroundColorMatchesAppearance() {
        let darkBg = TerminalPalette.darkModeBackgroundReference.makeNSColor()
        let lightBg = TerminalPalette.lightModeBackgroundReference.makeNSColor()
        let current = TerminalPalette.currentBackgroundColor()
        if TerminalPalette.isDarkMode {
            #expect(current == darkBg)
        } else {
            #expect(current == lightBg)
        }
    }

    @Test @MainActor func darkAndLightBackgroundsAreDifferentColors() {
        let dark = TerminalPalette.darkModeBackgroundReference.makeNSColor()
        let light = TerminalPalette.lightModeBackgroundReference.makeNSColor()
        #expect(dark != light)
    }

    @Test @MainActor func currentPaletteMatchesAppearance() {
        let palette = TerminalPalette.currentPalette()
        if TerminalPalette.isDarkMode {
            #expect(palette == TerminalPalette.macOSAligned)
        } else {
            #expect(palette == TerminalPalette.lightPalette)
        }
    }

    // MARK: - Bright foreground resolution (issue #1650)

    /// A terminal view configured the way `TerminalTab` configures it, with
    /// the given palette installed, for direct color-resolution assertions.
    @MainActor
    private func makeResolvedPaletteView(
        palette: [TerminalPaletteEntry] = TerminalPalette.macOSAligned
    ) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        view.useBrightColors = false
        view.collapseBrightColorsToBase = false
        TerminalPalette.install(palette: palette, on: view)
        return view
    }

    /// Compares a resolved `NSColor` against a palette entry (sRGB, tolerant).
    private func expectColor(
        _ actual: NSColor,
        matches entry: TerminalPaletteEntry,
        _ comment: Comment
    ) {
        let srgb = actual.usingColorSpace(.sRGB) ?? actual
        #expect(abs(srgb.redComponent - CGFloat(entry.red) / 255.0) < 0.001, comment)
        #expect(abs(srgb.greenComponent - CGFloat(entry.green) / 255.0) < 0.001, comment)
        #expect(abs(srgb.blueComponent - CGFloat(entry.blue) / 255.0) < 0.001, comment)
    }

    @Test @MainActor func brightForegroundIndexesResolveToTheirOwnSlots() {
        let view = makeResolvedPaletteView()
        // Covers both SGR forms: \e[38;5;8m..\e[38;5;15m and \e[90m..\e[97m
        // all arrive here as ansi256 codes 8-15.
        for code: UInt8 in 8...15 {
            let resolved = view.mapColor(
                color: .ansi256(code: code), isFg: true, isBold: false, useBrightColors: false
            )
            expectColor(
                resolved,
                matches: TerminalPalette.macOSAligned[Int(code)],
                "ansi \(code) must resolve to palette slot \(code), not \(code - 8)"
            )
        }
    }

    @Test @MainActor func boldTextKeepsItsBaseColor() {
        let view = makeResolvedPaletteView()
        // #733 preserved: bold must neither promote to bright nor collapse.
        let resolved = view.mapColor(
            color: .ansi256(code: 1), isFg: true, isBold: true, useBrightColors: false
        )
        expectColor(resolved, matches: TerminalPalette.macOSAligned[1], "bold red must stay slot 1")
        let brightBold = view.mapColor(
            color: .ansi256(code: 9), isFg: true, isBold: true, useBrightColors: false
        )
        expectColor(brightBold, matches: TerminalPalette.macOSAligned[9], "bold bright red must stay slot 9")
    }

    @Test @MainActor func slot0ForegroundIsTrueBlack() {
        let view = makeResolvedPaletteView()
        let resolved = view.mapColor(
            color: .ansi256(code: 0), isFg: true, isBold: false, useBrightColors: false
        )
        // p10k-style segment text on bright backgrounds must be One Dark's
        // canonical black (#282C34), not the former grey substitute.
        expectColor(
            resolved,
            matches: TerminalPaletteEntry(red: 0x28, green: 0x2C, blue: 0x34),
            "slot 0 must be One Dark's true black"
        )
    }

    @Test @MainActor func ghostTextResolvesToSlot8() {
        let view = makeResolvedPaletteView()
        let resolved = view.mapColor(
            color: .ansi256(code: 8), isFg: true, isBold: false, useBrightColors: false
        )
        // zsh-autosuggestions sends fg=8; it must read the real bright-black
        // slot (#5C6370) rather than collapsing onto slot 0.
        expectColor(
            resolved,
            matches: TerminalPaletteEntry(red: 0x5C, green: 0x63, blue: 0x70),
            "ghost text must resolve to slot 8"
        )
    }

    @Test @MainActor func extendedRangeIndexesAreNotShifted() {
        let view = makeResolvedPaletteView()
        // The upstream collapse shifted EVERY index above 7 down by 8,
        // corrupting the 6x6x6 cube and grayscale ramp too. The default
        // (`useBrightColors = true`) mapping is the identity for indexes
        // above 7, so resolving through it yields the true slot-200 color.
        let resolved = view.mapColor(
            color: .ansi256(code: 200), isFg: true, isBold: false, useBrightColors: false
        )
        let identity = view.mapColor(color: .ansi256(code: 200), isFg: true, isBold: false)
        #expect(resolved == identity, "ansi 200 must resolve to slot 200, not 192")

        let legacy = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        legacy.useBrightColors = false
        let collapsed = legacy.mapColor(
            color: .ansi256(code: 200), isFg: true, isBold: false, useBrightColors: false
        )
        #expect(collapsed != resolved, "legacy mode must still shift ansi 200 down to slot 192")
    }

    @Test @MainActor func brightBackgroundsResolveToTheirOwnSlots() {
        let view = makeResolvedPaletteView()
        // Backgrounds always map with bright colors enabled; this must hold
        // regardless of the foreground configuration.
        let resolved = view.mapColor(color: .ansi256(code: 11), isFg: false, isBold: false)
        expectColor(resolved, matches: TerminalPalette.macOSAligned[11], "bright yellow background")
    }

    @Test @MainActor func legacyCollapseRemainsTheUpstreamDefault() {
        // Backward compatibility: a view Pine did not opt in must keep the
        // historical collapse behavior.
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        #expect(view.collapseBrightColorsToBase == true)
        TerminalPalette.install(palette: TerminalPalette.macOSAligned, on: view)
        let resolved = view.mapColor(
            color: .ansi256(code: 9), isFg: true, isBold: false, useBrightColors: false
        )
        expectColor(
            resolved,
            matches: TerminalPalette.macOSAligned[1],
            "legacy mode must collapse ansi 9 onto slot 1"
        )
    }

    @Test @MainActor func sgrBrightFormsParseToAnsi256Codes8Through15() {
        let view = makeResolvedPaletteView()
        let terminal = view.getTerminal()
        // SGR 90-97 and the 256-color form must land on the same codes 8-15
        // that `mapColor` resolves above.
        terminal.feed(text: "\u{1B}[90mA")
        terminal.feed(text: "\u{1B}[0m\u{1B}[38;5;8mB")
        terminal.feed(text: "\u{1B}[0m\u{1B}[97mC")
        terminal.feed(text: "\u{1B}[0m\u{1B}[38;5;15mD")
        let line = 0
        #expect(terminal.getCharData(col: 0, row: line)?.attribute.fg == .ansi256(code: 8), "SGR 90 must parse to ansi256 8")
        #expect(terminal.getCharData(col: 1, row: line)?.attribute.fg == .ansi256(code: 8), "38;5;8 must parse to ansi256 8")
        #expect(terminal.getCharData(col: 2, row: line)?.attribute.fg == .ansi256(code: 15), "SGR 97 must parse to ansi256 15")
        #expect(terminal.getCharData(col: 3, row: line)?.attribute.fg == .ansi256(code: 15), "38;5;15 must parse to ansi256 15")
    }
}
