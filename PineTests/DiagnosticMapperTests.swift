//
//  DiagnosticMapperTests.swift
//  PineTests
//
//  Unit tests for DiagnosticMapper — pure logic mapping LSP diagnostics
//  (0-based positions) into Pine's ValidationDiagnostic (1-based).
//

import Foundation
import Testing

@testable import Pine

@Suite("DiagnosticMapper Tests")
struct DiagnosticMapperTests {

    // MARK: - Line conversion (LSP 0-based → Pine 1-based)

    @Test("LSP line 0 maps to Pine line 1")
    func lineZeroMapsToOne() {
        let diag = makeDiagnostic(line: 0, character: 0)
        let result = DiagnosticMapper.map(diag)
        #expect(result.line == 1)
    }

    @Test("LSP line 5 maps to Pine line 6")
    func lineFiveMapsToSix() {
        let diag = makeDiagnostic(line: 5, character: 0)
        let result = DiagnosticMapper.map(diag)
        #expect(result.line == 6)
    }

    // MARK: - Column conversion (LSP 0-based character → Pine 1-based column)

    @Test("LSP character 0 maps to Pine column 1")
    func characterZeroMapsToOne() {
        let diag = makeDiagnostic(line: 0, character: 0)
        let result = DiagnosticMapper.map(diag)
        #expect(result.column == 1)
    }

    @Test("LSP character 10 maps to Pine column 11")
    func characterTenMapsToEleven() {
        let diag = makeDiagnostic(line: 0, character: 10)
        let result = DiagnosticMapper.map(diag)
        #expect(result.column == 11)
    }

    // MARK: - Negative character clamping

    @Test("Negative character clamps to column 1")
    func negativeCharacterClamps() {
        let diag = makeDiagnostic(line: 0, character: -1)
        let result = DiagnosticMapper.map(diag)
        #expect(result.column == 1)  // max(0, -1) + 1 = 1
    }

    @Test("Large negative character clamps to column 1")
    func largeNegativeCharacterClamps() {
        let diag = makeDiagnostic(line: 0, character: -42)
        let result = DiagnosticMapper.map(diag)
        #expect(result.column == 1)  // max(0, -42) + 1 = 1
    }

    // MARK: - Missing severity defaults

    @Test("Missing severity defaults to info")
    func missingSeverityDefaultsToInfo() {
        let diag = makeDiagnostic(line: 0, character: 0)
        let result = DiagnosticMapper.map(diag)
        #expect(result.severity == .info)
    }

    @Test("Error severity maps correctly")
    func errorSeverity() {
        let diag = makeDiagnostic(line: 0, character: 0, severity: 1)
        #expect(DiagnosticMapper.map(diag).severity == .error)
    }

    @Test("Warning severity maps correctly")
    func warningSeverity() {
        let diag = makeDiagnostic(line: 0, character: 0, severity: 2)
        #expect(DiagnosticMapper.map(diag).severity == .warning)
    }

    @Test("Information severity maps to info")
    func informationSeverity() {
        let diag = makeDiagnostic(line: 0, character: 0, severity: 3)
        #expect(DiagnosticMapper.map(diag).severity == .info)
    }

    @Test("Hint severity maps to info")
    func hintSeverity() {
        let diag = makeDiagnostic(line: 0, character: 0, severity: 4)
        #expect(DiagnosticMapper.map(diag).severity == .info)
    }

    // MARK: - Missing source defaults

    @Test("Missing source defaults to 'lsp'")
    func missingSourceDefaultsToLSP() {
        let diag = makeDiagnostic(line: 0, character: 0)
        #expect(DiagnosticMapper.map(diag).source == "lsp")
    }

    @Test("Custom fallback source used when source missing")
    func customFallbackSource() {
        let diag = makeDiagnostic(line: 0, character: 0)
        #expect(DiagnosticMapper.map(diag, fallbackSource: "eslint").source == "eslint")
    }

    @Test("Explicit source preserved over fallback")
    func explicitSourcePreserved() {
        let diag = makeDiagnostic(line: 0, character: 0, source: "swift-format")
        #expect(DiagnosticMapper.map(diag).source == "swift-format")
    }

    // MARK: - Notification mapping

    @Test("Notification maps all diagnostics")
    func notificationMapsAll() {
        let d1 = makeDiagnostic(line: 0, character: 0, message: "first")
        let d2 = makeDiagnostic(line: 3, character: 5, message: "second")
        let notification = LSPDiagnosticsNotification(uri: "file:///test.swift", diagnostics: [d1, d2])
        let results = DiagnosticMapper.map(notification)
        #expect(results.count == 2)
        #expect(results[0].line == 1)
        #expect(results[1].line == 4)
        #expect(results[1].column == 6)
    }

    @Test("Empty diagnostics notification produces empty array")
    func emptyNotification() {
        let notification = LSPDiagnosticsNotification(uri: "file:///test.swift", diagnostics: [])
        let results = DiagnosticMapper.map(notification)
        #expect(results.isEmpty)
    }

    @Test("Publish diagnostics parses an exact document version")
    func notificationVersionParsed() throws {
        let notification = try #require(LSPDiagnosticsNotification(params: [
            "uri": "file:///test.swift",
            "version": 7,
            "diagnostics": []
        ]))
        #expect(notification.version == 7)
    }

    @Test("Publish diagnostics without version remains unverified")
    func notificationWithoutVersionIsUnverified() throws {
        let notification = try #require(LSPDiagnosticsNotification(params: [
            "uri": "file:///test.swift",
            "diagnostics": []
        ]))
        #expect(notification.version == nil)
    }

    // MARK: - Message preservation

    @Test("Message is preserved through mapping")
    func messagePreserved() {
        let diag = makeDiagnostic(line: 2, character: 3, message: "Variable never used")
        #expect(DiagnosticMapper.map(diag).message == "Variable never used")
    }

    // MARK: - Helpers

    private func rangeDict(line: Int, character: Int) -> [String: Any] {
        ["start": ["line": line, "character": character],
         "end": ["line": line, "character": character + 5]]
    }

    private func makeDiagnostic(
        line: Int, character: Int, severity: Int? = nil,
        source: String? = nil, message: String = "test"
    ) -> LSPDiagnostic {
        var json: [String: Any] = [
            "range": rangeDict(line: line, character: character),
            "message": message
        ]
        if let severity { json["severity"] = severity }
        if let source { json["source"] = source }
        // swiftlint:disable:next force_unwrapping
        return LSPDiagnostic(json: json)!
    }
}
