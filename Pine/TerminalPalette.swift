//
//  TerminalPalette.swift
//  Pine
//
//  Centralised ANSI 16-color palette for Pine's embedded SwiftTerm terminal.
//
//  Goal (issue #733): make Pine's terminal visually consistent with native
//  macOS terminals (Terminal.app, Ghostty, iTerm2). Prompts coloured by
//  oh-my-zsh / starship should look as muted as in those terminals, not
//  noticeably brighter or more saturated.
//
//  Reference: Ghostty's built-in default 16-color palette
//  (https://github.com/ghostty-org/ghostty, src/terminal/color.zig,
//  `Name.default()`). This is the same Tomorrow-Night-derived set used by
//  Ghostty out of the box on macOS, and it is what users see in
//  Terminal.app's modern profiles, iTerm2's default and most "system"
//  themes — visibly more muted than the highly-saturated Terminal.app
//  "Basic" preset that SwiftTerm and Pine previously used.
//
//  ANSI 16 colors are fixed RGB values by convention — the standard does
//  not vary with light/dark mode. Background / foreground / cursor remain
//  semantic and follow the system appearance via NSColor.textColor /
//  NSColor.textBackgroundColor (configured in TerminalTab).
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
}

/// Pine's ANSI 16-color palette.
///
/// Order matches the SGR / xterm convention:
/// `[black, red, green, yellow, blue, magenta, cyan, white,`
/// ` brightBlack, brightRed, brightGreen, brightYellow,`
/// ` brightBlue, brightMagenta, brightCyan, brightWhite]`.
///
/// The palette is a value type so tests can compare it without instantiating
/// SwiftTerm views. The actual install into a `LocalProcessTerminalView`
/// happens via `apply(to:)`.
enum TerminalPalette {

    /// Number of ANSI colors expected by SwiftTerm's `installColors`.
    static let colorCount = 16

    /// macOS-aligned 16-color ANSI palette (Ghostty default scheme).
    /// See file header for rationale and provenance.
    static let macOSAligned: [TerminalPaletteEntry] = [
        .init(red: 0x1D, green: 0x1F, blue: 0x21), // 0  black
        .init(red: 0xCC, green: 0x66, blue: 0x66), // 1  red
        .init(red: 0xB5, green: 0xBD, blue: 0x68), // 2  green
        .init(red: 0xF0, green: 0xC6, blue: 0x74), // 3  yellow
        .init(red: 0x81, green: 0xA2, blue: 0xBE), // 4  blue
        .init(red: 0xB2, green: 0x94, blue: 0xBB), // 5  magenta
        .init(red: 0x8A, green: 0xBE, blue: 0xB7), // 6  cyan
        .init(red: 0xC5, green: 0xC8, blue: 0xC6), // 7  white
        .init(red: 0x66, green: 0x66, blue: 0x66), // 8  bright black (dim — autosuggestions)
        .init(red: 0xD5, green: 0x4E, blue: 0x53), // 9  bright red
        .init(red: 0xB9, green: 0xCA, blue: 0x4A), // 10 bright green
        .init(red: 0xE7, green: 0xC5, blue: 0x47), // 11 bright yellow
        .init(red: 0x7A, green: 0xA6, blue: 0xDA), // 12 bright blue
        .init(red: 0xC3, green: 0x97, blue: 0xD8), // 13 bright magenta
        .init(red: 0x70, green: 0xC0, blue: 0xB1), // 14 bright cyan
        .init(red: 0xEA, green: 0xEA, blue: 0xEA), // 15 bright white
    ]

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

    /// Installs the macOS-aligned palette on a `LocalProcessTerminalView`.
    ///
    /// Wrapped in a `guard` so that an unexpected SwiftTerm API change (the
    /// palette failing to build) leaves the terminal usable on whatever
    /// SwiftTerm provides by default — colors might look off, but the
    /// terminal will not crash or render blank.
    @MainActor
    static func install(on terminalView: LocalProcessTerminalView) {
        guard let colors = swiftTermColors() else { return }
        terminalView.installColors(colors)
    }
}
