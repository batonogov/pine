//
//  YAMLFileFormatterTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("YAMLFileFormatter")
struct YAMLFileFormatterTests {

    // MARK: - Helper

    private func makeFormatter(
        runner: MockProcessRunner,
        toolPath: String? = "/usr/local/bin/prettier"
    ) -> YAMLFileFormatter {
        let external = ExternalFileFormatter(
            toolPath: toolPath,
            toolName: "prettier",
            extensions: ["yml", "yaml"],
            arguments: ["--parser", "yaml"],
            processRunner: runner.run
        )
        return YAMLFileFormatter(formatter: external)
    }

    // MARK: - Prettier found

    @Test("Prettier found — formats .yml files")
    func prettierFormatsYMLFiles() {
        let runner = MockProcessRunner(
            stdout: "apiVersion: v1\nkind: ConfigMap\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "apiVersion: v1\nkind:ConfigMap\n",
            url: URL(fileURLWithPath: "/project/config.yml")
        )
        #expect(result == "apiVersion: v1\nkind: ConfigMap\n")
    }

    @Test("Prettier found — formats .yaml files")
    func prettierFormatsYAMLFiles() {
        let runner = MockProcessRunner(
            stdout: "name: CI\non:\n  push:\n    branches:\n      - main\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "name: CI\non:\n  push:\n   branches:\n    - main\n",
            url: URL(fileURLWithPath: "/project/.github/workflows/ci.yaml")
        )
        #expect(result == "name: CI\non:\n  push:\n    branches:\n      - main\n")
    }

    // MARK: - Prettier not found

    @Test("Prettier not found — returns original content (no-op formatter)")
    func prettierNotFoundReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "should not appear", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner, toolPath: nil)

        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/config.yml")))

        let result = formatter.format("key: value", url: URL(fileURLWithPath: "/project/config.yml"))
        #expect(result == "key: value")
    }

    // MARK: - Error handling

    @Test("Non-zero exit code — returns original content")
    func nonZeroExitReturnsOriginal() {
        let runner = MockProcessRunner(
            stdout: "partial output",
            stderr: "Error: Invalid YAML",
            exitCode: 1
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format("invalid: yaml: [", url: URL(fileURLWithPath: "/project/config.yml"))
        #expect(result == "invalid: yaml: [")
    }

    @Test("Timeout — returns original content")
    func timeoutReturnsOriginal() {
        let external = ExternalFileFormatter(
            toolPath: "/usr/local/bin/prettier",
            toolName: "prettier",
            extensions: ["yml", "yaml"],
            arguments: ["--parser", "yaml"],
            processRunner: MockProcessRunner(
                stdout: "", stderr: "", exitCode: 0, simulateTimeout: true
            ).run,
            timeout: 0.1
        )
        let formatter = YAMLFileFormatter(formatter: external)
        let result = formatter.format("key: value", url: URL(fileURLWithPath: "/project/config.yml"))
        #expect(result == "key: value")
    }

    @Test("Empty stdout — returns original content")
    func emptyStdoutReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format("key: value", url: URL(fileURLWithPath: "/project/config.yml"))
        #expect(result == "key: value")
    }

    // MARK: - Extension handling

    @Test("Case-insensitive extensions — .YML and .YAML are formatted")
    func caseInsensitiveExtensions() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/CONFIG.YML")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/workflow.YAML")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/mixed.Yml")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/deploy.YaMl")))
    }

    @Test("Non-YAML files are not formatted")
    func nonYAMLFilesIgnored() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/main.swift")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/config.json")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/main.tf")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/style.css")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/readme.md")))
    }

    // MARK: - Stdin piping

    @Test("File content is piped to the process via stdin")
    func stdinReceivesFileContent() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        _ = formatter.format("key: value\n", url: URL(fileURLWithPath: "/project/config.yml"))
        #expect(runner.lastStdinContent == "key: value\n")
    }

    // MARK: - Blocklist

    @Test("pnpm-lock.yaml is never reformatted")
    func pnpmLockSkipped() {
        let runner = MockProcessRunner(stdout: "reformatted lock", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "lockfileVersion: '6.0'\n",
            url: URL(fileURLWithPath: "/project/pnpm-lock.yaml")
        )
        #expect(result == "lockfileVersion: '6.0'\n")
        #expect(runner.lastStdinContent == nil)
    }

    @Test("yarn.lock is never reformatted")
    func yarnLockSkipped() {
        let runner = MockProcessRunner(stdout: "reformatted lock", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "# yarn lockfile\n",
            url: URL(fileURLWithPath: "/project/yarn.lock")
        )
        #expect(result == "# yarn lockfile\n")
    }

    @Test("Gemfile.lock is never reformatted")
    func gemfileLockSkipped() {
        let runner = MockProcessRunner(stdout: "reformatted lock", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "GEM\n  remote: https://rubygems.org/\n",
            url: URL(fileURLWithPath: "/project/Gemfile.lock")
        )
        #expect(result == "GEM\n  remote: https://rubygems.org/\n")
    }

    @Test("Cargo.lock is never reformatted")
    func cargoLockSkipped() {
        let runner = MockProcessRunner(stdout: "reformatted lock", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "[[package]]\nname = \"serde\"\n",
            url: URL(fileURLWithPath: "/project/Cargo.lock")
        )
        #expect(result == "[[package]]\nname = \"serde\"\n")
    }

    @Test("Blocklist is case-insensitive")
    func blocklistCaseInsensitive() {
        let runner = MockProcessRunner(stdout: "reformatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "lockfileVersion: '6.0'\n",
            url: URL(fileURLWithPath: "/project/PNPM-LOCK.YAML")
        )
        #expect(result == "lockfileVersion: '6.0'\n")
    }

    // MARK: - Large files

    @Test("Files over 100KB are skipped")
    func largeFilesSkipped() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let largeContent = String(repeating: "key: value\n", count: 10_001)
        let result = formatter.format(
            largeContent,
            url: URL(fileURLWithPath: "/project/huge.yml")
        )
        #expect(result == largeContent)
        #expect(runner.lastStdinContent == nil)
    }

    @Test("Files just under 100KB are formatted")
    func filesUnderLimitAreFormatted() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let content = "key: value\n"
        #expect(content.utf8.count < 100_000)
        let result = formatter.format(content, url: URL(fileURLWithPath: "/project/config.yml"))
        #expect(result == "formatted")
    }

    // MARK: - Resolve priority

    @Test("YAMLFileFormatter.resolve uses prettier when available")
    func resolveUsesPrettierWhenAvailable() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let prettierPath = tempDir.appendingPathComponent("prettier")
        FileManager.default.createFile(atPath: prettierPath.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: prettierPath.path
        )

        let resolver = ExternalToolResolver(searchDirectories: [tempDir.path])
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = YAMLFileFormatter.resolve(processRunner: runner.run, resolver: resolver)

        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/config.yml")))
        let result = formatter.format("key: value", url: URL(fileURLWithPath: "/project/config.yml"))
        #expect(result == "formatted")
    }

    @Test("YAMLFileFormatter.resolve is no-op when prettier is missing")
    func resolveNoOpWhenPrettierMissing() {
        let resolver = ExternalToolResolver(searchDirectories: [])
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = YAMLFileFormatter.resolve(processRunner: runner.run, resolver: resolver)

        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/config.yml")))
    }

    // MARK: - Main-thread safety

    @Test("format() can be called from the main thread without crashing")
    @MainActor
    func formatFromMainThreadDoesNotCrash() {
        let runner = MockProcessRunner(
            stdout: "key: value\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "key:value\n",
            url: URL(fileURLWithPath: "/project/config.yml")
        )
        #expect(result == "key: value\n")
    }

    // MARK: - Registry integration

    @Test("YAML formatter coexists with JSON and HCL formatters in registry")
    func registryIntegration() {
        let runner = MockProcessRunner(stdout: "yaml-formatted", stderr: "", exitCode: 0)
        let yamlFormatter = makeFormatter(runner: runner)
        let hclFormatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/terraform",
            toolName: "terraform",
            extensions: ["tf"],
            arguments: ["fmt", "-"],
            processRunner: runner.run
        )
        let registry = FileFormatterRegistry(formatters: [
            JSONFileFormatter(),
            hclFormatter,
            yamlFormatter
        ])

        // .yml file — YAML formatter
        let ymlResult = registry.format(
            content: "key: value",
            url: URL(fileURLWithPath: "/project/config.yml")
        )
        #expect(ymlResult == "yaml-formatted")

        // .yaml file — YAML formatter
        let yamlResult = registry.format(
            content: "name: test",
            url: URL(fileURLWithPath: "/project/workflow.yaml")
        )
        #expect(yamlResult == "yaml-formatted")

        // .tf file — HCL formatter
        let tfResult = registry.format(
            content: "resource {}",
            url: URL(fileURLWithPath: "/project/main.tf")
        )
        #expect(tfResult == "yaml-formatted")

        // .json file — JSON formatter
        let jsonResult = registry.format(
            content: #"{"key":"value"}"#,
            url: URL(fileURLWithPath: "/project/config.json")
        )
        #expect(jsonResult.contains("\"key\""))

        // .swift file — no formatter
        let swiftResult = registry.format(
            content: "let x = 1",
            url: URL(fileURLWithPath: "/project/main.swift")
        )
        #expect(swiftResult == "let x = 1")
    }
}
