//
//  ProductionDefaultsIsolationTests.swift
//  PineTests
//
//  Regression guard for #1554: production types that accept an injected
//  `UserDefaults` must keep every write inside the injected suite. A call
//  site that lets the `.standard` default slip through leaks throwaway test
//  fixtures into the developer's real preference domain — the exact defect
//  that accumulated 618 dead keys on the maintainer's machine.
//
//  Leak detection keys off the fixture's temporary path: both `sessionState:`
//  and `quickOpen.recentFiles.` keys embed the project root path, so a leaked
//  write is always visible as a key containing that path. Filtering by the
//  path keeps the guard immune to unrelated AppKit keys appearing in
//  `.standard` while the suite runs.
//

import Foundation
import Testing

@testable import Pine

@Suite("Production Defaults Isolation")
@MainActor
struct ProductionDefaultsIsolationTests {

    private func makeFixtureProject() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-Isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("main.swift")
        try "let value = 1".write(to: file, atomically: true, encoding: .utf8)
        return (dir, file)
    }

    /// Production-domain keys that embed the given path — i.e. leaked writes.
    private func leakedProductionKeys(containing path: String) -> Set<String> {
        Set(
            UserDefaults.standard.dictionaryRepresentation().keys
                .filter { $0.contains(path) }
        )
    }

    @Test("ProjectManager.saveSession stays inside the injected sessionDefaults suite")
    func projectManagerSaveSessionStaysScoped() throws {
        let (dir, file) = try makeFixtureProject()
        defer { try? FileManager.default.removeItem(at: dir) }

        let suiteName = "PineTests.Isolation.PMSession.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pm = ProjectManager(sessionDefaults: defaults)
        pm.workspace.loadDirectory(url: dir)
        pm.primaryTabManager.openTab(url: file)
        pm.saveSession()

        let canonical = dir.resolvingSymlinksInPath()
        #expect(leakedProductionKeys(containing: canonical.path).isEmpty)
        #expect(leakedProductionKeys(containing: dir.path).isEmpty)
        // The session itself must be present in the injected suite.
        #expect(SessionState.load(for: canonical, defaults: defaults) != nil)
    }

    @Test("QuickOpenProvider recents stay inside the injected suite")
    func quickOpenRecentsStayScoped() throws {
        let (dir, file) = try makeFixtureProject()
        defer { try? FileManager.default.removeItem(at: dir) }

        let suiteName = "PineTests.Isolation.QuickOpen.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = FileNode(url: dir, projectRoot: dir)
        let provider = QuickOpenProvider(defaults: defaults)
        provider.buildIndex(from: [root], rootURL: dir)

        provider.recordOpened(url: file)
        _ = provider.search(query: "")

        #expect(leakedProductionKeys(containing: dir.resolvingSymlinksInPath().path).isEmpty)
        // The recents list must be readable back from the injected suite.
        let results = provider.search(query: "")
        #expect(results.map(\.fileName) == ["main.swift"])
    }

    @Test("SessionState.save with an injected suite stays out of the production domain")
    func sessionStateSaveStaysScoped() throws {
        let (dir, file) = try makeFixtureProject()
        defer { try? FileManager.default.removeItem(at: dir) }

        let suiteName = "PineTests.Isolation.SessionState.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SessionState.save(projectURL: dir, openFileURLs: [file], defaults: defaults)

        let canonical = dir.resolvingSymlinksInPath()
        #expect(leakedProductionKeys(containing: canonical.path).isEmpty)
        #expect(SessionState.load(for: canonical, defaults: defaults)?.openFilePaths == [file.path])
    }

    @Test("removePersistentDomain fully wipes a scoped suite")
    func scopedSuiteTearDownRemovesDomain() throws {
        let suiteName = "PineTests.Isolation.Wipe.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(["leak"], forKey: "probe")
        #expect(defaults.stringArray(forKey: "probe") == ["leak"])

        defaults.removePersistentDomain(forName: suiteName)

        let reopened = try #require(UserDefaults(suiteName: suiteName))
        #expect(reopened.dictionaryRepresentation().isEmpty)
    }
}
