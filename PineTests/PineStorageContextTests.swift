import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("Test persistence isolation")
struct PineStorageContextTests {
    @Test("Reset flags require the separate test application identity")
    func launchGuard() {
        #expect(!PineStorageContext.launchIsSafe(
            testHost: false, bundleIdentifier: "fixture.production", arguments: ["--reset-state"]
        ))
        #expect(!PineStorageContext.launchIsSafe(
            testHost: false, bundleIdentifier: "fixture.production",
            arguments: ["--application-lifecycle-process-test"]
        ))
        #expect(!PineStorageContext.launchIsSafe(
            testHost: true, bundleIdentifier: "fixture.production", arguments: []
        ))
        #expect(PineStorageContext.launchIsSafe(
            testHost: true, bundleIdentifier: PineStorageContext.testBundleIdentifier,
            arguments: ["--reset-state"]
        ))
        #expect(PineStorageContext.launchIsSafe(
            testHost: false, bundleIdentifier: "fixture.production", arguments: []
        ))
        for marker in [PineStorageContext.namespaceEnvironmentKey, "XCTestConfigurationFilePath"] {
            #expect(!PineStorageContext.launchIsSafe(
                testHost: false, bundleIdentifier: "fixture.production", arguments: [],
                environment: [marker: "malformed"]
            ))
        }
    }

    @Test("Application support scopes keep owned recovery files separate")
    func recoveryPaths() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let production = PineStorageContext.scopedApplicationSupportDirectory(base: base, testNamespace: nil)
        let test = PineStorageContext.scopedApplicationSupportDirectory(base: base, testNamespace: UUID())
        let productionRecovery = production.appendingPathComponent("Pine/Recovery")
        let testRecovery = test.appendingPathComponent("Pine/Recovery")
        try FileManager.default.createDirectory(at: productionRecovery, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testRecovery, withIntermediateDirectories: true)
        let sentinel = productionRecovery.appendingPathComponent("sentinel")
        try Data("owned production fixture".utf8).write(to: sentinel)
        try FileManager.default.removeItem(at: testRecovery)
        #expect(try Data(contentsOf: sentinel) == Data("owned production fixture".utf8))
        #expect(production == base)
        #expect(test != production)
    }

    @MainActor
    @Test("Session and font resets leave an unrelated owned domain intact")
    func isolatedReset() throws {
        let productionName = "PineTests.FakeProduction.\(UUID().uuidString)"
        let production = try #require(UserDefaults(suiteName: productionName))
        defer { production.removePersistentDomain(forName: productionName) }
        let key = "sessionState:/owned/fixture"
        production.set("preserved", forKey: key)
        production.set(17, forKey: "editorFontSize")
        let testName = "PineTests.ResetFixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: testName))
        defer { defaults.removePersistentDomain(forName: testName) }
        defaults.set("test", forKey: key)
        defaults.set(16, forKey: "editorFontSize")
        SessionState.removeAll(defaults: defaults)
        FontSizeSettings(defaults: defaults).reset()
        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.double(forKey: "editorFontSize") == 13)
        #expect(production.string(forKey: key) == "preserved")
        #expect(production.double(forKey: "editorFontSize") == 17)
    }

    @Test("A stale test storage symlink cannot redirect writes")
    func staleSymlink() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let ownedProduction = base.appendingPathComponent("OwnedProduction")
        try FileManager.default.createDirectory(at: ownedProduction, withIntermediateDirectories: true)
        let sentinel = ownedProduction.appendingPathComponent("recovery")
        try Data("preserved".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("PineTestState"), withDestinationURL: ownedProduction
        )
        #expect(throws: (any Error).self) {
            try PineStorageContext.prepareTestApplicationSupportDirectory(base: base, namespace: UUID())
        }
        #expect(try Data(contentsOf: sentinel) == Data("preserved".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: ownedProduction.path) == ["recovery"])
    }

    @Test("Stale descendant links cannot redirect recovery access", arguments: [
        "Pine", "Pine/Recovery", "Pine/Recovery/project", "Pine/Recovery/project/snapshot.json",
    ])
    func staleDescendantSymlink(component: String) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let ownedProduction = base.appendingPathComponent("OwnedProduction")
        try FileManager.default.createDirectory(at: ownedProduction, withIntermediateDirectories: true)
        let sentinel = ownedProduction.appendingPathComponent("recovery.json")
        try Data("preserved".utf8).write(to: sentinel)
        let namespace = UUID()
        let scope = try PineStorageContext.prepareTestApplicationSupportDirectory(base: base, namespace: namespace)
        let link = scope.appendingPathComponent(component)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: component.hasSuffix(".json") ? sentinel : ownedProduction
        )
        #expect(throws: (any Error).self) {
            try PineStorageContext.prepareTestApplicationSupportDirectory(base: base, namespace: namespace)
        }
        #expect(try Data(contentsOf: sentinel) == Data("preserved".utf8))
    }

    @Test("Hardlinks may share test-owned inodes but cannot reference outside state")
    func hardlinksRemainConfined() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let namespace = UUID()
        let scope = try PineStorageContext.prepareTestApplicationSupportDirectory(base: base, namespace: namespace)
        let lock = scope.appendingPathComponent("lock")
        try Data("internal".utf8).write(to: lock)
        try FileManager.default.linkItem(at: lock, to: scope.appendingPathComponent("guard"))
        #expect(try PineStorageContext.prepareTestApplicationSupportDirectory(base: base, namespace: namespace) == scope)
        let sentinel = base.appendingPathComponent("owned-production.json")
        try Data("preserved".utf8).write(to: sentinel)
        try FileManager.default.linkItem(at: sentinel, to: scope.appendingPathComponent("snapshot.json"))
        #expect(throws: (any Error).self) {
            try PineStorageContext.prepareTestApplicationSupportDirectory(base: base, namespace: namespace)
        }
        #expect(try Data(contentsOf: sentinel) == Data("preserved".utf8))
    }

    @Test("Namespace inspection fails closed at its entry and depth bounds")
    func boundedInspection() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let namespace = UUID()
        let scope = try PineStorageContext.prepareTestApplicationSupportDirectory(base: base, namespace: namespace)
        let nested = scope.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: nested.appendingPathComponent("entry"))
        #expect(throws: (any Error).self) {
            try PineStorageContext.prepareTestApplicationSupportDirectory(
                base: base, namespace: namespace, maximumEntries: 1
            )
        }
        #expect(throws: (any Error).self) {
            try PineStorageContext.prepareTestApplicationSupportDirectory(
                base: base, namespace: namespace, maximumDepth: 1
            )
        }
        #expect(try PineStorageContext.prepareTestApplicationSupportDirectory(base: base, namespace: namespace) == scope)
    }

    @Test("Special files are rejected without opening a blocking stream")
    func specialFileIsRejected() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let namespace = UUID()
        let scope = try PineStorageContext.prepareTestApplicationSupportDirectory(base: base, namespace: namespace)
        #expect(mkfifo(scope.appendingPathComponent("fifo").path, 0o600) == 0)
        #expect(throws: (any Error).self) {
            try PineStorageContext.prepareTestApplicationSupportDirectory(base: base, namespace: namespace)
        }
    }
}
