//
//  ProjectDisplayNamesTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Project Display Names")
struct ProjectDisplayNamesTests {
    private func directory(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private func names(_ paths: [String]) -> [String: String] {
        let urls = paths.map(directory)
        let resolved = ProjectDisplayNames.resolve(for: urls)
        return zip(paths, urls).reduce(into: [:]) { result, pair in
            result[pair.0] = resolved[pair.1.standardizedFileURL]
        }
    }

    @Test("a name nothing collides with stays a bare folder name")
    func uniqueNamesStayShort() {
        let resolved = names(["/Users/f/pine", "/Users/f/backend"])

        #expect(resolved["/Users/f/pine"] == "pine")
        #expect(resolved["/Users/f/backend"] == "backend")
    }

    @Test("colliding names take the nearest parent, and only that parent")
    func collisionTakesOneParent() {
        let resolved = names([
            "/Users/f/project1/infra",
            "/Users/f/project2/infra",
        ])

        #expect(resolved["/Users/f/project1/infra"] == "project1/infra")
        #expect(resolved["/Users/f/project2/infra"] == "project2/infra")
    }

    @Test("a shared parent keeps growing until the names separate")
    func sharedParentGrowsFurther() {
        let resolved = names(["/a/x/infra", "/b/x/infra"])

        // `x/infra` is still ambiguous, so both reach full depth — where the
        // name is the whole path and is spelled as one.
        #expect(resolved["/a/x/infra"] == "/a/x/infra")
        #expect(resolved["/b/x/infra"] == "/b/x/infra")
    }

    @Test("only the colliding roots grow; their neighbours stay short")
    func growthIsLocalToTheCollision() {
        let resolved = names([
            "/Users/f/pine",
            "/Users/f/project1/infra",
            "/Users/f/project2/infra",
            "/Users/f/project1/backend",
        ])

        #expect(resolved["/Users/f/pine"] == "pine")
        #expect(resolved["/Users/f/project1/infra"] == "project1/infra")
        #expect(resolved["/Users/f/project2/infra"] == "project2/infra")
        #expect(resolved["/Users/f/project1/backend"] == "backend")
    }

    @Test("the user's layout: four roots, two names, four readable rows")
    func twoNamesAcrossTwoParents() {
        let resolved = names([
            "/Users/f/project1/infra",
            "/Users/f/project2/infra",
            "/Users/f/project1/backend",
            "/Users/f/project2/backend",
        ])

        #expect(resolved["/Users/f/project1/infra"] == "project1/infra")
        #expect(resolved["/Users/f/project2/infra"] == "project2/infra")
        #expect(resolved["/Users/f/project1/backend"] == "project1/backend")
        #expect(resolved["/Users/f/project2/backend"] == "project2/backend")
    }

    @Test("a root nested under its own sibling still separates")
    func nestedSiblingSeparates() {
        let resolved = names(["/Users/f/p", "/Users/f/p/p"])

        #expect(resolved["/Users/f/p"] == "f/p")
        #expect(resolved["/Users/f/p/p"] == "p/p")
        #expect(resolved["/Users/f/p"] != resolved["/Users/f/p/p"])
    }

    @Test("a root directly under the filesystem root reads as absolute")
    func topLevelRootIsAbsolute() {
        let resolved = names(["/infra", "/Users/f/infra"])

        // `/infra` has one component and cannot grow, so it is spelled as the
        // absolute path it is — which also tells it apart from the other.
        #expect(resolved["/infra"] == "/infra")
        #expect(resolved["/Users/f/infra"] == "infra")
    }

    @Test("the filesystem root itself is still named")
    func filesystemRootIsNamed() {
        #expect(names(["/"])["/"] == "/")
    }

    @Test("an empty set resolves to no names")
    func emptyInput() {
        #expect(ProjectDisplayNames.resolve(for: []).isEmpty)
    }

    @Test("a repeated URL collapses instead of looping forever")
    func repeatedURLTerminates() {
        let url = directory("/Users/f/project1/infra")

        let resolved = ProjectDisplayNames.resolve(for: [url, url, url])

        #expect(resolved.count == 1)
        #expect(resolved[url.standardizedFileURL] == "infra")
    }

    @Test("paths are standardized before they are compared")
    func standardizesBeforeComparing() {
        let messy = directory("/Users/f/project1/../project2/infra")
        let plain = directory("/Users/f/project2/infra")

        let resolved = ProjectDisplayNames.resolve(for: [messy, plain])

        // The two spell the same directory, so this is one root, not a
        // collision to disambiguate.
        #expect(resolved.count == 1)
        #expect(resolved[plain.standardizedFileURL] == "infra")
    }

    @Test("canonically equivalent Unicode names count as a collision")
    func unicodeEquivalentNamesCollide() {
        let composed = "\u{0439}"
        let decomposed = "\u{0438}\u{0306}"
        // Two different encodings of one glyph, which `String` equality — and
        // therefore the bucketing — already treats as the same name.
        #expect(composed.unicodeScalars.count != decomposed.unicodeScalars.count)

        let resolved = names([
            "/Users/f/project1/\(composed)",
            "/Users/f/project2/\(decomposed)",
        ])

        // Identical on screen, so both must carry a parent — comparing the
        // raw code units would have called them distinct and shown two
        // indistinguishable rows.
        #expect(
            resolved["/Users/f/project1/\(composed)"]
                == "project1/\(composed)"
        )
        #expect(
            resolved["/Users/f/project2/\(decomposed)"]
                == "project2/\(decomposed)"
        )
    }

    @Test("many identically named roots all end up distinguishable")
    func manyCollisionsAllSeparate() {
        let paths = (0..<200).map { "/Users/f/client\($0)/infra" }

        let resolved = names(paths)

        #expect(resolved.count == paths.count)
        let rendered = paths.compactMap { resolved[$0] }
        #expect(rendered.count == paths.count)
        #expect(Set(rendered).count == paths.count)
        #expect(resolved["/Users/f/client7/infra"] == "client7/infra")
    }

    @Test("a root outside the peer set is named against it anyway")
    func nameAmongPeers() {
        let target = directory("/Users/f/project1/infra")

        #expect(
            ProjectDisplayNames.name(
                for: target,
                among: [directory("/Users/f/project2/infra")]
            ) == "project1/infra"
        )
        #expect(
            ProjectDisplayNames.name(for: target, among: []) == "infra"
        )
        #expect(
            ProjectDisplayNames.name(
                for: target,
                among: [directory("/Users/f/pine")]
            ) == "infra"
        )
    }
}
