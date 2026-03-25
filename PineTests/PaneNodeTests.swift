//
//  PaneNodeTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("PaneNode Tests")
struct PaneNodeTests {

    // MARK: - Basic construction

    @Test func singleLeaf_hasOneLeaf_depthOne() {
        let node = PaneNode.leaf(PaneID(), .editor)
        #expect(node.leafCount == 1)
        #expect(node.depth == 1)
    }

    @Test func splitNode_hasTwoLeaves_depthTwo() {
        let node = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.5
        )
        #expect(node.leafCount == 2)
        #expect(node.depth == 2)
    }

    @Test func nestedSplit_hasCorrectLeafCountAndDepth() {
        let inner = PaneNode.split(
            .vertical,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .editor),
            ratio: 0.5
        )
        let outer = PaneNode.split(
            .horizontal,
            first: inner,
            second: .leaf(PaneID(), .terminal),
            ratio: 0.6
        )
        #expect(outer.leafCount == 3)
        #expect(outer.depth == 3)
    }

    // MARK: - Tree queries

    @Test func leafIDs_returnsAllLeavesInOrder() {
        let id1 = PaneID()
        let id2 = PaneID()
        let id3 = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id1, .editor),
            second: .split(
                .vertical,
                first: .leaf(id2, .terminal),
                second: .leaf(id3, .editor),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        let ids = tree.leafIDs
        #expect(ids.count == 3)
        #expect(ids[0] == id1)
        #expect(ids[1] == id2)
        #expect(ids[2] == id3)
    }

    @Test func firstLeafID_returnsLeftmostLeaf() {
        let id1 = PaneID()
        let id2 = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id1, .editor),
            second: .leaf(id2, .terminal),
            ratio: 0.5
        )
        #expect(tree.firstLeafID == id1)
    }

    @Test func firstLeafID_singleLeaf() {
        let id = PaneID()
        let node = PaneNode.leaf(id, .editor)
        #expect(node.firstLeafID == id)
    }

    @Test func contains_trueForExistingID() {
        let id = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(id, .terminal),
            ratio: 0.5
        )
        #expect(tree.contains(id))
    }

    @Test func contains_falseForUnknownID() {
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.5
        )
        #expect(!tree.contains(PaneID()))
    }

    @Test func content_returnsCorrectType() {
        let editorID = PaneID()
        let terminalID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(editorID, .editor),
            second: .leaf(terminalID, .terminal),
            ratio: 0.5
        )
        #expect(tree.content(for: editorID) == .editor)
        #expect(tree.content(for: terminalID) == .terminal)
    }

    @Test func content_returnsNilForUnknownID() {
        let tree = PaneNode.leaf(PaneID(), .editor)
        #expect(tree.content(for: PaneID()) == nil)
    }

    // MARK: - Splitting

    @Test func splitting_leafCreatesNewSplit() {
        let id = PaneID()
        let newID = PaneID()
        let leaf = PaneNode.leaf(id, .editor)

        let result = leaf.splitting(id, axis: .horizontal, newPaneID: newID, newContent: .terminal)
        #expect(result != nil)
        #expect(result?.leafCount == 2)
        #expect(result?.contains(id) == true)
        #expect(result?.contains(newID) == true)
    }

    @Test func splitting_preservesOriginalContent() {
        let id = PaneID()
        let newID = PaneID()
        let leaf = PaneNode.leaf(id, .editor)

        let result = leaf.splitting(id, axis: .vertical, newPaneID: newID, newContent: .terminal)
        #expect(result?.content(for: id) == .editor)
        #expect(result?.content(for: newID) == .terminal)
    }

    @Test func splitting_unknownID_returnsNil() {
        let leaf = PaneNode.leaf(PaneID(), .editor)
        let result = leaf.splitting(PaneID(), axis: .horizontal, newPaneID: PaneID(), newContent: .terminal)
        #expect(result == nil)
    }

    @Test func splitting_deepInNestedTree() {
        let targetID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .split(
                .vertical,
                first: .leaf(PaneID(), .editor),
                second: .leaf(targetID, .editor),
                ratio: 0.5
            ),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.5
        )

        let newID = PaneID()
        let result = tree.splitting(targetID, axis: .horizontal, newPaneID: newID, newContent: .terminal)
        #expect(result != nil)
        #expect(result?.leafCount == 4)
        #expect(result?.contains(targetID) == true)
        #expect(result?.contains(newID) == true)
    }

    @Test func splitting_customRatio() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        let result = leaf.splitting(id, axis: .horizontal, newPaneID: PaneID(), newContent: .terminal, ratio: 0.7)
        if case .split(_, _, _, let ratio) = result {
            #expect(ratio == 0.7)
        } else {
            Issue.record("Expected split node")
        }
    }

    // MARK: - Removing

    @Test func removing_fromSplit_promotesSibling() {
        let keep = PaneID()
        let remove = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(keep, .editor),
            second: .leaf(remove, .terminal),
            ratio: 0.5
        )

        let result = tree.removing(remove)
        #expect(result != nil)
        #expect(result?.leafCount == 1)
        #expect(result?.contains(keep) == true)
        #expect(result?.contains(remove) == false)
    }

    @Test func removing_singleLeaf_returnsNil() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        #expect(leaf.removing(id) == nil)
    }

    @Test func removing_deepInNestedTree() {
        let removeID = PaneID()
        let siblingID = PaneID()
        let otherID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .split(
                .vertical,
                first: .leaf(siblingID, .editor),
                second: .leaf(removeID, .editor),
                ratio: 0.5
            ),
            second: .leaf(otherID, .terminal),
            ratio: 0.5
        )

        let result = tree.removing(removeID)
        #expect(result != nil)
        #expect(result?.leafCount == 2)
        #expect(result?.contains(siblingID) == true)
        #expect(result?.contains(otherID) == true)
        #expect(result?.contains(removeID) == false)
    }

    @Test func removing_unknownID_returnsNil() {
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.5
        )
        #expect(tree.removing(PaneID()) == nil)
    }

    @Test func removing_promotesFirstChild() {
        let keep = PaneID()
        let remove = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(keep, .editor),
            second: .leaf(remove, .terminal),
            ratio: 0.5
        )
        let result = tree.removing(remove)
        if case .leaf(let id, let content) = result {
            #expect(id == keep)
            #expect(content == .editor)
        } else {
            Issue.record("Expected leaf node after removing sibling")
        }
    }

    // MARK: - Updating ratio

    @Test func updatingRatio_changesCorrectSplit() {
        let id1 = PaneID()
        let id2 = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id1, .editor),
            second: .leaf(id2, .terminal),
            ratio: 0.5
        )

        let result = tree.updatingRatio(for: id1, ratio: 0.7)
        if case .split(_, _, _, let ratio) = result {
            #expect(ratio == 0.7)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func updatingRatio_unknownID_returnsNil() {
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.5
        )
        #expect(tree.updatingRatio(for: PaneID(), ratio: 0.7) == nil)
    }

    @Test func updatingRatio_onLeaf_returnsNil() {
        let leaf = PaneNode.leaf(PaneID(), .editor)
        #expect(leaf.updatingRatio(for: PaneID(), ratio: 0.7) == nil)
    }

    @Test func updatingRatio_clampsToMinimum() {
        let id = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id, .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.5
        )
        let result = tree.updatingRatio(for: id, ratio: 0.0)
        if case .split(_, _, _, let ratio) = result {
            #expect(ratio == 0.1)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func updatingRatio_clampsToMaximum() {
        let id = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id, .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.5
        )
        let result = tree.updatingRatio(for: id, ratio: 1.0)
        if case .split(_, _, _, let ratio) = result {
            #expect(ratio == 0.9)
        } else {
            Issue.record("Expected split node")
        }
    }

    // MARK: - Codable

    @Test func codable_singleLeaf() throws {
        let id = PaneID()
        let node = PaneNode.leaf(id, .editor)
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
        #expect(decoded == node)
    }

    @Test func codable_splitWithTwoLeaves() throws {
        let node = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.6
        )
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
        #expect(decoded == node)
    }

    @Test func codable_deeplyNestedTree() throws {
        let node = PaneNode.split(
            .horizontal,
            first: .split(
                .vertical,
                first: .leaf(PaneID(), .editor),
                second: .split(
                    .horizontal,
                    first: .leaf(PaneID(), .terminal),
                    second: .leaf(PaneID(), .editor),
                    ratio: 0.3
                ),
                ratio: 0.5
            ),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.7
        )
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
        #expect(decoded == node)
    }

    @Test func codable_roundTripPreservesEquality() throws {
        let id1 = PaneID()
        let id2 = PaneID()
        let original = PaneNode.split(
            .vertical,
            first: .leaf(id1, .terminal),
            second: .leaf(id2, .editor),
            ratio: 0.4
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
        #expect(original == decoded)
        // Verify specific IDs survived round-trip
        #expect(decoded.contains(id1))
        #expect(decoded.contains(id2))
    }

    // MARK: - Edge cases

    @Test func split_withRatioZero() {
        let node = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.0
        )
        #expect(node.leafCount == 2)
    }

    @Test func split_withRatioOne() {
        let node = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 1.0
        )
        #expect(node.leafCount == 2)
    }

    @Test func veryDeepTree_tenLevels() {
        var node = PaneNode.leaf(PaneID(), .editor)
        for _ in 0..<9 {
            node = .split(.horizontal, first: node, second: .leaf(PaneID(), .editor), ratio: 0.5)
        }
        #expect(node.depth == 10)
        #expect(node.leafCount == 10)
    }

    @Test func allEditorLeaves() {
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .split(
                .vertical,
                first: .leaf(PaneID(), .editor),
                second: .leaf(PaneID(), .editor),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        let allEditor = tree.leafIDs.allSatisfy { tree.content(for: $0) == .editor }
        #expect(allEditor)
    }

    @Test func mixedEditorAndTerminalLeaves() {
        let editorID = PaneID()
        let terminalID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(editorID, .editor),
            second: .leaf(terminalID, .terminal),
            ratio: 0.5
        )
        #expect(tree.content(for: editorID) == .editor)
        #expect(tree.content(for: terminalID) == .terminal)
    }

    @Test func paneID_equalityAndHashing() {
        let uuid = UUID()
        let id1 = PaneID(id: uuid)
        let id2 = PaneID(id: uuid)
        #expect(id1 == id2)
        #expect(id1.hashValue == id2.hashValue)
    }

    @Test func paneID_twoNewIDsAreNeverEqual() {
        let id1 = PaneID()
        let id2 = PaneID()
        #expect(id1 != id2)
    }

    // MARK: - Negative cases

    @Test func splitting_nonExistentID_returnsNil() {
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.5
        )
        #expect(tree.splitting(PaneID(), axis: .vertical, newPaneID: PaneID(), newContent: .editor) == nil)
    }

    @Test func removing_nonExistentID_returnsNil() {
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.5
        )
        #expect(tree.removing(PaneID()) == nil)
    }

    @Test func removing_theOnlyLeaf_returnsNil() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        #expect(leaf.removing(id) == nil)
    }

    @Test func updatingRatio_onLeafNode_returnsNil() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        #expect(leaf.updatingRatio(for: id, ratio: 0.5) == nil)
    }

    // MARK: - Additional edge cases

    @Test func splitting_doesNotPreventDuplicatePaneID() {
        // Splitting with a PaneID that already exists in the tree is allowed
        // (the caller is responsible for providing unique IDs)
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        let result = leaf.splitting(id, axis: .horizontal, newPaneID: id, newContent: .terminal)
        #expect(result != nil)
        // Tree has two leaves with the same ID — leafCount should still be 2
        #expect(result?.leafCount == 2)
    }

    @Test func removing_firstChild_promotesSecond() {
        let remove = PaneID()
        let keep = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(remove, .editor),
            second: .leaf(keep, .terminal),
            ratio: 0.5
        )
        let result = tree.removing(remove)
        if case .leaf(let id, let content) = result {
            #expect(id == keep)
            #expect(content == .terminal)
        } else {
            Issue.record("Expected leaf node after removing first child")
        }
    }

    @Test func updatingRatio_withNegativeValue_clampsToMinimum() {
        let id = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id, .editor),
            second: .leaf(PaneID(), .terminal),
            ratio: 0.5
        )
        let result = tree.updatingRatio(for: id, ratio: -0.5)
        if case .split(_, _, _, let ratio) = result {
            #expect(ratio == 0.1)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func codable_decodingInvalidJSON_throws() {
        let invalidJSON = Data(#"{"type":"unknown"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PaneNode.self, from: invalidJSON)
        }
    }

    @Test func codable_decodingEmptyJSON_throws() {
        let emptyJSON = Data("{}".utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PaneNode.self, from: emptyJSON)
        }
    }
}
