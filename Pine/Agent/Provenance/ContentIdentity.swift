//
//  ContentIdentity.swift
//  Pine
//
//  Trusted event provenance slice (epic #933, section 1 — "Trusted event
//  provenance"). A `ContentIdentity` is a verifiable fingerprint of file
//  contents at one point in time, used by `AgentFileChange` to record exact
//  before/after state for a verified agent write.
//
//  Safety invariants (see #933 / #1183):
//  - Stores ONLY a SHA-256 digest and a byte count. It NEVER stores, embeds,
//    or logs the original file contents.
//  - Two identities compare equal iff the digested bytes were identical,
//    which lets a future safe-undo path detect divergence before reverting
//    (#1183: "refuse when the current file has diverged from the expected
//    after-state").
//  - Hashing is deterministic: identical bytes always produce an identical
//    identity, regardless of machine or locale.
//

import CryptoKit
import Foundation

/// A verifiable, content-only fingerprint of a file's bytes at one moment.
///
/// Holds a SHA-256 digest and the original byte count — never the bytes
/// themselves. Two `ContentIdentity` values are equal only when both the
/// digest and byte count match, which is how a verified event can detect that
/// the working tree has diverged from its expected after-state before any
/// inverse operation runs (#1183).
struct ContentIdentity: Codable, Sendable, Equatable, Hashable {
    /// Lowercase hex encoding of the SHA-256 digest (exactly 64 characters).
    let sha256Hex: String
    /// Number of bytes that were hashed. Stored alongside the digest so a
    /// digest collision between inputs of different lengths cannot be treated
    /// as a match.
    let byteCount: Int

    /// Computes the identity of the given data without retaining it.
    ///
    /// - Parameter content: The bytes to fingerprint. They are hashed and then
    ///   discarded; this type never stores them.
    init(content: Data) {
        let digest = SHA256.hash(data: content)
        self.sha256Hex = digest.map { String(format: "%02x", $0) }.joined()
        self.byteCount = content.count
    }

    /// Reconstructs an identity from persisted components.
    ///
    /// Returns `nil` unless `sha256Hex` is exactly 64 lowercase-hex characters
    /// and `byteCount` is non-negative. This keeps a corrupted or tampered
    /// store from loading an identity that could authorize a rollback.
    init?(sha256Hex: String, byteCount: Int) {
        guard byteCount >= 0,
              sha256Hex.count == 64,
              sha256Hex.allSatisfy({ $0.isHexDigit }),
              sha256Hex == sha256Hex.lowercased()
        else { return nil }
        self.sha256Hex = sha256Hex
        self.byteCount = byteCount
    }

    /// The identity of empty content. Useful as a "before" identity for a
    /// newly created file, and as a safe fallback that matches nothing but
    /// other empty content.
    static let empty = ContentIdentity(content: Data())
}

private extension Character {
    /// `true` for characters legal in a lowercase hex string (`0`–`9`, `a`–`f`).
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self)
    }
}
