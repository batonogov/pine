//
//  UserConfigurationEditorTests.swift
//  PineTests
//
//  Issue #1117: verifies starter-file generation and the no-overwrite rule
//  for user configuration files (keybindings.json / tasks.json).
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("User configuration editor & starter files")
nonisolated struct UserConfigurationEditorTests {

    @Test("Keybindings starter is valid JSON with an empty registry")
    func keybindingsStarterIsValid() throws {
        let content = UserConfigurationEditor.starterContent(for: .keybindings)
        let data = Data(content.utf8)

        // Must be parseable JSON...
        let object = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(object as? [String: Any])
        // ...document guidance lives in a `_comment` field...
        let comment = try #require(dict["_comment"] as? String)
        for command in UserCommand.allCases {
            #expect(comment.contains(command.rawValue))
        }
        // ...and the `keybindings` array is empty (no accidental bindings).
        let entries = try #require(dict["keybindings"] as? [Any])
        #expect(entries.isEmpty)
    }

    @Test("Tasks starter is valid JSON with an empty task list")
    func tasksStarterIsValid() throws {
        let content = UserConfigurationEditor.starterContent(for: .tasks)
        let data = Data(content.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(object as? [String: Any])
        let comment = try #require(dict["_comment"] as? String)
        #expect(comment.contains("replaces_file_content"))
        #expect(!comment.contains("stdout does not currently replace"))
        let entries = try #require(dict["tasks"] as? [Any])
        #expect(entries.isEmpty)
    }

    @Test("A freshly-created keybindings starter reloads with no diagnostics")
    @MainActor
    func keybindingsStarterReloadsCleanly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        try Data(UserConfigurationEditor.starterContent(for: .keybindings).utf8)
            .write(to: file)

        let registry = UserKeybindingRegistry()
        let report = await registry.load(from: file)
        #expect(report.outcome == .loaded)
        #expect(report.diagnostics.isEmpty)
        #expect(registry.isEmpty)
    }

    @Test("A freshly-created tasks starter reloads with no diagnostics")
    @MainActor
    func tasksStarterReloadsCleanly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.json")
        try Data(UserConfigurationEditor.starterContent(for: .tasks).utf8)
            .write(to: file)

        let registry = UserTaskRegistry()
        let report = await registry.load(from: file)
        #expect(report.outcome == .loaded)
        #expect(report.diagnostics.isEmpty)
        #expect(registry.tasks.isEmpty)
    }

    @Test("ensureStarterFileExists creates when missing and reports creation")
    func starterCreatedWhenMissing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("keybindings.json")

        let created = try await UserConfigurationEditor.ensureStarterFileExists(
            .keybindings,
            at: fileURL
        )

        #expect(created)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let data = try Data(contentsOf: fileURL)
        _ = try JSONSerialization.jsonObject(with: data)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        #expect(
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        )
    }

    @Test("ensureStarterFileExists does not overwrite an existing file")
    func starterDoesNotOverwrite() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        let userContent = Data(#"[{"id":"mine","label":"Mine","command":"echo hi"}]"#.utf8)
        try userContent.write(to: fileURL)

        let created = try await UserConfigurationEditor.ensureStarterFileExists(
            .tasks,
            at: fileURL
        )

        #expect(!created)
        let onDisk = try Data(contentsOf: fileURL)
        #expect(onDisk == userContent)
    }

    @Test("Exclusive creation never overwrites a racing contender")
    func racingCreationHasOneWinner() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        let creator = ExclusiveUserConfigurationFileCreator()
        let results = StarterCreationRaceResults()
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        for data in [Data("first".utf8), Data("second".utf8)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                start.wait()
                do {
                    let created = try creator.createIfMissing(
                        data: data,
                        at: fileURL
                    )
                    results.record(.success(created))
                } catch {
                    results.record(.failure(error))
                }
                group.leave()
            }
        }
        start.signal()
        start.signal()
        group.wait()

        let values = try results.values.map { try $0.get() }
        #expect(values.filter(\.self).count == 1)
        #expect(values.filter { !$0 }.count == 1)
        let content = try Data(contentsOf: fileURL)
        #expect(content == Data("first".utf8) || content == Data("second".utf8))
    }

    @Test("Symlink destination is rejected without changing its target")
    func symlinkDestinationIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.json")
        let fileURL = directory.appendingPathComponent("tasks.json")
        let original = Data("user-owned".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fileURL,
            withDestinationURL: target
        )

        await #expect(throws: POSIXError.self) {
            try await UserConfigurationEditor.ensureStarterFileExists(
                .tasks,
                at: fileURL
            )
        }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test("Symlink parent directory is rejected")
    func symlinkParentIsRejected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: realDirectory
        )

        await #expect(throws: POSIXError.self) {
            try await UserConfigurationEditor.ensureStarterFileExists(
                .keybindings,
                at: linkedDirectory.appendingPathComponent("keybindings.json")
            )
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: realDirectory
                    .appendingPathComponent("keybindings.json")
                    .path
            )
        )
    }

    @Test("Non-regular destination is rejected")
    func nonRegularDestinationIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        try FileManager.default.createDirectory(
            at: fileURL,
            withIntermediateDirectories: false
        )

        await #expect(throws: POSIXError.self) {
            try await UserConfigurationEditor.ensureStarterFileExists(
                .tasks,
                at: fileURL
            )
        }
    }

    @Test("Starter creation executes away from the main thread")
    func starterCreationIsOffMain() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("keybindings.json")
        let creator = ThreadRecordingConfigurationFileCreator()

        _ = try await UserConfigurationEditor.ensureStarterFileExists(
            .keybindings,
            at: fileURL,
            creator: creator
        )

        #expect(creator.wasCalled)
        #expect(!creator.wasCalledOnMainThread)
    }

    @Test("Open success creates, opens, and does not present an alert")
    @MainActor
    func openSuccess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("keybindings.json")
        let opener = RecordingConfigurationOpener(result: true)
        let presenter = RecordingConfigurationAlertPresenter()

        let outcome = await UserConfigurationEditor.open(
            .keybindings,
            at: fileURL,
            opener: opener,
            alertPresenter: presenter
        )

        #expect(outcome == .opened(createdStarter: true))
        #expect(opener.openedURLs == [fileURL])
        #expect(presenter.descriptors.isEmpty)
    }

    @Test("Creation failure presents one dismissible warning")
    @MainActor
    func openCreationFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        try FileManager.default.createDirectory(
            at: fileURL,
            withIntermediateDirectories: false
        )
        let opener = RecordingConfigurationOpener(result: true)
        let presenter = RecordingConfigurationAlertPresenter()

        let outcome = await UserConfigurationEditor.open(
            .tasks,
            at: fileURL,
            opener: opener,
            alertPresenter: presenter
        )

        #expect(outcome == .creationFailed)
        #expect(opener.openedURLs.isEmpty)
        #expect(presenter.descriptors.count == 1)
        #expect(presenter.descriptors[0].style == .warning)
        #expect(presenter.dismissalCount == 1)
        #expect(!presenter.isPresenting)
    }

    @Test("Workspace open failure is visible and dismissible")
    @MainActor
    func workspaceOpenFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        let opener = RecordingConfigurationOpener(result: false)
        let presenter = RecordingConfigurationAlertPresenter()

        let outcome = await UserConfigurationEditor.open(
            .tasks,
            at: fileURL,
            opener: opener,
            alertPresenter: presenter
        )

        #expect(outcome == .openFailed)
        #expect(opener.openedURLs == [fileURL])
        #expect(presenter.descriptors.count == 1)
        #expect(presenter.descriptors[0].style == .warning)
        #expect(presenter.descriptors[0].informativeText.contains("tasks"))
        #expect(presenter.dismissalCount == 1)
        #expect(!presenter.isPresenting)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }
}

nonisolated private final class StarterCreationRaceResults:
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Result<Bool, Error>] = []

    var values: [Result<Bool, Error>] {
        lock.withLock { storedValues }
    }

    func record(_ result: Result<Bool, Error>) {
        lock.withLock {
            storedValues.append(result)
        }
    }
}

nonisolated private final class ThreadRecordingConfigurationFileCreator:
    UserConfigurationFileCreating,
    @unchecked Sendable {
    private let lock = NSLock()
    private var callThreads: [Bool] = []

    var wasCalled: Bool {
        lock.withLock { !callThreads.isEmpty }
    }

    var wasCalledOnMainThread: Bool {
        lock.withLock { callThreads.contains(true) }
    }

    func createIfMissing(data: Data, at url: URL) throws -> Bool {
        lock.withLock {
            callThreads.append(Thread.isMainThread)
        }
        return try ExclusiveUserConfigurationFileCreator().createIfMissing(
            data: data,
            at: url
        )
    }
}

@MainActor
private final class RecordingConfigurationOpener: UserConfigurationOpening {
    private let result: Bool
    private(set) var openedURLs: [URL] = []

    init(result: Bool) {
        self.result = result
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return result
    }
}

@MainActor
private final class RecordingConfigurationAlertPresenter:
    UserConfigurationAlertPresenting {
    private(set) var descriptors: [UserConfigurationAlertDescriptor] = []
    private(set) var dismissalCount = 0
    private(set) var isPresenting = false

    func present(
        _ descriptor: UserConfigurationAlertDescriptor
    ) async -> NSApplication.ModalResponse {
        isPresenting = true
        descriptors.append(descriptor)
        dismissalCount += 1
        isPresenting = false
        return .alertFirstButtonReturn
    }
}
