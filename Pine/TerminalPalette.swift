//
//  TerminalPalette.swift
//  Pine
//
//  Centralised ANSI 16-color palette for Pine's embedded SwiftTerm terminal.
//
//  Pine uses appearance-aware ANSI palettes for the 16 ANSI slots that TUI
//  apps such as k9s, htop, lazygit, btop and vim drive directly via
//  `\e[3xm` / `tput setaf`. One Dark is used in dark mode; a
//  contrast-adjusted Catppuccin Latte palette is used in light mode. Both
//  provide excellent readability on their respective backgrounds.
//
//  Scope of `install(on:)`:
//  ONLY the 16 ANSI palette slots are touched here. Background / foreground
//  / cursor / selection are deliberately NOT set — `TerminalSession` owns
//  the default terminal colors and reapplies them when the system appearance
//  changes. TUI apps paint their own background through ANSI sequences anyway.
//
//  Coverage across SGR forms:
//
//    * Basic SGR \e[30m..\e[37m and \e[90m..\e[97m, plus the 256-color
//      form \e[38;5;Nm for N in 0...15 — both go through the SAME code
//      path in `Apple/AppleTerminalView.swift` (`case .ansi256(let ansi):`
//      in `mapColor`). There is no separate handler for the basic 16;
//      SGR 90-97 are parsed into `ansi256` codes 8-15 (`Terminal.swift`,
//      `case 90...97`).
//
//      Pine sets `useBrightColors = false` in `TerminalSession.swift` so
//      that bold text does NOT auto-promote to bright (issue #733 / Ghostty
//      parity). Upstream SwiftTerm 1.19.0 coupled a second behavior to that
//      flag: with `useBrightColors = false`, `mapColor` folded EVERY ANSI
//      index above 7 onto `index - 8` before looking up
//      `terminal.ansiColors[midx]`, which made slots 8-15 unreachable for
//      foreground text and shifted the whole 16-255 extended range down
//      by 8 (issue #1650).
//
//      Pine ships a SwiftTerm fork (batonogov/SwiftTerm, pinned to an
//      exact `1.19.0-pine.*` tag) that decouples the two behaviors via
//      `collapseBrightColorsToBase`. Pine sets it to `false`, so `\e[38;5;8m`
//      (which is what zsh-autosuggestions / fish use for ghost text via
//      `fg=8`) now reads the real slot 8, and bright themes (Dracula,
//      GitHub, Digital Rain) render their distinct bright variants. Bold
//      text still keeps its base color (#733 preserved).
//
//    * True color \e[38;2;R;G;Bm — not affected by palettes, passes
//      through unchanged (by design).
//

import Foundation
import SwiftTerm

/// 8-bit RGB triple used to describe a single ANSI palette entry in
/// human-readable form. Converted to SwiftTerm's 16-bit `Color` at install
/// time. Public for unit-testing.
struct TerminalPaletteEntry: Equatable, Hashable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    /// Promotes 8-bit components to SwiftTerm's 16-bit color space using the
    /// standard `x 257` formula (so 0xFF -> 0xFFFF, preserving full intensity).
    func makeSwiftTermColor() -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(red) * 257,
            green: UInt16(green) * 257,
            blue: UInt16(blue) * 257
        )
    }

    /// Produces an `NSColor` in the sRGB color space. Used for the non-ANSI
    /// slots (background / foreground / cursor / selection) that SwiftTerm
    /// exposes as `NSColor` rather than `SwiftTerm.Color`.
    func makeNSColor(alpha: CGFloat = 1.0) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: alpha
        )
    }
}

#if canImport(AppKit)
import AppKit
#endif

/// Pine's ANSI 16-color palette plus the non-ANSI background / foreground /
/// cursor / selection colors required to match a terminal profile end-to-end.
///
/// ANSI slot order matches the SGR / xterm convention:
/// `[black, red, green, yellow, blue, magenta, cyan, white,`
/// ` brightBlack, brightRed, brightGreen, brightYellow,`
/// ` brightBlue, brightMagenta, brightCyan, brightWhite]`.
///
/// The palette is a value type so tests can compare it without instantiating
/// SwiftTerm views. The actual install into a `LocalProcessTerminalView`
/// happens via `install(on:)`.
enum TerminalPalette {

    /// Number of ANSI colors expected by SwiftTerm's `installColors`.
    static let colorCount = 16

    // MARK: - Terminal.app "Basic" (reference for tests)

    /// Exact sRGB values from `Basic.terminal` shipped with macOS — kept
    /// bit-for-bit so the unit tests can pin against the canonical profile.
    static let terminalAppBasic: [TerminalPaletteEntry] = [
        .init(red: 0x00, green: 0x00, blue: 0x00), // 0  black
        .init(red: 0x99, green: 0x00, blue: 0x00), // 1  red
        .init(red: 0x00, green: 0xA6, blue: 0x00), // 2  green
        .init(red: 0x99, green: 0x99, blue: 0x00), // 3  yellow
        .init(red: 0x00, green: 0x00, blue: 0xB2), // 4  blue
        .init(red: 0xB2, green: 0x00, blue: 0xB2), // 5  magenta
        .init(red: 0x00, green: 0xA6, blue: 0xB2), // 6  cyan
        .init(red: 0xBF, green: 0xBF, blue: 0xBF), // 7  white
        .init(red: 0x66, green: 0x66, blue: 0x66), // 8  bright black
        .init(red: 0xE5, green: 0x00, blue: 0x00), // 9  bright red
        .init(red: 0x00, green: 0xD9, blue: 0x00), // 10 bright green
        .init(red: 0xE5, green: 0xE5, blue: 0x00), // 11 bright yellow
        .init(red: 0x00, green: 0x00, blue: 0xFF), // 12 bright blue
        .init(red: 0xE5, green: 0x00, blue: 0xE5), // 13 bright magenta
        .init(red: 0x00, green: 0xE5, blue: 0xE5), // 14 bright cyan
        .init(red: 0xE5, green: 0xE5, blue: 0xE5), // 15 bright white
    ]

    // MARK: - One Dark palette

    /// One Dark (Atom editor) palette — the palette Pine installs.
    /// Note: bright colors (slots 9-14) intentionally equal their normal
    /// counterparts — this is canonical for One Dark, not a copy-paste error.
    static let oneDark: [TerminalPaletteEntry] = [
        .init(red: 0x28, green: 0x2C, blue: 0x34), // 0  black
        .init(red: 0xE0, green: 0x6C, blue: 0x75), // 1  red
        .init(red: 0x98, green: 0xC3, blue: 0x79), // 2  green
        .init(red: 0xE5, green: 0xC0, blue: 0x7B), // 3  yellow
        .init(red: 0x61, green: 0xAF, blue: 0xEF), // 4  blue
        .init(red: 0xC6, green: 0x78, blue: 0xDD), // 5  magenta
        .init(red: 0x56, green: 0xB6, blue: 0xC2), // 6  cyan
        .init(red: 0xAB, green: 0xB2, blue: 0xBF), // 7  white
        .init(red: 0x5C, green: 0x63, blue: 0x70), // 8  bright black
        .init(red: 0xE0, green: 0x6C, blue: 0x75), // 9  bright red
        .init(red: 0x98, green: 0xC3, blue: 0x79), // 10 bright green
        .init(red: 0xE5, green: 0xC0, blue: 0x7B), // 11 bright yellow
        .init(red: 0x61, green: 0xAF, blue: 0xEF), // 12 bright blue
        .init(red: 0xC6, green: 0x78, blue: 0xDD), // 13 bright magenta
        .init(red: 0x56, green: 0xB6, blue: 0xC2), // 14 bright cyan
        .init(red: 0xFF, green: 0xFF, blue: 0xFF), // 15 bright white
    ]

    /// Reference background used by the contrast assertions for the
    /// dark-mode `NSColor.textBackgroundColor` worst case. Hard-coded so
    /// the test target does not depend on host appearance.
    /// One Dark canonical background (#282C34) — matches the hardcoded
    /// background in `TerminalSession.swift`.
    static let darkModeBackgroundReference = TerminalPaletteEntry(red: 0x28, green: 0x2C, blue: 0x34)

    /// Default palette Pine actually installs in dark mode.
    ///
    /// Exactly One Dark, with NO slot substitutions: slot 0 is One Dark's
    /// canonical black (#282C34), so text sent as ANSI 0 (e.g. p10k segment
    /// text on bright backgrounds) renders as the theme's true black rather
    /// than a grey substitute. zsh-autosuggestions ghost text reads the real
    /// bright-black slot 8 (#5C6370) now that Pine's SwiftTerm fork no longer
    /// collapses bright foreground indexes onto the base palette (issue
    /// #1650 — see the file header).
    static let macOSAligned: [TerminalPaletteEntry] = oneDark

    // MARK: - Light palette (Catppuccin Latte base)

    /// Catppuccin Latte palette. Bright colors (slots 9-14) intentionally
    /// equal their normal counterparts — canonical for Catppuccin Latte,
    /// not a copy-paste error. Slot 0 is Latte's canonical terminal black
    /// (Subtext 1, #5C5F77); zsh-autosuggestions ghost text reads the real
    /// bright-black slot 8 now that the SwiftTerm fork keeps bright
    /// foreground indexes addressable (issue #1650).
    private static let catppuccinLatte: [TerminalPaletteEntry] = [
        .init(red: 0x5C, green: 0x5F, blue: 0x77), // 0  black (Subtext 1)
        .init(red: 0xD2, green: 0x0F, blue: 0x39), // 1  red
        .init(red: 0x40, green: 0xA0, blue: 0x2B), // 2  green
        .init(red: 0xDF, green: 0x8E, blue: 0x1D), // 3  yellow
        .init(red: 0x1E, green: 0x66, blue: 0xF5), // 4  blue
        .init(red: 0xEA, green: 0x76, blue: 0xCB), // 5  magenta
        .init(red: 0x17, green: 0x92, blue: 0x99), // 6  cyan
        .init(red: 0xAC, green: 0xB0, blue: 0xBE), // 7  white
        .init(red: 0x6C, green: 0x6F, blue: 0x85), // 8  bright black
        .init(red: 0xD2, green: 0x0F, blue: 0x39), // 9  bright red
        .init(red: 0x40, green: 0xA0, blue: 0x2B), // 10 bright green
        .init(red: 0xDF, green: 0x8E, blue: 0x1D), // 11 bright yellow
        .init(red: 0x1E, green: 0x66, blue: 0xF5), // 12 bright blue
        .init(red: 0xEA, green: 0x76, blue: 0xCB), // 13 bright magenta
        .init(red: 0x17, green: 0x92, blue: 0x99), // 14 bright cyan
        .init(red: 0xBC, green: 0xC0, blue: 0xCC), // 15 bright white
    ]

    /// Pine-specific light-palette adjustments for ANSI colors that do not
    /// reach 3:1 against Catppuccin Latte Base (#EFF1F5). Each color is a
    /// proportional sRGB darkening of its upstream value, preserving hue.
    /// Normal/bright chromatic pairs continue to share one value, while both
    /// neutral whites use the same 72% scale so bright white stays brighter.
    ///
    /// These are intentional deviations from upstream Catppuccin Latte:
    /// - green: #40A02B -> #3F9E2B (99%)
    /// - yellow: #DF8E1D -> #C07A19 (86%)
    /// - magenta: #EA76CB -> #CC67B1 (87%)
    /// - white: #ACB0BE -> #7C7F89 (72%)
    /// - bright white: #BCC0CC -> #878A93 (72%)
    private static let lightContrastGreen = TerminalPaletteEntry(red: 0x3F, green: 0x9E, blue: 0x2B)
    private static let lightContrastYellow = TerminalPaletteEntry(red: 0xC0, green: 0x7A, blue: 0x19)
    private static let lightContrastMagenta = TerminalPaletteEntry(red: 0xCC, green: 0x67, blue: 0xB1)
    private static let lightContrastWhite = TerminalPaletteEntry(red: 0x7C, green: 0x7F, blue: 0x89)
    private static let lightContrastBrightWhite = TerminalPaletteEntry(red: 0x87, green: 0x8A, blue: 0x93)

    /// Light-mode ANSI palette with contrast overrides applied.
    static let lightPalette: [TerminalPaletteEntry] = {
        var entries = catppuccinLatte
        entries[2] = lightContrastGreen
        entries[3] = lightContrastYellow
        entries[5] = lightContrastMagenta
        entries[7] = lightContrastWhite
        entries[10] = lightContrastGreen
        entries[11] = lightContrastYellow
        entries[13] = lightContrastMagenta
        entries[15] = lightContrastBrightWhite
        return entries
    }()

    /// Light-mode reference background (#EFF1F5 — Catppuccin Latte base).
    static let lightModeBackgroundReference = TerminalPaletteEntry(red: 0xEF, green: 0xF1, blue: 0xF5)

    // MARK: - Appearance detection

    /// Whether the system is currently in dark mode.
    static var isDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Returns the ANSI palette matching the current system appearance.
    static func currentPalette() -> [TerminalPaletteEntry] {
        isDarkMode ? macOSAligned : lightPalette
    }

    /// Returns the terminal background color matching the current system appearance.
    static func currentBackgroundColor() -> NSColor {
        isDarkMode
            ? darkModeBackgroundReference.makeNSColor()
            : lightModeBackgroundReference.makeNSColor()
    }

    // MARK: - Build / install helpers

    /// Builds the SwiftTerm `Color` array for `installColors`.
    /// Returns `nil` if the entry list does not contain exactly 16 entries —
    /// the caller should then leave SwiftTerm on its built-in default rather
    /// than installing a malformed palette.
    static func swiftTermColors(
        from entries: [TerminalPaletteEntry] = macOSAligned
    ) -> [SwiftTerm.Color]? {
        guard entries.count == colorCount else { return nil }
        return entries.map { $0.makeSwiftTermColor() }
    }

    /// Installs an ANSI 16-color palette on a `LocalProcessTerminalView`.
    ///
    /// Scope is intentionally limited to the 16 ANSI slots. Background,
    /// foreground, cursor and selection are managed by `TerminalSession`
    /// via semantic `NSColor` values so the terminal remains light/dark
    /// adaptive (Apple HIG).
    ///
    /// Wrapped in a `guard` so that an unexpected SwiftTerm API change (the
    /// palette failing to build) leaves the terminal usable on whatever
    /// SwiftTerm provides by default.
    @MainActor
    static func install(
        palette: [TerminalPaletteEntry]? = nil,
        on terminalView: LocalProcessTerminalView
    ) {
        let entries = palette ?? currentPalette()
        guard let colors = swiftTermColors(from: entries) else { return }
        terminalView.installColors(colors)
    }
}
