//
//  AccessibilityIdentifierGuardTests.swift
//  PineTests
//
//  Identifier hygiene half of #1533. `AccessibilityID` grew to well over a
//  hundred entries, and nothing noticed when one stopped being referenced or
//  when two names aliased the same string — a stale identifier looks exactly
//  like a live one from the inside. Stated over the source, the way
//  `AccessibilityStringGuardTests` states its own invariant.
//

import Foundation
import Testing

@testable import Pine

@Suite("Accessibility identifiers are referenced and unique")
struct AccessibilityIdentifierGuardTests {

    /// `static let name = "value"` declarations, with the value allowed on
    /// the next line. `static func` entries are parameterised generators —
    /// they cannot go dead in the same way and are excluded by the pattern.
    private static func declaredIdentifiers() throws -> [(name: String, value: String)] {
        let root = try ProductionSourceScan.repositoryRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Pine/AccessibilityIdentifiers.swift"
            ),
            encoding: .utf8
        )
        let pattern = #/static let (\w+) =\s*"([^"]+)"/#
        return source.matches(of: pattern).map {
            (name: String($0.1), value: String($0.2))
        }
    }

    /// Every Swift source that might reference an identifier, excluding the
    /// declaration file itself.
    private static func consumerSources() throws -> [String: String] {
        let root = try ProductionSourceScan.repositoryRoot()
        var files = try ["Pine", "PineTests", "PineUITests"].flatMap { dir in
            try ProductionSourceScan.swiftFileURLs(
                under: root.appendingPathComponent(dir)
            )
        }
        files.removeAll { $0.lastPathComponent == "AccessibilityIdentifiers.swift" }

        var sources: [String: String] = [:]
        for url in files {
            sources[url.path] = try String(contentsOf: url, encoding: .utf8)
        }
        return sources
    }

    @Test("No declared identifier is dead")
    func noDeadIdentifiers() throws {
        let declared = try Self.declaredIdentifiers()
        #expect(
            !declared.isEmpty,
            "The scan found no declarations — the regex no longer matches, so this guard proves nothing"
        )
        let consumers = try Self.consumerSources()
        #expect(!consumers.isEmpty, "The consumer scan found no sources")

        let dead = declared.filter { identifier in
            !consumers.values.contains { source in
                source.contains("AccessibilityID.\(identifier.name)")
                    || source.contains("\"\(identifier.value)\"")
            }
        }
        #expect(
            dead.isEmpty,
            """
            Dead accessibility identifiers — declared, never referenced: \
            \(dead.map(\.name).sorted()). Delete each, or wire it into the \
            view it names (#1533).
            """
        )
    }

    @Test("No two identifiers alias the same string")
    func noDuplicatedValues() throws {
        let declared = try Self.declaredIdentifiers()
        var namesByValue: [String: [String]] = [:]
        for identifier in declared {
            namesByValue[identifier.value, default: []].append(identifier.name)
        }
        let duplicated = namesByValue.filter { $0.value.count > 1 }
        #expect(
            duplicated.isEmpty,
            """
            Duplicated accessibility identifier values: \(duplicated). Two \
            names for one string make the tree ambiguous to every consumer \
            that looks elements up by identifier (#1533).
            """
        )
    }
}
