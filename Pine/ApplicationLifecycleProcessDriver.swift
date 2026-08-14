#if DEBUG

import AppKit
import Darwin
import Foundation

/// Scenarios executed by a separately launched Debug Pine binary. This is an
/// in-process driver rather than UI automation: AppKit owns the real app
/// lifecycle while a file-marker protocol makes every suspension deterministic
/// and keeps diagnostics free of editor/terminal payloads.
nonisolated enum ApplicationLifecycleProcessScenario:
    String, Codable, Sendable {
    case interactiveQuit = "interactive-quit"
    case interruptedSessionSave = "interrupted-session-save"
    case verifyRestoration = "verify-restoration"
}

nonisolated struct ApplicationLifecycleProcessConfiguration:
    Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let scenario: ApplicationLifecycleProcessScenario
    let stateDirectoryPath: String
    let projectPath: String
    let primaryFilePath: String
    let secondaryFilePath: String
    let defaultsSuiteName: String
    let terminalFixturePath: String

    init(
        scenario: ApplicationLifecycleProcessScenario,
        stateDirectoryPath: String,
        projectPath: String,
        primaryFilePath: String,
        secondaryFilePath: String,
        defaultsSuiteName: String,
        terminalFixturePath: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.scenario = scenario
        self.stateDirectoryPath = stateDirectoryPath
        self.projectPath = projectPath
        self.primaryFilePath = primaryFilePath
        self.secondaryFilePath = secondaryFilePath
        self.defaultsSuiteName = defaultsSuiteName
        self.terminalFixturePath = terminalFixturePath
    }
}

nonisolated struct ApplicationLifecycleProcessIdentity:
    Codable, Equatable, Sendable {
    let processIdentifier: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    init(_ identity: UserTaskProcessIdentity) {
        processIdentifier = identity.processID
        startSeconds = identity.startSeconds
        startMicroseconds = identity.startMicroseconds
    }

    var userTaskIdentity: UserTaskProcessIdentity {
        UserTaskProcessIdentity(
            processID: processIdentifier,
            startSeconds: startSeconds,
            startMicroseconds: startMicroseconds
        )
    }
}

/// Sanitized evidence persisted per phase. It intentionally contains only
/// lifecycle booleans, counts, and exact OS identities—not file contents,
/// terminal output, environment values, prompts, or credentials.
nonisolated struct ApplicationLifecycleProcessEvidence:
    Codable, Equatable, Sendable {
    let phase: String
    var processIdentifier: Int32?
    var terminalRoot: ApplicationLifecycleProcessIdentity?
    var terminalChild: ApplicationLifecycleProcessIdentity?
    var terminalReplacement: ApplicationLifecycleProcessIdentity?
    var confirmationVisible: Bool?
    var dirtyContentPresent: Bool?
    var terminalRunning: Bool?
    var windowVisible: Bool?
    var inputAccepted: Bool?
    var savedToDisk: Bool?
    var restoredFileCount: Int?
    var restoredTerminalCount: Int?
    var staleProcessOwnership: Bool?
    var failureCode: String?

    init(phase: String) {
        self.phase = phase
    }
}

@MainActor
final class ApplicationLifecycleProcessDriver {
    private enum TerminationMode: Equatable {
        case cancel
        case failSave
        case saveAndQuit
        case clean
    }

    private enum DriverFailure: String, Error {
        case invalidProject = "invalid-project"
        case missingPrimaryFile = "missing-primary-file"
        case missingSecondaryFile = "missing-secondary-file"
        case missingSession = "missing-session"
        case unexpectedSession = "unexpected-session"
        case terminalDidNotStart = "terminal-did-not-start"
        case terminalOwnershipUnavailable = "terminal-ownership-unavailable"
        case terminalChildUnavailable = "terminal-child-unavailable"
        case terminalReplacementUnavailable = "terminal-replacement-unavailable"
        case unexpectedTerminationReply = "unexpected-termination-reply"
        case commandTimedOut = "command-timed-out"
        case evidenceWriteFailed = "evidence-write-failed"
    }

    private struct TraceIdentity {
        let identity: UserTaskProcessIdentity
    }

    private static let configurationEnvironmentKey =
        "PINE_APPLICATION_LIFECYCLE_CONFIG"
    private static let launchArgument =
        "--application-lifecycle-process-test"
    private static let committedFixtureContent =
        "// committed lifecycle fixture\n"

    private let configuration: ApplicationLifecycleProcessConfiguration
    private let defaults: UserDefaults
    private let stateDirectory: URL
    private let eventsDirectory: URL
    private let commandsDirectory: URL
    private let projectURL: URL
    private let primaryFileURL: URL
    private let secondaryFileURL: URL
    private let terminalTraceURL: URL
    private var terminationMode: TerminationMode = .clean
    private weak var appDelegate: AppDelegate?
    private weak var terminalTab: TerminalTab?
    private var fixtureWindow: NSWindow?
    private var initialTerminalChild: UserTaskProcessIdentity?
    private var replacementTerminalChild: UserTaskProcessIdentity?

    static func fromEnvironment() -> ApplicationLifecycleProcessDriver? {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains(launchArgument),
              let path = processInfo.environment[
                configurationEnvironmentKey
              ],
              let data = try? Data(
                contentsOf: URL(fileURLWithPath: path)
              ),
              let configuration = try? JSONDecoder().decode(
                ApplicationLifecycleProcessConfiguration.self,
                from: data
              ),
              configuration.schemaVersion
                == ApplicationLifecycleProcessConfiguration
                    .currentSchemaVersion else {
            return nil
        }
        return ApplicationLifecycleProcessDriver(
            configuration: configuration
        )
    }

    private init?(configuration: ApplicationLifecycleProcessConfiguration) {
        guard let defaults = UserDefaults(
            suiteName: configuration.defaultsSuiteName
        ) else { return nil }
        self.configuration = configuration
        self.defaults = defaults
        stateDirectory = URL(
            fileURLWithPath: configuration.stateDirectoryPath,
            isDirectory: true
        )
        eventsDirectory = stateDirectory.appending(
            path: "events",
            directoryHint: .isDirectory
        )
        commandsDirectory = stateDirectory.appending(
            path: "commands",
            directoryHint: .isDirectory
        )
        projectURL = URL(
            fileURLWithPath: configuration.projectPath,
            isDirectory: true
        ).resolvingSymlinksInPath()
        primaryFileURL = URL(
            fileURLWithPath: configuration.primaryFilePath
        ).standardizedFileURL
        secondaryFileURL = URL(
            fileURLWithPath: configuration.secondaryFilePath
        ).standardizedFileURL
        terminalTraceURL = stateDirectory.appending(path: "terminal.trace")
    }

    func makeRegistry() -> ProjectRegistry {
        ProjectRegistry(
            defaults: defaults,
            agentTasks: AgentTaskRegistry(
                persistence: ApplicationLifecycleProcessAgentStore()
            ),
            agentDetectionPollInterval: 3_600,
            agentDetectionInitialPollDelay: 3_600
        )
    }

    func start(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await prepareProtocolDirectories()
                switch configuration.scenario {
                case .interactiveQuit:
                    try await runInteractiveQuit()
                case .interruptedSessionSave:
                    try await runInterruptedSessionSave()
                case .verifyRestoration:
                    try await runRestorationVerification()
                }
            } catch let failure as DriverFailure {
                await failAndExit(code: failure.rawValue)
            } catch {
                await failAndExit(code: "unexpected-driver-failure")
            }
        }
    }

    private func runInteractiveQuit() async throws {
        let project = try await makeProjectManager()
        guard FileManager.default.fileExists(atPath: primaryFileURL.path) else {
            throw DriverFailure.missingPrimaryFile
        }
        project.primaryTabManager.openTab(url: primaryFileURL)
        project.primaryTabManager.autoSavePreferenceProvider = { false }
        project.primaryTabManager.updateContent(
            Self.committedFixtureContent
        )
        let window = makeFixtureWindow(for: project)

        let initialProcess = TerminalInitialProcess(
            executablePath: "/bin/sh",
            arguments: [
                configuration.terminalFixturePath,
                "tree",
                terminalTraceURL.path,
            ]
        )
        let terminalPane = project.paneManager.createTerminalPaneAtBottom(
            workingDirectory: projectURL,
            initialProcess: initialProcess
        )
        guard let tab = project.paneManager.terminalState(
            for: terminalPane
        )?.activeTab else {
            throw DriverFailure.terminalDidNotStart
        }
        terminalTab = tab
        tab.terminalView.frame = NSRect(
            x: 0,
            y: 0,
            width: 800,
            height: 300
        )
        tab.startIfNeeded()
        guard let controller = tab.processTreeControllerForTesting else {
            throw DriverFailure.terminalOwnershipUnavailable
        }
        let child = try await requireTraceIdentity(phase: "child")
        initialTerminalChild = child.identity

        var ready = ApplicationLifecycleProcessEvidence(
            phase: "interactive-ready"
        )
        ready.processIdentifier = ProcessInfo.processInfo.processIdentifier
        ready.terminalRoot = ApplicationLifecycleProcessIdentity(
            controller.rootIdentity
        )
        ready.terminalChild = ApplicationLifecycleProcessIdentity(
            child.identity
        )
        ready.dirtyContentPresent = project.hasUnsavedChanges
        ready.terminalRunning = tab.isProcessRunning
        ready.windowVisible = window.isVisible
        try await emit(ready)

        installTerminationOverrides(project: project)
        let cancelled = await requestTermination(mode: .cancel)
        guard !cancelled else {
            throw DriverFailure.unexpectedTerminationReply
        }
        let acceptedAfterCancel = tab.sendText("probe\n")
        var cancellation = ApplicationLifecycleProcessEvidence(
            phase: "cancelled-usable"
        )
        cancellation.dirtyContentPresent = project.hasUnsavedChanges
        cancellation.terminalRunning = tab.isProcessRunning
        cancellation.windowVisible = window.isVisible
        cancellation.inputAccepted = acceptedAfterCancel
        try await emit(cancellation)

        try await waitForCommand("retry-failure")
        let failed = await requestTermination(mode: .failSave)
        guard !failed else {
            throw DriverFailure.unexpectedTerminationReply
        }
        var saveFailure = ApplicationLifecycleProcessEvidence(
            phase: "save-failure-usable"
        )
        saveFailure.dirtyContentPresent = project.hasUnsavedChanges
        saveFailure.terminalRunning = tab.isProcessRunning
        saveFailure.windowVisible = window.isVisible
        saveFailure.inputAccepted = tab.sendText("probe\n")
        try await emit(saveFailure)

        try await waitForCommand("retry-success")
        let confirmed = await requestTermination(mode: .saveAndQuit)
        guard confirmed else {
            throw DriverFailure.unexpectedTerminationReply
        }
        let savedToDisk = (try? String(
            contentsOf: primaryFileURL,
            encoding: .utf8
        )) == Self.committedFixtureContent
        var completion = ApplicationLifecycleProcessEvidence(
            phase: "confirmed-quit"
        )
        completion.terminalRoot = ApplicationLifecycleProcessIdentity(
            controller.rootIdentity
        )
        completion.terminalChild = initialTerminalChild.map(
            ApplicationLifecycleProcessIdentity.init
        )
        completion.terminalReplacement = replacementTerminalChild.map(
            ApplicationLifecycleProcessIdentity.init
        )
        completion.dirtyContentPresent = project.hasUnsavedChanges
        completion.terminalRunning = tab.isProcessRunning
        completion.windowVisible = window.isVisible
        completion.savedToDisk = savedToDisk
        try await emit(completion)
        NSApp.terminate(nil)
    }

    private func runInterruptedSessionSave() async throws {
        let project = try await makeProjectManager()
        let session = try requireCommittedSession()
        _ = ProjectSessionRestorer.restore(
            session,
            into: project,
            rootURL: projectURL
        )
        guard FileManager.default.fileExists(atPath: secondaryFileURL.path)
        else {
            throw DriverFailure.missingSecondaryFile
        }

        let restoredTabs = project.allTabs
        guard restoredTabs.count == 1,
              restoredTabs.first?.fileURL?.standardizedFileURL
                == primaryFileURL else {
            throw DriverFailure.unexpectedSession
        }
        let staleOwnership = hasStaleProcessOwnership(project)
        project.primaryTabManager.openTab(url: secondaryFileURL)
        _ = makeFixtureWindow(for: project)

        var ready = ApplicationLifecycleProcessEvidence(
            phase: "crash-generation-ready"
        )
        ready.processIdentifier = ProcessInfo.processInfo.processIdentifier
        ready.restoredFileCount = restoredTabs.count
        ready.restoredTerminalCount = project.allTerminalTabs.count
        ready.staleProcessOwnership = staleOwnership
        try await emit(ready)

        installTerminationOverrides(project: project)
        let confirmed = await requestTermination(mode: .clean)
        guard confirmed else {
            throw DriverFailure.unexpectedTerminationReply
        }
        var committed = ApplicationLifecycleProcessEvidence(
            phase: "crash-termination-committed"
        )
        committed.processIdentifier = ProcessInfo.processInfo.processIdentifier
        try await emit(committed)
        NSApp.terminate(nil)
    }

    private func runRestorationVerification() async throws {
        let project = try await makeProjectManager()
        let session = try requireCommittedSession()
        _ = ProjectSessionRestorer.restore(
            session,
            into: project,
            rootURL: projectURL
        )
        let restoredPaths = Set(project.allTabs.compactMap {
            $0.fileURL?.standardizedFileURL
        })
        guard restoredPaths == [primaryFileURL] else {
            throw DriverFailure.unexpectedSession
        }
        let savedToDisk = (try? String(
            contentsOf: primaryFileURL,
            encoding: .utf8
        )) == Self.committedFixtureContent
        _ = makeFixtureWindow(for: project)

        var restored = ApplicationLifecycleProcessEvidence(
            phase: "restoration-verified"
        )
        restored.processIdentifier = ProcessInfo.processInfo.processIdentifier
        restored.savedToDisk = savedToDisk
        restored.restoredFileCount = project.allTabs.count
        restored.restoredTerminalCount = project.allTerminalTabs.count
        restored.staleProcessOwnership = hasStaleProcessOwnership(project)
        try await emit(restored)

        installTerminationOverrides(project: project)
        let confirmed = await requestTermination(mode: .clean)
        guard confirmed else {
            throw DriverFailure.unexpectedTerminationReply
        }
        NSApp.terminate(nil)
    }

    private func makeProjectManager() async throws -> ProjectManager {
        guard let appDelegate,
              let project = appDelegate.registry.projectManager(
                for: projectURL
              ) else {
            throw DriverFailure.invalidProject
        }
        await project.workspace.waitForLoadingComplete()
        return project
    }

    private func requireCommittedSession() throws -> SessionState {
        guard let session = SessionState.load(
            for: projectURL,
            defaults: defaults
        ) else {
            throw DriverFailure.missingSession
        }
        guard session.existingFileURLs.map(\.standardizedFileURL)
                == [primaryFileURL] else {
            throw DriverFailure.unexpectedSession
        }
        return session
    }

    private func makeFixtureWindow(for project: ProjectManager) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lifecycle Fixture"
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.isReleasedWhenClosed = false
        project.bindDialogOwnerWindow(window)
        window.makeKeyAndOrderFront(nil)
        fixtureWindow = window
        return window
    }

    private func installTerminationOverrides(project: ProjectManager) {
        guard let appDelegate else { return }
        appDelegate.terminationAlertPresenterForProcessTest = { [weak self] template, _, _, _ in
            guard let self else { return .abort }
            return await self.present(template: template)
        }
        appDelegate.terminationSaveAllForProcessTest = { [weak self] projectManager, _ in
            guard let self else { return false }
            switch self.terminationMode {
            case .failSave:
                return false
            case .cancel, .saveAndQuit, .clean:
                return projectManager.saveAllPaneTabs()
            }
        }
        project.primaryTabManager.autoSavePreferenceProvider = { false }
    }

    private func present(
        template: AlertTemplate
    ) async -> NSApplication.ModalResponse {
        if template == .applicationQuitSummary,
           terminationMode == .cancel {
            var visible = ApplicationLifecycleProcessEvidence(
                phase: "confirmation-visible"
            )
            visible.confirmationVisible = true
            try? await emit(visible)
            do {
                try await waitForCommand("replace-and-cancel")
                guard let terminalTab,
                      terminalTab.sendText("replace\n") else {
                    return .abort
                }
                let replacement = try await requireTraceIdentity(
                    phase: "replacement",
                    excluding: initialTerminalChild
                )
                replacementTerminalChild = replacement.identity
                try? await Task.sleep(for: .milliseconds(100))
                var evidence = ApplicationLifecycleProcessEvidence(
                    phase: "replacement-while-confirming"
                )
                evidence.terminalReplacement =
                    ApplicationLifecycleProcessIdentity(
                        replacement.identity
                    )
                evidence.confirmationVisible = true
                evidence.terminalRunning = terminalTab.isProcessRunning
                try await emit(evidence)
            } catch {
                return .abort
            }
            return .abort
        }

        if template == .applicationQuitFailure
            || template == .fileOperationErrorCritical {
            return .alertFirstButtonReturn
        }
        return .alertFirstButtonReturn
    }

    private func requestTermination(mode: TerminationMode) async -> Bool {
        guard let appDelegate else { return false }
        terminationMode = mode
        appDelegate.terminationDeadlineForProcessTest = .now() + 8
        return await withCheckedContinuation { continuation in
            let reply = appDelegate.beginApplicationTermination {
                continuation.resume(returning: $0)
            }
            if reply == .terminateNow {
                continuation.resume(returning: true)
            }
        }
    }

    private func hasStaleProcessOwnership(
        _ project: ProjectManager
    ) -> Bool {
        let hasTerminalOwnership = project.allTerminalTabs.contains {
            $0.isProcessRunning || $0.agentSession != nil
        }
        guard let appDelegate else { return true }
        return hasTerminalOwnership
            || !appDelegate.registry.agentTasks.tasks.isEmpty
    }

    private func requireTraceIdentity(
        phase: String,
        excluding excluded: UserTaskProcessIdentity? = nil
    ) async throws -> TraceIdentity {
        let traceURL = terminalTraceURL
        let deadline = DispatchTime.now() + .seconds(5)
        while DispatchTime.now() < deadline {
            if let identity = await Task.detached(priority: .utility, operation: {
                Self.lastTraceIdentity(phase: phase, at: traceURL)
            }).value,
               identity.identity != excluded {
                return identity
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        switch phase {
        case "child":
            throw DriverFailure.terminalChildUnavailable
        default:
            throw DriverFailure.terminalReplacementUnavailable
        }
    }

    nonisolated private static func lastTraceIdentity(
        phase: String,
        at url: URL
    ) -> TraceIdentity? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            var values: [Substring: Substring] = [:]
            for field in line.split(separator: " ") {
                let pair = field.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                values[pair[0]] = pair[1]
            }
            guard values["phase"] == Substring(phase),
                  let processText = values["pid"],
                  let processIdentifier = pid_t(processText),
                  let identity = UserTaskProcessInspector.identity(
                    for: processIdentifier
                  ) else { continue }
            return TraceIdentity(identity: identity)
        }
        return nil
    }

    private func prepareProtocolDirectories() async throws {
        let events = eventsDirectory
        let commands = commandsDirectory
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(
                    at: events,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: commands,
                    withIntermediateDirectories: true
                )
            }.value
        } catch {
            throw DriverFailure.evidenceWriteFailed
        }
    }

    private func emit(
        _ evidence: ApplicationLifecycleProcessEvidence
    ) async throws {
        let destination = eventsDirectory.appending(
            path: evidence.phase + ".json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(evidence)
        } catch {
            throw DriverFailure.evidenceWriteFailed
        }
        do {
            try await Task.detached(priority: .utility) {
                try data.write(to: destination, options: .atomic)
            }.value
        } catch {
            throw DriverFailure.evidenceWriteFailed
        }
    }

    private func waitForCommand(_ name: String) async throws {
        let marker = commandsDirectory.appending(path: name)
        let deadline = DispatchTime.now() + .seconds(10)
        while DispatchTime.now() < deadline {
            let exists = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: marker.path)
            }.value
            if exists { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw DriverFailure.commandTimedOut
    }

    private func failAndExit(code: String) async {
        var failure = ApplicationLifecycleProcessEvidence(
            phase: "driver-failed"
        )
        failure.processIdentifier = ProcessInfo.processInfo.processIdentifier
        failure.failureCode = code
        try? await emit(failure)

        if let controller = terminalTab?.stopForApplicationTermination() {
            _ = await Task.detached(priority: .utility) {
                controller.waitForTermination(timeout: 3)
            }.value
        }
        Darwin.exit(70)
    }
}

private actor ApplicationLifecycleProcessAgentStore:
    AgentTaskPersisting {
    func load(
        project: AgentTaskProjectIdentity
    ) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(status: .missing, tasks: [])
    }

    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        .saved(taskCount: tasks.count)
    }
}

#endif
