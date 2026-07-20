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
                newText: "H"
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
                range: LSPRange(start: LSPPosition(line: 0, character: 6),
                                end: LSPPosition(line: 0, character: 11)),
                newText: "Swift"
            ),
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 0),
                                end: LSPPosition(line: 0, character: 5)),
                newText: "I love"
            ),
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 5),
                                end: LSPPosition(line: 0, character: 6)),
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
                                end: LSPPosition(line: 1, character: 5)),
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

    @Test("Character past its line fails instead of spilling into next line")
    func characterPastLineEnd() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 3),
                            end: LSPPosition(line: 0, character: 3)),
            newText: "x"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "hi\nthere")
        #expect(!result.success)
        #expect(result.newText == nil)
    }

    @Test("Negative line or character fails")
    func negativePosition() {
        let negativeLine = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: -1, character: 0),
                            end: LSPPosition(line: 0, character: 0)),
            newText: "x"
        )
        let negativeCharacter = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: -1),
                            end: LSPPosition(line: 0, character: 0)),
            newText: "x"
        )

        #expect(!WorkspaceEditApplier.applyEdits([negativeLine], to: "hi").success)
        #expect(!WorkspaceEditApplier.applyEdits([negativeCharacter], to: "hi").success)
    }

    @Test("One invalid range rejects the complete edit batch")
    func invalidRangeIsAtomic() {
        let edits = [
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 0),
                                end: LSPPosition(line: 0, character: 5)),
                newText: "changed"
            ),
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 2, character: 0),
                                end: LSPPosition(line: 2, character: 0)),
                newText: "invalid"
            ),
        ]

        let result = WorkspaceEditApplier.applyEdits(edits, to: "hello")
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

    @Test("Insert into an empty document at its only valid position")
    func editEmptyDocument() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0),
                            end: LSPPosition(line: 0, character: 0)),
            newText: "hello"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "")
        #expect(result.success)
        #expect(result.newText == "hello")
    }

    @Test("Empty document rejects positions after line zero character zero")
    func invalidEditInEmptyDocument() {
        let invalidLine = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 1, character: 0),
                            end: LSPPosition(line: 1, character: 0)),
            newText: "x"
        )
        let invalidCharacter = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 1),
                            end: LSPPosition(line: 0, character: 1)),
            newText: "x"
        )

        #expect(!WorkspaceEditApplier.applyEdits([invalidLine], to: "").success)
        #expect(!WorkspaceEditApplier.applyEdits([invalidCharacter], to: "").success)
    }

    @Test("Trailing newline creates one final empty line")
    func editTrailingEmptyLine() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 1, character: 0),
                            end: LSPPosition(line: 1, character: 0)),
            newText: "second"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "first\n")
        #expect(result.success)
        #expect(result.newText == "first\nsecond")
    }

    @Test("Line after a trailing empty line is invalid")
    func editAfterTrailingEmptyLine() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 2, character: 0),
                            end: LSPPosition(line: 2, character: 0)),
            newText: "third"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "first\n")
        #expect(!result.success)
        #expect(result.newText == nil)
    }

    @Test("Ranges use UTF-16 code-unit coordinates")
    func editUTF16Range() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 1),
                            end: LSPPosition(line: 0, character: 3)),
            newText: "🙂"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "A😀B")
        #expect(result.success)
        #expect(result.newText == "A🙂B")
    }

    @Test("Range boundary inside a UTF-16 surrogate pair fails")
    func editInsideSurrogatePair() {
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 2),
                            end: LSPPosition(line: 0, character: 3)),
            newText: "x"
        )
        let result = WorkspaceEditApplier.applyEdits([edit], to: "A😀B")
        #expect(!result.success)
        #expect(result.newText == nil)
    }

    @Test("Overlapping replacement ranges reject the complete batch")
    func overlappingReplacementsFailAtomically() {
        let edits = [
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 0),
                                end: LSPPosition(line: 0, character: 3)),
                newText: "first"
            ),
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 2),
                                end: LSPPosition(line: 0, character: 5)),
                newText: "second"
            ),
        ]

        let result = WorkspaceEditApplier.applyEdits(edits, to: "abcdef")
        #expect(!result.success)
        #expect(result.newText == nil)
    }

    @Test("Insertion strictly inside a replacement range fails")
    func insertionInsideReplacementFails() {
        let edits = [
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 1),
                                end: LSPPosition(line: 0, character: 4)),
                newText: "X"
            ),
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 2),
                                end: LSPPosition(line: 0, character: 2)),
                newText: "inside"
            ),
        ]

        let result = WorkspaceEditApplier.applyEdits(edits, to: "abcdef")
        #expect(!result.success)
        #expect(result.newText == nil)
    }

    @Test("Insertions at replacement boundaries remain valid")
    func insertionsAtReplacementBoundaries() {
        let edits = [
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 1),
                                end: LSPPosition(line: 0, character: 1)),
                newText: "["
            ),
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 1),
                                end: LSPPosition(line: 0, character: 2)),
                newText: "X"
            ),
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 2),
                                end: LSPPosition(line: 0, character: 2)),
                newText: "]"
            ),
        ]

        let result = WorkspaceEditApplier.applyEdits(edits, to: "abc")
        #expect(result.success)
        #expect(result.newText == "a[X]c")
    }

    @Test("Insertions at the same position preserve server order")
    func samePositionInsertionsPreserveOrder() {
        let edits = ["A", "B", "C"].map { newText in
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 1),
                                end: LSPPosition(line: 0, character: 1)),
                newText: newText
            )
        }

        let result = WorkspaceEditApplier.applyEdits(edits, to: "abc")
        #expect(result.success)
        #expect(result.newText == "aABCbc")
    }

    @Test("Large non-conflicting batch applies successfully")
    func largeNonconflictingBatch() {
        let insertion = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0),
                            end: LSPPosition(line: 0, character: 0)),
            newText: ""
        )
        var edits = Array(repeating: insertion, count: 10_000)
        edits.append(
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 0),
                                end: LSPPosition(line: 0, character: 1)),
                newText: "B"
            )
        )

        let result = WorkspaceEditApplier.applyEdits(edits, to: "a")
        #expect(result.success)
        #expect(result.newText == "B")
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
