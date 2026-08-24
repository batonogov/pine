//
//  ProductionSourceScanTests.swift
//  PineTests
//
//  The enumeration every repository-scanning guard depends on (#1508).
//

import Foundation
import Testing

@testable import Pine

@Suite("Production source scan")
struct ProductionSourceScanTests {
    // MARK: - The hidden-file trap

    /// The defect in one assertion, staged the way it really occurs.
    ///
    /// It is not the dotted ancestor name that empties the scan — a directory
    /// named `.worktrees` containing ordinary files enumerates fine. It is the
    /// `UF_HIDDEN` filesystem flag, which in an agent worktree under
    /// `.claude/worktrees/…` is set on the source files themselves. With that
    /// flag set, `.skipsHiddenFiles` returns nothing at all.
    @Test("files carrying the hidden flag are still scanned")
    func hiddenFlagDoesNotEmptyTheScan() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.makeTree(
            underHiddenAncestor: true,
            files: ["Alpha.swift", "Beta.swift"],
            markingFilesHidden: true
        )

        // The option that caused #1508, demonstrated rather than described.
        #expect(fixture.swiftFilesSkippingHidden(under: root).isEmpty)

        let scanned = try ProductionSourceScan.swiftFileURLs(under: root)
        #expect(scanned.map(\.lastPathComponent) == ["Alpha.swift", "Beta.swift"])
    }

    /// The control for the test above: same dotted ancestor, no flag. The
    /// enumeration is unaffected, which is why "hidden ancestor" alone is not
    /// the explanation and the fix must not rely on it being one.
    @Test("a dotted ancestor alone does not empty the old enumeration")
    func dottedAncestorAloneIsHarmless() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.makeTree(
            underHiddenAncestor: true,
            files: ["Alpha.swift"],
            markingFilesHidden: false
        )

        #expect(fixture.swiftFilesSkippingHidden(under: root).count == 1)
        #expect(try ProductionSourceScan.swiftFileURLs(under: root).count == 1)
    }

    /// The distinction the scan has to make: hidden *below* the root is the
    /// caller's own build detritus and stays excluded; hidden *above* it is
    /// none of the scan's business.
    @Test("hidden directories below the root are still excluded")
    func hiddenDescendantsAreExcluded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.makeTree(
            underHiddenAncestor: false,
            files: ["Visible.swift", ".build/Generated.swift", ".hidden.swift"]
        )

        let scanned = try ProductionSourceScan.swiftFileURLs(under: root)

        #expect(scanned.map(\.lastPathComponent) == ["Visible.swift"])
    }

    @Test("both rules apply at once: hidden ancestor, hidden descendant")
    func hiddenAncestorAndDescendantTogether() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.makeTree(
            underHiddenAncestor: true,
            files: ["Kept.swift", ".derived/Dropped.swift"]
        )

        let scanned = try ProductionSourceScan.swiftFileURLs(under: root)

        #expect(scanned.map(\.lastPathComponent) == ["Kept.swift"])
    }

    // MARK: - Failing closed

    /// The important half of #1508: whatever the enumeration options end up
    /// being, a completeness guard that finds no inputs must fail.
    @Test("an empty directory is an error, not an empty list")
    func emptyScanThrows() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.makeTree(
            underHiddenAncestor: false,
            files: []
        )

        #expect(throws: ProductionSourceScan.EmptyScanError.self) {
            try ProductionSourceScan.swiftFileURLs(under: root)
        }
    }

    @Test("a directory with no Swift files is an error too")
    func nonSwiftContentThrows() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.makeTree(
            underHiddenAncestor: false,
            files: ["README.md", "Info.plist"]
        )

        #expect(throws: ProductionSourceScan.EmptyScanError.self) {
            try ProductionSourceScan.swiftFileURLs(under: root)
        }
    }

    @Test("a missing directory is an error, not an empty list")
    func missingRootThrows() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let missing = try fixture
            .makeTree(underHiddenAncestor: false, files: ["Kept.swift"])
            .appendingPathComponent("NoSuchDirectory", isDirectory: true)

        #expect(throws: ProductionSourceScan.EmptyScanError.self) {
            try ProductionSourceScan.swiftFileURLs(under: missing)
        }
    }

    // MARK: - Repository root

    /// Found by content, so a suite that moves into a subdirectory does not
    /// silently scan the wrong tree — which is how a fixed number of
    /// `deletingLastPathComponent()` calls fails.
    @Test("the repository root is located by Pine.xcodeproj, not by depth")
    func repositoryRootIsFoundByContent() throws {
        let root = try ProductionSourceScan.repositoryRoot()

        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Pine.xcodeproj").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Pine/PineApp.swift").path
        ))
    }

    @Test("a path outside any checkout has no repository root")
    func noRepositoryRootOutsideTheCheckout() {
        #expect(
            throws: ProductionSourceScan.RepositoryRootNotFoundError.self
        ) {
            try ProductionSourceScan.repositoryRoot(from: "/tmp/nowhere.swift")
        }
    }

    // MARK: - The real tree

    /// The scan that every guard in this target actually performs. The count
    /// is deliberately a floor rather than an exact number — this asserts the
    /// scan reaches the production tree, not how large the tree is.
    @Test("the production scan finds Pine's sources from this test file")
    func productionScanReachesTheRealTree() throws {
        let urls = try ProductionSourceScan.productionSwiftFileURLs()

        #expect(urls.count > 100)
        #expect(urls.contains { $0.lastPathComponent == "PineApp.swift" })
        #expect(urls.allSatisfy { $0.pathExtension == "swift" })
        // Sorted, so a guard reporting offenders reports them in a stable
        // order run to run.
        #expect(urls.map(\.path) == urls.map(\.path).sorted())
    }

    /// The scan must be complete wherever it runs — CI's plain checkout, a
    /// developer's clone, or an agent worktree whose files are flagged hidden.
    /// This asserts the invariant that distinguishes the two enumerations
    /// without assuming which environment the suite is in: the correct scan
    /// never returns fewer files than the one that skips hidden items.
    @Test("the production scan loses nothing the old enumeration kept")
    func productionScanIsNeverSmallerThanTheOldOne() throws {
        let sourceRoot = try ProductionSourceScan.repositoryRoot()
            .appendingPathComponent("Pine")
        let skippingHidden = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        let scanned = try ProductionSourceScan.productionSwiftFileURLs()

        #expect(scanned.count >= skippingHidden.count)
        // In an agent worktree the right-hand side is 0 and the left is the
        // whole tree; in a plain checkout the two agree.
        #expect(scanned.count > 100)
    }

    // MARK: - Fixture

    private final class Fixture {
        private let base: URL

        init() throws {
            base = FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    "PineSourceScan-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true
            )
        }

        /// The `.swift` files the pre-#1508 enumeration would have found.
        func swiftFilesSkippingHidden(under root: URL) -> [URL] {
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )?.compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
        }

        /// Builds a tree of empty files, optionally below a dotted directory
        /// and optionally carrying the `UF_HIDDEN` flag an agent worktree
        /// puts on every file, and returns the root a scan is pointed at.
        func makeTree(
            underHiddenAncestor: Bool,
            files: [String],
            markingFilesHidden: Bool = false
        ) throws -> URL {
            let container = underHiddenAncestor
                ? base.appendingPathComponent(".worktrees", isDirectory: true)
                : base
            let root = container.appendingPathComponent(
                "Sources",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            for file in files {
                let url = root.appendingPathComponent(file)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: url.path, contents: Data())
                if markingFilesHidden {
                    var hidden = url
                    var values = URLResourceValues()
                    values.isHidden = true
                    try hidden.setResourceValues(values)
                }
            }
            return root
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: base)
        }
    }
}
