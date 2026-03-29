//
//  LSPClientTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct LSPClientTests {

    // MARK: - Parse Completion Items

    @Test func parseCompletionItemsFromArray() {
        let items: [[String: Any]] = [
            ["label": "print", "kind": 3, "detail": "func print()"],
            ["label": "String", "kind": 7]
        ]
        let result = LSPClient.parseCompletionItems(from: AnyCodable(items))
        #expect(result.count == 2)
        #expect(result[0].label == "print")
        #expect(result[0].kind == 3)
        #expect(result[0].detail == "func print()")
        #expect(result[1].label == "String")
        #expect(result[1].kind == 7)
    }

    @Test func parseCompletionItemsFromCompletionList() {
        let list: [String: Any] = [
            "isIncomplete": false,
            "items": [
                ["label": "forEach", "kind": 2, "insertText": "forEach { $1 }"],
                ["label": "map", "kind": 2]
            ]
        ]
        let result = LSPClient.parseCompletionItems(from: AnyCodable(list))
        #expect(result.count == 2)
        #expect(result[0].label == "forEach")
        #expect(result[0].insertText == "forEach { $1 }")
        #expect(result[1].label == "map")
    }

    @Test func parseCompletionItemsFromNil() {
        let result = LSPClient.parseCompletionItems(from: nil)
        #expect(result.isEmpty)
    }

    @Test func parseCompletionItemsFromEmptyArray() {
        let result = LSPClient.parseCompletionItems(from: AnyCodable([] as [Any]))
        #expect(result.isEmpty)
    }

    @Test func parseCompletionItemsFromEmptyList() {
        let list: [String: Any] = ["isIncomplete": true, "items": [] as [Any]]
        let result = LSPClient.parseCompletionItems(from: AnyCodable(list))
        #expect(result.isEmpty)
    }

    @Test func parseCompletionItemsSkipsInvalidEntries() {
        // Items without "label" should be skipped
        let items: [[String: Any]] = [
            ["label": "valid", "kind": 1],
            ["kind": 3], // no label — should be skipped
            ["label": "also_valid"]
        ]
        let result = LSPClient.parseCompletionItems(from: AnyCodable(items))
        #expect(result.count == 2)
        #expect(result[0].label == "valid")
        #expect(result[1].label == "also_valid")
    }

    @Test func parseCompletionItemsFromScalarReturnsEmpty() {
        let result = LSPClient.parseCompletionItems(from: AnyCodable("not an array"))
        #expect(result.isEmpty)
    }

    @Test func parseCompletionItemsFromIntReturnsEmpty() {
        let result = LSPClient.parseCompletionItems(from: AnyCodable(42))
        #expect(result.isEmpty)
    }

    // MARK: - LSPClient State

    @Test func initialStateIsIdle() {
        let client = LSPClient(serverPath: "/nonexistent")
        #expect(client.state == .idle)
    }

    @Test func startFailsForNonexistentServer() {
        let client = LSPClient(serverPath: "/nonexistent/server")
        #expect(throws: (any Error).self) {
            try client.start()
        }
    }

    // MARK: - LSPClientError

    @Test func errorEquality() {
        let a = LSPClient.LSPClientError.serverNotRunning
        let b = LSPClient.LSPClientError.serverNotRunning
        #expect(a == b)

        let c = LSPClient.LSPClientError.encodingFailed
        #expect(a != c)

        let d = LSPClient.LSPClientError.serverError(code: -32600, message: "Invalid")
        let e = LSPClient.LSPClientError.serverError(code: -32600, message: "Invalid")
        #expect(d == e)

        let f = LSPClient.LSPClientError.serverError(code: -32601, message: "Not found")
        #expect(d != f)
    }

    @Test func requestTimeoutError() {
        let error = LSPClient.LSPClientError.requestTimeout
        #expect(error == .requestTimeout)
        #expect(error != .serverNotRunning)
    }

    // MARK: - State Equality

    @Test func stateEquality() {
        #expect(LSPClient.State.idle == .idle)
        #expect(LSPClient.State.running == .running)
        #expect(LSPClient.State.idle != .running)
        #expect(LSPClient.State.starting != .shutdown)
    }
}
