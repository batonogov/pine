import Foundation

/// One bounded physical writer for a connection. A send completes only after
/// every byte reaches the owning child's pipe. Failed or cancelled writes close
/// the channel; they are never retried or replayed as queued user input.
actor CodexAppServerOutbound {
    private struct PendingWrite {
        let bytes: Data
        let deadline: ContinuousClock.Instant
        let beforeWrite: @Sendable () throws -> Void
        let completion: CheckedContinuation<Void, any Error>
    }

    static let maximumPendingWrites = 32
    private let channel: CodexAppServerStdioChannel
    private var pending: [PendingWrite] = []
    private var draining = false
    private var stopped = false

    init(channel: CodexAppServerStdioChannel) { self.channel = channel }

    func send(_ bytes: Data, deadline: ContinuousClock.Instant,
              beforeWrite: @escaping @Sendable () throws -> Void = {}) async throws {
        let channel = self.channel
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !stopped else { throw CodexAppServerWireError.closed }
            guard bytes.count <= CodexAppServerFramer.maximumFrameBytes + 1,
                  pending.count + (draining ? 1 : 0) < Self.maximumPendingWrites else {
                close()
                throw CodexAppServerWireError.capacityExceeded
            }
            try await withCheckedThrowingContinuation { continuation in
                pending.append(PendingWrite(bytes: bytes, deadline: deadline, beforeWrite: beforeWrite, completion: continuation))
                if !draining {
                    draining = true
                    Task { await drain() }
                }
            }
        } onCancel: {
            // Synchronous cancellation fences the descriptor before the actor
            // can be re-entered to drain another queued operation.
            channel.close()
        }
    }

    func close() {
        stopped = true
        channel.close()
        let abandoned = pending
        pending.removeAll()
        for write in abandoned { write.completion.resume(throwing: CodexAppServerWireError.closed) }
    }

    private func drain() async {
        while !stopped, !pending.isEmpty {
            let write = pending.removeFirst()
            do {
                try await channel.write(write.bytes, deadline: write.deadline, beforeWrite: write.beforeWrite)
                write.completion.resume()
            } catch {
                write.completion.resume(throwing: error)
                close()
            }
        }
        draining = false
    }
}
