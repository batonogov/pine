//
//  MenuPlacementGuardTests.swift
//  PineTests
//
//  The placement half of #1564. A Mac user finds Close Window in the File
//  menu, Show in Finder in the File menu, tab and window arrangement in the
//  Window menu, and auxiliary panels in the Window menu. The four moves
//  that established that layout are easy to undo with a careless paste, so
//  the invariant is stated over the menu source the same way
//  MenuHardcodedShortcutGuardTests states its own: each relocated item must
//  live in exactly one CommandGroup, and that group must be the one the
//  move chose.
//

import Foundation
import Testing

@testable import Pine

@Suite("Menu items sit in the menus a Mac user expects")
struct MenuPlacementGuardTests {
    /// One `CommandGroup(…)` call in the menu source: its anchor (modifier
    /// plus placement name) and its full argument text.
    private struct Segment {
        let anchor: String
        let text: String
    }

    /// The anchors that build the File menu, in menu order.
    private static let fileMenuAnchors = [
        "replacing: .newItem",
        "after: .newItem",
        "replacing: .saveItem",
    ]

    /// The anchor that appends to the Window menu's arrangement section.
    private static let windowMenuAnchor = "after: .windowArrangement"

    /// The anchor that appends to the View menu.
    private static let viewMenuAnchor = "after: .toolbar"

    // MARK: - File menu

    @Test("Close Window sits in the File menu, not the Window menu")
    func closeWindowLivesInFileMenu() throws {
        try Self.assertItem(
            "Strings.menuCloseWindow",
            livesInAnchors: Self.fileMenuAnchors,
            because: """
                Standard macOS places Close in the File menu (#1564). The \
                former `before: .windowSize` group must stay deleted.
                """
        )
        let windowSizedGroups = try Self.segments()
            .filter { $0.anchor == "before: .windowSize" }
        #expect(
            windowSizedGroups.isEmpty,
            """
            A `before: .windowSize` group exists again; Close Window moved \
            to File in #1564 and that group must not return (#1564).
            """
        )
    }

    @Test("Reveal File and Project in Finder sit in the File menu")
    func revealItemsLiveInFileMenu() throws {
        try Self.assertItem(
            "Strings.menuRevealFileInFinder",
            livesInAnchors: Self.fileMenuAnchors,
            because: """
                Finder and Xcode place "Show in Finder" in the File menu (#1564).
                """
        )
        try Self.assertItem(
            "Strings.menuRevealProjectInFinder",
            livesInAnchors: Self.fileMenuAnchors,
            because: """
                Finder and Xcode place "Show in Finder" in the File menu (#1564).
                """
        )
    }

    // MARK: - Window menu

    @Test("Move Tab commands sit in the Window menu")
    func moveTabItemsLiveInWindowMenu() throws {
        for item in [
            "Strings.tabMoveLeading",
            "Strings.tabMoveTrailing",
            "Strings.tabMoveToPreviousPane",
            "Strings.tabMoveToNextPane",
        ] {
            try Self.assertItem(
                item,
                livesInAnchors: [Self.windowMenuAnchor],
                because: """
                    Tab and window arrangement belongs in the Window menu (#1564).
                    """
            )
        }
    }

    @Test("Agent Inbox, Activity, and History sit in the Window menu")
    func agentPanelsLiveInWindowMenu() throws {
        for item in [
            "Strings.menuAgentInbox",
            "Strings.menuAgentActivity",
            "Strings.menuAgentHistory",
        ] {
            try Self.assertItem(
                item,
                livesInAnchors: [Self.windowMenuAnchor],
                because: """
                    Auxiliary panels conventionally live in the Window menu (#1564).
                    """
            )
        }
    }

    /// The View menu keeps owning the items #1564 did not move, so a broad
    /// cut-and-paste cannot hide behind these guards.
    @Test("the View menu keeps the items #1564 left there")
    func viewMenuKeepsItsOwnItems() throws {
        let view = try Self.segment(anchor: Self.viewMenuAnchor)
        for item in [
            "Strings.menuToggleMinimap",
            "Strings.menuToggleBlame",
            "Strings.menuToggleWordWrap",
            "Strings.menuProblems",
            "Strings.menuNextDiagnostic",
            "Strings.menuPreviousDiagnostic",
            "Strings.projectSwitcherNewAgent",
            "Strings.menuAgentWorktrees",
        ] {
            #expect(
                view.text.contains(item),
                """
                \(item) no longer sits in the View menu; #1564 moved only \
                the Move Tab, Reveal, and agent-panel items out of it.
                """
            )
        }
    }

    // MARK: - Scanning the menu source

    private static func assertItem(
        _ item: String,
        livesInAnchors allowedAnchors: [String],
        because reason: String
    ) throws {
        let homes = try Self.segments()
            .filter { $0.text.contains(item) }
            .map(\.anchor)

        #expect(
            homes.count == 1,
            """
            \(item) appears in \(homes.count) CommandGroups (\(homes)); an \
            item must be defined exactly once.
            """
        )
        #expect(
            allowedAnchors.contains(homes.first ?? ""),
            """
            \(item) lives in "\(homes.first ?? "nowhere")"; it belongs to \
            \(allowedAnchors.joined(separator: " / ")). \(reason)
            """
        )
    }

    private static func segment(anchor: String) throws -> Segment {
        try #require(
            segments().first { $0.anchor == anchor },
            """
            No CommandGroup anchored \(anchor) exists in the menu source; \
            this guard cannot pass on a menu it failed to read.
            """
        )
    }

    /// Every `CommandGroup(…)` call, with the anchor spelled in its header.
    ///
    /// Fails closed: an unreadable file is an error, never an empty list.
    private static func segments() throws -> [Segment] {
        let url = try ProductionSourceScan.repositoryRoot()
            .appendingPathComponent(MenuCommandSource.relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        guard text.contains("struct PineAppMenuCommands") else {
            throw MenuCommandSource.SourceNotRecognizedError(
                url: url,
                reason: "no PineAppMenuCommands declaration"
            )
        }

        var results: [Segment] = []
        var searchStart = text.startIndex
        while let opening = text.range(
            of: "CommandGroup(",
            range: searchStart..<text.endIndex
        ) {
            // Match the call's parentheses, then the trailing closure that
            // follows them — `CommandGroup(after: .x) { …items… }` keeps its
            // items in the closure, not in the argument list.
            var parenDepth = 1
            var index = opening.upperBound
            while index < text.endIndex, parenDepth > 0 {
                if text[index] == "(" {
                    parenDepth += 1
                } else if text[index] == ")" {
                    parenDepth -= 1
                }
                index = text.index(after: index)
            }
            guard parenDepth == 0 else {
                throw MenuCommandSource.SourceNotRecognizedError(
                    url: url,
                    reason: "unclosed CommandGroup call"
                )
            }

            var end = index
            if let braceOpening = text[index...].firstIndex(of: "{") {
                var braceDepth = 1
                var braceIndex = text.index(after: braceOpening)
                while braceIndex < text.endIndex, braceDepth > 0 {
                    if text[braceIndex] == "{" {
                        braceDepth += 1
                    } else if text[braceIndex] == "}" {
                        braceDepth -= 1
                    }
                    braceIndex = text.index(after: braceIndex)
                }
                guard braceDepth == 0 else {
                    throw MenuCommandSource.SourceNotRecognizedError(
                        url: url,
                        reason: "unclosed CommandGroup trailing closure"
                    )
                }
                end = braceIndex
            }
            let argument = String(text[opening.upperBound..<end])

            // The anchor marker nearest the start of the call: the header
            // precedes the body, so the earliest marker wins even if a
            // comment inside some other group mentions a later one.
            let anchor = ["replacing: ", "after: ", "before: "]
                .compactMap { marker -> (lowerBound: String.Index, anchor: String)? in
                    guard let range = argument.range(of: marker) else {
                        return nil
                    }
                    let remainder = argument[range.upperBound...]
                        .prefix { $0.isLetter || $0.isNumber || $0 == "." }
                    return (range.lowerBound, marker + remainder)
                }
                .min { $0.lowerBound < $1.lowerBound }?
                .anchor

            if let anchor {
                results.append(Segment(anchor: anchor, text: argument))
            }
            searchStart = end
        }

        guard results.count >= 5 else {
            throw MenuCommandSource.SourceNotRecognizedError(
                url: url,
                reason: "found only \(results.count) anchored CommandGroups"
            )
        }
        return results
    }
}
