//
//  ConfigValidatorEdgeTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

@Suite("ConfigValidator Edge Case Tests")
@MainActor
struct ConfigValidatorEdgeTests {

    // MARK: - BuiltinValidator YAML

    @Test func builtinYAML_tabIndentation() {
        let content = "\tkey: value"
        let diags = BuiltinValidator.validateYAML(content)
        #expect(diags.contains { $0.message.contains("tab") && $0.severity == .error })
    }

    @Test func builtinYAML_trailingWhitespace() {
        let content = "key: value   "
        let diags = BuiltinValidator.validateYAML(content)
        #expect(diags.contains { $0.message.contains("Trailing whitespace") })
    }

    @Test func builtinYAML_unusualIndentation1Space() {
        let content = " key: value"
        let diags = BuiltinValidator.validateYAML(content)
        #expect(diags.contains { $0.message.contains("Unusual indentation (1 spaces)") })
    }

    @Test func builtinYAML_unusualIndentation3Spaces() {
        let content = "   key: value"
        let diags = BuiltinValidator.validateYAML(content)
        #expect(diags.contains { $0.message.contains("3 spaces") })
    }

    @Test func builtinYAML_normalIndentation2Spaces() {
        let content = "  key: value"
        let diags = BuiltinValidator.validateYAML(content)
        let indentDiags = diags.filter { $0.message.contains("indentation") }
        #expect(indentDiags.isEmpty)
    }

    @Test func builtinYAML_normalIndentation4Spaces() {
        let content = "    key: value"
        let diags = BuiltinValidator.validateYAML(content)
        let indentDiags = diags.filter { $0.message.contains("indentation") }
        #expect(indentDiags.isEmpty)
    }

    @Test func builtinYAML_emptyContent() {
        let diags = BuiltinValidator.validateYAML("")
        #expect(diags.isEmpty)
    }

    @Test func builtinYAML_emptyLinesOnly() {
        let diags = BuiltinValidator.validateYAML("\n\n\n")
        #expect(diags.isEmpty)
    }

    @Test func builtinYAML_commentsSkipped() {
        let content = "# This is a comment"
        let diags = BuiltinValidator.validateYAML(content)
        #expect(diags.isEmpty)
    }

    @Test func builtinYAML_ambiguousMapping() {
        let content = "key: value: extra: stuff"
        let diags = BuiltinValidator.validateYAML(content)
        #expect(diags.contains { $0.message.contains("Ambiguous mapping") })
    }

    @Test func builtinYAML_urlNotAmbiguous() {
        // URL after colon should NOT trigger ambiguous mapping
        let content = "url: https://example.com"
        let diags = BuiltinValidator.validateYAML(content)
        let ambig = diags.filter { $0.message.contains("Ambiguous") }
        #expect(ambig.isEmpty)
    }

    @Test func builtinYAML_trailingTab() {
        let content = "key: value\t"
        let diags = BuiltinValidator.validateYAML(content)
        #expect(diags.contains { $0.message.contains("Trailing whitespace") })
    }

    // MARK: - BuiltinValidator Dockerfile

    @Test func builtinDockerfile_validFile() {
        let content = "FROM ubuntu:20.04\nRUN apt-get update\nCMD [\"bash\"]"
        let diags = BuiltinValidator.validateDockerfile(content)
        #expect(diags.isEmpty)
    }

    @Test func builtinDockerfile_missingFROM() {
        let content = "RUN apt-get update"
        let diags = BuiltinValidator.validateDockerfile(content)
        #expect(diags.contains { $0.message.contains("FROM") && $0.severity == .error })
    }

    @Test func builtinDockerfile_invalidInstruction() {
        let content = "FROM ubuntu\nINVALIDCMD foo"
        let diags = BuiltinValidator.validateDockerfile(content)
        #expect(diags.contains { $0.message.contains("Invalid Dockerfile instruction") })
    }

    @Test func builtinDockerfile_deprecatedMAINTAINER() {
        let content = "FROM ubuntu\nMAINTAINER test@test.com"
        let diags = BuiltinValidator.validateDockerfile(content)
        #expect(diags.contains { $0.message.contains("deprecated") })
    }

    @Test func builtinDockerfile_lowercaseInstruction() {
        let content = "FROM ubuntu\nrun apt-get update"
        let diags = BuiltinValidator.validateDockerfile(content)
        #expect(diags.contains { $0.message.contains("should be uppercase") })
    }

    @Test func builtinDockerfile_continuationLines() {
        let content = "FROM ubuntu\nRUN apt-get update && \\\n    apt-get install -y curl"
        let diags = BuiltinValidator.validateDockerfile(content)
        // No errors expected
        let errors = diags.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test func builtinDockerfile_emptyFile() {
        let diags = BuiltinValidator.validateDockerfile("")
        // Empty file with only empty lines should NOT trigger missing FROM
        #expect(diags.isEmpty)
    }

    @Test func builtinDockerfile_commentsOnly() {
        let content = "# This is a comment\n# Another comment"
        let diags = BuiltinValidator.validateDockerfile(content)
        #expect(diags.isEmpty)
    }

    @Test func builtinDockerfile_allInstructions() {
        // Verify all valid instructions are recognized
        let instructions = BuiltinValidator.dockerfileInstructions
        #expect(instructions.contains("FROM"))
        #expect(instructions.contains("RUN"))
        #expect(instructions.contains("CMD"))
        #expect(instructions.contains("EXPOSE"))
        #expect(instructions.contains("ENV"))
        #expect(instructions.contains("COPY"))
        #expect(instructions.contains("ENTRYPOINT"))
        #expect(instructions.contains("WORKDIR"))
        #expect(instructions.contains("ARG"))
        #expect(instructions.contains("HEALTHCHECK"))
    }

    // MARK: - BuiltinValidator Shell

    @Test func builtinShell_unquotedVariable() {
        let content = "[ $var == \"value\" ]"
        let diags = BuiltinValidator.validateShell(content)
        #expect(diags.contains { $0.message.contains("Unquoted variable") })
    }

    @Test func builtinShell_backtickSubstitution() {
        let content = "result=`date`"
        let diags = BuiltinValidator.validateShell(content)
        #expect(diags.contains { $0.message.contains("$(...) instead of backticks") })
    }

    @Test func builtinShell_backtickInSingleQuotes() {
        // Backticks inside single quotes should NOT trigger warning
        let content = "echo 'use `date` here'"
        let diags = BuiltinValidator.validateShell(content)
        let backtickDiags = diags.filter { $0.message.contains("backticks") }
        #expect(backtickDiags.isEmpty)
    }

    @Test func builtinShell_emptyContent() {
        let diags = BuiltinValidator.validateShell("")
        #expect(diags.isEmpty)
    }

    @Test func builtinShell_commentsSkipped() {
        let content = "# This is a comment with `backticks`"
        let diags = BuiltinValidator.validateShell(content)
        #expect(diags.isEmpty)
    }

    @Test func builtinShell_cleanScript() {
        let content = "#!/bin/bash\necho \"Hello\"\nexit 0"
        let diags = BuiltinValidator.validateShell(content)
        #expect(diags.isEmpty)
    }

    // MARK: - ValidatorOutputParser shellcheck

    @Test func parseShellcheck_validJSON() {
        let json = """
        [{"line":3,"column":5,"level":"warning","message":"Double quote","code":2086}]
        """
        let diags = ValidatorOutputParser.parseShellcheck(json)
        #expect(diags.count == 1)
        #expect(diags[0].line == 3)
        #expect(diags[0].column == 5)
        #expect(diags[0].severity == .warning)
        #expect(diags[0].message.contains("SC2086"))
        #expect(diags[0].source == "shellcheck")
    }

    @Test func parseShellcheck_errorLevel() {
        let json = """
        [{"line":1,"column":1,"level":"error","message":"Parse error","code":1000}]
        """
        let diags = ValidatorOutputParser.parseShellcheck(json)
        #expect(diags[0].severity == .error)
    }

    @Test func parseShellcheck_infoLevel() {
        let json = """
        [{"line":1,"column":1,"level":"info","message":"Style suggestion","code":2000}]
        """
        let diags = ValidatorOutputParser.parseShellcheck(json)
        #expect(diags[0].severity == .info)
    }

    @Test func parseShellcheck_invalidJSON() {
        let diags = ValidatorOutputParser.parseShellcheck("not json")
        #expect(diags.isEmpty)
    }

    @Test func parseShellcheck_emptyInput() {
        let diags = ValidatorOutputParser.parseShellcheck("")
        #expect(diags.isEmpty)
    }

    // MARK: - ValidatorOutputParser terraform

    @Test func parseTerraform_validOutput() {
        // swiftlint:disable:next line_length
        let json = "{\"valid\":false,\"diagnostics\":[{\"severity\":\"error\",\"summary\":\"Missing resource\",\"detail\":\"Resource not found\",\"range\":{\"start\":{\"line\":5,\"column\":3}}}]}"
        let diags = ValidatorOutputParser.parseTerraform(json)
        #expect(diags.count == 1)
        #expect(diags[0].line == 5)
        #expect(diags[0].column == 3)
        #expect(diags[0].severity == .error)
        #expect(diags[0].message.contains("Missing resource"))
        #expect(diags[0].message.contains("Resource not found"))
        #expect(diags[0].source == "terraform")
    }

    @Test func parseTerraform_warningLevel() {
        let json = """
        {"valid":true,"diagnostics":[{"severity":"warning","summary":"Deprecated","detail":"","range":null}]}
        """
        let diags = ValidatorOutputParser.parseTerraform(json)
        #expect(diags.count == 1)
        #expect(diags[0].severity == .warning)
        #expect(diags[0].line == 1) // Default when no range
    }

    @Test func parseTerraform_noDiagnostics() {
        let json = """
        {"valid":true,"diagnostics":null}
        """
        let diags = ValidatorOutputParser.parseTerraform(json)
        #expect(diags.isEmpty)
    }

    @Test func parseTerraform_invalidJSON() {
        let diags = ValidatorOutputParser.parseTerraform("invalid")
        #expect(diags.isEmpty)
    }

    @Test func parseTerraform_noDetailField() {
        let json = """
        {"valid":false,"diagnostics":[{"severity":"error","summary":"Error msg"}]}
        """
        let diags = ValidatorOutputParser.parseTerraform(json)
        #expect(diags.count == 1)
        #expect(diags[0].message == "Error msg")
    }

    // MARK: - ValidatorOutputParser hadolint

    @Test func parseHadolint_validOutput() {
        let json = """
        [{"line":1,"column":0,"level":"warning","message":"Pin versions","code":"DL3008"}]
        """
        let diags = ValidatorOutputParser.parseHadolint(json)
        #expect(diags.count == 1)
        #expect(diags[0].line == 1)
        #expect(diags[0].column == nil) // column 0 → nil
        #expect(diags[0].severity == .warning)
        #expect(diags[0].message.contains("DL3008"))
        #expect(diags[0].source == "hadolint")
    }

    @Test func parseHadolint_columnPositive() {
        let json = """
        [{"line":3,"column":5,"level":"error","message":"Bad","code":"DL3000"}]
        """
        let diags = ValidatorOutputParser.parseHadolint(json)
        #expect(diags[0].column == 5)
    }

    @Test func parseHadolint_infoLevel() {
        let json = """
        [{"line":1,"column":0,"level":"style","message":"Style","code":"DL3000"}]
        """
        let diags = ValidatorOutputParser.parseHadolint(json)
        #expect(diags[0].severity == .info) // default
    }

    @Test func parseHadolint_invalidJSON() {
        let diags = ValidatorOutputParser.parseHadolint("not json")
        #expect(diags.isEmpty)
    }

    // MARK: - ValidatorOutputParser yamllint

    @Test func parseYamllintLine_validError() {
        let line = "config.yml:10:5: [error] too many spaces"
        let diag = ValidatorOutputParser.parseYamllintLine(line)
        #expect(diag != nil)
        #expect(diag?.line == 10)
        #expect(diag?.column == 5)
        #expect(diag?.severity == .error)
        #expect(diag?.message == "too many spaces")
    }

    @Test func parseYamllintLine_validWarning() {
        let line = "file.yaml:3:1: [warning] line too long"
        let diag = ValidatorOutputParser.parseYamllintLine(line)
        #expect(diag != nil)
        #expect(diag?.severity == .warning)
    }

    @Test func parseYamllintLine_invalidLine() {
        let diag = ValidatorOutputParser.parseYamllintLine("not a yamllint line")
        #expect(diag == nil)
    }

    @Test func parseYamllint_multipleLines() {
        let output = """
        f.yml:1:1: [error] err1
        f.yml:2:3: [warning] warn1

        """
        let diags = ValidatorOutputParser.parseYamllint(output)
        #expect(diags.count == 2)
    }

    // MARK: - ValidationDiagnostic Equatable

    @Test func validationDiagnostic_equalityByValue() {
        let a = ValidationDiagnostic(line: 1, column: 2, message: "msg", severity: .error, source: "test")
        let b = ValidationDiagnostic(line: 1, column: 2, message: "msg", severity: .error, source: "test")
        #expect(a == b)
    }

    @Test func validationDiagnostic_inequalityByMessage() {
        let a = ValidationDiagnostic(line: 1, column: nil, message: "msg1", severity: .error, source: "test")
        let b = ValidationDiagnostic(line: 1, column: nil, message: "msg2", severity: .error, source: "test")
        #expect(a != b)
    }

    // MARK: - ConfigValidator clear

    @Test func configValidator_clear_resetsState() {
        let validator = ConfigValidator()
        validator.clear()
        #expect(validator.diagnostics.isEmpty)
        #expect(validator.activeValidator == nil)
        #expect(validator.toolAvailable == false)
        #expect(validator.isValidating == false)
    }

    // MARK: - ToolAvailability cache

    @Test func toolAvailability_clearCache() {
        // Should not crash
        ToolAvailability.clearCache()
    }

    // MARK: - ValidatorDetector

    @Test func validatorDetector_dockerfileDotVariant() {
        let url = URL(fileURLWithPath: "/tmp/dockerfile.dev")
        #expect(ValidatorDetector.detect(for: url) == .hadolint)
    }

    @Test func validatorDetector_upperCaseExtension() {
        let url = URL(fileURLWithPath: "/tmp/config.YAML")
        #expect(ValidatorDetector.detect(for: url) == .yamllint)
    }

    // MARK: - ValidationSeverity

    @Test func validationSeverity_equatable() {
        #expect(ValidationSeverity.error == .error)
        #expect(ValidationSeverity.warning != .info)
    }
}
