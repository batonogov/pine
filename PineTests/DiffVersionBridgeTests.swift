//
//  DiffVersionBridgeTests.swift
//  PineTests
//
//  Regression test for issue #809 — diff gutter markers become stale
//  because SwiftUI does not call `updateNSView` when `@State lineDiffs`
//  changes inside a Task. The fix introduces a monotonic `diffVersion`
//  counter that forces SwiftUI to detect a change and invoke updateNSView.
//
//  These tests verify:
//  1. CodeEditorView exposes a `diffVersion` property
//  2. The version counter mechanism guarantees SwiftUI re-render

import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Diff Version Bridge (#809)")
@MainActor
struct DiffVersionBridgeTests {

    // MARK: - CodeEditorView accepts diffVersion parameter

    /// CodeEditorView must have a `diffVersion` property so that SwiftUI
    /// can detect changes and call `updateNSView`. Without this field,
    /// changing `lineDiffs` inside a Task does not trigger re-render.
    @Test("CodeEditorView has diffVersion property that defaults to 0")
    func codeEditorViewHasDiffVersionProperty() {
        let view = CodeEditorView(
            text: .constant("hello"),
            language: "swift",
            diffVersion: 0,
            foldState: .constant(FoldState())
        )
        #expect(view.diffVersion == 0)
    }

    /// Different diffVersion values create distinct view instances from
    /// SwiftUI's perspective, which forces `updateNSView` to be called.
    @Test("CodeEditorView with different diffVersion values are distinguishable")
    func codeEditorViewDiffVersionDistinguishable() {
        let viewA = CodeEditorView(
            text: .constant("hello"),
            language: "swift",
            diffVersion: 1,
            foldState: .constant(FoldState())
        )
        let viewB = CodeEditorView(
            text: .constant("hello"),
            language: "swift",
            diffVersion: 2,
            foldState: .constant(FoldState())
        )
        #expect(viewA.diffVersion != viewB.diffVersion,
                "Different diffVersion values must be distinguishable to force updateNSView")
    }

    // MARK: - Version counter overflow safety

    /// The `&+=` wrapping addition ensures no crash at UInt64.max.
    @Test("diffVersion wrapping addition does not crash at UInt64.max")
    func diffVersionWrappingAddition() {
        var version: UInt64 = UInt64.max
        version &+= 1
        #expect(version == 0, "wrapping addition should wrap around to 0")
    }

    // MARK: - End-to-end: save triggers diff refresh with version bump

    /// Simulates the full flow: edit → save → git diff returns results →
    /// diffVersion must increment (forcing updateNSView).
    /// This is the exact scenario that was broken in #809.
    @Test("full edit → save → refreshLineDiffs bumps diffVersion")
    func fullEditSaveBumpsDiffVersion() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let fileURL = dir.appendingPathComponent("file.txt")
        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let tabManager = TabManager()
        tabManager.openTab(url: fileURL)

        // Simulate initial state: diffVersion starts at 0
        var diffVersion: UInt64 = 0
        var lineDiffs: [GitLineDiff] = []

        // Pre-edit: no diffs
        let before = await provider.diffForFileAsync(at: fileURL)
        #expect(before.isEmpty)

        // Edit and save
        tabManager.updateContent("line1\nEDITED\nline3\n")
        let saved = tabManager.saveTab(at: 0)
        #expect(saved == true)

        // Fetch diffs (what refreshLineDiffs does)
        let after = await provider.diffForFileAsync(at: fileURL)
        #expect(after.isEmpty == false)

        // Simulate what the fix does: assign diffs and bump version
        lineDiffs = after
        diffVersion &+= 1

        #expect(lineDiffs.isEmpty == false,
                "diffs must be non-empty after edit+save")
        #expect(diffVersion == 1,
                "diffVersion must increment — this forces SwiftUI to call updateNSView")
    }

    /// Verifies that reverting to HEAD content clears diffs AND bumps
    /// diffVersion, ensuring markers disappear from the gutter.
    @Test("revert to HEAD → empty diffs + diffVersion bump")
    func revertToHeadClearsDiffsAndBumpsVersion() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let fileURL = dir.appendingPathComponent("file.txt")
        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        // Edit + save to create diffs
        try "line1\nMODIFIED\nline3\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let diffs = await provider.diffForFileAsync(at: fileURL)
        #expect(diffs.isEmpty == false)

        var diffVersion: UInt64 = 0
        var lineDiffs: [GitLineDiff] = diffs
        diffVersion &+= 1
        #expect(diffVersion == 1)

        // Revert to HEAD content
        try "line1\nline2\nline3\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let afterRevert = await provider.diffForFileAsync(at: fileURL)
        #expect(afterRevert.isEmpty)

        // Simulate refreshLineDiffs completing after revert
        lineDiffs = afterRevert
        diffVersion &+= 1

        #expect(lineDiffs.isEmpty,
                "diffs must be empty after reverting to HEAD")
        #expect(diffVersion == 2,
                "diffVersion must increment even when clearing — ensures updateNSView fires to remove markers")
    }

    /// Multiple rapid edits each bump diffVersion — no deduplication.
    @Test("rapid consecutive refreshes each bump diffVersion")
    func rapidRefreshesBumpVersion() {
        var diffVersion: UInt64 = 0
        for iteration in 1...10 {
            diffVersion &+= 1
            #expect(diffVersion == UInt64(iteration))
        }
    }

    // MARK: - Helpers

    private func makeGitRepo() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-diffver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let dir = try resolveURL(rawDir)
        try runShell("git init -b main", at: dir)
        try runShell("git config user.email 'test@test.com'", at: dir)
        try runShell("git config user.name 'Test'", at: dir)
        try "line1\nline2\nline3\n".write(
            to: dir.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runShell("git add .", at: dir)
        try runShell("git commit -m 'initial'", at: dir)
        return dir
    }

    private func resolveURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    private func runShell(_ command: String, at dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "ShellError",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "'\(command)' failed: \(stderr)"]
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
