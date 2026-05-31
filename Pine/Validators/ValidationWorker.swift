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

    /// Runs validation on the current thread (expected to be called from a background queue).
    /// Returns parsed diagnostics and whether an external tool was available.
    static func runValidation(
        url: URL,
        content: String,
        kind: ValidatorKind
    ) -> (diagnostics: [ValidationDiagnostic], toolAvailable: Bool) {
        // Check tool availability
        let toolPath = ToolAvailability.path(for: kind.toolName)
        let hasExternalTool = toolPath != nil

        // Run external tool if available
        var parsed: [ValidationDiagnostic] = []
        if let toolPath = toolPath {
            // Write content to temp file for validation
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)

            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: tempFile) }

                let result = runTool(toolPath: toolPath, kind: kind, filePath: tempFile.path)

                switch kind {
                case .yamllint:
                    parsed = ValidatorOutputParser.parseYamllint(result)
                case .shellcheck:
                    parsed = ValidatorOutputParser.parseShellcheck(result)
                case .terraform:
                    parsed = ValidatorOutputParser.parseTerraform(result)
                case .hadolint:
                    parsed = ValidatorOutputParser.parseHadolint(result)
                }
            } catch {
                // Temp file write failed — fall through to built-in
            }
        }

        // Fall back to built-in validation only when external tool is not installed.
        // If external tool is installed and returned empty output, the file is valid.
        if parsed.isEmpty && !hasExternalTool {
            switch kind {
            case .yamllint:
                parsed = BuiltinValidator.validateYAML(content)
            case .hadolint:
                parsed = BuiltinValidator.validateDockerfile(content)
            case .shellcheck:
                parsed = BuiltinValidator.validateShell(content)
            case .terraform:
                break // No built-in terraform validation
            }
        }

        return (parsed, hasExternalTool)
    }

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
