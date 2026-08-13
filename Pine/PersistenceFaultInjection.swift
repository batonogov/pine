//
//  PersistenceFaultInjection.swift
//  Pine
//
//  Deterministic persistence failures shared by unit and process tests.
//

import Foundation
#if DEBUG
import Darwin
#endif

nonisolated enum PersistenceStoreKind: String, CaseIterable, Sendable {
    case preferences
    case session
    case recovery
    case agentTask = "agent-task"
}

nonisolated enum PersistenceWritePhase: String, CaseIterable, Sendable {
    case beforeWrite = "before-write"
    case afterTemporaryWrite = "after-temporary-write"
    case beforeAtomicReplace = "before-atomic-replace"
    case afterAtomicReplace = "after-atomic-replace"
    case beforeSync = "before-sync"
}

nonisolated enum PersistenceFailureKind: String, CaseIterable, Error, Sendable {
    case permissionDenied = "permission-denied"
    case readOnly = "read-only"
    case noSpace = "no-space"
    case atomicRename = "atomic-rename"
    case fsync
    case concurrentWriter = "concurrent-writer"
    case interrupted
}

nonisolated struct PersistenceFault: Equatable, Sendable {
    let store: PersistenceStoreKind
    let phase: PersistenceWritePhase
    let failure: PersistenceFailureKind

    init(
        store: PersistenceStoreKind,
        phase: PersistenceWritePhase,
        failure: PersistenceFailureKind
    ) {
        self.store = store
        self.phase = phase
        self.failure = failure
    }

    init?(encoded: String) {
        let fields = encoded.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let store = PersistenceStoreKind(rawValue: String(fields[0])),
              let phase = PersistenceWritePhase(rawValue: String(fields[1])),
              let failure = PersistenceFailureKind(rawValue: String(fields[2])) else {
            return nil
        }
        self.init(store: store, phase: phase, failure: failure)
    }

    var encoded: String {
        "\(store.rawValue):\(phase.rawValue):\(failure.rawValue)"
    }
}

nonisolated struct PersistenceFaultInjector: Sendable {
    private let injection: @Sendable (
        PersistenceStoreKind,
        PersistenceWritePhase
    ) throws -> Void

    init(
        injection: @escaping @Sendable (
            PersistenceStoreKind,
            PersistenceWritePhase
        ) throws -> Void
    ) {
        self.injection = injection
    }

    func checkpoint(
        store: PersistenceStoreKind,
        phase: PersistenceWritePhase
    ) throws {
        try injection(store, phase)
    }

    static let none = PersistenceFaultInjector { _, _ in }

    /// A repeatable deterministic fault shared by the launched app process.
    /// Release builds deliberately ignore test-only process configuration.
    static let processEnvironment: PersistenceFaultInjector = {
        #if DEBUG
        guard let encoded = ProcessInfo.processInfo.environment[
            "PINE_PERSISTENCE_FAULT"
        ],
        let fault = PersistenceFault(encoded: encoded) else {
            return .none
        }
        let armFile = ProcessInfo.processInfo.environment[
            "PINE_PERSISTENCE_FAULT_ARM_FILE"
        ].map { URL(fileURLWithPath: $0).standardizedFileURL }
        return PersistenceFaultInjector { store, phase in
            guard store == fault.store,
                  phase == fault.phase,
                  armFile.map({
                      FileManager.default.fileExists(atPath: $0.path)
                  }) ?? true else { return }
            if fault.failure == .interrupted {
                PersistenceProcessInterruption.terminate(at: fault)
            }
            throw fault.failure
        }
        #else
        return .none
        #endif
    }()
}

#if DEBUG
/// Turns the explicit process-level `interrupted` fault into the crash that
/// the release gate needs to exercise. Unit fault plans still throw
/// `.interrupted` normally; only the launched app's opt-in environment path
/// can terminate the process.
nonisolated private enum PersistenceProcessInterruption {
    static func terminate(at fault: PersistenceFault) -> Never {
        writeDurableDiagnostic(fault.encoded)
        _ = Darwin.kill(Darwin.getpid(), SIGKILL)
        fatalError("SIGKILL failed for persistence interruption fixture")
    }

    private static func writeDurableDiagnostic(_ diagnostic: String) {
        guard let directory = ProcessInfo.processInfo.environment[
            "PINE_LIFECYCLE_DIAGNOSTICS_DIRECTORY"
        ], directory.hasPrefix("/") else { return }
        let path = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("persistence-interruption.log")
            .path
        let descriptor = Darwin.open(
            path,
            O_WRONLY | O_CREAT | O_APPEND,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return }
        defer { _ = Darwin.close(descriptor) }
        let bytes = Array("\(diagnostic)\n".utf8)
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(descriptor, baseAddress, buffer.count)
        }
        _ = Darwin.fsync(descriptor)
    }
}
#endif

/// Thread-safe, ordered, one-shot fault plan. Unrelated checkpoints cannot
/// consume the next planned injection.
nonisolated final class PersistenceFaultPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [PersistenceFault]

    init(_ faults: [PersistenceFault]) {
        remaining = faults
    }

    var injector: PersistenceFaultInjector {
        PersistenceFaultInjector { [weak self] store, phase in
            try self?.inject(store: store, phase: phase)
        }
    }

    var remainingFaults: [PersistenceFault] {
        lock.withLock { remaining }
    }

    private func inject(
        store: PersistenceStoreKind,
        phase: PersistenceWritePhase
    ) throws {
        let failure = lock.withLock { () -> PersistenceFailureKind? in
            guard let first = remaining.first,
                  first.store == store,
                  first.phase == phase else { return nil }
            remaining.removeFirst()
            return first.failure
        }
        if let failure { throw failure }
    }
}
