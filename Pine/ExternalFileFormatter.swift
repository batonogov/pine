//
//  ExternalFileFormatter.swift
//  Pine
//

import Foundation

/// Result of running an external process.
struct ProcessRunResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool
}

/// Abstraction for running external processes. Allows mocking in tests.
protocol ProcessRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval
    ) -> ProcessRunResult
}

/// Runs a real `Process` with stdin/stdout piping and a timeout.
struct RealProcessRunner: ProcessRunning {
    func run(
        executablePath: String,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            // Write stdin content and close
            if let data = stdin.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            stdinPipe.fileHandleForWriting.closeFile()

            // Schedule timeout
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            var timedOut = false
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                timedOut = true
                if process.isRunning {
                    process.terminate()
                }
            }
            timer.resume()

            // Read pipes before waitUntilExit to avoid deadlock
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            process.waitUntilExit()
            timer.cancel()

            return ProcessRunResult(
                stdout: String(bytes: outData, encoding: .utf8) ?? "",
                stderr: String(bytes: errData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus,
                timedOut: timedOut
            )
        } catch {
            return ProcessRunResult(
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: -1,
                timedOut: false
            )
        }
    }
}

/// A file formatter that delegates to an external CLI tool via stdin/stdout.
///
/// Falls back to the original content on any failure: tool not found, non-zero exit,
/// timeout, or empty output. This guarantees save never blocks on a broken tool.
final class ExternalFileFormatter: FileFormatter, @unchecked Sendable {

    /// Display name of the tool (e.g. "terraform", "shfmt", "prettier").
    let toolName: String

    /// File extensions this formatter handles (lowercase, without dot).
    let extensions: Set<String>

    /// Arguments to pass to the tool (the content comes via stdin).
    let arguments: [String]

    /// Maximum time to wait for the tool to finish.
    let timeout: TimeInterval

    /// Resolved path to the executable, or nil if not found.
    private(set) var toolPath: String?

    private let processRunner: ProcessRunning

    /// Creates an external file formatter.
    ///
    /// - Parameters:
    ///   - toolName: Name of the tool binary.
    ///   - extensions: File extensions to handle (without dot, case-insensitive).
    ///   - arguments: Arguments to pass to the tool.
    ///   - processRunner: Process runner implementation (use `RealProcessRunner` in production).
    ///   - toolPath: Override the tool path (skips resolution). If nil and a real runner is used,
    ///               the tool will be resolved via `ExternalToolResolver`.
    ///   - timeout: Maximum execution time (default 5 seconds).
    init(
        toolName: String,
        extensions: [String],
        arguments: [String],
        processRunner: ProcessRunning = RealProcessRunner(),
        toolPath: String? = "RESOLVE",
        timeout: TimeInterval = 5.0
    ) {
        self.toolName = toolName
        self.extensions = Set(extensions.map { $0.lowercased() })
        self.arguments = arguments
        self.processRunner = processRunner
        self.timeout = timeout

        if toolPath == "RESOLVE" {
            // Auto-resolve from PATH
            self.toolPath = ExternalToolResolver.fromEnvironment().resolve(tool: toolName)
        } else {
            self.toolPath = toolPath
        }
    }

    func canFormat(url: URL) -> Bool {
        guard toolPath != nil else { return false }
        let ext = url.pathExtension.lowercased()
        return extensions.contains(ext)
    }

    func format(_ content: String, url: URL) -> String {
        guard let executablePath = toolPath else {
            return content
        }

        let result = processRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            stdin: content,
            timeout: timeout
        )

        // Fall back to original on any failure
        guard !result.timedOut,
              result.exitCode == 0,
              !result.stdout.isEmpty else {
            return content
        }

        return result.stdout
    }
}
