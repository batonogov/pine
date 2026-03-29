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
        let items: JSONValue = .array([
            .object(["label": .string("print"), "kind": .int(3), "detail": .string("func print()")]),
            .object(["label": .string("String"), "kind": .int(7)])
        ])
        let result = LSPClient.parseCompletionItems(from: items)
        #expect(result.count == 2)
        #expect(result[0].label == "print")
        #expect(result[0].kind == 3)
        #expect(result[0].detail == "func print()")
        #expect(result[1].label == "String")
        #expect(result[1].kind == 7)
    }

    @Test func parseCompletionItemsFromCompletionList() {
        let list: JSONValue = .object([
            "isIncomplete": .bool(false),
            "items": .array([
                .object([
                    "label": .string("forEach"),
                    "kind": .int(2),
                    "insertText": .string("forEach { $1 }")
                ]),
                .object(["label": .string("map"), "kind": .int(2)])
            ])
        ])
        let result = LSPClient.parseCompletionItems(from: list)
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
        let result = LSPClient.parseCompletionItems(from: .array([]))
        #expect(result.isEmpty)
    }

    @Test func parseCompletionItemsFromEmptyList() {
        let list: JSONValue = .object(["isIncomplete": .bool(true), "items": .array([])])
        let result = LSPClient.parseCompletionItems(from: list)
        #expect(result.isEmpty)
    }

    @Test func parseCompletionItemsSkipsInvalidEntries() {
        // Items without "label" should be skipped
        let items: JSONValue = .array([
            .object(["label": .string("valid"), "kind": .int(1)]),
            .object(["kind": .int(3)]), // no label — should be skipped
            .object(["label": .string("also_valid")])
        ])
        let result = LSPClient.parseCompletionItems(from: items)
        #expect(result.count == 2)
        #expect(result[0].label == "valid")
        #expect(result[1].label == "also_valid")
    }

    @Test func parseCompletionItemsFromScalarReturnsEmpty() {
        let result = LSPClient.parseCompletionItems(from: .string("not an array"))
        #expect(result.isEmpty)
    }

    @Test func parseCompletionItemsFromIntReturnsEmpty() {
        let result = LSPClient.parseCompletionItems(from: .int(42))
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

    @Test func asyncStartCallsCompletion() async {
        let client = LSPClient(serverPath: "/nonexistent/server")
        let result: Result<Void, any Error> = await withCheckedContinuation { continuation in
            client.start { result in
                continuation.resume(returning: result)
            }
        }
        // Should fail since the server doesn't exist
        switch result {
        case .success:
            Issue.record("Expected failure for nonexistent server")
        case .failure:
            #expect(client.state == .idle)
        }
    }

    // MARK: - LSPClientError

    @Test func errorEquality() {
        let errA = LSPClient.LSPClientError.serverNotRunning
        let errB = LSPClient.LSPClientError.serverNotRunning
        #expect(errA == errB)

        let errC = LSPClient.LSPClientError.encodingFailed
        #expect(errA != errC)

        let errD = LSPClient.LSPClientError.serverError(code: -32600, message: "Invalid")
        let errE = LSPClient.LSPClientError.serverError(code: -32600, message: "Invalid")
        #expect(errD == errE)

        let errF = LSPClient.LSPClientError.serverError(code: -32601, message: "Not found")
        #expect(errD != errF)
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

    // MARK: - Timeout Configuration

    @Test func requestTimeoutIntervalIs30Seconds() {
        #expect(LSPClient.requestTimeoutInterval == 30)
    }

    // MARK: - Thread-safe State Access

    @Test func stateIsThreadSafe() async {
        let client = LSPClient(serverPath: "/nonexistent")

        // Access state from multiple concurrent tasks
        await withTaskGroup(of: LSPClient.State.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    client.state
                }
            }
            for await state in group {
                #expect(state == .idle)
            }
        }
    }
}
