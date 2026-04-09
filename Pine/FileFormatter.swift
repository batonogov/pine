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
    func format(_ content: String) -> String
}

/// Formats JSON with 2-space indentation and sorted keys. Preserves the original text on
/// any parse failure so that invalid JSON remains editable.
struct JSONFileFormatter: FileFormatter {
    func canFormat(url: URL) -> Bool {
        url.pathExtension.lowercased() == "json"
    }

    func format(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return content }
        guard let data = trimmed.data(using: .utf8) else { return content }
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            return content
        }
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        ) else {
            return content
        }
        guard let string = String(data: pretty, encoding: .utf8) else { return content }
        // JSONSerialization uses 2-space indentation by default on Apple platforms, which
        // matches the Pine convention. Do not append a trailing newline — that is the job
        // of `ensuringTrailingNewline()` in the save pipeline so we avoid double-adding.
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
            return formatter.format(content)
        }
        return content
    }
}
