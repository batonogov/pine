//
//  PaneNode.swift
//  Pine
//
//  Created by Claude on 25.03.2026.
//

import Foundation

/// Unique identifier for a pane in the split layout.
///
/// - Important: Callers must ensure each `PaneID` is unique within a `PaneNode` tree.
///   Duplicate IDs lead to undefined behavior in queries and mutations.
struct PaneID: Hashable, Codable, Identifiable, Sendable {
    let id: UUID

    init() { self.id = UUID() }
    init(id: UUID) { self.id = id }
}

/// The type of content a leaf pane displays.
/// Each pane owns a `TabManager` for editor tabs, keyed by `PaneID`.
enum PaneContent: String, Hashable, Codable, Sendable {
    case editor
}

/// Split direction for a non-leaf pane.
enum SplitAxis: String, Codable, Sendable {
    case horizontal // side by side (left | right)
    case vertical   // stacked (top / bottom)
}

/// Maximum nesting depth for pane splits.
/// Prevents runaway recursion and keeps the UI manageable.
let paneMaxDepth = 8

/// Epsilon for floating-point ratio comparison.
/// Ratios within this tolerance are considered equal.
private let ratioEpsilon: CGFloat = 1e-6

/// A node in the pane layout tree.
/// Leaf nodes contain content (editor or terminal).
/// Split nodes divide space between two children.
indirect enum PaneNode: Sendable {
    case leaf(PaneID, PaneContent)
    case split(SplitAxis, first: PaneNode, second: PaneNode, ratio: CGFloat)

    // MARK: - Queries

    /// Returns all leaf PaneIDs in this subtree (left-to-right / top-to-bottom order).
    var leafIDs: [PaneID] {
        switch self {
        case .leaf(let id, _):
            return [id]
        case .split(_, let first, let second, _):
            return first.leafIDs + second.leafIDs
        }
    }

    /// Returns the PaneID of the first (leftmost / topmost) leaf.
    var firstLeafID: PaneID? {
        switch self {
        case .leaf(let id, _):
            return id
        case .split(_, let first, _, _):
            return first.firstLeafID
        }
    }

    /// Finds the content type for a given PaneID.
    func content(for id: PaneID) -> PaneContent? {
        switch self {
        case .leaf(let leafID, let content):
            return leafID == id ? content : nil
        case .split(_, let first, let second, _):
            return first.content(for: id) ?? second.content(for: id)
        }
    }

    /// Returns true if the tree contains the given PaneID.
    func contains(_ id: PaneID) -> Bool {
        content(for: id) != nil
    }

    /// Returns the total number of leaves.
    var leafCount: Int {
        switch self {
        case .leaf:
            return 1
        case .split(_, let first, let second, _):
            return first.leafCount + second.leafCount
        }
    }

    /// Returns the depth of the tree (leaf = 1, split = 1 + max child depth).
    var depth: Int {
        switch self {
        case .leaf:
            return 1
        case .split(_, let first, let second, _):
            return 1 + max(first.depth, second.depth)
        }
    }

    /// Returns all PaneIDs (leaf) present in the tree as a Set for O(1) lookup.
    var allIDs: Set<PaneID> {
        switch self {
        case .leaf(let id, _):
            return [id]
        case .split(_, let first, let second, _):
            return first.allIDs.union(second.allIDs)
        }
    }

    // MARK: - Mutations (return new trees)

    /// Replaces a leaf with a split, putting the original leaf and a new leaf side by side.
    /// Returns nil if `targetID` is not found, if `newPaneID` already exists in the tree,
    /// or if the resulting tree would exceed `paneMaxDepth`.
    func splitting(
        _ targetID: PaneID,
        axis: SplitAxis,
        newPaneID: PaneID,
        newContent: PaneContent,
        ratio: CGFloat = 0.5
    ) -> PaneNode? {
        let clamped = min(max(ratio, 0.1), 0.9)

        // Validate: newPaneID must not already exist in the tree
        guard !contains(newPaneID) else { return nil }

        // Validate: resulting depth must not exceed maxDepth
        guard depth < paneMaxDepth else { return nil }

        return splittingInternal(targetID, axis: axis, newPaneID: newPaneID, newContent: newContent, ratio: clamped)
    }

    /// Internal recursive splitting without re-validating constraints.
    private func splittingInternal(
        _ targetID: PaneID,
        axis: SplitAxis,
        newPaneID: PaneID,
        newContent: PaneContent,
        ratio: CGFloat
    ) -> PaneNode? {
        switch self {
        case .leaf(let id, let content):
            guard id == targetID else { return nil }
            let newLeaf = PaneNode.leaf(newPaneID, newContent)
            return .split(axis, first: .leaf(id, content), second: newLeaf, ratio: ratio)

        case .split(let ax, let first, let second, let currentRatio):
            if let newFirst = first.splittingInternal(
                targetID, axis: axis, newPaneID: newPaneID, newContent: newContent, ratio: ratio
            ) {
                return .split(ax, first: newFirst, second: second, ratio: currentRatio)
            }
            if let newSecond = second.splittingInternal(
                targetID, axis: axis, newPaneID: newPaneID, newContent: newContent, ratio: ratio
            ) {
                return .split(ax, first: first, second: newSecond, ratio: currentRatio)
            }
            return nil
        }
    }

    /// Removes a leaf and collapses its parent split, promoting the sibling.
    /// Returns nil if `targetID` is not found, or if this is the only leaf (can't remove last pane).
    func removing(_ targetID: PaneID) -> PaneNode? {
        switch self {
        case .leaf(let id, _):
            // Can't remove the only leaf
            guard id == targetID else { return nil }
            return nil

        case .split(let ax, let first, let second, let currentRatio):
            // Check if target is a direct child
            if case .leaf(let id, _) = first, id == targetID {
                return second
            }
            if case .leaf(let id, _) = second, id == targetID {
                return first
            }
            // Recurse into children
            if let newFirst = first.removing(targetID) {
                return .split(ax, first: newFirst, second: second, ratio: currentRatio)
            }
            if let newSecond = second.removing(targetID) {
                return .split(ax, first: first, second: newSecond, ratio: currentRatio)
            }
            return nil
        }
    }

    /// Updates the split ratio of the **immediate parent split** of the given leaf.
    ///
    /// Finds the split node whose direct child is the leaf with `targetID`,
    /// and replaces its ratio. Works for any tree shape — the leaf's parent
    /// is always a split, even when both siblings are splits themselves.
    ///
    /// Clamps ratio to 0.1...0.9. Returns nil if `targetID` is not found.
    func updatingRatio(for targetID: PaneID, ratio: CGFloat) -> PaneNode? {
        let clamped = min(max(ratio, 0.1), 0.9)
        switch self {
        case .leaf:
            return nil

        case .split(let ax, let first, let second, let currentRatio):
            // If target is a direct leaf child, this is the parent — update ratio
            if case .leaf(let id, _) = first, id == targetID {
                return .split(ax, first: first, second: second, ratio: clamped)
            }
            if case .leaf(let id, _) = second, id == targetID {
                return .split(ax, first: first, second: second, ratio: clamped)
            }

            // Recurse into children
            if let newFirst = first.updatingRatio(for: targetID, ratio: ratio) {
                return .split(ax, first: newFirst, second: second, ratio: currentRatio)
            }
            if let newSecond = second.updatingRatio(for: targetID, ratio: ratio) {
                return .split(ax, first: first, second: newSecond, ratio: currentRatio)
            }
            return nil
        }
    }

    /// Updates the ratio of the split node whose **direct child subtree** contains
    /// the given leaf `targetID`. Unlike `updatingRatio(for:ratio:)` which targets
    /// the leaf's immediate parent, this targets the **ancestor split one level up**
    /// — the split whose child is a subtree containing the leaf.
    ///
    /// Use this to resize the divider between two split subtrees (Phase 2 drag-resize).
    /// Clamps ratio to 0.1...0.9. Returns nil if `targetID` is not found
    /// or the leaf is a direct child of this split (use `updatingRatio(for:ratio:)` instead).
    func updatingRatioOfSplit(containing targetID: PaneID, ratio: CGFloat) -> PaneNode? {
        let clamped = min(max(ratio, 0.1), 0.9)
        switch self {
        case .leaf:
            return nil

        case .split(let ax, let first, let second, let currentRatio):
            let inFirst = first.contains(targetID)
            let inSecond = second.contains(targetID)

            guard inFirst || inSecond else { return nil }

            // Skip direct leaf children — use updatingRatio(for:ratio:) for those
            if case .leaf(let id, _) = first, id == targetID { return nil }
            if case .leaf(let id, _) = second, id == targetID { return nil }

            // Target is inside a subtree child — check if it's a direct child of that subtree
            if inFirst, case .split = first, first.contains(targetID) {
                // Is it directly inside first? Or deeper?
                if first.hasDirectLeafChild(targetID) {
                    // The leaf is a direct child of our first child → update this split's ratio
                    return .split(ax, first: first, second: second, ratio: clamped)
                }
                // Deeper — recurse
                if let newFirst = first.updatingRatioOfSplit(containing: targetID, ratio: ratio) {
                    return .split(ax, first: newFirst, second: second, ratio: currentRatio)
                }
                return nil
            }
            if inSecond, case .split = second, second.contains(targetID) {
                if second.hasDirectLeafChild(targetID) {
                    return .split(ax, first: first, second: second, ratio: clamped)
                }
                if let newSecond = second.updatingRatioOfSplit(containing: targetID, ratio: ratio) {
                    return .split(ax, first: first, second: newSecond, ratio: currentRatio)
                }
                return nil
            }
            return nil
        }
    }

    /// Returns true if the given ID is a direct leaf child of this split.
    private func hasDirectLeafChild(_ id: PaneID) -> Bool {
        guard case .split(_, let first, let second, _) = self else { return false }
        if case .leaf(let fid, _) = first, fid == id { return true }
        if case .leaf(let sid, _) = second, sid == id { return true }
        return false
    }

    /// Replaces the subtree rooted at the pane with `targetID` with a new node.
    /// Returns nil if `targetID` is not found.
    func replacing(_ targetID: PaneID, with newNode: PaneNode) -> PaneNode? {
        switch self {
        case .leaf(let id, _):
            return id == targetID ? newNode : nil
        case .split(let ax, let first, let second, let currentRatio):
            if let newFirst = first.replacing(targetID, with: newNode) {
                return .split(ax, first: newFirst, second: second, ratio: currentRatio)
            }
            if let newSecond = second.replacing(targetID, with: newNode) {
                return .split(ax, first: first, second: newSecond, ratio: currentRatio)
            }
            return nil
        }
    }

    /// Swaps the positions of two panes identified by their IDs.
    /// Returns nil if either ID is not found.
    func swapping(_ idA: PaneID, with idB: PaneID) -> PaneNode? {
        guard let contentA = content(for: idA),
              let contentB = content(for: idB) else {
            return nil
        }
        // Replace A with B's content, then B with A's content
        guard let step1 = replacing(idA, with: .leaf(idA, contentB)) else { return nil }
        guard let step2 = step1.replacing(idB, with: .leaf(idB, contentA)) else { return nil }
        return step2
    }
}

// MARK: - Equatable (epsilon-based ratio comparison)

extension PaneNode: Equatable {
    static func == (lhs: PaneNode, rhs: PaneNode) -> Bool {
        switch (lhs, rhs) {
        case let (.leaf(idL, contentL), .leaf(idR, contentR)):
            return idL == idR && contentL == contentR
        case let (
            .split(axL, firstL, secondL, ratioL),
            .split(axR, firstR, secondR, ratioR)
        ):
            return axL == axR
                && firstL == firstR
                && secondL == secondR
                && abs(ratioL - ratioR) < ratioEpsilon
        default:
            return false
        }
    }
}

// MARK: - Codable

extension PaneNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, id, content, axis, first, second, ratio
    }

    private enum NodeType: String, Codable {
        case leaf, split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)
        switch type {
        case .leaf:
            let id = try container.decode(PaneID.self, forKey: .id)
            let content = try container.decode(PaneContent.self, forKey: .content)
            self = .leaf(id, content)
        case .split:
            let axis = try container.decode(SplitAxis.self, forKey: .axis)
            let first = try container.decode(PaneNode.self, forKey: .first)
            let second = try container.decode(PaneNode.self, forKey: .second)
            let ratio = try container.decode(CGFloat.self, forKey: .ratio)
            self = .split(axis, first: first, second: second, ratio: ratio)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id, let content):
            try container.encode(NodeType.leaf, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(content, forKey: .content)
        case .split(let axis, let first, let second, let ratio):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
            try container.encode(ratio, forKey: .ratio)
        }
    }
}
