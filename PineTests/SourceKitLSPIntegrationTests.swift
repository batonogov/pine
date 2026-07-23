//
//  SourceKitLSPIntegrationTests.swift
//  PineTests
//
//  Opt-in smoke coverage for Pine's real SourceKit-LSP process path.
//

import Darwin
import Foundation
import Testing
@testable import Pine

@Suite("SourceKit-LSP Integration Smoke", .serialized)
@MainActor
struct SourceKitLSPIntegrationTests {
    @Test(
        "Initialize, diagnose, query, and shut down SourceKit-LSP",
        .enabled(
            if: SourceKitLSPSmokeConfiguration.isRunnable,
            Comment(
                rawValue: SourceKitLSPSmokeConfiguration.skipReason
            )
        ),
        .timeLimit(.minutes(1))
    )
    func realSourceKitLSPRoundTrip() async throws {
        let fixture = try SourceKitLSPFixture()
        defer { fixture.remove() }

        let stderrHandle = try FileHandle(forWritingTo: fixture.stderrURL)
        defer { try? stderrHandle.close() }

        let client = LSPClient(language: "swift")
        var didShutDown = false
        defer {
            if !didShutDown {
                client.shutdown()
            }
        }

        do {
            let sourceKitPath = try #require(
                SourceKitLSPSmokeConfiguration.sourceKitLSPPath
            )
            let started = try await boundedValue(
                step: "initialize",
                timeout: .seconds(20),
                client: client
            ) {
                await client.start(
                    command: sourceKitPath,
                    arguments: [
                        "--scratch-path",
                        fixture.scratchURL.path,
                        "--default-workspace-type",
                        "swiftPM"
                    ],
                    rootURI: fixture.rootURL.absoluteString,
                    environment: fixture.environment,
                    currentDirectoryURL: fixture.rootURL,
                    standardError: stderrHandle
                )
            }
            guard started else {
                throw SourceKitLSPSmokeError.failed("initialize returned false")
            }

            var diagnostics: [LSPDiagnostic] = []
            client.onDiagnostics = { notification in
                guard fixture.matchesDocumentURI(notification.uri) else {
                    return
                }
                diagnostics = notification.diagnostics
            }
            client.didOpen(
                uri: fixture.fileURL.absoluteString,
                language: "swift",
                version: 1,
                text: fixture.source
            )

            try await waitUntil(
                step: "publishDiagnostics",
                timeout: .seconds(20)
            ) {
                diagnostics.contains {
                    $0.range.start.line == fixture.diagnosticLine
                        && !$0.message.isEmpty
                }
            }

            let symbolOffset = try #require(fixture.callSymbolOffset)
            let position = LSPPositionConverter.lspPosition(
                utf16Offset: symbolOffset,
                in: fixture.source
            )
            #expect(position.line == fixture.callLine)
            #expect(position.character == fixture.callCharacter)

            let hover = try await boundedValue(
                step: "textDocument/hover",
                timeout: .seconds(10),
                client: client
            ) {
                await client.hover(
                    uri: fixture.fileURL.absoluteString,
                    position: position
                )
            }
            guard let hover,
                  hover.markup.value.localizedCaseInsensitiveContains("greet")
                    || hover.markup.value.contains("String") else {
                throw SourceKitLSPSmokeError.failed(
                    "hover did not describe the greet symbol"
                )
            }

            let definition = try await boundedValue(
                step: "textDocument/definition",
                timeout: .seconds(10),
                client: client
            ) {
                await client.definition(
                    uri: fixture.fileURL.absoluteString,
                    position: position
                )
            }
            guard fixture.matchesDefinition(definition) else {
                throw SourceKitLSPSmokeError.failed(
                    "definition did not resolve to the fixture method"
                )
            }

            let cleanShutdown = await client.shutdownGracefully(
                timeout: .seconds(5)
            )
            didShutDown = true
            guard cleanShutdown,
                  client.state == .exited,
                  !client.transport.isRunning else {
                throw SourceKitLSPSmokeError.failed(
                    "server did not acknowledge shutdown and exit naturally"
                )
            }
        } catch {
            if !didShutDown {
                client.shutdown()
                didShutDown = true
            }
            let stderr = fixture.readCapturedStderr(
                synchronizing: stderrHandle
            )
            Issue.record(
                """
                SourceKit-LSP smoke failed: \(error)

                Captured server stderr:
                \(stderr.isEmpty ? "<empty>" : stderr)
                """
            )
        }
    }
}

nonisolated private enum SourceKitLSPSmokeConfiguration {
    static let optInEnvironmentVariable = "PINE_RUN_SOURCEKIT_LSP_SMOKE"

    static let isOptedIn =
        ProcessInfo.processInfo.environment[optInEnvironmentVariable] == "1"

    static let sourceKitLSPPath =
        isOptedIn ? resolveSourceKitLSP() : nil

    static var isRunnable: Bool {
        isOptedIn && sourceKitLSPPath != nil
    }

    static var skipReason: String {
        if !isOptedIn {
            return """
            Pass PINE_RUN_SOURCEKIT_LSP_SMOKE=1 as an xcodebuild setting
            """
        }
        return """
        sourcekit-lsp is unavailable through the active DEVELOPER_DIR
        """
    }

    private static func resolveSourceKitLSP() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let developerDirectory = environment["DEVELOPER_DIR"] {
            let candidate = URL(fileURLWithPath: developerDirectory)
                .appendingPathComponent(
                    "Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
                )
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "sourcekit-lsp"]
        process.environment = environment

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }

        guard (try? process.run()) != nil else { return nil }
        guard exitSemaphore.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            if exitSemaphore.wait(timeout: .now() + 0.5) == .timedOut,
               process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exitSemaphore.wait(timeout: .now() + 0.5)
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty,
              FileManager.default.isExecutableFile(atPath: output) else {
            return nil
        }
        return output
    }
}

private struct SourceKitLSPFixture {
    let rootURL: URL
    let fileURL: URL
    let scratchURL: URL
    let stderrURL: URL
    let source: String

    let diagnosticLine = 8
    let callLine = 7
    let callCharacter = 20

    init() throws {
        let fileManager = FileManager.default
        rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "PineSourceKitLSPSmoke-\(UUID().uuidString)",
            isDirectory: true
        )
        scratchURL = rootURL.appendingPathComponent(
            ".build",
            isDirectory: true
        )
        stderrURL = rootURL.appendingPathComponent("sourcekit-lsp.stderr")
        fileURL = rootURL.appendingPathComponent(
            "Sources/Smoke/main.swift"
        )
        source = """
        struct Greeter {
            let message: String
            func greet() -> String { message }
        }

        let tree = "🌲"
        let greeter = Greeter(message: tree)
        print("🌲", greeter.greet())
        let broken: Int = tree

        """

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: rootURL.appendingPathComponent("home"),
            withIntermediateDirectories: true
        )
        for directory in [
            "config",
            "cache",
            "tmp",
            "module-cache",
            "swiftpm-config"
        ] {
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }

        let packageManifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "PineSourceKitLSPSmoke",
            targets: [
                .executableTarget(name: "Smoke")
            ]
        )

        """
        try packageManifest.write(
            to: rootURL.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try source.write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        guard fileManager.createFile(
            atPath: stderrURL.path,
            contents: nil
        ) else {
            throw SourceKitLSPSmokeError.failed(
                "could not create stderr capture"
            )
        }
    }

    var environment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let inheritedKeys = [
            "DEVELOPER_DIR",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "SDKROOT",
            "TOOLCHAINS"
        ]
        var result = inheritedKeys.reduce(into: [String: String]()) {
            if let value = inherited[$1] {
                $0[$1] = value
            }
        }

        var executablePaths: [String] = []
        if let developerDirectory = inherited["DEVELOPER_DIR"] {
            executablePaths.append(
                URL(fileURLWithPath: developerDirectory)
                    .appendingPathComponent(
                        "Toolchains/XcodeDefault.xctoolchain/usr/bin"
                    )
                    .path
            )
            executablePaths.append(
                URL(fileURLWithPath: developerDirectory)
                    .appendingPathComponent("usr/bin")
                    .path
            )
        }
        executablePaths += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        result["PATH"] = executablePaths.joined(separator: ":")

        let isolatedHome =
            rootURL.appendingPathComponent("home").path
        result["HOME"] = isolatedHome
        result["CFFIXED_USER_HOME"] = isolatedHome
        result["PWD"] = rootURL.path
        result["XDG_CONFIG_HOME"] =
            rootURL.appendingPathComponent("config").path
        result["XDG_CACHE_HOME"] =
            rootURL.appendingPathComponent("cache").path
        result["TMPDIR"] =
            rootURL.appendingPathComponent("tmp").path + "/"
        result["SWIFTPM_MODULECACHE_OVERRIDE"] =
            rootURL.appendingPathComponent("module-cache").path
        result["CLANG_MODULE_CACHE_PATH"] =
            rootURL.appendingPathComponent("module-cache").path
        result["SWIFTPM_CONFIG_DIR"] =
            rootURL.appendingPathComponent("swiftpm-config").path
        return result
    }

    var callSymbolOffset: Int? {
        let range = (source as NSString).range(
            of: "greet",
            options: .backwards
        )
        return range.location == NSNotFound ? nil : range.location
    }

    func matchesDocumentURI(_ uri: String) -> Bool {
        guard let url = URL(string: uri) else { return false }
        return canonicalFileURL(url) == canonicalFileURL(fileURL)
    }

    func matchesDefinition(_ response: LSPDefinitionResponse) -> Bool {
        let expectedURL = canonicalFileURL(fileURL)
        switch response {
        case .empty:
            return false
        case .locations(let locations):
            return locations.contains {
                $0.url.map(canonicalFileURL) == expectedURL
                    && $0.range.start.line == 2
            }
        case .locationLinks(let links):
            return links.contains {
                URL(string: $0.targetUri).map(canonicalFileURL)
                    == expectedURL
                    && $0.targetSelectionRange.start.line == 2
            }
        }
    }

    func readCapturedStderr(synchronizing handle: FileHandle) -> String {
        try? handle.synchronize()
        guard let data = try? Data(contentsOf: stderrURL) else { return "" }
        let boundedData = Data(data.suffix(16 * 1024))
        return String(data: boundedData, encoding: .utf8) ?? "<non-UTF-8>"
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func canonicalFileURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let path = standardized.hasPrefix("/private/")
            ? String(standardized.dropFirst("/private".count))
            : standardized
        return URL(fileURLWithPath: path)
    }
}

private enum SourceKitLSPSmokeError: Error, CustomStringConvertible {
    case failed(String)
    case timeout(String)

    var description: String {
        switch self {
        case .failed(let detail):
            return detail
        case .timeout(let step):
            return "timed out waiting for \(step)"
        }
    }
}

private enum BoundedResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

@MainActor
private func boundedValue<Value: Sendable>(
    step: String,
    timeout: Duration,
    client: LSPClient,
    operation: @escaping @MainActor @Sendable () async -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(
        of: BoundedResult<Value>.self,
        returning: Value.self
    ) { group in
        group.addTask {
            .value(await operation())
        }
        group.addTask {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return .timedOut
            }
            return .timedOut
        }

        guard let first = try await group.next() else {
            client.shutdown()
            throw SourceKitLSPSmokeError.failed(
                "no result while waiting for \(step)"
            )
        }
        group.cancelAll()
        switch first {
        case .value(let value):
            return value
        case .timedOut:
            client.shutdown()
            throw SourceKitLSPSmokeError.timeout(step)
        }
    }
}

@MainActor
private func waitUntil(
    step: String,
    timeout: Duration,
    condition: @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        try Task.checkCancellation()
        guard clock.now < deadline else {
            throw SourceKitLSPSmokeError.timeout(step)
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}
