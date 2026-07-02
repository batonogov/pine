//
//  WorkspaceEditApplierTests.swift
//  PineTests
//
//  Unit tests for WorkspaceEditApplier — pure logic that applies a list of
//  LSPTextEdit values to a text string in reverse position order.
//

import Foundation
import Testing

@testable import Pine

@Suite("WorkspaceEditApplier Tests")
struct WorkspaceEditApplierTests {

    // MARK: - Single edit

    @Test("Apply single edit replaces range")
    func applySingleEdit() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0),
                            end: LSPPosition(line: 0, character: 5)),
            newText: "world"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "hello world")
        #expect(result.success)
        #expect(result.newText == "world world")
    }

    @Test("Apply single edit inserting text at position")
    func applyInsertionEdit() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 5),
                            end: LSPPosition(line: 0, character: 5)),
            newText: " beautiful"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "hello world")
        #expect(result.success)
        #expect(result.newText == "hello beautiful world")
    }

    @Test("Apply single edit deleting range")
    func applyDeletionEdit() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 5),
                            end: LSPPosition(line: 0, character: 11)),
            newText: ""
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "hello world")
        #expect(result.success)
        #expect(result.newText == "hello")
    }

    // MARK: - Multiple non-overlapping edits (reverse order)

    @Test("Apply multiple non-overlapping edits")
    func applyMultipleEdits() {
        let edits = [
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 0),
                                end: LSPPosition(line: 0, character: 1)),
                newText: "W"
            ),
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 6),
                                end: LSPPosition(line: 0, character: 11)),
                newText: "there"
            ),
        ]
        let result = WorkspaceEditApplier.applyEdits(edits, to: "hello world")
        #expect(result.success)
        #expect(result.newText == "Hello there")
    }

    @Test("Apply three edits in jumbled order")
    func applyThreeEditsJumbled() {
        let edits = [
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 7),
                                end: LSPPosition(line: 0, character: 12)),
                newText: "Swift"
            ),
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 0),
                                end: LSPPosition(line: 0, character: 5)),
                newText: "I love"
            ),
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 5),
                                end: LSPPosition(line: 0, character: 7)),
                newText: " "
            ),
        ]
        // "hello world" → "I love Swift"
        let result = WorkspaceEditApplier.applyEdits(edits, to: "hello world")
        #expect(result.success)
        #expect(result.newText == "I love Swift")
    }

    @Test("Apply edits across multiple lines")
    func applyEditsMultipleLines() {
        let edits = [
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 0),
                                end: LSPPosition(line: 0, character: 5)),
                newText: "first"
            ),
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 1, character: 0),
                                end: LSPPosition(line: 1, character: 6)),
                newText: "second"
            ),
        ]
        let result = WorkspaceEditApplier.applyEdits(edits, to: "hello\nworld!")
        #expect(result.success)
        #expect(result.newText == "first\nsecond!")
    }

    // MARK: - Out-of-bounds range → failure

    @Test("Out-of-bounds end position fails")
    func outOfBoundsEnd() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0),
                            end: LSPPosition(line: 0, character: 100)),
            newText: "x"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "hello")
        #expect(!result.success)
        #expect(result.newText == nil)
        #expect(result.errorMessage != nil)
    }

    @Test("Out-of-bounds line fails")
    func outOfBoundsLine() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 5, character: 0),
                            end: LSPPosition(line: 5, character: 3)),
            newText: "x"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "hello")
        #expect(!result.success)
        #expect(result.newText == nil)
    }

    @Test("Reversed range (end < start) fails")
    func reversedRange() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 5),
                            end: LSPPosition(line: 0, character: 0)),
            newText: "x"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "hello")
        #expect(!result.success)
    }

    // MARK: - Empty edits list

    @Test("Empty edits list returns original text unchanged")
    func emptyEditsList() {
        let original = "hello world"
        let result = WorkspaceEditApplier.applyEdits([], to: original)
        #expect(result.success)
        #expect(result.newText == original)
    }

    // MARK: - Edge cases

    @Test("Edit at end of string")
    func editAtEnd() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 5),
                            end: LSPPosition(line: 0, character: 5)),
            newText: "!"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "hello")
        #expect(result.success)
        #expect(result.newText == "hello!")
    }

    @Test("Edit replacing entire single line")
    func editReplaceEntireLine() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0),
                            end: LSPPosition(line: 0, character: 5)),
            newText: "replaced"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "hello")
        #expect(result.success)
        #expect(result.newText == "replaced")
    }

    @Test("Edit with multi-line replacement")
    func editMultiLineReplacement() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0),
                            end: LSPPosition(line: 0, character: 5)),
            newText: "line1\nline2"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "hello world")
        #expect(result.success)
        #expect(result.newText == "line1\nline2 world")
    }

    // MARK: - editPlan helper

    @Test("editPlan extracts edit-only operations sorted by URL")
    func editPlanFiltersNonEdits() {
        let editFile = LSPOperatedFile(
            uri: "file:///b.swift", kind: .edit,
            edits: [LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 0),
                                                end: LSPPosition(line: 0, character: 1)),
                                newText: "x")]
        )
        let createFile = LSPOperatedFile(uri: "file:///a.txt", kind: .create)
        let renameFile = LSPOperatedFile(uri: "file:///c.txt", kind: .rename, newURI: "file:///d.txt")

        let workspaceEdit = LSPWorkspaceEdit(operatedFiles: [editFile, createFile, renameFile])
        let plan = WorkspaceEditApplier.editPlan(from: workspaceEdit)
        #expect(plan.count == 1)
        #expect(plan[0].url.path == "/b.swift")
    }
}
