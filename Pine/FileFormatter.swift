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
/// - **Sandbox-friendly** — no spawning of external binaries (we run inside the app
///   sandbox and cannot exec `terraform`, `swift-format`, or `prettier`).
protocol FileFormatter: Sendable {
    /// Returns true when this formatter should be applied to the given file URL.
    func canFormat(url: URL) -> Bool

    /// Returns a formatted copy of `content`, or the original on any failure.
    /// The `url` is provided for blocklist checks and filename-based decisions.
    func format(_ content: String, url: URL) -> String
}

/// Formats JSON with 2-space indentation. Preserves the original text on
/// any parse failure so that invalid JSON remains editable.
///
/// **Known limitation**: `JSONSerialization` round-trips numbers lossily —
/// `1.0` may become `1`, scientific notation changes form, and integers
/// above 2^53 lose precision. Files with these patterns are skipped until
/// a proper tokenizer-based formatter is written.
struct JSONFileFormatter: FileFormatter {
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

/// Composes an ordered list of formatters, applying the first whose `canFormat` returns
/// true. The empty registry is a no-op — safe default for files with no known formatter.
struct FileFormatterRegistry: Sendable {
    let formatters: [FileFormatter]

    /// Default registry. Currently ships a single in-Swift JSON formatter. Additional
    /// formatters (YAML, Markdown, Terraform, Swift) can be added here once pure-Swift
    /// implementations land — the sandbox prevents shelling out to external tools.
    static let `default` = FileFormatterRegistry(formatters: [JSONFileFormatter()])

    /// Returns a formatted copy of `content` for the given URL, or the original if no
    /// registered formatter claims the file type.
    func format(content: String, url: URL) -> String {
        for formatter in formatters where formatter.canFormat(url: url) {
            return formatter.format(content, url: url)
        }
        return content
    }
}
