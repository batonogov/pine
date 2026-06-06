//
//  ValidatorDetection.swift
//  Pine
//
//  Extracted from ConfigValidator.swift — language detection and tool availability.
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

// MARK: - LanguageValidator Protocol

/// Protocol for language-specific validators. Each validator declares which file
/// extensions it supports and can produce diagnostics for a given file.
/// Adding a new language requires only creating a conforming type — no switch-cases to update.
protocol LanguageValidator: Sendable {
    /// File extensions this validator handles (lowercased, without dot).
    var supportedExtensions: Set<String> { get }

    /// File names this validator handles (lowercased). Used for extensionless files like "Dockerfile".
    var supportedNames: Set<String> { get }

    /// File name prefixes this validator handles (lowercased). E.g. "dockerfile.".
    var supportedNamePrefixes: Set<String> { get }

    /// The tool name for display and lookup purposes.
    var toolName: String { get }

    /// Display name for status bar / tooltips.
    var displayName: String { get }

    /// Validate the file content, running the external tool if available.
    /// Falls back to built-in validation when no external tool is installed.
    /// Explicitly nonisolated — runs on background threads via ConfigValidator.
    nonisolated func validate(url: URL, content: String) -> (diagnostics: [ValidationDiagnostic], toolAvailable: Bool)
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
