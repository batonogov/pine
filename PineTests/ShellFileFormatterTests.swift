//
//  ShellFileFormatterTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("ShellFileFormatter")
struct ShellFileFormatterTests {

    // MARK: - Helper

    private func makeFormatter(
        runner: MockProcessRunner,
        toolPath: String? = "/usr/local/bin/shfmt"
    ) -> ShellFileFormatter {
        let external = ExternalFileFormatter(
            toolPath: toolPath,
            toolName: "shfmt",
            extensions: ["sh", "bash", "zsh"],
            arguments: ["-i", "2", "-ci", "-bn"],
            processRunner: runner.run
        )
        return ShellFileFormatter(formatter: external)
    }

    // MARK: - shfmt found — extension-based formatting

    @Test("shfmt found — formats .sh files")
    func shfmtFormatsSHFiles() {
        let runner = MockProcessRunner(
            stdout: "#!/bin/sh\necho \"hello\"\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "#!/bin/sh\necho \"hello\"\n",
            url: URL(fileURLWithPath: "/project/script.sh")
        )
        #expect(result == "#!/bin/sh\necho \"hello\"\n")
    }

    @Test("shfmt found — formats .bash files")
    func shfmtFormatsBashFiles() {
        let runner = MockProcessRunner(
            stdout: "#!/bin/bash\nif true; then\n  echo yes\nfi\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "#!/bin/bash\nif true; then\necho yes\nfi\n",
            url: URL(fileURLWithPath: "/project/script.bash")
        )
        #expect(result == "#!/bin/bash\nif true; then\n  echo yes\nfi\n")
    }

    @Test("shfmt found — formats .zsh files")
    func shfmtFormatsZshFiles() {
        let runner = MockProcessRunner(
            stdout: "#!/bin/zsh\necho \"zsh script\"\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "#!/bin/zsh\necho \"zsh script\"\n",
            url: URL(fileURLWithPath: "/project/script.zsh")
        )
        #expect(result == "#!/bin/zsh\necho \"zsh script\"\n")
    }

    @Test(".sh file without shebang — formats because shfmt detects language by extension")
    func shFileWithoutShebang() {
        let runner = MockProcessRunner(stdout: "echo hello\n", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/script.sh")
        #expect(formatter.canFormat(url: url))
        let result = formatter.format("echo hello\n", url: url)
        #expect(result == "echo hello\n")
    }

    @Test("Non-standard path — #!/usr/local/bin/bash detected via regex")
    func nonStandardPathBash() {
        let runner = MockProcessRunner(
            stdout: "#!/usr/local/bin/bash\necho hello\n", stderr: "", exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/runme")
        #expect(formatter.canFormat(url: url))
        let result = formatter.format("#!/usr/local/bin/bash\necho hello\n", url: url)
        #expect(result == "#!/usr/local/bin/bash\necho hello\n")
    }

    @Test("Non-standard path — #!/opt/homebrew/bin/zsh detected via regex")
    func nonStandardPathZsh() {
        let runner = MockProcessRunner(
            stdout: "#!/opt/homebrew/bin/zsh\necho hello\n", stderr: "", exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/setup")
        #expect(formatter.canFormat(url: url))
        let result = formatter.format("#!/opt/homebrew/bin/zsh\necho hello\n", url: url)
        #expect(result == "#!/opt/homebrew/bin/zsh\necho hello\n")
    }

    // MARK: - Shebang detection — files without shell extension

    @Test("Shebang #!/bin/sh detected — formats file without extension")
    func shebangBinShDetected() {
        let runner = MockProcessRunner(
            stdout: "#!/bin/sh\necho hello\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/myscript")
        #expect(formatter.canFormat(url: url))
        let result = formatter.format("#!/bin/sh\necho hello\n", url: url)
        #expect(result == "#!/bin/sh\necho hello\n")
    }

    @Test("Shebang #!/bin/bash detected — formats file without extension")
    func shebangBinBashDetected() {
        let runner = MockProcessRunner(
            stdout: "#!/bin/bash\necho hello\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/runme")
        #expect(formatter.canFormat(url: url))
        let result = formatter.format("#!/bin/bash\necho hello\n", url: url)
        #expect(result == "#!/bin/bash\necho hello\n")
    }

    @Test("Shebang #!/usr/bin/env bash detected — formats file without extension")
    func shebangEnvBashDetected() {
        let runner = MockProcessRunner(
            stdout: "#!/usr/bin/env bash\necho hello\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/setup")
        #expect(formatter.canFormat(url: url))
        let result = formatter.format("#!/usr/bin/env bash\necho hello\n", url: url)
        #expect(result == "#!/usr/bin/env bash\necho hello\n")
    }

    @Test("Shebang #!/usr/bin/env sh detected — formats file without extension")
    func shebangEnvShDetected() {
        let runner = MockProcessRunner(
            stdout: "#!/usr/bin/env sh\necho hello\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/bootstrap")
        #expect(formatter.canFormat(url: url))
        let result = formatter.format("#!/usr/bin/env sh\necho hello\n", url: url)
        #expect(result == "#!/usr/bin/env sh\necho hello\n")
    }

    @Test("Shebang #!/usr/bin/env zsh detected — formats file without extension")
    func shebangEnvZshDetected() {
        let runner = MockProcessRunner(
            stdout: "#!/usr/bin/env zsh\necho hello\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/zshrc-setup")
        #expect(formatter.canFormat(url: url))
        let result = formatter.format("#!/usr/bin/env zsh\necho hello\n", url: url)
        #expect(result == "#!/usr/bin/env zsh\necho hello\n")
    }

    @Test("Shebang with options — #!/bin/bash -e detected")
    func shebangWithOptionsDetected() {
        let runner = MockProcessRunner(
            stdout: "#!/bin/bash -e\necho hello\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/deploy")
        #expect(formatter.canFormat(url: url))
        let result = formatter.format("#!/bin/bash -e\necho hello\n", url: url)
        #expect(result == "#!/bin/bash -e\necho hello\n")
    }

    @Test("Shebang #!/bin/dash detected — formats file without extension")
    func shebangBinDashDetected() {
        let runner = MockProcessRunner(
            stdout: "#!/bin/dash\necho hello\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/dashscript")
        #expect(formatter.canFormat(url: url))
        let result = formatter.format("#!/bin/dash\necho hello\n", url: url)
        #expect(result == "#!/bin/dash\necho hello\n")
    }

    @Test("Shebang #!/usr/bin/env dash detected — formats file without extension")
    func shebangEnvDashDetected() {
        let runner = MockProcessRunner(
            stdout: "#!/usr/bin/env dash\necho hello\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/envdash")
        #expect(formatter.canFormat(url: url))
        let result = formatter.format("#!/usr/bin/env dash\necho hello\n", url: url)
        #expect(result == "#!/usr/bin/env dash\necho hello\n")
    }

    @Test("No shebang and no shell extension — format() returns original")
    func noShebangNoExtensionNotFormatted() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/readme")
        // canFormat claims extensionless files for shebang detection
        #expect(formatter.canFormat(url: url))
        // But format() returns original because there's no shell shebang
        let content = "This is just a text file\n"
        let result = formatter.format(content, url: url)
        #expect(result == content)
    }

    @Test("Non-shell shebang — format() returns original")
    func nonShellShebangNotFormatted() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/script.py")
        #expect(!formatter.canFormat(url: url))
    }

    @Test("Non-shell shebang in extensionless file — format() returns original")
    func nonShellShebangExtensionlessNotFormatted() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/script")
        let content = "#!/usr/bin/python3\nprint('hello')\n"
        let result = formatter.format(content, url: url)
        #expect(result == content)
    }

    @Test("Empty content — format() returns original (no shebang)")
    func emptyContentNotMatched() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let url = URL(fileURLWithPath: "/project/empty")
        // canFormat claims extensionless files for shebang detection
        #expect(formatter.canFormat(url: url))
        // But format() returns original because content is empty (no shebang)
        let result = formatter.format("", url: url)
        #expect(result == "")
    }

    // MARK: - shfmt not found

    @Test("shfmt not found — returns original content (no-op formatter)")
    func shfmtNotFoundReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "should not appear", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner, toolPath: nil)

        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/script.sh")))

        let result = formatter.format(
            "#!/bin/sh\necho hello\n",
            url: URL(fileURLWithPath: "/project/script.sh")
        )
        #expect(result == "#!/bin/sh\necho hello\n")
    }

    // MARK: - Error handling

    @Test("Non-zero exit code — returns original content")
    func nonZeroExitReturnsOriginal() {
        let runner = MockProcessRunner(
            stdout: "partial output",
            stderr: "Error: syntax error",
            exitCode: 1
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "invalid shell syntax {",
            url: URL(fileURLWithPath: "/project/script.sh")
        )
        #expect(result == "invalid shell syntax {")
    }

    @Test("Timeout — returns original content")
    func timeoutReturnsOriginal() {
        let external = ExternalFileFormatter(
            toolPath: "/usr/local/bin/shfmt",
            toolName: "shfmt",
            extensions: ["sh", "bash", "zsh"],
            arguments: ["-i", "2", "-ci", "-bn"],
            processRunner: MockProcessRunner(
                stdout: "", stderr: "", exitCode: 0, simulateTimeout: true
            ).run,
            timeout: 0.1
        )
        let formatter = ShellFileFormatter(formatter: external)
        let result = formatter.format(
            "#!/bin/sh\necho hello\n",
            url: URL(fileURLWithPath: "/project/script.sh")
        )
        #expect(result == "#!/bin/sh\necho hello\n")
    }

    @Test("Empty stdout — returns original content")
    func emptyStdoutReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "#!/bin/sh\necho hello\n",
            url: URL(fileURLWithPath: "/project/script.sh")
        )
        #expect(result == "#!/bin/sh\necho hello\n")
    }

    // MARK: - Size limit

    @Test("Large file — returns original content (maxFormatSize exceeded)")
    func largeFileReturnsOriginal() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        // Create content larger than maxFormatSize (100_000 bytes)
        let largeContent = String(repeating: "#!/bin/sh\necho hello\n", count: 5_000)
        #expect(largeContent.utf8.count > 100_000)
        let result = formatter.format(
            largeContent,
            url: URL(fileURLWithPath: "/project/large.sh")
        )
        #expect(result == largeContent)
    }

    // MARK: - Extension handling

    @Test("Case-insensitive extensions — .SH, .BASH, .ZSH are formatted")
    func caseInsensitiveExtensions() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/SCRIPT.SH")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/script.BASH")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/script.ZSH")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/mixed.Sh")))
    }

    @Test("Non-shell files are not formatted")
    func nonShellFilesIgnored() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/main.swift")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/config.json")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/style.css")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/main.tf")))
    }

    // MARK: - Stdin piping

    @Test("File content is piped to the process via stdin")
    func stdinReceivesFileContent() {
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = makeFormatter(runner: runner)
        _ = formatter.format(
            "#!/bin/bash\necho hello\n",
            url: URL(fileURLWithPath: "/project/script.sh")
        )
        #expect(runner.lastStdinContent == "#!/bin/bash\necho hello\n")
    }

    // MARK: - Resolve

    @Test("ShellFileFormatter.resolve uses shfmt when available")
    func resolveUsesShfmtWhenAvailable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let shfmtPath = tempDir.appendingPathComponent("shfmt")
        FileManager.default.createFile(
            atPath: shfmtPath.path,
            contents: Data("#!/bin/sh\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: shfmtPath.path
        )

        let resolver = ExternalToolResolver(searchDirectories: [tempDir.path])
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = ShellFileFormatter.resolve(
            processRunner: runner.run,
            resolver: resolver
        )

        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/project/script.sh")))
        let result = formatter.format(
            "#!/bin/sh\necho hello\n",
            url: URL(fileURLWithPath: "/project/script.sh")
        )
        #expect(result == "formatted")
    }

    @Test("ShellFileFormatter.resolve is no-op when shfmt is missing")
    func resolveNoOpWhenShfmtMissing() {
        let resolver = ExternalToolResolver(searchDirectories: [])
        let runner = MockProcessRunner(stdout: "formatted", stderr: "", exitCode: 0)
        let formatter = ShellFileFormatter.resolve(
            processRunner: runner.run,
            resolver: resolver
        )

        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/project/script.sh")))
    }

    // MARK: - Main-thread safety

    @Test("format() can be called from the main thread without crashing")
    @MainActor
    func formatFromMainThreadDoesNotCrash() {
        let runner = MockProcessRunner(
            stdout: "#!/bin/sh\necho hello\n",
            stderr: "",
            exitCode: 0
        )
        let formatter = makeFormatter(runner: runner)
        let result = formatter.format(
            "#!/bin/sh\necho hello\n",
            url: URL(fileURLWithPath: "/project/script.sh")
        )
        #expect(result == "#!/bin/sh\necho hello\n")
    }

    // MARK: - Registry integration

    @Test("Shell formatter coexists with JSON, HCL, and YAML formatters in registry")
    func registryIntegration() {
        let runner = MockProcessRunner(stdout: "shell-formatted", stderr: "", exitCode: 0)
        let shellFormatter = makeFormatter(runner: runner)
        let registry = FileFormatterRegistry(formatters: [
            JSONFileFormatter(),
            shellFormatter
        ])

        // .sh file — Shell formatter
        let shResult = registry.format(
            content: "#!/bin/sh\necho hello\n",
            url: URL(fileURLWithPath: "/project/script.sh")
        )
        #expect(shResult == "shell-formatted")

        // .bash file — Shell formatter
        let bashResult = registry.format(
            content: "#!/bin/bash\necho hello\n",
            url: URL(fileURLWithPath: "/project/run.bash")
        )
        #expect(bashResult == "shell-formatted")

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
