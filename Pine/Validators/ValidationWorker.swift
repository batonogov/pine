//
//  ValidationWorker.swift
//  Pine
//
//  Extracted from ConfigValidator.swift — background validation dispatch.
//

import Foundation

// MARK: - ConfigValidationWorker

/// Namespace for config validation work that runs on background threads.
/// Deliberately **not** `@MainActor` so closures inside `DispatchQueue.global().async`
/// do not inherit MainActor isolation — prevents `dispatch_assert_queue_fail`
/// crash under Swift 6 strict concurrency.
/// Marked `nonisolated` to opt out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated enum ConfigValidationWorker {

    /// Runs an external validation tool and returns its raw output.
    /// Called by the `LanguageValidator` default implementation.
    static func runTool(toolPath: String, kind: ValidatorKind, filePath: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)

        switch kind {
        case .yamllint:
            process.arguments = ["-f", "parsable", filePath]
        case .shellcheck:
            process.arguments = ["-f", "json", filePath]
        case .terraform:
            // terraform validate needs to run in the file's directory
            let dir = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
            process.arguments = ["validate", "-json"]
        case .hadolint:
            process.arguments = ["--format", "json", filePath]
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Ensure common tool paths are available
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        process.environment = env

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        // yamllint outputs to stdout, shellcheck to stdout, terraform to stdout
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        // Some tools output to stderr (yamllint parsable goes to stdout)
        let output = String(data: outData, encoding: .utf8) ?? ""
        let errOutput = String(data: errData, encoding: .utf8) ?? ""

        // Return whichever has content
        return output.isEmpty ? errOutput : output
    }
}
