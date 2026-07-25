//
//  UserKeybindingDispatcherTests.swift
//  PineTests
//
//  Issue #1117: verifies the user-keybinding precedence rule that the
//  AppDelegate keyDown monitor relies on. A user override claims an event
//  (so a built-in menu equivalent for the same chord is suppressed); an
//  empty or non-matching registry lets the event fall through.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("User keybinding dispatcher precedence")
@MainActor
struct UserKeybindingDispatcherTests {

    @Test("Empty registry never claims an event")
    func emptyRegistryClaimsNothing() throws {
        let registry = UserKeybindingRegistry()
        let event = try makeCmdEvent(key: "p")
        // An empty registry must let every event fall through to built-in
        // shortcuts, text input, and terminal input untouched.
        #expect(UserKeybindingDispatcher.command(for: event, in: registry) == nil)
    }

    @Test("A user override claims its chord and suppresses the built-in")
    func overrideClaimsItsChord() async throws {
        let registry = try await makeRegistry(chords: [("quickOpen", "cmd+p")])
        let event = try makeCmdEvent(key: "p")
        // A match means the monitor consumes the event; a built-in menu
        // equivalent for "cmd+p" therefore cannot also fire — no double-dispatch.
        #expect(UserKeybindingDispatcher.command(for: event, in: registry) == .quickOpen)
    }

    @Test("A non-matching event falls through even when overrides exist")
    func nonMatchingEventFallsThrough() async throws {
        let registry = try await makeRegistry(chords: [("quickOpen", "cmd+p")])
        let event = try makeCmdEvent(key: "f")
        // The registry has an override, but not for this chord: built-in
        // shortcuts and text input keep working.
        #expect(UserKeybindingDispatcher.command(for: event, in: registry) == nil)
    }

    @Test("One event resolves to exactly one command")
    func oneEventOneCommand() async throws {
        // Two overrides for different chords: each event matches only its own.
        let registry = try await makeRegistry(chords: [
            ("quickOpen", "cmd+p"),
            ("findInFile", "cmd+shift+f"),
        ])
        let pEvent = try makeCmdEvent(key: "p")
        let fEvent = try makeCmdEvent(key: "f", modifiers: [.command, .shift])

        #expect(UserKeybindingDispatcher.command(for: pEvent, in: registry) == .quickOpen)
        #expect(UserKeybindingDispatcher.command(for: fEvent, in: registry) == .findInFile)
        // No event matches more than one command.
        #expect(UserKeybindingDispatcher.command(for: pEvent, in: registry) != .findInFile)
    }

    @Test("User override wins before a conflicting built-in handler")
    func userOverridePrecedesBuiltIn() async throws {
        let registry = try await makeRegistry(chords: [
            ("quickOpen", "cmd+shift+b"),
        ])
        let event = try makeCmdEvent(
            key: "b",
            modifiers: [.command, .shift]
        )
        var dispatchedCommands: [UserCommand] = []
        var builtInCallCount = 0

        let routed = UserKeybindingDispatcher.route(
            event,
            registry: registry,
            dispatchUserCommand: { dispatchedCommands.append($0) },
            dispatchBuiltIn: { _ in
                builtInCallCount += 1
                return true
            }
        )

        #expect(routed == nil)
        #expect(dispatchedCommands == [.quickOpen])
        #expect(builtInCallCount == 0)
    }

    @Test("Built-in handler runs once when no user override matches")
    func builtInRunsAfterUserMiss() async throws {
        let registry = try await makeRegistry(chords: [
            ("quickOpen", "cmd+p"),
        ])
        let event = try makeCmdEvent(key: "f")
        var userDispatchCount = 0
        var builtInCallCount = 0

        let routed = UserKeybindingDispatcher.route(
            event,
            registry: registry,
            dispatchUserCommand: { _ in userDispatchCount += 1 },
            dispatchBuiltIn: { _ in
                builtInCallCount += 1
                return true
            }
        )

        #expect(routed == nil)
        #expect(userDispatchCount == 0)
        #expect(builtInCallCount == 1)
    }

    @Test("Rebinding a command suppresses its former built-in shortcut")
    func reboundCommandSuppressesOldShortcut() async throws {
        let registry = try await makeRegistry(chords: [
            ("quickOpen", "cmd+k"),
        ])
        let formerShortcut = try makeCmdEvent(key: "p")
        var userDispatchCount = 0
        var builtInCallCount = 0

        let routed = UserKeybindingDispatcher.route(
            formerShortcut,
            registry: registry,
            dispatchUserCommand: { _ in userDispatchCount += 1 },
            dispatchBuiltIn: { _ in
                builtInCallCount += 1
                return true
            }
        )

        #expect(routed == nil)
        #expect(userDispatchCount == 0)
        #expect(builtInCallCount == 0)
        #expect(registry.suppressesBuiltInShortcut(for: formerShortcut))
    }

    @Test("A different user command may claim a built-in shortcut")
    func userCommandClaimsAnotherBuiltInShortcut() async throws {
        let registry = try await makeRegistry(chords: [
            ("toggleComment", "cmd+p"),
        ])
        let event = try makeCmdEvent(key: "p")
        var dispatchedCommands: [UserCommand] = []
        var builtInCallCount = 0

        let routed = UserKeybindingDispatcher.route(
            event,
            registry: registry,
            dispatchUserCommand: { dispatchedCommands.append($0) },
            dispatchBuiltIn: { _ in
                builtInCallCount += 1
                return true
            }
        )

        #expect(routed == nil)
        #expect(dispatchedCommands == [.toggleComment])
        #expect(builtInCallCount == 0)
    }

    @Test("Unhandled event reaches menu, text, or terminal unchanged")
    func unhandledEventFallsThrough() async throws {
        let registry = try await makeRegistry(chords: [
            ("quickOpen", "cmd+p"),
        ])
        let event = try makeCmdEvent(key: "x")
        var dispatchCount = 0

        let routed = UserKeybindingDispatcher.route(
            event,
            registry: registry,
            dispatchUserCommand: { _ in dispatchCount += 1 },
            dispatchBuiltIn: { _ in false }
        )

        #expect(routed === event)
        #expect(dispatchCount == 0)
    }

    @Test("Reload that keeps the registry does not silently drop overrides")
    func rejectedReloadKeepsOverridesActive() async throws {
        // Precedence invariant must survive a rejected reload: the last valid
        // registry stays active, so an override keeps claiming its chord.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-dispatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        try Data(#"[{"command": "quickOpen", "key": "cmd+p"}]"#.utf8).write(to: file)

        let registry = UserKeybindingRegistry()
        #expect((await registry.load(from: file)).outcome == .loaded)

        // Now write a malformed file and reload: registry must be unchanged.
        try Data("{".utf8).write(to: file)
        let rejected = await registry.load(from: file)
        #expect(rejected.outcome == .rejected)
        #expect(registry.count == 1)

        let event = try makeCmdEvent(key: "p")
        #expect(UserKeybindingDispatcher.command(for: event, in: registry) == .quickOpen)
    }

    // MARK: - Helpers

    private func makeRegistry(
        chords: [(command: String, key: String)]
    ) async throws -> UserKeybindingRegistry {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-dispatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        // Note: we intentionally do not delete this dir per-test to keep the
        // helper simple; it lives under the system temp dir and is namespaced
        // by UUID, so it cannot collide with real user config.
        let file = directory.appendingPathComponent("keybindings.json")
        let entries = chords.map { chord in
            #"{"command": "\#(chord.command)", "key": "\#(chord.key)"}"#
        }.joined(separator: ", ")
        try Data("[\(entries)]".utf8).write(to: file)
        let registry = UserKeybindingRegistry()
        _ = await registry.load(from: file)
        return registry
    }

    @MainActor
    private func makeCmdEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: 0 // resolved via charactersIgnoringModifiers
        ))
    }
}
