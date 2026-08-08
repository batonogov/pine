//
//  FileFormatter.swift
//  Pine
//

import Foundation

/// A language-aware content formatter that rewrites file contents before they are written
/// to disk. Formatters MUST be:
///
/// - **Pure and synchronous** — invoked on the main thread inside `TabManager.trySaveTab`.
/// - **Idempotent** — `format(format(x)) == format(x)`.
/// - **Safe on parse failure** — return the original string unchanged if the input cannot
///   be parsed, so save never blocks on malformed files.
/// - **Sandbox-friendly** — pure-Swift formatters should not spawn external binaries.
///   For external tools, use `ExternalFileFormatter` which handles Process lifecycle.
nonisolated protocol FileFormatter: Sendable {
    /// Returns true when this formatter should be applied to the given file URL.
    func canFormat(url: URL) -> Bool

    /// Returns a formatted copy of `content`, or the original on any failure.
    /// The `url` is provided for blocklist checks and filename-based decisions.
    func format(_ content: String, url: URL) -> String

    /// Deadline-aware variant used by application termination. Pure formatters
    /// inherit the synchronous default; external formatters override it so the
    /// child-process timeout never exceeds Quit's remaining shared budget.
    func format(
        _ content: String,
        url: URL,
        maximumDuration: TimeInterval
    ) -> String
}

nonisolated extension FileFormatter {
    func format(
        _ content: String,
        url: URL,
        maximumDuration: TimeInterval
    ) -> String {
        format(content, url: url)
    }
}

/// Formats JSON with 2-space indentation. Preserves the original text on
/// any parse failure so that invalid JSON remains editable.
///
/// **Known limitation**: `JSONSerialization` round-trips numbers lossily —
/// `1.0` may become `1`, scientific notation changes form, and integers
/// above 2^53 lose precision. Files with these patterns are skipped until
/// a proper tokenizer-based formatter is written.
nonisolated struct JSONFileFormatter: FileFormatter {
    /// Files that must never be reformatted because their key order carries
    /// semantic meaning (npm, TypeScript, Composer, VS Code workspaces).
    private static let blocklist: Set<String> = [
        "package.json", "package-lock.json",
        "tsconfig.json", "jsconfig.json",
        "composer.json", "composer.lock"
    ]

    /// Extensions that are also skipped (VS Code workspaces, etc.).
    private static let blockExtensions: Set<String> = ["code-workspace"]

    /// Maximum content size to format synchronously on the main thread.
    /// Larger files are left as-is to avoid blocking the UI.
    private static let maxFormatSize = 100_000

    func canFormat(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "json" || Self.blockExtensions.contains(ext) else { return false }
        // blocklisted files and extensions are claimed but format() returns
        // them unchanged — this prevents other formatters from touching them.
        return true
    }

    func format(_ content: String, url: URL) -> String {
        // Skip blocklisted filenames
        let filename = url.lastPathComponent.lowercased()
        if Self.blocklist.contains(filename) { return content }
        if Self.blockExtensions.contains(url.pathExtension.lowercased()) { return content }

        // Skip large files — main-thread budget
        guard content.utf8.count < Self.maxFormatSize else { return content }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return content }
        guard let data = trimmed.data(using: .utf8) else { return content }
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            return content
        }
        // Do NOT use .sortedKeys — it destroys the human-meaningful key
        // order in files like package.json (name → version → scripts).
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .fragmentsAllowed]
        ) else {
            return content
        }
        guard let string = String(data: pretty, encoding: .utf8) else { return content }
        return string
    }
}

/// Formats YAML via `prettier --parser yaml`. Skips lock files and large files
/// to avoid corrupting dependency trees or blocking the UI.
nonisolated struct YAMLFileFormatter: FileFormatter, Sendable {
    /// Lock files that must never be reformatted — reformatting changes
    /// content hashes and breaks dependency resolution.
    private static let blocklist: Set<String> = [
        "pnpm-lock.yaml", "yarn.lock",
        "gemfile.lock", "cargo.lock"
    ]

    /// Maximum content size to format synchronously on the main thread.
    /// Larger files are left as-is to avoid blocking the UI.
    private static let maxFormatSize = 100_000

    private let formatter: ExternalFileFormatter

    init(formatter: ExternalFileFormatter) {
        self.formatter = formatter
    }

    static func resolve(
        processRunner: @escaping ProcessRunner = runRealProcess,
        resolver: ExternalToolResolver = .fromEnvironment()
    ) -> YAMLFileFormatter {
        let extensions = ["yml", "yaml"]
        let arguments = ["--parser", "yaml"]

        let external: ExternalFileFormatter
        if let path = resolver.resolve(tool: "prettier") {
            external = ExternalFileFormatter(
                toolPath: path,
                toolName: "prettier",
                extensions: extensions,
                arguments: arguments,
                processRunner: processRunner
            )
        } else {
            external = ExternalFileFormatter(
                toolPath: nil,
                toolName: "prettier",
                extensions: extensions,
                arguments: arguments,
                processRunner: processRunner
            )
        }
        return YAMLFileFormatter(formatter: external)
    }

    func canFormat(url: URL) -> Bool {
        formatter.canFormat(url: url)
    }

    func format(_ content: String, url: URL) -> String {
        let filename = url.lastPathComponent.lowercased()
        if Self.blocklist.contains(filename) { return content }
        guard content.utf8.count < Self.maxFormatSize else { return content }
        return formatter.format(content, url: url)
    }

    func format(
        _ content: String,
        url: URL,
        maximumDuration: TimeInterval
    ) -> String {
        let filename = url.lastPathComponent.lowercased()
        if Self.blocklist.contains(filename) { return content }
        guard content.utf8.count < Self.maxFormatSize else { return content }
        return formatter.format(
            content,
            url: url,
            maximumDuration: maximumDuration
        )
    }
}

/// Creates an HCL formatter that delegates to `terraform fmt -` or `tofu fmt -`.
/// Prefers `terraform` when both are installed; gracefully no-ops when neither is found.
nonisolated enum HCLFileFormatter {
    static func resolve(
        processRunner: @escaping ProcessRunner = runRealProcess,
        resolver: ExternalToolResolver = .fromEnvironment()
    ) -> ExternalFileFormatter {
        let extensions = ["tf", "tfvars", "hcl"]
        let arguments = ["fmt", "-"]

        // Try terraform first, then OpenTofu
        for toolName in ["terraform", "tofu"] {
            if let path = resolver.resolve(tool: toolName) {
                return ExternalFileFormatter(
                    toolPath: path,
                    toolName: toolName,
                    extensions: extensions,
                    arguments: arguments,
                    processRunner: processRunner
                )
            }
        }

        // Neither found — no-op formatter
        return ExternalFileFormatter(
            toolPath: nil,
            toolName: "terraform",
            extensions: extensions,
            arguments: arguments,
            processRunner: processRunner
        )
    }
}

/// Formats shell scripts via `shfmt -i 2 -ci -bn`. Handles `.sh`, `.bash`, `.zsh` extensions
/// and detects shell shebangs (`#!/bin/sh`, `#!/bin/bash`, `#!/usr/bin/env bash`, etc.)
/// in extensionless files. Gracefully no-ops when `shfmt` is not installed.
nonisolated struct ShellFileFormatter: FileFormatter, Sendable {
    /// Shell file extensions (lowercase, without dot).
    private static let shellExtensions: Set<String> = ["sh", "bash", "zsh"]

    /// Maximum content size to format. Larger files are left as-is
    /// to avoid blocking the UI with an external process.
    private static let maxFormatSize = 100_000

    /// Pre-compiled regex for shell shebang detection.
    /// Matches lines like `#!/bin/sh`, `#!/bin/bash -e`, `#!/usr/bin/env bash`.
    private static let shellShebangRegex: NSRegularExpression = {
        let interpreters = [
            "/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash",
            "/usr/bin/env sh", "/usr/bin/env bash", "/usr/bin/env zsh", "/usr/bin/env dash"
        ]
        let alt = interpreters.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "^#!.*(" + alt + ")(\\s|$)"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern)
    }()

    private let formatter: ExternalFileFormatter

    init(formatter: ExternalFileFormatter) {
        self.formatter = formatter
    }

    static func resolve(
        processRunner: @escaping ProcessRunner = runRealProcess,
        resolver: ExternalToolResolver = .fromEnvironment()
    ) -> ShellFileFormatter {
        let extensions = ["sh", "bash", "zsh"]
        let arguments = ["-i", "2", "-ci", "-bn"]

        let external: ExternalFileFormatter
        if let path = resolver.resolve(tool: "shfmt") {
            external = ExternalFileFormatter(
                toolPath: path,
                toolName: "shfmt",
                extensions: extensions,
                arguments: arguments,
                processRunner: processRunner
            )
        } else {
            external = ExternalFileFormatter(
                toolPath: nil,
                toolName: "shfmt",
                extensions: extensions,
                arguments: arguments,
                processRunner: processRunner
            )
        }
        return ShellFileFormatter(formatter: external)
    }

    func canFormat(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        // Files with shell extensions
        if Self.shellExtensions.contains(ext) {
            return formatter.toolPath != nil
        }
        // Extensionless files — claim when shfmt is available for shebang detection in format()
        if ext.isEmpty {
            return formatter.toolPath != nil
        }
        return false
    }

    func format(_ content: String, url: URL) -> String {
        guard content.utf8.count < Self.maxFormatSize else { return content }

        let ext = url.pathExtension.lowercased()

        // For extensionless files, verify shell shebang before formatting
        if ext.isEmpty {
            guard hasShellShebang(content) else {
                return content
            }
        }

        return formatter.format(content, url: url)
    }

    func format(
        _ content: String,
        url: URL,
        maximumDuration: TimeInterval
    ) -> String {
        guard content.utf8.count < Self.maxFormatSize else { return content }

        let ext = url.pathExtension.lowercased()
        if ext.isEmpty, !hasShellShebang(content) {
            return content
        }
        return formatter.format(
            content,
            url: url,
            maximumDuration: maximumDuration
        )
    }

    /// Checks whether the content starts with a shell shebang line.
    private func hasShellShebang(_ content: String) -> Bool {
        guard content.hasPrefix("#!") else { return false }
        guard let firstLine = content.split(separator: "\n", maxSplits: 1).first else {
            return false
        }
        let range = NSRange(firstLine.startIndex..., in: firstLine)
        return Self.shellShebangRegex.firstMatch(in: String(firstLine), range: range) != nil
    }
}

/// Composes an ordered list of formatters, applying the first whose `canFormat` returns
/// true. The empty registry is a no-op — safe default for files with no known formatter.
nonisolated struct FileFormatterRegistry: Sendable {
    let formatters: [FileFormatter]

    /// Default registry. Ships a pure-Swift JSON formatter. External tool formatters
    /// (e.g. `ExternalFileFormatter` for terraform, shfmt, prettier) can be appended
    /// by consumers — they participate in the same first-match dispatch.
    /// ShellFileFormatter is listed last so it doesn't intercept extensionless files
    /// before other formatters get a chance.
    static let `default` = FileFormatterRegistry(formatters: [
        JSONFileFormatter(),
        HCLFileFormatter.resolve(),
        YAMLFileFormatter.resolve(),
        ShellFileFormatter.resolve()
    ])

    /// Returns a formatted copy of `content` for the given URL, or the original if no
    /// registered formatter claims the file type.
    func format(content: String, url: URL) -> String {
        for formatter in formatters where formatter.canFormat(url: url) {
            return formatter.format(content, url: url)
        }
        return content
    }

    func format(
        content: String,
        url: URL,
        maximumDuration: TimeInterval
    ) -> String {
        for formatter in formatters where formatter.canFormat(url: url) {
            return formatter.format(
                content,
                url: url,
                maximumDuration: maximumDuration
            )
        }
        return content
    }
}
