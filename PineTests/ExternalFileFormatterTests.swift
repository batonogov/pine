//
//  ExternalFileFormatterTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("ExternalFileFormatter")
struct ExternalFileFormatterTests {

    /// Helper to create a formatter with a mock tool path (bypasses real PATH resolution).
    private func makeFormatter(
        extensions: [String] = ["tf"],
        arguments: [String] = ["fmt", "-"],
        runner: MockProcessRunner,
        toolPath: String? = "/mock/testfmt",
        timeout: TimeInterval = 5.0
    ) -> ExternalFileFormatter {
        ExternalFileFormatter(
            toolPath: toolPath,
            toolName: "testfmt",
            extensions: extensions,
            arguments: arguments,
            processRunner: runner.run,
            timeout: timeout
        )
    }

    // MARK: - ProcessRunner protocol for testability

    @Test("Successful formatting returns stdout")
    func successfulFormat() {
        let runner = MockProcessRunner(stdout: "formatted output", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format("unformatted", url: URL(fileURLWithPath: "/tmp/main.tf"))
        #expect(result == "formatted output")
    }

    @Test("Non-zero exit code returns original content")
    func nonZeroExitFallback() {
        let runner = MockProcessRunner(stdout: "partial", stderr: "error: syntax", exitCode: 1)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format("original", url: URL(fileURLWithPath: "/tmp/main.tf"))
        #expect(result == "original")
    }

    @Test("Empty stdout on success returns original (safety)")
    func emptyStdoutFallback() {
        let runner = MockProcessRunner(stdout: "", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format("original", url: URL(fileURLWithPath: "/tmp/main.tf"))
        #expect(result == "original")
    }

    @Test("Process launch failure returns original content")
    func launchFailureFallback() {
        let runner = MockProcessRunner(error: NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "launch failed"]
        ))
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format("original", url: URL(fileURLWithPath: "/tmp/main.tf"))
        #expect(result == "original")
    }

    @Test("Timeout returns original content")
    func timeoutFallback() {
        let runner = MockProcessRunner(stdout: "", stderr: "", exitCode: 0, simulateTimeout: true)
        let formatter = makeFormatter(runner: runner, timeout: 0.1)
        let result = formatter.format("original", url: URL(fileURLWithPath: "/tmp/main.tf"))
        #expect(result == "original")
    }

    // MARK: - canFormat gating

    @Test("canFormat matches configured extensions")
    func canFormatMatches() {
        let runner = MockProcessRunner(stdout: "", stderr: "", exitCode: 0)
        let formatter = makeFormatter(extensions: ["tf", "hcl"], runner: runner)
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/tmp/main.tf")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/tmp/config.hcl")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/tmp/main.swift")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/tmp/main.json")))
    }

    @Test("canFormat is case-insensitive")
    func canFormatCaseInsensitive() {
        let runner = MockProcessRunner(stdout: "", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/tmp/main.TF")))
    }

    @Test("canFormat returns false when tool is not resolved")
    func canFormatNoTool() {
        let runner = MockProcessRunner(stdout: "", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner, toolPath: nil)
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/tmp/main.tf")))
    }

    // MARK: - stdin piping

    @Test("Content is sent via stdin to the process")
    func stdinPiping() {
        let runner = MockProcessRunner(stdout: "FORMATTED", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        _ = formatter.format("input content", url: URL(fileURLWithPath: "/tmp/main.tf"))
        #expect(runner.lastStdinContent == "input content")
    }

    // MARK: - format with nil toolPath returns original

    @Test("format returns original content when toolPath is nil")
    func formatWithNilToolPath() {
        let runner = MockProcessRunner(stdout: "should not appear", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner, toolPath: nil)
        let result = formatter.format("original", url: URL(fileURLWithPath: "/tmp/main.tf"))
        #expect(result == "original")
    }

    // MARK: - Integration with real Process

    @Test("Integration: formats via real /bin/cat (identity transform)")
    func integrationWithCat() {
        // runRealProcess() requires a non-main thread.
        // Swift Testing runs on the cooperative executor which may map to main,
        // so we dispatch to a real GCD background thread.
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = ""

        DispatchQueue.global().async {
            let formatter = ExternalFileFormatter(
                toolPath: "/bin/cat",
                toolName: "cat",
                extensions: ["txt"],
                arguments: []
            )
            result = formatter.format("hello world", url: URL(fileURLWithPath: "/tmp/test.txt"))
            semaphore.signal()
        }

        semaphore.wait()
        #expect(result == "hello world")
    }

    @Test("Timeout kills a TERM-ignoring process group and closes pipes")
    func timeoutKillsProcessGroup() {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ProcessRunResult?
        nonisolated(unsafe) var elapsed: TimeInterval = 0

        DispatchQueue.global().async {
            let start = Date()
            result = runRealProcess(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' TERM; sleep 10 & wait",
                ],
                stdin: "",
                timeout: 0.2
            )
            elapsed = Date().timeIntervalSince(start)
            semaphore.signal()
        }

        #expect(semaphore.wait(timeout: .now() + 1) == .success)
        #expect(result?.timedOut == true)
        #expect(elapsed < 0.5)
    }

    // MARK: - Registry integration

    @Test("ExternalFileFormatter works in FileFormatterRegistry")
    func registryIntegration() {
        let runner = MockProcessRunner(stdout: "terraform-formatted", stderr: "", exitCode: 0)
        let extFormatter = makeFormatter(runner: runner)
        let registry = FileFormatterRegistry(formatters: [JSONFileFormatter(), extFormatter])

        // .tf file should be handled by external formatter
        let tfResult = registry.format(
            content: "resource {}",
            url: URL(fileURLWithPath: "/tmp/main.tf")
        )
        #expect(tfResult == "terraform-formatted")

        // .json file should still be handled by JSON formatter
        let jsonResult = registry.format(
            content: #"{"a":1}"#,
            url: URL(fileURLWithPath: "/tmp/a.json")
        )
        #expect(jsonResult.contains("\"a\" : 1"))
    }
}

// MARK: - Mock ProcessRunner

/// Test double that records the last stdin content and returns canned output.
/// Exposes its `run` method directly as a `ProcessRunner` closure via `runner.run`.
nonisolated final class MockProcessRunner: @unchecked Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let error: Error?
    let simulateTimeout: Bool
    private(set) var lastStdinContent: String?

    init(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        error: Error? = nil,
        simulateTimeout: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.error = error
        self.simulateTimeout = simulateTimeout
    }

    func run(
        executablePath: String,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        lastStdinContent = stdin
        if let error {
            return ProcessRunResult(stdout: "", stderr: error.localizedDescription, exitCode: -1, timedOut: false)
        }
        if simulateTimeout {
            return ProcessRunResult(stdout: "", stderr: "timed out", exitCode: -1, timedOut: true)
        }
        return ProcessRunResult(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: false)
    }
}
