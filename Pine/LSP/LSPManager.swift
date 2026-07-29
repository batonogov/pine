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

    private struct OpenDocument {
        let url: URL
        let version: Int
        let text: String
        let ownerID: UUID
        let contentRevision: UInt64
    }

    private struct DocumentOwnerBuffer {
        let ownerID: UUID
        let text: String
        let contentRevision: UInt64
    }

    /// Per-client state for each active language server.
    struct ServerEntry: Identifiable {
        let id: String // == language id
        let language: String
        var client: any LSPClientProtocol
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

    /// Diagnostics bound to the exact current editor revision. A supplied LSP
    /// version must also match the current open-document version.
    private var problemsDiagnosticsByURI: [String: LSPProblemsDiagnostics] = [:]

    /// Advances whenever pending editor buffers are announced to an
    /// initialized client generation. Structural consumers observe this to
    /// retry requests that can precede SwiftUI's `onAppear`/`didOpen`.
    ///
    /// The compatibility name originated with folding; it now drives symbols
    /// as well.
    private(set) var foldingRefreshGeneration = 0

    /// Advances whenever `diagnosticsByURI` changes. The Problems panel
    /// observes this (Equatable `Int`) via `.onChange` to invalidate stale
    /// selection/navigation state and refresh the summary — the diagnostics
    /// dictionary itself is not `Equatable` and tuples are not, so this token
    /// is the reliable change signal (issue #1236).
    private(set) var diagnosticsGeneration = 0

    /// Languages whose configured server is missing, invalid, or failed to
    /// initialize. Problems uses this to distinguish unavailable from clean.
    private(set) var unavailableLanguages: Set<String> = []

    /// The single persisted source of truth for the global toggle.
    var enabled: Bool { settings.isEnabled }

    /// The workspace root URI (file://...) used for `initialize`.
    private var rootURI: String?

    /// Injected resolver — overridable for tests.
    private let resolver: any LanguageServerResolving

    /// Application-wide persisted settings shared by every project.
    private let settings: LSPSettings

    /// Injectable factory for clients — overridable for tests so a real
    /// `Process` is never spawned in unit tests.
    private let clientFactory: (String) -> any LSPClientProtocol

    /// Invalidates initialize continuations after disable/reconfiguration.
    private var serverGenerations: [String: Int] = [:]

    /// Prevents document events from racing a graceful targeted restart.
    private var restartingLanguages: Set<String> = []

    /// Languages that were active when the global toggle was disabled.
    private var suspendedLanguages: Set<String> = []

    /// Latest editor buffers, including events received while disabled or
    /// while a client is restarting. Replays always read this live mirror
    /// after initialization rather than a pre-shutdown snapshot.
    private var openDocuments: [URL: OpenDocument] = [:]

    /// Number of visible editor owners for each URL. The same file can be
    /// open in multiple panes, so only the final balanced close removes it.
    private var openDocumentOwnerCounts: [URL: Int] = [:]

    /// Exact visible editor owners and their independent buffers. URL-level
    /// counts alone cannot restore the surviving pane after another pane with
    /// the same URL closes.
    private var documentOwnerBuffers:
        [URL: [UUID: DocumentOwnerBuffer]] = [:]

    /// Stable most-recent-owner order for deterministic duplicate-URL resync.
    private var documentOwnerOrder: [URL: [UUID]] = [:]

    /// Documents already announced to the current client generation.
    /// Prevents duplicate `didOpen` when enabling races a normal editor open.
    private var openedDocumentsByLanguage: [String: Set<URL>] = [:]

    /// Clients removed from `servers` while graceful shutdown is in flight.
    /// `shutdownAll()` still needs to terminate them synchronously on quit.
    private var stoppingClients:
        [ObjectIdentifier: any LSPClientProtocol] = [:]

    /// Permanently prevents work from relaunching after project destruction.
    private var isInvalidated = false
    private var lifecycleEpoch = 0

    init(
        settings: LSPSettings = .shared,
        resolver: any LanguageServerResolving = LanguageServerResolver.defaultResolver,
        clientFactory: @escaping (String) -> any LSPClientProtocol = {
            LSPClient(language: $0)
        }
    ) {
        self.settings = settings
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
        isInvalidated = true
        lifecycleEpoch &+= 1

        let activeLanguages = Set(servers.keys).union(restartingLanguages)
        for language in activeLanguages {
            bumpGeneration(for: language)
        }

        var clients: [ObjectIdentifier: any LSPClientProtocol] =
            stoppingClients
        for entry in servers.values {
            clients[ObjectIdentifier(entry.client)] = entry.client
        }
        for client in clients.values {
            client.shutdown()
        }

        servers.removeAll()
        stoppingClients.removeAll()
        diagnosticsByURI = [:]
        rawDiagnosticsByURI = [:]
        problemsDiagnosticsByURI = [:]
        bumpDiagnosticsGeneration()
        openDocuments.removeAll()
        openDocumentOwnerCounts.removeAll()
        documentOwnerBuffers.removeAll()
        documentOwnerOrder.removeAll()
        openedDocumentsByLanguage.removeAll()
        restartingLanguages.removeAll()
        suspendedLanguages.removeAll()
        unavailableLanguages.removeAll()
    }

    /// Applies one persisted settings change without disturbing unrelated
    /// language servers. Previously active clients are replayed from current
    /// editor buffers after the replacement finishes initializing.
    func applySettingsChange(_ change: LSPSettingsChange) async {
        guard !isInvalidated, !Task.isCancelled else { return }
        let epoch = lifecycleEpoch

        switch change {
        case .enabled(false):
            suspendedLanguages.formUnion(servers.keys)
            for language in servers.keys.sorted() {
                await stopServer(for: language)
                guard canContinue(epoch: epoch) else { return }
            }
            diagnosticsByURI = [:]
            rawDiagnosticsByURI = [:]
            problemsDiagnosticsByURI = [:]
            bumpDiagnosticsGeneration()

        case .enabled(true):
            let documentLanguages = openDocuments.values.compactMap {
                LanguageServerRegistry.server(for: $0.url)?.language
            }
            let languages = suspendedLanguages.union(documentLanguages)
            suspendedLanguages.removeAll()
            for language in languages.sorted() {
                await replayDocuments(for: language, epoch: epoch)
                guard canContinue(epoch: epoch) else { return }
            }

        case .language(let language):
            let wasActive = servers[language] != nil
            if wasActive {
                await stopServer(for: language)
                guard canContinue(epoch: epoch) else { return }
            } else {
                clearDiagnostics(for: language)
            }
            if enabled {
                await replayDocuments(for: language, epoch: epoch)
            }
        }
    }

    // MARK: - Document sync

    /// Notifies the appropriate language server that a document was opened.
    /// Lazily spawns the server for the file's language on first use.
    /// No-op when LSP is disabled, the file has no configured server, or the
    /// server binary is not installed.
    func didOpen(
        url: URL,
        ownerID suppliedOwnerID: UUID? = nil,
        contentRevision: UInt64 = 0,
        version: Int = 1,
        text: String
    ) {
        guard !isInvalidated else { return }
        let ownerID = suppliedOwnerID ?? UUID()
        let previousOwner = documentOwnerBuffers[url]?[ownerID]
        let alreadyOwned = previousOwner != nil
        documentOwnerBuffers[url, default: [:]][ownerID] =
            DocumentOwnerBuffer(
                ownerID: ownerID,
                text: text,
                contentRevision: contentRevision
            )
        moveOwnerToEnd(ownerID, for: url)
        let previousOwnerCount = openDocumentOwnerCounts[url, default: 0]
        let ownerCount = documentOwnerBuffers[url]?.count ?? 0
        openDocumentOwnerCounts[url] = ownerCount

        let language = LanguageServerRegistry.server(for: url)?.language
        let isAnnounced = language.flatMap {
            openedDocumentsByLanguage[$0]?.contains(url)
        } == true
        if previousOwnerCount == 0 || !isAnnounced {
            // Before didOpen reaches a client generation, the latest visible
            // owner is the initial snapshot. Once announced, a duplicate owner
            // must not reset the manager version back to 1.
            openDocuments[url] = OpenDocument(
                url: url,
                version: previousOwnerCount == 0
                    ? version
                    : (openDocuments[url]?.version ?? version),
                text: text,
                ownerID: ownerID,
                contentRevision: contentRevision
            )
        }
        if alreadyOwned {
            // SwiftUI may repeat onAppear for the same tab identity. Treat it as
            // an owner refresh, not a second lifecycle owner.
            if isAnnounced,
               previousOwner?.text != text
                || previousOwner?.contentRevision != contentRevision {
                didChange(
                    url: url,
                    ownerID: ownerID,
                    contentRevision: contentRevision,
                    text: text
                )
            }
            return
        }
        if previousOwnerCount > 0 {
            clearDiagnostics(for: url)
        }
        guard enabled else { return }
        guard let serverConfig = LanguageServerRegistry.server(for: url) else { return }

        Task {
            guard await ensureServer(for: serverConfig) else { return }
            sendPendingDidOpen(for: serverConfig.language)
        }
    }

    /// Notifies the appropriate language server that a document changed.
    func didChange(
        url: URL,
        ownerID suppliedOwnerID: UUID? = nil,
        contentRevision: UInt64 = 0,
        text: String
    ) {
        guard !isInvalidated else { return }
        guard let ownerID = resolveOwnerID(
            suppliedOwnerID,
            for: url
        ) else {
            return
        }
        documentOwnerBuffers[url, default: [:]][ownerID] =
            DocumentOwnerBuffer(
                ownerID: ownerID,
                text: text,
                contentRevision: contentRevision
            )
        moveOwnerToEnd(ownerID, for: url)
        let version = (openDocuments[url]?.version ?? 0) + 1
        openDocuments[url] = OpenDocument(
            url: url,
            version: version,
            text: text,
            ownerID: ownerID,
            contentRevision: contentRevision
        )
        // Existing diagnostics describe the previous buffer revision. Clear
        // every surface until the server publishes this exact version.
        clearDiagnostics(for: url)
        guard enabled else { return }
        // Resolve via URL extension so a .ts file reaches the typescript server, etc.
        guard let serverConfig = LanguageServerRegistry.server(for: url) else { return }
        guard openedDocumentsByLanguage[serverConfig.language]?.contains(
            url
        ) == true else {
            return
        }
        let uri = url.absoluteString
        servers[serverConfig.language]?.client.didChange(uri: uri, text: text)
    }

    /// Notifies the appropriate language server that a document was closed.
    func didClose(url: URL, ownerID suppliedOwnerID: UUID? = nil) {
        guard !isInvalidated else { return }
        guard let ownerID = resolveOwnerID(
            suppliedOwnerID,
            for: url
        ), documentOwnerBuffers[url]?.removeValue(forKey: ownerID) != nil else {
            return
        }
        documentOwnerOrder[url]?.removeAll { $0 == ownerID }
        let remainingCount = documentOwnerBuffers[url]?.count ?? 0
        if remainingCount > 0 {
            openDocumentOwnerCounts[url] = remainingCount
            clearDiagnostics(for: url)
            // Re-synchronize whenever an exact sole owner emerges, and also if
            // the disappearing pane owned the current server mirror. This
            // advances the LSP version so a delayed publish from the removed
            // buffer cannot be attributed to the survivor.
            if remainingCount == 1 || openDocuments[url]?.ownerID == ownerID {
                synchronizeMostRecentOwner(for: url)
            }
            return
        }
        openDocumentOwnerCounts[url] = nil
        documentOwnerBuffers[url] = nil
        documentOwnerOrder[url] = nil
        openDocuments[url] = nil
        guard let serverConfig = LanguageServerRegistry.server(for: url) else { return }
        let uri = url.absoluteString
        clearDiagnostics(for: url)
        guard openedDocumentsByLanguage[serverConfig.language]?.remove(
            url
        ) != nil else {
            return
        }
        servers[serverConfig.language]?.client.didClose(uri: uri)
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

    // MARK: - Structural queries (folding — #1008)

    /// Requests LSP fold ranges for the file at `url`. Returns the decoded
    /// `LSPFoldingRange` list, or `nil` when LSP is disabled, the file has no
    /// server, the server lacks `foldingRange` capability, or the request
    /// fails. A `nil` return tells `FoldingCoordinator` to defer to the
    /// bracket fallback.
    ///
    /// `text` is the immutable editor snapshot this request must match. The
    /// request fails closed unless that exact text is already synchronized to
    /// the current client generation; a structural query must never roll the
    /// server back to an older snapshot merely to satisfy itself.
    func foldingRanges(url: URL, text: String) async -> [LSPFoldingRange]? {
        guard enabled else { return nil }
        guard let serverConfig = LanguageServerRegistry.server(for: url) else { return nil }
        let language = serverConfig.language
        guard openDocumentOwnerCounts[url, default: 0] > 0,
              openDocuments[url]?.text == text else {
            return nil
        }
        guard await ensureServer(for: serverConfig) else { return nil }
        guard servers[language]?.state == .initialized else { return nil }
        // `ensureServer` can suspend while edits, closes, or a settings
        // restart advance the document/client generation. Revalidate before
        // announcing or querying anything.
        guard openDocumentOwnerCounts[url, default: 0] > 0,
              openDocuments[url]?.text == text else {
            return nil
        }
        sendPendingDidOpen(for: language)
        guard openedDocumentsByLanguage[language]?.contains(url) == true,
              let client = servers[language]?.client,
              client.supportsFoldingRange else {
            return nil
        }

        let clientID = ObjectIdentifier(client)
        let serverGeneration = serverGenerations[language, default: 0]
        let uri = url.absoluteString
        let ranges = await client.foldingRange(uri: uri)
        guard !Task.isCancelled,
              serverGenerations[language, default: 0] == serverGeneration,
              let currentClient = servers[language]?.client,
              ObjectIdentifier(currentClient) == clientID,
              openedDocumentsByLanguage[language]?.contains(url) == true,
              openDocumentOwnerCounts[url, default: 0] > 0,
              openDocuments[url]?.text == text else {
            return nil
        }
        // An empty list means "no ranges / unsupported" — surface as nil so
        // the provider defers to the bracket fallback rather than blanking
        // all structure.
        return ranges.isEmpty ? nil : ranges
    }

    /// Requests hierarchical LSP document symbols for an exact synchronized
    /// snapshot. Every lifecycle check mirrors folding: no server,
    /// unsupported capability, stale text, client replacement, cancellation,
    /// and empty results all defer to the regex provider.
    func documentSymbols(
        url: URL,
        text: String
    ) async -> [LSPDocumentSymbol]? {
        guard enabled else { return nil }
        guard let serverConfig = LanguageServerRegistry.server(for: url) else {
            return nil
        }
        let language = serverConfig.language
        guard openDocumentOwnerCounts[url, default: 0] > 0,
              openDocuments[url]?.text == text else {
            return nil
        }
        guard await ensureServer(for: serverConfig),
              servers[language]?.state == .initialized else {
            return nil
        }
        guard openDocumentOwnerCounts[url, default: 0] > 0,
              openDocuments[url]?.text == text else {
            return nil
        }
        sendPendingDidOpen(for: language)
        guard openedDocumentsByLanguage[language]?.contains(url) == true,
              let client = servers[language]?.client,
              client.supportsDocumentSymbols else {
            return nil
        }

        let clientID = ObjectIdentifier(client)
        let serverGeneration = serverGenerations[language, default: 0]
        let symbols = await client.documentSymbols(
            uri: url.absoluteString
        )
        guard !Task.isCancelled,
              serverGenerations[language, default: 0] == serverGeneration,
              let currentClient = servers[language]?.client,
              ObjectIdentifier(currentClient) == clientID,
              openedDocumentsByLanguage[language]?.contains(url) == true,
              openDocumentOwnerCounts[url, default: 0] > 0,
              openDocuments[url]?.text == text else {
            return nil
        }
        return symbols.isEmpty ? nil : symbols
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
            if let tabIndex = tabManager.tabs.firstIndex(where: {
                $0.fileURL == fileURL
            }) {
                let original = tabManager.tabs[tabIndex].content
                let result = WorkspaceEditApplier.applyEdits(operated.edits, to: original)
                guard result.success, let newText = result.newText else {
                    let msg = result.errorMessage ?? "unknown"
                    Logger.lsp.error("WorkspaceEdit apply failed for \(fileURL.lastPathComponent, privacy: .public): \(msg, privacy: .public)")
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
                    let msg = result.errorMessage ?? "unknown"
                    Logger.lsp.error("WorkspaceEdit apply failed for \(fileURL.lastPathComponent, privacy: .public): \(msg, privacy: .public)")
                    return false
                }
                diskWrites.append((url: fileURL, newText: newText))
            }
        }

        // Phase 2: commit all changes.
        for change in pendingChanges {
            // Update the tab content directly — the edit is already computed.
            tabManager.tabs[change.tabIndex].content = change.newText
            // Notify the LSP server of the change.
            let tab = tabManager.tabs[change.tabIndex]
            didChange(
                url: change.fileURL,
                ownerID: tab.id,
                contentRevision: tab.contentVersion,
                text: change.newText
            )
        }

        for write in diskWrites {
            do {
                try write.newText.write(to: write.url, atomically: true, encoding: .utf8)
            } catch {
                let errDesc = String(describing: error)
                Logger.lsp.error("WorkspaceEdit: cannot write \(write.url.lastPathComponent, privacy: .public): \(errDesc, privacy: .public)")
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

    /// Revision-bound diagnostics suitable for project-wide Problems routing.
    /// Stale, closed-document, and ambiguous multi-owner results never enter
    /// this store. Versionless server notifications retain `nil` as their LSP
    /// version and are invalidated by the next editor lifecycle transition.
    var allProblemsDiagnostics: [LSPProblemsDiagnostics] {
        problemsDiagnosticsByURI.values
            .filter { !$0.diagnostics.isEmpty }
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
        guard enabled, !isInvalidated, !Task.isCancelled else {
            return false
        }
        guard !restartingLanguages.contains(config.language) else {
            return false
        }

        // Already have an entry for this language?
        if let existing = servers[config.language] {
            return existing.state == .initialized
        }

        let resolution = resolver.resolve(
            config: config,
            serverOverride: settings.serverOverride(for: config.language)
        )
        guard let launch = resolution.launchConfiguration else {
            unavailableLanguages.insert(config.language)
            bumpDiagnosticsGeneration()
            switch resolution {
            case .notFound(let command):
                Logger.lsp.info(
                    "Server binary not installed for \(config.language, privacy: .public): \(command, privacy: .public)"
                )
            case .invalidOverride(let error):
                Logger.lsp.error(
                    "Invalid server override for \(config.language, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            case .resolved:
                break
            }
            return false
        }

        let generation = serverGenerations[config.language, default: 0]
        let epoch = lifecycleEpoch
        let client = clientFactory(config.language)
        let clientID = ObjectIdentifier(client)
        let entry = ServerEntry(
            id: config.language,
            language: config.language,
            client: client,
            state: .uninitialized
        )
        servers[config.language] = entry
        unavailableLanguages.remove(config.language)
        bumpDiagnosticsGeneration()

        // Wire diagnostics callback before starting so nothing is lost.
        client.onDiagnostics = { [weak self] notification in
            guard let self else { return }
            self.handleDiagnostics(
                notification,
                language: config.language,
                generation: generation,
                clientID: clientID
            )
        }

        servers[config.language]?.state = .initializing
        bumpDiagnosticsGeneration()
        let started = await client.startForManager(
            command: launch.executablePath,
            arguments: launch.arguments,
            rootURI: rootURI
        )

        guard enabled,
              !isInvalidated,
              !Task.isCancelled,
              lifecycleEpoch == epoch,
              !restartingLanguages.contains(config.language),
              serverGenerations[config.language, default: 0] == generation,
              let current = servers[config.language],
              ObjectIdentifier(current.client) == clientID else {
            client.shutdown()
            return false
        }

        if started {
            servers[config.language]?.state = .initialized
            unavailableLanguages.remove(config.language)
            Logger.lsp.info("LSP server ready for \(config.language, privacy: .public)")
        } else {
            servers[config.language]?.state = .failed
            unavailableLanguages.insert(config.language)
            Logger.lsp.error("LSP server failed to start for \(config.language, privacy: .public)")
        }
        bumpDiagnosticsGeneration()
        return started
    }

    /// Receives a `publishDiagnostics` notification and merges it into the store.
    private func handleDiagnostics(
        _ notification: LSPDiagnosticsNotification,
        language: String,
        generation: Int,
        clientID: ObjectIdentifier
    ) {
        guard enabled,
              serverGenerations[language, default: 0] == generation,
              let current = servers[language],
              ObjectIdentifier(current.client) == clientID,
              let url = URL(string: notification.uri),
              openDocumentOwnerCounts[url, default: 0] > 0,
              let document = openDocuments[url] else {
            return
        }
        if let version = notification.version,
           version != document.version {
            return
        }
        let mapped = DiagnosticMapper.map(notification)
        diagnosticsByURI[notification.uri] = mapped
        rawDiagnosticsByURI[notification.uri] = notification.diagnostics
        if openDocumentOwnerCounts[url] == 1 {
            problemsDiagnosticsByURI[notification.uri] = LSPProblemsDiagnostics(
                uri: notification.uri,
                documentVersion: notification.version,
                contentRevision: document.contentRevision,
                diagnostics: mapped
            )
        } else {
            problemsDiagnosticsByURI[notification.uri] = nil
        }
        bumpDiagnosticsGeneration()
    }

    /// Removes and gracefully terminates one client while blocking lazy
    /// relaunch until shutdown has completed.
    private func stopServer(for language: String) async {
        restartingLanguages.insert(language)
        bumpGeneration(for: language)
        let client = servers.removeValue(forKey: language)?.client
        openedDocumentsByLanguage[language] = nil
        clearDiagnostics(for: language)
        if let client {
            let clientID = ObjectIdentifier(client)
            stoppingClients[clientID] = client
            _ = await client.shutdownGracefully(timeout: .seconds(3))
            stoppingClients[clientID] = nil
        }
        restartingLanguages.remove(language)
    }

    /// Reopens the latest current editor buffers for one language.
    private func replayDocuments(
        for language: String,
        epoch: Int
    ) async {
        guard enabled,
              canContinue(epoch: epoch),
              let config = LanguageServerRegistry.server(
                  forLanguage: language
              ) else {
            return
        }

        guard hasOpenDocuments(for: language) else { return }
        guard await ensureServer(for: config) else { return }
        guard canContinue(epoch: epoch) else { return }
        sendPendingDidOpen(for: language)
    }

    /// Sends every current document not yet opened in this client generation.
    /// Called only after initialization, so events received during the await
    /// are included with their latest text.
    private func sendPendingDidOpen(for language: String) {
        guard !isInvalidated,
              servers[language]?.state == .initialized else {
            return
        }

        let pending = openDocuments.values
            .filter {
                LanguageServerRegistry.server(for: $0.url)?.language
                    == language
                    && openedDocumentsByLanguage[language]?.contains(
                        $0.url
                    ) != true
            }
            .sorted { $0.url.absoluteString < $1.url.absoluteString }
        guard !pending.isEmpty else { return }
        for document in pending {
            openedDocumentsByLanguage[language, default: []].insert(
                document.url
            )
            servers[language]?.client.didOpen(
                uri: document.url.absoluteString,
                language: language,
                version: document.version,
                text: document.text
            )
        }
        foldingRefreshGeneration &+= 1
    }

    private func resolveOwnerID(
        _ suppliedOwnerID: UUID?,
        for url: URL
    ) -> UUID? {
        if let suppliedOwnerID {
            guard documentOwnerBuffers[url]?[suppliedOwnerID] != nil else {
                return nil
            }
            return suppliedOwnerID
        }
        return documentOwnerOrder[url]?.last
    }

    private func moveOwnerToEnd(_ ownerID: UUID, for url: URL) {
        documentOwnerOrder[url, default: []].removeAll { $0 == ownerID }
        documentOwnerOrder[url, default: []].append(ownerID)
    }

    private func synchronizeMostRecentOwner(for url: URL) {
        guard let ownerID = documentOwnerOrder[url]?.last,
              let owner = documentOwnerBuffers[url]?[ownerID] else {
            return
        }
        let version = (openDocuments[url]?.version ?? 0) + 1
        openDocuments[url] = OpenDocument(
            url: url,
            version: version,
            text: owner.text,
            ownerID: owner.ownerID,
            contentRevision: owner.contentRevision
        )
        guard enabled,
              let config = LanguageServerRegistry.server(for: url),
              openedDocumentsByLanguage[config.language]?.contains(url)
                == true else {
            return
        }
        servers[config.language]?.client.didChange(
            uri: url.absoluteString,
            text: owner.text
        )
    }

    private func clearDiagnostics(for url: URL) {
        let uri = url.absoluteString
        diagnosticsByURI[uri] = nil
        rawDiagnosticsByURI[uri] = nil
        problemsDiagnosticsByURI[uri] = nil
        bumpDiagnosticsGeneration()
    }

    private func hasOpenDocuments(for language: String) -> Bool {
        openDocuments.values.contains {
            LanguageServerRegistry.server(for: $0.url)?.language == language
        }
    }

    private func canContinue(epoch: Int) -> Bool {
        !isInvalidated
            && !Task.isCancelled
            && lifecycleEpoch == epoch
    }

    /// Advances `diagnosticsGeneration` so the Problems panel (and any other
    /// observer) refreshes after a `diagnosticsByURI` mutation.
    private func bumpDiagnosticsGeneration() {
        diagnosticsGeneration &+= 1
    }

    private func clearDiagnostics(for language: String) {
        diagnosticsByURI = diagnosticsByURI.filter {
            languageForURI($0.key) != language
        }
        rawDiagnosticsByURI = rawDiagnosticsByURI.filter {
            languageForURI($0.key) != language
        }
        problemsDiagnosticsByURI = problemsDiagnosticsByURI.filter {
            languageForURI($0.key) != language
        }
        bumpDiagnosticsGeneration()
    }

    private func languageForURI(_ uri: String) -> String? {
        guard let url = URL(string: uri) else { return nil }
        return LanguageServerRegistry.server(for: url)?.language
    }

    private func bumpGeneration(for language: String) {
        serverGenerations[language, default: 0] &+= 1
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
