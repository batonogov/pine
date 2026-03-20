//
//  GitBlameInfo.swift
//  Pine
//

import Foundation

/// A single line of git blame output.
struct GitBlameLine: Equatable, Identifiable {
    let hash: String
    let author: String
    let authorTime: Date
    let summary: String
    /// 1-based final line number in the current file.
    let finalLine: Int

    /// Unique identity for popover binding.
    var id: Int { finalLine }

    /// Whether this line is uncommitted (all-zeros hash).
    var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}

/// Container for blame data for an entire file.
struct GitBlameInfo: Equatable {
    let lines: [GitBlameLine]

    static let empty = GitBlameInfo(lines: [])
}
