//
//  PaneSessionTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

// swiftlint:disable type_body_length file_length

@Suite("Pane Session Persistence Tests")
struct PaneSessionTests {

    private let suiteName = "PineTests.PaneSession.\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return defaults
    }

    private func cleanupDefaults(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func createFile(in dir: URL, name: String) -> URL {
        let file = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: file.path, contents: Data("// test".utf8))
        return file
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - PaneTabState Codable round-trip

    @Test func paneTabStateEncodesDecodesAllFields() throws {
        let state = PaneTabState(
            openFilePaths: ["/tmp/a.swift", "/tmp/b.swift"],
            activeFilePath: "/tmp/a.swift",
            editorStates: [
                "/tmp/a.swift": PerTabEditorState(
                    cursorPosition: 42,
                    scrollOffset: 100.5,
                    foldedRanges: [
                        PerTabEditorState.SerializableFoldRange(
                            startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 50, kind: "braces"
                        )
                    ]
                )
            ],
            pinnedPaths: ["/tmp/a.swift"],
            highlightingDisabledPaths: ["/tmp/b.swift"],
            previewModes: ["/tmp/a.swift": "split"]
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PaneTabState.self, from: data)

        #expect(decoded.openFilePaths == ["/tmp/a.swift", "/tmp/b.swift"])
        #expect(decoded.activeFilePath == "/tmp/a.swift")
        #expect(decoded.pinnedPaths == ["/tmp/a.swift"])
        #expect(decoded.highlightingDisabledPaths == ["/tmp/b.swift"])
        #expect(decoded.previewModes == ["/tmp/a.swift": "split"])
        #expect(decoded.editorStates?["/tmp/a.swift"]?.cursorPosition == 42)
        #expect(decoded.editorStates?["/tmp/a.swift"]?.scrollOffset == 100.5)
        #expect(decoded.editorStates?["/tmp/a.swift"]?.foldedRanges?.count == 1)
    }

    @Test func paneTabStateEncodesDecodesNilFields() throws {
        let state = PaneTabState(
            openFilePaths: [],
            activeFilePath: nil,
            editorStates: nil,
            pinnedPaths: nil,
            highlightingDisabledPaths: nil,
            previewModes: nil
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PaneTabState.self, from: data)

        #expect(decoded.openFilePaths.isEmpty)
        #expect(decoded.activeFilePath == nil)
        #expect(decoded.editorStates == nil)
        #expect(decoded.pinnedPaths == nil)
        #expect(decoded.highlightingDisabledPaths == nil)
        #expect(decoded.previewModes == nil)
    }

    @Test func paneTabStateEquality() {
        let state1 = PaneTabState(
            openFilePaths: ["/a.swift"],
            activeFilePath: "/a.swift",
            editorStates: nil,
            pinnedPaths: nil,
            highlightingDisabledPaths: nil,
            previewModes: nil
        )
        let state2 = PaneTabState(
            openFilePaths: ["/a.swift"],
            activeFilePath: "/a.swift",
            editorStates: nil,
            pinnedPaths: nil,
            highlightingDisabledPaths: nil,
            previewModes: nil
        )
        #expect(state1 == state2)
    }

    // MARK: - PaneTabState filtering

    @Test func paneTabStateFilteredRemovesOutsideProjectRoot() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let insideFile = createFile(in: tempDir, name: "inside.swift")
        let outsideDir = try makeTempDirectory()
        defer { cleanup(outsideDir) }
        let outsideFile = createFile(in: outsideDir, name: "outside.swift")

        let state = PaneTabState(
            openFilePaths: [insideFile.path, outsideFile.path],
            activeFilePath: outsideFile.path,
            editorStates: [
                insideFile.path: PerTabEditorState(cursorPosition: 0, scrollOffset: 0),
                outsideFile.path: PerTabEditorState(cursorPosition: 10, scrollOffset: 50)
            ],
            pinnedPaths: [insideFile.path, outsideFile.path],
            highlightingDisabledPaths: [outsideFile.path],
            previewModes: [outsideFile.path: "preview"]
        )

        let prefix = tempDir.path + "/"
        let filtered = state.filtered(withPrefix: prefix)

        #expect(filtered.openFilePaths == [insideFile.path])
        #expect(filtered.activeFilePath == nil)
        #expect(filtered.editorStates?.count == 1)
        #expect(filtered.editorStates?[insideFile.path] != nil)
        #expect(filtered.pinnedPaths == [insideFile.path])
        #expect(filtered.highlightingDisabledPaths == nil)
        #expect(filtered.previewModes == nil)
    }

    @Test func paneTabStateFilteredRemovesDeletedFiles() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let existingFile = createFile(in: tempDir, name: "exists.swift")
        let deletedPath = tempDir.appendingPathComponent("gone.swift").path

        let state = PaneTabState(
            openFilePaths: [existingFile.path, deletedPath],
            activeFilePath: deletedPath,
            editorStates: [deletedPath: PerTabEditorState(cursorPosition: 0, scrollOffset: 0)],
            pinnedPaths: [deletedPath],
            highlightingDisabledPaths: [deletedPath],
            previewModes: [deletedPath: "split"]
        )

        let prefix = tempDir.path + "/"
        let filtered = state.filtered(withPrefix: prefix)

        #expect(filtered.openFilePaths == [existingFile.path])
        #expect(filtered.activeFilePath == nil)
        #expect(filtered.editorStates == nil)
        #expect(filtered.pinnedPaths == nil)
        #expect(filtered.highlightingDisabledPaths == nil)
        #expect(filtered.previewModes == nil)
    }

    // MARK: - SessionState with single pane round-trip

    @Test func saveAndLoadSinglePaneRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file = createFile(in: tempDir, name: "main.swift")
        let paneID = PaneID()
        let tree = PaneNode.leaf(paneID, .editor)

        let paneState = PaneTabState(
            openFilePaths: [file.path],
            activeFilePath: file.path,
            editorStates: [file.path: PerTabEditorState(cursorPosition: 10, scrollOffset: 25.0)],
            pinnedPaths: nil,
            highlightingDisabledPaths: nil,
            previewModes: nil
        )

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [file],
            activeFileURL: file,
            paneTree: tree,
            activePaneUUID: paneID.id.uuidString,
            paneStates: [paneID.id.uuidString: paneState],
            defaults: defaults
        )

        let loaded = try #require(SessionState.load(for: tempDir, defaults: defaults))

        #expect(loaded.hasPaneTree)
        #expect(loaded.paneTree == tree)
        #expect(loaded.activePaneUUID == paneID.id.uuidString)
        #expect(loaded.paneStates?.count == 1)

        let loadedPaneState = try #require(loaded.paneStates?[paneID.id.uuidString])
        #expect(loadedPaneState.openFilePaths == [file.path])
        #expect(loadedPaneState.activeFilePath == file.path)
        #expect(loadedPaneState.editorStates?[file.path]?.cursorPosition == 10)
    }

    // MARK: - Multi-pane round-trip (2 splits)

    @Test func saveAndLoadTwoPaneSplitRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file1 = createFile(in: tempDir, name: "left.swift")
        let file2 = createFile(in: tempDir, name: "right.swift")

        let leftID = PaneID()
        let rightID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(leftID, .editor),
            second: .leaf(rightID, .editor),
            ratio: 0.6
        )

        let leftState = PaneTabState(
            openFilePaths: [file1.path],
            activeFilePath: file1.path,
            editorStates: nil,
            pinnedPaths: nil,
            highlightingDisabledPaths: nil,
            previewModes: nil
        )
        let rightState = PaneTabState(
            openFilePaths: [file2.path],
            activeFilePath: file2.path,
            editorStates: nil,
            pinnedPaths: [file2.path],
            highlightingDisabledPaths: nil,
            previewModes: nil
        )

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [file1, file2],
            paneTree: tree,
            activePaneUUID: leftID.id.uuidString,
            paneStates: [
                leftID.id.uuidString: leftState,
                rightID.id.uuidString: rightState
            ],
            defaults: defaults
        )

        let loaded = try #require(SessionState.load(for: tempDir, defaults: defaults))

        #expect(loaded.hasPaneTree)
        #expect(loaded.paneTree == tree)
        #expect(loaded.resolvedActivePaneUUID == leftID.id.uuidString)
        #expect(loaded.paneStates?.count == 2)

        let loadedLeft = try #require(loaded.paneStates?[leftID.id.uuidString])
        let loadedRight = try #require(loaded.paneStates?[rightID.id.uuidString])
        #expect(loadedLeft.openFilePaths == [file1.path])
        #expect(loadedRight.pinnedPaths == [file2.path])
    }

    // MARK: - Backward compatibility: old format (no paneTree) loads as single pane

    @Test func legacyFormatWithoutPaneTreeLoadsAsSinglePane() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file = createFile(in: tempDir, name: "legacy.swift")

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Save without pane tree fields (legacy format)
        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [file],
            activeFileURL: file,
            defaults: defaults
        )

        let loaded = try #require(SessionState.load(for: tempDir, defaults: defaults))

        #expect(!loaded.hasPaneTree)
        #expect(loaded.paneTree == nil)
        #expect(loaded.activePaneUUID == nil)
        #expect(loaded.paneStates == nil)
        #expect(loaded.resolvedActivePaneUUID == nil)

        // Legacy fields should work
        #expect(loaded.existingFileURLs.count == 1)
        #expect(loaded.activeFileURL?.path == file.path)
    }

    @Test func oldJSONWithoutPaneFieldsDecodes() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Manually write old-format JSON to simulate pre-pane sessions
        let oldJSON: [String: Any] = [
            "projectPath": tempDir.path,
            "openFilePaths": [String](),
            "activeFilePath": NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: oldJSON)
        let key = "sessionState:" + tempDir.resolvingSymlinksInPath().path
        defaults.set(data, forKey: key)

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.hasPaneTree == false)
        #expect(loaded?.paneTree == nil)
        #expect(loaded?.paneStates == nil)
    }

    // MARK: - Deep tree (3+ splits) round-trip

    @Test func deepTreeThreeSplitsRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file1 = createFile(in: tempDir, name: "a.swift")
        let file2 = createFile(in: tempDir, name: "b.swift")
        let file3 = createFile(in: tempDir, name: "c.swift")

        let id1 = PaneID()
        let id2 = PaneID()
        let id3 = PaneID()

        // Tree: horizontal split, left is vertical split (id1 / id2), right is id3
        let tree = PaneNode.split(
            .horizontal,
            first: PaneNode.split(
                .vertical,
                first: .leaf(id1, .editor),
                second: .leaf(id2, .editor),
                ratio: 0.5
            ),
            second: .leaf(id3, .editor),
            ratio: 0.7
        )

        let states: [String: PaneTabState] = [
            id1.id.uuidString: PaneTabState(
                openFilePaths: [file1.path], activeFilePath: file1.path,
                editorStates: nil, pinnedPaths: nil, highlightingDisabledPaths: nil, previewModes: nil
            ),
            id2.id.uuidString: PaneTabState(
                openFilePaths: [file2.path], activeFilePath: file2.path,
                editorStates: nil, pinnedPaths: nil, highlightingDisabledPaths: nil, previewModes: nil
            ),
            id3.id.uuidString: PaneTabState(
                openFilePaths: [file3.path], activeFilePath: file3.path,
                editorStates: nil, pinnedPaths: nil, highlightingDisabledPaths: nil, previewModes: nil
            )
        ]

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [file1, file2, file3],
            paneTree: tree,
            activePaneUUID: id2.id.uuidString,
            paneStates: states,
            defaults: defaults
        )

        let loaded = try #require(SessionState.load(for: tempDir, defaults: defaults))

        #expect(loaded.paneTree == tree)
        #expect(loaded.paneTree?.leafCount == 3)
        #expect(loaded.paneTree?.depth == 3)
        #expect(loaded.resolvedActivePaneUUID == id2.id.uuidString)
        #expect(loaded.paneStates?.count == 3)

        let leafIDs = loaded.paneTree?.leafIDs.map(\.id.uuidString) ?? []
        #expect(leafIDs.contains(id1.id.uuidString))
        #expect(leafIDs.contains(id2.id.uuidString))
        #expect(leafIDs.contains(id3.id.uuidString))
    }

    // MARK: - Empty pane (no open files) round-trip

    @Test func emptyPaneRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let paneID = PaneID()
        let tree = PaneNode.leaf(paneID, .editor)
        let emptyState = PaneTabState(
            openFilePaths: [],
            activeFilePath: nil,
            editorStates: nil,
            pinnedPaths: nil,
            highlightingDisabledPaths: nil,
            previewModes: nil
        )

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [],
            paneTree: tree,
            activePaneUUID: paneID.id.uuidString,
            paneStates: [paneID.id.uuidString: emptyState],
            defaults: defaults
        )

        let loaded = try #require(SessionState.load(for: tempDir, defaults: defaults))

        #expect(loaded.hasPaneTree)
        let loadedState = try #require(loaded.paneStates?[paneID.id.uuidString])
        #expect(loadedState.openFilePaths.isEmpty)
        #expect(loadedState.activeFilePath == nil)
    }

    // MARK: - activePaneUUID not found -> falls back to first leaf

    @Test func activePaneUUIDNotFoundFallsBackToFirstLeaf() throws {
        let leftID = PaneID()
        let rightID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(leftID, .editor),
            second: .leaf(rightID, .editor),
            ratio: 0.5
        )

        let state = SessionState(
            projectPath: "/tmp/project",
            openFilePaths: [],
            paneTree: tree,
            activePaneUUID: UUID().uuidString // non-existent UUID
        )

        // Should fall back to first leaf
        #expect(state.resolvedActivePaneUUID == leftID.id.uuidString)
    }

    @Test func activePaneUUIDNilFallsBackToFirstLeaf() throws {
        let paneID = PaneID()
        let tree = PaneNode.leaf(paneID, .editor)

        let state = SessionState(
            projectPath: "/tmp/project",
            openFilePaths: [],
            paneTree: tree,
            activePaneUUID: nil
        )

        #expect(state.resolvedActivePaneUUID == paneID.id.uuidString)
    }

    @Test func resolvedActivePaneUUIDNilWhenNoPaneTree() {
        let state = SessionState(
            projectPath: "/tmp/project",
            openFilePaths: []
        )
        #expect(state.resolvedActivePaneUUID == nil)
    }

    // MARK: - Mixed content types (editor + terminal panes)

    @Test func mixedEditorAndTerminalPanesRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file = createFile(in: tempDir, name: "code.swift")

        let editorID = PaneID()
        let terminalID = PaneID()
        let tree = PaneNode.split(
            .vertical,
            first: .leaf(editorID, .editor),
            second: .leaf(terminalID, .terminal),
            ratio: 0.7
        )

        let editorState = PaneTabState(
            openFilePaths: [file.path],
            activeFilePath: file.path,
            editorStates: nil,
            pinnedPaths: nil,
            highlightingDisabledPaths: nil,
            previewModes: nil
        )
        // Terminal pane has empty tab state (terminals don't have file tabs)
        let terminalState = PaneTabState(
            openFilePaths: [],
            activeFilePath: nil,
            editorStates: nil,
            pinnedPaths: nil,
            highlightingDisabledPaths: nil,
            previewModes: nil
        )

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [file],
            paneTree: tree,
            activePaneUUID: editorID.id.uuidString,
            paneStates: [
                editorID.id.uuidString: editorState,
                terminalID.id.uuidString: terminalState
            ],
            defaults: defaults
        )

        let loaded = try #require(SessionState.load(for: tempDir, defaults: defaults))

        #expect(loaded.paneTree == tree)

        // Verify content types preserved
        #expect(loaded.paneTree?.content(for: editorID) == .editor)
        #expect(loaded.paneTree?.content(for: terminalID) == .terminal)

        let loadedEditor = try #require(loaded.paneStates?[editorID.id.uuidString])
        let loadedTerminal = try #require(loaded.paneStates?[terminalID.id.uuidString])
        #expect(loadedEditor.openFilePaths == [file.path])
        #expect(loadedTerminal.openFilePaths.isEmpty)
    }

    // MARK: - Split ratios preserved

    @Test func splitRatiosPreservedInRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let id1 = PaneID()
        let id2 = PaneID()
        let id3 = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(id1, .editor),
            second: PaneNode.split(
                .vertical,
                first: .leaf(id2, .editor),
                second: .leaf(id3, .terminal),
                ratio: 0.3
            ),
            ratio: 0.8
        )

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [],
            paneTree: tree,
            activePaneUUID: id1.id.uuidString,
            paneStates: [:],
            defaults: defaults
        )

        let loaded = try #require(SessionState.load(for: tempDir, defaults: defaults))
        #expect(loaded.paneTree == tree)
    }

    // MARK: - existingPaneStates filters correctly

    @Test func existingPaneStatesFiltersDeletedFiles() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let existing = createFile(in: tempDir, name: "exists.swift")
        let deletedPath = tempDir.appendingPathComponent("gone.swift").path

        let paneID = PaneID()
        let state = SessionState(
            projectPath: tempDir.path,
            openFilePaths: [],
            paneTree: PaneNode.leaf(paneID, .editor),
            paneStates: [
                paneID.id.uuidString: PaneTabState(
                    openFilePaths: [existing.path, deletedPath],
                    activeFilePath: deletedPath,
                    editorStates: nil,
                    pinnedPaths: nil,
                    highlightingDisabledPaths: nil,
                    previewModes: nil
                )
            ]
        )

        let filteredStates = try #require(state.existingPaneStates)
        let paneState = try #require(filteredStates[paneID.id.uuidString])
        #expect(paneState.openFilePaths == [existing.path])
        #expect(paneState.activeFilePath == nil)
    }

    // MARK: - hasPaneTree property

    @Test func hasPaneTreeTrueWhenTreePresent() {
        let state = SessionState(
            projectPath: "/tmp",
            openFilePaths: [],
            paneTree: .leaf(PaneID(), .editor)
        )
        #expect(state.hasPaneTree)
    }

    @Test func hasPaneTreeFalseWhenNoTree() {
        let state = SessionState(
            projectPath: "/tmp",
            openFilePaths: []
        )
        #expect(!state.hasPaneTree)
    }

    // MARK: - Deeply nested tree (4 splits, depth 5)

    @Test func deeplyNestedFourSplitsRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let ids = (0..<5).map { _ in PaneID() }
        // Build: split(split(split(split(leaf, leaf), leaf), leaf), leaf)
        var tree = PaneNode.leaf(ids[0], .editor)
        for idx in 1..<5 {
            tree = .split(
                idx.isMultiple(of: 2) ? .horizontal : .vertical,
                first: tree,
                second: .leaf(ids[idx], .editor),
                ratio: CGFloat(idx) * 0.1 + 0.3
            )
        }

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        var states: [String: PaneTabState] = [:]
        for id in ids {
            states[id.id.uuidString] = PaneTabState(
                openFilePaths: [], activeFilePath: nil,
                editorStates: nil, pinnedPaths: nil,
                highlightingDisabledPaths: nil, previewModes: nil
            )
        }

        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [],
            paneTree: tree,
            activePaneUUID: ids[3].id.uuidString,
            paneStates: states,
            defaults: defaults
        )

        let loaded = try #require(SessionState.load(for: tempDir, defaults: defaults))

        #expect(loaded.paneTree == tree)
        #expect(loaded.paneTree?.leafCount == 5)
        #expect(loaded.paneTree?.depth == 5)
        #expect(loaded.resolvedActivePaneUUID == ids[3].id.uuidString)
    }

    // MARK: - Pane tree with all PaneContent types

    @Test func allPaneContentTypesPreserved() throws {
        let editorID = PaneID()
        let terminalID = PaneID()
        let tree = PaneNode.split(
            .horizontal,
            first: .leaf(editorID, .editor),
            second: .leaf(terminalID, .terminal),
            ratio: 0.5
        )

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(PaneNode.self, from: data)

        #expect(decoded.content(for: editorID) == .editor)
        #expect(decoded.content(for: terminalID) == .terminal)
    }

    // MARK: - Edge: paneStates with missing pane IDs

    @Test func paneStatesWithExtraneousKeysStillLoads() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let paneID = PaneID()
        let tree = PaneNode.leaf(paneID, .editor)
        let bogusUUID = UUID().uuidString

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Save with an extra pane state that doesn't match any leaf
        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [],
            paneTree: tree,
            activePaneUUID: paneID.id.uuidString,
            paneStates: [
                paneID.id.uuidString: PaneTabState(
                    openFilePaths: [], activeFilePath: nil,
                    editorStates: nil, pinnedPaths: nil,
                    highlightingDisabledPaths: nil, previewModes: nil
                ),
                bogusUUID: PaneTabState(
                    openFilePaths: ["/tmp/ghost.swift"], activeFilePath: nil,
                    editorStates: nil, pinnedPaths: nil,
                    highlightingDisabledPaths: nil, previewModes: nil
                )
            ],
            defaults: defaults
        )

        let loaded = try #require(SessionState.load(for: tempDir, defaults: defaults))

        // Both keys loaded (consumers filter by tree leaf IDs)
        #expect(loaded.paneStates?.count == 2)
        #expect(loaded.paneStates?[paneID.id.uuidString] != nil)
        #expect(loaded.paneStates?[bogusUUID] != nil)
    }

    // MARK: - capturePaneTabState static helper

    @Test func capturePaneTabStateFromTabManager() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file = createFile(in: tempDir, name: "test.swift")
        let rootPath = tempDir.path + "/"

        let tm = TabManager()
        tm.openTab(url: file)

        let captured = ProjectManager.capturePaneTabState(from: tm, rootPath: rootPath)

        #expect(captured.openFilePaths == [file.path])
        #expect(captured.activeFilePath == file.path)
    }

    @Test func capturePaneTabStateEmptyTabManager() {
        let tm = TabManager()
        let captured = ProjectManager.capturePaneTabState(from: tm, rootPath: "/tmp/project/")

        #expect(captured.openFilePaths.isEmpty)
        #expect(captured.activeFilePath == nil)
        #expect(captured.editorStates == nil)
        #expect(captured.pinnedPaths == nil)
    }

    // MARK: - Combined legacy + pane data

    @Test func sessionWithBothLegacyAndPaneFieldsUsesPane() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file = createFile(in: tempDir, name: "dual.swift")
        let paneID = PaneID()

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Save with both legacy fields and pane tree
        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [file],
            activeFileURL: file,
            paneTree: .leaf(paneID, .editor),
            activePaneUUID: paneID.id.uuidString,
            paneStates: [
                paneID.id.uuidString: PaneTabState(
                    openFilePaths: [file.path],
                    activeFilePath: file.path,
                    editorStates: nil,
                    pinnedPaths: nil,
                    highlightingDisabledPaths: nil,
                    previewModes: nil
                )
            ],
            defaults: defaults
        )

        let loaded = try #require(SessionState.load(for: tempDir, defaults: defaults))

        // Both legacy and pane fields are available
        #expect(loaded.hasPaneTree)
        #expect(loaded.existingFileURLs.count == 1) // legacy still works
        #expect(loaded.paneStates?.count == 1) // pane also works
    }
}

// swiftlint:enable type_body_length file_length
