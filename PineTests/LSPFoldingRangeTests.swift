//
//  LSPFoldingRangeTests.swift
//  PineTests
//
//  Issue #1008 — tests for the LSP `FoldingRange` decoder, server capability
//  decoding, and position-encoding parsing.
//

import Foundation
import Testing

@testable import Pine

@Suite("LSPFoldingRange & Capabilities Tests")
@MainActor
struct LSPFoldingRangeTests {

    // MARK: - FoldingRange decoding

    @Test("Decodes a complete FoldingRange")
    func decodeComplete() {
        let json: [String: Any] = [
            "startLine": 0,
            "endLine": 5,
            "startCharacter": 2,
            "endCharacter": 1,
            "kind": "region"
        ]
        let range = LSPFoldingRange(json: json)
        #expect(range?.startLine == 0)
        #expect(range?.endLine == 5)
        #expect(range?.startCharacter == 2)
        #expect(range?.endCharacter == 1)
        #expect(range?.kind == "region")
    }

    @Test("Decodes a minimal FoldingRange (lines only)")
    func decodeMinimal() {
        let json: [String: Any] = ["startLine": 3, "endLine": 9]
        let range = LSPFoldingRange(json: json)
        #expect(range?.startLine == 3)
        #expect(range?.endLine == 9)
        #expect(range?.startCharacter == nil)
        #expect(range?.endCharacter == nil)
        #expect(range?.kind == nil)
    }

    @Test("Rejects a FoldingRange missing startLine")
    func rejectsMissingStartLine() {
        let json: [String: Any] = ["endLine": 5]
        #expect(LSPFoldingRange(json: json) == nil)
    }

    @Test("Rejects a FoldingRange missing endLine")
    func rejectsMissingEndLine() {
        let json: [String: Any] = ["startLine": 0]
        #expect(LSPFoldingRange(json: json) == nil)
    }

    @Test("Rejects non-dictionary input")
    func rejectsNonDictionary() {
        #expect(LSPFoldingRange(json: "not a dict") == nil)
        #expect(LSPFoldingRange(json: 42) == nil)
        #expect(LSPFoldingRange(json: [1, 2, 3]) == nil)
    }

    // MARK: - Server capabilities decoding

    @Test("Decodes boolean foldingRangeProvider")
    func decodeBoolCapability() {
        // LSPServerCapabilities takes the capabilities object directly (the
        // value of `result["capabilities"]`, extracted by LSPClient).
        let caps = LSPServerCapabilities(json: ["foldingRangeProvider": true])
        #expect(caps.foldingRangeProvider == true)
        #expect(caps.documentSymbolProvider == false)
    }

    @Test("Decodes object foldingRangeProvider as supported")
    func decodeObjectCapability() {
        let caps = LSPServerCapabilities(json: [
            "foldingRangeProvider": ["workDoneProgress": false]
        ])
        #expect(caps.foldingRangeProvider == true)
    }

    @Test("Absence means unsupported")
    func absenceMeansUnsupported() {
        let caps = LSPServerCapabilities(json: [:])
        #expect(caps.foldingRangeProvider == false)
        #expect(caps.documentSymbolProvider == false)
    }

    @Test("Explicit false means unsupported")
    func explicitFalseUnsupported() {
        let caps = LSPServerCapabilities(json: ["foldingRangeProvider": false])
        #expect(caps.foldingRangeProvider == false)
    }

    // MARK: - Position encoding

    @Test("UTF-16 encoding variants parse")
    func utf16Variants() {
        #expect(LSPPositionEncoding(encoding: "utf-16") == .utf16)
        #expect(LSPPositionEncoding(encoding: "utf16") == .utf16)
        #expect(LSPPositionEncoding(encoding: "UTF-16") == .utf16)
    }

    @Test("UTF-8 encoding variants parse")
    func utf8Variants() {
        #expect(LSPPositionEncoding(encoding: "utf-8") == .utf8)
        #expect(LSPPositionEncoding(encoding: "utf8") == .utf8)
    }

    @Test("Missing/unknown encoding defaults to UTF-16")
    func unknownDefaultsToUTF16() {
        #expect(LSPPositionEncoding(encoding: nil) == .utf16)
        #expect(LSPPositionEncoding(encoding: "") == .utf16)
        #expect(LSPPositionEncoding(encoding: "weird") == .utf16)
    }

    // MARK: - LSPFoldProvider adapter

    @Test("LSPFoldProvider defers on nil request result")
    func providerDefersOnNil() async {
        let snap = DocumentSnapshot(uri: "file:///t", text: "a {\n}", revision: DocumentRevision(1))
        let provider = LSPFoldProvider { _ in nil }
        let result = await provider.foldRanges(for: snap)
        #expect(result == nil)
    }

    @Test("LSPFoldProvider defers on empty request result")
    func providerDefersOnEmpty() async {
        let snap = DocumentSnapshot(uri: "file:///t", text: "a {\n}", revision: DocumentRevision(1))
        let provider = LSPFoldProvider { _ in [] }
        let result = await provider.foldRanges(for: snap)
        #expect(result == nil)
    }

    @Test("LSPFoldProvider normalises valid ranges")
    func providerNormalises() async {
        let text = "func a() {\n    x()\n}\n"
        let snap = DocumentSnapshot(uri: "file:///t", text: text, revision: DocumentRevision(1))
        let provider = LSPFoldProvider { _ in
            [LSPFoldingRange(startLine: 0, endLine: 2)]
        }
        let result = await provider.foldRanges(for: snap)
        #expect(result?.count == 1)
        #expect(result?[0].startLine == 1 && result?[0].endLine == 3)
    }
}
