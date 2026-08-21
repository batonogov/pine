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

    @Test("Setting a valid override then an invalid one leaves only the valid one persisted")
    func validThenInvalidOverridePersistence() throws {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)

        // First, persist a valid override.
        try settings.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: ["--stdio"]
        )
        #expect(
            settings.serverOverride(for: "swift")
                == LanguageServerOverride(
                    executablePath: "/bin/echo",
                    arguments: ["--stdio"]
                )
        )

        // An invalid attempt must NOT overwrite the valid persisted state.
        #expect(throws: LSPSettingsValidationError.pathMustBeAbsolute) {
            try settings.setServerOverride(
                language: "swift",
                executablePath: "relative/path",
                arguments: nil
            )
        }
        // The valid override survives — invalid input is non-destructive.
        #expect(
            settings.serverOverride(for: "swift")
                == LanguageServerOverride(
                    executablePath: "/bin/echo",
                    arguments: ["--stdio"]
                )
        )

        // Relaunch sees only the valid override.
        let relaunched = LSPSettings(defaults: defaults)
        #expect(
            relaunched.serverOverride(for: "swift")
                == LanguageServerOverride(
                    executablePath: "/bin/echo",
                    arguments: ["--stdio"]
                )
        )
    }

    @Test("Blanking all fields removes the override so defaults are inherited")
    func blankingFieldsRemovesOverride() throws {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)

        try settings.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: ["--stdio"]
        )
        #expect(settings.serverOverride(for: "swift") != nil)

        // Passing nil/blank for both fields normalizes to no override.
        try settings.setServerOverride(
            language: "swift",
            executablePath: "   ",
            arguments: nil
        )
        #expect(settings.serverOverride(for: "swift") == nil)
    }

    @Test("Each language override is persisted independently")
    func perLanguageIndependence() throws {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)

        try settings.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: nil
        )
        try settings.setServerOverride(
            language: "python",
            executablePath: "/usr/bin/true",
            arguments: ["--stdio"]
        )

        #expect(
            settings.serverOverride(for: "swift")?.executablePath
                == "/bin/echo"
        )
        #expect(
            settings.serverOverride(for: "python")?.arguments
                == ["--stdio"]
        )

        // Resetting one does not affect the other.
        settings.resetServerOverride(language: "swift")
        #expect(settings.serverOverride(for: "swift") == nil)
        #expect(settings.serverOverride(for: "python") != nil)
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
        // `#expect`, not `#require`: collect the whole picture instead of
        // stopping at the first symptom. Nothing between here and the reads
        // below can trap on an unsatisfied wait — every read is a `#require`
        // or an `Optional` chain — so continuing costs nothing and a failure
        // here reports the startup timeout *and* whatever the restart
        // actually produced. (Note this is not a double-report question:
        // `waitUntil` records its own issue and returns `false`, so a timeout
        // is reported twice either way.)
        #expect(
            await waitUntil {
                manager.servers.count == 2
                    && manager.servers.values.allSatisfy {
                        $0.state == .initialized
                    }
            },
            """
            Both language servers must be initialized before the restart; \
            everything below measures the restart, not the startup.
            """
        )

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
        #expect(pythonClients.count == 1)
        // `[0]` is safe by construction — the only writer is
        // `clientsByLanguage[language, default: []].append(client)`, so a key
        // exists only once it holds at least one element.
        #expect(swiftClients[0].gracefulShutdownCount == 1)
        #expect(pythonClients[0].gracefulShutdownCount == 0)

        // `[1]` is not. The replacement client exists only if
        // `applySettingsChange(.language("swift"))` carries the restart all
        // the way through, and there are six ways for it not to. Two are
        // `guard`s in `replayDocuments` (`LSPManager.swift:977-986`):
        // disabled / epoch-superseded / no registry entry, and no open
        // documents. The other four are the early exits in `ensureServer`
        // (`:822-857`), which `replayDocuments` delegates its third `guard`
        // to and which all return before `clientFactory` runs: the
        // lifecycle/cancellation gate, an in-flight restart for the language,
        // an entry already present for the language, and an unresolved launch
        // configuration. (A seventh path — `replayDocuments`' final
        // `canContinue(epoch:)` at `:988` — does create the client but skips
        // the replay, so it fails the `opens` assertions instead of the
        // count.) Any of the six leaves the count at 1, and a bare
        // `swiftClients[1]` after a *soft* `#expect(count == 2)` raises
        // `EXC_BREAKPOINT` — killing the whole `PineTests` process along with
        // every unrelated suite sharing it (#1506). `#require` throws
        // instead.
        let restarted = try #require(
            swiftClients.dropFirst().first,
            """
            The swift language server never came back after \
            `applySettingsChange(.language("swift"))`.
            """
        )
        #expect(restarted.starts.first?.arguments == ["$(literal)", "--stdio"])
        #expect(restarted.opens.count == 1)
        #expect(restarted.opens.first?.text == "let value = 2")
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

        manager.didOpen(
            url: url,
            contentRevision: 7,
            text: "let value = 1"
        )
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

    @Test("Background suspend is idempotent and resume replays latest buffers once")
    func backgroundSuspendAndResume() async throws {
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

        manager.didOpen(
            url: url,
            contentRevision: 1,
            text: "let value = 1"
        )
        await waitUntil { manager.servers["swift"]?.state == .initialized }
        let original = try #require(clients.first)

        manager.suspendForBackground()
        manager.suspendForBackground()
        #expect(manager.presentationLifecycle == .backgroundSuspended)
        #expect(manager.servers.isEmpty)
        #expect(original.shutdownCount == 1)

        manager.didChange(
            url: url,
            contentRevision: 2,
            text: "let value = 2"
        )
        manager.resumeFromBackground()
        manager.resumeFromBackground()
        await waitUntil {
            clients.count == 2
                && manager.servers["swift"]?.state == .initialized
        }

        let replacement = try #require(clients.last)
        #expect(manager.presentationLifecycle == .active)
        #expect(replacement.starts.count == 1)
        #expect(replacement.opens.count == 1)
        #expect(replacement.opens.first?.text == "let value = 2")
    }

    @Test("Delayed old presentation close preserves the reopened owner")
    func delayedOldClosePreservesReopenedPresentation() async throws {
        let settings = makeSettings()
        let client = RecordingLSPClient()
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in client }
        let url = URL(fileURLWithPath: "/project/App.swift")
        let oldPresentation = UUID()
        let reopenedPresentation = UUID()

        manager.didOpen(
            url: url,
            ownerID: oldPresentation,
            contentRevision: 1,
            text: "old"
        )
        await waitUntil { client.opens.count == 1 }
        manager.didOpen(
            url: url,
            ownerID: reopenedPresentation,
            contentRevision: 2,
            text: "reopened"
        )

        // SwiftUI can deliver this disappearance after the replacement view's
        // onAppear. Its unique presentation token must not close the reopen.
        manager.didClose(url: url, ownerID: oldPresentation)
        manager.didChange(
            url: url,
            ownerID: reopenedPresentation,
            contentRevision: 3,
            text: "reopened latest"
        )

        #expect(client.closes.isEmpty)
        #expect(Array(client.changes.map(\.text).suffix(2)) == [
            "reopened",
            "reopened latest"
        ])
        manager.didClose(url: url, ownerID: reopenedPresentation)
        #expect(client.closes == [url.absoluteString])
    }

    @Test("Suspend during initialize fences stale completion after resume")
    func suspendDuringInitializeAndResume() async throws {
        let settings = makeSettings()
        let suspended = SuspendedStartLSPClient()
        var replacements: [RecordingLSPClient] = []
        var creationCount = 0
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in
            creationCount += 1
            if creationCount == 1 { return suspended }
            let replacement = RecordingLSPClient()
            replacements.append(replacement)
            return replacement
        }
        let url = URL(fileURLWithPath: "/project/App.swift")

        manager.didOpen(url: url, text: "before")
        await waitUntil { suspended.isWaitingToStart }
        manager.suspendForBackground()
        manager.didChange(url: url, text: "after")
        manager.resumeFromBackground()
        await waitUntil {
            manager.servers["swift"]?.state == .initialized
        }

        suspended.resumeStart(true)
        await Task.yield()

        let replacement = try #require(replacements.first)
        #expect(suspended.shutdownCount == 2)
        #expect(suspended.opens.isEmpty)
        #expect(replacement.opens.map(\.text) == ["after"])
        #expect(manager.servers["swift"]?.state == .initialized)
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
        #expect(client.changes.map(\.text) == ["first", "still open"])

        manager.didClose(url: url)
        #expect(client.closes == [url.absoluteString])

        manager.didChange(url: url, text: "must be ignored")
        #expect(client.changes.count == 2)
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

    @Test("Duplicate owner close resynchronizes the surviving buffer and version")
    func duplicateOwnerCloseResynchronizesSurvivor() async throws {
        let settings = makeSettings()
        let client = RecordingLSPClient()
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in client }
        let url = URL(fileURLWithPath: "/project/App.swift")
        let firstOwner = UUID()
        let secondOwner = UUID()
        let diagnostic = try #require(LSPDiagnostic(json: [
            "range": [
                "start": ["line": 0, "character": 0],
                "end": ["line": 0, "character": 1]
            ],
            "severity": 1,
            "message": "stale duplicate"
        ]))

        manager.didOpen(
            url: url,
            ownerID: firstOwner,
            contentRevision: 1,
            text: "pane A"
        )
        await waitUntil {
            manager.servers["swift"]?.state == .initialized
                && client.opens.count == 1
        }
        manager.didChange(
            url: url,
            ownerID: firstOwner,
            contentRevision: 2,
            text: "pane A current"
        )
        manager.didOpen(
            url: url,
            ownerID: secondOwner,
            contentRevision: 10,
            text: "pane B"
        )
        manager.didChange(
            url: url,
            ownerID: secondOwner,
            contentRevision: 11,
            text: "pane B current"
        )

        manager.didClose(url: url, ownerID: secondOwner)

        #expect(client.opens.first?.version == 1)
        #expect(client.changes.map(\.text) == [
            "pane A current",
            "pane B current",
            "pane A current"
        ])

        client.onDiagnostics?(LSPDiagnosticsNotification(
            uri: url.absoluteString,
            version: 3,
            diagnostics: [diagnostic]
        ))
        #expect(manager.allProblemsDiagnostics.isEmpty)

        client.onDiagnostics?(LSPDiagnosticsNotification(
            uri: url.absoluteString,
            version: 4,
            diagnostics: [diagnostic]
        ))
        #expect(manager.allProblemsDiagnostics.first?.documentVersion == 4)
        #expect(manager.allProblemsDiagnostics.first?.contentRevision == 2)
    }

    @Test("Repeated didOpen for one owner is lifecycle-idempotent")
    func repeatedDidOpenForSameOwnerIsIdempotent() async {
        let settings = makeSettings()
        let client = RecordingLSPClient()
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in client }
        let url = URL(fileURLWithPath: "/project/App.swift")
        let owner = UUID()

        manager.didOpen(url: url, ownerID: owner, text: "first")
        manager.didOpen(url: url, ownerID: owner, text: "first")
        await waitUntil { client.opens.count == 1 }
        manager.didClose(url: url, ownerID: owner)

        #expect(client.opens.count == 1)
        #expect(client.closes == [url.absoluteString])
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

    @Test("Problems diagnostics bind versioned and unversioned publishes to the editor revision")
    func problemsDiagnosticsRequireCurrentVersion() async throws {
        let settings = makeSettings()
        let client = RecordingLSPClient()
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in client }
        let url = URL(fileURLWithPath: "/project/App.swift")
        let diagnostic = try #require(LSPDiagnostic(json: [
            "range": [
                "start": ["line": 1, "character": 4],
                "end": ["line": 1, "character": 8]
            ],
            "severity": 1,
            "source": "sourcekit-lsp",
            "message": "type mismatch"
        ]))

        manager.didOpen(
            url: url,
            contentRevision: 7,
            text: "let value = 1"
        )
        await waitUntil {
            manager.servers["swift"]?.state == .initialized
                && client.opens.count == 1
        }

        client.onDiagnostics?(LSPDiagnosticsNotification(
            uri: url.absoluteString,
            version: 1,
            diagnostics: [diagnostic]
        ))
        #expect(manager.allProblemsDiagnostics.count == 1)
        #expect(
            manager.allProblemsDiagnostics.first?.documentVersion == 1
        )
        #expect(
            manager.allProblemsDiagnostics.first?.contentRevision == 7
        )

        manager.didChange(
            url: url,
            contentRevision: 8,
            text: "let value = true"
        )
        #expect(manager.allProblemsDiagnostics.isEmpty)
        #expect(manager.diagnostics(for: url).isEmpty)

        client.onDiagnostics?(LSPDiagnosticsNotification(
            uri: url.absoluteString,
            version: 1,
            diagnostics: [diagnostic]
        ))
        #expect(manager.allProblemsDiagnostics.isEmpty)
        #expect(manager.diagnostics(for: url).isEmpty)

        client.onDiagnostics?(LSPDiagnosticsNotification(
            uri: url.absoluteString,
            version: 2,
            diagnostics: [diagnostic]
        ))
        #expect(
            manager.allProblemsDiagnostics.first?.documentVersion == 2
        )
        #expect(manager.diagnostics(for: url).count == 1)

        client.onDiagnostics?(LSPDiagnosticsNotification(
            uri: url.absoluteString,
            diagnostics: [diagnostic]
        ))
        #expect(manager.allProblemsDiagnostics.count == 1)
        #expect(manager.allProblemsDiagnostics.first?.documentVersion == nil)
        #expect(manager.allProblemsDiagnostics.first?.contentRevision == 8)
        #expect(manager.diagnostics(for: url).count == 1)

        manager.didClose(url: url)
        #expect(manager.allProblemsDiagnostics.isEmpty)
        #expect(manager.diagnostics(for: url).isEmpty)
    }

    @Test("Publish diagnostics flow through the project aggregate and stale rows expire")
    func publishDiagnosticsIntegrationWithProblemsController() async throws {
        let settings = makeSettings()
        let client = RecordingLSPClient()
        let manager = LSPManager(
            settings: settings,
            resolver: TestLSPResolver(executablePath: "/bin/echo")
        ) { _ in client }
        let controller = ProblemsPanelController(lspManager: manager)
        let paneID = PaneID()
        let tabID = UUID()
        let url = URL(fileURLWithPath: "/project/App.swift")
        let owner = controller.documentOwner(
            paneID: paneID,
            tabID: tabID,
            uri: url.absoluteString
        )
        var revision: UInt64 = 3
        controller.configureDocumentStatesProvider {
            [
                ProblemsDocumentState(
                    owner: owner,
                    contentRevision: revision,
                    isFocusedPane: true
                )
            ]
        }
        let diagnostic = try #require(LSPDiagnostic(json: [
            "range": [
                "start": ["line": 2, "character": 5],
                "end": ["line": 2, "character": 8]
            ],
            "severity": 1,
            "source": "sourcekit-lsp",
            "message": "type mismatch"
        ]))

        manager.didOpen(
            url: url,
            ownerID: tabID,
            contentRevision: revision,
            text: "let value = 1"
        )
        await waitUntil { client.opens.count == 1 }
        client.onDiagnostics?(LSPDiagnosticsNotification(
            uri: url.absoluteString,
            version: 1,
            diagnostics: [diagnostic]
        ))

        #expect(controller.flatDiagnostics.count == 1)
        let captured = try #require(controller.flatDiagnostics.first)
        #expect(controller.summary.errorCount == 1)
        #expect(captured.diagnostic.line == 3)
        #expect(captured.diagnostic.column == 6)

        revision = 4
        manager.didChange(
            url: url,
            ownerID: tabID,
            contentRevision: revision,
            text: "let value = true"
        )
        controller.refreshDocumentOwnership()

        #expect(controller.summary.total == 0)
        #expect(controller.navigationTarget(for: captured) == nil)
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

    /// Polls `condition`, returning whether it ever became true.
    ///
    /// The result is `@discardableResult` because most call sites here only
    /// need the recorded issue. Any call site that goes on to index into
    /// something the wait was supposed to populate must *not* discard it — a
    /// soft timeout followed by a hard subscript is how a single flaky wait
    /// takes down the whole `PineTests` process (#1506).
    @discardableResult
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            await Task.yield()
        }
        Issue.record("Timed out waiting for LSP test state")
        return false
    }
}
