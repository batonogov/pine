//
//  ConfigValidatorTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

struct ConfigValidatorTests {

    // MARK: - ValidatorDetector

    @Test func detect_yaml() {
        let url = URL(fileURLWithPath: "/tmp/config.yml")
        #expect(ValidatorDetector.detect(for: url) == .yamllint)
    }

    @Test func detect_yamlExtension() {
        let url = URL(fileURLWithPath: "/tmp/config.yaml")
        #expect(ValidatorDetector.detect(for: url) == .yamllint)
    }

    @Test func detect_yamlCaseInsensitive() {
        let url = URL(fileURLWithPath: "/tmp/config.YML")
        #expect(ValidatorDetector.detect(for: url) == .yamllint)
    }

    @Test func detect_terraform_tf() {
        let url = URL(fileURLWithPath: "/tmp/main.tf")
        #expect(ValidatorDetector.detect(for: url) == .terraform)
    }

    @Test func detect_terraform_tfvars() {
        let url = URL(fileURLWithPath: "/tmp/vars.tfvars")
        #expect(ValidatorDetector.detect(for: url) == .terraform)
    }

    @Test func detect_shell_sh() {
        let url = URL(fileURLWithPath: "/tmp/script.sh")
        #expect(ValidatorDetector.detect(for: url) == .shellcheck)
    }

    @Test func detect_shell_bash() {
        let url = URL(fileURLWithPath: "/tmp/deploy.bash")
        #expect(ValidatorDetector.detect(for: url) == .shellcheck)
    }

    @Test func detect_shell_zsh() {
        let url = URL(fileURLWithPath: "/tmp/init.zsh")
        #expect(ValidatorDetector.detect(for: url) == .shellcheck)
    }

    @Test func detect_dockerfile() {
        let url = URL(fileURLWithPath: "/tmp/Dockerfile")
        #expect(ValidatorDetector.detect(for: url) == .hadolint)
    }

    @Test func detect_dockerfile_variant() {
        let url = URL(fileURLWithPath: "/tmp/Dockerfile.prod")
        #expect(ValidatorDetector.detect(for: url) == .hadolint)
    }

    @Test func detect_swift_returnsNil() {
        let url = URL(fileURLWithPath: "/tmp/main.swift")
        #expect(ValidatorDetector.detect(for: url) == nil)
    }

    @Test func detect_json_returnsNil() {
        let url = URL(fileURLWithPath: "/tmp/config.json")
        #expect(ValidatorDetector.detect(for: url) == nil)
    }

    @Test func detect_noExtension_notDockerfile_returnsNil() {
        let url = URL(fileURLWithPath: "/tmp/Makefile")
        #expect(ValidatorDetector.detect(for: url) == nil)
    }

    // MARK: - ValidatorKind properties

    @Test func validatorKind_displayName() {
        #expect(ValidatorKind.yamllint.displayName == "yamllint")
        #expect(ValidatorKind.terraform.displayName == "terraform")
        #expect(ValidatorKind.shellcheck.displayName == "shellcheck")
        #expect(ValidatorKind.hadolint.displayName == "hadolint")
    }

    @Test func validatorKind_toolName() {
        #expect(ValidatorKind.yamllint.toolName == "yamllint")
        #expect(ValidatorKind.terraform.toolName == "terraform")
        #expect(ValidatorKind.shellcheck.toolName == "shellcheck")
        #expect(ValidatorKind.hadolint.toolName == "hadolint")
    }

    // MARK: - yamllint parser

    @Test func parseYamllint_error() {
        let output = "config.yml:3:1: [error] syntax error: mapping values are not allowed here"
        let results = ValidatorOutputParser.parseYamllint(output)
        #expect(results.count == 1)
        #expect(results[0].line == 3)
        #expect(results[0].column == 1)
        #expect(results[0].severity == .error)
        #expect(results[0].message == "syntax error: mapping values are not allowed here")
        #expect(results[0].source == "yamllint")
    }

    @Test func parseYamllint_warning() {
        let output = "config.yml:5:3: [warning] comment not indented like content (comments-indentation)"
        let results = ValidatorOutputParser.parseYamllint(output)
        #expect(results.count == 1)
        #expect(results[0].line == 5)
        #expect(results[0].column == 3)
        #expect(results[0].severity == .warning)
        #expect(results[0].message == "comment not indented like content (comments-indentation)")
    }

    @Test func parseYamllint_multipleLines() {
        let output = """
        file.yml:1:1: [warning] missing document start "---" (document-start)
        file.yml:3:81: [error] line too long (89 > 80 characters) (line-length)
        file.yml:10:1: [warning] too many blank lines (2 > 0) (empty-lines)
        """
        let results = ValidatorOutputParser.parseYamllint(output)
        #expect(results.count == 3)
        #expect(results[0].line == 1)
        #expect(results[1].line == 3)
        #expect(results[1].severity == .error)
        #expect(results[2].line == 10)
    }

    @Test func parseYamllint_emptyOutput() {
        let results = ValidatorOutputParser.parseYamllint("")
        #expect(results.isEmpty)
    }

    @Test func parseYamllint_invalidLine_skipped() {
        let output = "This is not a valid yamllint output line"
        let results = ValidatorOutputParser.parseYamllint(output)
        #expect(results.isEmpty)
    }

    @Test func parseYamllintLine_returnsNil_forGarbage() {
        #expect(ValidatorOutputParser.parseYamllintLine("garbage") == nil)
    }

    @Test func parseYamllintLine_returnsNil_forEmpty() {
        #expect(ValidatorOutputParser.parseYamllintLine("") == nil)
    }

    // MARK: - shellcheck parser

    @Test func parseShellcheck_singleError() {
        let json = """
        [{"line":3,"column":5,"level":"error","message":"Expected \\"then\\"","code":1046}]
        """
        let results = ValidatorOutputParser.parseShellcheck(json)
        #expect(results.count == 1)
        #expect(results[0].line == 3)
        #expect(results[0].column == 5)
        #expect(results[0].severity == .error)
        #expect(results[0].message == "SC1046: Expected \"then\"")
        #expect(results[0].source == "shellcheck")
    }

    @Test func parseShellcheck_warningAndInfo() {
        let json = """
        [
          {"line":1,"column":1,"level":"warning","message":"Use #!/usr/bin/env bash","code":2148},
          {"line":5,"column":3,"level":"info","message":"Double quote to prevent globbing","code":2086}
        ]
        """
        let results = ValidatorOutputParser.parseShellcheck(json)
        #expect(results.count == 2)
        #expect(results[0].severity == .warning)
        #expect(results[1].severity == .info)
        #expect(results[1].message.hasPrefix("SC2086:"))
    }

    @Test func parseShellcheck_emptyArray() {
        let results = ValidatorOutputParser.parseShellcheck("[]")
        #expect(results.isEmpty)
    }

    @Test func parseShellcheck_invalidJSON() {
        let results = ValidatorOutputParser.parseShellcheck("not json")
        #expect(results.isEmpty)
    }

    @Test func parseShellcheck_emptyString() {
        let results = ValidatorOutputParser.parseShellcheck("")
        #expect(results.isEmpty)
    }

    // MARK: - terraform parser

    @Test func parseTerraform_valid() {
        let json = """
        {"valid":true,"diagnostics":[]}
        """
        let results = ValidatorOutputParser.parseTerraform(json)
        #expect(results.isEmpty)
    }

    @Test func parseTerraform_withError() {
        let json = """
        {
          "valid": false,
          "diagnostics": [
            {
              "severity": "error",
              "summary": "Invalid resource name",
              "detail": "Names must start with a letter",
              "range": {
                "start": {"line": 5, "column": 10}
              }
            }
          ]
        }
        """
        let results = ValidatorOutputParser.parseTerraform(json)
        #expect(results.count == 1)
        #expect(results[0].line == 5)
        #expect(results[0].column == 10)
        #expect(results[0].severity == .error)
        #expect(results[0].message == "Invalid resource name: Names must start with a letter")
        #expect(results[0].source == "terraform")
    }

    @Test func parseTerraform_withWarning_noDetail() {
        let json = """
        {
          "valid": true,
          "diagnostics": [
            {
              "severity": "warning",
              "summary": "Deprecated attribute",
              "detail": "",
              "range": {
                "start": {"line": 2, "column": 1}
              }
            }
          ]
        }
        """
        let results = ValidatorOutputParser.parseTerraform(json)
        #expect(results.count == 1)
        #expect(results[0].severity == .warning)
        #expect(results[0].message == "Deprecated attribute")
    }

    @Test func parseTerraform_noRange_defaultsToLine1() {
        let json = """
        {
          "valid": false,
          "diagnostics": [
            {
              "severity": "error",
              "summary": "Module not found"
            }
          ]
        }
        """
        let results = ValidatorOutputParser.parseTerraform(json)
        #expect(results.count == 1)
        #expect(results[0].line == 1)
        #expect(results[0].column == nil)
    }

    @Test func parseTerraform_invalidJSON() {
        let results = ValidatorOutputParser.parseTerraform("broken")
        #expect(results.isEmpty)
    }

    @Test func parseTerraform_emptyString() {
        let results = ValidatorOutputParser.parseTerraform("")
        #expect(results.isEmpty)
    }

    @Test func parseTerraform_noDiagnosticsKey() {
        let json = """
        {"valid": true}
        """
        let results = ValidatorOutputParser.parseTerraform(json)
        #expect(results.isEmpty)
    }

    // MARK: - hadolint parser

    @Test func parseHadolint_singleWarning() {
        let json = """
        [{"line":3,"column":0,"level":"warning","message":"Use COPY instead of ADD","code":"DL3020"}]
        """
        let results = ValidatorOutputParser.parseHadolint(json)
        #expect(results.count == 1)
        #expect(results[0].line == 3)
        #expect(results[0].column == nil) // column 0 → nil
        #expect(results[0].severity == .warning)
        #expect(results[0].message == "DL3020: Use COPY instead of ADD")
        #expect(results[0].source == "hadolint")
    }

    @Test func parseHadolint_error() {
        let json = """
        [{"line":1,"column":1,"level":"error","message":"Invalid base image","code":"DL3006"}]
        """
        let results = ValidatorOutputParser.parseHadolint(json)
        #expect(results.count == 1)
        #expect(results[0].severity == .error)
        #expect(results[0].column == 1)
    }

    @Test func parseHadolint_infoLevel() {
        let json = """
        [{"line":5,"column":0,"level":"info","message":"Pin versions","code":"DL3018"}]
        """
        let results = ValidatorOutputParser.parseHadolint(json)
        #expect(results.count == 1)
        #expect(results[0].severity == .info)
    }

    @Test func parseHadolint_emptyArray() {
        let results = ValidatorOutputParser.parseHadolint("[]")
        #expect(results.isEmpty)
    }

    @Test func parseHadolint_invalidJSON() {
        let results = ValidatorOutputParser.parseHadolint("not json")
        #expect(results.isEmpty)
    }

    // MARK: - ValidationDiagnostic equality

    @Test func diagnostic_equality() {
        let diag1 = ValidationDiagnostic(
            line: 1, column: 2, message: "test", severity: .error, source: "yamllint"
        )
        let diag2 = ValidationDiagnostic(
            line: 1, column: 2, message: "test", severity: .error, source: "yamllint"
        )
        #expect(diag1 == diag2)
    }

    @Test func diagnostic_inequality_differentLine() {
        let diag1 = ValidationDiagnostic(
            line: 1, column: 2, message: "test", severity: .error, source: "yamllint"
        )
        let diag2 = ValidationDiagnostic(
            line: 2, column: 2, message: "test", severity: .error, source: "yamllint"
        )
        #expect(diag1 != diag2)
    }

    @Test func diagnostic_inequality_differentSeverity() {
        let diag1 = ValidationDiagnostic(
            line: 1, column: 2, message: "test", severity: .error, source: "yamllint"
        )
        let diag2 = ValidationDiagnostic(
            line: 1, column: 2, message: "test", severity: .warning, source: "yamllint"
        )
        #expect(diag1 != diag2)
    }

    @Test func diagnostic_inequality_differentSource() {
        let diag1 = ValidationDiagnostic(
            line: 1, column: nil, message: "test", severity: .error, source: "yamllint"
        )
        let diag2 = ValidationDiagnostic(
            line: 1, column: nil, message: "test", severity: .error, source: "shellcheck"
        )
        #expect(diag1 != diag2)
    }

    // MARK: - ValidationSeverity

    @Test func severity_equatable() {
        #expect(ValidationSeverity.error == ValidationSeverity.error)
        #expect(ValidationSeverity.warning == ValidationSeverity.warning)
        #expect(ValidationSeverity.info == ValidationSeverity.info)
        #expect(ValidationSeverity.error != ValidationSeverity.warning)
    }

    // MARK: - ConfigValidator state

    @Test func validator_initialState() {
        let validator = ConfigValidator()
        #expect(validator.diagnostics.isEmpty)
        #expect(validator.isValidating == false)
        #expect(validator.activeValidator == nil)
        #expect(validator.toolAvailable == false)
    }

    @Test func validator_clear_resetsDiagnostics() {
        let validator = ConfigValidator()
        validator.clear()
        #expect(validator.diagnostics.isEmpty)
        #expect(validator.activeValidator == nil)
        #expect(validator.toolAvailable == false)
    }

    // MARK: - ToolAvailability

    @Test func toolAvailability_clearCache() {
        // Just ensure clearCache doesn't crash
        ToolAvailability.clearCache()
    }

    // MARK: - Edge cases: yamllint with path containing colons

    @Test func parseYamllint_pathWithSpaces() {
        let output = "/path/to my/config.yml:7:1: [error] duplication of key"
        let results = ValidatorOutputParser.parseYamllint(output)
        #expect(results.count == 1)
        #expect(results[0].line == 7)
        #expect(results[0].column == 1)
    }

    // MARK: - Multiple diagnostics mixed

    @Test func parseShellcheck_multipleDiagnostics() {
        let json = """
        [
          {"line":1,"column":1,"level":"error","message":"Missing shebang","code":2148},
          {"line":3,"column":5,"level":"warning","message":"Quote variable","code":2086},
          {"line":7,"column":1,"level":"info","message":"Use $() instead of backticks","code":2006}
        ]
        """
        let results = ValidatorOutputParser.parseShellcheck(json)
        #expect(results.count == 3)
        #expect(results[0].severity == .error)
        #expect(results[1].severity == .warning)
        #expect(results[2].severity == .info)
    }

    // MARK: - Terraform multiple diagnostics

    @Test func parseTerraform_multipleDiagnostics() {
        let json = """
        {
          "valid": false,
          "diagnostics": [
            {
              "severity": "error",
              "summary": "First error",
              "range": {"start": {"line": 1, "column": 1}}
            },
            {
              "severity": "warning",
              "summary": "A warning",
              "detail": "More info",
              "range": {"start": {"line": 10, "column": 5}}
            }
          ]
        }
        """
        let results = ValidatorOutputParser.parseTerraform(json)
        #expect(results.count == 2)
        #expect(results[0].line == 1)
        #expect(results[0].severity == .error)
        #expect(results[1].line == 10)
        #expect(results[1].severity == .warning)
        #expect(results[1].message == "A warning: More info")
    }
}
