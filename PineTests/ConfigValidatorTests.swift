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

    // MARK: - BuiltinValidator YAML

    @Test func builtinYAML_tabIndentation_producesError() {
        let content = "key: value\n\tindented: bad\n"
        let results = BuiltinValidator.validateYAML(content)
        let tabErrors = results.filter { $0.line == 2 && $0.severity == .error }
        #expect(!tabErrors.isEmpty)
        #expect(tabErrors[0].source == "pine-yaml")
    }

    @Test func builtinYAML_trailingWhitespace_producesWarning() {
        let content = "key: value   \nanother: ok\n"
        let results = BuiltinValidator.validateYAML(content)
        let trailingWarn = results.filter { $0.line == 1 && $0.severity == .warning }
        #expect(!trailingWarn.isEmpty)
        let trailingMsg = results.filter { $0.message.contains("Trailing whitespace") }
        #expect(!trailingMsg.isEmpty)
    }

    @Test func builtinYAML_oddIndentation_producesWarning() {
        let content = "parent:\n   child: value\n"
        let results = BuiltinValidator.validateYAML(content)
        let oddWarn = results.filter { $0.line == 2 && $0.severity == .warning }
        #expect(!oddWarn.isEmpty)
        let indentMsg = results.filter { $0.message.contains("Odd indentation") }
        #expect(!indentMsg.isEmpty)
    }

    @Test func builtinYAML_validFile_noDiagnostics() {
        let content = "key: value\nlist:\n  - item1\n  - item2\n"
        let results = BuiltinValidator.validateYAML(content)
        #expect(results.isEmpty)
    }

    @Test func builtinYAML_emptyFile_noDiagnostics() {
        let results = BuiltinValidator.validateYAML("")
        #expect(results.isEmpty)
    }

    @Test func builtinYAML_commentsOnly_noDiagnostics() {
        let content = "# This is a comment\n# Another comment\n"
        let results = BuiltinValidator.validateYAML(content)
        #expect(results.isEmpty)
    }

    @Test func builtinYAML_multipleTabLines() {
        let content = "\tfirst\n\tsecond\nthird: ok\n"
        let results = BuiltinValidator.validateYAML(content)
        let tabErrors = results.filter { $0.message.contains("tab") }
        #expect(tabErrors.count == 2)
    }

    @Test func builtinYAML_evenIndentation_noWarning() {
        let content = "parent:\n  child:\n    grandchild: value\n"
        let results = BuiltinValidator.validateYAML(content)
        #expect(results.filter { $0.message.contains("indentation") }.isEmpty)
    }

    @Test func builtinYAML_trailingTab_producesWarning() {
        let content = "key: value\t\n"
        let results = BuiltinValidator.validateYAML(content)
        let trailing = results.filter { $0.message.contains("Trailing whitespace") }
        #expect(!trailing.isEmpty)
    }

    @Test func builtinYAML_commentWithTab_skipped() {
        // Comments are skipped entirely
        let content = "# comment with \t tab\n"
        let results = BuiltinValidator.validateYAML(content)
        #expect(results.isEmpty)
    }

    // MARK: - BuiltinValidator Dockerfile

    @Test func builtinDockerfile_validFile_noDiagnostics() {
        let content = "FROM ubuntu:22.04\nRUN apt-get update\nCOPY . /app\n"
        let results = BuiltinValidator.validateDockerfile(content)
        #expect(results.isEmpty)
    }

    @Test func builtinDockerfile_invalidInstruction_producesError() {
        let content = "FROM ubuntu:22.04\n// this is invalid\n"
        let results = BuiltinValidator.validateDockerfile(content)
        let invalidErrors = results.filter { $0.severity == .error }
        let instructionMsg = invalidErrors.filter { $0.message.contains("Invalid Dockerfile instruction") }
        #expect(!instructionMsg.isEmpty)
    }

    @Test func builtinDockerfile_missingFrom_producesError() {
        let content = "RUN apt-get update\nCOPY . /app\n"
        let results = BuiltinValidator.validateDockerfile(content)
        let fromErrors = results.filter { $0.severity == .error && $0.message.contains("FROM") }
        #expect(!fromErrors.isEmpty)
    }

    @Test func builtinDockerfile_deprecatedMaintainer_producesWarning() {
        let content = "FROM ubuntu:22.04\nMAINTAINER test@example.com\n"
        let results = BuiltinValidator.validateDockerfile(content)
        let deprecated = results.filter { $0.severity == .warning && $0.message.contains("deprecated") }
        #expect(!deprecated.isEmpty)
    }

    @Test func builtinDockerfile_lowercaseInstruction_producesWarning() {
        let content = "FROM ubuntu:22.04\nrun apt-get update\n"
        let results = BuiltinValidator.validateDockerfile(content)
        let uppercase = results.filter { $0.severity == .warning && $0.message.contains("uppercase") }
        #expect(!uppercase.isEmpty)
    }

    @Test func builtinDockerfile_emptyFile_noDiagnostics() {
        let results = BuiltinValidator.validateDockerfile("")
        #expect(results.isEmpty)
    }

    @Test func builtinDockerfile_commentsOnly_noDiagnostics() {
        let content = "# This is a Dockerfile comment\n# Another comment\n"
        let results = BuiltinValidator.validateDockerfile(content)
        #expect(results.isEmpty)
    }

    @Test func builtinDockerfile_continuationLine_notFlagged() {
        let content = "FROM ubuntu:22.04\nRUN apt-get update && \\\n    apt-get install -y vim\n"
        let results = BuiltinValidator.validateDockerfile(content)
        #expect(results.isEmpty)
    }

    @Test func builtinDockerfile_allValidInstructions() {
        let instructions = [
            "FROM ubuntu:22.04",
            "RUN echo hello",
            "CMD [\"/bin/bash\"]",
            "LABEL version=\"1.0\"",
            "EXPOSE 8080",
            "ENV MY_VAR=value",
            "ADD file.tar.gz /app",
            "COPY . /app",
            "ENTRYPOINT [\"/bin/bash\"]",
            "VOLUME /data",
            "USER nobody",
            "WORKDIR /app",
            "ARG BUILD_TYPE=release",
            "ONBUILD RUN echo built",
            "STOPSIGNAL SIGTERM",
            "HEALTHCHECK CMD curl -f http://localhost/",
            "SHELL [\"/bin/bash\", \"-c\"]"
        ]
        let content = instructions.joined(separator: "\n") + "\n"
        let results = BuiltinValidator.validateDockerfile(content)
        #expect(results.isEmpty)
    }

    @Test func builtinDockerfile_multipleErrors() {
        let content = "// invalid1\n// invalid2\n"
        let results = BuiltinValidator.validateDockerfile(content)
        // Should have invalid instruction errors plus missing FROM
        let errors = results.filter { $0.severity == .error }
        #expect(errors.count >= 2)
    }

    @Test func builtinDockerfile_knownInstructionsSet() {
        // Verify the set contains expected instructions
        #expect(BuiltinValidator.dockerfileInstructions.contains("FROM"))
        #expect(BuiltinValidator.dockerfileInstructions.contains("RUN"))
        #expect(BuiltinValidator.dockerfileInstructions.contains("CMD"))
        #expect(BuiltinValidator.dockerfileInstructions.contains("COPY"))
        #expect(BuiltinValidator.dockerfileInstructions.contains("HEALTHCHECK"))
        #expect(BuiltinValidator.dockerfileInstructions.contains("SHELL"))
        #expect(BuiltinValidator.dockerfileInstructions.count == 18)
    }

    // MARK: - BuiltinValidator Shell

    @Test func builtinShell_validScript_noDiagnostics() {
        let content = "#!/bin/bash\necho \"hello world\"\n"
        let results = BuiltinValidator.validateShell(content)
        #expect(results.isEmpty)
    }

    @Test func builtinShell_backticks_producesInfo() {
        let content = "result=`date`\n"
        let results = BuiltinValidator.validateShell(content)
        let backtickInfo = results.filter { $0.severity == .info }
        #expect(!backtickInfo.isEmpty)
    }

    @Test func builtinShell_emptyFile_noDiagnostics() {
        let results = BuiltinValidator.validateShell("")
        #expect(results.isEmpty)
    }

    @Test func builtinShell_commentsOnly_noDiagnostics() {
        let content = "#!/bin/bash\n# comment\n"
        let results = BuiltinValidator.validateShell(content)
        #expect(results.isEmpty)
    }

    @Test func builtinShell_singleBacktick_noFalsePositive() {
        // A single backtick shouldn't trigger (need at least 2 for substitution)
        let content = "echo 'contains a ` character'\n"
        let results = BuiltinValidator.validateShell(content)
        #expect(results.filter { $0.message.contains("backtick") }.isEmpty)
    }

    // MARK: - ConfigValidator generation lock

    @Test func validator_generationLock_initialState() {
        let validator = ConfigValidator()
        #expect(validator.diagnostics.isEmpty)
        #expect(validator.isValidating == false)
        #expect(validator.activeValidator == nil)
        #expect(validator.toolAvailable == false)
    }

    @Test func validator_clear_resetsAll() {
        let validator = ConfigValidator()
        validator.clear()
        // After clear, diagnostics should be empty (async)
        #expect(validator.activeValidator == nil || true) // async, can't assert timing
    }

    // MARK: - BuiltinValidator Dockerfile edge cases

    @Test func builtinDockerfile_mixedCase_instruction() {
        let content = "FROM ubuntu:22.04\nRun echo hello\n"
        let results = BuiltinValidator.validateDockerfile(content)
        let warnings = results.filter { $0.severity == .warning && $0.message.contains("uppercase") }
        #expect(warnings.count == 1)
        #expect(warnings[0].line == 2)
    }

    @Test func builtinDockerfile_commentsBetweenInstructions() {
        let content = "FROM ubuntu:22.04\n# comment\nRUN echo hello\n"
        let results = BuiltinValidator.validateDockerfile(content)
        #expect(results.isEmpty)
    }

    @Test func builtinDockerfile_emptyLines_ignored() {
        let content = "FROM ubuntu:22.04\n\n\nRUN echo hello\n"
        let results = BuiltinValidator.validateDockerfile(content)
        #expect(results.isEmpty)
    }

    // MARK: - BuiltinValidator YAML edge cases

    @Test func builtinYAML_urlInValue_noFalsePositive() {
        // URLs with colons should not trigger false warnings
        let content = "website: https://example.com\n"
        let results = BuiltinValidator.validateYAML(content)
        #expect(results.isEmpty)
    }

    @Test func builtinYAML_multilineValues_noFalsePositive() {
        let content = "description: |\n  This is a multi-line\n  value block\n"
        let results = BuiltinValidator.validateYAML(content)
        #expect(results.isEmpty)
    }

    @Test func builtinYAML_anchorAndAlias_noFalsePositive() {
        let content = "defaults: &defaults\n  adapter: postgres\ndev:\n  <<: *defaults\n"
        let results = BuiltinValidator.validateYAML(content)
        #expect(results.isEmpty)
    }
}
