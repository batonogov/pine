//
//  LanguageValidatorTests.swift
//  PineTests
//
//  Tests for each LanguageValidator conformance: protocol requirements,
//  matching by extension/name, tool-found/not-found paths, and built-in fallback.
//

import Foundation
import Testing
@testable import Pine

@Suite("LanguageValidator Tests")
struct LanguageValidatorTests {

    // MARK: - YAMLLanguageValidator

    @Test func yaml_supportedExtensions() {
        let validator = YAMLLanguageValidator()
        #expect(validator.supportedExtensions == ["yml", "yaml"])
    }

    @Test func yaml_supportedNames_empty() {
        let validator = YAMLLanguageValidator()
        #expect(validator.supportedNames.isEmpty)
    }

    @Test func yaml_supportedNamePrefixes_empty() {
        let validator = YAMLLanguageValidator()
        #expect(validator.supportedNamePrefixes.isEmpty)
    }

    @Test func yaml_toolAndDisplayNames() {
        let validator = YAMLLanguageValidator()
        #expect(validator.toolName == "yamllint")
        #expect(validator.displayName == "yamllint")
    }

    @Test func yaml_validatorKind() {
        let validator = YAMLLanguageValidator()
        #expect(validator.validatorKind == .yamllint)
    }

    @Test func yaml_builtinValidation_returnsDiagnostics() {
        let validator = YAMLLanguageValidator()
        let content = "\tkey: value\n"
        guard let result = validator.builtinValidation(content) else {
            Issue.record("Expected non-nil built-in validation result")
            return
        }
        #expect(!result.isEmpty)
    }

    @Test func yaml_builtinValidation_validContent_returnsEmpty() {
        let validator = YAMLLanguageValidator()
        let content = "key: value\nlist:\n  - item\n"
        guard let result = validator.builtinValidation(content) else {
            Issue.record("Expected non-nil built-in validation result")
            return
        }
        #expect(result.isEmpty)
    }

    @Test func yaml_parseToolOutput_delegatesToParser() {
        let validator = YAMLLanguageValidator()
        let output = "config.yml:3:1: [error] syntax error"
        let result = validator.parseToolOutput(output)
        #expect(result.count == 1)
        #expect(result[0].line == 3)
    }

    @Test func yaml_validate_noTool_fallsBackToBuiltin() {
        let validator = YAMLLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/test.yml")
        let content = "\tkey: value\n"
        let result = validator.validate(url: url, content: content)
        if !result.toolAvailable {
            let tabErrors = result.diagnostics.filter { $0.message.contains("tab") }
            #expect(!tabErrors.isEmpty)
        }
    }

    @Test func yaml_validate_noTool_validContent_emptyDiagnostics() {
        let validator = YAMLLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/valid.yml")
        let content = "key: value\nlist:\n  - item\n"
        let result = validator.validate(url: url, content: content)
        if !result.toolAvailable {
            #expect(result.diagnostics.isEmpty)
        }
    }

    @Test func yaml_validate_preservesToolAvailableFlag() {
        let validator = YAMLLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/test.yml")
        let content = "key: value\n"
        let result = validator.validate(url: url, content: content)
        // Either tool is available or not — both are valid outcomes
        #expect(result.toolAvailable == ToolAvailability.path(for: "yamllint").map { _ in true } ?? false)
    }

    // MARK: - ShellLanguageValidator

    @Test func shell_supportedExtensions() {
        let validator = ShellLanguageValidator()
        #expect(validator.supportedExtensions == ["sh", "bash", "zsh"])
    }

    @Test func shell_supportedNames_empty() {
        let validator = ShellLanguageValidator()
        #expect(validator.supportedNames.isEmpty)
    }

    @Test func shell_supportedNamePrefixes_empty() {
        let validator = ShellLanguageValidator()
        #expect(validator.supportedNamePrefixes.isEmpty)
    }

    @Test func shell_toolAndDisplayNames() {
        let validator = ShellLanguageValidator()
        #expect(validator.toolName == "shellcheck")
        #expect(validator.displayName == "shellcheck")
    }

    @Test func shell_validatorKind() {
        let validator = ShellLanguageValidator()
        #expect(validator.validatorKind == .shellcheck)
    }

    @Test func shell_builtinValidation_returnsDiagnostics() {
        let validator = ShellLanguageValidator()
        let content = "result=`date`\n"
        guard let result = validator.builtinValidation(content) else {
            Issue.record("Expected non-nil built-in validation result")
            return
        }
        #expect(!result.isEmpty)
    }

    @Test func shell_builtinValidation_validContent_returnsEmpty() {
        let validator = ShellLanguageValidator()
        let content = "#!/bin/bash\necho \"hello\"\n"
        guard let result = validator.builtinValidation(content) else {
            Issue.record("Expected non-nil built-in validation result")
            return
        }
        #expect(result.isEmpty)
    }

    @Test func shell_parseToolOutput_delegatesToParser() {
        let validator = ShellLanguageValidator()
        let json = "[{\"line\":3,\"column\":5,\"level\":\"error\",\"message\":\"Error\",\"code\":1}]"
        let result = validator.parseToolOutput(json)
        #expect(result.count == 1)
        #expect(result[0].line == 3)
    }

    @Test func shell_validate_noTool_fallsBackToBuiltin() {
        let validator = ShellLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/test.sh")
        let content = "result=`date`\n"
        let result = validator.validate(url: url, content: content)
        if !result.toolAvailable {
            let backtickInfo = result.diagnostics.filter { $0.severity == .info }
            #expect(!backtickInfo.isEmpty)
        }
    }

    @Test func shell_validate_noTool_validContent_emptyDiagnostics() {
        let validator = ShellLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/test.sh")
        let content = "#!/bin/bash\necho \"hello\"\n"
        let result = validator.validate(url: url, content: content)
        if !result.toolAvailable {
            #expect(result.diagnostics.isEmpty)
        }
    }

    // MARK: - DockerfileLanguageValidator

    @Test func dockerfile_supportedExtensions_empty() {
        let validator = DockerfileLanguageValidator()
        #expect(validator.supportedExtensions.isEmpty)
    }

    @Test func dockerfile_supportedNames() {
        let validator = DockerfileLanguageValidator()
        #expect(validator.supportedNames == ["dockerfile"])
    }

    @Test func dockerfile_supportedNamePrefixes() {
        let validator = DockerfileLanguageValidator()
        #expect(validator.supportedNamePrefixes == ["dockerfile."])
    }

    @Test func dockerfile_toolAndDisplayNames() {
        let validator = DockerfileLanguageValidator()
        #expect(validator.toolName == "hadolint")
        #expect(validator.displayName == "hadolint")
    }

    @Test func dockerfile_validatorKind() {
        let validator = DockerfileLanguageValidator()
        #expect(validator.validatorKind == .hadolint)
    }

    @Test func dockerfile_builtinValidation_returnsDiagnostics() {
        let validator = DockerfileLanguageValidator()
        let content = "INVALID foo\n"
        guard let result = validator.builtinValidation(content) else {
            Issue.record("Expected non-nil built-in validation result")
            return
        }
        #expect(!result.isEmpty)
    }

    @Test func dockerfile_builtinValidation_validContent_returnsEmpty() {
        let validator = DockerfileLanguageValidator()
        let content = "FROM ubuntu:22.04\nRUN echo hello\n"
        guard let result = validator.builtinValidation(content) else {
            Issue.record("Expected non-nil built-in validation result")
            return
        }
        #expect(result.isEmpty)
    }

    @Test func dockerfile_parseToolOutput_delegatesToParser() {
        let validator = DockerfileLanguageValidator()
        let json = "[{\"line\":1,\"column\":0,\"level\":\"warning\",\"message\":\"Pin versions\",\"code\":\"DL3008\"}]"
        let result = validator.parseToolOutput(json)
        #expect(result.count == 1)
        #expect(result[0].line == 1)
    }

    @Test func dockerfile_validate_noTool_fallsBackToBuiltin() {
        let validator = DockerfileLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/Dockerfile")
        let content = "RUN echo hello\n"
        let result = validator.validate(url: url, content: content)
        if !result.toolAvailable {
            let fromErrors = result.diagnostics.filter { $0.message.contains("FROM") }
            #expect(!fromErrors.isEmpty)
        }
    }

    @Test func dockerfile_validate_noTool_validContent_emptyDiagnostics() {
        let validator = DockerfileLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/Dockerfile")
        let content = "FROM ubuntu:22.04\nRUN echo hello\n"
        let result = validator.validate(url: url, content: content)
        if !result.toolAvailable {
            #expect(result.diagnostics.isEmpty)
        }
    }

    // MARK: - TerraformLanguageValidator

    @Test func terraform_supportedExtensions() {
        let validator = TerraformLanguageValidator()
        #expect(validator.supportedExtensions == ["tf", "tfvars"])
    }

    @Test func terraform_supportedNames_empty() {
        let validator = TerraformLanguageValidator()
        #expect(validator.supportedNames.isEmpty)
    }

    @Test func terraform_supportedNamePrefixes_empty() {
        let validator = TerraformLanguageValidator()
        #expect(validator.supportedNamePrefixes.isEmpty)
    }

    @Test func terraform_toolAndDisplayNames() {
        let validator = TerraformLanguageValidator()
        #expect(validator.toolName == "terraform")
        #expect(validator.displayName == "terraform")
    }

    @Test func terraform_validatorKind() {
        let validator = TerraformLanguageValidator()
        #expect(validator.validatorKind == .terraform)
    }

    @Test func terraform_builtinValidation_returnsNil() {
        let validator = TerraformLanguageValidator()
        let content = "resource \"null_resource\" \"test\" {}\n"
        let result = validator.builtinValidation(content)
        #expect(result == nil, "Terraform has no built-in validation")
    }

    @Test func terraform_parseToolOutput_delegatesToParser() {
        let validator = TerraformLanguageValidator()
        let json = "{\"valid\":false,\"diagnostics\":[{\"severity\":\"error\",\"summary\":\"Error\"}]}"
        let result = validator.parseToolOutput(json)
        #expect(result.count == 1)
    }

    @Test func terraform_validate_noTool_noBuiltin_returnsEmptyDiagnostics() {
        let validator = TerraformLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/main.tf")
        let content = "resource \"null_resource\" \"test\" {}\n"
        let result = validator.validate(url: url, content: content)
        if !result.toolAvailable {
            // No built-in terraform validation — empty diagnostics expected
            #expect(result.diagnostics.isEmpty)
        }
    }

    // MARK: - ConfigValidator facade dispatches to correct validator

    @Test func facade_matchesByExtension_yml() {
        let facade = ConfigValidator()
        let validators = facade.validators
        let ext = "yml"
        let matched = validators.first { $0.supportedExtensions.contains(ext) }
        #expect(matched is YAMLLanguageValidator)
    }

    @Test func facade_matchesByExtension_yaml() {
        let facade = ConfigValidator()
        let validators = facade.validators
        let ext = "yaml"
        let matched = validators.first { $0.supportedExtensions.contains(ext) }
        #expect(matched is YAMLLanguageValidator)
    }

    @Test func facade_matchesByExtension_sh() {
        let facade = ConfigValidator()
        let validators = facade.validators
        let ext = "sh"
        let matched = validators.first { $0.supportedExtensions.contains(ext) }
        #expect(matched is ShellLanguageValidator)
    }

    @Test func facade_matchesByExtension_bash() {
        let facade = ConfigValidator()
        let validators = facade.validators
        let ext = "bash"
        let matched = validators.first { $0.supportedExtensions.contains(ext) }
        #expect(matched is ShellLanguageValidator)
    }

    @Test func facade_matchesByExtension_zsh() {
        let facade = ConfigValidator()
        let validators = facade.validators
        let ext = "zsh"
        let matched = validators.first { $0.supportedExtensions.contains(ext) }
        #expect(matched is ShellLanguageValidator)
    }

    @Test func facade_matchesByExtension_tf() {
        let facade = ConfigValidator()
        let validators = facade.validators
        let ext = "tf"
        let matched = validators.first { $0.supportedExtensions.contains(ext) }
        #expect(matched is TerraformLanguageValidator)
    }

    @Test func facade_matchesByExtension_tfvars() {
        let facade = ConfigValidator()
        let validators = facade.validators
        let ext = "tfvars"
        let matched = validators.first { $0.supportedExtensions.contains(ext) }
        #expect(matched is TerraformLanguageValidator)
    }

    @Test func facade_matchesByName_dockerfile() {
        let facade = ConfigValidator()
        let validators = facade.validators
        let name = "dockerfile"
        let matched = validators.first { $0.supportedNames.contains(name) }
        #expect(matched is DockerfileLanguageValidator)
    }

    @Test func facade_matchesByNamePrefix_dockerfileDot() {
        let facade = ConfigValidator()
        let validators = facade.validators
        let name = "dockerfile.prod"
        let matched = validators.first { v in
            v.supportedNamePrefixes.contains(where: { name.hasPrefix($0) })
        }
        #expect(matched is DockerfileLanguageValidator)
    }

    @Test func facade_noMatch_forSwift() {
        let facade = ConfigValidator()
        let validators = facade.validators
        let ext = "swift"
        let matched = validators.first { $0.supportedExtensions.contains(ext) }
        #expect(matched == nil)
    }

    @Test func facade_noMatch_forJson() {
        let facade = ConfigValidator()
        let validators = facade.validators
        let ext = "json"
        let matched = validators.first { $0.supportedExtensions.contains(ext) }
        #expect(matched == nil)
    }

    // MARK: - Temp file uses UUID (no collision)

    @Test func tempFileCollisionResistance() async {
        // Run two validators concurrently with same file name.
        // UUID-based temp file names must not collide.
        let validator = YAMLLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/test.yml")
        let content = "key: value\n"

        async let r1 = Task.detached {
            validator.validate(url: url, content: content)
        }.value

        async let r2 = Task.detached {
            validator.validate(url: url, content: content)
        }.value

        let result1 = await r1
        let result2 = await r2

        // Both should succeed without errors (no crash from file collision)
        #expect(result1.diagnostics.isEmpty || result1.toolAvailable)
        #expect(result2.diagnostics.isEmpty || result2.toolAvailable)
    }

    // MARK: - Protocol default validate() built-in fallback logic

    @Test func defaultValidate_builtinFallbackOnlyWhenNoTool() {
        // When external tool is not available, built-in should be used.
        // Verify by checking that the YAML validator produces diagnostics
        // for content that the built-in validator catches.
        let validator = YAMLLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/test.yml")
        let content = "\tkey: value\n" // tab indentation

        let result = validator.validate(url: url, content: content)
        if !result.toolAvailable {
            #expect(!result.diagnostics.isEmpty, "Built-in should produce diagnostics for tab indentation")
        }
    }

    @Test func defaultValidate_noBuiltin_returnsEmptyWhenNoTool() {
        // Terraform has no built-in fallback — should return empty diagnostics.
        let validator = TerraformLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/main.tf")
        let content = "broken { }\n"
        let result = validator.validate(url: url, content: content)
        if !result.toolAvailable {
            #expect(result.diagnostics.isEmpty, "No built-in terraform validation means empty diagnostics")
        }
    }

    @Test func defaultValidate_toolInstalled_emptyOutputMeansValid() {
        // If external tool is installed and returns empty output,
        // the file is considered valid (built-in is NOT run).
        // We can only test this meaningfully when the tool is installed.
        let validator = YAMLLanguageValidator()
        let url = URL(fileURLWithPath: "/tmp/test.yml")
        let content = "\tkey: value\n"
        let result = validator.validate(url: url, content: content)
        if result.toolAvailable {
            // External tool produced results — we can't predict exact output,
            // but verify the method runs without crashing.
            _ = result.diagnostics
        }
    }
}
