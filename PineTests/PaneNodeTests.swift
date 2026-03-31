//
//  PaneNodeTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

// swiftlint:disable type_body_length file_length

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
            second: .leaf(PaneID(), .editor),
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
            second: .leaf(PaneID(), .editor),
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
                first: .leaf(id2, .editor),
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
            second: .leaf(id2, .editor),
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
            second: .leaf(id, .editor),
            ratio: 0.5
        )
        #expect(tree.contains(id))
    }

    @Test func contains_falseForUnknownID() {
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .editor),
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
            second: .leaf(terminalID, .editor),
            ratio: 0.5
        )
        #expect(tree.content(for: editorID) == .editor)
        #expect(tree.content(for: terminalID) == .editor)
    }

    @Test func content_returnsNilForUnknownID() {
        let tree = PaneNode.leaf(PaneID(), .editor)
        #expect(tree.content(for: PaneID()) == nil)
    }

    @Test func allIDs_returnsSetOfAllLeafIDs() {
        let id1 = PaneID()
        let id2 = PaneID()
        let id3 = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id1, .editor),
            second: .split(.vertical, first: .leaf(id2, .editor), second: .leaf(id3, .editor), ratio: 0.5),
            ratio: 0.5
        )
        let ids = tree.allIDs
        #expect(ids.count == 3)
        #expect(ids.contains(id1))
        #expect(ids.contains(id2))
        #expect(ids.contains(id3))
    }

    // MARK: - Splitting

    @Test func splitting_leafCreatesNewSplit() {
        let id = PaneID()
        let newID = PaneID()
        let leaf = PaneNode.leaf(id, .editor)

        let result = leaf.splitting(id, axis: .horizontal, newPaneID: newID, newContent: .editor)
        #expect(result != nil)
        #expect(result?.leafCount == 2)
        #expect(result?.contains(id) == true)
        #expect(result?.contains(newID) == true)
    }

    @Test func splitting_preservesOriginalContent() {
        let id = PaneID()
        let newID = PaneID()
        let leaf = PaneNode.leaf(id, .editor)

        let result = leaf.splitting(id, axis: .vertical, newPaneID: newID, newContent: .editor)
        #expect(result?.content(for: id) == .editor)
        #expect(result?.content(for: newID) == .editor)
    }

    @Test func splitting_unknownID_returnsNil() {
        let leaf = PaneNode.leaf(PaneID(), .editor)
        let result = leaf.splitting(PaneID(), axis: .horizontal, newPaneID: PaneID(), newContent: .editor)
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
            second: .leaf(PaneID(), .editor),
            ratio: 0.5
        )

        let newID = PaneID()
        let result = tree.splitting(targetID, axis: .horizontal, newPaneID: newID, newContent: .editor)
        #expect(result != nil)
        #expect(result?.leafCount == 4)
        #expect(result?.contains(targetID) == true)
        #expect(result?.contains(newID) == true)
    }

    @Test func splitting_customRatio() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        let result = leaf.splitting(id, axis: .horizontal, newPaneID: PaneID(), newContent: .editor, ratio: 0.7)
        if case .split(_, _, _, let ratio) = result {
            #expect(ratio == 0.7)
        } else {
            Issue.record("Expected split node")
        }
    }

    // MARK: - Splitting — duplicate ID rejection (К3)

    @Test func splitting_duplicateID_returnsNil() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        let result = leaf.splitting(id, axis: .horizontal, newPaneID: id, newContent: .editor)
        #expect(result == nil)
    }

    @Test func splitting_duplicateIDInDeepTree_returnsNil() {
        let existingID = PaneID()
        let targetID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(existingID, .editor),
            second: .leaf(targetID, .editor),
            ratio: 0.5
        )
        // Try to split targetID using existingID as newPaneID — should fail
        let result = tree.splitting(targetID, axis: .vertical, newPaneID: existingID, newContent: .editor)
        #expect(result == nil)
    }

    // MARK: - Splitting — maxDepth enforcement (С2)

    @Test func splitting_atMaxDepth_returnsNil() {
        // Build a tree at exactly paneMaxDepth
        var node = PaneNode.leaf(PaneID(), .editor)
        for _ in 1..<paneMaxDepth {
            node = .split(.horizontal, first: node, second: .leaf(PaneID(), .editor), ratio: 0.5)
        }
        #expect(node.depth == paneMaxDepth)

        // Trying to split further should fail
        guard let deepLeaf = node.leafIDs.last else {
            Issue.record("Expected at least one leaf")
            return
        }
        let result = node.splitting(deepLeaf, axis: .vertical, newPaneID: PaneID(), newContent: .editor)
        #expect(result == nil)
    }

    @Test func splitting_belowMaxDepth_succeeds() {
        var node = PaneNode.leaf(PaneID(), .editor)
        for _ in 1..<(paneMaxDepth - 1) {
            node = .split(.horizontal, first: node, second: .leaf(PaneID(), .editor), ratio: 0.5)
        }
        #expect(node.depth == paneMaxDepth - 1)

        // Split the shallowest leaf (depth 1 from its parent) — result depth = current + 1
        guard let shallowLeaf = node.leafIDs.last else {
            Issue.record("Expected at least one leaf")
            return
        }
        let result = node.splitting(shallowLeaf, axis: .vertical, newPaneID: PaneID(), newContent: .editor)
        #expect(result != nil)
    }

    // MARK: - Removing

    @Test func removing_fromSplit_promotesSibling() {
        let keep = PaneID()
        let remove = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(keep, .editor),
            second: .leaf(remove, .editor),
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
            second: .leaf(otherID, .editor),
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
            second: .leaf(PaneID(), .editor),
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
            second: .leaf(remove, .editor),
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
            second: .leaf(id2, .editor),
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
            second: .leaf(PaneID(), .editor),
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
            second: .leaf(PaneID(), .editor),
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
            second: .leaf(PaneID(), .editor),
            ratio: 0.5
        )
        let result = tree.updatingRatio(for: id, ratio: 1.0)
        if case .split(_, _, _, let ratio) = result {
            #expect(ratio == 0.9)
        } else {
            Issue.record("Expected split node")
        }
    }

    // MARK: - updatingRatio with split-split children (К1)

    @Test func updatingRatio_splitWithTwoSplitChildren_updatesInnerRatio() {
        let idA = PaneID()
        let idB = PaneID()
        let idC = PaneID()
        let idD = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .split(.vertical, first: .leaf(idA, .editor), second: .leaf(idB, .editor), ratio: 0.5),
            second: .split(.vertical, first: .leaf(idC, .editor), second: .leaf(idD, .editor), ratio: 0.5),
            ratio: 0.5
        )

        // updatingRatio(for: idA) should update the inner-left split's ratio
        let result = tree.updatingRatio(for: idA, ratio: 0.7)
        #expect(result != nil)

        // Root ratio should be unchanged
        if case .split(_, let first, _, let rootRatio) = result {
            #expect(abs(rootRatio - 0.5) < 1e-6)
            // Inner split ratio should be updated
            if case .split(_, _, _, let innerRatio) = first {
                #expect(abs(innerRatio - 0.7) < 1e-6)
            } else {
                Issue.record("Expected inner split")
            }
        } else {
            Issue.record("Expected split node")
        }
    }

    // MARK: - updatingRatioOfSplit (К1 — resize between split subtrees)

    @Test func updatingRatioOfSplit_betweenTwoSplitChildren() {
        let idA = PaneID()
        let idB = PaneID()
        let idC = PaneID()
        let idD = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .split(.vertical, first: .leaf(idA, .editor), second: .leaf(idB, .editor), ratio: 0.5),
            second: .split(.vertical, first: .leaf(idC, .editor), second: .leaf(idD, .editor), ratio: 0.5),
            ratio: 0.5
        )

        // Using any leaf from either subtree should update root's ratio
        let result = tree.updatingRatioOfSplit(containing: idA, ratio: 0.7)
        #expect(result != nil)
        if case .split(_, _, _, let rootRatio) = result {
            #expect(abs(rootRatio - 0.7) < 1e-6)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func updatingRatioOfSplit_directLeafChild_returnsNil() {
        let id = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id, .editor),
            second: .leaf(PaneID(), .editor),
            ratio: 0.5
        )
        // Direct leaf children should return nil — use updatingRatio instead
        #expect(tree.updatingRatioOfSplit(containing: id, ratio: 0.7) == nil)
    }

    @Test func updatingRatioOfSplit_unknownID_returnsNil() {
        let tree = PaneNode.split(
            .horizontal,
            first: .split(.vertical, first: .leaf(PaneID(), .editor), second: .leaf(PaneID(), .editor), ratio: 0.5),
            second: .leaf(PaneID(), .editor),
            ratio: 0.5
        )
        #expect(tree.updatingRatioOfSplit(containing: PaneID(), ratio: 0.7) == nil)
    }

    @Test func updatingRatioOfSplit_clampsRatio() {
        let id = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .split(.vertical, first: .leaf(id, .editor), second: .leaf(PaneID(), .editor), ratio: 0.5),
            second: .leaf(PaneID(), .editor),
            ratio: 0.5
        )
        let result = tree.updatingRatioOfSplit(containing: id, ratio: 0.0)
        if case .split(_, _, _, let ratio) = result {
            #expect(abs(ratio - 0.1) < 1e-6)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func updatingRatioOfSplit_deeplyNestedLeaf_updatesCorrectLevel() {
        // 3-level tree: root splits into (left-split, right-leaf)
        // left-split splits into (inner-split, leafB)
        // inner-split splits into (leafA, leafC)
        // Target: leafA at depth 3 — should update inner-split's parent ratio
        let leafA = PaneID()
        let leafB = PaneID()
        let leafC = PaneID()
        let leafR = PaneID()
        let innerSplit = PaneNode.split(.horizontal, first: .leaf(leafA, .editor), second: .leaf(leafC, .editor), ratio: 0.5)
        let leftSplit = PaneNode.split(.vertical, first: innerSplit, second: .leaf(leafB, .editor), ratio: 0.4)
        let root = PaneNode.split(.horizontal, first: leftSplit, second: .leaf(leafR, .editor), ratio: 0.6)

        let result = root.updatingRatioOfSplit(containing: leafA, ratio: 0.8)
        // Should update leftSplit's ratio (where innerSplit containing leafA is a direct child)
        // NOT root's ratio
        if case .split(_, let first, _, let rootRatio) = result {
            // Root ratio should be unchanged
            #expect(abs(rootRatio - 0.6) < 1e-6)
            // Left split should have updated ratio
            if case .split(_, _, _, let leftRatio) = first {
                #expect(abs(leftRatio - 0.8) < 1e-6)
            } else {
                Issue.record("Expected left split node")
            }
        } else {
            Issue.record("Expected result")
        }
    }

    // MARK: - Replacing (С3)

    @Test func replacing_leafWithNewLeaf() {
        let id = PaneID()
        let newID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id, .editor),
            second: .leaf(PaneID(), .editor),
            ratio: 0.5
        )
        let result = tree.replacing(id, with: .leaf(newID, .editor))
        #expect(result != nil)
        #expect(result?.contains(newID) == true)
        #expect(result?.contains(id) == false)
        #expect(result?.content(for: newID) == .editor)
    }

    @Test func replacing_leafWithSplit() {
        let id = PaneID()
        let newA = PaneID()
        let newB = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        let replacement = PaneNode.split(.vertical, first: .leaf(newA, .editor), second: .leaf(newB, .editor), ratio: 0.5)
        let result = leaf.replacing(id, with: replacement)
        #expect(result != nil)
        #expect(result?.leafCount == 2)
        #expect(result?.contains(newA) == true)
        #expect(result?.contains(newB) == true)
    }

    @Test func replacing_unknownID_returnsNil() {
        let tree = PaneNode.leaf(PaneID(), .editor)
        #expect(tree.replacing(PaneID(), with: .leaf(PaneID(), .editor)) == nil)
    }

    @Test func replacing_deepInTree() {
        let targetID = PaneID()
        let newID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .split(.vertical, first: .leaf(targetID, .editor), second: .leaf(PaneID(), .editor), ratio: 0.5),
            second: .leaf(PaneID(), .editor),
            ratio: 0.5
        )
        let result = tree.replacing(targetID, with: .leaf(newID, .editor))
        #expect(result != nil)
        #expect(result?.contains(newID) == true)
        #expect(result?.contains(targetID) == false)
    }

    // MARK: - Swapping (С3)

    @Test func swapping_twoLeaves() {
        let idA = PaneID()
        let idB = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(idA, .editor),
            second: .leaf(idB, .editor),
            ratio: 0.5
        )
        let result = tree.swapping(idA, with: idB)
        #expect(result != nil)
        // Content should be swapped, IDs stay in place
        #expect(result?.content(for: idA) == .editor)
        #expect(result?.content(for: idB) == .editor)
    }

    @Test func swapping_unknownID_returnsNil() {
        let id = PaneID()
        let tree = PaneNode.leaf(id, .editor)
        #expect(tree.swapping(id, with: PaneID()) == nil)
    }

    @Test func swapping_sameContent_noChange() {
        let idA = PaneID()
        let idB = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(idA, .editor),
            second: .leaf(idB, .editor),
            ratio: 0.5
        )
        let result = tree.swapping(idA, with: idB)
        #expect(result != nil)
        #expect(result?.content(for: idA) == .editor)
        #expect(result?.content(for: idB) == .editor)
    }

    @Test func swapping_deepInTree() {
        let idA = PaneID()
        let idB = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .split(.vertical, first: .leaf(idA, .editor), second: .leaf(PaneID(), .editor), ratio: 0.5),
            second: .split(.vertical, first: .leaf(idB, .editor), second: .leaf(PaneID(), .editor), ratio: 0.5),
            ratio: 0.5
        )
        let result = tree.swapping(idA, with: idB)
        #expect(result != nil)
        #expect(result?.content(for: idA) == .editor)
        #expect(result?.content(for: idB) == .editor)
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
            second: .leaf(PaneID(), .editor),
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
                    first: .leaf(PaneID(), .editor),
                    second: .leaf(PaneID(), .editor),
                    ratio: 0.3
                ),
                ratio: 0.5
            ),
            second: .leaf(PaneID(), .editor),
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
            first: .leaf(id1, .editor),
            second: .leaf(id2, .editor),
            ratio: 0.4
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
        #expect(original == decoded)
        #expect(decoded.contains(id1))
        #expect(decoded.contains(id2))
    }

    // MARK: - Floating point ratio equality (С1)

    @Test func equatable_nearlyEqualRatios_areEqual() {
        let uuid1 = UUID()
        let uuid2 = UUID()
        let nodeA = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(id: uuid1), .editor),
            second: .leaf(PaneID(id: uuid2), .editor),
            ratio: 0.5
        )
        let nodeB = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(id: uuid1), .editor),
            second: .leaf(PaneID(id: uuid2), .editor),
            ratio: 0.5 + 1e-10  // within epsilon
        )
        #expect(nodeA == nodeB)
    }

    @Test func equatable_significantlyDifferentRatios_areNotEqual() {
        let uuid1 = UUID()
        let uuid2 = UUID()
        let nodeA = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(id: uuid1), .editor),
            second: .leaf(PaneID(id: uuid2), .editor),
            ratio: 0.5
        )
        let nodeB = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(id: uuid1), .editor),
            second: .leaf(PaneID(id: uuid2), .editor),
            ratio: 0.500_002  // beyond epsilon
        )
        #expect(nodeA != nodeB)
    }

    @Test func equatable_0_999999_vs_1_0_areNotEqual() {
        let uuid1 = UUID()
        let uuid2 = UUID()
        let nodeA = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(id: uuid1), .editor),
            second: .leaf(PaneID(id: uuid2), .editor),
            ratio: 0.999_999
        )
        let nodeB = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(id: uuid1), .editor),
            second: .leaf(PaneID(id: uuid2), .editor),
            ratio: 1.0
        )
        #expect(nodeA != nodeB)
    }

    // MARK: - Edge cases

    @Test func split_withRatioZero() {
        let node = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .editor),
            ratio: 0.0
        )
        #expect(node.leafCount == 2)
    }

    @Test func split_withRatioOne() {
        let node = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .editor),
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

    @Test func veryDeepTree_100Levels_performance() {
        // Build a deep tree (bypassing maxDepth via direct construction)
        var node = PaneNode.leaf(PaneID(), .editor)
        for _ in 0..<99 {
            node = .split(.horizontal, first: node, second: .leaf(PaneID(), .editor), ratio: 0.5)
        }
        #expect(node.depth == 100)
        #expect(node.leafCount == 100)

        // Queries should still work
        let ids = node.leafIDs
        #expect(ids.count == 100)
        if let lastID = ids.last {
            #expect(node.contains(lastID))
        }
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

    @Test func twoEditorLeaves_contentLookup() {
        let leftID = PaneID()
        let rightID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(leftID, .editor),
            second: .leaf(rightID, .editor),
            ratio: 0.5
        )
        #expect(tree.content(for: leftID) == .editor)
        #expect(tree.content(for: rightID) == .editor)
        #expect(tree.leafCount == 2)
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
            second: .leaf(PaneID(), .editor),
            ratio: 0.5
        )
        #expect(tree.splitting(PaneID(), axis: .vertical, newPaneID: PaneID(), newContent: .editor) == nil)
    }

    @Test func removing_nonExistentID_returnsNil() {
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(), .editor),
            second: .leaf(PaneID(), .editor),
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

    // MARK: - Removing with sibling promotion

    @Test func removing_firstChild_promotesSecond() {
        let remove = PaneID()
        let keep = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(remove, .editor),
            second: .leaf(keep, .editor),
            ratio: 0.5
        )
        let result = tree.removing(remove)
        if case .leaf(let id, let content) = result {
            #expect(id == keep)
            #expect(content == .editor)
        } else {
            Issue.record("Expected leaf node after removing first child")
        }
    }

    @Test func updatingRatio_withNegativeValue_clampsToMinimum() {
        let id = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id, .editor),
            second: .leaf(PaneID(), .editor),
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

    // MARK: - Equatable

    @Test func equatable_identicalLeaves_areEqual() {
        let uuid = UUID()
        let nodeA = PaneNode.leaf(PaneID(id: uuid), .editor)
        let nodeB = PaneNode.leaf(PaneID(id: uuid), .editor)
        #expect(nodeA == nodeB)
    }

    @Test func equatable_differentIDs_areNotEqual() {
        let nodeA = PaneNode.leaf(PaneID(), .editor)
        let nodeB = PaneNode.leaf(PaneID(), .editor)
        #expect(nodeA != nodeB)
    }

    @Test func equatable_identicalSplits_areEqual() {
        let uuid1 = UUID()
        let uuid2 = UUID()
        let nodeA = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(id: uuid1), .editor),
            second: .leaf(PaneID(id: uuid2), .editor),
            ratio: 0.5
        )
        let nodeB = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(id: uuid1), .editor),
            second: .leaf(PaneID(id: uuid2), .editor),
            ratio: 0.5
        )
        #expect(nodeA == nodeB)
    }

    @Test func equatable_differentRatios_areNotEqual() {
        let uuid1 = UUID()
        let uuid2 = UUID()
        let nodeA = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(id: uuid1), .editor),
            second: .leaf(PaneID(id: uuid2), .editor),
            ratio: 0.3
        )
        let nodeB = PaneNode.split(
            .horizontal,
            first: .leaf(PaneID(id: uuid1), .editor),
            second: .leaf(PaneID(id: uuid2), .editor),
            ratio: 0.7
        )
        #expect(nodeA != nodeB)
    }

    // MARK: - Splitting axis preservation

    @Test func splitting_preservesHorizontalAxis() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        let result = leaf.splitting(id, axis: .horizontal, newPaneID: PaneID(), newContent: .editor)
        if case .split(let axis, _, _, _) = result {
            #expect(axis == .horizontal)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func splitting_preservesVerticalAxis() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        let result = leaf.splitting(id, axis: .vertical, newPaneID: PaneID(), newContent: .editor)
        if case .split(let axis, _, _, _) = result {
            #expect(axis == .vertical)
        } else {
            Issue.record("Expected split node")
        }
    }

    // MARK: - Removing leaf when sibling is split (subtree promotion)

    @Test func removing_leaf_promotesSplitSibling() {
        let removeID = PaneID()
        let innerID1 = PaneID()
        let innerID2 = PaneID()
        let innerSplit = PaneNode.split(
            .vertical,
            first: .leaf(innerID1, .editor),
            second: .leaf(innerID2, .editor),
            ratio: 0.4
        )
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(removeID, .editor),
            second: innerSplit,
            ratio: 0.5
        )

        let result = tree.removing(removeID)
        #expect(result == innerSplit)
        #expect(result?.leafCount == 2)
        #expect(result?.contains(innerID1) == true)
        #expect(result?.contains(innerID2) == true)
        if case .split(let axis, _, _, let ratio) = result {
            #expect(axis == .vertical)
            #expect(abs(ratio - 0.4) < 1e-6)
        } else {
            Issue.record("Expected split node after promotion")
        }
    }

    @Test func removing_leaf_promotesFirstChildSplitSibling() {
        let removeID = PaneID()
        let innerID1 = PaneID()
        let innerID2 = PaneID()
        let innerSplit = PaneNode.split(
            .horizontal,
            first: .leaf(innerID1, .editor),
            second: .leaf(innerID2, .editor),
            ratio: 0.6
        )
        let tree = PaneNode.split(
            .vertical,
            first: innerSplit,
            second: .leaf(removeID, .editor),
            ratio: 0.5
        )

        let result = tree.removing(removeID)
        #expect(result == innerSplit)
    }

    // MARK: - Splitting ratio edge cases (К2)

    @Test func splitting_ratioZero_clampsToMinimum() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        let result = leaf.splitting(id, axis: .horizontal, newPaneID: PaneID(), newContent: .editor, ratio: 0.0)
        if case .split(_, _, _, let ratio) = result {
            #expect(ratio == 0.1)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func splitting_ratioOne_clampsToMaximum() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        let result = leaf.splitting(id, axis: .horizontal, newPaneID: PaneID(), newContent: .editor, ratio: 1.0)
        if case .split(_, _, _, let ratio) = result {
            #expect(ratio == 0.9)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func splitting_negativeRatio_clampsToMinimum() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        let result = leaf.splitting(id, axis: .horizontal, newPaneID: PaneID(), newContent: .editor, ratio: -0.5)
        if case .split(_, _, _, let ratio) = result {
            #expect(ratio == 0.1)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func splitting_ratioGreaterThanOne_clampsToMaximum() {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, .editor)
        let result = leaf.splitting(id, axis: .horizontal, newPaneID: PaneID(), newContent: .editor, ratio: 2.5)
        if case .split(_, _, _, let ratio) = result {
            #expect(ratio == 0.9)
        } else {
            Issue.record("Expected split node")
        }
    }

    // MARK: - Splitting ratio clamping in recursive calls (К2)

    @Test func splitting_deepInTree_ratioIsClamped() {
        let targetID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(targetID, .editor),
            second: .leaf(PaneID(), .editor),
            ratio: 0.5
        )
        // Split with extreme ratio deep in tree
        let result = tree.splitting(targetID, axis: .vertical, newPaneID: PaneID(), newContent: .editor, ratio: -1.0)
        #expect(result != nil)
        // Find the inner split and verify its ratio is clamped
        if case .split(_, let first, _, _) = result {
            if case .split(_, _, _, let innerRatio) = first {
                #expect(innerRatio == 0.1)
            } else {
                Issue.record("Expected inner split")
            }
        } else {
            Issue.record("Expected outer split")
        }
    }

    // MARK: - Replacing and swapping negative scenarios

    @Test func replacing_onSingleLeaf_unknownID_returnsNil() {
        let leaf = PaneNode.leaf(PaneID(), .editor)
        #expect(leaf.replacing(PaneID(), with: .leaf(PaneID(), .editor)) == nil)
    }

    @Test func swapping_bothUnknown_returnsNil() {
        let tree = PaneNode.leaf(PaneID(), .editor)
        #expect(tree.swapping(PaneID(), with: PaneID()) == nil)
    }

    @Test func swapping_oneKnownOneUnknown_returnsNil() {
        let id = PaneID()
        let tree = PaneNode.leaf(id, .editor)
        #expect(tree.swapping(id, with: PaneID()) == nil)
    }

    @Test func swapping_sameID_returnsIdentical() {
        let id = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id, .editor),
            second: .leaf(PaneID(), .editor),
            ratio: 0.5
        )
        let result = tree.swapping(id, with: id)
        #expect(result != nil)
        #expect(result?.content(for: id) == .editor)
    }
}

// swiftlint:enable type_body_length file_length
