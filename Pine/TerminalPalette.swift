//
//  TerminalPalette.swift
//  Pine
//
//  Centralised ANSI 16-color palette for Pine's embedded SwiftTerm terminal.
//
//  Goal (issue #765): make Pine's terminal visually indistinguishable from
//  the system `Terminal.app` "Basic" profile. TUI apps such as k9s, htop,
//  lazygit, btop and vim drive the 16 base ANSI colors directly via
//  `\e[3xm` / `tput setaf`; if those 16 slots disagree with Terminal.app
//  the familiar TUIs look "off" and users bail out to iTerm2.
//
//  The default palette is therefore the exact sRGB values that ship in
//  `/System/Applications/Utilities/Terminal.app/Contents/Resources/Basic.terminal`:
//
//      black   #000000   red     #990000   green   #00A600   yellow  #999900
//      blue    #0000B2   magenta #B200B2   cyan    #00A6B2   white   #BFBFBF
//      brBlack #666666   brRed   #E50000   brGreen #00D900   brYlw   #E5E500
//      brBlue  #0000FF   brMag   #E500E5   brCyan  #00E5E5   brWht   #E5E5E5
//
//  Together with Basic's background (#000000), foreground (#BFBFBF),
//  cursor (#BFBFBF) and selection (#414141) this gives the same look as
//  a fresh Terminal.app window — which is what #765 asks for.
//
//  Background / foreground / cursor / selection are all installed by
//  `install(on:)` so the palette has a single source of truth and cannot
//  drift from the ANSI slots it is tuned for.
//
//  Additional palettes (Terminal.app "Pro", Solarized Dark/Light) are
//  declared below but intentionally not wired up yet — a theme picker is
//  out of scope for #765 and will land in a follow-up PR.
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

    // MARK: - Terminal.app "Basic" (default)

    /// Exact sRGB values from `Basic.terminal` shipped with macOS.
    /// This is what TUI apps compare against when users report "colors are
    /// wrong in Pine's terminal" (issue #765).
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

    /// Background color from the Basic profile — solid black, matching
    /// Terminal.app. Also used as the reference background in the contrast
    /// unit tests.
    static let basicBackground = TerminalPaletteEntry(red: 0x00, green: 0x00, blue: 0x00)

    /// Default foreground color in Basic — the same #BFBFBF as ANSI white.
    static let basicForeground = TerminalPaletteEntry(red: 0xBF, green: 0xBF, blue: 0xBF)

    /// Cursor color in Basic matches the foreground.
    static let basicCursor = TerminalPaletteEntry(red: 0xBF, green: 0xBF, blue: 0xBF)

    /// Selection highlight color in Basic (dark grey).
    static let basicSelection = TerminalPaletteEntry(red: 0x41, green: 0x41, blue: 0x41)

    // MARK: - Alternative profiles (not wired up yet — follow-up PR)

    // Terminal.app "Pro" profile — darker red, teal/green bias.
    // TODO(#765-followup): expose a theme picker and let users opt in.
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

    // Ethan Schoonover's Solarized Dark — reference values for the
    // follow-up theme picker. Intentionally unused for now.
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

    /// Default palette used by Pine today. Points at the Terminal.app Basic
    /// values above. When the theme picker lands (TODO #765-followup) this
    /// is the only reference callers need to change.
    static let macOSAligned: [TerminalPaletteEntry] = terminalAppBasic

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

    /// Installs the Terminal.app Basic palette — ANSI 16 colors plus the
    /// non-ANSI background / foreground / cursor / selection — on a
    /// `LocalProcessTerminalView`.
    ///
    /// Wrapped in a `guard` so that an unexpected SwiftTerm API change (the
    /// palette failing to build) leaves the terminal usable on whatever
    /// SwiftTerm provides by default — colors might look off, but the
    /// terminal will not crash or render blank.
    @MainActor
    static func install(on terminalView: LocalProcessTerminalView) {
        guard let colors = swiftTermColors() else { return }
        terminalView.installColors(colors)

        // Sync the non-ANSI slots so the whole terminal matches the Basic
        // profile, not just the SGR foreground colors. Without this step
        // bright-black text (e.g. zsh-autosuggestions) would be judged
        // against the wrong background and look subtly different from
        // Terminal.app.
        terminalView.nativeBackgroundColor = basicBackground.makeNSColor()
        terminalView.nativeForegroundColor = basicForeground.makeNSColor()
        terminalView.caretColor = basicCursor.makeNSColor()
        terminalView.selectedTextBackgroundColor = basicSelection.makeNSColor()
    }
}
