//
//  MenuChordConventionTests.swift
//  PineTests
//
//  The chord half of #1564. The commands and their rebinding machinery are
//  free to name any chord; the *defaults* are a public interface, and the
//  acceptance criteria state three properties no default is allowed to lose:
//  no chord without a dispatch modifier (⌥Z claimed a typeable letter
//  app-wide), no bare function key (F8/⇧F8 demanded Fn and collided with
//  system feature keys), and no two commands answering to the same chord.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Default command chords follow the keyboard conventions")
struct MenuChordConventionTests {
    /// The built-in chord of every rebindable command, paired with its owner.
    private static var claims: [(command: UserCommand, chord: ParsedKeyChord)] {
        UserCommand.allCases.compactMap { command in
            command.defaultChord.map { (command, $0) }
        }
    }

    /// A default chord must carry Command or Control — the same bar the
    /// registry holds user chords to (`hasDispatchModifier`). An Option-only
    /// or bare chord steals a typeable character from the editor and the
    /// terminal on some layout: ⌥Z was "Ω" on US (#1564).
    @Test("no default chord omits Command and Control")
    func everyDefaultChordCarriesADispatchModifier() {
        for (command, chord) in Self.claims {
            #expect(
                !chord.modifiers.isDisjoint(with: [.command, .control]),
                """
                \(command.rawValue) defaults to \(chord.displayText), which \
                carries neither Command nor Control. A chord without a \
                dispatch modifier claims a typeable character app-wide (#1564).
                """
            )
        }
    }

    /// A function key without Command demands Fn under default macOS settings
    /// and collides with the system feature keys layered on F1–F12.
    @Test("no default chord is a bare function key")
    func noDefaultChordIsABareFunctionKey() {
        for (command, chord) in Self.claims {
            let isFunctionKey = (1...20).contains { index in
                chord.key == "f\(index)"
            }
            #expect(
                !isFunctionKey || chord.modifiers.contains(.command),
                """
                \(command.rawValue) defaults to \(chord.displayText): a \
                function key without Command (#1564).
                """
            )
        }
    }

    /// Every command that owns a built-in chord, one distinct chord each. A
    /// collision means one chord silently shadows the other in NSMenu, and
    /// the registry's suppression logic cannot tell them apart.
    @Test("default chords are pairwise distinct")
    func defaultChordsAreUnique() {
        let chords = Self.claims.map(\.chord)
        #expect(
            Set(chords).count == chords.count,
            """
            Two commands claim the same default chord: \
            \(Self.claims.filter { claim in
                chords.filter { $0 == claim.chord }.count > 1
            }.map(\.command.rawValue).sorted()).
            """
        )
    }

    // MARK: - The #1564 replacements

    @Test("Toggle Word Wrap moved off Option-Z onto Command-Option-Z")
    func wordWrapChord() throws {
        let chord = try #require(UserCommand.toggleWordWrap.defaultChord)
        #expect(chord == UserKeybindingRegistry.parse("cmd+option+z"))
        #expect(chord.displayText == "⌥⌘Z")
    }

    @Test(
        "diagnostics moved off bare F8 onto Command-Option arrows mirroring change navigation"
    )
    func diagnosticChords() throws {
        let next = try #require(UserCommand.nextDiagnostic.defaultChord)
        let previous = try #require(UserCommand.previousDiagnostic.defaultChord)
        #expect(next == UserKeybindingRegistry.parse("cmd+option+down"))
        #expect(previous == UserKeybindingRegistry.parse("cmd+option+up"))
        #expect(next.displayText == "⌥⌘↓")
        #expect(previous.displayText == "⌥⌘↑")
    }

    /// The retired chords must stay retired. If a future command picks up
    /// `option+z`, `f8`, or `shift+f8` as its default, it reintroduces the
    /// #1564 defect through the back door.
    @Test("the retired chords stay retired")
    func retiredChordsAreUnclaimed() throws {
        let retired = [
            "option+z",
            "f8",
            "shift+f8",
        ]
        for spelling in retired {
            let chord = try #require(
                UserKeybindingRegistry.parse(spelling),
                "\(spelling) no longer parses; update this test"
            )
            let claimants = Self.claims.filter { $0.chord == chord }
            #expect(
                claimants.isEmpty,
                """
                \(claimants.map(\.command.rawValue)) claim \(spelling), which \
                #1564 retired from the built-in set.
                """
            )
        }
    }

    /// The replacement chords mirror Next/Previous Change (⌃⌥↓/↑) on the
    /// Command family. That pairing is only useful while the two families
    /// stay distinct — ⌥⌘↓ must never quietly become the change chord.
    @Test("diagnostic arrows stay distinct from change arrows")
    func diagnosticArrowsDoNotCollideWithChangeArrows() throws {
        let nextChange = try #require(UserCommand.nextChange.defaultChord)
        let nextDiagnostic = try #require(
            UserCommand.nextDiagnostic.defaultChord
        )
        #expect(nextChange != nextDiagnostic)
        #expect(nextChange.displayText == "⌃⌥↓")
        #expect(nextDiagnostic.displayText == "⌥⌘↓")
    }
}
