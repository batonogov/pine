//
//  PaneNode.swift
//  Pine
//
//  Created by Claude on 25.03.2026.
//

import Foundation

/// Unique identifier for a pane in the split layout.
struct PaneID: Hashable, Codable, Identifiable {
    let id: UUID

    init() { self.id = UUID() }
    init(id: UUID) { self.id = id }
}

/// The type of content a leaf pane displays.
enum PaneContent: String, Hashable, Codable {
    case editor
    case terminal
}

/// Split direction for a non-leaf pane.
enum SplitAxis: String, Codable {
    case horizontal // side by side (left | right)
    case vertical   // stacked (top / bottom)
}

/// A node in the pane layout tree.
/// Leaf nodes contain content (editor or terminal).
/// Split nodes divide space between two children.
indirect enum PaneNode: Equatable {
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

    // MARK: - Mutations (return new trees)

    /// Replaces a leaf with a split, putting the original leaf and a new leaf side by side.
    /// Returns nil if `targetID` is not found in the tree.
    func splitting(
        _ targetID: PaneID,
        axis: SplitAxis,
        newPaneID: PaneID,
        newContent: PaneContent,
        ratio: CGFloat = 0.5
    ) -> PaneNode? {
        switch self {
        case .leaf(let id, let content):
            guard id == targetID else { return nil }
            let newLeaf = PaneNode.leaf(newPaneID, newContent)
            return .split(axis, first: .leaf(id, content), second: newLeaf, ratio: ratio)

        case .split(let ax, let first, let second, let r):
            if let newFirst = first.splitting(targetID, axis: axis, newPaneID: newPaneID, newContent: newContent, ratio: ratio) {
                return .split(ax, first: newFirst, second: second, ratio: r)
            }
            if let newSecond = second.splitting(targetID, axis: axis, newPaneID: newPaneID, newContent: newContent, ratio: ratio) {
                return .split(ax, first: first, second: newSecond, ratio: r)
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

        case .split(let ax, let first, let second, let r):
            // Check if target is a direct child
            if case .leaf(let id, _) = first, id == targetID {
                return second
            }
            if case .leaf(let id, _) = second, id == targetID {
                return first
            }
            // Recurse into children
            if let newFirst = first.removing(targetID) {
                return .split(ax, first: newFirst, second: second, ratio: r)
            }
            if let newSecond = second.removing(targetID) {
                return .split(ax, first: first, second: newSecond, ratio: r)
            }
            return nil
        }
    }

    /// Updates the split ratio for the split that directly contains the given PaneID as a child.
    /// Clamps ratio to 0.1...0.9. Returns nil if `targetID` is not found.
    func updatingRatio(for targetID: PaneID, ratio: CGFloat) -> PaneNode? {
        let clamped = min(max(ratio, 0.1), 0.9)
        switch self {
        case .leaf:
            return nil

        case .split(let ax, let first, let second, let r):
            // Check if target is a direct child of this split
            let firstContains: Bool
            if case .leaf(let id, _) = first, id == targetID {
                firstContains = true
            } else {
                firstContains = false
            }
            let secondContains: Bool
            if case .leaf(let id, _) = second, id == targetID {
                secondContains = true
            } else {
                secondContains = false
            }

            if firstContains || secondContains {
                return .split(ax, first: first, second: second, ratio: clamped)
            }
            // Recurse
            if let newFirst = first.updatingRatio(for: targetID, ratio: ratio) {
                return .split(ax, first: newFirst, second: second, ratio: r)
            }
            if let newSecond = second.updatingRatio(for: targetID, ratio: ratio) {
                return .split(ax, first: first, second: newSecond, ratio: r)
            }
            return nil
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
