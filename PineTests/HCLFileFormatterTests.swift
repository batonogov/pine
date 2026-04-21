//
//  HCLFileFormatterTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("HCLFileFormatter")
struct HCLFileFormatterTests {

    // MARK: - Helper

    private func makeFormatter(
        extensions: [String] = ["tf", "tfvars", "hcl"],
        arguments: [String] = ["fmt", "-"],
        runner: MockProcessRunner,
        toolPath: String? = "/usr/local/bin/terraform",
        toolName: String = "terraform"
    ) -> ExternalFileFormatter {
        ExternalFileFormatter(
            toolPath: toolPath,
            toolName: toolName,
            extensions: extensions,
            arguments: arguments,
            processRunner: runner
        )
    }

    // MARK: - Terraform formatting

    @Test("Terraform found — formats .tf files")
    func terraformFormatsTFFiles() {
        let runner = MockProcessRunner(
            stdout: "resource \"aws_instance\" \"web\" {\n  ami = \"abc-123\"\n}\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "resource \"aws_instance\" \"web\" {\nami = \"abc-123\"\n}\n",
            url: URL(fileURLWithPath: "/project/main.tf")
        )
        #expect(result == "resource \"aws_instance\" \"web\" {\n  ami = \"abc-123\"\n}\n")
    }

    @Test("Terraform found — formats .tfvars files")
    func terraformFormatsTFVarsFiles() {
        let runner = MockProcessRunner(stdout: "region = \"us-east-1\"\n", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "region=\"us-east-1\"\n",
            url: URL(fileURLWithPath: "/project/terraform.tfvars")
        )
        #expect(result == "region = \"us-east-1\"\n")
    }

    @Test("Terraform found — formats .hcl files")
    func terraformFormatsHCLFiles() {
        let runner = MockProcessRunner(
            stdout: "variable \"region\" {\n  default = \"us-east-1\"\n}\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "variable \"region\" {\ndefault = \"us-east-1\"\n}\n",
            url: URL(fileURLWithPath: "/project/config.hcl")
        )
        #expect(result == "variable \"region\" {\n  default = \"us-east-1\"\n}\n")
    }

    // MARK: - OpenTofu fallback

    @Test("Tofu fallback when terraform is missing")
    func tofuFallbackWhenTerraformMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create only a tofu executable in the temp dir (no terraform)
        let tofuPath = tempDir.appendingPathComponent("tofu")
        FileManager.default.createFile(atPath: tofuPath.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tofuPath.path)

        // Use searchDirectories init to avoid well-known dirs (which may contain real terraform)
        let resolver = ExternalToolResolver(searchDirectories: [tempDir.path])
        let runner = MockProcessRunner(stdout: "formatted by tofu", stderr: "", exitCode: 0)
        let formatter = HCLFileFormatter.resolve(processRunner: runner, resolver: resolver)

        #expect(formatter.toolName == "tofu")
        #expect(formatter.toolPath == tofuPath.path)
    }

    // MARK: - Neither installed

    @Test("Neither installed — returns original content (no-op formatter)")
    func neitherInstalledReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "should not appear", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner, toolPath: nil)

        #expect(formatter.toolPath == nil)
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/main.tf")))

        let result = formatter.format("original content", url: URL(fileURLWithPath: "/project/main.tf"))
        #expect(result == "original content")
    }

    // MARK: - Error handling

    @Test("Non-zero exit code — returns original content")
    func nonZeroExitReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "partial output", stderr: "Error: Invalid HCL", exitCode: 1)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format("invalid { hcl", url: URL(fileURLWithPath: "/project/main.tf"))
        #expect(result == "invalid { hcl")
    }

    @Test("Timeout — returns original content")
    func timeoutReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "", stderr: "", exitCode: 0, simulateTimeout: true)
        let formatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/terraform",
            toolName: "terraform",
            extensions: ["tf", "tfvars", "hcl"],
            arguments: ["fmt", "-"],
            processRunner: runner,
            timeout: 0.1
        )
        let result = formatter.format("resource {}", url: URL(fileURLWithPath: "/project/main.tf"))
        #expect(result == "resource {}")
    }

    @Test("Empty stdout — returns original content")
    func emptyStdoutReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format("resource {}", url: URL(fileURLWithPath: "/project/main.tf"))
        #expect(result == "resource {}")
    }

    // MARK: - Extension handling

    @Test("Case-insensitive extensions — .TF, .TFVARS, and .HCL are formatted")
    func caseInsensitiveExtensions() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/MAIN.TF")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/vars.TFVARS")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/mixed.Tf")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/config.HCL")))
    }

    @Test("Non-HCL files are not formatted")
    func nonHCLFilesIgnored() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/main.swift")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/config.json")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/style.css")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/readme.md")))
    }

    @Test(".hcl files ARE formatted")
    func hclExtensionIsFormatted() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/main.hcl")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/packer.hcl")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/vault.hcl")))
    }

    // MARK: - Priority

    @Test("Terraform preferred over tofu when both installed")
    func terraformPreferredOverTofu() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create both terraform and tofu executables
        for name in ["terraform", "tofu"] {
            let path = tempDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: path.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        // Use searchDirectories init for isolation from system-installed tools
        let resolver = ExternalToolResolver(searchDirectories: [tempDir.path])
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = HCLFileFormatter.resolve(processRunner: runner, resolver: resolver)

        #expect(formatter.toolName == "terraform")
        #expect(formatter.toolPath == tempDir.appendingPathComponent("terraform").path)
    }

    // MARK: - Stdin piping

    @Test("File content is piped to the process via stdin")
    func stdinReceivesFileContent() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        _ = formatter.format("resource \"null\" {}\n", url: URL(fileURLWithPath: "/project/main.tf"))
        #expect(runner.lastStdinContent == "resource \"null\" {}\n")
    }

    // MARK: - Tofu formatting

    @Test("Tofu formats .tf files when it is the resolved tool")
    func tofuFormatsTFFiles() {
        let runner = MockProcessRunner(
            stdout: "resource \"aws_instance\" \"web\" {\n  ami = \"abc-123\"\n}\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner, toolPath: "/opt/homebrew/bin/tofu", toolName: "tofu")
        let result = formatter.format(
            "resource \"aws_instance\" \"web\" {\nami = \"abc-123\"\n}\n",
            url: URL(fileURLWithPath: "/project/main.tf")
        )
        #expect(result == "resource \"aws_instance\" \"web\" {\n  ami = \"abc-123\"\n}\n")
    }

    @Test("Tofu formats .tfvars files")
    func tofuFormatsTFVarsFiles() {
        let runner = MockProcessRunner(stdout: "region = \"us-east-1\"\n", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner, toolPath: "/opt/homebrew/bin/tofu", toolName: "tofu")
        let result = formatter.format(
            "region=\"us-east-1\"\n",
            url: URL(fileURLWithPath: "/project/terraform.tfvars")
        )
        #expect(result == "region = \"us-east-1\"\n")
    }

    @Test("Tofu formats .hcl files")
    func tofuFormatsHCLFiles() {
        let runner = MockProcessRunner(
            stdout: "variable \"region\" {\n  default = \"us-east-1\"\n}\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner, toolPath: "/opt/homebrew/bin/tofu", toolName: "tofu")
        let result = formatter.format(
            "variable \"region\" {\ndefault = \"us-east-1\"\n}\n",
            url: URL(fileURLWithPath: "/project/config.hcl")
        )
        #expect(result == "variable \"region\" {\n  default = \"us-east-1\"\n}\n")
    }

    @Test("Tofu non-zero exit code — returns original content")
    func tofuNonZeroExitReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "partial", stderr: "Error", exitCode: 1)
        let formatter = makeFormatter(runner: runner, toolPath: "/opt/homebrew/bin/tofu", toolName: "tofu")
        let result = formatter.format("invalid { hcl", url: URL(fileURLWithPath: "/project/main.tf"))
        #expect(result == "invalid { hcl")
    }

    // MARK: - Main-thread safety (regression for #873)

    @Test("format() can be called from the main thread without crashing")
    @MainActor
    func formatFromMainThreadDoesNotCrash() {
        let runner = MockProcessRunner(
            stdout: "resource \"aws_instance\" \"web\" {\n  ami = \"abc-123\"\n}\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "resource \"aws_instance\" \"web\" {\nami = \"abc-123\"\n}\n",
            url: URL(fileURLWithPath: "/project/main.tf")
        )
        #expect(result == "resource \"aws_instance\" \"web\" {\n  ami = \"abc-123\"\n}\n")
    }

    // MARK: - Registry integration

    @Test("HCL formatter coexists with JSON formatter in registry")
    func registryIntegration() {
        let runner = MockProcessRunner(stdout: "hcl-formatted", stderr: "", exitCode: 0)
        let hclFormatter = makeFormatter(runner: runner)
        let registry = FileFormatterRegistry(formatters: [JSONFileFormatter(), hclFormatter])

        // .tf file should be handled by HCL formatter
        let tfResult = registry.format(
            content: "resource {}",
            url: URL(fileURLWithPath: "/project/main.tf")
        )
        #expect(tfResult == "hcl-formatted")

        // .tfvars file should be handled by HCL formatter
        let tfvarsResult = registry.format(
            content: "region = \"us-east-1\"",
            url: URL(fileURLWithPath: "/project/vars.tfvars")
        )
        #expect(tfvarsResult == "hcl-formatted")

        // .hcl file should be handled by HCL formatter
        let hclResult = registry.format(
            content: "variable {}",
            url: URL(fileURLWithPath: "/project/config.hcl")
        )
        #expect(hclResult == "hcl-formatted")

        // .json file should still be handled by JSON formatter
        let jsonResult = registry.format(
            content: #"{"key":"value"}"#,
            url: URL(fileURLWithPath: "/project/config.json")
        )
        #expect(jsonResult.contains("\"key\""))

        // .swift file should not be formatted (returned as-is)
        let swiftResult = registry.format(
            content: "let x = 1",
            url: URL(fileURLWithPath: "/project/main.swift")
        )
        #expect(swiftResult == "let x = 1")
    }
}
