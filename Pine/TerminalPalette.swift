//
//  TerminalPalette.swift
//  Pine
//
//  Centralised ANSI 16-color palette for Pine's embedded SwiftTerm terminal.
//
//  Goal (issue #765): make Pine's terminal visually indistinguishable from
//  the system `Terminal.app` "Basic" profile for the 16 ANSI slots that TUI
//  apps such as k9s, htop, lazygit, btop and vim drive directly via
//  `\e[3xm` / `tput setaf`. If those 16 slots disagree with Terminal.app
//  the familiar TUIs look "off" and users bail out to iTerm2.
//
//  The reference palette is the exact sRGB values that ship in
//  `/System/Applications/Utilities/Terminal.app/Contents/Resources/Basic.terminal`:
//
//      black   #000000   red     #990000   green   #00A600   yellow  #999900
//      blue    #0000B2   magenta #B200B2   cyan    #00A6B2   white   #BFBFBF
//      brBlack #666666   brRed   #E50000   brGreen #00D900   brYlw   #E5E500
//      brBlue  #0000FF   brMag   #E500E5   brCyan  #00E5E5   brWht   #E5E5E5
//
//  Scope of `install(on:)`:
//  ONLY the 16 ANSI palette slots are touched here. Background / foreground
//  / cursor / selection are deliberately NOT set — `TerminalSession` keeps
//  them on semantic `NSColor.textBackgroundColor` / `NSColor.textColor` so
//  the terminal stays adaptive to light/dark mode and respects the system
//  appearance the way every other native macOS app does. TUI apps paint
//  their own background through ANSI sequences anyway, which is what #765
//  is actually about.
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
//  Theme picker (issue #816) exposes all built-in palettes via the
//  Terminal > Theme menu. `TerminalThemeID` enumerates the available
//  themes and `TerminalThemeSettings` persists the user's choice.
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
    /// standard `× 257` formula (so 0xFF → 0xFFFF, preserving full intensity).
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

/// Identifies a built-in terminal color theme.
///
/// Each case maps to a 16-color ANSI palette. The raw value is persisted in
/// UserDefaults, so cases must not be renamed without a migration path.
enum TerminalThemeID: String, CaseIterable, Identifiable {
    case basic
    case pro
    case solarizedDark
    case dracula
    case oneDark
    case nord

    var id: String { rawValue }

    /// Human-readable name shown in the Terminal > Theme menu.
    var displayName: String {
        switch self {
        case .basic: "Basic"
        case .pro: "Pro"
        case .solarizedDark: "Solarized Dark"
        case .dracula: "Dracula"
        case .oneDark: "One Dark"
        case .nord: "Nord"
        }
    }

    /// Returns the 16-color ANSI palette for this theme.
    var palette: [TerminalPaletteEntry] {
        switch self {
        case .basic: TerminalPalette.terminalAppBasic
        case .pro: TerminalPalette.terminalAppPro
        case .solarizedDark: TerminalPalette.solarizedDark
        case .dracula: TerminalPalette.dracula
        case .oneDark: TerminalPalette.oneDark
        case .nord: TerminalPalette.nord
        }
    }

    /// Per-theme color to override slot 0 so that zsh-autosuggestions / fish
    /// ghost text (which hits slot 0 via SwiftTerm's 8 → 0 collapse) remains
    /// readable. Each theme uses its own slot 8 value as the ghost text color
    /// because SwiftTerm collapses 8 → 0 when `useBrightColors = false`.
    ///
    /// `nil` means no override — slot 0 is already distinct enough from the
    /// background (e.g. Solarized Dark where slot 0 is #073642).
    ///
    /// Basic and Pro use the Tomorrow Night grey (#969896) instead of their
    /// own slot 8 values (#666666 / #555555) which are too dark on the
    /// standard dark-mode background.
    var ghostTextColor: TerminalPaletteEntry? {
        switch self {
        case .basic: TerminalPaletteEntry(red: 0x96, green: 0x98, blue: 0x96)
        case .pro: TerminalPaletteEntry(red: 0x96, green: 0x98, blue: 0x96)
        case .solarizedDark: nil
        case .dracula: TerminalPaletteEntry(red: 0x62, green: 0x72, blue: 0xA4)
        case .oneDark: TerminalPaletteEntry(red: 0x5C, green: 0x63, blue: 0x70)
        case .nord: TerminalPaletteEntry(red: 0x4C, green: 0x56, blue: 0x6A)
        }
    }
}

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

    // MARK: - Terminal.app "Basic" (reference, unmodified)

    /// Exact sRGB values from `Basic.terminal` shipped with macOS — kept
    /// bit-for-bit so the unit tests can pin against the canonical profile.
    /// Note: this is NOT the palette Pine actually installs. The shipped
    /// palette is `macOSAligned` below, which equals Basic except for slot
    /// 8 (bright black) — see the file header for the rationale.
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

    /// Tomorrow Night value (#969896) used to override slot 0 so that
    /// zsh-autosuggestions / fish ghost text remains readable on the
    /// dark-mode background — the regression fixed by issue #733.
    ///
    /// Why slot 0 and not slot 8? SwiftTerm 1.13.0 in `useBrightColors = false`
    /// mode (which Pine sets in `TerminalSession.swift` for #733 / Ghostty
    /// parity) collapses ANSI 256-color indices 8..15 → 0..7 inside
    /// `Apple/AppleTerminalView.swift:246-249`:
    ///
    ///     // useBrightColors = false branch
    ///     midx = ansi > 7 ? (Int (ansi) - 8) : Int(ansi)
    ///
    /// This means any `\e[38;5;8m` (which is what zsh-autosuggestions sends
    /// for `fg=8`) actually reads `terminal.ansiColors[0]` — slot 8 is
    /// physically unreachable. We work around it by overriding slot 0 with
    /// the readable grey, so the ghost text comes out at #969896 via the
    /// 8 → 0 collapse. ANSI 0 ("black") on a dark terminal background was
    /// already invisible by definition, so making it grey is strictly an
    /// improvement, not a loss.
    ///
    /// On a light background "black" text becomes mid-grey instead of pure
    /// black — slightly off-spec but still readable, and the only common
    /// place that matters is shells whose default config uses the matching
    /// `NSColor.textColor` foreground anyway.
    ///
    /// Long-term fix is upstream in SwiftTerm: separate the bold-as-bright
    /// rendering path from the 256-color index collapse so `useBrightColors`
    /// only affects the former. Track that as a follow-up.
    static let ghostTextOverride = TerminalPaletteEntry(red: 0x96, green: 0x98, blue: 0x96)

    /// Reference background used by the contrast assertions for the
    /// dark-mode `NSColor.textBackgroundColor` worst case. Hard-coded so
    /// the test target does not depend on host appearance.
    static let darkModeBackgroundReference = TerminalPaletteEntry(red: 0x1E, green: 0x1E, blue: 0x1E)

    // MARK: - Alternative profiles

    /// Terminal.app "Pro" profile — darker red, teal/green bias.
    static let terminalAppPro: [TerminalPaletteEntry] = [
        .init(red: 0x00, green: 0x00, blue: 0x00), // 0  black
        .init(red: 0xBB, green: 0x00, blue: 0x00), // 1  red
        .init(red: 0x00, green: 0xBB, blue: 0x00), // 2  green
        .init(red: 0xBB, green: 0xBB, blue: 0x00), // 3  yellow
        .init(red: 0x00, green: 0x00, blue: 0xBB), // 4  blue
        .init(red: 0xBB, green: 0x00, blue: 0xBB), // 5  magenta
        .init(red: 0x00, green: 0xBB, blue: 0xBB), // 6  cyan
        .init(red: 0xBB, green: 0xBB, blue: 0xBB), // 7  white
        .init(red: 0x55, green: 0x55, blue: 0x55), // 8  bright black
        .init(red: 0xFF, green: 0x55, blue: 0x55), // 9  bright red
        .init(red: 0x55, green: 0xFF, blue: 0x55), // 10 bright green
        .init(red: 0xFF, green: 0xFF, blue: 0x55), // 11 bright yellow
        .init(red: 0x55, green: 0x55, blue: 0xFF), // 12 bright blue
        .init(red: 0xFF, green: 0x55, blue: 0xFF), // 13 bright magenta
        .init(red: 0x55, green: 0xFF, blue: 0xFF), // 14 bright cyan
        .init(red: 0xFF, green: 0xFF, blue: 0xFF), // 15 bright white
    ]

    /// Ethan Schoonover's Solarized Dark.
    static let solarizedDark: [TerminalPaletteEntry] = [
        .init(red: 0x07, green: 0x36, blue: 0x42), // 0  base02
        .init(red: 0xDC, green: 0x32, blue: 0x2F), // 1  red
        .init(red: 0x85, green: 0x99, blue: 0x00), // 2  green
        .init(red: 0xB5, green: 0x89, blue: 0x00), // 3  yellow
        .init(red: 0x26, green: 0x8B, blue: 0xD2), // 4  blue
        .init(red: 0xD3, green: 0x36, blue: 0x82), // 5  magenta
        .init(red: 0x2A, green: 0xA1, blue: 0x98), // 6  cyan
        .init(red: 0xEE, green: 0xE8, blue: 0xD5), // 7  base2
        .init(red: 0x00, green: 0x2B, blue: 0x36), // 8  base03
        .init(red: 0xCB, green: 0x4B, blue: 0x16), // 9  orange
        .init(red: 0x58, green: 0x6E, blue: 0x75), // 10 base01
        .init(red: 0x65, green: 0x7B, blue: 0x83), // 11 base00
        .init(red: 0x83, green: 0x94, blue: 0x96), // 12 base0
        .init(red: 0x6C, green: 0x71, blue: 0xC4), // 13 violet
        .init(red: 0x93, green: 0xA1, blue: 0xA1), // 14 base1
        .init(red: 0xFD, green: 0xF6, blue: 0xE3), // 15 base3
    ]

    /// Dracula — https://draculatheme.com/contribute
    static let dracula: [TerminalPaletteEntry] = [
        .init(red: 0x21, green: 0x22, blue: 0x2C), // 0  black
        .init(red: 0xFF, green: 0x55, blue: 0x55), // 1  red
        .init(red: 0x50, green: 0xFA, blue: 0x7B), // 2  green
        .init(red: 0xF1, green: 0xFA, blue: 0x8C), // 3  yellow
        .init(red: 0xBD, green: 0x93, blue: 0xF9), // 4  blue
        .init(red: 0xFF, green: 0x79, blue: 0xC6), // 5  magenta
        .init(red: 0x8B, green: 0xE9, blue: 0xFD), // 6  cyan
        .init(red: 0xF8, green: 0xF8, blue: 0xF2), // 7  white
        .init(red: 0x62, green: 0x72, blue: 0xA4), // 8  bright black
        .init(red: 0xFF, green: 0x6E, blue: 0x6E), // 9  bright red
        .init(red: 0x69, green: 0xFF, blue: 0x94), // 10 bright green
        .init(red: 0xFF, green: 0xFF, blue: 0xA5), // 11 bright yellow
        .init(red: 0xD6, green: 0xAC, blue: 0xFF), // 12 bright blue
        .init(red: 0xFF, green: 0x92, blue: 0xDF), // 13 bright magenta
        .init(red: 0xA4, green: 0xFF, blue: 0xFF), // 14 bright cyan
        .init(red: 0xFF, green: 0xFF, blue: 0xFF), // 15 bright white
    ]

    /// One Dark (Atom editor) palette.
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

    /// Nord — https://www.nordtheme.com
    /// Note: bright colors (slots 9-14) intentionally equal their normal
    /// counterparts — this is canonical for Nord, not a copy-paste error.
    static let nord: [TerminalPaletteEntry] = [
        .init(red: 0x3B, green: 0x42, blue: 0x52), // 0  black
        .init(red: 0xBF, green: 0x61, blue: 0x6A), // 1  red
        .init(red: 0xA3, green: 0xBE, blue: 0x8C), // 2  green
        .init(red: 0xEB, green: 0xCB, blue: 0x8B), // 3  yellow
        .init(red: 0x81, green: 0xA1, blue: 0xC1), // 4  blue
        .init(red: 0xB4, green: 0x8E, blue: 0xAD), // 5  magenta
        .init(red: 0x88, green: 0xC0, blue: 0xD0), // 6  cyan
        .init(red: 0xE5, green: 0xE9, blue: 0xF0), // 7  white
        .init(red: 0x4C, green: 0x56, blue: 0x6A), // 8  bright black
        .init(red: 0xBF, green: 0x61, blue: 0x6A), // 9  bright red
        .init(red: 0xA3, green: 0xBE, blue: 0x8C), // 10 bright green
        .init(red: 0xEB, green: 0xCB, blue: 0x8B), // 11 bright yellow
        .init(red: 0x81, green: 0xA1, blue: 0xC1), // 12 bright blue
        .init(red: 0xB4, green: 0x8E, blue: 0xAD), // 13 bright magenta
        .init(red: 0x88, green: 0xC0, blue: 0xD0), // 14 bright cyan
        .init(red: 0xEC, green: 0xEF, blue: 0xF4), // 15 bright white
    ]

    /// Default palette Pine actually installs today.
    ///
    /// Equals `terminalAppBasic` for every slot EXCEPT slot 0 (black), which
    /// is replaced with `ghostTextOverride` (Tomorrow Night `#969896`).
    /// See the doc on `ghostTextOverride` for *why* slot 0 and not slot 8 —
    /// SwiftTerm 1.13.0 collapses 256-color 8 → 0 in `useBrightColors = false`
    /// mode so slot 8 is physically unreachable, and the ghost-text fix has to
    /// land on slot 0 to actually take effect at runtime.
    ///
    /// All other slots (1..15) are bit-for-bit Terminal.app Basic — that is
    /// what #765 asks for. The slot-0 override is the deliberate compromise
    /// between #765 (TUI parity) and #733 (ghost text contrast). When the
    /// theme picker lands the alternative profiles will be exposed unmodified
    /// — only the default carries this override.
    static let macOSAligned: [TerminalPaletteEntry] = {
        var entries = terminalAppBasic
        entries[0] = ghostTextOverride
        return entries
    }()

    // MARK: - Build / install helpers

    /// Resolves the effective palette for a given theme, applying the
    /// ghost-text override to slot 0 when the theme requires it.
    static func resolvedPalette(for theme: TerminalThemeID) -> [TerminalPaletteEntry] {
        var entries = theme.palette
        if let ghostColor = theme.ghostTextColor {
            entries[0] = ghostColor
        }
        return entries
    }

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
        on terminalView: LocalProcessTerminalView,
        theme: TerminalThemeID = .basic
    ) {
        let entries = resolvedPalette(for: theme)
        guard let colors = swiftTermColors(from: entries) else { return }
        terminalView.installColors(colors)
    }
}
