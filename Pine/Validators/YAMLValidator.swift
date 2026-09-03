//
//  YAMLValidator.swift
//  Pine
//
//  Extracted from ConfigValidator.swift — YAML built-in validation and yamllint parser.
//

import Foundation

// MARK: - YAMLLanguageValidator

/// LanguageValidator for YAML files (.yml, .yaml).
/// Uses yamllint if installed, falls back to built-in regex-based validation.
struct YAMLLanguageValidator: LanguageValidator, Sendable {
    let supportedExtensions: Set<String> = ["yml", "yaml"]
    let supportedNames: Set<String> = []
    let supportedNamePrefixes: Set<String> = []
    let toolName = "yamllint"
    let displayName = "yamllint"
    let validatorKind: ValidatorKind = .yamllint

    nonisolated func builtinValidation(_ content: String) -> [ValidationDiagnostic]? {
        BuiltinValidator.validateYAML(content)
    }

    nonisolated func parseToolOutput(_ output: String) -> [ValidationDiagnostic] {
        ValidatorOutputParser.parseYamllint(output)
    }
}

// MARK: - yamllint Output Parser

extension ValidatorOutputParser {
    /// Parses yamllint output in default format: `file.yml:3:1: [error] message`
    nonisolated static func parseYamllint(_ output: String) -> [ValidationDiagnostic] {
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
    ///
    /// Marked `internal` to prevent misuse outside the module. Test-only access
    /// is available via `@testable import Pine`.
    nonisolated static func parseYamllintLine(_ line: String) -> ValidationDiagnostic? {
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
}

// MARK: - Built-in YAML Validator

extension BuiltinValidator {

    /// Basic YAML validation using regex patterns.
    nonisolated static func validateYAML(_ content: String) -> [ValidationDiagnostic] {
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
                    message: Strings.validationYamlTabIndentation(),
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
                                message: Strings.validationYamlAmbiguousMapping(),
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
                    message: Strings.validationYamlTrailingWhitespace(),
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
                    message: Strings.validationYamlUnusualIndentation(leadingSpaces),
                    severity: .warning,
                    source: "pine-yaml"
                ))
            }
        }

        return diagnostics
    }
}
