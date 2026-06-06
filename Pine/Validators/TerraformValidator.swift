//
//  TerraformValidator.swift
//  Pine
//
//  Extracted from ConfigValidator.swift — terraform validate parser.
//

import Foundation

// MARK: - TerraformLanguageValidator

/// LanguageValidator for Terraform files (.tf, .tfvars).
/// Uses `terraform validate` if installed. No built-in fallback.
struct TerraformLanguageValidator: LanguageValidator, Sendable {
    let supportedExtensions: Set<String> = ["tf", "tfvars"]
    let supportedNames: Set<String> = []
    let supportedNamePrefixes: Set<String> = []
    let toolName = "terraform"
    let displayName = "terraform"
    let validatorKind: ValidatorKind = .terraform

    nonisolated func builtinValidation(_ content: String) -> [ValidationDiagnostic]? {
        nil // No built-in terraform validation
    }

    nonisolated func parseToolOutput(_ output: String) -> [ValidationDiagnostic] {
        ValidatorOutputParser.parseTerraform(output)
    }
}

// MARK: - terraform validate Output Parser

extension ValidatorOutputParser {

    /// Parses `terraform validate -json` output.
    nonisolated static func parseTerraform(_ jsonOutput: String) -> [ValidationDiagnostic] {
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
}
