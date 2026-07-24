//
//  ContentIdentityTests.swift
//  PineTests
//
//  Tests for ContentIdentity (epic #933, slice 1 — trusted event provenance).
//

import Foundation
import Testing

@testable import Pine

nonisolated struct ContentIdentityTests {

    // MARK: - Hashing determinism

    @Test func identicalContent_producesEqualIdentities() {
        let a = ContentIdentity(content: Data("hello world".utf8))
        let b = ContentIdentity(content: Data("hello world".utf8))
        #expect(a == b)
        #expect(a.sha256Hex == b.sha256Hex)
        #expect(a.byteCount == b.byteCount)
    }

    @Test func differentContent_producesDifferentIdentities() {
        let a = ContentIdentity(content: Data("hello".utf8))
        let b = ContentIdentity(content: Data("Hello".utf8))
        #expect(a != b)
        #expect(a.sha256Hex != b.sha256Hex)
    }

    @Test func knownSha256Value_isDeterministic() {
        // SHA-256("hello") is a fixed, well-known digest. Asserting it proves
        // the hashing is deterministic and matches the standard algorithm.
        let identity = ContentIdentity(content: Data("hello".utf8))
        #expect(identity.sha256Hex == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(identity.byteCount == 5)
    }

    @Test func emptyContent_hasStableEmptyIdentity() {
        let empty = ContentIdentity.empty
        let fromData = ContentIdentity(content: Data())
        #expect(empty == fromData)
        #expect(empty.byteCount == 0)
        // SHA-256 of zero bytes is also a fixed value.
        #expect(empty.sha256Hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: - Never stores content

    @Test func identityDoesNotRetainSourceContent() {
        // The identity is a value type holding only a hex string + count.
        // There is no field that could hold the original bytes; this test
        // documents the invariant by confirming the public surface.
        let identity = ContentIdentity(content: Data("sensitive content".utf8))
        #expect(identity.sha256Hex.count == 64)
        // No accessible property exposes the source bytes.
        #expect(Mirror(reflecting: identity).children.map(\.label) == ["sha256Hex", "byteCount"])
    }

    // MARK: - Reconstruction validation (fail-closed)

    @Test func reconstruct_acceptsValidHexAndCount() {
        let hex = String(repeating: "a", count: 64)
        let identity = ContentIdentity(sha256Hex: hex, byteCount: 7)
        #expect(identity?.sha256Hex == hex)
        #expect(identity?.byteCount == 7)
    }

    @Test func reconstruct_rejectsHexOfWrongLength() {
        #expect(ContentIdentity(sha256Hex: "abcd", byteCount: 4) == nil)
        #expect(ContentIdentity(sha256Hex: String(repeating: "a", count: 63), byteCount: 4) == nil)
        #expect(ContentIdentity(sha256Hex: String(repeating: "a", count: 65), byteCount: 4) == nil)
    }

    @Test func reconstruct_rejectsNonHexCharacters() {
        #expect(ContentIdentity(sha256Hex: String(repeating: "z", count: 64), byteCount: 4) == nil)
        #expect(ContentIdentity(sha256Hex: String(repeating: " ", count: 64), byteCount: 4) == nil)
    }

    @Test func reconstruct_rejectsUppercaseHex() {
        // Only lowercase hex is accepted to keep persisted identities canonical.
        #expect(ContentIdentity(sha256Hex: String(repeating: "A", count: 64), byteCount: 4) == nil)
    }

    @Test func reconstruct_rejectsNegativeByteCount() {
        #expect(ContentIdentity(sha256Hex: String(repeating: "a", count: 64), byteCount: -1) == nil)
    }

    @Test func roundTripThroughComputedIdentity_reconstructs() {
        let original = ContentIdentity(content: Data("round trip".utf8))
        let reconstructed = ContentIdentity(sha256Hex: original.sha256Hex, byteCount: original.byteCount)
        #expect(reconstructed == original)
    }

    // MARK: - Codable

    @Test func codable_roundTripsPreservingHash() throws {
        let original = ContentIdentity(content: Data("encode me".utf8))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentIdentity.self, from: data)
        #expect(decoded == original)
    }

    @Test func codable_rejectsInvalidDigest() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sha256Hex": "not-a-digest",
            "byteCount": 12,
        ])

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ContentIdentity.self, from: data)
        }
    }

    @Test func codable_rejectsNegativeByteCount() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sha256Hex": String(repeating: "a", count: 64),
            "byteCount": -1,
        ])

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ContentIdentity.self, from: data)
        }
    }

    @Test func hashingIsAvailableFromDetachedTask() async {
        let identity = await Task.detached {
            ContentIdentity(content: Data("background".utf8))
        }.value

        #expect(identity.byteCount == 10)
    }
}
