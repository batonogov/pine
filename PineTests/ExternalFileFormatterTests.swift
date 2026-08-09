//
//  ExternalFileFormatterTests.swift
//  PineTests
//

import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("ExternalFileFormatter", .serialized)
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

    @Test("Formatter preserves the process-group leader until its final signal")
    func formatterReapsOnlyAfterSafeBoundary() {
        #expect(formatterShouldAttemptReap(
            terminationStarted: false,
            streamsAreClosed: true
        ))
        #expect(!formatterShouldAttemptReap(
            terminationStarted: false,
            streamsAreClosed: false
        ))
        #expect(!formatterShouldAttemptReap(
            terminationStarted: true,
            streamsAreClosed: true
        ))
        #expect(!formatterShouldAttemptReap(
            terminationStarted: true,
            streamsAreClosed: false
        ))
    }

    @Test("Continuous stdout cannot evade the monotonic timeout")
    func continuousOutputHonorsTimeout() {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ProcessRunResult?
        nonisolated(unsafe) var elapsed: TimeInterval = 0

        DispatchQueue.global().async {
            let start = Date()
            result = runRealProcess(
                executablePath: "/usr/bin/awk",
                arguments: [
                    "BEGIN { while (1) print \"0123456789abcdef0123456789abcdef\" }",
                ],
                stdin: "",
                timeout: 0.05,
                outputLimits: ProcessOutputLimits(
                    stdoutBytes: 32 * 1_024 * 1_024,
                    stderrBytes: 1_024
                )
            )
            elapsed = Date().timeIntervalSince(start)
            semaphore.signal()
        }

        #expect(semaphore.wait(timeout: .now() + 1) == .success)
        #expect(result?.timedOut == true)
        #expect(result?.outputLimitExceeded == false)
        #expect(elapsed < 0.5)
    }

    @Test("Output cap terminates a producer and reports explicit failure")
    func outputCapFailsWithoutReturningTruncatedOutput() {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ProcessRunResult?
        nonisolated(unsafe) var elapsed: TimeInterval = 0

        DispatchQueue.global().async {
            let start = Date()
            result = runRealProcess(
                executablePath: "/usr/bin/yes",
                arguments: [],
                stdin: "",
                timeout: 1,
                outputLimits: ProcessOutputLimits(
                    stdoutBytes: 32 * 1_024,
                    stderrBytes: 1_024
                )
            )
            elapsed = Date().timeIntervalSince(start)
            semaphore.signal()
        }

        #expect(semaphore.wait(timeout: .now() + 1) == .success)
        #expect(result?.outputLimitExceeded == true)
        #expect(result?.timedOut == false)
        #expect(result?.stdout.utf8.count == 32 * 1_024)
        #expect(elapsed < 0.5)
    }

    @Test("Stderr has an independent bounded capture cap")
    func stderrCapTerminatesProducer() {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ProcessRunResult?

        DispatchQueue.global().async {
            result = runRealProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", "exec /usr/bin/yes >&2"],
                stdin: "",
                timeout: 1,
                outputLimits: ProcessOutputLimits(
                    stdoutBytes: 1_024,
                    stderrBytes: 8 * 1_024
                )
            )
            semaphore.signal()
        }

        #expect(semaphore.wait(timeout: .now() + 1) == .success)
        #expect(result?.outputLimitExceeded == true)
        #expect(result?.timedOut == false)
        #expect(result?.stderr.utf8.count == 8 * 1_024)
    }

    @Test("Spawn closes unrelated inheritable descriptors")
    func spawnDoesNotInheritUnrelatedDescriptor() throws {
        let descriptor = Darwin.open("/dev/null", O_RDONLY)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
        #expect(descriptorFlags >= 0)
        guard descriptorFlags >= 0 else { return }
        #expect(Darwin.fcntl(
            descriptor,
            F_SETFD,
            descriptorFlags & ~FD_CLOEXEC
        ) == 0)

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ProcessRunResult?
        DispatchQueue.global().async {
            result = runRealProcess(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    "if test -e /dev/fd/\(descriptor); then printf leaked; else printf closed; fi",
                ],
                stdin: "",
                timeout: 1
            )
            semaphore.signal()
        }

        #expect(semaphore.wait(timeout: .now() + 2) == .success)
        #expect(result?.exitCode == 0)
        #expect(result?.stdout == "closed")
    }

    @Test("Formatter rejects output explicitly marked as overflowed")
    func formatterRejectsOverflowedOutput() {
        let runner = MockProcessRunner(
            stdout: "truncated",
            stderr: "",
            exitCode: 0,
            outputLimitExceeded: true
        )
        let formatter = makeFormatter(runner: runner)

        #expect(formatter.format(
            "original",
            url: URL(fileURLWithPath: "/tmp/main.tf")
        ) == "original")
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
    let outputLimitExceeded: Bool
    private(set) var lastStdinContent: String?

    init(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        error: Error? = nil,
        simulateTimeout: Bool = false,
        outputLimitExceeded: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.error = error
        self.simulateTimeout = simulateTimeout
        self.outputLimitExceeded = outputLimitExceeded
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
        return ProcessRunResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            timedOut: false,
            outputLimitExceeded: outputLimitExceeded
        )
    }
}
