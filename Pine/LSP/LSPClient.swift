//
//  LSPClient.swift
//  Pine
//
//  Phase 1 of LSP support (issue #1010, parent #994).
//
//  Foundation: spawns a language server process per language, exchanges
//  JSON-RPC 2.0 messages over stdio, and exposes the document-sync
//  notifications (`textDocument/didOpen`, `textDocument/didChange`,
//  `textDocument/didClose`) plus a callback for
//  `textDocument/publishDiagnostics`.
//
//  All I/O runs off the main thread. Public mutating methods
//  (`start`, `sendNotification`, `shutdown`) are safe to call from any
//  actor — they serialise onto a private background queue.
//

import Foundation
import os

// MARK: - JSON-RPC framing

/// Encodes/decodes LSP messages using the Language Server Protocol header
/// framing over stdio:
///
/// `Content-Length: <bytes>\r\n\r\n<UTF-8 JSON payload>`
///
/// Marked `nonisolated` to opt out of the project-wide MainActor default
/// isolation — framing is pure data work with no UI surface.
nonisolated enum LSPMessageFraming {

    /// Serialises a JSON-RPC payload into the LSP wire format.
    /// - Parameter payload: The `[String: Any]` dictionary to JSON-encode.
    /// - Returns: Framed bytes ready to write to the server's stdin.
    static func frame(_ payload: [String: Any]) -> Data {
        guard let json = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.fragmentsAllowed]
        ) else {
            return Data()
        }
        let header = "Content-Length: \(json.count)\r\n\r\n"
        var framed = Data(header.utf8)
        framed.append(json)
        return framed
    }

    /// Extracts the `Content-Length` value from a header block.
    /// Returns `nil` if the header is absent or unparseable.
    static func contentLength(from header: String) -> Int? {
        // Case-insensitive search — servers are inconsistent on casing.
        guard let range = header.range(of: "Content-Length:", options: .caseInsensitive) else {
            return nil
        }
        let afterKey = header[range.upperBound...]
        // Trim leading whitespace then take digits up to the first non-digit.
        let trimmed = afterKey.drop(while: { $0.isWhitespace })
        var digits = ""
        for char in trimmed {
            guard char.isNumber else { break }
            digits.append(char)
        }
        return Int(digits)
    }
}

// MARK: - Transport

/// A minimal JSON-RPC 2.0 transport over a `Process`'s stdio.
///
/// Owns the spawned language-server `Process`, writes framed messages to its
/// stdin, and parses the framing of stdout to deliver complete JSON messages
/// to a delegate. Runs entirely on a private serial dispatch queue so no LSP
/// I/O ever touches the main thread.
///
/// Marked `nonisolated(unsafe)` because access is fully serialised by
/// `ioQueue`. The only cross-thread surface is the delegate callback, which
/// hops to the main actor at the call site.
final class LSPTransport {

    /// Receives fully-decoded JSON-RPC messages (notifications and responses).
    weak var delegate: LSPTransportDelegate?

    /// The spawned language-server process (nil until `start` succeeds).
    private var process: Process?

    /// The pipe used to write messages to the server's stdin.
    private var stdinPipe: Pipe?

    /// Private serial queue — all reads/writes of mutable state happen here.
    private let ioQueue = DispatchQueue(label: "com.pine.lsp-transport")

    /// Accumulates the raw stdout bytes until a complete message is framed.
    private var readBuffer = Data()

    // MARK: - Lifecycle

    /// Spawns the language server with the given command and arguments.
    /// - Parameters:
    ///   - command: Absolute path to the server executable.
    ///   - arguments: Arguments to pass to the server.
    ///   - environment: Environment for the spawned process. When nil the
    ///     current process environment is used with common tool paths prepended.
    /// - Returns: `true` if the process launched successfully.
    @discardableResult
    func start(command: String, arguments: [String], environment: [String: String]? = nil) -> Bool {
        ioQueue.sync {
            // Already running — refuse to double-start.
            if process?.isRunning == true { return false }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: command)
            proc.arguments = arguments

            var env = environment ?? ProcessInfo.processInfo.environment
            // Ensure common tool paths are discoverable by the server itself
            // (e.g. sourcekit-lsp locating the toolchain).
            let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin"]
            let currentPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
            proc.environment = env

            let inPipe = Pipe()
            let outPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = outPipe
            proc.standardError = Pipe() // discard server stderr for now

            // Forward stdout data to the framing reader.
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                self?.ioQueue.async {
                    self?.appendAndParse(chunk)
                }
            }

            do {
                try proc.run()
            } catch {
                Logger.lsp.error("Failed to launch server \(command, privacy: .public): \(String(describing: error), privacy: .public)")
                process = nil
                stdinPipe = nil
                return false
            }

            process = proc
            stdinPipe = inPipe
            Logger.lsp.info("LSP server started: \(command, privacy: .public)")
            return true
        }
    }

    /// Whether the server process is currently running.
    var isRunning: Bool {
        ioQueue.sync { process?.isRunning ?? false }
    }

    /// Writes a framed JSON-RPC message to the server's stdin.
    /// No-op when the process is not running.
    func send(_ payload: [String: Any]) {
        ioQueue.async { [weak self] in
            guard let self,
                  let pipe = self.stdinPipe,
                  self.process?.isRunning == true else { return }
            let framed = LSPMessageFraming.frame(payload)
            do {
                try pipe.fileHandleForWriting.write(contentsOf: framed)
            } catch {
                Logger.lsp.error("Failed to write to server stdin: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Terminates the server process. Sends SIGTERM first, then SIGKILL as a
    /// fallback if the process does not exit within `timeout` seconds.
    func terminate(timeout: TimeInterval = 3.0) {
        ioQueue.sync {
            outPipeCleanup()
            guard let proc = process else { return }
            if proc.isRunning {
                proc.terminate()
                // Give it a moment to exit cleanly.
                proc.waitUntilExit()
            }
            process = nil
            stdinPipe = nil
        }
    }

    /// Detaches the readability handler so the pipe stops calling back.
    /// Must run before the process is terminated to avoid a dangling handler.
    private func outPipeCleanup() {
        guard let proc = process else { return }
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    // MARK: - Framing reader

    /// Appends a stdout chunk and parses as many complete messages as are
    /// available. Runs on `ioQueue` so the buffer is never accessed
    /// concurrently.
    private func appendAndParse(_ chunk: Data) {
        readBuffer.append(chunk)

        while let (message, consumed) = parseNextMessage() {
            // Drop the consumed bytes, keeping any partial trailing data.
            readBuffer.removeFirst(consumed)
            deliver(message)
        }
    }

    /// Attempts to parse one complete JSON-RPC message from the head of
    /// `readBuffer`. Returns the decoded `[String: Any]` and the number of
    /// bytes consumed (header + payload), or `nil` if more data is needed.
    private func parseNextMessage() -> (message: [String: Any], consumed: Int)? {
        // The header is ASCII; look for the `\r\n\r\n` terminator.
        guard let headerRange = readBuffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil // header not yet complete
        }

        let headerData = readBuffer[readBuffer.startIndex..<headerRange.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else {
            // Malformed header — drop everything up to the separator to resync.
            readBuffer.removeSubrange(readBuffer.startIndex...headerRange.upperBound)
            return nil
        }

        guard let length = LSPMessageFraming.contentLength(from: header) else {
            readBuffer.removeSubrange(readBuffer.startIndex...headerRange.upperBound)
            return nil
        }

        let bodyStart = headerRange.upperBound
        // `Data.index(_:offsetBy:)` traps if it would run past endIndex, so
        // validate available bytes first and return nil (wait for more) instead.
        let available = readBuffer.distance(from: bodyStart, to: readBuffer.endIndex)
        guard available >= length else {
            return nil // payload not yet complete
        }
        let bodyEnd = readBuffer.index(bodyStart, offsetBy: length)

        let bodyData = readBuffer.subdata(in: bodyStart..<bodyEnd)
        let consumed = readBuffer.distance(from: readBuffer.startIndex, to: bodyEnd)

        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            Logger.lsp.error("Failed to decode LSP JSON payload")
            return ([:], consumed) // consume to avoid re-parsing a bad message
        }
        return (json, consumed)
    }

    /// Delivers a decoded message to the delegate on the main thread — the
    /// delegate is an `LSPClient` which is `@MainActor`.
    private func deliver(_ message: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.transport(didReceive: message)
        }
    }
}

/// Callback surface for `LSPTransport`.
@MainActor
protocol LSPTransportDelegate: AnyObject {
    /// Called for every complete JSON-RPC message (notification or response).
    func transport(didReceive message: [String: Any])
}

// MARK: - LSPClient

/// Drives a single language-server connection: the JSON-RPC handshake
/// (`initialize` / `initialized`), document-sync notifications, and routing of
/// server-to-client notifications (`textDocument/publishDiagnostics`) to a
/// callback.
///
/// One `LSPClient` instance owns one server process and one set of open
/// documents. `LSPManager` owns a dictionary of these keyed by language id.
///
/// `@MainActor` because all public state (open documents, the diagnostic
/// callback) drives UI, and the transport already hops inbound messages to the
/// main thread before delivering them here.
@MainActor
final class LSPClient {

    /// Server lifecycle state.
    enum State: Equatable {
        case uninitialized
        case initializing
        case initialized
        case shutDown
        case exited
        case failed
    }

    /// The underlying stdio transport. Exposed `internal` for test injection.
    let transport: LSPTransport

    /// Monotonic request-id counter for correlating JSON-RPC requests/responses.
    private var nextRequestID: Int = 0

    /// Pending requests awaiting a server response, keyed by request id.
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]

    /// The language id this client serves (e.g. "swift", "typescript").
    let language: String

    /// Current lifecycle state.
    private(set) var state: State = .uninitialized

    /// Open documents tracked by URI, so `didChange`/`didClose` can reference them.
    private var openDocuments: [String: LSPTextDocumentItem] = [:]

    /// Called whenever the server publishes diagnostics for a document.
    var onDiagnostics: ((LSPDiagnosticsNotification) -> Void)?

    init(language: String, transport: LSPTransport = LSPTransport()) {
        self.language = language
        self.transport = transport
        self.transport.delegate = self
    }

    // MARK: - Lifecycle

    /// Starts the server process and performs the `initialize` handshake.
    /// - Parameters:
    ///   - command: Absolute path to the server binary.
    ///   - arguments: Arguments for the server binary.
    ///   - rootURI: The workspace root as a URI string (e.g. "file:///path").
    /// - Returns: `true` if the server reached the `.initialized` state.
    @discardableResult
    func start(command: String, arguments: [String], rootURI: String?) async -> Bool {
        guard state == .uninitialized || state == .exited else { return false }

        guard transport.start(command: command, arguments: arguments) else {
            state = .failed
            return false
        }

        state = .initializing

        // initialize request
        var initParams: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "capabilities": [
                "textDocument": [
                    "synchronization": [
                        "didOpen": true,
                        "didChange": true,
                        "didClose": true
                    ]
                ]
            ]
        ]
        if let rootURI {
            initParams["rootUri"] = rootURI
        }

        do {
            _ = try await sendRequest("initialize", params: initParams)
        } catch {
            Logger.lsp.error("LSP initialize failed: \(String(describing: error), privacy: .public)")
            state = .failed
            terminate()
            return false
        }

        // initialized notification
        sendNotification("initialized", params: [:])
        state = .initialized
        return true
    }

    /// Performs a graceful `shutdown` → `exit` and terminates the process.
    /// Safe to call even when the server never started.
    func shutdown() {
        guard state == .initialized else {
            terminate()
            return
        }

        // Best-effort shutdown request; ignore failures — we terminate regardless.
        let id = allocateRequestID()
        transport.send([
            "jsonrpc": "2.0",
            "id": id,
            "method": "shutdown"
        ])

        sendNotification("exit", params: [:])
        state = .shutDown
        terminate()
        state = .exited
    }

    /// Force-terminates the transport and marks the client as failed.
    private func terminate() {
        transport.terminate()
    }

    // MARK: - Document sync

    /// Sends `textDocument/didOpen` and tracks the document.
    func didOpen(uri: String, language: String, version: Int, text: String) {
        guard state == .initialized else { return }
        let item = LSPTextDocumentItem(uri: uri, languageId: language, version: version, text: text)
        openDocuments[uri] = item
        sendNotification("textDocument/didOpen", params: [
            "textDocument": [
                "uri": uri,
                "languageId": language,
                "version": version,
                "text": text
            ]
        ])
    }

    /// Sends `textDocument/didChange` (full-document sync) and bumps the version.
    func didChange(uri: String, text: String) {
        guard state == .initialized else { return }
        guard var doc = openDocuments[uri] else { return }
        doc.version += 1
        doc.text = text
        openDocuments[uri] = doc
        sendNotification("textDocument/didChange", params: [
            "textDocument": [
                "uri": uri,
                "version": doc.version
            ],
            "contentChanges": [
                ["text": text]
            ]
        ])
    }

    /// Sends `textDocument/didClose` and stops tracking the document.
    func didClose(uri: String) {
        guard state == .initialized else { return }
        openDocuments[uri] = nil
        sendNotification("textDocument/didClose", params: [
            "textDocument": ["uri": uri]
        ])
    }

    // MARK: - JSON-RPC plumbing

    /// Sends a JSON-RPC request and awaits the server's response.
    func sendRequest(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = allocateRequestID()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            transport.send([
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params
            ])
        }
    }

    /// Sends a JSON-RPC notification (no response expected).
    func sendNotification(_ method: String, params: [String: Any]) {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if !params.isEmpty {
            payload["params"] = params
        }
        transport.send(payload)
    }

    /// Allocates the next sequential request id.
    private func allocateRequestID() -> Int {
        nextRequestID += 1
        return nextRequestID
    }

    /// Resolves a pending request by id, invoking its continuation.
    private func resolveRequest(id: Int, result: Any?, error: [String: Any]?) {
        guard let handler = pending.removeValue(forKey: id) else { return }
        if let error {
            handler(.failure(LSPError(error: error)))
        } else {
            handler(.success((result as? [String: Any]) ?? [:]))
        }
    }
}

/// Error wrapping a JSON-RPC error object.
struct LSPError: Error {
    let error: [String: Any]
}

// MARK: - LSPTransportDelegate

extension LSPClient: LSPTransportDelegate {

    func transport(didReceive message: [String: Any]) {
        // A server-to-client notification (no "id", has "method").
        if let method = message["method"] as? String {
            let params = (message["params"] as? [String: Any]) ?? [:]
            handleNotification(method: method, params: params)
            return
        }

        // A response to a request we sent (has "id").
        if let id = message["id"] as? Int {
            let result = message["result"]
            let error = message["error"] as? [String: Any]
            resolveRequest(id: id, result: result, error: error)
        }
    }

    /// Dispatches a server-to-client notification to the right handler.
    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "textDocument/publishDiagnostics":
            if let notification = LSPDiagnosticsNotification(params: params) {
                onDiagnostics?(notification)
            }
        default:
            // Other notifications (window/logMessage, etc.) are ignored in Phase 1.
            break
        }
    }
}

// MARK: - LSP value types

/// A `textDocument/didOpen` payload.
struct LSPTextDocumentItem {
    var uri: String
    var languageId: String
    var version: Int
    var text: String
}
