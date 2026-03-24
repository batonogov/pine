//
//  BreadcrumbProviderTests.swift
//  PineTests
//
//  Tests for BreadcrumbProvider — path decomposition, siblings, truncation.
//

import Testing
import Foundation
@testable import Pine

@Suite("BreadcrumbProvider")
struct BreadcrumbProviderTests {

    // MARK: - Path decomposition

    @Test("File at project root produces two segments: root + file")
    func fileAtRoot() {
        let root = URL(fileURLWithPath: "/Users/dev/MyProject")
        let file = URL(fileURLWithPath: "/Users/dev/MyProject/main.swift")

        let segments = BreadcrumbProvider.segments(for: file, relativeTo: root)

        #expect(segments.count == 2)
        #expect(segments[0].name == "MyProject")
        #expect(segments[0].isDirectory == true)
        #expect(segments[0].parentURL == nil)
        #expect(segments[1].name == "main.swift")
        #expect(segments[1].isDirectory == false)
        #expect(segments[1].parentURL == root)
    }

    @Test("Nested file produces segments for each path component")
    func nestedFile() {
        let root = URL(fileURLWithPath: "/Users/dev/MyProject")
        let file = URL(fileURLWithPath: "/Users/dev/MyProject/src/components/Button.swift")

        let segments = BreadcrumbProvider.segments(for: file, relativeTo: root)

        #expect(segments.count == 4)
        #expect(segments.map(\.name) == ["MyProject", "src", "components", "Button.swift"])
        #expect(segments[0].isDirectory == true) // MyProject
        #expect(segments[1].isDirectory == true) // src
        #expect(segments[2].isDirectory == true) // components
        #expect(segments[3].isDirectory == false) // Button.swift
    }

    @Test("File outside project root shows only filename")
    func fileOutsideProject() {
        let root = URL(fileURLWithPath: "/Users/dev/MyProject")
        let file = URL(fileURLWithPath: "/tmp/scratch.txt")

        let segments = BreadcrumbProvider.segments(for: file, relativeTo: root)

        #expect(segments.count == 1)
        #expect(segments[0].name == "scratch.txt")
        #expect(segments[0].isDirectory == false)
    }

    @Test("Deeply nested file (10+ levels) produces correct segment count")
    func deeplyNestedFile() {
        let root = URL(fileURLWithPath: "/project")
        let file = URL(fileURLWithPath: "/project/a/b/c/d/e/f/g/h/i/j/file.txt")

        let segments = BreadcrumbProvider.segments(for: file, relativeTo: root)

        // root + 10 dirs + file = 12 segments
        #expect(segments.count == 12)
        #expect(segments.first?.name == "project")
        #expect(segments.last?.name == "file.txt")
        #expect(segments.last?.isDirectory == false)
    }

    @Test("Unicode directory names are handled correctly")
    func unicodeDirectoryNames() {
        let root = URL(fileURLWithPath: "/Users/dev/Проект")
        let file = URL(fileURLWithPath: "/Users/dev/Проект/исходники/файл.swift")

        let segments = BreadcrumbProvider.segments(for: file, relativeTo: root)

        #expect(segments.count == 3)
        #expect(segments.map(\.name) == ["Проект", "исходники", "файл.swift"])
    }

    @Test("Each segment has correct parentURL")
    func parentURLs() {
        let root = URL(fileURLWithPath: "/project")
        let file = URL(fileURLWithPath: "/project/src/main.swift")

        let segments = BreadcrumbProvider.segments(for: file, relativeTo: root)

        #expect(segments[0].parentURL == nil) // root has no parent
        #expect(segments[1].parentURL == root) // src's parent is root
        #expect(segments[2].parentURL == URL(fileURLWithPath: "/project/src")) // main.swift's parent is src
    }

    @Test("Each segment's id equals its full URL")
    func segmentIDs() {
        let root = URL(fileURLWithPath: "/project")
        let file = URL(fileURLWithPath: "/project/src/main.swift")

        let segments = BreadcrumbProvider.segments(for: file, relativeTo: root)

        #expect(segments[0].url == root)
        #expect(segments[1].url == URL(fileURLWithPath: "/project/src"))
        #expect(segments[2].url == file)
    }

    // MARK: - Truncation

    @Test("No truncation when segments fit")
    func noTruncation() {
        let segments = makeSegments(count: 3)
        let (ellipsis, visible) = BreadcrumbProvider.truncate(segments, maxVisible: 5)

        #expect(ellipsis == false)
        #expect(visible.count == 3)
    }

    @Test("Truncation shows ellipsis and keeps last N segments")
    func truncationKeepsLastSegments() {
        let segments = makeSegments(count: 8)
        let (ellipsis, visible) = BreadcrumbProvider.truncate(segments, maxVisible: 3)

        #expect(ellipsis == true)
        #expect(visible.count == 3)
        #expect(visible.map(\.name) == ["seg5", "seg6", "seg7"])
    }

    @Test("Truncation with exact count produces no ellipsis")
    func truncationExactCount() {
        let segments = makeSegments(count: 4)
        let (ellipsis, visible) = BreadcrumbProvider.truncate(segments, maxVisible: 4)

        #expect(ellipsis == false)
        #expect(visible.count == 4)
    }

    @Test("Truncation with maxVisible 0 returns ellipsis with empty segments")
    func truncationZeroMax() {
        let segments = makeSegments(count: 3)
        let (ellipsis, visible) = BreadcrumbProvider.truncate(segments, maxVisible: 0)

        #expect(ellipsis == false)
        #expect(visible.count == 3)
    }

    // MARK: - Siblings (filesystem tests)

    @Test("Siblings for a directory lists its contents")
    func siblingsForDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreadcrumbTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create test structure
        let subdir = tempDir.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "hello".write(to: tempDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "world".write(to: tempDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        let segment = BreadcrumbSegment(
            id: tempDir,
            name: tempDir.lastPathComponent,
            isDirectory: true,
            parentURL: nil
        )

        let siblings = BreadcrumbProvider.siblings(for: segment, projectRoot: tempDir)

        #expect(siblings.count == 3)
        // Folders first
        #expect(siblings[0].isDirectory == true)
        #expect(siblings[0].name == "subfolder")
        // Then files alphabetically
        #expect(siblings[1].name == "file1.txt")
        #expect(siblings[2].name == "file2.txt")
    }

    @Test("Siblings for a file lists its parent directory contents")
    func siblingsForFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreadcrumbTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "a".write(to: tempDir.appendingPathComponent("alpha.swift"), atomically: true, encoding: .utf8)
        try "b".write(to: tempDir.appendingPathComponent("beta.swift"), atomically: true, encoding: .utf8)

        let segment = BreadcrumbSegment(
            id: tempDir.appendingPathComponent("alpha.swift"),
            name: "alpha.swift",
            isDirectory: false,
            parentURL: tempDir
        )

        let siblings = BreadcrumbProvider.siblings(for: segment, projectRoot: tempDir)

        #expect(siblings.count == 2)
        #expect(siblings.map(\.name).contains("alpha.swift"))
        #expect(siblings.map(\.name).contains("beta.swift"))
    }

    // MARK: - Helpers

    private func makeSegments(count: Int) -> [BreadcrumbSegment] {
        (0..<count).map { i in
            BreadcrumbSegment(
                id: URL(fileURLWithPath: "/project/seg\(i)"),
                name: "seg\(i)",
                isDirectory: i < count - 1,
                parentURL: i > 0 ? URL(fileURLWithPath: "/project/seg\(i - 1)") : nil
            )
        }
    }
}
