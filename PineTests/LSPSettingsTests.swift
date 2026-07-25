//
//  LSPSettingsTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("LSP Settings")
@MainActor
struct LSPSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "LSPSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("Failed to create test defaults")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Global toggle and language overrides persist across relaunch")
    func persistenceAndReset() throws {
        let defaults = makeDefaults()
        let first = LSPSettings(defaults: defaults)

        #expect(first.isEnabled)
        #expect(first.overrides.isEmpty)

        first.setEnabled(false)
        try first.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: ["--stdio", "$(touch /tmp/never)", ";"]
        )

        let relaunched = LSPSettings(defaults: defaults)
        #expect(!relaunched.isEnabled)
        #expect(
            relaunched.serverOverride(for: "swift")
                == LanguageServerOverride(
                    executablePath: "/bin/echo",
                    arguments: ["--stdio", "$(touch /tmp/never)", ";"]
                )
        )

        relaunched.resetServerOverride(language: "swift")
        let resetRelaunch = LSPSettings(defaults: defaults)
        #expect(resetRelaunch.serverOverride(for: "swift") == nil)
    }

    @Test("Malformed persistence fails closed without affecting toggle")
    func malformedPersistence() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: LSPSettings.Keys.enabled)
        defaults.set(Data("not-json".utf8), forKey: LSPSettings.Keys.overrides)

        let settings = LSPSettings(defaults: defaults)
        #expect(!settings.isEnabled)
        #expect(settings.overrides.isEmpty)
    }

    @Test("Unknown persisted languages are ignored")
    func unknownLanguagesIgnored() throws {
        let defaults = makeDefaults()
        let encoded = try JSONEncoder().encode([
            "future-language": LanguageServerOverride(
                executablePath: "/bin/echo",
                arguments: []
            ),
            "swift": LanguageServerOverride(
                executablePath: "/bin/echo",
                arguments: nil
            )
        ])
        defaults.set(encoded, forKey: LSPSettings.Keys.overrides)

        let settings = LSPSettings(defaults: defaults)
        #expect(Set(settings.overrides.keys) == ["swift"])
    }

    @Test("Invalid path and argument input is non-destructive")
    func invalidInputIsNonDestructive() throws {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)
        try settings.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: ["first"]
        )
        let original = settings.serverOverride(for: "swift")

        #expect(throws: LSPSettingsValidationError.pathMustBeAbsolute) {
            try settings.setServerOverride(
                language: "swift",
                executablePath: "relative/sourcekit-lsp",
                arguments: nil
            )
        }
        #expect(throws: LSPSettingsValidationError.pathDoesNotExist) {
            try settings.setServerOverride(
                language: "swift",
                executablePath: "/definitely/missing/sourcekit-lsp",
                arguments: nil
            )
        }
        #expect(throws: LSPSettingsValidationError.pathIsDirectory) {
            try settings.setServerOverride(
                language: "swift",
                executablePath: "/tmp",
                arguments: nil
            )
        }
        #expect(
            throws: LSPSettingsValidationError.invalidArgument(index: 0)
        ) {
            try settings.setServerOverride(
                language: "swift",
                executablePath: "/bin/echo",
                arguments: ["first\nsecond"]
            )
        }

        #expect(settings.serverOverride(for: "swift") == original)
    }

    @Test("Non-executable files are rejected")
    func nonExecutableRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-lsp-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("server")
        try Data().write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: file.path
        )

        let settings = LSPSettings(defaults: makeDefaults())
        #expect(throws: LSPSettingsValidationError.pathNotExecutable) {
            try settings.setServerOverride(
                language: "swift",
                executablePath: file.path,
                arguments: nil
            )
        }
    }

    @Test("Resolution prefers explicit path and preserves literal arguments")
    func resolutionPrecedence() {
        let config = LanguageServerConfig(
            language: "test",
            fileExtensions: ["test"],
            command: "echo",
            arguments: ["default"]
        )
        let resolver = LanguageServerResolver(
            resolver: ExternalToolResolver(
                searchDirectories: ["/bin"]
            )
        )

        #expect(
            resolver.resolve(
                config: config,
                serverOverride: nil
            ) == .resolved(
                LanguageServerLaunchConfiguration(
                    executablePath: "/bin/echo",
                    arguments: ["default"]
                )
            )
        )

        let literalArguments = ["$(touch /tmp/never)", "a;b", "*.swift"]
        #expect(
            resolver.resolve(
                config: config,
                serverOverride: LanguageServerOverride(
                    executablePath: "/usr/bin/true",
                    arguments: literalArguments
                )
            ) == .resolved(
                LanguageServerLaunchConfiguration(
                    executablePath: "/usr/bin/true",
                    arguments: literalArguments
                )
            )
        )
    }

    @Test("Invalid explicit path never falls back to PATH")
    func invalidOverrideDoesNotFallback() {
        let config = LanguageServerConfig(
            language: "test",
            fileExtensions: ["test"],
            command: "echo",
            arguments: []
        )
        let resolver = LanguageServerResolver(
            resolver: ExternalToolResolver(
                searchDirectories: ["/bin"]
            )
        )

        #expect(
            resolver.resolve(
                config: config,
                serverOverride: LanguageServerOverride(
                    executablePath: "/missing/custom-server",
                    arguments: nil
                )
            ) == .invalidOverride(.pathDoesNotExist)
        )
    }

    @Test("Persisted invalid arguments fail closed during resolution")
    func invalidPersistedArgumentsDoNotResolve() {
        let config = LanguageServerConfig(
            language: "test",
            fileExtensions: ["test"],
            command: "echo",
            arguments: []
        )
        let resolver = LanguageServerResolver(
            resolver: ExternalToolResolver(
                searchDirectories: ["/bin"]
            )
        )

        #expect(
            resolver.resolve(
                config: config,
                serverOverride: LanguageServerOverride(
                    executablePath: nil,
                    arguments: ["first\nsecond"]
                )
            ) == .invalidOverride(.invalidArgument(index: 0))
        )
    }

}

nonisolated private struct TestLSPResolver: LanguageServerResolving {
    let executablePath: String

    func resolve(
        config: LanguageServerConfig,
        serverOverride: LanguageServerOverride?
    ) -> LanguageServerResolution {
        .resolved(
            LanguageServerLaunchConfiguration(
                executablePath:
                    serverOverride?.executablePath ?? executablePath,
                arguments:
                    serverOverride?.arguments ?? config.arguments
            )
        )
    }
}

@MainActor
private class RecordingLSPClient: LSPClientProtocol {
    struct Start: Equatable {
        let command: String
        let arguments: [String]
        let rootURI: String?
    }

    struct Open: Equatable {
        let uri: String
        let language: String
        let version: Int
        let text: String
    }

    var onDiagnostics: ((LSPDiagnosticsNotification) -> Void)?
    private(set) var starts: [Start] = []
    private(set) var opens: [Open] = []
    private(set) var changes: [(uri: String, text: String)] = []
    private(set) var closes: [String] = []
    private(set) var shutdownCount = 0
    private(set) var gracefulShutdownCount = 0
    var foldingSupported = false
    var foldingRangesResult: [LSPFoldingRange] = []
    private(set) var foldingRequests: [String] = []
    var documentSymbolsSupported = false
    var documentSymbolsResult: [LSPDocumentSymbol] = []
    private(set) var documentSymbolRequests: [String] = []

    func startForManager(
        command: String,
        arguments: [String],
        rootURI: String?
    ) async -> Bool {
        starts.append(
            Start(
                command: command,
                arguments: arguments,
                rootURI: rootURI
            )
        )
        return true
    }

    func shutdown() {
        shutdownCount += 1
    }

    func shutdownGracefully(timeout: Duration) async -> Bool {
        gracefulShutdownCount += 1
        return true
    }

    func didOpen(
        uri: String,
        language: String,
        version: Int,
        text: String
    ) {
        opens.append(
            Open(
                uri: uri,
                language: language,
                version: version,
                text: text
            )
        )
    }

    func didChange(uri: String, text: String) {
        changes.append((uri, text))
    }

    func didClose(uri: String) {
        closes.append(uri)
    }

    var supportsFoldingRange: Bool {
        foldingSupported
    }

    func foldingRange(uri: String) async -> [LSPFoldingRange] {
        foldingRequests.append(uri)
        return foldingRangesResult
    }

    var supportsDocumentSymbols: Bool {
        documentSymbolsSupported
    }

    func documentSymbols(uri: String) async -> [LSPDocumentSymbol] {
        documentSymbolRequests.append(uri)
        return documentSymbolsResult
    }
}

@MainActor
private final class SuspendedStartLSPClient: RecordingLSPClient {
    private(set) var isWaitingToStart = false
    private var continuation: CheckedContinuation<Bool, Never>?

    override func startForManager(
        command: String,
        arguments: [String],
        rootURI: String?
    ) async -> Bool {
        isWaitingToStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resumeStart(_ result: Bool) {
        isWaitingToStart = false
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class SuspendedShutdownLSPClient: RecordingLSPClient {
    private(set) var isWaitingToShutDown = false
    private var continuation: CheckedContinuation<Bool, Never>?

    override func shutdownGracefully(timeout: Duration) async -> Bool {
        isWaitingToShutDown = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resumeShutdown(_ result: Bool) {
        isWaitingToShutDown = false
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@Suite("LSP Settings Lifecycle")
@MainActor
struct LSPSettingsLifecycleTests {
    private func makeSettings() -> LSPSettings {
        let name = "LSPSettingsLifecycleTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("Failed to create test defaults")
        }
        defaults.removePersistentDomain(forName: name)
        return LSPSettings(defaults: defaults)
    }

    @Test("Changing one language restarts only its active client and replays")
    func targetedRestartAndReplay() async throws {
        let settings = makeSettings()
        var clientsByLanguage: [String: [RecordingLSPClient]] = [:]
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { language in
            let client = RecordingLSPClient()
            clientsByLanguage[language, default: []].append(client)
            return client
        }
        let swiftURL = URL(fileURLWithPath: "/project/App.swift")
        let pythonURL = URL(fileURLWithPath: "/project/main.py")

        manager.didOpen(url: swiftURL, text: "let value = 1")
        manager.didOpen(url: pythonURL, text: "value = 1")
        await waitUntil {
            manager.servers.count == 2
                && manager.servers.values.allSatisfy {
                    $0.state == .initialized
                }
        }

        try settings.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: ["$(literal)", "--stdio"]
        )
        manager.didChange(url: swiftURL, text: "let value = 2")
        manager.didChange(url: pythonURL, text: "value = 2")
        await manager.applySettingsChange(.language("swift"))

        let swiftClients = try #require(clientsByLanguage["swift"])
        let pythonClients = try #require(clientsByLanguage["python"])
        #expect(swiftClients.count == 2)
        #expect(swiftClients[0].gracefulShutdownCount == 1)
        #expect(
            swiftClients[1].starts.first?.arguments
                == ["$(literal)", "--stdio"]
        )
        #expect(swiftClients[1].opens.count == 1)
        #expect(swiftClients[1].opens.first?.text == "let value = 2")
        #expect(pythonClients.count == 1)
        #expect(pythonClients[0].gracefulShutdownCount == 0)
    }

    @Test("Disable stops clients, blocks lazy launch, and enable restores them")
    func disableAndEnable() async throws {
        let settings = makeSettings()
        var clients: [RecordingLSPClient] = []
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in
            let client = RecordingLSPClient()
            clients.append(client)
            return client
        }
        let url = URL(fileURLWithPath: "/project/App.swift")

        manager.didOpen(url: url, text: "let value = 1")
        await waitUntil { manager.servers["swift"]?.state == .initialized }

        settings.setEnabled(false)
        await manager.applySettingsChange(.enabled(false))
        #expect(manager.servers.isEmpty)
        #expect(clients.first?.gracefulShutdownCount == 1)

        manager.didChange(url: url, text: "let value = 2")
        await Task.yield()
        #expect(clients.count == 1)

        settings.setEnabled(true)
        await manager.applySettingsChange(.enabled(true))
        #expect(clients.count == 2)
        #expect(clients.last?.opens.first?.text == "let value = 2")
    }

    @Test("A stale initialize cannot replace a reconfigured client")
    func reconfigureDuringInitialize() async throws {
        let settings = makeSettings()
        let suspended = SuspendedStartLSPClient()
        var replacements: [RecordingLSPClient] = []
        var creationCount = 0
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in
            creationCount += 1
            if creationCount == 1 {
                return suspended
            }
            let replacement = RecordingLSPClient()
            replacements.append(replacement)
            return replacement
        }
        let url = URL(fileURLWithPath: "/project/App.swift")

        manager.didOpen(url: url, text: "old")
        await waitUntil { suspended.isWaitingToStart }

        try settings.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: ["new"]
        )
        manager.didChange(url: url, text: "current")
        await manager.applySettingsChange(.language("swift"))

        let replacement = try #require(replacements.first)
        #expect(replacement.opens.first?.text == "current")
        #expect(manager.servers["swift"]?.state == .initialized)

        suspended.resumeStart(true)
        await Task.yield()

        #expect(suspended.opens.isEmpty)
        #expect(suspended.shutdownCount == 1)
        #expect(manager.servers["swift"]?.state == .initialized)
        #expect(replacements.count == 1)
    }

    @Test("Enabling starts servers for documents opened while disabled")
    func enablingReplaysCurrentDocuments() async {
        let settings = makeSettings()
        settings.setEnabled(false)
        var clientsByLanguage: [String: RecordingLSPClient] = [:]
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { language in
            let client = RecordingLSPClient()
            clientsByLanguage[language] = client
            return client
        }
        let swiftURL = URL(fileURLWithPath: "/project/App.swift")
        let pythonURL = URL(fileURLWithPath: "/project/main.py")

        manager.didOpen(url: swiftURL, text: "current Swift")
        await Task.yield()
        #expect(clientsByLanguage.isEmpty)

        settings.setEnabled(true)
        manager.didOpen(url: pythonURL, text: "current Python")
        await waitUntil {
            manager.servers["python"]?.state == .initialized
        }
        await manager.applySettingsChange(.enabled(true))

        #expect(clientsByLanguage.keys.sorted() == ["python", "swift"])
        #expect(clientsByLanguage["swift"]?.opens.count == 1)
        #expect(clientsByLanguage["python"]?.opens.count == 1)
    }

    @Test("Configuring an inactive language starts only that open language")
    func configuringInactiveLanguageStartsMatchingDocuments() async {
        let settings = makeSettings()
        settings.setEnabled(false)
        var createdLanguages: [String] = []
        var clients: [RecordingLSPClient] = []
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { language in
            createdLanguages.append(language)
            let client = RecordingLSPClient()
            clients.append(client)
            return client
        }
        let swiftURL = URL(fileURLWithPath: "/project/App.swift")
        let pythonURL = URL(fileURLWithPath: "/project/main.py")

        manager.didOpen(url: swiftURL, text: "let value = 1")
        manager.didOpen(url: pythonURL, text: "value = 1")
        settings.setEnabled(true)
        await manager.applySettingsChange(.language("swift"))

        #expect(createdLanguages == ["swift"])
        #expect(clients.first?.opens.first?.uri == swiftURL.absoluteString)
    }

    @Test("Edits during replacement initialization replay latest text")
    func editDuringReplacementInitialization() async throws {
        let settings = makeSettings()
        let original = RecordingLSPClient()
        let replacement = SuspendedStartLSPClient()
        var creationCount = 0
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in
            creationCount += 1
            return creationCount == 1 ? original : replacement
        }
        let url = URL(fileURLWithPath: "/project/App.swift")

        manager.didOpen(url: url, text: "before")
        await waitUntil { manager.servers["swift"]?.state == .initialized }

        let restart = Task { @MainActor in
            await manager.applySettingsChange(.language("swift"))
        }
        await waitUntil { replacement.isWaitingToStart }

        manager.didChange(url: url, text: "latest")
        replacement.resumeStart(true)
        await restart.value

        #expect(replacement.opens.count == 1)
        #expect(replacement.opens.first?.text == "latest")
    }

    @Test("Open and close events survive graceful restart")
    func openAndCloseDuringGracefulRestart() async throws {
        let settings = makeSettings()
        let original = SuspendedShutdownLSPClient()
        var replacements: [RecordingLSPClient] = []
        var creationCount = 0
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in
            creationCount += 1
            if creationCount == 1 {
                return original
            }
            let replacement = RecordingLSPClient()
            replacements.append(replacement)
            return replacement
        }
        let closedURL = URL(fileURLWithPath: "/project/Closed.swift")
        let openedURL = URL(fileURLWithPath: "/project/Opened.swift")

        manager.didOpen(url: closedURL, text: "closed")
        await waitUntil { manager.servers["swift"]?.state == .initialized }

        let restart = Task { @MainActor in
            await manager.applySettingsChange(.language("swift"))
        }
        await waitUntil { original.isWaitingToShutDown }

        manager.didClose(url: closedURL)
        manager.didOpen(url: openedURL, text: "opened stale")
        manager.didChange(url: openedURL, text: "opened latest")
        original.resumeShutdown(true)
        await restart.value

        let replacement = try #require(replacements.first)
        #expect(replacement.opens.map(\.uri) == [openedURL.absoluteString])
        #expect(replacement.opens.first?.text == "opened latest")
    }

    @Test("Shutdown invalidates an in-flight settings restart")
    func shutdownDuringSettingsRestart() async {
        let settings = makeSettings()
        let original = SuspendedShutdownLSPClient()
        var creationCount = 0
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in
            creationCount += 1
            return original
        }
        let url = URL(fileURLWithPath: "/project/App.swift")

        manager.didOpen(url: url, text: "current")
        await waitUntil { manager.servers["swift"]?.state == .initialized }

        let restart = Task { @MainActor in
            await manager.applySettingsChange(.language("swift"))
        }
        await waitUntil { original.isWaitingToShutDown }

        manager.shutdownAll()
        original.resumeShutdown(true)
        await restart.value

        #expect(original.shutdownCount == 1)
        #expect(creationCount == 1)
        #expect(manager.servers.isEmpty)
    }

    @Test("Duplicate pane owners close a document only after the final owner")
    func duplicatePaneOwnerLifecycle() async {
        let settings = makeSettings()
        let client = RecordingLSPClient()
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in client }
        let url = URL(fileURLWithPath: "/project/App.swift")

        manager.didOpen(url: url, text: "first")
        manager.didOpen(url: url, text: "second")
        await waitUntil { manager.servers["swift"]?.state == .initialized }

        #expect(client.opens.count == 1)
        #expect(client.opens.first?.text == "second")

        manager.didClose(url: url)
        manager.didChange(url: url, text: "still open")
        #expect(client.closes.isEmpty)
        #expect(client.changes.last?.text == "still open")

        manager.didClose(url: url)
        #expect(client.closes == [url.absoluteString])

        manager.didChange(url: url, text: "must be ignored")
        #expect(client.changes.count == 1)
    }

    @Test("Restart replays the last live edit for duplicate URL owners")
    func duplicateOwnerRestartUsesLastLiveEdit() async throws {
        let settings = makeSettings()
        var clients: [RecordingLSPClient] = []
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in
            let client = RecordingLSPClient()
            clients.append(client)
            return client
        }
        let url = URL(fileURLWithPath: "/project/App.swift")

        manager.didOpen(url: url, text: "pane A")
        manager.didOpen(url: url, text: "pane B")
        await waitUntil { manager.servers["swift"]?.state == .initialized }

        manager.didChange(url: url, text: "pane A latest")
        await manager.applySettingsChange(.language("swift"))

        let replacement = try #require(clients.last)
        #expect(replacement.opens.count == 1)
        #expect(replacement.opens.first?.text == "pane A latest")
    }

    @Test("Inactive tabs do not become phantom owners after restart")
    func inactiveTabSwitchAfterRestart() async throws {
        let settings = makeSettings()
        var clients: [RecordingLSPClient] = []
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in
            let client = RecordingLSPClient()
            clients.append(client)
            return client
        }
        let firstURL = URL(fileURLWithPath: "/project/First.swift")
        let secondURL = URL(fileURLWithPath: "/project/Second.swift")

        manager.didOpen(url: firstURL, text: "first")
        await waitUntil { manager.servers["swift"]?.state == .initialized }
        await manager.applySettingsChange(.language("swift"))

        let replacement = try #require(clients.last)
        #expect(replacement.opens.map(\.uri) == [firstURL.absoluteString])

        manager.didClose(url: firstURL)
        manager.didOpen(url: secondURL, text: "second")
        await waitUntil { replacement.opens.count == 2 }
        manager.didClose(url: secondURL)

        #expect(
            replacement.closes
                == [firstURL.absoluteString, secondURL.absoluteString]
        )
        manager.didChange(url: secondURL, text: "must be ignored")
        #expect(replacement.changes.isEmpty)
    }

    @Test("Folding query requires the exact synchronized document snapshot")
    func foldingRequiresExactSynchronizedSnapshot() async {
        let settings = makeSettings()
        let client = RecordingLSPClient()
        client.foldingSupported = true
        client.foldingRangesResult = [
            LSPFoldingRange(startLine: 0, endLine: 1)
        ]
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in client }
        let url = URL(fileURLWithPath: "/project/App.swift")

        manager.didOpen(url: url, text: "func old() {\n}")
        await waitUntil {
            manager.servers["swift"]?.state == .initialized
                && client.opens.count == 1
        }
        #expect(manager.foldingRefreshGeneration == 1)

        let initial = await manager.foldingRanges(
            url: url,
            text: "func old() {\n}"
        )
        #expect(initial?.count == 1)
        #expect(client.foldingRequests == [url.absoluteString])

        let unsynchronized = await manager.foldingRanges(
            url: url,
            text: "func new() {\n}"
        )
        #expect(unsynchronized == nil)
        #expect(client.foldingRequests == [url.absoluteString])
        #expect(client.changes.isEmpty)

        manager.didChange(url: url, text: "func new() {\n}")
        let synchronized = await manager.foldingRanges(
            url: url,
            text: "func new() {\n}"
        )
        #expect(synchronized?.count == 1)
        #expect(client.changes.last?.text == "func new() {\n}")
        #expect(
            client.foldingRequests
                == [url.absoluteString, url.absoluteString]
        )

        manager.didClose(url: url)
        let closed = await manager.foldingRanges(
            url: url,
            text: "func new() {\n}"
        )
        #expect(closed == nil)
        #expect(client.foldingRequests.count == 2)
    }

    @Test("Document symbols require the exact synchronized snapshot")
    func symbolsRequireExactSynchronizedSnapshot() async {
        let settings = makeSettings()
        let client = RecordingLSPClient()
        client.documentSymbolsSupported = true
        client.documentSymbolsResult = [
            LSPDocumentSymbol(
                name: "old",
                kind: 12,
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 0),
                    end: LSPPosition(line: 0, character: 13)
                ),
                selectionRange: LSPRange(
                    start: LSPPosition(line: 0, character: 5),
                    end: LSPPosition(line: 0, character: 8)
                )
            )
        ]
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in client }
        let url = URL(fileURLWithPath: "/project/App.swift")

        manager.didOpen(url: url, text: "func old() {}")
        await waitUntil {
            manager.servers["swift"]?.state == .initialized
                && client.opens.count == 1
        }

        let initial = await manager.documentSymbols(
            url: url,
            text: "func old() {}"
        )
        #expect(initial?.map(\.name) == ["old"])
        #expect(client.documentSymbolRequests == [url.absoluteString])

        let unsynchronized = await manager.documentSymbols(
            url: url,
            text: "func new() {}"
        )
        #expect(unsynchronized == nil)
        #expect(client.documentSymbolRequests == [url.absoluteString])

        manager.didChange(url: url, text: "func new() {}")
        let synchronized = await manager.documentSymbols(
            url: url,
            text: "func new() {}"
        )
        #expect(synchronized?.map(\.name) == ["old"])
        #expect(client.documentSymbolRequests.count == 2)

        manager.didClose(url: url)
        let closed = await manager.documentSymbols(
            url: url,
            text: "func new() {}"
        )
        #expect(closed == nil)
        #expect(client.documentSymbolRequests.count == 2)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for LSP test state")
    }
}
