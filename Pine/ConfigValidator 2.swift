//
//  ConfigValidator.swift
//  Pine
//
//  Created by Claude on 29.03.2026.
//

import Foundation

// MARK: - Models

/// Severity of a validation diagnostic.
enum ValidationSeverity: Sendable, Equatable {
    case error
    case warning
    case info
}

/// A single validation diagnostic tied to a line in the file.
struct ValidationDiagnostic: Sendable, Equatable, Identifiable {
    let id = UUID()
    let line: Int
    let column: Int?
    let message: String
    let severity: ValidationSeverity
    /// The validator that produced this diagnostic (e.g. "yamllint", "shellcheck").
    let source: String

    static func == (lhs: ValidationDiagnostic, rhs: ValidationDiagnostic) -> Bool {
        lhs.line == rhs.line
            && lhs.column == rhs.column
            && lhs.message == rhs.message
            && lhs.severity == rhs.severity
            && lhs.source == rhs.source
    }
}

/// The type of config validator to use for a given file.
enum ValidatorKind: Sendable, Equatable {
    case yamllint
    case terraform
    case shellcheck
    case hadolint

    /// Display name for status bar / tooltips.
    var displayName: String {
        switch self {
        case .yamllint: return "yamllint"
        case .terraform: return "terraform"
        case .shellcheck: return "shellcheck"
        case .hadolint: return "hadolint"
        }
    }

    /// The command-line tool name.
    var toolName: String {
        switch self {
        case .yamllint: return "yamllint"
        case .terraform: return "terraform"
        case .shellcheck: return "shellcheck"
        case .hadolint: return "hadolint"
        }
    }
}

// MARK: - Validator Detection

/// Determines which validator to use based on file extension or name.
enum ValidatorDetector {
    static func detect(for url: URL) -> ValidatorKind? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        switch ext {
        case "yml", "yaml":
            return .yamllint
        case "tf", "tfvars":
            return .terraform
        case "sh", "bash", "zsh":
            return .shellcheck
        default:
            break
        }

        // Dockerfile detection by name
        if name == "dockerfile" || name.hasPrefix("dockerfile.") {
            return .hadolint
        }

        return nil
    }
}

// MARK: - Tool Availability

/// Checks whether a command-line tool is available via `which`.
enum ToolAvailability {
    /// Cached availability results to avoid repeated `which` calls.
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    /// Returns the full path to the tool if installed, nil otherwise.
    static func path(for tool: String) -> String? {
        lock.lock()
        if let cached = cache[tool] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result = runWhich(tool)

        lock.lock()
        cache[tool] = result
        lock.unlock()

        return result
    }

    /// Clears cached results (useful for testing).
    static func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static func runWhich(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [tool]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        // Add common tool paths
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "\(NSHomeDirectory())/.local/bin"
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        process.environment = env

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return path?.isEmpty == false ? path : nil
            }
        } catch {
            // Tool not found
        }
        return nil
    }
}

// MARK: - Output Parsers

/// Parses output from various config validators into diagnostics.
enum ValidatorOutputParser {

    // MARK: - yamllint

    /// Parses yamllint output in default format: `file.yml:3:1: [error] message`
    static func parseYamllint(_ output: String) -> [ValidationDiagnostic] {
        var diagnostics: [ValidationDiagnostic] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            guard let diagnostic = parseYamllintLine(line) else { continue }
            diagnostics.append(diagnostic)
        }
        return diagnostics
    }

    /// Parses a single yamllint output line.
    /// Format: `path:line:col: [level] message` or `path:line:col: [level] message (rule)`
    static func parseYamllintLine(_ line: String) -> ValidationDiagnostic? {
        // Pattern: anything:digits:digits: [error/warning] message
        let pattern = #"^.*?:(\d+):(\d+): \[(error|warning)\] (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 5 else {
            return nil
        }

        guard let lineRange = Range(match.range(at: 1), in: line),
              let colRange = Range(match.range(at: 2), in: line),
              let levelRange = Range(match.range(at: 3), in: line),
              let msgRange = Range(match.range(at: 4), in: line) else {
            return nil
        }

        guard let lineNum = Int(line[lineRange]),
              let colNum = Int(line[colRange]) else {
            return nil
        }

        let level = String(line[levelRange])
        let message = String(line[msgRange])
        let severity: ValidationSeverity = level == "error" ? .error : .warning

        return ValidationDiagnostic(
            line: lineNum,
            column: colNum,
            message: message,
            severity: severity,
            source: "yamllint"
        )
    }

    // MARK: - shellcheck

    /// Parses shellcheck JSON output.
    static func parseShellcheck(_ jsonOutput: String) -> [ValidationDiagnostic] {
        guard let data = jsonOutput.data(using: .utf8) else { return [] }

        struct ShellCheckItem: Decodable {
            let line: Int
            let column: Int
            let level: String
            let message: String
            let code: Int
        }

        guard let items = try? JSONDecoder().decode([ShellCheckItem].self, from: data) else {
            return []
        }

        return items.map { item in
            let severity: ValidationSeverity
            switch item.level {
            case "error": severity = .error
            case "warning": severity = .warning
            default: severity = .info
            }
            return ValidationDiagnostic(
                line: item.line,
                column: item.column,
                message: "SC\(item.code): \(item.message)",
                severity: severity,
                source: "shellcheck"
            )
        }
    }

    // MARK: - terraform validate

    /// Parses `terraform validate -json` output.
    static func parseTerraform(_ jsonOutput: String) -> [ValidationDiagnostic] {
        guard let data = jsonOutput.data(using: .utf8) else { return [] }

        struct TerraformOutput: Decodable {
            let valid: Bool
            let diagnostics: [TerraformDiag]?
        }

        struct TerraformDiag: Decodable {
            let severity: String
            let summary: String
            let detail: String?
            let range: TerraformRange?
        }

        struct TerraformRange: Decodable {
            let start: TerraformPos
        }

        struct TerraformPos: Decodable {
            let line: Int
            let column: Int
        }

        guard let output = try? JSONDecoder().decode(TerraformOutput.self, from: data) else {
            return []
        }

        return (output.diagnostics ?? []).map { diag in
            let severity: ValidationSeverity = diag.severity == "error" ? .error : .warning
            let message: String
            if let detail = diag.detail, !detail.isEmpty {
                message = "\(diag.summary): \(detail)"
            } else {
                message = diag.summary
            }
            return ValidationDiagnostic(
                line: diag.range?.start.line ?? 1,
                column: diag.range?.start.column ?? nil,
                message: message,
                severity: severity,
                source: "terraform"
            )
        }
    }

    // MARK: - hadolint

    /// Parses hadolint JSON output (--format json).
    static func parseHadolint(_ jsonOutput: String) -> [ValidationDiagnostic] {
        guard let data = jsonOutput.data(using: .utf8) else { return [] }

        struct HadolintItem: Decodable {
            let line: Int
            let column: Int
            let level: String
            let message: String
            let code: String
        }

        guard let items = try? JSONDecoder().decode([HadolintItem].self, from: data) else {
            return []
        }

        return items.map { item in
            let severity: ValidationSeverity
            switch item.level {
            case "error": severity = .error
            case "warning": severity = .warning
            default: severity = .info
            }
            return ValidationDiagnostic(
                line: item.line,
                column: item.column > 0 ? item.column : nil,
                message: "\(item.code): \(item.message)",
                severity: severity,
                source: "hadolint"
            )
        }
    }
}

// MARK: - ConfigValidator

/// Runs external config validators and produces diagnostics.
/// Designed to be called from a background queue with debouncing.
@Observable
final class ConfigValidator {

    /// Current diagnostics for the active file.
    private(set) var diagnostics: [ValidationDiagnostic] = []

    /// Whether validation is currently running.
    private(set) var isValidating = false

    /// The validator kind for the current file, if any.
    private(set) var activeValidator: ValidatorKind?

    /// Whether the required tool is available.
    private(set) var toolAvailable = false

    /// Debounce interval in seconds.
    static let debounceInterval: TimeInterval = 0.3

    /// Serial queue for validation work.
    private let queue = DispatchQueue(label: "com.pine.config-validation", qos: .utility)

    /// Generation token to discard stale results.
    private var generation: UInt64 = 0

    /// Debounce work item.
    private var debounceWorkItem: DispatchWorkItem?

    /// Validates the given file content, debounced.
    /// - Parameters:
    ///   - url: The file URL (used for extension detection and temp file creation).
    ///   - content: The current file content.
    func validate(url: URL, content: String) {
        debounceWorkItem?.cancel()

        guard let kind = ValidatorDetector.detect(for: url) else {
            DispatchQueue.main.async { [weak self] in
                self?.diagnostics = []
                self?.activeValidator = nil
                self?.toolAvailable = false
            }
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.runValidation(url: url, content: content, kind: kind)
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: workItem)
    }

    /// Clears all diagnostics (e.g. when switching tabs).
    func clear() {
        debounceWorkItem?.cancel()
        generation &+= 1
        DispatchQueue.main.async { [weak self] in
            self?.diagnostics = []
            self?.activeValidator = nil
            self?.toolAvailable = false
            self?.isValidating = false
        }
    }

    // MARK: - Private

    private func runValidation(url: URL, content: String, kind: ValidatorKind) {
        let currentGen = generation &+ 1
        generation = currentGen

        DispatchQueue.main.async { [weak self] in
            self?.isValidating = true
            self?.activeValidator = kind
        }

        // Check tool availability
        guard let toolPath = ToolAvailability.path(for: kind.toolName) else {
            DispatchQueue.main.async { [weak self] in
                guard self?.generation == currentGen else { return }
                self?.diagnostics = []
                self?.toolAvailable = false
                self?.isValidating = false
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.toolAvailable = true
        }

        // Write content to temp file for validation
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)

        do {
            try content.write(to: tempFile, atomically: true, encoding: .utf8)
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard self?.generation == currentGen else { return }
                self?.diagnostics = []
                self?.isValidating = false
            }
            return
        }

        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = runTool(toolPath: toolPath, kind: kind, filePath: tempFile.path)

        guard generation == currentGen else { return }

        let parsed: [ValidationDiagnostic]
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

        DispatchQueue.main.async { [weak self] in
            guard self?.generation == currentGen else { return }
            self?.diagnostics = parsed
            self?.isValidating = false
        }
    }

    private func runTool(toolPath: String, kind: ValidatorKind, filePath: String) -> String {
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
