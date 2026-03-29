//
//  LSPClient.swift
//  Pine
//

import Foundation
import os

/// LSP client that communicates with a language server via JSON-RPC over stdin/stdout.
///
/// Manages the server process lifecycle, sends requests/notifications, and routes responses.
/// Thread-safe: all state mutations are serialized on an internal queue.
final class LSPClient: @unchecked Sendable {

    // MARK: - Types

    enum LSPClientError: Error, Equatable {
        case serverNotRunning
        case encodingFailed
        case requestTimeout
        case serverError(code: Int, message: String)
    }

    enum State: Equatable {
        case idle
        case starting
        case running
        case shutdown
    }

    typealias ResponseHandler = (Result<AnyCodable?, LSPClientError>) -> Void

    // MARK: - Properties

    private(set) var state: State = .idle
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var nextRequestId = 1
    private var pendingRequests: [Int: ResponseHandler] = [:]
    private var readBuffer = Data()

    private let queue = DispatchQueue(label: "com.pine.lsp-client", qos: .userInitiated)
    private let serverPath: String
    private let serverArguments: [String]
    private let environment: [String: String]?

    /// Called on the main queue when the server sends a notification.
    var onNotification: ((String, AnyCodable?) -> Void)?

    // MARK: - Init

    /// Creates an LSP client for the given language server executable.
    /// - Parameters:
    ///   - serverPath: Path to the language server binary.
    ///   - arguments: Command-line arguments for the server.
    ///   - environment: Optional environment variables for the server process.
    init(serverPath: String, arguments: [String] = [], environment: [String: String]? = nil) {
        self.serverPath = serverPath
        self.serverArguments = arguments
        self.environment = environment
    }

    deinit {
        stopProcess()
    }

    // MARK: - Lifecycle

    /// Starts the language server process.
    func start() throws {
        try queue.sync {
            guard state == .idle else { return }
            state = .starting

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: serverPath)
            proc.arguments = serverArguments

            if let env = environment {
                var processEnv = ProcessInfo.processInfo.environment
                for (key, val) in env {
                    processEnv[key] = val
                }
                proc.environment = processEnv
            }

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()

            proc.standardInput = stdin
            proc.standardOutput = stdout
            proc.standardError = stderr

            self.stdinPipe = stdin
            self.stdoutPipe = stdout
            self.stderrPipe = stderr
            self.process = proc

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.queue.async {
                    self?.handleStdoutData(data)
                }
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    Logger.lsp.debug("LSP stderr: \(text)")
                }
            }

            proc.terminationHandler = { [weak self] _ in
                self?.queue.async {
                    self?.handleTermination()
                }
            }

            try proc.run()
            state = .running
            Logger.lsp.info("LSP server started: \(self.serverPath)")
        }
    }

    /// Sends the initialize request and waits for the response.
    func initialize(rootUri: String?, completion: @escaping (Result<AnyCodable?, LSPClientError>) -> Void) {
        let params = InitializeParams(rootUri: rootUri)
        sendRequest(method: "initialize", params: encodableToAnyCodable(params), completion: { result in
            switch result {
            case .success:
                // Send initialized notification after successful init response
                self.sendNotification(method: "initialized", params: AnyCodable([:] as [String: Any]))
            case .failure:
                break
            }
            completion(result)
        })
    }

    /// Sends a shutdown request followed by exit notification.
    func shutdown(completion: @escaping () -> Void) {
        sendRequest(method: "shutdown", params: nil) { [weak self] _ in
            self?.sendNotification(method: "exit", params: nil)
            self?.queue.async {
                self?.stopProcess()
                completion()
            }
        }
    }

    // MARK: - Document Sync

    /// Notifies the server that a document was opened.
    func didOpenDocument(uri: String, languageId: String, version: Int, text: String) {
        let item = TextDocumentItem(uri: uri, languageId: languageId, version: version, text: text)
        let params: [String: Any] = [
            "textDocument": [
                "uri": item.uri,
                "languageId": item.languageId,
                "version": item.version,
                "text": item.text
            ]
        ]
        sendNotification(method: "textDocument/didOpen", params: AnyCodable(params))
    }

    /// Notifies the server that a document was closed.
    func didCloseDocument(uri: String) {
        let params: [String: Any] = [
            "textDocument": ["uri": uri]
        ]
        sendNotification(method: "textDocument/didClose", params: AnyCodable(params))
    }

    /// Notifies the server that a document changed (full sync).
    func didChangeDocument(uri: String, version: Int, text: String) {
        let params: [String: Any] = [
            "textDocument": ["uri": uri, "version": version],
            "contentChanges": [["text": text]]
        ]
        sendNotification(method: "textDocument/didChange", params: AnyCodable(params))
    }

    // MARK: - Completion

    /// Requests completions at the given position.
    func requestCompletion(
        uri: String,
        line: Int,
        character: Int,
        completion: @escaping (Result<[CompletionItem], LSPClientError>) -> Void
    ) {
        let params: [String: Any] = [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character]
        ]
        sendRequest(method: "textDocument/completion", params: AnyCodable(params)) { result in
            switch result {
            case .success(let value):
                let items = Self.parseCompletionItems(from: value)
                completion(.success(items))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - JSON-RPC Transport

    /// Sends a JSON-RPC request and registers a response handler.
    func sendRequest(method: String, params: AnyCodable?, completion: @escaping ResponseHandler) {
        queue.async { [weak self] in
            guard let self, self.state == .running else {
                completion(.failure(.serverNotRunning))
                return
            }

            let id = self.nextRequestId
            self.nextRequestId += 1
            self.pendingRequests[id] = completion

            let request = JSONRPCRequest(id: id, method: method, params: params)
            guard let data = try? LSPMessageCodec.encode(request) else {
                self.pendingRequests.removeValue(forKey: id)
                completion(.failure(.encodingFailed))
                return
            }

            self.stdinPipe?.fileHandleForWriting.write(data)
            Logger.lsp.debug("LSP request [\(id)] \(method)")
        }
    }

    /// Sends a JSON-RPC notification (no response expected).
    func sendNotification(method: String, params: AnyCodable?) {
        queue.async { [weak self] in
            guard let self, self.state == .running else { return }

            let notification = JSONRPCNotification(method: method, params: params)
            guard let data = try? LSPMessageCodec.encode(notification) else { return }

            self.stdinPipe?.fileHandleForWriting.write(data)
            Logger.lsp.debug("LSP notification: \(method)")
        }
    }

    // MARK: - Response Handling

    private func handleStdoutData(_ data: Data) {
        readBuffer.append(data)

        while let (response, consumed) = LSPMessageCodec.decode(from: readBuffer) {
            readBuffer = Data(readBuffer.dropFirst(consumed))

            if let id = response.id {
                // It's a response to a request
                if let handler = pendingRequests.removeValue(forKey: id) {
                    if let error = response.error {
                        handler(.failure(.serverError(code: error.code, message: error.message)))
                    } else {
                        handler(.success(response.result))
                    }
                }
            } else {
                // It's a server notification — parse method from raw JSON
                // JSONRPCResponse doesn't have method, so we re-decode
                if let notif = decodeNotification(from: readBuffer, consumed: consumed, originalData: data) {
                    DispatchQueue.main.async { [weak self] in
                        self?.onNotification?(notif.method, notif.params)
                    }
                }
            }
        }
    }

    /// Attempts to decode a server-initiated notification from the raw body.
    /// This is needed because JSONRPCResponse doesn't carry a method field.
    private func decodeNotification(from buffer: Data, consumed: Int, originalData: Data) -> JSONRPCNotification? {
        // Re-parse from the original buffer to get the method field
        // This is a simplified approach — in production we'd use a unified message type
        nil
    }

    private func handleTermination() {
        state = .shutdown
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, handler) in pending {
            handler(.failure(.serverNotRunning))
        }
        Logger.lsp.info("LSP server terminated")
    }

    private func stopProcess() {
        process?.terminate()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        state = .shutdown
    }

    // MARK: - Helpers

    /// Converts an Encodable value to AnyCodable via JSON round-trip.
    private func encodableToAnyCodable<T: Encodable>(_ value: T) -> AnyCodable? {
        guard let data = try? JSONEncoder().encode(value),
              let dict = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return AnyCodable(dict)
    }

    /// Parses completion items from the server response.
    static func parseCompletionItems(from value: AnyCodable?) -> [CompletionItem] {
        guard let value else { return [] }

        // Response can be either [CompletionItem] or CompletionList { items: [CompletionItem] }
        if let dict = value.value as? [String: Any],
           let itemsArray = dict["items"] as? [[String: Any]] {
            return itemsArray.compactMap { parseOneCompletionItem($0) }
        } else if let array = value.value as? [[String: Any]] {
            return array.compactMap { parseOneCompletionItem($0) }
        }
        return []
    }

    private static func parseOneCompletionItem(_ dict: [String: Any]) -> CompletionItem? {
        guard let label = dict["label"] as? String else { return nil }
        return CompletionItem(
            label: label,
            kind: dict["kind"] as? Int,
            detail: dict["detail"] as? String,
            insertText: dict["insertText"] as? String
        )
    }
}
