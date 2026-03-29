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

    /// Known server configurations.
    static let defaultConfigs: [ServerConfig] = [
        ServerConfig(
            languageId: "swift",
            serverPath: "/usr/bin/xcrun",
            arguments: ["sourcekit-lsp"],
            extensions: ["swift"]
        ),
        ServerConfig(
            languageId: "typescript",
            serverPath: "/usr/local/bin/typescript-language-server",
            arguments: ["--stdio"],
            extensions: ["ts", "tsx"]
        ),
        ServerConfig(
            languageId: "javascript",
            serverPath: "/usr/local/bin/typescript-language-server",
            arguments: ["--stdio"],
            extensions: ["js", "jsx"]
        ),
        ServerConfig(
            languageId: "python",
            serverPath: "/usr/local/bin/pylsp",
            arguments: [],
            extensions: ["py"]
        ),
        ServerConfig(
            languageId: "go",
            serverPath: "/usr/local/bin/gopls",
            arguments: ["serve"],
            extensions: ["go"]
        ),
        ServerConfig(
            languageId: "rust",
            serverPath: "/usr/local/bin/rust-analyzer",
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

            // Verify server exists
            guard FileManager.default.isExecutableFile(atPath: config.serverPath) else {
                Logger.lsp.warning("Server not found at: \(config.serverPath)")
                completion(.failure(.serverNotRunning))
                return
            }

            let client = LSPClient(serverPath: config.serverPath, arguments: config.arguments)
            self.clients[languageId] = client

            do {
                try client.start()
            } catch {
                Logger.lsp.error("Failed to start LSP server for \(languageId): \(error)")
                self.clients.removeValue(forKey: languageId)
                completion(.failure(.serverNotRunning))
                return
            }

            let rootUri = self.rootUri
            client.initialize(rootUri: rootUri) { result in
                switch result {
                case .success:
                    Logger.lsp.info("LSP initialized for \(languageId)")
                    completion(.success(client))
                case .failure(let error):
                    Logger.lsp.error("LSP initialize failed for \(languageId): \(error)")
                    completion(.failure(error))
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
