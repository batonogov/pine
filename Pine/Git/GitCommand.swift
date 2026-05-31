//
//  GitCommand.swift
//  Pine
//
//  Low-level git process execution. No business logic, no state.
//

import Foundation

/// Result of a git command invocation.
struct GitCommandResult: Sendable {
    let output: String
    let errorOutput: String
    let exitCode: Int32
}

/// Runs git commands as subprocesses with timeout support.
nonisolated enum GitCommand {

    /// Default timeout for git commands (30 seconds).
    static let defaultTimeout: TimeInterval = 30.0

    /// Executes `git` with the given arguments in the specified directory.
    ///
    /// - Parameters:
    ///   - arguments: Git subcommand and arguments (e.g. `["status", "--porcelain"]`).
    ///   - directory: Working directory for the git process.
    ///   - timeout: Maximum time to wait before terminating the process.
    /// - Returns: A `GitCommandResult` with stdout, stderr, and exit code.
    static func run(
        _ arguments: [String],
        at directory: URL,
        timeout: TimeInterval = defaultTimeout
    ) -> GitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()

            // Schedule a timeout to terminate hung processes
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
            }
            timer.resume()

            // Read pipe data before waitUntilExit to avoid deadlock:
            // if the process fills the pipe buffer, it blocks on write
            // and never exits, while we block on waitUntilExit.
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

            process.waitUntilExit()
            timer.cancel()
            return GitCommandResult(
                output: String(bytes: outData, encoding: .utf8) ?? "",
                errorOutput: String(bytes: errData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )
        } catch {
            return GitCommandResult(
                output: "",
                errorOutput: error.localizedDescription,
                exitCode: -1
            )
        }
    }
}
