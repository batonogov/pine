//
//  ConfigValidator.swift
//  Pine
//
//  Created by Claude on 29.03.2026.
//

import Foundation

// MARK: - Models

/// Severity of a validation diagnostic.
nonisolated enum ValidationSeverity: Sendable, Equatable {
    case error
    case warning
    case info
}

/// A single validation diagnostic tied to a line in the file.
nonisolated struct ValidationDiagnostic: Sendable, Equatable, Identifiable {
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
nonisolated enum ValidatorKind: Sendable, Equatable {
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
nonisolated enum ValidatorDetector {
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
nonisolated enum ToolAvailability {
    /// Cached availability results to avoid repeated `which` calls.
    /// nonisolated(unsafe): protected by `lock` — all reads and writes go through lock/unlock.
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
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
nonisolated enum ValidatorOutputParser {

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

// MARK: - Built-in Validators

/// Built-in regex-based validators that work without external tools.
/// These provide basic validation when CLI tools (yamllint, hadolint, etc.) are not installed.
nonisolated enum BuiltinValidator {

    // Cached regex for detecting unquoted variables in shell test expressions.
    // swiftlint:disable:next force_try
    private static let unquotedVarInTestRegex = try! NSRegularExpression(
        pattern: #"\[\s+\$\w+\s+(==?|!=|-eq|-ne|-lt|-gt)\s+"#
    )

    // MARK: - YAML

    /// Basic YAML validation using regex patterns.
    static func validateYAML(_ content: String) -> [ValidationDiagnostic] {
        var diagnostics: [ValidationDiagnostic] = []
        let lines = content.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Detect tab indentation (YAML requires spaces)
            if line.hasPrefix("\t") {
                diagnostics.append(ValidationDiagnostic(
                    line: lineNum,
                    column: 1,
                    message: "YAML does not allow tab characters for indentation, use spaces",
                    severity: .error,
                    source: "pine-yaml"
                ))
            }

            // Detect duplicate colon in mapping (e.g. "key: value: extra")
            // but skip lines that are valid multi-colon values like URLs
            if let colonIdx = trimmed.firstIndex(of: ":"),
               !trimmed.hasPrefix("-"),
               !trimmed.hasPrefix("\""),
               !trimmed.hasPrefix("'") {
                let afterColon = trimmed[trimmed.index(after: colonIdx)...]
                let afterTrimmed = afterColon.trimmingCharacters(in: .whitespaces)
                // Check for unquoted value containing a colon (common URL pattern excluded)
                if !afterTrimmed.isEmpty,
                   !afterTrimmed.hasPrefix("\""),
                   !afterTrimmed.hasPrefix("'"),
                   !afterTrimmed.hasPrefix("//"),
                   !afterTrimmed.hasPrefix("|"),
                   !afterTrimmed.hasPrefix(">"),
                   !afterTrimmed.hasPrefix("&"),
                   !afterTrimmed.hasPrefix("*") {
                    // Check for obviously broken mapping syntax
                    if afterTrimmed.contains(": ") {
                        let parts = trimmed.components(separatedBy: ": ")
                        if parts.count > 2 && !trimmed.contains("\"") && !trimmed.contains("'") {
                            diagnostics.append(ValidationDiagnostic(
                                line: lineNum,
                                column: nil,
                                message: "Ambiguous mapping entry — value contains unquoted ': '",
                                severity: .warning,
                                source: "pine-yaml"
                            ))
                        }
                    }
                }
            }

            // Detect trailing spaces
            if line.hasSuffix(" ") || line.hasSuffix("\t") {
                diagnostics.append(ValidationDiagnostic(
                    line: lineNum,
                    column: nil,
                    message: "Trailing whitespace",
                    severity: .warning,
                    source: "pine-yaml"
                ))
            }

            // Detect unusual indentation (1 or 3 spaces).
            // 2-space and 4-space indents are both common in YAML so we only flag
            // truly unusual levels that likely indicate a mistake.
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            if leadingSpaces == 1 || leadingSpaces == 3 {
                diagnostics.append(ValidationDiagnostic(
                    line: lineNum,
                    column: 1,
                    message: "Unusual indentation (\(leadingSpaces) spaces) — YAML typically uses 2 or 4 spaces",
                    severity: .warning,
                    source: "pine-yaml"
                ))
            }
        }

        return diagnostics
    }

    // MARK: - Dockerfile

    /// Known valid Dockerfile instructions (uppercase).
    static let dockerfileInstructions: Set<String> = [
        "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV",
        "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR",
        "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL"
    ]

    /// Basic Dockerfile validation using regex patterns.
    static func validateDockerfile(_ content: String) -> [ValidationDiagnostic] {
        var diagnostics: [ValidationDiagnostic] = []
        let lines = content.components(separatedBy: "\n")
        var hasFrom = false
        var isContinuation = false

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                isContinuation = false
                continue
            }

            // Skip continuation lines (previous line ended with \)
            if isContinuation {
                isContinuation = trimmed.hasSuffix("\\")
                continue
            }

            isContinuation = trimmed.hasSuffix("\\")

            // Extract the instruction (first word)
            let instruction = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed
            let upper = instruction.uppercased()

            // Check for valid instruction
            if !dockerfileInstructions.contains(upper) {
                diagnostics.append(ValidationDiagnostic(
                    line: lineNum,
                    column: 1,
                    message: "Invalid Dockerfile instruction '\(instruction)'",
                    severity: .error,
                    source: "pine-dockerfile"
                ))
                continue
            }

            // Track FROM instruction
            if upper == "FROM" {
                hasFrom = true
            }

            // Warn about deprecated MAINTAINER
            if upper == "MAINTAINER" {
                diagnostics.append(ValidationDiagnostic(
                    line: lineNum,
                    column: 1,
                    message: "MAINTAINER is deprecated, use LABEL maintainer=\"...\" instead",
                    severity: .warning,
                    source: "pine-dockerfile"
                ))
            }

            // Check instruction is uppercase (Dockerfile convention)
            if instruction != upper && dockerfileInstructions.contains(upper) {
                diagnostics.append(ValidationDiagnostic(
                    line: lineNum,
                    column: 1,
                    message: "Instruction '\(instruction)' should be uppercase '\(upper)'",
                    severity: .warning,
                    source: "pine-dockerfile"
                ))
            }
        }

        // Check that FROM is present
        if !hasFrom && !lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty
            || $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
            diagnostics.insert(ValidationDiagnostic(
                line: 1,
                column: 1,
                message: "Dockerfile must start with a FROM instruction",
                severity: .error,
                source: "pine-dockerfile"
            ), at: 0)
        }

        return diagnostics
    }

    // MARK: - Shell scripts

    /// Basic shell script validation using regex patterns.
    static func validateShell(_ content: String) -> [ValidationDiagnostic] {
        var diagnostics: [ValidationDiagnostic] = []
        let lines = content.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Detect common quoting issues: unquoted variable in test
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if unquotedVarInTestRegex.firstMatch(in: trimmed, range: range) != nil {
                diagnostics.append(ValidationDiagnostic(
                    line: lineNum,
                    column: nil,
                    message: "Unquoted variable in test — use \"$var\" to prevent word splitting",
                    severity: .warning,
                    source: "pine-shell"
                ))
            }

            // Detect backtick command substitution (prefer $())
            // Only count backticks that are outside single and double quotes.
            if trimmed.contains("`") && !trimmed.hasPrefix("#") {
                var inSingle = false
                var inDouble = false
                var unquotedBackticks = 0
                for char in trimmed {
                    if char == "'" && !inDouble {
                        inSingle.toggle()
                    } else if char == "\"" && !inSingle {
                        inDouble.toggle()
                    } else if char == "`" && !inSingle && !inDouble {
                        unquotedBackticks += 1
                    }
                }
                if unquotedBackticks >= 2 {
                    diagnostics.append(ValidationDiagnostic(
                        line: lineNum,
                        column: nil,
                        message: "Use $(...) instead of backticks for command substitution",
                        severity: .info,
                        source: "pine-shell"
                    ))
                }
            }
        }

        return diagnostics
    }
}

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

// MARK: - ConfigValidator

/// Runs external config validators and produces diagnostics.
/// Falls back to built-in regex-based validators when external tools are not installed.
/// Explicitly `@MainActor` — all UI state lives here. Heavy validation work is
/// dispatched to `ConfigValidationWorker` (nonisolated) to avoid
/// `dispatch_assert_queue_fail` crashes under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
@MainActor
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
    nonisolated static let debounceInterval: TimeInterval = 0.3

    /// Generation token to discard stale results.
    private var generation: UInt64 = 0

    /// Debounce task handle.
    private var debounceTask: Task<Void, Never>?

    /// Increments and returns the new generation token.
    private func nextGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Validates the given file content, debounced.
    /// - Parameters:
    ///   - url: The file URL (used for extension detection and temp file creation).
    ///   - content: The current file content.
    func validate(url: URL, content: String) {
        debounceTask?.cancel()

        guard let kind = ValidatorDetector.detect(for: url) else {
            diagnostics = []
            activeValidator = nil
            toolAvailable = false
            return
        }

        let currentGen = nextGeneration()

        debounceTask = Task { [weak self] in
            // Debounce
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }

            self.runValidation(url: url, content: content, kind: kind, expectedGen: currentGen)
        }
    }

    /// Clears all diagnostics (e.g. when switching tabs).
    func clear() {
        debounceTask?.cancel()
        _ = nextGeneration()
        diagnostics = []
        activeValidator = nil
        toolAvailable = false
        isValidating = false
    }

    // MARK: - Private

    private func runValidation(url: URL, content: String, kind: ValidatorKind, expectedGen: UInt64) {
        guard generation == expectedGen else { return }

        isValidating = true
        activeValidator = kind

        let capturedGen = expectedGen

        Task.detached {
            let result = ConfigValidationWorker.runValidation(url: url, content: content, kind: kind)

            await MainActor.run { [weak self] in
                guard let self, self.generation == capturedGen else { return }
                self.diagnostics = result.diagnostics
                self.toolAvailable = result.toolAvailable
                self.isValidating = false
            }
        }
    }
}
