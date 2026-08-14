//
//  ApplicationLifecycleProcessTests.swift
//  PineTests
//

import Darwin
import Foundation
import Testing

@testable import Pine

nonisolated private enum ApplicationLifecycleHarnessError:
    Error, CustomStringConvertible {
    case launchFailed
    case processIdentityUnavailable
    case phaseTimedOut(String)
    case driverFailed(String)
    case unexpectedExit(String)

    var description: String {
        switch self {
        case .launchFailed:
            "Pine lifecycle harness could not launch the app process"
        case .processIdentityUnavailable:
            "Pine lifecycle harness could not capture an exact app identity"
        case .phaseTimedOut(let phase):
            "Pine lifecycle harness timed out in phase: \(phase)"
        case .driverFailed(let code):
            "Pine lifecycle driver failed with sanitized code: \(code)"
        case .unexpectedExit(let phase):
            "Pine lifecycle process exited unexpectedly in phase: \(phase)"
        }
    }
}

nonisolated private struct ApplicationLifecycleProcessExit: Sendable {
    let reason: Process.TerminationReason
    let status: Int32
}

nonisolated private final class ApplicationLifecycleLaunchedProcess:
    @unchecked Sendable {
    let process: Process
    let identity: UserTaskProcessIdentity
    let stateDirectory: URL

    private let standardOutputHandle: FileHandle
    private let standardErrorHandle: FileHandle

    init(
        executableURL: URL,
        configuration: ApplicationLifecycleProcessConfiguration,
        stateDirectory: URL,
        pauseAtSessionCheckpoint: Bool = false
    ) throws {
        self.stateDirectory = stateDirectory
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        let configurationURL = stateDirectory.appending(path: "config.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(configuration).write(
            to: configurationURL,
            options: .atomic
        )

        let stdoutURL = stateDirectory.appending(path: "stdout.log")
        let stderrURL = stateDirectory.appending(path: "stderr.log")
        FileManager.default.createFile(
            atPath: stdoutURL.path,
            contents: nil
        )
        FileManager.default.createFile(
            atPath: stderrURL.path,
            contents: nil
        )
        standardOutputHandle = try FileHandle(forWritingTo: stdoutURL)
        standardErrorHandle = try FileHandle(forWritingTo: stderrURL)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--application-lifecycle-process-test",
            "--disable-agent-detection",
            "--disable-metal",
            "--disable-quick-terminal",
            "--disable-terminal-seeding",
            "-ApplePersistenceIgnoreState",
            "YES",
        ]
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "XCInjectBundleInto",
            "XCTestBundlePath",
            "XCTestConfigurationFilePath",
            "DYLD_INSERT_LIBRARIES",
            "LLVM_PROFILE_FILE",
        ] {
            environment.removeValue(forKey: key)
        }
        environment["PINE_APPLICATION_LIFECYCLE_CONFIG"] =
            configurationURL.path
        environment["PINE_DISABLE_AGENT_DETECTION"] = "1"
        environment["PINE_DISABLE_METAL"] = "1"
        environment["PINE_DISABLE_QUICK_TERMINAL"] = "1"
        if pauseAtSessionCheckpoint {
            environment["PINE_PERSISTENCE_PAUSE"] =
                "session:before-atomic-replace"
            environment["PINE_PERSISTENCE_CHECKPOINT_DIRECTORY"] =
                stateDirectory.path
        }
        process.environment = environment
        process.standardOutput = standardOutputHandle
        process.standardError = standardErrorHandle

        do {
            try process.run()
        } catch {
            standardOutputHandle.closeFile()
            standardErrorHandle.closeFile()
            throw ApplicationLifecycleHarnessError.launchFailed
        }
        self.process = process

        let deadline = DispatchTime.now() + .seconds(2)
        var capturedIdentity: UserTaskProcessIdentity?
        repeat {
            capturedIdentity = UserTaskProcessInspector.identity(
                for: process.processIdentifier
            )
            if capturedIdentity != nil { break }
            Darwin.usleep(10_000)
        } while DispatchTime.now() < deadline
        guard let capturedIdentity else {
            if process.isRunning {
                process.terminate()
            }
            throw ApplicationLifecycleHarnessError
                .processIdentityUnavailable
        }
        identity = capturedIdentity
    }

    deinit {
        standardOutputHandle.closeFile()
        standardErrorHandle.closeFile()
    }

    func evidence(
        phase: String,
        timeout: TimeInterval = 10
    ) async throws -> ApplicationLifecycleProcessEvidence {
        let eventURL = stateDirectory
            .appending(path: "events", directoryHint: .isDirectory)
            .appending(path: phase + ".json")
        let failureURL = stateDirectory
            .appending(path: "events", directoryHint: .isDirectory)
            .appending(path: "driver-failed.json")
        let deadline = DispatchTime.now() + timeout
        while DispatchTime.now() < deadline {
            if let failure = Self.decodeEvidence(at: failureURL) {
                throw ApplicationLifecycleHarnessError.driverFailed(
                    failure.failureCode ?? "unspecified"
                )
            }
            if let evidence = Self.decodeEvidence(at: eventURL) {
                return evidence
            }
            if !process.isRunning {
                throw ApplicationLifecycleHarnessError.unexpectedExit(
                    phase
                )
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw ApplicationLifecycleHarnessError.phaseTimedOut(phase)
    }

    func waitForFile(
        named name: String,
        timeout: TimeInterval = 10
    ) async throws -> URL {
        let url = stateDirectory.appending(path: name)
        let deadline = DispatchTime.now() + timeout
        while DispatchTime.now() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return url }
            if !process.isRunning {
                throw ApplicationLifecycleHarnessError.unexpectedExit(name)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw ApplicationLifecycleHarnessError.phaseTimedOut(name)
    }

    func sendCommand(_ name: String) async throws {
        let directory = stateDirectory.appending(
            path: "commands",
            directoryHint: .isDirectory
        )
        let destination = directory.appending(path: name)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data().write(to: destination, options: .atomic)
        }.value
    }

    func waitForExit(timeout: TimeInterval = 10) async throws
        -> ApplicationLifecycleProcessExit {
        let process = process
        let deadline = DispatchTime.now() + timeout
        while process.isRunning, DispatchTime.now() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !process.isRunning else {
            throw ApplicationLifecycleHarnessError.phaseTimedOut(
                "process-exit"
            )
        }
        await Task.detached(priority: .utility) {
            process.waitUntilExit()
        }.value
        standardOutputHandle.synchronizeFile()
        standardErrorHandle.synchronizeFile()
        return ApplicationLifecycleProcessExit(
            reason: process.terminationReason,
            status: process.terminationStatus
        )
    }

    func killIfRunning(signal: Int32 = SIGKILL) {
        guard process.isRunning,
              UserTaskProcessInspector.identity(
                for: identity.processID
              ) == identity else { return }
        _ = Darwin.kill(identity.processID, signal)
    }

    nonisolated private static func decodeEvidence(
        at url: URL
    ) -> ApplicationLifecycleProcessEvidence? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(
            ApplicationLifecycleProcessEvidence.self,
            from: data
        )
    }
}

@Suite("Application lifecycle process gate", .serialized)
struct ApplicationLifecycleProcessTests {
    private struct PersistenceCheckpoint: Codable {
        let store: String
        let phase: String
        let processIdentifier: Int32
    }

    private struct Fixture {
        let project: URL
        let primaryFile: URL
        let secondaryFile: URL
        let defaultsSuite: String
        let terminalFixture: URL
    }

    @Test("quit, crash, and relaunch preserve the durable lifecycle contract")
    func quitCrashAndRelaunchJourney() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pine-application-lifecycle-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let project = root.appending(
            path: "Lifecycle Project",
            directoryHint: .isDirectory
        )
        let primaryFile = project.appending(path: "committed.swift")
        let secondaryFile = project.appending(path: "interrupted.swift")
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        try "// initial lifecycle fixture\n".write(
            to: primaryFile,
            atomically: true,
            encoding: .utf8
        )
        try "// secondary lifecycle fixture\n".write(
            to: secondaryFile,
            atomically: true,
            encoding: .utf8
        )
        let defaultsSuite =
            "PineTests.ApplicationLifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        let executableURL = try #require(Bundle.main.executableURL)
        let terminalFixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/Terminal/pty-process-tree.sh")
        let fixture = Fixture(
            project: project,
            primaryFile: primaryFile,
            secondaryFile: secondaryFile,
            defaultsSuite: defaultsSuite,
            terminalFixture: terminalFixture
        )

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        let unrelatedIdentity = try #require(
            UserTaskProcessInspector.identity(
                for: unrelated.processIdentifier
            )
        )

        var launchedProcesses: [ApplicationLifecycleLaunchedProcess] = []
        var ownedTerminalIdentities: [UserTaskProcessIdentity] = []
        defer {
            retainSanitizedDiagnostics(from: root)
            for launched in launchedProcesses {
                launched.killIfRunning()
            }
            for identity in ownedTerminalIdentities where
                    UserTaskProcessInspector.identity(
                        for: identity.processID
                    ) == identity {
                _ = Darwin.kill(identity.processID, SIGKILL)
            }
            if unrelated.isRunning,
               UserTaskProcessInspector.identity(
                for: unrelatedIdentity.processID
               ) == unrelatedIdentity {
                unrelated.terminate()
                unrelated.waitUntilExit()
            }
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }

        let interactiveState = root.appending(
            path: "generation-1",
            directoryHint: .isDirectory
        )
        let interactiveConfiguration = makeConfiguration(
            scenario: .interactiveQuit,
            stateDirectory: interactiveState,
            fixture: fixture
        )
        let first = try ApplicationLifecycleLaunchedProcess(
            executableURL: executableURL,
            configuration: interactiveConfiguration,
            stateDirectory: interactiveState
        )
        launchedProcesses.append(first)

        let ready = try await first.evidence(phase: "interactive-ready")
        #expect(ready.dirtyContentPresent == true)
        #expect(ready.terminalRunning == true)
        #expect(ready.windowVisible == true)
        let rootIdentity = try #require(
            ready.terminalRoot?.userTaskIdentity
        )
        let childIdentity = try #require(
            ready.terminalChild?.userTaskIdentity
        )
        ownedTerminalIdentities.append(contentsOf: [
            rootIdentity,
            childIdentity,
        ])
        #expect(identityIsLive(rootIdentity))
        #expect(identityIsLive(childIdentity))

        let visible = try await first.evidence(
            phase: "confirmation-visible"
        )
        #expect(visible.confirmationVisible == true)
        try await first.sendCommand("replace-and-cancel")
        let replacement = try await first.evidence(
            phase: "replacement-while-confirming"
        )
        let replacementIdentity = try #require(
            replacement.terminalReplacement?.userTaskIdentity
        )
        ownedTerminalIdentities.append(replacementIdentity)
        #expect(replacement.confirmationVisible == true)
        #expect(replacement.terminalRunning == true)
        #expect(replacementIdentity != childIdentity)

        let cancelled = try await first.evidence(
            phase: "cancelled-usable"
        )
        #expect(cancelled.dirtyContentPresent == true)
        #expect(cancelled.terminalRunning == true)
        #expect(cancelled.windowVisible == true)
        #expect(cancelled.inputAccepted == true)

        try await first.sendCommand("retry-failure")
        let failedSave = try await first.evidence(
            phase: "save-failure-usable"
        )
        #expect(failedSave.dirtyContentPresent == true)
        #expect(failedSave.terminalRunning == true)
        #expect(failedSave.windowVisible == true)
        #expect(failedSave.inputAccepted == true)

        let livePineDescendants = descendantIdentities(of: first.identity)
        #expect(livePineDescendants.contains(rootIdentity))
        ownedTerminalIdentities.append(contentsOf: livePineDescendants)

        try await first.sendCommand("retry-success")
        let confirmed = try await first.evidence(
            phase: "confirmed-quit"
        )
        #expect(confirmed.dirtyContentPresent == false)
        #expect(confirmed.terminalRunning == false)
        #expect(confirmed.windowVisible == true)
        #expect(confirmed.savedToDisk == true)
        let firstExit = try await first.waitForExit()
        #expect(firstExit.reason == .exit)
        #expect(firstExit.status == 0)
        #expect(await waitUntilIdentitiesExit(ownedTerminalIdentities))
        #expect(identityIsLive(unrelatedIdentity))

        defaults.synchronize()
        let committedSession = try #require(SessionState.load(
            for: project,
            defaults: defaults
        ))
        #expect(
            committedSession.existingFileURLs.map(\.standardizedFileURL)
                == [primaryFile.standardizedFileURL]
        )

        let crashState = root.appending(
            path: "generation-2",
            directoryHint: .isDirectory
        )
        let crashConfiguration = makeConfiguration(
            scenario: .interruptedSessionSave,
            stateDirectory: crashState,
            fixture: fixture
        )
        let second = try ApplicationLifecycleLaunchedProcess(
            executableURL: executableURL,
            configuration: crashConfiguration,
            stateDirectory: crashState,
            pauseAtSessionCheckpoint: true
        )
        launchedProcesses.append(second)
        let crashReady = try await second.evidence(
            phase: "crash-generation-ready"
        )
        #expect(crashReady.restoredFileCount == 1)
        #expect(crashReady.restoredTerminalCount == 1)
        #expect(crashReady.staleProcessOwnership == false)
        _ = try await second.evidence(
            phase: "crash-termination-committed"
        )
        let checkpointURL = try await second.waitForFile(
            named: "persistence-checkpoint.json"
        )
        let checkpoint = try String(
            contentsOf: checkpointURL,
            encoding: .utf8
        )
        #expect(checkpoint.contains("\"store\":\"session\""))
        #expect(checkpoint.contains(
            "\"phase\":\"before-atomic-replace\""
        ))
        #expect(identityIsLive(second.identity))
        second.killIfRunning()
        let secondExit = try await second.waitForExit()
        #expect(secondExit.reason == .uncaughtSignal)
        #expect(secondExit.status == SIGKILL)

        let restoreState = root.appending(
            path: "generation-3",
            directoryHint: .isDirectory
        )
        let restoreConfiguration = makeConfiguration(
            scenario: .verifyRestoration,
            stateDirectory: restoreState,
            fixture: fixture
        )
        let third = try ApplicationLifecycleLaunchedProcess(
            executableURL: executableURL,
            configuration: restoreConfiguration,
            stateDirectory: restoreState
        )
        launchedProcesses.append(third)
        let restored = try await third.evidence(
            phase: "restoration-verified"
        )
        #expect(restored.savedToDisk == true)
        #expect(restored.restoredFileCount == 1)
        #expect(restored.restoredTerminalCount == 1)
        #expect(restored.staleProcessOwnership == false)
        let thirdExit = try await third.waitForExit()
        #expect(thirdExit.reason == .exit)
        #expect(thirdExit.status == 0)

        #expect(!identityIsLive(first.identity))
        #expect(!identityIsLive(second.identity))
        #expect(!identityIsLive(third.identity))
        #expect(await waitUntilIdentitiesExit(ownedTerminalIdentities))
        #expect(identityIsLive(unrelatedIdentity))
    }

    private func makeConfiguration(
        scenario: ApplicationLifecycleProcessScenario,
        stateDirectory: URL,
        fixture: Fixture
    ) -> ApplicationLifecycleProcessConfiguration {
        ApplicationLifecycleProcessConfiguration(
            scenario: scenario,
            stateDirectoryPath: stateDirectory.path,
            projectPath: fixture.project.path,
            primaryFilePath: fixture.primaryFile.path,
            secondaryFilePath: fixture.secondaryFile.path,
            defaultsSuiteName: fixture.defaultsSuite,
            terminalFixturePath: fixture.terminalFixture.path
        )
    }

    private func retainSanitizedDiagnostics(from root: URL) {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuredDestination = ProcessInfo.processInfo.environment[
            "PINE_LIFECYCLE_DIAGNOSTICS"
        ].flatMap { path in
            path.isEmpty ? nil : URL(
                fileURLWithPath: path,
                isDirectory: true
            )
        }
        let destination = configuredDestination ?? sourceRoot.appending(
            path: "LifecycleDiagnostics",
            directoryHint: .isDirectory
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for generation in ["generation-1", "generation-2", "generation-3"] {
            let source = root.appending(
                path: generation,
                directoryHint: .isDirectory
            )
            let retained = destination.appending(
                path: generation,
                directoryHint: .isDirectory
            )
            let events = source.appending(
                path: "events",
                directoryHint: .isDirectory
            )
            if let eventURLs = try? FileManager.default.contentsOfDirectory(
                at: events,
                includingPropertiesForKeys: nil
            ) {
                let retainedEvents = retained.appending(
                    path: "events",
                    directoryHint: .isDirectory
                )
                try? FileManager.default.createDirectory(
                    at: retainedEvents,
                    withIntermediateDirectories: true
                )
                for eventURL in eventURLs where
                        eventURL.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: eventURL),
                          let evidence = try? JSONDecoder().decode(
                              ApplicationLifecycleProcessEvidence.self,
                              from: data
                          ),
                          let sanitized = try? encoder.encode(evidence) else {
                        continue
                    }
                    try? sanitized.write(
                        to: retainedEvents.appending(
                            path: eventURL.lastPathComponent
                        ),
                        options: .atomic
                    )
                }
            }

            let checkpointURL = source.appending(
                path: "persistence-checkpoint.json"
            )
            guard let checkpointData = try? Data(contentsOf: checkpointURL),
                  let checkpoint = try? JSONDecoder().decode(
                      PersistenceCheckpoint.self,
                      from: checkpointData
                  ),
                  let sanitized = try? encoder.encode(checkpoint) else {
                continue
            }
            try? FileManager.default.createDirectory(
                at: retained,
                withIntermediateDirectories: true
            )
            try? sanitized.write(
                to: retained.appending(
                    path: "persistence-checkpoint.json"
                ),
                options: .atomic
            )
        }
    }

    nonisolated private func identityIsLive(
        _ identity: UserTaskProcessIdentity
    ) -> Bool {
        UserTaskProcessInspector.identity(for: identity.processID) == identity
    }

    nonisolated private func waitUntilIdentitiesExit(
        _ identities: [UserTaskProcessIdentity],
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = DispatchTime.now() + timeout
        while DispatchTime.now() < deadline {
            if identities.allSatisfy({ !identityIsLive($0) }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return identities.allSatisfy { !identityIsLive($0) }
    }

    nonisolated private func descendantIdentities(
        of root: UserTaskProcessIdentity
    ) -> [UserTaskProcessIdentity] {
        var pending = [root]
        var visited: Set<UserTaskProcessIdentity> = []
        var descendants: Set<UserTaskProcessIdentity> = []
        while let parent = pending.popLast(),
              visited.count < 1_024 {
            guard visited.insert(parent).inserted else { continue }
            for processIdentifier in childProcessIdentifiers(
                of: parent.processID
            ) {
                guard let child = UserTaskProcessInspector.identity(
                    for: processIdentifier,
                    expectedParent: parent.processID
                ) else { continue }
                descendants.insert(child)
                pending.append(child)
            }
        }
        return Array(descendants)
    }

    nonisolated private func childProcessIdentifiers(
        of parent: pid_t
    ) -> [pid_t] {
        let requestedCount = proc_listchildpids(parent, nil, 0)
        guard requestedCount > 0 else { return [] }
        let capacity = min(max(Int(requestedCount) + 16, 16), 1_024)
        var processIdentifiers = [pid_t](repeating: 0, count: capacity)
        let returnedCount = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listchildpids(
                parent,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard returnedCount > 0,
              Int(returnedCount) < processIdentifiers.count else {
            return []
        }
        return Array(
            processIdentifiers
                .prefix(Int(returnedCount))
                .filter { $0 > 1 }
        )
    }
}
