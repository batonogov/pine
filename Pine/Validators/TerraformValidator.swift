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

    nonisolated func validate(url: URL, content: String) -> (diagnostics: [ValidationDiagnostic], toolAvailable: Bool) {
        let toolPath = ToolAvailability.path(for: toolName)
        let hasExternalTool = toolPath != nil

        var parsed: [ValidationDiagnostic] = []
        if let toolPath = toolPath {
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)

            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: tempFile) }

                let result = ConfigValidationWorker.runTool(
                    toolPath: toolPath, kind: .terraform, filePath: tempFile.path
                )
                parsed = ValidatorOutputParser.parseTerraform(result)
            } catch {
                // Temp file write failed — no built-in terraform validation
            }
        }

        return (parsed, hasExternalTool)
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
