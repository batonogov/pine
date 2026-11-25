//
//  UserConfigurationReloadTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("User configuration atomic reload")
@MainActor
struct UserConfigurationReloadTests {

    @Test func keybindingsLoadEnvelopeAndBareArrayDocuments() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        let registry = UserKeybindingRegistry()

        try write(
            """
            {
              "keybindings": [
                {"command": "commandPalette", "key": "cmd+p"},
                {"command": "toggleComment", "key": "command+shift+f"}
              ]
            }
            """,
            to: file
        )

        let envelopeReport = await registry.load(from: file)
        #expect(envelopeReport.outcome == .loaded)
        #expect(envelopeReport.activeEntryCount == 2)
        #expect(envelopeReport.diagnostics.isEmpty)
        #expect(registry.entries.map { $0.command } == [.commandPalette, .toggleComment])
        #expect(registry.entries[1].chord.modifiers == [.command, .shift])
        #expect(registry.entries[1].chord.key == "f")

        try write(
            """
            [
              {"command": "save", "key": "ctrl+l"}
            ]
            """,
            to: file
        )

        let arrayReport = await registry.load(from: file)
        #expect(arrayReport.outcome == .loaded)
        #expect(arrayReport.activeEntryCount == 1)
        #expect(registry.entries.map { $0.command } == [.save])
    }

    @Test func invalidKeybindingsRejectTheWholeDocument() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        let registry = UserKeybindingRegistry()
        try write(
            """
            [{"command": "commandPalette", "key": "cmd+p"}]
            """,
            to: file
        )
        #expect((await registry.load(from: file)).outcome == .loaded)

        try write(
            """
            [
              {"command": "notACommand", "key": "cmd+y"},
              {"command": "toggleComment", "key": "cmd+hyper+f"},
              {"command": "save", "key": "command+shift+g"},
              {"command": "toggleComment", "key": "SHIFT+command+G"},
              {"command": "commandPalette", "key": "cmd++p"}
            ]
            """,
            to: file
        )

        let report = await registry.load(from: file)

        #expect(report.outcome == .rejected)
        #expect(report.activeEntryCount == 1)
        #expect(report.diagnostics.map(\.reason).contains(
            .unknownCommand(id: "notACommand")
        ))
        #expect(report.diagnostics.map(\.reason).contains(
            .invalidChord(value: "cmd+hyper+f")
        ))
        #expect(report.diagnostics.map(\.reason).contains(
            .invalidChord(value: "cmd++p")
        ))
        #expect(report.diagnostics.map(\.reason).contains(
            .duplicateChord(value: "SHIFT+command+G", firstEntryNumber: 3)
        ))
        #expect(report.diagnostics.map(\.entryNumber) == [1, 2, 4, 5])
        #expect(registry.entries.map { $0.command } == [.commandPalette])
    }

    @Test func duplicateCommandBindingsRejectAtomically() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        let registry = UserKeybindingRegistry()

        try write(
            #"[{"command": "toggleComment", "key": "cmd+f"}]"#,
            to: file
        )
        #expect((await registry.load(from: file)).outcome == .loaded)

        try write(
            """
            [
              {"command": "commandPalette", "key": "cmd+k"},
              {"command": "commandPalette", "key": "cmd+option+k"}
            ]
            """,
            to: file
        )
        let report = await registry.load(from: file)

        #expect(report.outcome == .rejected)
        #expect(report.diagnostics.map(\.reason).contains(
            .duplicateCommand(id: "commandPalette", firstEntryNumber: 1)
        ))
        #expect(registry.entries.map(\.command) == [.toggleComment])
    }

    @Test func safeDirectCommandsLoadWhileUnsafeChordsAreRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        let registry = UserKeybindingRegistry()
        try write(
            """
            [
              {"command": "toggleWordWrap", "key": "cmd+k"},
              {"command": "commandPalette", "key": "f"},
              {"command": "save", "key": "cmd+c"}
            ]
            """,
            to: file
        )

        let report = await registry.load(from: file)

        #expect(report.outcome == .rejected)
        #expect(!report.diagnostics.map(\.reason).contains(
            .unavailableCommand(id: "toggleWordWrap")
        ))
        #expect(report.diagnostics.map(\.reason).contains(
            .textInputChord(value: "f")
        ))
        #expect(report.diagnostics.map(\.reason).contains(
            .reservedSystemChord(value: "cmd+c")
        ))
        #expect(registry.isEmpty)
    }

    @Test func retiredCommandsDoNotRejectOtherBindings() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        let registry = UserKeybindingRegistry()
        try write(
            """
            [
              {"command": "showProblems", "key": "cmd+shift+x"},
              {"command": "nextDiagnostic", "key": "cmd+option+down"},
              {"command": "previousDiagnostic", "key": "cmd+option+up"},
              {"command": "foldCode", "key": "cmd+option+left"},
              {"command": "unfoldCode", "key": "cmd+option+right"},
              {"command": "foldAll", "key": "cmd+option+shift+left"},
              {"command": "unfoldAll", "key": "cmd+option+shift+right"},
              {"command": "showBranchSwitcher", "key": "cmd+shift+b"},
              {"command": "toggleMinimap", "key": "cmd+shift+m"},
              {"command": "toggleBlame", "key": "cmd+control+b"},
              {"command": "commandPalette", "key": "cmd+p"}
            ]
            """,
            to: file
        )

        let report = await registry.load(from: file)

        #expect(report.outcome == .loaded)
        #expect(report.diagnostics.isEmpty)
        #expect(report.activeEntryCount == 1)
        #expect(
            registry.effectiveChord(for: .commandPalette)
                == UserKeybindingRegistry.parse("cmd+p")
        )
    }

    @Test func retiredSearchCommandsDoNotRejectOtherBindings() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        let registry = UserKeybindingRegistry()
        try write(
            """
            [
              {"command": "quickOpen", "key": "cmd+p"},
              {"command": "findInProject", "key": "cmd+shift+f"},
              {"command": "findInFile", "key": "cmd+f"},
              {"command": "findAndReplace", "key": "cmd+option+f"},
              {"command": "findNext", "key": "cmd+g"},
              {"command": "findPrevious", "key": "cmd+shift+g"},
              {"command": "useSelectionForFind", "key": "cmd+e"},
              {"command": "goToLine", "key": "cmd+l"},
              {"command": "symbolNavigator", "key": "not a chord"},
              {"command": "commandPalette", "key": "cmd+option+p"}
            ]
            """,
            to: file
        )

        let report = await registry.load(from: file)

        #expect(report.outcome == .loaded)
        #expect(report.diagnostics.isEmpty)
        #expect(report.activeEntryCount == 1)
        #expect(registry.entries.map(\.command) == [.commandPalette])
        #expect(
            registry.effectiveChord(for: .commandPalette)
                == UserKeybindingRegistry.parse("cmd+option+p")
        )
    }

    /// Function-key chords carry no dispatch modifier, but are not text input.
    @Test func functionKeyChordsLoadAsRebindsNotTextInput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        let registry = UserKeybindingRegistry()
        try write(
            """
            [
              {"command": "commandPalette", "key": "f8"},
              {"command": "toggleComment", "key": "shift+f8"}
            ]
            """,
            to: file
        )

        let report = await registry.load(from: file)

        #expect(report.outcome == .loaded)
        #expect(report.diagnostics.isEmpty)
        #expect(report.activeEntryCount == 2)
        #expect(
            registry.effectiveChord(for: .commandPalette)
                == UserKeybindingRegistry.parse("f8")
        )
        #expect(
            registry.effectiveChord(for: .toggleComment)
                == UserKeybindingRegistry.parse("shift+f8")
        )
    }

    @Test func namedKeybindingsMatchAppKitKeyEvents() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        let registry = UserKeybindingRegistry()
        try write(
            """
            [
              {"command": "commandPalette", "key": "cmd+return"},
              {"command": "save", "key": "ctrl+esc"},
              {"command": "toggleComment", "key": "cmd+up"},
              {"command": "nextChange", "key": "cmd+delete"}
            ]
            """,
            to: file
        )
        #expect((await registry.load(from: file)).outcome == .loaded)

        let returnEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        let escapeEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .capsLock],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        ))
        let keypadReturnEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .numericPad],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 76
        ))
        let upArrowEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .numericPad, .function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 126
        ))
        let forwardDeleteEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}",
            isARepeat: false,
            keyCode: 117
        ))

        #expect(registry.command(for: returnEvent) == .commandPalette)
        #expect(registry.command(for: escapeEvent) == .save)
        #expect(registry.command(for: keypadReturnEvent) == .commandPalette)
        #expect(registry.command(for: upArrowEvent) == .toggleComment)
        #expect(registry.command(for: forwardDeleteEvent) == .nextChange)
        #expect(UserKeybindingRegistry.keyToken(
            keyCode: 0,
            charactersIgnoringModifiers: "P"
        ) == "p")
        #expect(UserKeybindingRegistry.keyToken(
            keyCode: 0,
            charactersIgnoringModifiers: nil
        ) == nil)
    }

    @Test(arguments: [
        (UInt16(36), "return"),
        (UInt16(76), "return"),
        (UInt16(48), "tab"),
        (UInt16(51), "delete"),
        (UInt16(117), "delete"),
        (UInt16(53), "esc"),
        (UInt16(49), "space"),
        (UInt16(123), "left"),
        (UInt16(124), "right"),
        (UInt16(125), "down"),
        (UInt16(126), "up"),
    ])
    func namedKeyCodesUseCanonicalTokens(keyCode: UInt16, expected: String) {
        #expect(UserKeybindingRegistry.keyToken(
            keyCode: keyCode,
            charactersIgnoringModifiers: nil
        ) == expected)
    }

    @Test func malformedAndUnreadableKeybindingsKeepTheLastValidRegistry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        let registry = UserKeybindingRegistry()
        try write(
            """
            [{"command": "commandPalette", "key": "cmd+p"}]
            """,
            to: file
        )
        #expect((await registry.load(from: file)).outcome == .loaded)

        try write("{", to: file)
        let malformed = await registry.load(from: file)
        #expect(malformed.outcome == .rejected)
        #expect(malformed.diagnostics.count == 1)
        #expect(malformed.diagnostics[0].entryNumber == nil)
        if case .malformedDocument = malformed.diagnostics[0].reason {
            // Expected.
        } else {
            Issue.record("Expected malformed-document diagnostic")
        }
        #expect(registry.entries.map { $0.command } == [.commandPalette])

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let unreadable = await registry.load(from: file)
        #expect(unreadable.outcome == .rejected)
        if case .unreadable = unreadable.diagnostics[0].reason {
            // Expected.
        } else {
            Issue.record("Expected unreadable-file diagnostic")
        }
        #expect(registry.entries.map { $0.command } == [.commandPalette])
    }

    @Test func missingKeybindingsApplyAnEmptyRegistry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        let registry = UserKeybindingRegistry()
        try write(
            """
            [{"command": "commandPalette", "key": "cmd+p"}]
            """,
            to: file
        )
        #expect((await registry.load(from: file)).outcome == .loaded)
        try FileManager.default.removeItem(at: file)

        let report = await registry.load(from: file)

        #expect(report.outcome == .missing)
        #expect(report.wasApplied)
        #expect(report.activeEntryCount == 0)
        #expect(registry.isEmpty)
    }

    @Test func tasksLoadEnvelopeAndBareArrayDocuments() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.json")
        let registry = UserTaskRegistry()
        try write(
            """
            {
              "tasks": [
                {"id": "lint", "label": "Lint", "command": "swiftlint"}
              ]
            }
            """,
            to: file
        )

        let envelopeReport = await registry.load(from: file)
        #expect(envelopeReport.outcome == .loaded)
        #expect(envelopeReport.activeEntryCount == 1)
        #expect(registry.task(forID: "lint")?.label == "Lint")

        try write(
            """
            [
              {"id": "build", "label": "Build", "command": "swift build"},
              {"id": "test", "label": "Test", "command": "swift test"}
            ]
            """,
            to: file
        )

        let arrayReport = await registry.load(from: file)
        #expect(arrayReport.outcome == .loaded)
        #expect(arrayReport.activeEntryCount == 2)
        #expect(registry.tasks.map(\.id) == ["build", "test"])
    }

    @Test func invalidTasksRejectTheWholeDocument() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.json")
        let registry = UserTaskRegistry()
        try write(
            """
            [{"id": "lint", "label": "Lint", "command": "swiftlint"}]
            """,
            to: file
        )
        #expect((await registry.load(from: file)).outcome == .loaded)

        try write(
            """
            [
              {"id": "duplicate", "label": "", "command": ""},
              {"id": "duplicate", "label": "Second", "command": "echo second"},
              {"id": " ", "label": "Whitespace ID", "command": "echo third"}
            ]
            """,
            to: file
        )

        let report = await registry.load(from: file)

        #expect(report.outcome == .rejected)
        #expect(report.activeEntryCount == 1)
        #expect(report.diagnostics.map(\.reason).contains(.emptyTaskLabel))
        #expect(report.diagnostics.map(\.reason).contains(.emptyTaskCommand))
        #expect(report.diagnostics.map(\.reason).contains(
            .duplicateTaskID(id: "duplicate", firstEntryNumber: 1)
        ))
        #expect(report.diagnostics.map(\.reason).contains(.emptyTaskID))
        #expect(registry.tasks.map(\.id) == ["lint"])
    }

    @Test func malformedTasksStayActiveUntilTheFileIsRemoved() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.json")
        let registry = UserTaskRegistry()
        try write(
            """
            [{"id": "lint", "label": "Lint", "command": "swiftlint"}]
            """,
            to: file
        )
        #expect((await registry.load(from: file)).outcome == .loaded)

        try write(#"{"tasks": "not-an-array"}"#, to: file)
        let malformed = await registry.load(from: file)
        #expect(malformed.outcome == .rejected)
        #expect(registry.tasks.map(\.id) == ["lint"])

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let unreadable = await registry.load(from: file)
        #expect(unreadable.outcome == .rejected)
        if case .unreadable = unreadable.diagnostics[0].reason {
            // Expected.
        } else {
            Issue.record("Expected unreadable-file diagnostic")
        }
        #expect(registry.tasks.map(\.id) == ["lint"])

        try FileManager.default.removeItem(at: file)
        let missing = await registry.load(from: file)
        #expect(missing.outcome == .missing)
        #expect(registry.tasks.isEmpty)
    }

    @Test func managerReloadsEachFileAtomicallyAndRetainsDiagnostics() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tasksFile = directory.appendingPathComponent("tasks.json")
        let keybindingsFile = directory.appendingPathComponent("keybindings.json")
        try write(
            """
            [{"id": "lint", "label": "Lint", "command": "swiftlint"}]
            """,
            to: tasksFile
        )
        try write(
            """
            [{"command": "commandPalette", "key": "cmd+p"}]
            """,
            to: keybindingsFile
        )
        let manager = ExtensibilityManager(
            tasksFileURL: tasksFile,
            keybindingsFileURL: keybindingsFile
        )
        let initialReport = await manager.reload()
        #expect(initialReport != nil)
        #expect(manager.tasks.count == 1)
        #expect(manager.keybindings.count == 1)

        try write(
            """
            [
              {"id": "build", "label": "Build", "command": "swift build"},
              {"id": "test", "label": "Test", "command": "swift test"}
            ]
            """,
            to: tasksFile
        )
        try write("{", to: keybindingsFile)

        let loadedReport = await manager.reload()
        let report = try #require(loadedReport)

        #expect(report.tasks.outcome == .loaded)
        #expect(report.tasks.activeEntryCount == 2)
        #expect(report.keybindings.outcome == .rejected)
        #expect(report.keybindings.activeEntryCount == 1)
        #expect(report.diagnostics.count == 1)
        #expect(manager.tasks.tasks.map(\.id) == ["build", "test"])
        #expect(manager.keybindings.entries.map { $0.command } == [.commandPalette])
        #expect(manager.lastReloadReport == report)
    }

    @Test func newerReloadDiscardsAnOlderCandidate() async {
        let controlledLoader = ControlledTaskConfigurationLoader()
        let manager = ExtensibilityManager(
            tasksFileURL: URL(fileURLWithPath: "/unused/tasks.json"),
            keybindingsFileURL: URL(fileURLWithPath: "/unused/keybindings.json"),
            taskLoader: { _ in
                await controlledLoader.load()
            },
            keybindingLoader: { _ in
                .missing
            }
        )

        let firstReload = Task { @MainActor in
            await manager.reload()
        }
        await controlledLoader.waitUntilFirstLoadStarts()

        let secondReport = await manager.reload()
        #expect(secondReport?.tasks.outcome == .loaded)
        #expect(manager.tasks.tasks.map(\.id) == ["new"])

        await controlledLoader.releaseFirstLoad()
        let supersededReport = await firstReload.value

        #expect(supersededReport == nil)
        #expect(manager.tasks.tasks.map(\.id) == ["new"])
        #expect(manager.lastReloadReport == secondReport)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-user-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }
}

private actor ControlledTaskConfigurationLoader {
    private var callCount = 0
    private var firstLoadStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstLoadRelease: CheckedContinuation<Void, Never>?

    func load() async -> UserConfigurationCandidate<UserTask> {
        callCount += 1
        guard callCount == 1 else {
            return .loaded([
                UserTask(id: "new", label: "New", command: "echo new")
            ])
        }

        firstLoadStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstLoadRelease = continuation
        }
        return .loaded([
            UserTask(id: "old", label: "Old", command: "echo old")
        ])
    }

    func waitUntilFirstLoadStarts() async {
        guard !firstLoadStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstLoad() {
        firstLoadRelease?.resume()
        firstLoadRelease = nil
    }
}
