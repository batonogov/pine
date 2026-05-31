//
//  GitModels.swift
//  Pine
//
//  Data models for git status, diff markers, and blame display.
//

import SwiftUI

// MARK: - GitFileStatus

enum GitFileStatus: Equatable, Sendable {
    case untracked
    case modified
    case staged
    case added
    case deleted
    case conflict
    case mixed // staged + unstaged changes
}

extension GitFileStatus {
    var color: Color {
        switch self {
        case .modified, .mixed: return .orange
        case .staged:           return .green
        case .added:            return Color(.systemGreen)
        case .untracked:        return Color(.systemTeal)
        case .deleted:          return .red
        case .conflict:         return .red
        }
    }
}

// MARK: - GitLineDiff

struct GitLineDiff: Equatable, Sendable {
    enum Kind: Sendable { case added, modified, deleted }
    let line: Int
    let kind: Kind

    /// Returns the first line of each contiguous change region, sorted ascending.
    nonisolated static func changeRegionStarts(_ diffs: [GitLineDiff]) -> [Int] {
        let sorted = diffs.sorted { $0.line < $1.line }
        var starts: [Int] = []
        var previousLine: Int?
        for diff in sorted {
            if let prev = previousLine, diff.line == prev + 1 {
                previousLine = diff.line
            } else {
                starts.append(diff.line)
                previousLine = diff.line
            }
        }
        return starts
    }

    /// Returns the line of the next change region after `currentLine`, wrapping to the first if needed.
    nonisolated static func nextChangeLine(from currentLine: Int, in diffs: [GitLineDiff]) -> Int? {
        let starts = changeRegionStarts(diffs)
        return nextChangeLine(from: currentLine, regionStarts: starts, diffs: diffs)
    }

    /// Returns the line of the previous change region before `currentLine`, wrapping to the last if needed.
    nonisolated static func previousChangeLine(from currentLine: Int, in diffs: [GitLineDiff]) -> Int? {
        let starts = changeRegionStarts(diffs)
        return previousChangeLine(from: currentLine, regionStarts: starts, diffs: diffs)
    }

    /// Next change using pre-computed region starts (avoids recomputation when caller needs both directions).
    nonisolated static func nextChangeLine(from currentLine: Int, regionStarts starts: [Int], diffs: [GitLineDiff]) -> Int? {
        guard !starts.isEmpty else { return nil }
        let idx = regionIndex(forLine: currentLine, regionStarts: starts, diffs: diffs)
        if let idx {
            return starts[(idx + 1) % starts.count]
        }
        if let next = starts.first(where: { $0 > currentLine }) {
            return next
        }
        return starts[0]
    }

    /// Previous change using pre-computed region starts.
    nonisolated static func previousChangeLine(from currentLine: Int, regionStarts starts: [Int], diffs: [GitLineDiff]) -> Int? {
        guard !starts.isEmpty else { return nil }
        let idx = regionIndex(forLine: currentLine, regionStarts: starts, diffs: diffs)
        if let idx {
            return starts[(idx - 1 + starts.count) % starts.count]
        }
        if let prev = starts.last(where: { $0 < currentLine }) {
            return prev
        }
        return starts[starts.count - 1]
    }

    /// Returns the index of the region that contains `line`, or nil if line is not in any region.
    nonisolated private static func regionIndex(forLine line: Int, regionStarts: [Int], diffs: [GitLineDiff]) -> Int? {
        let diffLines = Set(diffs.map(\.line))
        guard diffLines.contains(line) else { return nil }
        // Walk backwards from line to find the region start
        var current = line
        while current > 0 && diffLines.contains(current - 1) {
            current -= 1
        }
        return regionStarts.firstIndex(of: current)
    }
}
