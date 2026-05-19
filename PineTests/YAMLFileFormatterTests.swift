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
        toolPath: String? = "/usr/local/bin/prettier",
        toolName: String = "prettier"
    ) -> ExternalFileFormatter {
        ExternalFileFormatter(
            toolPath: toolPath,
            toolName: toolName,
            extensions: ["yml", "yaml"],
            arguments: ["--parser", "yaml"],
            processRunner: runner.run
        )
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

        #expect(formatter.toolPath == nil)
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
        let runner = MockProcessRunner(stdout: "", stderr: "", exitCode: 0, simulateTimeout: true)
        let formatter = ExternalFileFormatter(
            toolPath: "/usr/local/bin/prettier",
            toolName: "prettier",
            extensions: ["yml", "yaml"],
            arguments: ["--parser", "yaml"],
            processRunner: runner.run,
            timeout: 0.1
        )
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

        #expect(formatter.toolName == "prettier")
        #expect(formatter.toolPath == prettierPath.path)
    }

    @Test("YAMLFileFormatter.resolve is no-op when prettier is missing")
    func resolveNoOpWhenPrettierMissing() {
        let resolver = ExternalToolResolver(searchDirectories: [])
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = YAMLFileFormatter.resolve(processRunner: runner.run, resolver: resolver)

        #expect(formatter.toolPath == nil)
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
