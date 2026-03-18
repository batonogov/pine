//
//  SessionStateTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct SessionStateTests {

    private let suiteName = "PineTests.SessionState.\(UUID().uuidString)"

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

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Round-trip

    @Test func saveAndLoadRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file1 = tempDir.appendingPathComponent("a.swift")
        let file2 = tempDir.appendingPathComponent("b.swift")
        FileManager.default.createFile(atPath: file1.path, contents: nil)
        FileManager.default.createFile(atPath: file2.path, contents: nil)

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(projectURL: tempDir, openFileURLs: [file1, file2], defaults: defaults)

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.projectURL.path == tempDir.path)
        #expect(loaded?.existingFileURLs.count == 2)
        #expect(loaded?.existingFileURLs[0].path == file1.path)
        #expect(loaded?.existingFileURLs[1].path == file2.path)
    }

    // MARK: - Missing project folder

    @Test func loadReturnsNilWhenProjectDeleted() throws {
        let tempDir = try makeTempDirectory()
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(projectURL: tempDir, openFileURLs: [], defaults: defaults)

        // Delete the project folder
        cleanup(tempDir)

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded == nil)
    }

    // MARK: - Missing files filtered

    @Test func existingFileURLsFiltersDeletedFiles() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let existing = tempDir.appendingPathComponent("exists.swift")
        let missing = tempDir.appendingPathComponent("gone.swift")
        FileManager.default.createFile(atPath: existing.path, contents: nil)

        let state = SessionState(
            projectPath: tempDir.path,
            openFilePaths: [existing.path, missing.path]
        )

        #expect(state.existingFileURLs.count == 1)
        #expect(state.existingFileURLs[0].path == existing.path)
    }

    // MARK: - Empty state

    @Test func loadReturnsNilWhenNothingSaved() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded == nil)
    }

    // MARK: - Save with empty file list

    @Test func saveWithEmptyFileList() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(projectURL: tempDir, openFileURLs: [], defaults: defaults)

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.existingFileURLs.isEmpty == true)
        #expect(loaded?.projectURL.path == tempDir.path)
    }

    // MARK: - Per-project isolation

    @Test func perProjectSessionsAreIsolated() throws {
        let tempDir1 = try makeTempDirectory()
        let tempDir2 = try makeTempDirectory()
        defer { cleanup(tempDir1); cleanup(tempDir2) }

        let file1 = tempDir1.appendingPathComponent("a.swift")
        let file2 = tempDir2.appendingPathComponent("b.swift")
        FileManager.default.createFile(atPath: file1.path, contents: nil)
        FileManager.default.createFile(atPath: file2.path, contents: nil)

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(projectURL: tempDir1, openFileURLs: [file1], defaults: defaults)
        SessionState.save(projectURL: tempDir2, openFileURLs: [file2], defaults: defaults)

        let loaded1 = SessionState.load(for: tempDir1, defaults: defaults)
        let loaded2 = SessionState.load(for: tempDir2, defaults: defaults)
        #expect(loaded1?.projectURL.path == tempDir1.path)
        #expect(loaded2?.projectURL.path == tempDir2.path)
        #expect(loaded1?.existingFileURLs.count == 1)
        #expect(loaded2?.existingFileURLs.count == 1)
    }

    // MARK: - Clear

    @Test func clearRemovesProjectSession() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(projectURL: tempDir, openFileURLs: [], defaults: defaults)
        SessionState.clear(for: tempDir, defaults: defaults)

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded == nil)
    }

    // MARK: - projectURL computed property

    @Test func projectURLFromPath() throws {
        let state = SessionState(projectPath: "/tmp/myproject", openFilePaths: [])
        #expect(state.projectURL == URL(fileURLWithPath: "/tmp/myproject"))
    }

    // MARK: - Active file round-trip

    @Test func activeFilePathRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file1 = tempDir.appendingPathComponent("a.swift")
        let file2 = tempDir.appendingPathComponent("b.swift")
        FileManager.default.createFile(atPath: file1.path, contents: nil)
        FileManager.default.createFile(atPath: file2.path, contents: nil)

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [file1, file2],
            activeFileURL: file2,
            defaults: defaults
        )

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded?.activeFilePath == file2.path)
        #expect(loaded?.activeFileURL == file2)
    }

    @Test func activeFileURLReturnsNilWhenFileDeleted() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file = tempDir.appendingPathComponent("gone.swift")

        let state = SessionState(
            projectPath: tempDir.path,
            openFilePaths: [],
            activeFilePath: file.path
        )

        #expect(state.activeFileURL == nil)
    }

    @Test func activeFileURLReturnsNilWhenNotSet() throws {
        let state = SessionState(
            projectPath: "/tmp",
            openFilePaths: [],
            activeFilePath: nil
        )
        #expect(state.activeFileURL == nil)
    }

    @Test func backwardsCompatibleWithoutActiveFilePath() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Simulate old format without activeFilePath stored in legacy key
        let oldState = ["projectPath": tempDir.path, "openFilePaths": [String]()] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: oldState)
        defaults.set(data, forKey: "lastSessionState")

        // Legacy fallback should find it when loading for the same project
        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.activeFilePath == nil)
        #expect(loaded?.activeFileURL == nil)
    }

    // MARK: - File as project path (not directory)

    @Test func loadReturnsNilWhenProjectPathIsFile() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file = tempDir.appendingPathComponent("notadir.txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(projectURL: file, openFileURLs: [], defaults: defaults)

        let loaded = SessionState.load(for: file, defaults: defaults)
        #expect(loaded == nil)
    }

    // MARK: - Preview modes

    @Test func previewModesRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let file = tempDir.appendingPathComponent("readme.md")
        FileManager.default.createFile(atPath: file.path, contents: nil)

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let modes = [file.path: "split"]
        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [file],
            previewModes: modes,
            defaults: defaults
        )

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded?.previewModes?[file.path] == "split")
    }

    @Test func legacySessionWithoutPreviewModesLoadsDefaults() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Save without preview modes (simulating older format)
        SessionState.save(projectURL: tempDir, openFileURLs: [], defaults: defaults)

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.previewModes == nil)
    }

    // MARK: - Terminal state

    @Test func terminalStateRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        SessionState.save(
            projectURL: tempDir,
            openFileURLs: [],
            terminalTabCount: 3,
            activeTerminalIndex: 1,
            isTerminalVisible: true,
            isTerminalMaximized: false,
            defaults: defaults
        )

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.terminalTabCount == 3)
        #expect(loaded?.activeTerminalIndex == 1)
        #expect(loaded?.isTerminalVisible == true)
        #expect(loaded?.isTerminalMaximized == false)
    }

    @Test func legacySessionWithoutTerminalStateLoads() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Save without terminal fields (simulating older format)
        SessionState.save(projectURL: tempDir, openFileURLs: [], defaults: defaults)

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.terminalTabCount == nil)
        #expect(loaded?.activeTerminalIndex == nil)
        #expect(loaded?.isTerminalVisible == nil)
        #expect(loaded?.isTerminalMaximized == nil)
    }

    // MARK: - Corrupt data

    @Test func loadReturnsNilOnCorruptData() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Write corrupt data to per-project key
        let key = "sessionState:" + tempDir.resolvingSymlinksInPath().path
        defaults.set(Data("not json".utf8), forKey: key)

        let loaded = SessionState.load(for: tempDir, defaults: defaults)
        #expect(loaded == nil)
    }
}
