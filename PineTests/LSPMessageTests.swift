//
//  LSPMessageTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct LSPMessageTests {

    // MARK: - AnyCodable

    @Test func anyCodableEncodesString() throws {
        let value = AnyCodable("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        #expect(decoded.value as? String == "hello")
    }

    @Test func anyCodableEncodesInt() throws {
        let value = AnyCodable(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        #expect(decoded.value as? Int == 42)
    }

    @Test func anyCodableEncodesBool() throws {
        let value = AnyCodable(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        #expect(decoded.value as? Bool == true)
    }

    @Test func anyCodableEncodesDouble() throws {
        let value = AnyCodable(3.14)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        #expect(decoded.value as? Double == 3.14)
    }

    @Test func anyCodableEncodesNull() throws {
        let value = AnyCodable(NSNull())
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "null")
    }

    @Test func anyCodableEncodesArray() throws {
        let value = AnyCodable([1, 2, 3])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let array = decoded.value as? [Any]
        #expect(array?.count == 3)
    }

    @Test func anyCodableEncodesDictionary() throws {
        let value = AnyCodable(["key": "value"])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let dict = decoded.value as? [String: Any]
        #expect(dict?["key"] as? String == "value")
    }

    @Test func anyCodableEquality() {
        let a = AnyCodable(42)
        let b = AnyCodable(42)
        let c = AnyCodable("42")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func anyCodableNestedStructure() throws {
        let nested: [String: Any] = [
            "name": "test",
            "items": [1, 2, 3],
            "meta": ["active": true]
        ]
        let value = AnyCodable(nested)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let dict = decoded.value as? [String: Any]
        #expect(dict?["name"] as? String == "test")
    }

    // MARK: - JSONRPCRequest Encoding

    @Test func requestEncodesCorrectly() throws {
        let request = JSONRPCRequest(id: 1, method: "initialize", params: AnyCodable(["rootUri": "/test"]))
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["jsonrpc"] as? String == "2.0")
        #expect(json?["id"] as? Int == 1)
        #expect(json?["method"] as? String == "initialize")
    }

    @Test func requestWithNilParams() throws {
        let request = JSONRPCRequest(id: 5, method: "shutdown")
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["method"] as? String == "shutdown")
        #expect(json?["id"] as? Int == 5)
    }

    @Test func requestRoundTrips() throws {
        let original = JSONRPCRequest(id: 3, method: "textDocument/completion", params: AnyCodable(["line": 10]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        #expect(decoded.jsonrpc == "2.0")
        #expect(decoded.id == 3)
        #expect(decoded.method == "textDocument/completion")
    }

    // MARK: - JSONRPCNotification Encoding

    @Test func notificationEncodesCorrectly() throws {
        let notif = JSONRPCNotification(method: "initialized", params: AnyCodable([:] as [String: Any]))
        let data = try JSONEncoder().encode(notif)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["jsonrpc"] as? String == "2.0")
        #expect(json?["method"] as? String == "initialized")
        #expect(json?["id"] == nil) // notifications have no id
    }

    @Test func notificationWithoutParams() throws {
        let notif = JSONRPCNotification(method: "exit")
        let data = try JSONEncoder().encode(notif)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["method"] as? String == "exit")
    }

    // MARK: - JSONRPCResponse Decoding

    @Test func responseDecodesSuccess() throws {
        let json = """
        {"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}
        """
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(response.id == 1)
        #expect(response.error == nil)
        #expect(response.result != nil)
    }

    @Test func responseDecodesError() throws {
        let json = """
        {"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"Invalid request"}}
        """
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(response.id == 2)
        #expect(response.error?.code == -32600)
        #expect(response.error?.message == "Invalid request")
        #expect(response.result == nil)
    }

    @Test func responseDecodesNullResult() throws {
        let json = """
        {"jsonrpc":"2.0","id":3,"result":null}
        """
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(response.id == 3)
        #expect(response.error == nil)
    }

    // MARK: - LSP Message Framing

    @Test func encodeRequestWithContentLengthHeader() throws {
        let request = JSONRPCRequest(id: 1, method: "initialize")
        let framed = try LSPMessageCodec.encode(request)
        let text = String(data: framed, encoding: .utf8) ?? ""
        #expect(text.hasPrefix("Content-Length: "))
        #expect(text.contains("\r\n\r\n"))
    }

    @Test func encodeNotificationWithContentLengthHeader() throws {
        let notif = JSONRPCNotification(method: "exit")
        let framed = try LSPMessageCodec.encode(notif)
        let text = String(data: framed, encoding: .utf8) ?? ""
        #expect(text.hasPrefix("Content-Length: "))
    }

    @Test func frameContentLengthMatchesBody() {
        let body = Data("{\"test\":true}".utf8)
        let framed = LSPMessageCodec.frame(body)
        let text = String(data: framed, encoding: .utf8) ?? ""
        // Header should say Content-Length: 13 (the body size)
        #expect(text.contains("Content-Length: \(body.count)"))
    }

    @Test func decodeResponseFromFramedData() throws {
        let json = """
        {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"completionProvider":{}}}}
        """
        let body = Data(json.utf8)
        let framed = LSPMessageCodec.frame(body)

        let result = LSPMessageCodec.decode(from: framed)
        #expect(result != nil)
        #expect(result?.0.id == 1)
        #expect(result?.1 == framed.count)
    }

    @Test func decodeReturnsNilForIncompleteHeader() {
        let partial = Data("Content-Len".utf8)
        let result = LSPMessageCodec.decode(from: partial)
        #expect(result == nil)
    }

    @Test func decodeReturnsNilForIncompleteBody() {
        let header = "Content-Length: 100\r\n\r\n"
        let data = Data(header.utf8) + Data("{}".utf8) // only 2 bytes, not 100
        let result = LSPMessageCodec.decode(from: data)
        #expect(result == nil)
    }

    @Test func decodeMultipleMessagesFromBuffer() throws {
        let json1 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}"
        let json2 = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":42}"

        var buffer = LSPMessageCodec.frame(Data(json1.utf8))
        buffer.append(LSPMessageCodec.frame(Data(json2.utf8)))

        // Decode first
        let first = LSPMessageCodec.decode(from: buffer)
        #expect(first != nil)
        #expect(first?.0.id == 1)

        // Advance buffer
        let consumed = try #require(first).1
        let remaining = Data(buffer.dropFirst(consumed))
        let second = LSPMessageCodec.decode(from: remaining)
        #expect(second != nil)
        #expect(second?.0.id == 2)
    }

    @Test func decodeErrorResponse() throws {
        let json = """
        {"jsonrpc":"2.0","id":5,"error":{"code":-32601,"message":"Method not found"}}
        """
        let framed = LSPMessageCodec.frame(Data(json.utf8))
        let result = LSPMessageCodec.decode(from: framed)
        #expect(result?.0.error?.code == -32601)
        #expect(result?.0.error?.message == "Method not found")
    }

    // MARK: - Content-Length Parsing

    @Test func parseContentLengthFromHeader() {
        let header = "Content-Length: 42\r\nContent-Type: application/json"
        let length = LSPMessageCodec.parseContentLength(from: header)
        #expect(length == 42)
    }

    @Test func parseContentLengthCaseInsensitive() {
        let header = "content-length: 100"
        let length = LSPMessageCodec.parseContentLength(from: header)
        #expect(length == 100)
    }

    @Test func parseContentLengthReturnsNilForMissing() {
        let header = "Content-Type: application/json"
        let length = LSPMessageCodec.parseContentLength(from: header)
        #expect(length == nil)
    }

    @Test func parseContentLengthWithExtraSpaces() {
        let header = "Content-Length:   256  "
        let length = LSPMessageCodec.parseContentLength(from: header)
        #expect(length == 256)
    }

    // MARK: - LSP Position/Range

    @Test func positionEquality() {
        let a = LSPPosition(line: 5, character: 10)
        let b = LSPPosition(line: 5, character: 10)
        let c = LSPPosition(line: 5, character: 11)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func rangeEquality() {
        let range1 = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: 10, character: 5)
        )
        let range2 = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: 10, character: 5)
        )
        #expect(range1 == range2)
    }

    // MARK: - LSP Types Encoding

    @Test func initializeParamsEncodes() throws {
        let params = InitializeParams(rootUri: "file:///test")
        let data = try JSONEncoder().encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["rootUri"] as? String == "file:///test")
        #expect(json?["processId"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))
    }

    @Test func initializeParamsWithNilRoot() throws {
        let params = InitializeParams(rootUri: nil)
        let data = try JSONEncoder().encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // JSONEncoder encodes nil Optional as null, JSONSerialization reads it as NSNull
        // But rootUri may be omitted entirely — either case is valid for LSP
        let hasNullRoot = json?["rootUri"] is NSNull
        let missingRoot = json?["rootUri"] == nil
        #expect(hasNullRoot || missingRoot)
    }

    @Test func textDocumentItemEncodes() throws {
        let item = TextDocumentItem(uri: "file:///test.swift", languageId: "swift", version: 1, text: "import Foundation")
        let data = try JSONEncoder().encode(item)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["uri"] as? String == "file:///test.swift")
        #expect(json?["languageId"] as? String == "swift")
        #expect(json?["version"] as? Int == 1)
        #expect(json?["text"] as? String == "import Foundation")
    }

    @Test func completionParamsEncodes() throws {
        let params = CompletionParams(
            textDocument: TextDocumentIdentifier(uri: "file:///test.swift"),
            position: LSPPosition(line: 5, character: 10)
        )
        let data = try JSONEncoder().encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let textDoc = json?["textDocument"] as? [String: Any]
        let position = json?["position"] as? [String: Any]
        #expect(textDoc?["uri"] as? String == "file:///test.swift")
        #expect(position?["line"] as? Int == 5)
        #expect(position?["character"] as? Int == 10)
    }

    @Test func completionItemDecodes() throws {
        let json = """
        {"label":"print","kind":3,"detail":"func print(_ items: Any...)","insertText":"print($1)"}
        """
        let data = Data(json.utf8)
        let item = try JSONDecoder().decode(CompletionItem.self, from: data)
        #expect(item.label == "print")
        #expect(item.kind == 3)
        #expect(item.detail == "func print(_ items: Any...)")
        #expect(item.insertText == "print($1)")
    }

    @Test func completionItemWithMinimalFields() throws {
        let json = """
        {"label":"myFunction"}
        """
        let data = Data(json.utf8)
        let item = try JSONDecoder().decode(CompletionItem.self, from: data)
        #expect(item.label == "myFunction")
        #expect(item.kind == nil)
        #expect(item.detail == nil)
        #expect(item.insertText == nil)
    }

    @Test func completionItemEquality() {
        let a = CompletionItem(label: "test", kind: 3, detail: "detail")
        let b = CompletionItem(label: "test", kind: 3, detail: "detail")
        let c = CompletionItem(label: "other")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func completionListDecodes() throws {
        let json = """
        {"isIncomplete":false,"items":[{"label":"foo"},{"label":"bar","kind":6}]}
        """
        let data = Data(json.utf8)
        let list = try JSONDecoder().decode(CompletionList.self, from: data)
        #expect(list.isIncomplete == false)
        #expect(list.items.count == 2)
        #expect(list.items[0].label == "foo")
        #expect(list.items[1].label == "bar")
        #expect(list.items[1].kind == 6)
    }

    // MARK: - CompletionItemKind

    @Test func completionItemKindRawValues() {
        #expect(CompletionItemKind.text.rawValue == 1)
        #expect(CompletionItemKind.method.rawValue == 2)
        #expect(CompletionItemKind.function.rawValue == 3)
        #expect(CompletionItemKind.keyword.rawValue == 14)
        #expect(CompletionItemKind.snippet.rawValue == 15)
        #expect(CompletionItemKind.typeParameter.rawValue == 25)
    }

    // MARK: - Content Change Event

    @Test func contentChangeEventEncodes() throws {
        let change = TextDocumentContentChangeEvent(text: "new content")
        let data = try JSONEncoder().encode(change)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["text"] as? String == "new content")
    }

    // MARK: - Versioned Document Identifier

    @Test func versionedDocIdentifierEncodes() throws {
        let doc = VersionedTextDocumentIdentifier(uri: "file:///test.swift", version: 5)
        let data = try JSONEncoder().encode(doc)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["uri"] as? String == "file:///test.swift")
        #expect(json?["version"] as? Int == 5)
    }

    // MARK: - Client Capabilities

    @Test func clientCapabilitiesEncodes() throws {
        let caps = LSPClientCapabilities()
        let data = try JSONEncoder().encode(caps)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let textDoc = json?["textDocument"] as? [String: Any]
        #expect(textDoc != nil)
        let completion = textDoc?["completion"] as? [String: Any]
        #expect(completion != nil)
    }

    @Test func clientCapabilitiesSnippetSupportDefault() throws {
        let caps = LSPClientCapabilities()
        let data = try JSONEncoder().encode(caps)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let textDoc = json?["textDocument"] as? [String: Any]
        let completion = textDoc?["completion"] as? [String: Any]
        let completionItem = completion?["completionItem"] as? [String: Any]
        #expect(completionItem?["snippetSupport"] as? Bool == false)
    }
}
