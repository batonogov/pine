//
//  PersistenceFaultInjection.swift
//  Pine
//
//  Deterministic persistence failures shared by unit and process tests.
//

import Foundation

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
        let environment = ProcessInfo.processInfo.environment
        let fault = environment["PINE_PERSISTENCE_FAULT"].flatMap(
            PersistenceFault.init(encoded:)
        )
        let pause = PersistenceProcessCheckpointPause(
            environment: environment
        )
        guard fault != nil || pause != nil else {
            return .none
        }
        return PersistenceFaultInjector { store, phase in
            try pause?.pauseIfMatching(store: store, phase: phase)
            guard let fault,
                  store == fault.store,
                  phase == fault.phase else { return }
            throw fault.failure
        }
        #else
        return .none
        #endif
    }()
}

#if DEBUG
/// Test-only kill checkpoint used by the real-process lifecycle gate. The
/// marker contains only phase and PID; it never records payload bytes, paths,
/// environment values, prompts, or credentials. A hard timeout prevents a
/// malformed harness configuration from hanging a developer launch forever.
nonisolated private struct PersistenceProcessCheckpointPause: Sendable {
    private struct Marker: Codable {
        let store: String
        let phase: String
        let processIdentifier: Int32
    }

    private let store: PersistenceStoreKind
    private let phase: PersistenceWritePhase
    private let directory: URL

    init?(environment: [String: String]) {
        guard let encoded = environment["PINE_PERSISTENCE_PAUSE"],
              let directoryPath = environment[
                "PINE_PERSISTENCE_CHECKPOINT_DIRECTORY"
              ] else { return nil }
        let fields = encoded.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard fields.count == 2,
              let store = PersistenceStoreKind(rawValue: String(fields[0])),
              let phase = PersistenceWritePhase(
                rawValue: String(fields[1])
              ) else { return nil }
        self.store = store
        self.phase = phase
        directory = URL(
            fileURLWithPath: directoryPath,
            isDirectory: true
        )
    }

    func pauseIfMatching(
        store: PersistenceStoreKind,
        phase: PersistenceWritePhase
    ) throws {
        guard self.store == store, self.phase == phase else { return }
        let marker = Marker(
            store: store.rawValue,
            phase: phase.rawValue,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(
            to: directory.appending(path: "persistence-checkpoint.json"),
            options: .atomic
        )

        let release = directory.appending(path: "persistence-release")
        let deadline = DispatchTime.now() + .seconds(10)
        repeat {
            if FileManager.default.fileExists(atPath: release.path) { return }
            Thread.sleep(forTimeInterval: 0.01)
        } while DispatchTime.now() < deadline
        throw PersistenceFailureKind.interrupted
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
