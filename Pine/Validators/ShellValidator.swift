//
//  ShellValidator.swift
//  Pine
//
//  Extracted from ConfigValidator.swift — Shell built-in validation and shellcheck parser.
//

import Foundation

// MARK: - ShellLanguageValidator

/// LanguageValidator for shell scripts (.sh, .bash, .zsh).
/// Uses shellcheck if installed, falls back to built-in regex-based validation.
struct ShellLanguageValidator: LanguageValidator, Sendable {
    let supportedExtensions: Set<String> = ["sh", "bash", "zsh"]
    let supportedNames: Set<String> = []
    let supportedNamePrefixes: Set<String> = []
    let toolName = "shellcheck"
    let displayName = "shellcheck"
    let validatorKind: ValidatorKind = .shellcheck

    nonisolated func builtinValidation(_ content: String) -> [ValidationDiagnostic]? {
        BuiltinValidator.validateShell(content)
    }

    nonisolated func parseToolOutput(_ output: String) -> [ValidationDiagnostic] {
        ValidatorOutputParser.parseShellcheck(output)
    }
}

// MARK: - shellcheck Output Parser

extension ValidatorOutputParser {

    /// Parses shellcheck JSON output.
    nonisolated static func parseShellcheck(_ jsonOutput: String) -> [ValidationDiagnostic] {
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
}

// MARK: - Built-in Shell Validator

extension BuiltinValidator {

    // Cached regex for detecting unquoted variables in shell test expressions.
    // swiftlint:disable:next force_try
    nonisolated private static let unquotedVarInTestRegex = try! NSRegularExpression(
        pattern: #"\[\s+\$\w+\s+(==?|!=|-eq|-ne|-lt|-gt)\s+"#
    )

    /// Basic shell script validation using regex patterns.
    nonisolated static func validateShell(_ content: String) -> [ValidationDiagnostic] {
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
                    message: Strings.validationShellUnquotedVariable(),
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
                        message: Strings.validationShellBackticks(),
                        severity: .info,
                        source: "pine-shell"
                    ))
                }
            }
        }

        return diagnostics
    }
}
