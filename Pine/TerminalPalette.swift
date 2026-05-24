//
//  TerminalPalette.swift
//  Pine
//
//  Centralised ANSI 16-color palette for Pine's embedded SwiftTerm terminal.
//
//  Pine uses appearance-aware ANSI palettes for the 16 ANSI slots that TUI
//  apps such as k9s, htop, lazygit, btop and vim drive directly via
//  `\e[3xm` / `tput setaf`. One Dark is used in dark mode; Catppuccin Latte
//  in light mode. Both provide excellent readability on their respective
//  backgrounds.
//
//  Scope of `install(on:)`:
//  ONLY the 16 ANSI palette slots are touched here. Background / foreground
//  / cursor / selection are deliberately NOT set — `TerminalSession` keeps
//  them on semantic `NSColor.textBackgroundColor` / `NSColor.textColor` so
//  the terminal stays adaptive to light/dark mode and respects the system
//  appearance the way every other native macOS app does. TUI apps paint
//  their own background through ANSI sequences anyway.
//
//  Coverage across SGR forms — and the SwiftTerm 1.13.0 collapse quirk:
//
//    * Basic SGR \e[30m..\e[37m and \e[90m..\e[97m, plus the 256-color
//      form \e[38;5;Nm for N in 0...15 — both go through the SAME code
//      path in `Apple/AppleTerminalView.swift` (`case .ansi256(let ansi):`,
//      ~line 241). There is no separate handler for the basic 16. The
//      relevant snippet is:
//
//          if useBrightColors {
//              midx = ansi < 7 ? (Int (ansi) + (isBold ? 8 : 0)) : Int (ansi)
//          } else {
//              midx = ansi > 7 ? (Int (ansi) - 8) : Int(ansi)   // <- collapse!
//          }
//
//      Pine sets `useBrightColors = false` in `TerminalSession.swift` so
//      that bold text does NOT auto-promote to bright (issue #733 / Ghostty
//      parity). The unfortunate side effect is the second branch above:
//      it collapses every ANSI index 8..15 onto 0..7 BEFORE looking up
//      `terminal.ansiColors[midx]`. So `\e[38;5;8m` (which is what
//      zsh-autosuggestions / fish use for ghost text via `fg=8`) actually
//      reads `ansiColors[0]` — slot 8 is unreachable and any override on
//      it is silently ignored.
//
//      The workaround: override slot 0 instead (see `ghostTextOverride`).
//      That makes the 8 → 0 collapse land on the readable grey, which is
//      what users actually need. ANSI 0 ("black") on a dark terminal
//      background was already invisible, so making it grey is strictly
//      better, not worse. On light backgrounds it becomes mid-grey instead
//      of pure black — slightly off-spec but still legible.
//
//    * True color \e[38;2;R;G;Bm — not affected by palettes, passes
//      through unchanged (by design).
//
//  Long-term fix is upstream in SwiftTerm: separate the bold-as-bright
//  rendering decision from the 256-color index collapse so `useBrightColors`
//  only affects the former. Tracked as a follow-up issue.
//

import Foundation
import SwiftTerm

/// 8-bit RGB triple used to describe a single ANSI palette entry in
/// human-readable form. Converted to SwiftTerm's 16-bit `Color` at install
/// time. Public for unit-testing.
struct TerminalPaletteEntry: Equatable {
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

    /// One Dark's slot 8 value (#5C6370 — bright black / readable grey for
    /// zsh-autosuggestions ghost text). Used to override slot 0 so that
    /// ghost text remains readable on the dark-mode background.
    ///
    /// Why slot 0 and not slot 8? SwiftTerm 1.13.0 in `useBrightColors = false`
    /// mode (which Pine sets in `TerminalSession.swift` for #733 / Ghostty
    /// parity) collapses ANSI 256-color indices 8..15 -> 0..7 inside
    /// `Apple/AppleTerminalView.swift:246-249`:
    ///
    ///     // useBrightColors = false branch
    ///     midx = ansi > 7 ? (Int (ansi) - 8) : Int(ansi)
    ///
    /// This means any `\e[38;5;8m` (which is what zsh-autosuggestions sends
    /// for `fg=8`) actually reads `terminal.ansiColors[0]` — slot 8 is
    /// physically unreachable. We work around it by overriding slot 0 with
    /// the readable grey, so the ghost text comes out at #5C6370 via the
    /// 8 -> 0 collapse.
    static let ghostTextOverride = TerminalPaletteEntry(red: 0x5C, green: 0x63, blue: 0x70)

    /// Reference background used by the contrast assertions for the
    /// dark-mode `NSColor.textBackgroundColor` worst case. Hard-coded so
    /// the test target does not depend on host appearance.
    /// One Dark canonical background (#282C34) — matches the hardcoded
    /// background in `TerminalSession.swift`.
    static let darkModeBackgroundReference = TerminalPaletteEntry(red: 0x28, green: 0x2C, blue: 0x34)

    /// Default palette Pine actually installs.
    ///
    /// Equals `oneDark` for every slot EXCEPT slot 0 (black), which
    /// is replaced with `ghostTextOverride` (#5C6370 — One Dark's bright
    /// black). See the doc on `ghostTextOverride` for *why* slot 0 and not
    /// slot 8 — SwiftTerm 1.13.0 collapses 256-color 8 -> 0 in
    /// `useBrightColors = false` mode so slot 8 is physically unreachable,
    /// and the ghost-text fix has to land on slot 0 to actually take effect
    /// at runtime.
    static let macOSAligned: [TerminalPaletteEntry] = {
        var entries = oneDark
        entries[0] = ghostTextOverride
        return entries
    }()

    // MARK: - Light palette (Catppuccin Latte)

    /// Light-mode ghost text override for slot 0. Catppuccin Latte's Subtext 0
    /// (#6C6F85) — readable grey for ghost text on the light background.
    /// Uses the same slot-0 workaround as the dark palette (SwiftTerm 8→0 collapse).
    static let lightGhostTextOverride = TerminalPaletteEntry(red: 0x6C, green: 0x6F, blue: 0x85)

    /// Catppuccin Latte palette before ghost-text slot-0 override.
    /// Bright colors (slots 9-14) intentionally equal their normal counterparts
    /// — canonical for Catppuccin Latte, not a copy-paste error.
    private static let catppuccinLatte: [TerminalPaletteEntry] = [
        .init(red: 0xAC, green: 0xBE, blue: 0xBE), // 0  black (overridden below)
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

    /// Light-mode ANSI palette with ghost-text slot-0 override applied.
    static let lightPalette: [TerminalPaletteEntry] = {
        var entries = catppuccinLatte
        entries[0] = lightGhostTextOverride
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
