//
//  LSPCodeActionResponseTests.swift
//  PineTests
//
//  Unit tests for LSPCodeActionResponse — parses arrays of CodeAction and/or
//  bare Command objects, plus null/empty responses.
//

import Foundation
import Testing

@testable import Pine

@Suite("LSPCodeActionResponse Tests")
struct LSPCodeActionResponseTests {

    // MARK: - Array of CodeAction objects

    @Test("Parse array of CodeAction objects")
    func parseCodeActions() {
        let json: [Any] = [
            ["title": "Fix typo", "kind": "quickfix"],
            ["title": "Extract method", "kind": "refactor.extract"]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.actions.count == 2)
        #expect(response.commands.isEmpty)
        #expect(response.count == 2)
    }

    @Test("Parse CodeAction with edit")
    func parseCodeActionWithEdit() {
        let json: [Any] = [
            [
                "title": "Add missing import",
                "kind": "quickfix",
                "edit": [
                    "documentChanges": [
                        [
                            "textDocument": ["uri": "file:///test.swift", "version": 1],
                            "edits": [
                                ["range": ["start": ["line": 0, "character": 0],
                                            "end": ["line": 0, "character": 0]],
                                 "newText": "import Foundation\n"]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.actions.count == 1)
        let action = response.actions[0]
        #expect(action.title == "Add missing import")
        #expect(action.kind == .quickFix)
        #expect(action.edit != nil)
        #expect(action.edit?.operatedFiles.count == 1)
    }

    @Test("Parse CodeAction with isPreferred")
    func parseCodeActionIsPreferred() {
        let json: [Any] = [
            ["title": "Fix all", "kind": "quickfix", "isPreferred": true]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.actions[0].isPreferred)
    }

    @Test("isPreferred defaults to false")
    func isPreferredDefaultsFalse() {
        let json: [Any] = [
            ["title": "Fix", "kind": "quickfix"]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(!response.actions[0].isPreferred)
    }

    @Test("Parse CodeAction with command")
    func parseCodeActionWithCommand() {
        let json: [Any] = [
            [
                "title": "Run formatter",
                "command": ["title": "Format", "command": "swift-format.run"]
            ]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.actions.count == 1)
        #expect(response.actions[0].command != nil)
        #expect(response.actions[0].command?.command == "swift-format.run")
    }

    @Test("isExecutable true when action has edit")
    func isExecutableWithEdit() {
        let json: [Any] = [
            [
                "title": "Fix",
                "edit": ["changes": [:]]
            ]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.actions[0].isExecutable)
    }

    @Test("isExecutable false when no edit and no command")
    func isNotExecutableWithoutEditOrCommand() {
        let json: [Any] = [
            ["title": "Disabled fix"]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(!response.actions[0].isExecutable)
    }

    // MARK: - Bare Command objects

    @Test("Parse array with bare Command objects")
    func parseBareCommands() {
        let json: [Any] = [
            ["title": "Run tests", "command": "test.run"],
            ["title": "Build", "command": "build.run"]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.actions.isEmpty)
        #expect(response.commands.count == 2)
        #expect(response.count == 2)
    }

    @Test("Parse bare Command with arguments")
    func parseBareCommandWithArgs() {
        let json: [Any] = [
            ["title": "Go to", "command": "navigate", "arguments": ["line", 42]]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.commands.count == 1)
        #expect(response.commands[0].arguments != nil)
    }

    // MARK: - Null response

    @Test("Null response produces empty result")
    func nullResponse() {
        let response = LSPCodeActionResponse(result: nil)
        #expect(response.isEmpty)
        #expect(response.actions.isEmpty)
        #expect(response.commands.isEmpty)
        // count is also 0
        #expect(response.isEmpty)
    }

    @Test("Non-array response produces empty result")
    func nonArrayResponse() {
        let response = LSPCodeActionResponse(result: "not an array")
        #expect(response.isEmpty)
    }

    // MARK: - Mixed CodeAction + Command array

    @Test("Parse mixed CodeAction + Command array")
    func parseMixedArray() {
        let json: [Any] = [
            ["title": "Quick fix", "kind": "quickfix", "edit": ["changes": [:]]],
            ["title": "Run tool", "command": "tool.run"],
            ["title": "Refactor", "kind": "refactor", "command": ["title": "Do", "command": "do.refactor"]]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.actions.count == 2)   // first and third are CodeActions
        #expect(response.commands.count == 1)  // second is bare Command
        #expect(response.count == 3)
    }

    @Test("Empty array produces empty result")
    func emptyArray() {
        let response = LSPCodeActionResponse(result: [])
        #expect(response.isEmpty)
    }

    // MARK: - Malformed entries skipped

    @Test("Malformed entries are skipped")
    func malformedEntriesSkipped() {
        let json: [Any] = [
            ["kind": "quickfix"],  // missing title → not a CodeAction, not a Command
            "garbage string",
            ["title": "Valid", "kind": "quickfix"]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.actions.count == 1)
        #expect(response.actions[0].title == "Valid")
    }

    // MARK: - Kind parsing

    @Test("Parse all code action kinds")
    func parseAllKinds() {
        let json: [Any] = [
            ["title": "a", "kind": "quickfix"],
            ["title": "b", "kind": "refactor"],
            ["title": "c", "kind": "refactor.extract"],
            ["title": "d", "kind": "refactor.inline"],
            ["title": "e", "kind": "refactor.rewrite"],
            ["title": "f", "kind": "source"],
            ["title": "g", "kind": "source.organizeImports"],
            ["title": "h", "kind": "source.fixAll"]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.actions.count == 8)
        #expect(response.actions[0].kind == .quickFix)
        #expect(response.actions[1].kind == .refactor)
        #expect(response.actions[2].kind == .refactorExtract)
        #expect(response.actions[3].kind == .refactorInline)
        #expect(response.actions[4].kind == .refactorRewrite)
        #expect(response.actions[5].kind == .source)
        #expect(response.actions[6].kind == .sourceOrganizeImports)
        #expect(response.actions[7].kind == .sourceFixAll)
    }

    @Test("Unknown kind is nil (not an error)")
    func unknownKindNil() {
        let json: [Any] = [
            ["title": "Custom", "kind": "custom.weird.kind"]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.actions.count == 1)
        #expect(response.actions[0].kind == nil)
    }

    @Test("Missing kind is nil")
    func missingKindNil() {
        let json: [Any] = [
            ["title": "No kind", "edit": ["changes": [:]]]
        ]
        let response = LSPCodeActionResponse(result: json)
        #expect(response.actions[0].kind == nil)
    }
}
