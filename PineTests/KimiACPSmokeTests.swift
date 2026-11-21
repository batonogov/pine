import Foundation
import Synchronization
import Testing
@testable import Pine

/// FINAL GATE: bounded discovery + ACP handshake against the real Kimi Code
/// CLI. Opt-in: pass PINE_RUN_KIMI_ACP_SMOKE=1 as a test-run environment
/// variable; without it the test skips (CI has no binary and is
/// intentionally not the gate; the fixture-level codec/mapping/state machine
/// coverage remains the deterministic gate). When opted in: no auth
/// mutations, no paid calls, no session creation — only `kimi --version` and
/// the `initialize` exchange, then the child is terminated. A missing binary
/// or a version mismatch fails: a pin is a pin, and re-pinning goes through
/// a fresh dated observation.
nonisolated private enum KimiACPSmokeConfiguration {
    static let optInEnvironmentVariable = "PINE_RUN_KIMI_ACP_SMOKE"

    static let isOptedIn =
        ProcessInfo.processInfo.environment[optInEnvironmentVariable] == "1"

    static var skipReason: String {
        "Pass PINE_RUN_KIMI_ACP_SMOKE=1 to run the real-version gate "
        + "(discovery-only, no prompts); CI runs are intentionally not the gate."
    }
}

struct KimiACPSmokeTests {
    private static let searchPaths = ["/opt/homebrew/bin/kimi", "/usr/local/bin/kimi"]

    private static func findBinary() -> URL? {
        if let override = ProcessInfo.processInfo.environment["PINE_KIMI_BINARY"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for candidate in searchPaths {
            let url = URL(fileURLWithPath: candidate)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    @Test(
        .enabled(
            if: KimiACPSmokeConfiguration.isOptedIn,
            Comment(
                rawValue: KimiACPSmokeConfiguration.skipReason
            )
        )
    )
    func boundedDiscoveryAndInitializeHandshake() async throws {
        // Opted in: the gate must run, so a missing binary is a hard
        // failure, never a silent skip.
        guard let binary = Self.findBinary() else {
            Issue.record("Real-version smoke: kimi binary not found")
            return
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))

        // Isolation: fresh cwd + minimal env so the child never reads the
        // test host's provider state or configuration.
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "pine-kimi-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        var environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        for key in ["HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"] {
            let directory = sandbox.appending(path: key)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            environment[key] = directory.path
        }

        // 1. Version discovery: read-only, no provider state touched.
        let versionResult = await runOnBackground {
            GitCommand.runExecutable(binary, arguments: ["--version"],
                                     at: sandbox,
                                     timeout: 10, captureLimit: 4_096)
        }
        guard versionResult.succeeded else {
            Issue.record("Real-version smoke: `kimi --version` exited \(versionResult.exitCode)")
            return
        }
        let version = versionResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            Issue.record("Real-version smoke: empty version output")
            return
        }
        // A pin is a pin: a mismatched binary fails the gate and stops before
        // the handshake; re-pinning goes through a fresh dated observation.
        guard version == KimiACPCapabilities.pinnedCLIVersion else {
            let message = "Real-version smoke: installed \(version) differs from pinned "
                + "\(KimiACPCapabilities.pinnedCLIVersion); re-pin through a fresh observation"
            Issue.record(Comment(rawValue: message))
            return
        }

        // 2. ACP initialize handshake only. The child is terminated before
        // any session call, so no session is created and nothing is billed.
        let process = Process()
        process.executableURL = binary
        process.arguments = KimiACPLaunchArguments.subcommand
        process.currentDirectoryURL = sandbox
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        // Drain and discard stderr: it may carry provider diagnostics and
        // secrets; retention is the regression the fixtures guard against.
        let stderrDrain = Task.detached {
            _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
        }
        defer { stderrDrain.cancel() }

        let message = CodexAppServerMessage.request(
            .integer(0), method: "initialize", params: .object([
                "protocolVersion": .number("1"),
                "clientCapabilities": .object([
                    "elicitation": .object(["form": .object([:])])
                ]),
                "clientInfo": .object([
                    "name": .string("pine"), "title": .string("Pine"), "version": .string("3.0")
                ])
            ])
        )
        let bytes = try KimiACPWire.encode(message)
        // Pipe writes are file I/O: keep them off the test actor.
        try await runOnBackground {
            inputPipe.fileHandleForWriting.write(bytes)
        }

        let line = try await readHandshakeLine(
            outputPipe.fileHandleForReading, deadline: deadline,
            forceClose: { process.terminate() }
        )
        // Reap off-actor; a terminated child exits promptly on SIGTERM.
        _ = Task.detached { process.waitUntilExit() }
        let response = try CodexAppServerMessage(data: Data(line.utf8))
        guard case .response(let id, let result) = response, id == .integer(0) else {
            Issue.record("Real-version smoke: initialize did not produce a correlated response")
            return
        }
        // The version gate above already failed on mismatch, so the pinned
        // exact-version identity check is the assertion that matters here.
        let identity = try KimiACPAgentIdentity(
            response: result, agentName: "Kimi Code CLI",
            pinnedVersion: KimiACPCapabilities.pinnedCLIVersion
        )
        #expect(identity.capabilities.loadSession, "Real-version smoke: loadSession matrix")
    }

    private func readHandshakeLine(_ handle: FileHandle, deadline: ContinuousClock.Instant,
                                   forceClose: @escaping @Sendable () -> Void) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                let state = Mutex<CheckedContinuation<String, any Error>?>(continuation)
                func finish(_ result: Result<String, any Error>) {
                    let pending: CheckedContinuation<String, any Error>? = state.withLock { value in
                        guard let pending = value else { return nil }
                        value = nil
                        return pending
                    }
                    switch result {
                    case .success(let value): pending?.resume(returning: value)
                    case .failure(let error): pending?.resume(throwing: error)
                    }
                }
                DispatchQueue.global().async {
                    var data = Data()
                    while data.last != 10 {
                        guard let byte = try? handle.read(upToCount: 1), let first = byte.first else {
                            finish(.failure(KimiACPWireError.closed))
                            return
                        }
                        guard first == 10 || data.count < KimiACPWire.maximumFrameBytes else {
                            finish(.failure(KimiACPWireError.capacity))
                            return
                        }
                        data.append(first)
                    }
                    guard let text = String(data: data, encoding: .utf8) else {
                        finish(.failure(KimiACPWireError.invalidProtocol))
                        return
                    }
                    finish(.success(text))
                }
                let watchdog = Task {
                    do {
                        try await Task.sleep(until: deadline, clock: .continuous)
                        // finish() is idempotent: a settled read makes this a
                        // no-op; only a still-pending handshake force-closes
                        // the child (EOF unblocks the reader) and fails.
                        if state.withLock({ $0 != nil }) { forceClose() }
                        finish(.failure(KimiACPWireError.unavailable))
                    } catch { /* The read settled first. */ }
                }
                _ = watchdog
            }
        } onCancel: { forceClose() }
    }
}
