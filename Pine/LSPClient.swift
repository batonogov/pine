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
/// Marked `@unchecked Sendable` because all mutable state is protected by `queue`
/// (a serial DispatchQueue). The compiler cannot verify GCD-based synchronization,
/// so we use `@unchecked` and maintain the invariant manually.
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

    typealias ResponseHandler = (Result<JSONValue?, LSPClientError>) -> Void

    // MARK: - Constants

    /// Timeout interval for pending requests (30 seconds).
    static let requestTimeoutInterval: TimeInterval = 30

    // MARK: - Properties

    /// Thread-safe state accessor. Reads are synchronized via `queue`.
    var state: State {
        queue.sync { _state }
    }

    // All mutable state below is only accessed on `queue`.
    private var _state: State = .idle
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var nextRequestId = 1
    private var pendingRequests: [Int: ResponseHandler] = [:]
    private var requestTimeoutTimers: [Int: DispatchWorkItem] = [:]
    private var readBuffer = Data()

    private let queue = DispatchQueue(label: "com.pine.lsp-client", qos: .userInitiated)
    private let serverPath: String
    private let serverArguments: [String]
    private let environment: [String: String]?

    /// Called on the main queue when the server sends a notification.
    var onNotification: ((String, JSONValue?) -> Void)?

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

    /// Starts the language server process asynchronously.
    /// - Parameter completion: Called on the internal queue when start completes or fails.
    func start(completion: @escaping (Result<Void, any Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self._state == .idle else {
                completion(.success(()))
                return
            }
            self._state = .starting

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: self.serverPath)
            proc.arguments = self.serverArguments

            if let env = self.environment {
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

            do {
                try proc.run()
                self._state = .running
                Logger.lsp.info("LSP server started: \(self.serverPath)")
                completion(.success(()))
            } catch {
                self._state = .idle
                self.process = nil
                self.stdinPipe = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                Logger.lsp.error("Failed to start LSP server: \(error)")
                completion(.failure(error))
            }
        }
    }

    /// Synchronous start for backward compatibility (used in tests).
    /// Throws if the server cannot be started.
    func start() throws {
        try queue.sync {
            guard _state == .idle else { return }
            _state = .starting

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
            _state = .running
            Logger.lsp.info("LSP server started: \(self.serverPath)")
        }
    }

    /// Sends the initialize request and waits for the response.
    func initialize(rootUri: String?, completion: @escaping (Result<JSONValue?, LSPClientError>) -> Void) {
        let params = InitializeParams(rootUri: rootUri)
        sendRequest(method: "initialize", params: encodableToJSONValue(params), completion: { result in
            switch result {
            case .success:
                // Send initialized notification after successful init response
                self.sendNotification(method: "initialized", params: .object([:]))
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
        let params: JSONValue = .object([
            "textDocument": .object([
                "uri": .string(uri),
                "languageId": .string(languageId),
                "version": .int(version),
                "text": .string(text)
            ])
        ])
        sendNotification(method: "textDocument/didOpen", params: params)
    }

    /// Notifies the server that a document was closed.
    func didCloseDocument(uri: String) {
        let params: JSONValue = .object([
            "textDocument": .object(["uri": .string(uri)])
        ])
        sendNotification(method: "textDocument/didClose", params: params)
    }

    /// Notifies the server that a document changed (full sync).
    func didChangeDocument(uri: String, version: Int, text: String) {
        let params: JSONValue = .object([
            "textDocument": .object([
                "uri": .string(uri),
                "version": .int(version)
            ]),
            "contentChanges": .array([.object(["text": .string(text)])])
        ])
        sendNotification(method: "textDocument/didChange", params: params)
    }

    // MARK: - Completion

    /// Requests completions at the given position.
    func requestCompletion(
        uri: String,
        line: Int,
        character: Int,
        completion: @escaping (Result<[CompletionItem], LSPClientError>) -> Void
    ) {
        let params: JSONValue = .object([
            "textDocument": .object(["uri": .string(uri)]),
            "position": .object(["line": .int(line), "character": .int(character)])
        ])
        sendRequest(method: "textDocument/completion", params: params) { result in
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
    /// Automatically times out after `requestTimeoutInterval` seconds.
    func sendRequest(method: String, params: JSONValue?, completion: @escaping ResponseHandler) {
        queue.async { [weak self] in
            guard let self, self._state == .running else {
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

            // Schedule timeout cleanup
            self.scheduleTimeout(for: id)
        }
    }

    /// Sends a JSON-RPC notification (no response expected).
    func sendNotification(method: String, params: JSONValue?) {
        queue.async { [weak self] in
            guard let self, self._state == .running else { return }

            let notification = JSONRPCNotification(method: method, params: params)
            guard let data = try? LSPMessageCodec.encode(notification) else { return }

            self.stdinPipe?.fileHandleForWriting.write(data)
            Logger.lsp.debug("LSP notification: \(method)")
        }
    }

    // MARK: - Timeout Management

    /// Schedules a timeout for a pending request. Must be called on `queue`.
    private func scheduleTimeout(for requestId: Int) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Already on self.queue
            if let handler = self.pendingRequests.removeValue(forKey: requestId) {
                self.requestTimeoutTimers.removeValue(forKey: requestId)
                Logger.lsp.warning("LSP request [\(requestId)] timed out")
                handler(.failure(.requestTimeout))
            }
        }
        requestTimeoutTimers[requestId] = workItem
        queue.asyncAfter(
            deadline: .now() + Self.requestTimeoutInterval,
            execute: workItem
        )
    }

    /// Cancels the timeout timer for a completed request. Must be called on `queue`.
    private func cancelTimeout(for requestId: Int) {
        if let timer = requestTimeoutTimers.removeValue(forKey: requestId) {
            timer.cancel()
        }
    }

    // MARK: - Response Handling

    private func handleStdoutData(_ data: Data) {
        readBuffer.append(data)

        while let (message, consumed) = LSPMessageCodec.decodeMessage(from: readBuffer) {
            readBuffer = Data(readBuffer.dropFirst(consumed))

            if message.isResponse, let id = message.id {
                // It's a response to a request
                cancelTimeout(for: id)
                if let handler = pendingRequests.removeValue(forKey: id) {
                    if let error = message.error {
                        handler(.failure(.serverError(code: error.code, message: error.message)))
                    } else {
                        handler(.success(message.result))
                    }
                }
            } else if message.isNotification, let method = message.method {
                // Server-initiated notification (e.g., diagnostics, log messages)
                let params = message.params
                Logger.lsp.debug("LSP server notification: \(method)")
                DispatchQueue.main.async { [weak self] in
                    self?.onNotification?(method, params)
                }
            }
        }
    }

    private func handleTermination() {
        _state = .shutdown
        let pending = pendingRequests
        pendingRequests.removeAll()
        // Cancel all timeout timers
        for (_, timer) in requestTimeoutTimers {
            timer.cancel()
        }
        requestTimeoutTimers.removeAll()
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
        // Cancel all timeout timers
        for (_, timer) in requestTimeoutTimers {
            timer.cancel()
        }
        requestTimeoutTimers.removeAll()
        _state = .shutdown
    }

    // MARK: - Helpers

    /// Converts an Encodable value to JSONValue via JSON round-trip.
    private func encodableToJSONValue<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        return obj
    }

    /// Parses completion items from the server response.
    static func parseCompletionItems(from value: JSONValue?) -> [CompletionItem] {
        guard let value else { return [] }

        // Response can be either [CompletionItem] or CompletionList { items: [CompletionItem] }
        if case .object(let dict) = value,
           case .array(let itemsArray) = dict["items"] {
            return itemsArray.compactMap { parseOneCompletionItem($0) }
        } else if case .array(let array) = value {
            return array.compactMap { parseOneCompletionItem($0) }
        }
        return []
    }

    private static func parseOneCompletionItem(_ value: JSONValue) -> CompletionItem? {
        guard case .object(let dict) = value,
              case .string(let label) = dict["label"] else {
            return nil
        }
        return CompletionItem(
            label: label,
            kind: dict["kind"]?.intValue,
            detail: dict["detail"]?.stringValue,
            insertText: dict["insertText"]?.stringValue
        )
    }
}
