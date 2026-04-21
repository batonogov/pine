//
//  ExternalToolResolverTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("ExternalToolResolver")
struct ExternalToolResolverTests {

    // MARK: - PATH parsing

    @Test("Parses PATH string into directories")
    func parsesPATH() {
        let resolver = ExternalToolResolver(
            pathString: "/usr/bin:/usr/local/bin:/opt/homebrew/bin"
        )
        #expect(resolver.searchDirectories.contains("/usr/bin"))
        #expect(resolver.searchDirectories.contains("/usr/local/bin"))
        #expect(resolver.searchDirectories.contains("/opt/homebrew/bin"))
    }

    @Test("Empty PATH string still includes well-known directories")
    func emptyPATHIncludesWellKnown() {
        let resolver = ExternalToolResolver(
            pathString: ""
        )
        #expect(resolver.searchDirectories.contains("/opt/homebrew/bin"))
        #expect(resolver.searchDirectories.contains("/usr/local/bin"))
        #expect(resolver.searchDirectories.contains("/usr/bin"))
    }

    @Test("Nil PATH string still includes well-known directories")
    func nilPATHIncludesWellKnown() {
        let resolver = ExternalToolResolver(
            pathString: nil
        )
        #expect(resolver.searchDirectories.contains("/opt/homebrew/bin"))
        #expect(resolver.searchDirectories.contains("/usr/local/bin"))
        #expect(resolver.searchDirectories.contains("/usr/bin"))
    }

    @Test("Deduplicates directories from PATH and well-known")
    func deduplicates() {
        let resolver = ExternalToolResolver(
            pathString: "/usr/bin:/usr/bin:/opt/homebrew/bin"
        )
        let count = resolver.searchDirectories.filter { $0 == "/usr/bin" }.count
        #expect(count == 1)
    }

    // MARK: - Tool resolution

    @Test("Finds an existing executable (git)")
    func findsGit() {
        let resolver = ExternalToolResolver(
            pathString: "/usr/bin"
        )
        let path = resolver.resolve(tool: "git")
        #expect(path != nil)
        #expect(path?.hasSuffix("/git") == true)
    }

    @Test("Returns nil for a non-existent tool")
    func returnsNilForMissing() {
        let resolver = ExternalToolResolver(
            pathString: "/usr/bin"
        )
        let path = resolver.resolve(tool: "pine_nonexistent_tool_12345")
        #expect(path == nil)
    }

    @Test("Returns nil when tool is a directory, not a file")
    func rejectsDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine_test_\(UUID().uuidString)")
        let toolDir = tmpDir.appendingPathComponent("fakeTool")
        try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolver = ExternalToolResolver(
            pathString: tmpDir.path
        )
        let path = resolver.resolve(tool: "fakeTool")
        #expect(path == nil)
    }

    // MARK: - Caching

    @Test("Caches resolved path after first lookup")
    func cachesResolvedPath() {
        let resolver = ExternalToolResolver(
            pathString: "/usr/bin"
        )
        let first = resolver.resolve(tool: "git")
        let second = resolver.resolve(tool: "git")
        #expect(first == second)
        #expect(first != nil)
    }

    @Test("Caches nil result for missing tool")
    func cachesNilResult() {
        let resolver = ExternalToolResolver(
            pathString: "/usr/bin"
        )
        let first = resolver.resolve(tool: "pine_nonexistent_12345")
        let second = resolver.resolve(tool: "pine_nonexistent_12345")
        #expect(first == nil)
        #expect(second == nil)
    }

    @Test("clearCache clears cached results")
    func clearCacheWorks() {
        let resolver = ExternalToolResolver(
            pathString: "/usr/bin"
        )
        _ = resolver.resolve(tool: "git")
        resolver.clearCache()
        // After clearing, should resolve again (still finds it)
        let after = resolver.resolve(tool: "git")
        #expect(after != nil)
    }

    // MARK: - Absolute path passthrough

    @Test("Absolute path bypasses search if executable exists")
    func absolutePathPassthrough() {
        let resolver = ExternalToolResolver(
            pathString: ""
        )
        let path = resolver.resolve(tool: "/usr/bin/git")
        #expect(path == "/usr/bin/git")
    }

    @Test("Absolute path returns nil if not executable")
    func absolutePathNonExistent() {
        let resolver = ExternalToolResolver(
            pathString: ""
        )
        let path = resolver.resolve(tool: "/nonexistent/path/tool")
        #expect(path == nil)
    }

    // MARK: - Thread safety

    @Test("Concurrent resolve from multiple threads does not crash")
    func concurrentResolveThreadSafety() {
        let resolver = ExternalToolResolver(
            pathString: "/usr/bin"
        )
        let group = DispatchGroup()
        let iterations = 10

        for idx in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                // Mix of found and not-found tools to exercise both cache paths
                let tool = idx % 2 == 0 ? "git" : "pine_nonexistent_\(idx)"
                _ = resolver.resolve(tool: tool)
                // Also exercise clearCache concurrently
                if idx % 3 == 0 {
                    resolver.clearCache()
                }
            }
        }

        let result = group.wait(timeout: .now() + 10)
        #expect(result == .success)

        // After all concurrent access, resolver should still work correctly
        let gitPath = resolver.resolve(tool: "git")
        #expect(gitPath != nil)
    }
}
