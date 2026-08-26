//
//  MenuHardcodedShortcutGuardTests.swift
//  PineTests
//
//  The guard half of #1539. Converting 32 menu items to
//  `effectiveKeyboardShortcut` fixes the 32; it does nothing about the 33rd,
//  which is a single line someone adds six months from now. So the invariant
//  is stated over the source itself: a menu item may spell a key equivalent
//  out only when no `UserCommand` claims it.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("No menu item hardcodes a rebindable chord")
struct MenuHardcodedShortcutGuardTests {
    /// The menu items allowed to spell a key equivalent out in source.
    ///
    /// None of them is a `UserCommand`, so there is no override to honour and
    /// nothing for `effectiveKeyboardShortcut` to read. Every other item in
    /// the menu takes its chord from `keybindings.effectiveChord(for:)`.
    ///
    /// Adding a name here is a claim that the item has no `UserCommand` case.
    /// ``exemptChordsAreNotRebindable`` checks that claim against the chord,
    /// so an exemption written for a rebindable command still fails.
    static let exemptItems: Set<String> = [
        // Control-Tab MRU switching; handled by a local event monitor, with
        // the menu equivalents kept only as the Accessibility fallback.
        "tabSwitchNext",
        "tabSwitchPrevious",
        // Move Tab — pane and tab arrangement, not a registered command.
        "tabMoveLeading",
        "tabMoveTrailing",
        "tabMoveToPreviousPane",
        "tabMoveToNextPane",
        // Recover Terminal Display — a renderer escape hatch (#1472).
        "menuRecoverTerminalDisplay",
    ]

    @Test("only the exempt menu items spell a key equivalent out in source")
    func hardcodedShortcutsAreConfinedToExemptItems() throws {
        let sites = try MenuCommandSource.hardcodedShortcuts()

        #expect(Set(sites.map(\.item)) == Self.exemptItems)
    }

    /// The semantic half: whatever the allowlist says, a hardcoded chord that
    /// a `UserCommand` also claims is the #1539 bug by definition — the user
    /// can rebind that command, and the menu will keep advertising this.
    @Test("no hardcoded chord belongs to a rebindable command")
    func exemptChordsAreNotRebindable() throws {
        let rebindable = Set(UserCommand.allCases.compactMap(\.defaultChord))

        for site in try MenuCommandSource.hardcodedShortcuts() {
            let chord = try #require(
                MenuCommandSource.chord(from: site.argument),
                """
                \(site.item) at line \(site.line) spells out a key \
                equivalent this guard cannot read: \(site.argument). Route \
                it through effectiveKeyboardShortcut, or teach \
                MenuCommandSource.chord(from:) the new spelling — an \
                unreadable hardcode is not an exempt one.
                """
            )
            #expect(
                !rebindable.contains(chord),
                """
                \(site.item) at line \(site.line) hardcodes \
                \(chord.displayText), which is a UserCommand's built-in \
                chord. Use .effectiveKeyboardShortcut(...) so a user rebind \
                replaces it instead of running alongside it (#1539).
                """
            )
        }
    }

    /// Every exemption has to correspond to a site that actually exists, so a
    /// removed menu item leaves a stale name behind rather than a silent hole
    /// the next hardcode can slip through.
    @Test("no exemption outlives the menu item it was written for")
    func exemptionsAreAllInUse() throws {
        let sites = Set(try MenuCommandSource.hardcodedShortcuts().map(\.item))

        #expect(Self.exemptItems.subtracting(sites).isEmpty)
    }

    /// The other way to leave the conversion half-done: drop the hardcoded
    /// chord without putting `effectiveChord(for:)` in its place, or paste the
    /// replacement from the item above and leave the neighbouring command's
    /// name in it. Neither shows up in the counts — one item quietly loses its
    /// key equivalent and another quietly grows a second one.
    @Test("each command with a built-in chord is read by exactly one item")
    func rebindableCommandsAreWiredOnceEach() throws {
        let wired = try MenuCommandSource.overriddenCommands()
        let rebindable = Set(
            UserCommand.allCases
                .filter { $0.defaultChord != nil }
                .map(\.rawValue)
        )

        #expect(
            Set(wired).count == wired.count,
            """
            Two menu items read the same command's chord: \
            \(wired.filter { name in wired.filter { $0 == name }.count > 1 })
            """
        )
        #expect(
            rebindable.subtracting(wired).isEmpty,
            """
            \(rebindable.subtracting(wired).sorted()) own a built-in chord \
            that no menu item reads, so the menu advertises nothing for them.
            """
        )
    }
}

/// Reads `Pine/PineAppMenuCommands.swift` the way the guards above need it.
///
/// A source scan, not a runtime one, because `Commands` bodies are opaque:
/// SwiftUI offers no way to ask a built menu what key equivalent an item
/// carries, and the defect being guarded is a spelling in the source anyway.
///
/// Fails closed at every step — a moved file, an unreadable file, or a file
/// whose contents no longer look like the menu definitions is an error, never
/// an empty result. A guard that scans nothing must not pass (#1508).
enum MenuCommandSource {
    /// One `.keyboardShortcut(…)` call spelled out in the menu source.
    struct HardcodedShortcut {
        /// The `Strings.<key>` the enclosing item labels itself with — the
        /// closest thing the source has to an identity for a menu item.
        let item: String
        /// Source text between the call's parentheses, newlines collapsed.
        let argument: String
        let line: Int
    }

    struct SourceNotRecognizedError: Error, CustomStringConvertible {
        let url: URL
        let reason: String

        var description: String {
            """
            \(url.path) does not look like Pine's menu definitions \
            (\(reason)). This guard cannot pass on a file it failed to \
            read — check whether the menu moved.
            """
        }
    }

    static let relativePath = "Pine/PineAppMenuCommands.swift"

    /// The literal a hardcoded call passes as its key, mapped to the token the
    /// chord grammar uses for the same key.
    private static let keyTokensBySpelling: [String: String] = [
        ".return": "return",
        ".tab": "tab",
        ".delete": "delete",
        ".escape": "esc",
        ".space": "space",
        ".upArrow": "up",
        ".downArrow": "down",
        ".leftArrow": "left",
        ".rightArrow": "right",
        "\\t": "tab",
        "\\r": "return",
        "\\n": "return",
    ]

    static func source() throws -> String {
        let url = try ProductionSourceScan.repositoryRoot()
            .appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        guard text.contains("struct PineAppMenuCommands") else {
            throw SourceNotRecognizedError(
                url: url,
                reason: "no PineAppMenuCommands declaration"
            )
        }
        guard text.contains(".effectiveKeyboardShortcut(") else {
            throw SourceNotRecognizedError(
                url: url,
                reason: "no effectiveKeyboardShortcut call"
            )
        }
        return text
    }

    /// Every `.keyboardShortcut(…)` call in the menu source, with the menu
    /// item each one belongs to.
    ///
    /// `.effectiveKeyboardShortcut(` does not match: the capital `K` in the
    /// composed name is not the `.k` this searches for.
    static func hardcodedShortcuts() throws -> [HardcodedShortcut] {
        let text = try source()
        var results: [HardcodedShortcut] = []
        var searchStart = text.startIndex

        while let call = text.range(
            of: ".keyboardShortcut(",
            range: searchStart..<text.endIndex
        ) {
            var depth = 1
            var index = call.upperBound
            var argument = ""
            while index < text.endIndex {
                let character = text[index]
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                argument.append(character)
                index = text.index(after: index)
            }
            results.append(
                HardcodedShortcut(
                    item: itemLabel(before: call.lowerBound, in: text) ?? "",
                    argument: collapse(argument),
                    line: text[..<call.lowerBound].filter { $0 == "\n" }
                        .count + 1
                )
            )
            searchStart = index
        }
        return results
    }

    /// The commands the menu reads a chord for, in source order, one entry per
    /// `effectiveChord(for: .command)` call — repeats included, because a
    /// repeat is the defect ``rebindableCommandsAreWiredOnceEach`` looks for.
    static func overriddenCommands() throws -> [String] {
        let text = try source()
        let marker = "effectiveChord(for: ."
        var results: [String] = []
        var searchStart = text.startIndex

        while let call = text.range(
            of: marker,
            range: searchStart..<text.endIndex
        ) {
            let name = text[call.upperBound...].prefix {
                $0.isLetter || $0.isNumber
            }
            if !name.isEmpty { results.append(String(name)) }
            searchStart = call.upperBound
        }
        return results
    }

    /// Turns a hardcoded call's argument text into the chord it installs, so
    /// the guard can compare it with `UserCommand.defaultChord` rather than
    /// trusting an allowlist alone.
    ///
    /// Returns `nil` for a spelling it does not recognize; the caller treats
    /// that as a failure, so an unreadable hardcode is never a passing one.
    static func chord(from argument: String) -> ParsedKeyChord? {
        let parts = argument.components(separatedBy: "modifiers:")
        let keyText = parts[0]
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        guard let key = keyToken(from: keyText) else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        if parts.count > 1 {
            let modifierText = parts[1]
            if modifierText.contains(".command") { modifiers.insert(.command) }
            if modifierText.contains(".control") { modifiers.insert(.control) }
            if modifierText.contains(".option") { modifiers.insert(.option) }
            if modifierText.contains(".shift") { modifiers.insert(.shift) }
        }
        return ParsedKeyChord(modifiers: modifiers, key: key)
    }

    // MARK: - Private

    private static func keyToken(from text: String) -> String? {
        var spelling = text
        // `KeyEquivalent("x")` and a bare `"x"` name the same key.
        if spelling.hasPrefix("KeyEquivalent(") {
            spelling = String(spelling.dropFirst("KeyEquivalent(".count))
            guard spelling.hasSuffix(")") else { return nil }
            spelling = String(spelling.dropLast())
        }
        if let token = keyTokensBySpelling[spelling] { return token }
        guard spelling.hasPrefix("\""), spelling.hasSuffix("\""),
              spelling.count >= 2 else {
            return nil
        }
        let literal = String(spelling.dropFirst().dropLast())
        if let token = keyTokensBySpelling[literal] { return token }
        if let scalar = unicodeEscape(literal) {
            return UserKeybindingRegistry.keyToken(
                keyCode: 0,
                charactersIgnoringModifiers: String(scalar)
            )
        }
        guard literal.count == 1 else { return nil }
        return literal.lowercased()
    }

    /// Decodes a `\u{F70B}` escape as written in Swift source.
    private static func unicodeEscape(_ literal: String) -> Character? {
        guard literal.hasPrefix("\\u{"), literal.hasSuffix("}") else {
            return nil
        }
        let digits = literal.dropFirst("\\u{".count).dropLast()
        guard let value = UInt32(digits, radix: 16),
              let scalar = UnicodeScalar(value) else {
            return nil
        }
        return Character(scalar)
    }

    private static func itemLabel(
        before index: String.Index,
        in text: String
    ) -> String? {
        guard let marker = text.range(
            of: "Strings.",
            options: .backwards,
            range: text.startIndex..<index
        ) else {
            return nil
        }
        let name = text[marker.upperBound...].prefix {
            $0.isLetter || $0.isNumber || $0 == "_"
        }
        return name.isEmpty ? nil : String(name)
    }

    private static func collapse(_ argument: String) -> String {
        argument
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
