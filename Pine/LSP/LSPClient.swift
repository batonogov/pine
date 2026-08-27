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

import Darwin
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
        var parsedLength: Int?
        for line in header.components(separatedBy: "\r\n") {
            let fields = line.split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard fields.count == 2 else { continue }

            let name = fields[0].trimmingCharacters(
                in: .whitespaces
            )
            guard name.caseInsensitiveCompare("Content-Length")
                    == .orderedSame else {
                continue
            }
            // Multiple length fields are ambiguous and must fail closed.
            guard parsedLength == nil else { return nil }

            let value = fields[1].trimmingCharacters(
                in: .whitespaces
            )
            guard !value.isEmpty,
                  value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(value) else {
                return nil
            }
            parsedLength = length
        }
        return parsedLength
    }
}

// MARK: - Transport

/// Why an active stdio transport stopped accepting messages.
nonisolated enum LSPTransportTermination: Equatable, Sendable {
    case requested
    case endOfFile
    case processExited(status: Int32)
    case protocolViolation(LSPStreamParserError)
}

/// Error used to fail pending JSON-RPC continuations when stdio ends.
nonisolated struct LSPTransportError: LocalizedError, Equatable, Sendable {
    let termination: LSPTransportTermination

    var errorDescription: String? {
        switch termination {
        case .requested:
            return "LSP transport was terminated by the client"
        case .endOfFile:
            return "LSP server closed its stdout stream"
        case .processExited(let status):
            return "LSP server exited with status \(status)"
        case .protocolViolation(let error):
            return "LSP server sent malformed framing: \(error)"
        }
    }
}

/// Error returned when a bounded JSON-RPC request receives no response.
nonisolated struct LSPRequestTimeoutError: LocalizedError, Equatable, Sendable {
    let method: String

    var errorDescription: String? {
        "LSP request timed out: \(method)"
    }
}

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
nonisolated final class LSPTransport: @unchecked Sendable {
    /// Receives fully-decoded JSON-RPC messages (notifications and responses).
    weak var delegate: LSPTransportDelegate?

    /// The spawned language-server process (nil until `start` succeeds).
    private var process: Process?

    /// The pipe used to write messages to the server's stdin.
    private var stdinPipe: Pipe?

    /// Private serial queue — all reads/writes of mutable state happen here.
    /// `.workItem` pushes an autorelease pool around every asynchronously
    /// drained work item (reads, writes, exit hops), so framing and decoding
    /// temporaries drain per item instead of leaking into the worker
    /// thread's fallback pool (#1548).
    private let ioQueue = DispatchQueue(
        label: "com.pine.lsp-transport",
        autoreleaseFrequency: .workItem
    )

    /// Keeps process cleanup responsive when background utility work is busy.
    ///
    /// Termination is correctness-critical and can be awaited by the main
    /// actor, so it must not depend on the shared utility worker pool.
    /// `.workItem` pools each cleanup work item like `ioQueue` above (#1548).
    private let lifecycleQueue = DispatchQueue(
        label: "com.pine.lsp-transport.lifecycle",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    /// Incremental framing state, confined to `ioQueue`.
    private var streamParser = LSPMessageStreamParser()

    /// Signalled directly by the Process termination callback so bounded
    /// termination never waits for work that is itself queued on `ioQueue`.
    private var processExitSemaphore: DispatchSemaphore?

    /// Ignores stale callbacks from a process that was already replaced.
    private var processGeneration = 0

    /// Process exit can precede the final stdout readability callback.
    private var pendingExitStatus: Int32?

    /// EOF and Process.terminationHandler can report the same shutdown.
    private var didDeliverTermination = true

    // MARK: - Lifecycle

    /// Spawns the language server with the given command and arguments.
    /// - Parameters:
    ///   - command: Absolute path to the server executable.
    ///   - arguments: Arguments to pass to the server.
    ///   - environment: Environment for the spawned process. When nil the
    ///     current process environment is used with common tool paths prepended.
    ///   - currentDirectoryURL: Optional working directory for the server.
    ///   - standardError: Destination for server diagnostics.
    /// - Returns: `true` if the process launched successfully.
    @discardableResult
    func start(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        standardError: FileHandle = .nullDevice
    ) -> Bool {
        ioQueue.sync {
            // Already running — refuse to double-start.
            if process?.isRunning == true { return false }

            outPipeCleanup()
            process = nil
            stdinPipe = nil
            processExitSemaphore = nil

            processGeneration &+= 1
            let generation = processGeneration
            streamParser = LSPMessageStreamParser()
            pendingExitStatus = nil
            didDeliverTermination = false

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: command)
            proc.arguments = arguments
            proc.currentDirectoryURL = currentDirectoryURL

            var env: [String: String]
            if let environment {
                // An explicit environment may intentionally be isolated.
                // Preserve it exactly instead of adding host-specific paths.
                env = environment
            } else {
                env = ProcessInfo.processInfo.environment
                // Ensure common tool paths are discoverable by the server
                // when inheriting Pine's production environment.
                let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin"]
                let currentPath = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = (extraPaths + [currentPath])
                    .joined(separator: ":")
            }
            proc.environment = env

            let inPipe = Pipe()
            let outPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = outPipe
            proc.standardError = standardError
            let stdoutDescriptor = outPipe.fileHandleForReading.fileDescriptor
            guard Self.configureNonBlocking(
                descriptor: stdoutDescriptor
            ) else {
                didDeliverTermination = true
                Logger.lsp.error(
                    "Failed to configure nonblocking LSP stdout"
                )
                return false
            }

            let exitSemaphore = DispatchSemaphore(value: 0)
            processExitSemaphore = exitSemaphore

            // Forward stdout data to the framing reader.
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] _ in
                self?.ioQueue.async { [weak self] in
                    self?.drainOutput(
                        descriptor: stdoutDescriptor,
                        generation: generation
                    )
                }
            }

            proc.terminationHandler = { [weak self] terminatedProcess in
                let status = terminatedProcess.terminationStatus
                exitSemaphore.signal()
                self?.ioQueue.async { [weak self] in
                    self?.handleProcessExit(
                        status: status,
                        generation: generation,
                        stdoutDescriptor: stdoutDescriptor
                    )
                }
            }

            do {
                try proc.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                proc.terminationHandler = nil
                didDeliverTermination = true
                process = nil
                stdinPipe = nil
                processExitSemaphore = nil
                let detail = String(describing: error)
                Logger.lsp.error(
                    "Failed to launch server \(command, privacy: .public): \(detail, privacy: .public)"
                )
                return false
            }

            process = proc
            stdinPipe = inPipe
            Logger.lsp.info("LSP server started: \(command, privacy: .public)")
            return true
        }
    }

    /// Configures a pipe descriptor for nonblocking reads, retrying interrupted
    /// system calls. Startup fails closed when either operation is rejected.
    static func configureNonBlocking(descriptor: Int32) -> Bool {
        var descriptorFlags: Int32
        repeat {
            descriptorFlags = Darwin.fcntl(descriptor, F_GETFL)
        } while descriptorFlags == -1 && errno == EINTR
        guard descriptorFlags != -1 else { return false }

        var setResult: Int32
        repeat {
            setResult = Darwin.fcntl(
                descriptor,
                F_SETFL,
                descriptorFlags | O_NONBLOCK
            )
        } while setResult == -1 && errno == EINTR
        return setResult != -1
    }

    /// Whether the server process is currently running.
    var isRunning: Bool {
        ioQueue.sync { process?.isRunning ?? false }
    }

    /// Internal observability for process-lifecycle tests.
    var processIdentifier: pid_t? {
        ioQueue.sync { process?.processIdentifier }
    }

    /// Writes a framed JSON-RPC message to the server's stdin.
    /// No-op when the process is not running.
    func send(_ payload: [String: Any]) {
        // Box as @unchecked Sendable so the payload can cross the
        // nonisolated ioQueue boundary (see `deliver` / `SendableJSONBox`).
        let box = SendableJSONBox(payload)
        ioQueue.async { [weak self] in
            guard let self,
                  let pipe = self.stdinPipe,
                  self.process?.isRunning == true else { return }
            let framed = LSPMessageFraming.frame(box.value)
            do {
                try pipe.fileHandleForWriting.write(contentsOf: framed)
            } catch {
                let detail = String(describing: error)
                Logger.lsp.error(
                    "Failed to write to server stdin: \(detail, privacy: .public)"
                )
            }
        }
    }

    /// Terminates the server process. Sends SIGTERM first, then SIGKILL as a
    /// fallback if the process does not exit within `timeout` seconds.
    func terminate(timeout: TimeInterval = 3.0) {
        let boundedTimeout = timeout.isFinite ? max(0, timeout) : 3.0
        ioQueue.sync {
            outPipeCleanup()
            guard let proc = process else { return }

            if proc.isRunning {
                proc.terminate()
                let waitResult = processExitSemaphore?.wait(
                    timeout: .now() + boundedTimeout
                )
                if waitResult == .timedOut, proc.isRunning {
                    let killResult = Darwin.kill(
                        proc.processIdentifier,
                        SIGKILL
                    )
                    if killResult != 0 {
                        Logger.lsp.error(
                            "Failed to SIGKILL unresponsive LSP process"
                        )
                    }
                    _ = processExitSemaphore?.wait(
                        timeout: .now() + 1.0
                    )
                }
            }

            finishTransport(reason: .requested)
            stdinPipe = nil
            if proc.isRunning {
                // Preserve the handle until Process confirms exit. Reporting a
                // stopped transport must not hide a still-live child.
                process = proc
            } else {
                process = nil
                processExitSemaphore = nil
            }
        }
    }

    /// Runs the bounded TERM-to-KILL cleanup away from the caller's actor.
    func terminateAsync(timeout: TimeInterval = 3.0) async {
        await withCheckedContinuation { continuation in
            lifecycleQueue.async {
                self.terminate(timeout: timeout)
                continuation.resume()
            }
        }
    }

    /// Detaches the readability handler so the pipe stops calling back.
    /// Must run before the process is terminated to avoid a dangling handler.
    private func outPipeCleanup() {
        guard let proc = process else { return }
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    // MARK: - Framing reader

    private func drainOutput(descriptor: Int32, generation: Int) {
        guard generation == processGeneration,
              !didDeliverTermination else {
            return
        }

        var storage = [UInt8](repeating: 0, count: 64 * 1024)
        while !didDeliverTermination {
            let byteCount = storage.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress,
                    buffer.count
                )
            }
            if byteCount > 0 {
                appendAndParse(Data(storage.prefix(byteCount)))
                continue
            }
            if byteCount == 0 {
                handleEndOfFile()
                return
            }

            let readError = errno
            if readError == EINTR {
                continue
            }
            if readError == EAGAIN || readError == EWOULDBLOCK {
                return
            }

            Logger.lsp.error(
                "Failed reading LSP stdout: errno \(readError)"
            )
            handleEndOfFile()
            return
        }
    }

    /// Appends a stdout chunk and delivers every complete message in order.
    private func appendAndParse(_ chunk: Data) {
        if let error = handleParserEvents(streamParser.append(chunk)) {
            failTransportForProtocolViolation(error)
        }
    }

    @discardableResult
    private func handleParserEvents(
        _ events: [LSPStreamParserEvent]
    ) -> LSPStreamParserError? {
        for event in events {
            switch event {
            case .message(let message):
                deliver(message)
            case .malformed(let error):
                let detail = String(describing: error)
                Logger.lsp.error(
                    "Discarded malformed LSP stream input: \(detail, privacy: .public)"
                )
                if error.terminatesStream {
                    return error
                }
            }
        }
        return nil
    }

    private func handleProcessExit(
        status: Int32,
        generation: Int,
        stdoutDescriptor: Int32
    ) {
        guard generation == processGeneration else { return }
        pendingExitStatus = status
        if didDeliverTermination {
            clearExitedProcess()
            return
        }

        // A process can exit before its final readability callback is queued.
        // Non-blockingly drain bytes already in the pipe before considering
        // the stream terminated.
        drainOutput(
            descriptor: stdoutDescriptor,
            generation: generation
        )
        guard !didDeliverTermination else { return }

        // A descendant may inherit stdout and keep the pipe open after the
        // server exits. Bound that unusual case without losing available data.
        ioQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self,
                  generation == self.processGeneration,
                  !self.didDeliverTermination else {
                return
            }
            self.finishTransport(reason: .processExited(status: status))
            self.clearExitedProcess()
        }
    }

    private func handleEndOfFile() {
        if let pendingExitStatus {
            finishTransport(
                reason: .processExited(status: pendingExitStatus)
            )
            clearExitedProcess()
            return
        }

        guard let process else {
            finishTransport(reason: .endOfFile)
            return
        }

        // A normal process exit and stdout EOF race on separate callbacks.
        // Give the already-terminating process a short chance to publish its
        // status so callers can distinguish a clean exit from a live server
        // that merely closed stdout.
        if process.isRunning {
            let didExit = processExitSemaphore?.wait(
                timeout: .now() + .milliseconds(100)
            ) == .success
            if !didExit {
                finishTransport(reason: .endOfFile)
                stopRunningProcessWithoutWaiting()
                return
            }
        }

        let status = process.terminationStatus
        pendingExitStatus = status
        finishTransport(reason: .processExited(status: status))
        clearExitedProcess()
    }

    private func finishTransport(reason: LSPTransportTermination) {
        guard !didDeliverTermination else { return }
        didDeliverTermination = true
        outPipeCleanup()
        handleParserEvents(streamParser.finish())
        deliverTermination(reason)
    }

    private func failTransportForProtocolViolation(
        _ error: LSPStreamParserError
    ) {
        guard !didDeliverTermination else { return }
        finishTransport(reason: .protocolViolation(error))
        stopRunningProcessWithoutWaiting()
    }

    private func stopRunningProcessWithoutWaiting() {
        stdinPipe = nil
        guard let proc = process else { return }
        guard proc.isRunning else {
            clearExitedProcess()
            return
        }

        proc.terminate()
        lifecycleQueue.asyncAfter(
            deadline: .now() + 1.0
        ) {
            guard proc.isRunning else { return }
            if Darwin.kill(proc.processIdentifier, SIGKILL) != 0 {
                Logger.lsp.error(
                    "Failed to SIGKILL malformed LSP process"
                )
            }
        }
    }

    private func clearExitedProcess() {
        guard process?.isRunning != true else { return }
        process = nil
        stdinPipe = nil
        processExitSemaphore = nil
    }

    /// Delivers a decoded message to the delegate on the main thread — the
    /// delegate is an `LSPClient` which is `@MainActor`.
    private func deliver(_ message: [String: Any]) {
        // Wrap in an @unchecked Sendable box so Swift 6 strict concurrency
        // allows crossing the ioQueue → main thread boundary. The dictionary
        // is a freshly decoded JSON payload — no shared mutable state.
        let box = SendableJSONBox(message)
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.transport(didReceive: box.value)
        }
    }

    private func deliverTermination(_ reason: LSPTransportTermination) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.transportDidTerminate(reason)
        }
    }
}

/// Boxes a `[String: Any]` JSON payload as `@unchecked Sendable` so it can
/// cross actor boundaries. Safe because the payload is always a freshly
/// decoded JSON dictionary — never shared mutable state.
nonisolated struct SendableJSONBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// Boxes a polymorphic JSON-RPC result for a checked continuation.
///
/// LSP results may be dictionaries, arrays, scalars, or `null`. The value is
/// freshly decoded and treated as immutable; selected structural decoders may
/// carry the box to a detached task to keep large response walks off main.
nonisolated struct SendableJSONValueBox: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}

/// Callback surface for `LSPTransport`.
@MainActor
protocol LSPTransportDelegate: AnyObject {
    /// Called for every complete JSON-RPC message (notification or response).
    func transport(didReceive message: [String: Any])

    /// Called once when an active process or its stdout stream terminates.
    func transportDidTerminate(_ reason: LSPTransportTermination)
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
protocol LSPClientProtocol: AnyObject {
    var onDiagnostics: ((LSPDiagnosticsNotification) -> Void)? { get set }

    func startForManager(
        command: String,
        arguments: [String],
        rootURI: String?
    ) async -> Bool

    func shutdown()
    func shutdownGracefully(timeout: Duration) async -> Bool
    func didOpen(uri: String, language: String, version: Int, text: String)
    func didChange(uri: String, text: String)
    func didClose(uri: String)
    func hover(uri: String, position: LSPPosition) async -> LSPHover?
    func definition(
        uri: String,
        position: LSPPosition
    ) async -> LSPDefinitionResponse
    func completion(
        uri: String,
        position: LSPPosition
    ) async -> LSPCompletionList
    func codeAction(
        uri: String,
        range: LSPRange,
        diagnostics: [LSPDiagnostic]
    ) async -> LSPCodeActionResponse
    func rename(
        uri: String,
        position: LSPPosition,
        newName: String
    ) async -> LSPWorkspaceEdit

    /// Whether the server advertises `textDocument/foldingRange` (#1008).
    var supportsFoldingRange: Bool { get }

    /// Sends `textDocument/foldingRange` and returns the decoded ranges
    /// (#1008). Returns an empty list when unsupported or unavailable.
    func foldingRange(uri: String) async -> [LSPFoldingRange]

    /// Whether the server advertises hierarchical document symbols (#1008).
    var supportsDocumentSymbols: Bool { get }

    /// Sends `textDocument/documentSymbol` and returns its recursive result.
    func documentSymbols(uri: String) async -> [LSPDocumentSymbol]
}

extension LSPClientProtocol {
    func hover(
        uri: String,
        position: LSPPosition
    ) async -> LSPHover? {
        nil
    }

    func definition(
        uri: String,
        position: LSPPosition
    ) async -> LSPDefinitionResponse {
        .empty
    }

    func completion(
        uri: String,
        position: LSPPosition
    ) async -> LSPCompletionList {
        LSPCompletionList(items: [])
    }

    /// Default: no folding capability until a concrete client overrides it.
    var supportsFoldingRange: Bool { false }

    /// Default: no folding ranges (defer to the bracket fallback).
    func foldingRange(uri: String) async -> [LSPFoldingRange] { [] }

    /// Default: no document-symbol capability or result.
    var supportsDocumentSymbols: Bool { false }

    func documentSymbols(uri: String) async -> [LSPDocumentSymbol] { [] }

    func codeAction(
        uri: String,
        range: LSPRange,
        diagnostics: [LSPDiagnostic]
    ) async -> LSPCodeActionResponse {
        LSPCodeActionResponse(actions: [])
    }

    func rename(
        uri: String,
        position: LSPPosition,
        newName: String
    ) async -> LSPWorkspaceEdit {
        LSPWorkspaceEdit(operatedFiles: [])
    }
}

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

    private struct PendingRequest {
        let completion: (Result<SendableJSONValueBox, Error>) -> Void
        let timeoutTask: Task<Void, Never>?
    }

    /// Pending requests awaiting a server response, keyed by request id.
    private var pending: [Int: PendingRequest] = [:]

    /// Internal observability for deterministic transport-lifecycle tests.
    var pendingRequestCount: Int {
        pending.count
    }

    /// The language id this client serves (e.g. "swift", "typescript").
    let language: String

    /// Server capabilities decoded from the `initialize` result. `nil` until
    /// the handshake completes; `.none` (empty) means no structural features.
    /// Consulted per request so unsupported features short-circuit to the
    /// local fallback without a round trip (#1008).
    private(set) var serverCapabilities: LSPServerCapabilities?

    /// `true` when the server advertises `textDocument/foldingRange`.
    var supportsFoldingRange: Bool {
        serverCapabilities?.foldingRangeProvider == true
    }

    /// `true` when the server advertises `textDocument/documentSymbol`.
    var supportsDocumentSymbols: Bool {
        serverCapabilities?.documentSymbolProvider == true
    }

    /// Current lifecycle state.
    private(set) var state: State = .uninitialized

    /// Most recent terminal transport event for clean-shutdown verification.
    private var lastTermination: LSPTransportTermination?

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
    ///   - environment: Optional isolated environment for the server process.
    ///   - currentDirectoryURL: Optional working directory for the server.
    ///   - standardError: Destination for server diagnostics.
    ///   - initializationTimeout: Maximum time to await the initialize response.
    /// - Returns: `true` if the server reached the `.initialized` state.
    @discardableResult
    func start(
        command: String,
        arguments: [String],
        rootURI: String?,
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        standardError: FileHandle = .nullDevice,
        initializationTimeout: Duration = .seconds(20)
    ) async -> Bool {
        guard state == .uninitialized || state == .exited else { return false }
        lastTermination = nil

        guard transport.start(
            command: command,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            standardError: standardError
        ) else {
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
                    ],
                    "documentSymbol": [
                        "hierarchicalDocumentSymbolSupport": true
                    ]
                ]
            ]
        ]
        if let rootURI {
            initParams["rootUri"] = rootURI
        }

        do {
            let initResult = try await sendRequest(
                "initialize",
                params: initParams,
                timeout: initializationTimeout
            )
            // Capture advertised capabilities (foldingRangeProvider,
            // documentSymbolProvider, positionEncoding) so structural requests
            // can short-circuit unsupported features without a round trip
            // (#1008).
            let capsDict = initResult as? [String: Any] ?? [:]
            serverCapabilities = LSPServerCapabilities(
                json: capsDict["capabilities"] ?? [:]
            )
        } catch {
            Logger.lsp.error("LSP initialize failed: \(String(describing: error), privacy: .public)")
            state = .failed
            await transport.terminateAsync(timeout: 0.5)
            return false
        }

        // initialized notification
        sendNotification("initialized", params: [:])
        state = .initialized
        return true
    }

    /// Performs a synchronous best-effort cleanup.
    ///
    /// Call `shutdownGracefully(timeout:)` when the caller can await the
    /// protocol-level `shutdown` response before sending `exit`.
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

    /// Performs the protocol-level `shutdown` → response → `exit` sequence.
    ///
    /// Both the response wait and the server's natural exit are bounded.
    /// Failure or cancellation falls back to the transport's bounded
    /// TERM-to-KILL cleanup.
    /// - Returns: `true` only when the server acknowledged `shutdown` and
    ///   exited naturally after `exit`.
    func shutdownGracefully(
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        guard state == .initialized else {
            await transport.terminateAsync(timeout: 0.5)
            state = .exited
            return false
        }

        do {
            _ = try await sendRequest(
                "shutdown",
                params: [:],
                timeout: timeout
            )
        } catch {
            state = .shutDown
            await transport.terminateAsync(timeout: 0.5)
            state = .exited
            return false
        }

        state = .shutDown
        sendNotification("exit", params: [:])

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while lastTermination == nil {
            if Task.isCancelled || clock.now >= deadline {
                await transport.terminateAsync(timeout: 0.5)
                state = .exited
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                await transport.terminateAsync(timeout: 0.5)
                state = .exited
                return false
            }
        }

        let exitedCleanly =
            lastTermination == .processExited(status: 0)
        if !exitedCleanly, transport.isRunning {
            await transport.terminateAsync(timeout: 0.5)
        }
        state = .exited
        return exitedCleanly
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

    // MARK: - Phase 2 requests (hover + definition)

    /// Sends `textDocument/hover` and returns the decoded result, or `nil`
    /// when the server reports no hover info for this position.
    func hover(uri: String, position: LSPPosition) async -> LSPHover? {
        guard state == .initialized else { return nil }
        do {
            let result = try await sendRequest("textDocument/hover", params: [
                "textDocument": ["uri": uri],
                "position": ["line": position.line, "character": position.character]
            ])
            return LSPHover(result: result)
        } catch {
            Logger.lsp.error("LSP hover failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Sends `textDocument/definition` and returns the decoded result.
    /// `.empty` when the server reports no definition (or the feature is
    /// unsupported). Handles `Location`, `Location[]`, and `LocationLink[]`.
    func definition(uri: String, position: LSPPosition) async -> LSPDefinitionResponse {
        guard state == .initialized else { return .empty }
        do {
            let result = try await sendRequest("textDocument/definition", params: [
                "textDocument": ["uri": uri],
                "position": ["line": position.line, "character": position.character]
            ])
            return LSPDefinitionResponse(result: result)
        } catch {
            Logger.lsp.error("LSP definition failed: \(String(describing: error), privacy: .public)")
            return .empty
        }
    }

    // MARK: - Structural requests (folding — #1008)

    /// Sends `textDocument/foldingRange` and returns the decoded ranges, or an
    /// empty list when the server reports no ranges, the feature is
    /// unsupported, or the request fails.
    ///
    /// The result is a `FoldingRange[] | null`; both `null` and an empty array
    /// yield `[]`, which `FoldingCoordinator` treats as "defer to the bracket
    /// fallback".
    func foldingRange(uri: String) async -> [LSPFoldingRange] {
        guard state == .initialized, supportsFoldingRange else { return [] }
        do {
            let result = try await sendRequest(
                "textDocument/foldingRange",
                params: ["textDocument": ["uri": uri]],
                timeout: FoldingCoordinator.lspDeadline
            )
            let encoding = serverCapabilities?.positionEncoding ?? .utf16
            return await LSPFoldingRangeDecoder.decode(
                SendableJSONValueBox(result),
                positionEncoding: encoding
            )
        } catch {
            Logger.lsp.error(
                "LSP foldingRange failed: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    /// Sends `textDocument/documentSymbol` and decodes the recursive
    /// `DocumentSymbol[]` result. Empty, invalid, unsupported, cancelled, and
    /// timed-out results defer to the regex symbol provider.
    func documentSymbols(uri: String) async -> [LSPDocumentSymbol] {
        guard state == .initialized, supportsDocumentSymbols else { return [] }
        do {
            let result = try await sendRequest(
                "textDocument/documentSymbol",
                params: ["textDocument": ["uri": uri]],
                timeout: SymbolCoordinator.lspDeadline
            )
            let encoding = serverCapabilities?.positionEncoding ?? .utf16
            let resultBox = SendableJSONValueBox(result)
            return await Task.detached {
                guard let array = resultBox.value as? [Any] else {
                    return []
                }
                return array.compactMap {
                    LSPDocumentSymbol(
                        json: $0,
                        positionEncoding: encoding
                    )
                }
            }.value
        } catch {
            Logger.lsp.error(
                "LSP documentSymbol failed: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    // MARK: - Phase 3 requests (completion)

    /// Sends `textDocument/completion` and returns the decoded list, or an
    /// empty list when the server reports no completions for this position.
    ///
    /// Handles both the `CompletionList` object and the `CompletionItem[]`
    /// array shapes the spec permits.
    func completion(uri: String, position: LSPPosition) async -> LSPCompletionList {
        guard state == .initialized else { return LSPCompletionList(items: []) }
        do {
            let result = try await sendRequest("textDocument/completion", params: [
                "textDocument": ["uri": uri],
                "position": ["line": position.line, "character": position.character]
            ])
            return LSPCompletionList(result: result)
        } catch {
            Logger.lsp.error("LSP completion failed: \(String(describing: error), privacy: .public)")
            return LSPCompletionList(items: [])
        }
    }

    // MARK: - Phase 4 requests (code action + rename)

    /// Sends `textDocument/codeAction` and returns the decoded response.
    /// Returns an empty response when the server reports no actions for
    /// this position/range or the feature is unsupported.
    ///
    /// - Parameters:
    ///   - uri: The document URI.
    ///   - range: The LSP range to request actions for.
    ///   - diagnostics: The diagnostics at the range (passed as context so
    ///     the server can return targeted quick fixes).
    func codeAction(uri: String, range: LSPRange, diagnostics: [LSPDiagnostic]) async -> LSPCodeActionResponse {
        guard state == .initialized else { return LSPCodeActionResponse(actions: []) }
        do {
            let rawDiagnostics: [[String: Any]] = diagnostics.map { diag in
                var dict: [String: Any] = [
                    "range": [
                        "start": ["line": diag.range.start.line, "character": diag.range.start.character],
                        "end": ["line": diag.range.end.line, "character": diag.range.end.character]
                    ],
                    "message": diag.message
                ]
                if let severity = diag.severity {
                    dict["severity"] = severity.rawValue
                }
                if let source = diag.source {
                    dict["source"] = source
                }
                if let code = diag.code {
                    dict["code"] = code
                }
                return dict
            }
            let result = try await sendRequest("textDocument/codeAction", params: [
                "textDocument": ["uri": uri],
                "range": [
                    "start": ["line": range.start.line, "character": range.start.character],
                    "end": ["line": range.end.line, "character": range.end.character]
                ],
                "context": [
                    "diagnostics": rawDiagnostics
                ]
            ])
            return LSPCodeActionResponse(result: result)
        } catch {
            Logger.lsp.error("LSP codeAction failed: \(String(describing: error), privacy: .public)")
            return LSPCodeActionResponse(actions: [])
        }
    }

    /// Sends `textDocument/rename` and returns the decoded `WorkspaceEdit`.
    /// Returns an empty edit when the server reports no rename targets for
    /// this position or the feature is unsupported.
    ///
    /// - Parameters:
    ///   - uri: The document URI.
    ///   - position: The cursor position on the symbol to rename.
    ///   - newName: The new name for the symbol.
    func rename(uri: String, position: LSPPosition, newName: String) async -> LSPWorkspaceEdit {
        guard state == .initialized else { return LSPWorkspaceEdit(operatedFiles: []) }
        do {
            let result = try await sendRequest("textDocument/rename", params: [
                "textDocument": ["uri": uri],
                "position": ["line": position.line, "character": position.character],
                "newName": newName
            ])
            return LSPWorkspaceEdit(json: result ?? NSNull())
        } catch {
            Logger.lsp.error("LSP rename failed: \(String(describing: error), privacy: .public)")
            return LSPWorkspaceEdit(operatedFiles: [])
        }
    }

    // MARK: - JSON-RPC plumbing

    /// Sends a JSON-RPC request and awaits the server's response.
    func sendRequest(
        _ method: String,
        params: [String: Any],
        timeout: Duration? = nil
    ) async throws -> Any? {
        let id = allocateRequestID()
        // The box satisfies Swift 6 strict concurrency while preserving every
        // legal JSON result shape.
        //
        // A raw Foundation collection cannot cross the continuation boundary.
        let boxed: SendableJSONValueBox = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = timeout.map { duration in
                    Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(for: duration)
                        } catch {
                            return
                        }
                        self?.cancelPendingRequest(
                            id: id,
                            error: LSPRequestTimeoutError(method: method)
                        )
                    }
                }
                let completion: (
                    Result<SendableJSONValueBox, Error>
                ) -> Void = { result in
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                pending[id] = PendingRequest(
                    completion: completion,
                    timeoutTask: timeoutTask
                )

                transport.send([
                    "jsonrpc": "2.0",
                    "id": id,
                    "method": method,
                    "params": params
                ])
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest(
                    id: id,
                    error: CancellationError()
                )
            }
        }
        return boxed.value
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
        if let error {
            completeRequest(
                id: id,
                with: .failure(LSPError(error: error))
            )
        } else {
            completeRequest(
                id: id,
                with: .success(SendableJSONValueBox(result))
            )
        }
    }

    private func completeRequest(
        id: Int,
        with result: Result<SendableJSONValueBox, Error>
    ) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask?.cancel()
        request.completion(result)
    }

    /// Cancels both sides of an outstanding JSON-RPC request. Removing only
    /// Pine's continuation leaves a language server doing obsolete structural
    /// work, which can backlog newer interactive requests.
    private func cancelPendingRequest(
        id: Int,
        error: Error
    ) {
        guard pending[id] != nil else { return }
        sendNotification(
            "$/cancelRequest",
            params: ["id": id]
        )
        completeRequest(
            id: id,
            with: .failure(error)
        )
    }
}

extension LSPClient: LSPClientProtocol {
    func startForManager(
        command: String,
        arguments: [String],
        rootURI: String?
    ) async -> Bool {
        await start(
            command: command,
            arguments: arguments,
            rootURI: rootURI
        )
    }
}

/// Error wrapping a JSON-RPC error object.
nonisolated struct LSPError: Error, @unchecked Sendable {
    // `@unchecked Sendable`: the `[String: Any]` JSON-RPC error object is not
    // statically Sendable (`Any` cannot be), but it is a freshly decoded,
    // effectively-immutable payload — same pattern as `SendableJSONBox`.
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

    func transportDidTerminate(_ reason: LSPTransportTermination) {
        lastTermination = reason
        let transportError = LSPTransportError(termination: reason)
        let pendingRequests = Array(pending.values)
        pending.removeAll()
        for request in pendingRequests {
            request.timeoutTask?.cancel()
            request.completion(.failure(transportError))
        }

        switch state {
        case .shutDown, .exited:
            state = .exited
        case .uninitialized:
            break
        case .initializing, .initialized:
            state = .failed
        case .failed:
            break
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
nonisolated struct LSPTextDocumentItem {
    var uri: String
    var languageId: String
    var version: Int
    var text: String
}
