//
//  IconOnlyControlLabelGuardTests.swift
//  PineTests
//
//  The guard half of #1527. Labelling the nine controls found by hand fixes
//  those nine; it does nothing about the tenth, added next month. So the
//  invariant is stated over the source: a control that carries an
//  accessibility identifier is a control someone reaches, and it must also
//  carry a name.
//

import Foundation
import Testing

@Suite("Icon-only controls carry an accessibility label")
struct IconOnlyControlLabelGuardTests {

    /// Files whose interactive chrome reached VoiceOver unnamed (#1527).
    nonisolated static let auditedFiles = [
        "ContentView.swift",
        "TerminalSearchBar.swift",
        "StatusBarView.swift",
        "EditorTabBar.swift",
        "TerminalPaneTabBar.swift",
        "WelcomeView.swift"
    ]

    private static func sourceDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PineTests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Pine")
    }

    /// An icon-only control that carries an identifier but no name.
    ///
    /// Scoped to controls whose entire content is an SF Symbol, which is what
    /// #1527 is about: a text button already names itself, and a container
    /// names itself through its children. Deliberately textual — the point is
    /// to fail on a source pattern before anyone has to run VoiceOver, the
    /// same way `MenuHardcodedShortcutGuard` states its rule over the source.
    @Test(arguments: auditedFiles)
    func identifiedControlsAreNamed(_ fileName: String) throws {
        let url = Self.sourceDirectory().appendingPathComponent(fileName)
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        var unnamed: [Int] = []
        for (index, line) in lines.enumerated()
        where line.contains(".accessibilityIdentifier(") {
            let start = max(0, index - 12)
            let end = min(lines.count - 1, index + 6)
            let window = lines[start...end].joined(separator: "\n")

            // Only icon-only controls are in scope.
            guard window.contains("Image(systemName:") else { continue }
            let namesItself = window.contains(".accessibilityLabel(")
                || window.contains(".accessibilityElement(children: .contain)")
                || window.contains(".accessibilityRepresentation")
                || window.contains("Text(")
                || window.contains("Label(")
            if !namesItself {
                unnamed.append(index + 1)
            }
        }

        #expect(
            unnamed.isEmpty,
            """
            \(fileName): controls carry an accessibility identifier but no \
            name, at line(s) \(unnamed.map(String.init).joined(separator: ", ")). \
            A help tag is AXHelp, not AXTitle — VoiceOver announces these as \
            unnamed buttons (#1527).
            """
        )
    }
}
