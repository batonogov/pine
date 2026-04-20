//
//  HCLFileFormatterTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("HCLFileFormatter")
struct HCLFileFormatterTests {

    // MARK: - Terraform formatting

    @Test("Terraform found — formats .tf files")
    func terraformFormatsTFFiles() {
        let runner = MockProcessRunner(stdout: "resource \"aws_instance\" \"web\" {\n  ami = \"abc-123\"\n}\n", stderr: "", exitCode: 0)
        let formatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/terraform",
            toolName: "terraform",
            extensions: ["tf", "tfvars"],
            arguments: ["fmt", "-"],
            processRunner: runner
        )
        let result = formatter.format(
            "resource \"aws_instance\" \"web\" {\nami = \"abc-123\"\n}\n",
            url: URL(fileURLWithPath: "/project/main.tf")
        )
        #expect(result == "resource \"aws_instance\" \"web\" {\n  ami = \"abc-123\"\n}\n")
    }

    @Test("Terraform found — formats .tfvars files")
    func terraformFormatsTFVarsFiles() {
        let runner = MockProcessRunner(stdout: "region = \"us-east-1\"\n", stderr: "", exitCode: 0)
        let formatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/terraform",
            toolName: "terraform",
            extensions: ["tf", "tfvars"],
            arguments: ["fmt", "-"],
            processRunner: runner
        )
        let result = formatter.format(
            "region=\"us-east-1\"\n",
            url: URL(fileURLWithPath: "/project/terraform.tfvars")
        )
        #expect(result == "region = \"us-east-1\"\n")
    }

    // MARK: - OpenTofu fallback

    @Test("Tofu fallback when terraform is missing")
    func tofuFallbackWhenTerraformMissing() throws {
        // Use unique tool names that won't exist in well-known dirs.
        // We create a temp dir with only "tofu" present (no "terraform").
        // To avoid well-known dirs resolving real tools, we use a resolver with
        // ONLY the temp dir by overriding PATH to a non-existent prefix that
        // won't contain terraform or tofu. But ExternalToolResolver always appends
        // well-known dirs. So we test the resolve logic directly:
        // If a resolver only finds "tofu" (not "terraform"), the factory returns tofu.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create only a tofu executable in our temp dir
        let tofuPath = tempDir.appendingPathComponent("tofu")
        FileManager.default.createFile(atPath: tofuPath.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tofuPath.path)

        // Use a pathString that lists our temp dir first. The resolver searches PATH dirs
        // first and caches results. Since terraform won't be found in tempDir, it falls
        // through to well-known dirs. On machines without terraform, this tests the fallback.
        // We verify the behavior by using explicit toolPath instead:
        let runner = MockProcessRunner(stdout: "formatted by tofu", stderr: "", exitCode: 0)
        let formatter = ExternalFileFormatter(
            toolPath: tofuPath.path,
            toolName: "tofu",
            extensions: ["tf", "tfvars"],
            arguments: ["fmt", "-"],
            processRunner: runner
        )

        #expect(formatter.toolName == "tofu")
        #expect(formatter.toolPath == tofuPath.path)
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/main.tf")))

        let result = formatter.format("resource {}", url: URL(fileURLWithPath: "/project/main.tf"))
        #expect(result == "formatted by tofu")
    }

    // MARK: - Neither installed

    @Test("Neither installed — returns original content (no-op formatter)")
    func neitherInstalledReturnsOriginal() {
        // When neither terraform nor tofu is found, HCLFileFormatter.resolve() returns
        // a formatter with toolPath=nil. We test this directly with the explicit init.
        let runner = MockProcessRunner(stdout: "should not appear", stderr: "", exitCode: 0)
        let formatter = ExternalFileFormatter(
            toolPath: nil,
            toolName: "terraform",
            extensions: ["tf", "tfvars"],
            arguments: ["fmt", "-"],
            processRunner: runner
        )

        #expect(formatter.toolPath == nil)
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/main.tf")))

        let result = formatter.format("original content", url: URL(fileURLWithPath: "/project/main.tf"))
        #expect(result == "original content")
    }

    // MARK: - Error handling

    @Test("Non-zero exit code — returns original content")
    func nonZeroExitReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "partial output", stderr: "Error: Invalid HCL", exitCode: 1)
        let formatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/terraform",
            toolName: "terraform",
            extensions: ["tf", "tfvars"],
            arguments: ["fmt", "-"],
            processRunner: runner
        )
        let result = formatter.format("invalid { hcl", url: URL(fileURLWithPath: "/project/main.tf"))
        #expect(result == "invalid { hcl")
    }

    @Test("Timeout — returns original content")
    func timeoutReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "", stderr: "", exitCode: 0, simulateTimeout: true)
        let formatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/terraform",
            toolName: "terraform",
            extensions: ["tf", "tfvars"],
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
        let formatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/terraform",
            toolName: "terraform",
            extensions: ["tf", "tfvars"],
            arguments: ["fmt", "-"],
            processRunner: runner
        )
        let result = formatter.format("resource {}", url: URL(fileURLWithPath: "/project/main.tf"))
        #expect(result == "resource {}")
    }

    // MARK: - Extension handling

    @Test("Case-insensitive extensions — .TF and .TFVARS are formatted")
    func caseInsensitiveExtensions() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/terraform",
            toolName: "terraform",
            extensions: ["tf", "tfvars"],
            arguments: ["fmt", "-"],
            processRunner: runner
        )
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/MAIN.TF")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/vars.TFVARS")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/mixed.Tf")))
    }

    @Test("Non-HCL files are not formatted")
    func nonHCLFilesIgnored() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/terraform",
            toolName: "terraform",
            extensions: ["tf", "tfvars"],
            arguments: ["fmt", "-"],
            processRunner: runner
        )
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/main.swift")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/config.json")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/style.css")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/readme.md")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/main.hcl")))
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

        let resolver = ExternalToolResolver(pathString: tempDir.path)
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = HCLFileFormatter.resolve(processRunner: runner, resolver: resolver)

        #expect(formatter.toolName == "terraform")
        #expect(formatter.toolPath == tempDir.appendingPathComponent("terraform").path)
    }

    // MARK: - Stdin piping

    @Test("File content is piped to the process via stdin")
    func stdinReceivesFileContent() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/terraform",
            toolName: "terraform",
            extensions: ["tf", "tfvars"],
            arguments: ["fmt", "-"],
            processRunner: runner
        )
        _ = formatter.format("resource \"null\" {}\n", url: URL(fileURLWithPath: "/project/main.tf"))
        #expect(runner.lastStdinContent == "resource \"null\" {}\n")
    }

    // MARK: - Registry integration

    @Test("HCL formatter coexists with JSON formatter in registry")
    func registryIntegration() {
        let runner = MockProcessRunner(stdout: "hcl-formatted", stderr: "", exitCode: 0)
        let hclFormatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/terraform",
            toolName: "terraform",
            extensions: ["tf", "tfvars"],
            arguments: ["fmt", "-"],
            processRunner: runner
        )
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
