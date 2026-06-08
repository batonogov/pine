//
//  DockerfileValidator.swift
//  Pine
//
//  Extracted from ConfigValidator.swift — Dockerfile built-in validation and hadolint parser.
//

import Foundation

// MARK: - DockerfileLanguageValidator

/// LanguageValidator for Dockerfiles (Dockerfile, Dockerfile.*).
/// Uses hadolint if installed, falls back to built-in regex-based validation.
struct DockerfileLanguageValidator: LanguageValidator, Sendable {
    let supportedExtensions: Set<String> = []
    let supportedNames: Set<String> = ["dockerfile"]
    let supportedNamePrefixes: Set<String> = ["dockerfile."]
    let toolName = "hadolint"
    let displayName = "hadolint"
    let validatorKind: ValidatorKind = .hadolint

    nonisolated func builtinValidation(_ content: String) -> [ValidationDiagnostic]? {
        BuiltinValidator.validateDockerfile(content)
    }

    nonisolated func parseToolOutput(_ output: String) -> [ValidationDiagnostic] {
        ValidatorOutputParser.parseHadolint(output)
    }
}

// MARK: - hadolint Output Parser

extension ValidatorOutputParser {

    /// Parses hadolint JSON output (--format json).
    nonisolated static func parseHadolint(_ jsonOutput: String) -> [ValidationDiagnostic] {
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

// MARK: - Built-in Dockerfile Validator

extension BuiltinValidator {

    /// Known valid Dockerfile instructions (uppercase).
    nonisolated static let dockerfileInstructions: Set<String> = [
        "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV",
        "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR",
        "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL"
    ]

    /// Basic Dockerfile validation using regex patterns.
    nonisolated static func validateDockerfile(_ content: String) -> [ValidationDiagnostic] {
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
}
