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
    }
}
