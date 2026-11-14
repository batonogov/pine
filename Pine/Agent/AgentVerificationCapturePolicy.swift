import CryptoKit
import Darwin
import Foundation

/// Runtime projection of a selected recipe's input/output declarations. This
/// is neither a second recipe store nor authority to execute its commands.
nonisolated struct AgentVerificationCapturePolicy: Equatable, Sendable {
    let declaredOutputs: Set<String>
    let requiredIgnoredInputs: Set<String>

    static let conservative = AgentVerificationCapturePolicy(declaredOutputs: [], requiredIgnoredInputs: [])

    var isValid: Bool {
        declaredOutputs.count <= 128 && requiredIgnoredInputs.count <= 128
            && declaredOutputs.allSatisfy(Self.validRelativePath)
            && requiredIgnoredInputs.allSatisfy(Self.validRelativePath)
            && !declaredOutputs.contains(where: { output in
                requiredIgnoredInputs.contains { Self.overlaps(output, $0) }
            })
    }

    func excludes(_ path: String) -> Bool {
        declaredOutputs.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    var fingerprint: String {
        var hasher = AgentVerificationCanonicalHasher(domain: "pine.ade.capture-policy.v2")
        for output in Self.sorted(declaredOutputs) { hasher.append("output", output) }
        for input in Self.sorted(requiredIgnoredInputs) { hasher.append("required-ignored-input", input) }
        return hasher.finish()
    }

    static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.utf8.count <= 16_384
            && !path.utf8.contains(0)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git"
            }
    }

    static func sorted(_ paths: Set<String>) -> [String] {
        paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }
}

/// Editor-owned save bytes, ephemeral only. A capture compares these bytes to
/// the actual no-follow disk read; it never silently saves or verifies a buffer
/// by substituting its contents for disk. No buffer data is logged/persisted.
nonisolated struct AgentVerificationUnsavedInput: Sendable {
    let relativePath: String
    let saveBytes: Data
}

nonisolated enum AgentVerificationEditorPreflight: Sendable {
    case unavailable
    /// The owner supplies a thread-safe generation witness. Losing editor
    /// coverage during capture fails closed even when disk contents match.
    case available([AgentVerificationUnsavedInput], isCurrent: @Sendable () -> Bool)
}

nonisolated struct AgentVerificationCanonicalHasher {
    private var hasher = SHA256()

    init(domain: String) { append("domain", domain) }

    mutating func append(_ field: String, _ value: String) {
        append(field, Data(value.utf8))
    }

    mutating func append(_ field: String, _ data: Data) {
        frame(Data(field.utf8))
        frame(data)
    }

    mutating func finish() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func frame(_ data: Data) {
        var length = UInt64(data.count).bigEndian
        hasher.update(data: withUnsafeBytes(of: &length) { Data($0) })
        hasher.update(data: data)
    }
}

/// Ephemeral race signature. Never hashed into a content identity or persisted:
/// equal metadata cannot replace reading bytes, but changed metadata invalidates
/// the shared observation interval even when content was restored afterwards.
nonisolated enum AgentVerificationMetadataWitness {
    static func signature(_ value: stat) -> String {
        "\(value.st_dev):\(value.st_ino):\(value.st_gen):\(value.st_mode):\(value.st_uid):\(value.st_gid)"
            + ":\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec)"
            + ":\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
            + ":\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec)"
    }
}
