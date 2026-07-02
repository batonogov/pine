//
//  LSPWorkspaceEditTests.swift
//  PineTests
//
//  Unit tests for LSPWorkspaceEdit — parses documentChanges and legacy
//  changes forms, plus CreateFile/RenameFile/DeleteFile operations.
//

import Foundation
import Testing

@testable import Pine

@Suite("LSPWorkspaceEdit Tests")
struct LSPWorkspaceEditTests {

    // MARK: - documentChanges (TextDocumentEdit)

    @Test("Parse documentChanges with TextDocumentEdit")
    func parseDocumentChanges() {
        let json: [String: Any] = [
            "documentChanges": [
                [
                    "textDocument": ["uri": "file:///test.swift", "version": 1],
                    "edits": [
                        ["range": ["start": ["line": 0, "character": 0],
                                    "end": ["line": 0, "character": 5]],
                         "newText": "world"]
                    ]
                ]
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(!edit.isEmpty)
        #expect(edit.operatedFiles.count == 1)
        #expect(edit.operatedFiles[0].uri == "file:///test.swift")
        #expect(edit.operatedFiles[0].kind == .edit)
        #expect(edit.operatedFiles[0].edits.count == 1)
        #expect(edit.operatedFiles[0].edits[0].newText == "world")
    }

    @Test("Parse multiple TextDocumentEdits")
    func parseMultipleDocumentChanges() {
        let json: [String: Any] = [
            "documentChanges": [
                [
                    "textDocument": ["uri": "file:///a.swift", "version": 1],
                    "edits": [
                        ["range": ["start": ["line": 0, "character": 0],
                                    "end": ["line": 0, "character": 1]],
                         "newText": "A"]
                    ]
                ],
                [
                    "textDocument": ["uri": "file:///b.swift", "version": 1],
                    "edits": [
                        ["range": ["start": ["line": 0, "character": 0],
                                    "end": ["line": 0, "character": 1]],
                         "newText": "B"]
                    ]
                ]
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(edit.operatedFiles.count == 2)
        #expect(edit.totalTextEditCount == 2)
    }

    // MARK: - Legacy changes ({uri: [TextEdit]})

    @Test("Parse legacy changes dictionary")
    func parseLegacyChanges() {
        let json: [String: Any] = [
            "changes": [
                "file:///test.swift": [
                    ["range": ["start": ["line": 0, "character": 0],
                               "end": ["line": 0, "character": 5]],
                     "newText": "world"]
                ]
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(!edit.isEmpty)
        #expect(edit.operatedFiles.count == 1)
        #expect(edit.operatedFiles[0].uri == "file:///test.swift")
        #expect(edit.operatedFiles[0].kind == .edit)
        #expect(edit.operatedFiles[0].edits.count == 1)
    }

    @Test("Parse legacy changes with multiple files")
    func parseLegacyChangesMultipleFiles() {
        let json: [String: Any] = [
            "changes": [
                "file:///a.swift": [
                    ["range": ["start": ["line": 0, "character": 0],
                               "end": ["line": 0, "character": 1]],
                     "newText": "A"]
                ],
                "file:///b.swift": [
                    ["range": ["start": ["line": 0, "character": 0],
                               "end": ["line": 0, "character": 1]],
                     "newText": "B"]
                ]
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(edit.operatedFiles.count == 2)
    }

    @Test("documentChanges preferred over legacy changes")
    func documentChangesPreferred() {
        let json: [String: Any] = [
            "documentChanges": [
                [
                    "textDocument": ["uri": "file:///modern.swift", "version": 1],
                    "edits": []
                ]
            ],
            "changes": [
                "file:///legacy.swift": []
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(edit.operatedFiles.count == 1)
        #expect(edit.operatedFiles[0].uri == "file:///modern.swift")
    }

    // MARK: - Empty / null response

    @Test("Empty dictionary produces empty edit")
    func emptyDictionary() {
        let edit = LSPWorkspaceEdit(json: [:])
        #expect(edit.isEmpty)
        #expect(edit.operatedFiles.isEmpty)
    }

    @Test("Dictionary with empty documentChanges produces empty edit")
    func emptyDocumentChanges() {
        let edit = LSPWorkspaceEdit(json: ["documentChanges": []])
        #expect(edit.isEmpty)
    }

    @Test("Dictionary with empty changes produces empty edit")
    func emptyChanges() {
        let edit = LSPWorkspaceEdit(json: ["changes": [:]])
        #expect(edit.isEmpty)
    }

    @Test("Non-dictionary input produces empty edit")
    func nonDictionaryInput() {
        let edit = LSPWorkspaceEdit(json: "not a dict")
        #expect(edit.isEmpty)
    }

    // MARK: - CreateFile

    @Test("Parse CreateFile operation")
    func parseCreateFile() {
        let json: [String: Any] = [
            "documentChanges": [
                ["kind": "create", "uri": "file:///new.swift"]
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(edit.operatedFiles.count == 1)
        let file = edit.operatedFiles[0]
        #expect(file.kind == .create)
        #expect(file.uri == "file:///new.swift")
        #expect(file.edits.isEmpty)
    }

    // MARK: - RenameFile

    @Test("Parse RenameFile operation")
    func parseRenameFile() {
        let json: [String: Any] = [
            "documentChanges": [
                ["kind": "rename", "oldUri": "file:///old.swift", "newUri": "file:///new.swift"]
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(edit.operatedFiles.count == 1)
        let file = edit.operatedFiles[0]
        #expect(file.kind == .rename)
        #expect(file.uri == "file:///old.swift")
        #expect(file.newURI == "file:///new.swift")
        #expect(file.edits.isEmpty)
    }

    // MARK: - DeleteFile

    @Test("Parse DeleteFile operation")
    func parseDeleteFile() {
        let json: [String: Any] = [
            "documentChanges": [
                ["kind": "delete", "uri": "file:///gone.swift"]
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(edit.operatedFiles.count == 1)
        let file = edit.operatedFiles[0]
        #expect(file.kind == .delete)
        #expect(file.uri == "file:///gone.swift")
        #expect(file.edits.isEmpty)
    }

    // MARK: - Mixed operations

    @Test("Parse mixed documentChanges (edit + create + rename + delete)")
    func parseMixedOperations() {
        let json: [String: Any] = [
            "documentChanges": [
                [
                    "textDocument": ["uri": "file:///edit.swift", "version": 1],
                    "edits": [
                        ["range": ["start": ["line": 0, "character": 0],
                                    "end": ["line": 0, "character": 1]],
                         "newText": "X"]
                    ]
                ],
                ["kind": "create", "uri": "file:///new.swift"],
                ["kind": "rename", "oldUri": "file:///old.swift", "newUri": "file:///renamed.swift"],
                ["kind": "delete", "uri": "file:///trash.swift"]
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(edit.operatedFiles.count == 4)
        #expect(edit.operatedFiles[0].kind == .edit)
        #expect(edit.operatedFiles[1].kind == .create)
        #expect(edit.operatedFiles[2].kind == .rename)
        #expect(edit.operatedFiles[3].kind == .delete)
    }

    // MARK: - Convenience properties

    @Test("totalTextEditCount counts edits across files")
    func totalTextEditCount() {
        let json: [String: Any] = [
            "documentChanges": [
                [
                    "textDocument": ["uri": "file:///a.swift", "version": 1],
                    "edits": [
                        ["range": ["start": ["line": 0, "character": 0],
                                    "end": ["line": 0, "character": 1]],
                         "newText": "A"],
                        ["range": ["start": ["line": 1, "character": 0],
                                    "end": ["line": 1, "character": 1]],
                         "newText": "B"]
                    ]
                ],
                ["kind": "create", "uri": "file:///b.swift"]
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(edit.totalTextEditCount == 2)  // create has 0 edits
    }

    // MARK: - URL decoding

    @Test("File URL decoded from URI")
    func urlDecoding() {
        let json: [String: Any] = [
            "documentChanges": [
                ["kind": "create", "uri": "file:///path/to/file.swift"]
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(edit.operatedFiles[0].url?.path == "/path/to/file.swift")
    }

    @Test("New URL decoded for rename")
    func newURLDecoding() {
        let json: [String: Any] = [
            "documentChanges": [
                ["kind": "rename", "oldUri": "file:///old.swift", "newUri": "file:///new.swift"]
            ]
        ]
        let edit = LSPWorkspaceEdit(json: json)
        #expect(edit.operatedFiles[0].newURL?.path == "/new.swift")
    }
}
