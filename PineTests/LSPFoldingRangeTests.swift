//
//  LSPFoldingRangeTests.swift
//  PineTests
//
//  Issue #1008 — tests for the LSP `FoldingRange` decoder, server capability
//  decoding, and position-encoding parsing.
//

import AppKit
import Foundation
import SwiftUI
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
        #expect(range?.positionEncoding == .utf16)
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

    @Test("Missing encoding defaults to UTF-16; invalid values stay unknown")
    func missingDefaultsButUnknownFailsClosed() {
        #expect(LSPPositionEncoding(encoding: nil) == .utf16)
        #expect(LSPPositionEncoding(encoding: "") == .unknown)
        #expect(LSPPositionEncoding(encoding: "weird") == .unknown)
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

    @Test("Editors use their own project-scoped folding requesters")
    func editorRequestersRemainScoped() async throws {
        let firstURL = URL(fileURLWithPath: "/first/App.swift")
        let secondURL = URL(fileURLWithPath: "/second/App.swift")
        let firstRecorder = FoldRequestRecorder(
            ranges: [LSPFoldingRange(startLine: 0, endLine: 1)]
        )
        let secondRecorder = FoldRequestRecorder(
            ranges: [LSPFoldingRange(startLine: 1, endLine: 2)]
        )
        let firstView = CodeEditorView(
            text: .constant("a {\n}"),
            language: "swift",
            fileURL: firstURL,
            foldState: .constant(FoldState()),
            lspFoldRangeRequester: { url, text in
                firstRecorder.request(url: url, text: text)
            }
        )
        let secondView = CodeEditorView(
            text: .constant("b {\n\n}"),
            language: "swift",
            fileURL: secondURL,
            foldState: .constant(FoldState()),
            lspFoldRangeRequester: { url, text in
                secondRecorder.request(url: url, text: text)
            }
        )
        let snapshot = DocumentSnapshot(
            uri: firstURL.absoluteString,
            text: "snapshot",
            revision: DocumentRevision(1)
        )

        let firstResult = await CodeEditorView.Coordinator(
            parent: firstView
        ).requestLSPFoldRanges(snapshot: snapshot)
        let secondResult = await CodeEditorView.Coordinator(
            parent: secondView
        ).requestLSPFoldRanges(snapshot: snapshot)

        #expect(try #require(firstResult).first?.startLine == 0)
        #expect(try #require(secondResult).first?.startLine == 1)
        #expect(firstRecorder.requests.count == 1)
        #expect(firstRecorder.requests.first?.0 == firstURL)
        #expect(firstRecorder.requests.first?.1 == "snapshot")
        #expect(secondRecorder.requests.count == 1)
        #expect(secondRecorder.requests.first?.0 == secondURL)
        #expect(secondRecorder.requests.first?.1 == "snapshot")
    }

    @Test("Editor retries folding after its document reaches the LSP")
    func editorRetriesAfterDocumentAnnouncement() async {
        let url = URL(fileURLWithPath: "/project/App.swift")
        let recorder = FoldRequestRecorder(
            ranges: [LSPFoldingRange(startLine: 0, endLine: 1)]
        )
        let view = CodeEditorView(
            text: .constant("a {\n}"),
            language: "swift",
            fileURL: url,
            foldState: .constant(FoldState()),
            lspFoldRangeRequester: { requestURL, text in
                recorder.request(url: requestURL, text: text)
            },
            lspFoldRefreshGeneration: 4
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        let textView = NSTextView()
        textView.string = "a {\n}"
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        coordinator.scrollView = scrollView

        coordinator.refreshStructuralFoldRangesIfNeeded(generation: 4)
        await Task.yield()
        #expect(recorder.requests.isEmpty)

        coordinator.refreshStructuralFoldRangesIfNeeded(generation: 5)
        await waitUntil { recorder.requests.count == 1 }
        #expect(recorder.requests.first?.0 == url)
        #expect(recorder.requests.first?.1 == "a {\n}")

        coordinator.refreshStructuralFoldRangesIfNeeded(generation: 5)
        await Task.yield()
        #expect(recorder.requests.count == 1)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for structural folding request")
    }
}

@MainActor
private final class FoldRequestRecorder {
    let ranges: [LSPFoldingRange]
    private(set) var requests: [(URL, String)] = []

    init(ranges: [LSPFoldingRange]) {
        self.ranges = ranges
    }

    func request(url: URL, text: String) -> [LSPFoldingRange] {
        requests.append((url, text))
        return ranges
    }
}
