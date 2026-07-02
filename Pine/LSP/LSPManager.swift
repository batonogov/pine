//
//  LSPManager.swift
//  Pine
//
//  Phase 1 of LSP support (issue #1010, parent #994).
//
//  Owns the per-language `LSPClient` instances and the aggregated
//  diagnostics store. The single `@MainActor @Observable` surface that the
//  editor and Problems panel observe.
//
//  Responsibilities:
//    • Lazy-spawn a language server the first time a matching file is opened.
//    • Forward `textDocument/didOpen|didChange|didClose` to the right client.
//    • Collect `publishDiagnostics` from every client into a per-URI store.
//    • Graceful no-op when a server binary is missing (no crash, no hang).
//    • `shutdownAll()` on project close / app termination — leaves no orphan.
//

import Foundation
import SwiftUI
import os

/// `@MainActor @Observable` manager for all language-server connections in
/// one project. Owned by `ProjectManager`.
///
/// Mirrors the existing `ConfigValidator` shape: the editor reads
/// `diagnostics(for:)` and renders them through the same gutter-icon path
/// that config validators already use.
@MainActor
@Observable
final class LSPManager {

    /// Per-client state for each active language server.
    struct ServerEntry: Identifiable {
        let id: String // == language id
        let language: String
        var client: LSPClient
        var state: LSPClient.State
    }

    /// Active language-server clients, keyed by language id.
    private(set) var servers: [String: ServerEntry] = [:]

    /// All current diagnostics keyed by document URI.
    /// Replacing/emptying an entry clears that file's markers.
    private(set) var diagnosticsByURI: [String: [ValidationDiagnostic]] = [:]

    /// Raw LSP diagnostics keyed by URI, retained for code-action context.
    /// These are the original `LSPDiagnostic` structs (0-based LSP positions)
    /// needed when building the `CodeActionContext.diagnostics` array.
    private var rawDiagnosticsByURI: [String: [LSPDiagnostic]] = [:]

    /// Whether LSP diagnostics are enabled (global toggle). Defaults on.
    var enabled: Bool = true

    /// The workspace root URI (file://...) used for `initialize`.
    private var rootURI: String?

    /// Injected resolver — overridable for tests.
    private let resolver: LanguageServerResolver

    /// Injectable factory for clients — overridable for tests so a real
    /// `Process` is never spawned in unit tests.
    private let clientFactory: (String) -> LSPClient

    init(
        resolver: LanguageServerResolver = .defaultResolver,
        clientFactory: @escaping (String) -> LSPClient = { LSPClient(language: $0) }
    ) {
        self.resolver = resolver
        self.clientFactory = clientFactory
    }

    // MARK: - Workspace lifecycle

    /// Sets the workspace root so `initialize` requests pass the right `rootUri`.
    func setWorkspaceRoot(_ url: URL?) {
        rootURI = url.map { $0.absoluteString }
    }

    /// Shuts down every running server. Called on project close and app
    /// termination so no orphan language-server processes survive.
    func shutdownAll() {
        for entry in servers.values {
            entry.client.shutdown()
        }
        servers.removeAll()
        // Keep diagnosticsByURI intact across a shutdown? No — when the
        // project closes the manager is discarded anyway. Clear to be safe.
        diagnosticsByURI = [:]
    }

    // MARK: - Document sync

    /// Notifies the appropriate language server that a document was opened.
    /// Lazily spawns the server for the file's language on first use.
    /// No-op when LSP is disabled, the file has no configured server, or the
    /// server binary is not installed.
    func didOpen(url: URL, version: Int = 1, text: String) {
        guard enabled else { return }
        guard let serverConfig = LanguageServerRegistry.server(for: url) else { return }

        let language = serverConfig.language
        Task {
            guard await ensureServer(for: serverConfig) else { return }
            let uri = url.absoluteString
            servers[language]?.client.didOpen(
                uri: uri,
                language: language,
                version: version,
                text: text
            )
        }
    }

    /// Notifies the appropriate language server that a document changed.
    func didChange(url: URL, text: String) {
        guard enabled else { return }
        // Resolve via URL extension so a .ts file reaches the typescript server, etc.
        guard let serverConfig = LanguageServerRegistry.server(for: url) else { return }
        let uri = url.absoluteString
        servers[serverConfig.language]?.client.didChange(uri: uri, text: text)
    }

    /// Notifies the appropriate language server that a document was closed.
    func didClose(url: URL) {
        guard enabled else { return }
        guard let serverConfig = LanguageServerRegistry.server(for: url) else { return }
        let uri = url.absoluteString
        servers[serverConfig.language]?.client.didClose(uri: uri)
        // Clear that file's diagnostics immediately so stale markers don't linger.
        diagnosticsByURI[uri] = nil
        rawDiagnosticsByURI[uri] = nil
    }

    // MARK: - Phase 2 queries (hover + definition)

    /// Requests hover info for the symbol at `offset` (UTF-16 code units,
    /// matching `NSString`/`NSTextView`) in the file at `url`. Returns `nil`
    /// when LSP is disabled, the file has no configured server, or the server
    /// reports no hover for this position.
    func hover(url: URL, offset: Int, text: String) async -> LSPHover? {
        guard enabled else { return nil }
        guard let serverConfig = LanguageServerRegistry.server(for: url) else { return nil }
        let language = serverConfig.language
        // Ensure the server is up. A read-only hover should never spawn a
        // server that wasn't already needed — but if the file is open (it is,
        // since the editor is showing it) the server was spawned on didOpen.
        guard await ensureServer(for: serverConfig) else { return nil }
        guard servers[language]?.state == .initialized else { return nil }
        let uri = url.absoluteString
        let position = LSPPositionConverter.lspPosition(utf16Offset: offset, in: text)
        return await servers[language]?.client.hover(uri: uri, position: position)
    }

    /// Requests go-to-definition for the symbol at `offset` in the file at
    /// `url`. Returns `.empty` when LSP is disabled, the file has no server,
    /// or the server reports no definition.
    func definition(url: URL, offset: Int, text: String) async -> LSPDefinitionResponse {
        guard enabled else { return .empty }
        guard let serverConfig = LanguageServerRegistry.server(for: url) else { return .empty }
        let language = serverConfig.language
        guard await ensureServer(for: serverConfig) else { return .empty }
        guard servers[language]?.state == .initialized else { return .empty }
        let uri = url.absoluteString
        let position = LSPPositionConverter.lspPosition(utf16Offset: offset, in: text)
        return await servers[language]?.client.definition(uri: uri, position: position) ?? .empty
    }

    // MARK: - Phase 3 queries (completion)

    /// The idle delay after the user stops typing before a completion request
    /// is sent, in milliseconds. Tuned to feel responsive without spamming the
    /// server on every keystroke.
    static let completionDebounceMillis: Int = 300

    /// Requests completion items for the position at `offset` in the file at
    /// `url`. Returns an empty list when LSP is disabled, the file has no
    /// server, or the server reports no completions.
    ///
    /// The caller is responsible for debouncing (see
    /// `completionDebounceMillis`) and for filtering/ranking the returned
    /// items against the current word prefix.
    func completion(url: URL, offset: Int, text: String) async -> LSPCompletionList {
        guard enabled else { return LSPCompletionList(items: []) }
        guard let serverConfig = LanguageServerRegistry.server(for: url) else {
            return LSPCompletionList(items: [])
        }
        let language = serverConfig.language
        guard await ensureServer(for: serverConfig) else { return LSPCompletionList(items: []) }
        guard servers[language]?.state == .initialized else { return LSPCompletionList(items: []) }
        let uri = url.absoluteString
        let position = LSPPositionConverter.lspPosition(utf16Offset: offset, in: text)
        return await servers[language]?.client.completion(uri: uri, position: position)
            ?? LSPCompletionList(items: [])
    }

    // MARK: - Phase 4 queries (code action + rename)

    /// Requests code actions for the symbol at `offset` in the file at `url`.
    /// Returns an empty response when LSP is disabled, the file has no server,
    /// or the server reports no actions.
    func codeAction(url: URL, offset: Int, text: String) async -> LSPCodeActionResponse {
        guard enabled else { return LSPCodeActionResponse(actions: []) }
        guard let serverConfig = LanguageServerRegistry.server(for: url) else {
            return LSPCodeActionResponse(actions: [])
        }
        let language = serverConfig.language
        guard await ensureServer(for: serverConfig) else {
            return LSPCodeActionResponse(actions: [])
        }
        guard servers[language]?.state == .initialized else {
            return LSPCodeActionResponse(actions: [])
        }
        let uri = url.absoluteString
        let position = LSPPositionConverter.lspPosition(utf16Offset: offset, in: text)
        // Build a range from the word at the cursor (or a zero-length range).
        let range = wordRange(at: offset, in: text) ?? LSPRange(start: position, end: position)
        // Gather diagnostics for this file so the server can target fixes.
        let lspDiagnostics = lspDiagnosticsForApply(uri: uri)
        return await servers[language]?.client.codeAction(uri: uri, range: range, diagnostics: lspDiagnostics)
            ?? LSPCodeActionResponse(actions: [])
    }

    /// Requests a project-wide rename for the symbol at `offset` in the file
    /// at `url`. Returns the `WorkspaceEdit` describing all changes, or an
    /// empty edit when LSP is disabled or the server reports no targets.
    func rename(url: URL, offset: Int, text: String, newName: String) async -> LSPWorkspaceEdit {
        guard enabled else { return LSPWorkspaceEdit(operatedFiles: []) }
        guard let serverConfig = LanguageServerRegistry.server(for: url) else {
            return LSPWorkspaceEdit(operatedFiles: [])
        }
        let language = serverConfig.language
        guard await ensureServer(for: serverConfig) else {
            return LSPWorkspaceEdit(operatedFiles: [])
        }
        guard servers[language]?.state == .initialized else {
            return LSPWorkspaceEdit(operatedFiles: [])
        }
        let uri = url.absoluteString
        let position = LSPPositionConverter.lspPosition(utf16Offset: offset, in: text)
        return await servers[language]?.client.rename(uri: uri, position: position, newName: newName)
            ?? LSPWorkspaceEdit(operatedFiles: [])
    }

    // MARK: - WorkspaceEdit application

    /// Applies a `WorkspaceEdit` transactionally across open tabs.
    ///
    /// For each `.edit` operation:
    ///   1. If the file is open in any tab, applies the edits to the tab
    ///      content in memory (marking it dirty for save).
    ///   2. If the file is not open, reads it from disk, applies the edits,
    ///      and writes back.
    ///
    /// If any file's edit fails to apply, no partial state is committed and
    /// the method returns `false`.
    ///
    /// - Parameters:
    ///   - workspaceEdit: The edit to apply.
    ///   - tabManager: The active project's tab manager (for in-memory edits).
    ///   - workspaceURL: The project root URL (for resolving relative paths).
    /// - Returns: `true` when all edits were applied successfully.
    func applyWorkspaceEdit(
        _ workspaceEdit: LSPWorkspaceEdit,
        tabManager: TabManager,
        workspaceURL: URL?
    ) -> Bool {
        guard !workspaceEdit.isEmpty else { return true }

        // Phase 1: compute all new texts without committing any changes.
        // This ensures the operation is transactional — if any file fails,
        // nothing is modified.
        var pendingChanges: [(tabIndex: Int, newText: String, fileURL: URL)] = []
        var diskWrites: [(url: URL, newText: String)] = []

        for operated in workspaceEdit.operatedFiles where operated.kind == .edit {
            guard let fileURL = operated.url else { continue }
            guard !operated.edits.isEmpty else { continue }

            // Check if this file is open in a tab.
            if let tabIndex = tabManager.tabs.firstIndex(where: { $0.url == fileURL }) {
                let original = tabManager.tabs[tabIndex].content
                let result = WorkspaceEditApplier.applyEdits(operated.edits, to: original)
                guard result.success, let newText = result.newText else {
                    Logger.lsp.error("WorkspaceEdit apply failed for \(fileURL.lastPathComponent, privacy: .public): \(result.errorMessage ?? "unknown", privacy: .public)")
                    return false
                }
                pendingChanges.append((tabIndex: tabIndex, newText: newText, fileURL: fileURL))
            } else {
                // File not open — read from disk, apply, write back.
                guard let original = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    Logger.lsp.error("WorkspaceEdit: cannot read file \(fileURL.lastPathComponent, privacy: .public)")
                    return false
                }
                let result = WorkspaceEditApplier.applyEdits(operated.edits, to: original)
                guard result.success, let newText = result.newText else {
                    Logger.lsp.error("WorkspaceEdit apply failed for \(fileURL.lastPathComponent, privacy: .public): \(result.errorMessage ?? "unknown", privacy: .public)")
                    return false
                }
                diskWrites.append((url: fileURL, newText: newText))
            }
        }

        // Phase 2: commit all changes.
        for change in pendingChanges {
            // Use the tab's direct content update — the edit is already computed.
            tabManager.applyExternalEdit(at: change.tabIndex, newText: change.newText)
            // Notify the LSP server of the change.
            didChange(url: change.fileURL, text: change.newText)
        }

        for write in diskWrites {
            do {
                try write.newText.write(to: write.url, atomically: true, encoding: .utf8)
            } catch {
                Logger.lsp.error("WorkspaceEdit: cannot write file \(write.url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                return false
            }
        }

        Logger.lsp.info("WorkspaceEdit applied: \(pendingChanges.count, privacy: .public) tab(s), \(diskWrites.count, privacy: .public) disk file(s)")
        return true
    }

    // MARK: - Diagnostics access

    /// Returns the current Pine diagnostics for a document URI.
    func diagnostics(for uri: String) -> [ValidationDiagnostic] {
        diagnosticsByURI[uri] ?? []
    }

    /// Returns the diagnostics for a file URL.
    func diagnostics(for url: URL) -> [ValidationDiagnostic] {
        diagnostics(for: url.absoluteString)
    }

    /// All diagnostics across every open document, grouped by URI. Used by
    /// the Problems panel.
    var allDiagnostics: [(uri: String, diagnostics: [ValidationDiagnostic])] {
        diagnosticsByURI
            .filter { !$0.value.isEmpty }
            .map { (uri: $0.key, diagnostics: $0.value) }
            .sorted { $0.uri < $1.uri }
    }

    /// Total number of diagnostics across all files.
    var totalDiagnosticCount: Int {
        diagnosticsByURI.values.reduce(0) { $0 + $1.count }
    }

    /// Count of errors across all files.
    var errorCount: Int {
        diagnosticsByURI.values.flatMap { $0 }.filter { $0.severity == .error }.count
    }

    /// Count of warnings across all files.
    var warningCount: Int {
        diagnosticsByURI.values.flatMap { $0 }.filter { $0.severity == .warning }.count
    }

    // MARK: - Server lifecycle (internal)

    /// Ensures a server for the given config is running. Spawns it (and runs
    /// the `initialize` handshake) if it isn't. Returns `false` if the server
    /// binary is missing or the handshake failed.
    private func ensureServer(for config: LanguageServerConfig) async -> Bool {
        // Already have an entry for this language?
        if let existing = servers[config.language] {
            return existing.state == .initialized
        }

        // Discover the binary — graceful no-op when absent.
        guard let path = resolver.resolvePath(for: config) else {
            Logger.lsp.info("Server binary not installed for \(config.language, privacy: .public): \(config.command, privacy: .public)")
            return false
        }

        let client = clientFactory(config.language)
        let entry = ServerEntry(id: config.language, language: config.language, client: client, state: .uninitialized)
        servers[config.language] = entry

        // Wire diagnostics callback before starting so nothing is lost.
        client.onDiagnostics = { [weak self, weak client] notification in
            guard let self else { return }
            self.handleDiagnostics(notification, from: client)
        }

        let started = await client.start(
            command: path,
            arguments: config.arguments,
            rootURI: rootURI
        )

        if started {
            servers[config.language]?.state = .initialized
            Logger.lsp.info("LSP server ready for \(config.language, privacy: .public)")
        } else {
            servers[config.language]?.state = .failed
            Logger.lsp.error("LSP server failed to start for \(config.language, privacy: .public)")
        }
        return started
    }

    /// Receives a `publishDiagnostics` notification and merges it into the store.
    private func handleDiagnostics(_ notification: LSPDiagnosticsNotification, from client: LSPClient?) {
        let mapped = DiagnosticMapper.map(notification)
        diagnosticsByURI[notification.uri] = mapped
        rawDiagnosticsByURI[notification.uri] = notification.diagnostics
    }

    // MARK: - Phase 4 helpers

    /// Extracts the word range at `offset` for the code action context, or
    /// `nil` when the cursor is not on a word.
    private func wordRange(at offset: Int, in text: String) -> LSPRange? {
        let ns = text as NSString
        let clamped = min(max(0, offset), ns.length)

        // Scan backwards for word start.
        var start = clamped
        while start > 0 {
            let unit = ns.character(at: start - 1)
            guard let scalar = Unicode.Scalar(unit) else { break }
            let char = Character(scalar)
            if char.isLetter || char.isNumber || char == "_" {
                start -= 1
            } else {
                break
            }
        }

        // Scan forwards for word end.
        var end = clamped
        while end < ns.length {
            let unit = ns.character(at: end)
            guard let scalar = Unicode.Scalar(unit) else { break }
            let char = Character(scalar)
            if char.isLetter || char.isNumber || char == "_" {
                end += 1
            } else {
                break
            }
        }

        guard end > start else { return nil }
        let startPos = LSPPositionConverter.lspPosition(utf16Offset: start, in: text)
        let endPos = LSPPositionConverter.lspPosition(utf16Offset: end, in: text)
        return LSPRange(start: startPos, end: endPos)
    }

    /// Returns the raw `LSPDiagnostic` values for a URI, needed for the code
    /// action request context. These are the original structs with 0-based LSP
    /// positions, retained alongside the mapped Pine diagnostics.
    private func lspDiagnosticsForApply(uri: String) -> [LSPDiagnostic] {
        rawDiagnosticsByURI[uri] ?? []
    }
}
