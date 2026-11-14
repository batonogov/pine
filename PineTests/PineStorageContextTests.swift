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

    @Test("The reserved test identity requires matching compile mode", arguments: [false, true])
    func reservedIdentityRequiresTestMode(testHost: Bool) {
        #expect(PineStorageContext.launchIsSafe(
            testHost: testHost, bundleIdentifier: PineStorageContext.testBundleIdentifier, arguments: []
        ) == testHost)
    }

    @Test("Private UI fixtures require the Testing identity", arguments: [
        "--ui-test-agent-recovery", "--ui-test-agent-vendor-recovery", "--ui-test-live-agent",
        "--ui-test-a11y-dirty-buffer", "--ui-test-agent-attention", "--ui-test-agent-activity-all",
        "--ui-test-agent-activity-heuristic", "--ui-test-agent-inbox-marketing", "--ui-test-dark-appearance",
        "--ui-test-future-fixture", "--ui-test-",
    ])
    func privateFixtureArguments(flag: String) {
        var environment = ["PINE_OPEN_PROJECT": "/owned/fixture-project"]
        if flag == "--ui-test-a11y-dirty-buffer" {
            environment["PINE_UI_TEST_DIRTY_FILE"] = "main.swift"
            environment["PINE_UI_TEST_DIRTY_MARKER"] = "// owned dirty fixture"
        }
        #expect(!PineStorageContext.launchIsSafe(
            testHost: false, bundleIdentifier: "fixture.production", arguments: [flag], environment: environment
        ))
        #expect(PineStorageContext.launchIsSafe(
            testHost: true, bundleIdentifier: PineStorageContext.testBundleIdentifier,
            arguments: [flag], environment: environment
        ))
    }

    @Test("UI and persistence injection environments require Testing", arguments: [
        "PINE_UI_TEST_SETTINGS_SUITE", "PINE_UI_TEST_DIRTY_FILE", "PINE_UI_TEST_DIRTY_MARKER",
        "PINE_UI_TEST_FUTURE_FIXTURE", "PINE_UI_TEST_", "PINE_PERSISTENCE_FAULT",
        "PINE_PERSISTENCE_PAUSE", "PINE_PERSISTENCE_CHECKPOINT_DIRECTORY",
    ])
    func privateFixtureEnvironment(marker: String) {
        let configuredValue: String
        switch marker {
        case "PINE_PERSISTENCE_FAULT": configuredValue = "session:before-atomic-replace:permission-denied"
        case "PINE_PERSISTENCE_PAUSE": configuredValue = "session:before-atomic-replace"
        case "PINE_PERSISTENCE_CHECKPOINT_DIRECTORY": configuredValue = "/owned/fixture-checkpoint"
        case "PINE_UI_TEST_SETTINGS_SUITE": configuredValue = "PineUITests.Settings.owned-fixture"
        case "PINE_UI_TEST_DIRTY_FILE": configuredValue = "main.swift"
        case "PINE_UI_TEST_DIRTY_MARKER": configuredValue = "// owned dirty fixture"
        default: configuredValue = "1"
        }
        for value in ["", "malformed", configuredValue] {
            let environment = [marker: value, "PINE_OPEN_PROJECT": "/owned/fixture-project"]
            #expect(!PineStorageContext.launchIsSafe(
                testHost: false, bundleIdentifier: "fixture.production", arguments: [], environment: environment
            ))
            #expect(PineStorageContext.launchIsSafe(
                testHost: true, bundleIdentifier: PineStorageContext.testBundleIdentifier,
                arguments: [], environment: environment
            ))
        }
    }

    @Test("The unchanged release-smoke launch contract and normal search remain accepted")
    func ordinaryReleaseSmokeContract() {
        let arguments = [
            "--disable-agent-detection", "--disable-metal", "--disable-quick-terminal", "--disable-terminal-seeding",
            "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        var environment = [
            "HOME": "/owned/fixture-home", "CFFIXED_USER_HOME": "/owned/fixture-home", "TMPDIR": "/owned/fixture-home/tmp",
            "PINE_DISABLE_AGENT_DETECTION": "1", "PINE_DISABLE_METAL": "1", "PINE_DISABLE_QUICK_TERMINAL": "1",
            "PINE_OPEN_PROJECT": "/owned/fixture-project",
        ]
        #expect(PineStorageContext.launchIsSafe(
            testHost: false, bundleIdentifier: "io.github.batonogov.pine", arguments: arguments, environment: environment
        ))
        environment["PINE_SEARCH_QUERY"] = "normal query"
        #expect(PineStorageContext.launchIsSafe(
            testHost: false, bundleIdentifier: "io.github.batonogov.pine", arguments: arguments, environment: environment
        ))
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
