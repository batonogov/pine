import Darwin
import Foundation

/// Owns the three handles of one supervised child. No process is launched here.
/// The caller must authenticate/bind the child and supervise teardown separately.
/// Consumers read one message at a time: pipe backpressure bounds authoritative
/// traffic instead of building an unbounded Task or decoded-message queue.
nonisolated final class CodexAppServerStdioChannel: @unchecked Sendable {
    private enum Direction: Hashable { case input, output, error }
    private let input: FileHandle
    private let output: FileHandle
    private let error: FileHandle
    private let lock = NSLock()
    private var closed = false
    private var closeObserver: (@Sendable () -> Void)?
    private var active: Set<Direction> = []
    private var handlesClosed = false
    // Accessed exclusively by the single admitted output operation.
    private var framer = CodexAppServerFramer()
    private var buffered = Data()
    private var outputEnded = false

    init(standardInput: FileHandle, standardOutput: FileHandle, standardError: FileHandle) throws {
        input = standardInput
        output = standardOutput
        error = standardError
        do {
            for handle in [input, output, error] {
                let flags = fcntl(handle.fileDescriptor, F_GETFL)
                guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw CodexAppServerWireError.closed
                }
            }
            guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw CodexAppServerWireError.closed
            }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func readNext(deadline: ContinuousClock.Instant) async throws -> CodexAppServerMessage? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await runOnBackground { try self.readMessage(deadline: deadline) }
        } onCancel: { self.close() }
    }

    func write(_ bytes: Data, deadline: ContinuousClock.Instant,
               beforeWrite: @escaping @Sendable () throws -> Void = {}) async throws {
        guard bytes.count <= CodexAppServerFramer.maximumFrameBytes + 1 else {
            close()
            throw CodexAppServerWireError.frameTooLarge
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await runOnBackground {
                try self.writeBytes(bytes, deadline: deadline, beforeWrite: beforeWrite)
            }
        } onCancel: { self.close() }
    }

    private func writeBytes(_ bytes: Data, deadline: ContinuousClock.Instant,
                            beforeWrite: @Sendable () throws -> Void) throws {
        try self.begin(.input)
        defer { self.end(.input) }
        do {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    try self.wait(self.input.fileDescriptor, events: Int16(POLLOUT), deadline: deadline)
                    try beforeWrite()
                    try ensureOpen()
                    guard ContinuousClock.now < deadline else { throw CodexAppServerWireError.closed }
                    let count = Darwin.write(self.input.fileDescriptor, raw.baseAddress?.advanced(by: offset), raw.count - offset)
                    if count > 0 {
                        offset += count
                    } else if count < 0 && [EINTR, EAGAIN].contains(errno) {
                        continue
                    } else {
                        throw CodexAppServerWireError.closed
                    }
                }
            }
        } catch {
            self.close()
            throw error
        }
    }

    /// Stderr can contain secrets. Drain bounded chunks and retain no content;
    /// child exit/transport state supplies the user-facing diagnostic category.
    func drainStandardError(until deadline: ContinuousClock.Instant) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await runOnBackground {
                try self.drainErrors(deadline: deadline)
            }
        } onCancel: { self.close() }
    }

    private func drainErrors(deadline: ContinuousClock.Instant) throws {
        try self.begin(.error)
        defer { self.end(.error) }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        do {
            while true {
                try self.wait(self.error.fileDescriptor, events: Int16(POLLIN), deadline: deadline)
                let count = Darwin.read(self.error.fileDescriptor, &bytes, bytes.count)
                if count == 0 { return }
                if count < 0 && ![EINTR, EAGAIN].contains(errno) { throw CodexAppServerWireError.closed }
            }
        } catch {
            self.close()
            throw error
        }
    }

    /// Pollers observe close within one 20ms polling quantum. Handles close only
    /// after admitted operations leave, preventing descriptor-reuse races.
    /// Installs one negative-only owner revocation. It must not perform I/O or
    /// asynchronous work. Invocation is outside the channel lock, at most once.
    func installCloseObserver(_ observer: @escaping @Sendable () -> Void) throws {
        lock.lock()
        guard closeObserver == nil, !closed else {
            lock.unlock()
            throw CodexAppServerWireError.closed
        }
        closeObserver = observer
        lock.unlock()
    }

    func close() {
        lock.lock()
        let observer = closed ? nil : closeObserver
        closed = true
        closeObserver = nil
        let shouldClose = active.isEmpty && !handlesClosed
        if shouldClose { handlesClosed = true }
        lock.unlock()
        observer?()
        if shouldClose { closeHandles() }
    }

    private func readMessage(deadline: ContinuousClock.Instant) throws -> CodexAppServerMessage? {
        try begin(.output)
        defer { end(.output) }
        do {
            if outputEnded { return nil }
            while true {
                if !buffered.isEmpty {
                    let endIndex = buffered.firstIndex(of: 10).map { buffered.index(after: $0) } ?? buffered.endIndex
                    let fragment = buffered[..<endIndex]
                    var message: CodexAppServerMessage?
                    try framer.receive(Data(fragment)) { message = $0 }
                    buffered.removeSubrange(..<endIndex)
                    if let message {
                        try ensureOpen()
                        return message
                    }
                }
                try wait(output.fileDescriptor, events: Int16(POLLIN), deadline: deadline)
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count > 0 {
                    buffered.append(contentsOf: bytes.prefix(count))
                } else if count == 0 {
                    try framer.finish()
                    outputEnded = true
                    close()
                    return nil
                } else if ![EINTR, EAGAIN].contains(errno) {
                    throw CodexAppServerWireError.closed
                }
            }
        } catch {
            close()
            throw error
        }
    }

    private func wait(_ descriptor: Int32, events: Int16, deadline: ContinuousClock.Instant) throws {
        while true {
            lock.lock()
            let stopped = closed
            lock.unlock()
            guard !stopped, ContinuousClock.now < deadline else { throw CodexAppServerWireError.closed }
            var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&descriptorState, 1, 20)
            if result > 0 {
                guard descriptorState.revents & Int16(POLLNVAL) == 0 else { throw CodexAppServerWireError.closed }
                return
            }
            if result < 0 && errno != EINTR { throw CodexAppServerWireError.closed }
        }
    }

    func validateOpen() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw CodexAppServerWireError.closed }
    }

    private func ensureOpen() throws { try validateOpen() }

    private func begin(_ direction: Direction) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw CodexAppServerWireError.closed }
        guard active.insert(direction).inserted else { throw CodexAppServerWireError.invalidState }
    }

    private func end(_ direction: Direction) {
        lock.lock()
        active.remove(direction)
        let shouldClose = closed && active.isEmpty && !handlesClosed
        if shouldClose { handlesClosed = true }
        lock.unlock()
        if shouldClose { closeHandles() }
    }

    private func closeHandles() {
        try? input.close()
        try? output.close()
        try? error.close()
    }
}
