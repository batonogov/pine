//
//  AsyncFormatOnSaveTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Async format-on-save", .serialized)
@MainActor
struct AsyncFormatOnSaveTests {
    @Test("main-actor heartbeat continues while an external formatter waits")
    func mainActorRemainsResponsive() async throws {
        let probe = DelayedFormatterProbe(waitForRelease: true)
        let (manager, url) = try makeManager(probe: probe)
        defer { try? FileManager.default.removeItem(at: url) }

        manager.updateContent("draft")
        let save = Task { @MainActor in
            try await manager.trySaveTabAsync(at: 0)
        }
        try await waitUntil { probe.hasStarted }

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(!probe.hasFinished)
        #expect(!probe.ranOnMainThread)
        probe.release()
        let didSave = try await save.value
        #expect(didSave)
        #expect(manager.activeTab?.content == "FORMATTED: draft")
    }

    @Test("an edit made during formatting invalidates stale output")
    func staleFormatterOutputIsDiscarded() async throws {
        let probe = DelayedFormatterProbe(delay: 0.25)
        let (manager, url) = try makeManager(probe: probe)
        defer { try? FileManager.default.removeItem(at: url) }

        manager.updateContent("captured")
        let save = Task { @MainActor in
            try await manager.trySaveTabAsync(at: 0)
        }
        try await waitUntil { probe.hasStarted }
        manager.updateContent("newer edit")

        let didSave = try await save.value
        #expect(!didSave)
        #expect(manager.activeTab?.content == "newer edit")
        #expect(manager.activeTab?.isDirty == true)
        #expect(try String(contentsOf: url, encoding: .utf8) == "original")
    }

    @Test("an external edit during formatting is not overwritten")
    func externalEditDuringFormattingIsRejected() async throws {
        let probe = DelayedFormatterProbe(waitForRelease: true)
        let (manager, url) = try makeManager(probe: probe)
        defer { try? FileManager.default.removeItem(at: url) }

        manager.updateContent("local edits")
        let save = Task { @MainActor in
            try await manager.trySaveTabAsync(at: 0)
        }
        try await waitUntil { probe.hasStarted }
        try "external edits".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        probe.release()

        do {
            _ = try await save.value
            Issue.record("Expected the external disk revision to reject the save")
        } catch let TabPersistence.SaveError.externalChange(conflict) {
            #expect(conflict.url == url)
            #expect(conflict.kind == .modified)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "external edits")
        #expect(manager.activeTab?.content == "local edits")
        #expect(manager.activeTab?.isDirty == true)
    }

    @Test("Save All uses the background formatter path")
    func saveAllUsesBackgroundPreparation() async throws {
        let probe = DelayedFormatterProbe(delay: 0.2)
        let project = ProjectManager()
        let manager = project.activeTabManager
        let url = try configure(manager, probe: probe)
        defer { try? FileManager.default.removeItem(at: url) }

        manager.updateContent("save all")
        let save = Task { @MainActor in
            await project.saveAllPaneTabs(context: .unscoped)
        }
        try await waitUntil { probe.hasStarted }

        #expect(!probe.ranOnMainThread)
        let didSave = await save.value
        #expect(didSave)
        #expect(try String(contentsOf: url, encoding: .utf8) == "FORMATTED: save all")
    }

    @Test("auto-save uses the background formatter path")
    func autoSaveUsesBackgroundPreparation() async throws {
        let probe = DelayedFormatterProbe(delay: 0.2)
        let (manager, url) = try makeManager(probe: probe)
        defer { try? FileManager.default.removeItem(at: url) }
        manager.autoSavePreferenceProvider = { true }
        manager.setAutoSaveDelay(0.01)

        manager.updateContent("auto save")
        try await waitUntil { probe.hasStarted }
        #expect(manager.isAutoSaving)
        #expect(!probe.ranOnMainThread)
        try await waitUntil { manager.activeTab?.isDirty == false }

        #expect(try String(contentsOf: url, encoding: .utf8) == "FORMATTED: auto save")
        #expect(!manager.isAutoSaving)
    }

    private func makeManager(
        probe: DelayedFormatterProbe
    ) throws -> (TabManager, URL) {
        let manager = TabManager()
        return (manager, try configure(manager, probe: probe))
    }

    private func configure(
        _ manager: TabManager,
        probe: DelayedFormatterProbe
    ) throws -> URL {
        let suiteName = "AsyncFormatOnSaveTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = true
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false
        manager.editorSettings = settings
        manager.fileFormatters = FileFormatterRegistry(formatters: [
            ExternalFileFormatter(
                toolPath: "/mock/delayed-formatter",
                toolName: "delayed-formatter",
                extensions: ["asyncfmt"],
                arguments: [],
                processRunner: probe.run
            )
        ])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("async-save-\(UUID().uuidString).asyncfmt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        manager.openTab(url: url)
        return url
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }
}

nonisolated final class DelayedFormatterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private let releaseGate: DispatchSemaphore?
    private var started = false
    private var finished = false
    private var executedOnMainThread = false

    init(delay: TimeInterval) {
        self.delay = delay
        self.releaseGate = nil
    }

    init(waitForRelease: Bool) {
        self.delay = 0
        self.releaseGate = waitForRelease ? DispatchSemaphore(value: 0) : nil
    }

    var hasStarted: Bool {
        lock.withLock { started }
    }

    var hasFinished: Bool {
        lock.withLock { finished }
    }

    var ranOnMainThread: Bool {
        lock.withLock { executedOnMainThread }
    }

    func release() {
        releaseGate?.signal()
    }

    func run(
        executablePath: String,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        lock.withLock {
            started = true
            executedOnMainThread = Thread.isMainThread
        }
        if let releaseGate {
            _ = releaseGate.wait(timeout: .now() + 5)
        } else {
            Thread.sleep(forTimeInterval: min(delay, timeout))
        }
        lock.withLock { finished = true }
        return ProcessRunResult(
            stdout: "FORMATTED: \(stdin)",
            stderr: "",
            exitCode: 0,
            timedOut: false
        )
    }
}
