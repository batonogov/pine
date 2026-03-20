//
//  GitBlameInfo.swift
//  Pine
//

import Foundation

/// A single line of git blame output.
struct GitBlameLine: Equatable {
    let hash: String
    let author: String
    let authorTime: Date
    let summary: String
    /// 1-based final line number in the current file.
    let finalLine: Int

    /// Whether this line is uncommitted (all-zeros hash).
    var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}
