//
//  LSPManager.swift
//  Pine
//

import Foundation
import os

/// Manages LSP clients for different languages.
///
/// Determines the appropriate language server based on file extension,
/// starts/stops servers as needed, and routes document events.
/// Marked `@unchecked Sendable` because all mutable state is protected by `queue`
/// (a serial DispatchQueue). The compiler cannot verify GCD-based synchronization,
/// so we use `@unchecked` and maintain the invariant manually.
final class LSPManager: @unchecked Sendable {

    // MARK: - Types

    /// Configuration for a language server.
    struct ServerConfig: Equatable, Sendable {
        let languageId: String
        let serverPath: String
        let arguments: [String]
        let extensions: Set<String>

        init(languageId: String, serverPath: String, arguments: [String] = [], extensions: Set<String>) {
            self.languageId = languageId
            self.serverPath = serverPath
            self.arguments = arguments
            self.extensions = extensions
        }
    }

    // MARK: - Properties

    private let queue = DispatchQueue(label: "com.pine.lsp-manager", qos: .userInitiated)
    private var clients: [String: LSPClient] = [:] // keyed by languageId
    private var configs: [ServerConfig]
    private var rootUri: String?

    /// Common search paths for language server binaries.
    /// Includes both Intel (`/usr/local/bin`) and Apple Silicon (`/opt/homebrew/bin`) Homebrew paths.
    static let serverSearchPaths: [String] = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin"
    ]

    /// Resolves the first existing executable path for a binary name across known search paths.
    /// Returns the full path if found, or the original path if it's already absolute.
    static func resolveServerPath(_ name: String) -> String? {
        // If already an absolute path, return as-is if executable
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        // Search common paths
        for dir in serverSearchPaths {
            let fullPath = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    /// Known server configurations.
    /// Server paths use `resolveServerPath` at lookup time to support both Intel and Apple Silicon Macs.
    static let defaultConfigs: [ServerConfig] = [
        ServerConfig(
            languageId: "swift",
            serverPath: "/usr/bin/xcrun",
            arguments: ["sourcekit-lsp"],
            extensions: ["swift"]
        ),
        ServerConfig(
            languageId: "typescript",
            serverPath: "typescript-language-server",
            arguments: ["--stdio"],
            extensions: ["ts", "tsx"]
        ),
        ServerConfig(
            languageId: "javascript",
            serverPath: "typescript-language-server",
            arguments: ["--stdio"],
            extensions: ["js", "jsx"]
        ),
        ServerConfig(
            languageId: "python",
            serverPath: "pylsp",
            arguments: [],
            extensions: ["py"]
        ),
        ServerConfig(
            languageId: "go",
            serverPath: "gopls",
            arguments: ["serve"],
            extensions: ["go"]
        ),
        ServerConfig(
            languageId: "rust",
            serverPath: "rust-analyzer",
            arguments: [],
            extensions: ["rs"]
        ),
        ServerConfig(
            languageId: "c",
            serverPath: "/usr/bin/clangd",
            arguments: [],
            extensions: ["c", "h"]
        ),
        ServerConfig(
            languageId: "cpp",
            serverPath: "/usr/bin/clangd",
            arguments: [],
            extensions: ["cpp", "cc", "cxx", "hpp", "hxx"]
        )
    ]

    // MARK: - Init

    init(configs: [ServerConfig]? = nil) {
        self.configs = configs ?? Self.defaultConfigs
    }

    // MARK: - Public API

    /// Sets the workspace root URI for initialize requests.
    func setRootUri(_ uri: String?) {
        queue.sync {
            self.rootUri = uri
        }
    }

    /// Finds the server config for a file extension.
    func configForExtension(_ ext: String) -> ServerConfig? {
        let lower = ext.lowercased()
        return configs.first { $0.extensions.contains(lower) }
    }

    /// Returns the language ID for a file extension, if supported.
    func languageIdForExtension(_ ext: String) -> String? {
        configForExtension(ext)?.languageId
    }

    /// Returns the existing client for a language, if running.
    func clientForLanguage(_ languageId: String) -> LSPClient? {
        queue.sync { clients[languageId] }
    }

    /// Gets or creates a client for the given language, starts it, and runs initialize handshake.
    func ensureClient(
        for languageId: String,
        completion: @escaping (Result<LSPClient, LSPClient.LSPClientError>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            if let existing = self.clients[languageId], existing.state == .running {
                completion(.success(existing))
                return
            }

            guard let config = self.configs.first(where: { $0.languageId == languageId }) else {
                Logger.lsp.error("No server config for language: \(languageId)")
                completion(.failure(.serverNotRunning))
                return
            }

            // Resolve server path (supports both Intel and Apple Silicon)
            guard let resolvedPath = Self.resolveServerPath(config.serverPath) else {
                Logger.lsp.warning(
                    "Server not found for \(languageId). Searched: \(config.serverPath) in \(Self.serverSearchPaths)"
                )
                completion(.failure(.serverNotRunning))
                return
            }

            let client = LSPClient(serverPath: resolvedPath, arguments: config.arguments)
            self.clients[languageId] = client

            client.start { [weak self] result in
                switch result {
                case .success:
                    let rootUri = self?.queue.sync { self?.rootUri }
                    client.initialize(rootUri: rootUri ?? nil) { initResult in
                        switch initResult {
                        case .success:
                            Logger.lsp.info("LSP initialized for \(languageId)")
                            completion(.success(client))
                        case .failure(let error):
                            Logger.lsp.error("LSP initialize failed for \(languageId): \(error)")
                            completion(.failure(error))
                        }
                    }
                case .failure(let error):
                    Logger.lsp.error("Failed to start LSP server for \(languageId): \(error)")
                    self?.queue.async {
                        self?.clients.removeValue(forKey: languageId)
                    }
                    completion(.failure(.serverNotRunning))
                }
            }
        }
    }

    /// Shuts down all running language servers.
    func shutdownAll(completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion()
                return
            }

            let allClients = self.clients
            self.clients.removeAll()

            guard !allClients.isEmpty else {
                completion()
                return
            }

            let group = DispatchGroup()
            for (_, client) in allClients {
                group.enter()
                client.shutdown { group.leave() }
            }
            group.notify(queue: .main) { completion() }
        }
    }

    /// Converts a file URL to an LSP document URI string.
    static func documentUri(for fileURL: URL) -> String {
        fileURL.absoluteString
    }

    /// Converts a directory URL to an LSP root URI string.
    static func rootUri(for directoryURL: URL) -> String {
        directoryURL.absoluteString
    }
}
