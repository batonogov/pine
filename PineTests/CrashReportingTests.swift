//
//  CrashReportingTests.swift
//  PineTests
//

import Testing
import AppKit
import Foundation
@testable import Pine

// MARK: - CrashReportingSettings Tests

struct CrashReportingSettingsTests {

    // Use a unique suite name to avoid collisions with the app's real defaults
    private func withCleanDefaults(_ body: () -> Void) {
        let enabledKey = CrashReportingSettings.enabledKey
        let promptKey = CrashReportingSettings.promptShownKey
        let savedEnabled = UserDefaults.standard.object(forKey: enabledKey)
        let savedPrompt = UserDefaults.standard.object(forKey: promptKey)

        // Clear
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: promptKey)

        body()

        // Restore
        if let val = savedEnabled {
            UserDefaults.standard.set(val, forKey: enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: enabledKey)
        }
        if let val = savedPrompt {
            UserDefaults.standard.set(val, forKey: promptKey)
        } else {
            UserDefaults.standard.removeObject(forKey: promptKey)
        }
    }

    @Test func defaultState_isDisabled() {
        withCleanDefaults {
            #expect(!CrashReportingSettings.isEnabled)
        }
    }

    @Test func defaultState_promptNotShown() {
        withCleanDefaults {
            #expect(!CrashReportingSettings.hasShownPrompt)
        }
    }

    @Test func needsPrompt_trueWhenNotShown() {
        withCleanDefaults {
            #expect(CrashReportingSettings.needsPrompt)
        }
    }

    @Test func recordChoice_enabled_setsValues() {
        withCleanDefaults {
            CrashReportingSettings.recordChoice(enabled: true)
            #expect(CrashReportingSettings.isEnabled)
            #expect(CrashReportingSettings.hasShownPrompt)
            #expect(!CrashReportingSettings.needsPrompt)
        }
    }

    @Test func recordChoice_disabled_setsValues() {
        withCleanDefaults {
            CrashReportingSettings.recordChoice(enabled: false)
            #expect(!CrashReportingSettings.isEnabled)
            #expect(CrashReportingSettings.hasShownPrompt)
            #expect(!CrashReportingSettings.needsPrompt)
        }
    }

    @Test func isEnabled_canBeToggled() {
        withCleanDefaults {
            CrashReportingSettings.isEnabled = true
            #expect(CrashReportingSettings.isEnabled)
            CrashReportingSettings.isEnabled = false
            #expect(!CrashReportingSettings.isEnabled)
        }
    }

    @Test func keys_haveExpectedValues() {
        #expect(CrashReportingSettings.enabledKey == "crashReporting.enabled")
        #expect(CrashReportingSettings.promptShownKey == "crashReporting.promptShown")
    }
}

// MARK: - CrashReport Model Tests

struct CrashReportModelTests {

    @Test func init_setsDefaults() {
        let report = CrashReport()
        #expect(report.signal == nil)
        #expect(report.exceptionType == nil)
        #expect(report.terminationReason == nil)
        #expect(report.callStackFrames.isEmpty)
        #expect(report.openTabCount == nil)
    }

    @Test func init_withValues() {
        let report = CrashReport(
            signal: "SIGSEGV",
            exceptionType: "EXC_BAD_ACCESS",
            terminationReason: "Namespace SIGNAL, Code 11",
            callStackFrames: ["frame0", "frame1"],
            openTabCount: 5
        )
        #expect(report.signal == "SIGSEGV")
        #expect(report.exceptionType == "EXC_BAD_ACCESS")
        #expect(report.terminationReason == "Namespace SIGNAL, Code 11")
        #expect(report.callStackFrames.count == 2)
        #expect(report.openTabCount == 5)
    }

    @Test func init_capturesAppVersion() {
        let report = CrashReport()
        // In test target, Bundle.main may not have these keys, but should not crash
        #expect(report.appVersion is String)
        #expect(report.buildNumber is String)
        #expect(!report.osVersion.isEmpty)
    }

    @Test func testInit_explicitValues() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let report = CrashReport(
            id: id,
            timestamp: date,
            appVersion: "1.0.0",
            buildNumber: "42",
            osVersion: "26.0",
            signal: "SIGABRT",
            exceptionType: nil,
            terminationReason: nil,
            callStackFrames: ["a", "b", "c"],
            openTabCount: 3
        )
        #expect(report.id == id)
        #expect(report.timestamp == date)
        #expect(report.appVersion == "1.0.0")
        #expect(report.buildNumber == "42")
        #expect(report.osVersion == "26.0")
        #expect(report.signal == "SIGABRT")
        #expect(report.callStackFrames == ["a", "b", "c"])
        #expect(report.openTabCount == 3)
    }

    @Test func codable_roundTrip() throws {
        let original = CrashReport(
            id: UUID(),
            timestamp: Date(),
            appVersion: "2.0.0",
            buildNumber: "100",
            osVersion: "26.1",
            signal: "SIGSEGV",
            exceptionType: "EXC_BAD_ACCESS",
            terminationReason: "some reason",
            callStackFrames: ["frame0", "frame1"],
            openTabCount: 10
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CrashReport.self, from: data)
        #expect(original == decoded)
    }

    @Test func equatable_sameValues_areEqual() {
        let id = UUID()
        let date = Date()
        let a = CrashReport(id: id, timestamp: date, appVersion: "1", buildNumber: "1",
                            osVersion: "26", signal: nil, exceptionType: nil,
                            terminationReason: nil, callStackFrames: [], openTabCount: nil)
        let b = CrashReport(id: id, timestamp: date, appVersion: "1", buildNumber: "1",
                            osVersion: "26", signal: nil, exceptionType: nil,
                            terminationReason: nil, callStackFrames: [], openTabCount: nil)
        #expect(a == b)
    }

    @Test func equatable_differentIDs_areNotEqual() {
        let date = Date()
        let a = CrashReport(id: UUID(), timestamp: date, appVersion: "1", buildNumber: "1",
                            osVersion: "26", signal: nil, exceptionType: nil,
                            terminationReason: nil, callStackFrames: [], openTabCount: nil)
        let b = CrashReport(id: UUID(), timestamp: date, appVersion: "1", buildNumber: "1",
                            osVersion: "26", signal: nil, exceptionType: nil,
                            terminationReason: nil, callStackFrames: [], openTabCount: nil)
        #expect(a != b)
    }
}

// MARK: - ParseCallStack Tests

struct ParseCallStackTests {

    @Test func parseCallStack_basicFrames() {
        let raw = """
        0   Pine                        0x00000001000a1234 someFunction + 42
        1   Pine                        0x00000001000a5678 anotherFunction + 10
        """
        let frames = CrashReport.parseCallStack(raw)
        #expect(frames.count == 2)
        #expect(frames[0].contains("someFunction"))
        #expect(frames[1].contains("anotherFunction"))
    }

    @Test func parseCallStack_emptyString() {
        let frames = CrashReport.parseCallStack("")
        #expect(frames.isEmpty)
    }

    @Test func parseCallStack_singleFrame() {
        let raw = "0   Pine   0x1234 main + 0"
        let frames = CrashReport.parseCallStack(raw)
        #expect(frames.count == 1)
        #expect(frames[0].contains("main"))
    }

    @Test func parseCallStack_skipsEmptyLines() {
        let raw = """
        frame1

        frame2

        """
        let frames = CrashReport.parseCallStack(raw)
        #expect(frames.count == 2)
        #expect(frames[0] == "frame1")
        #expect(frames[1] == "frame2")
    }

    @Test func parseCallStack_trimsWhitespace() {
        let raw = "   frame with spaces   "
        let frames = CrashReport.parseCallStack(raw)
        #expect(frames.count == 1)
        #expect(frames[0] == "frame with spaces")
    }

    @Test func parseCallStack_multipleNewlineFormats() {
        let raw = "frame1\nframe2\nframe3"
        let frames = CrashReport.parseCallStack(raw)
        #expect(frames.count == 3)
    }

    @Test func parseCallStack_onlyWhitespaceLines() {
        let raw = "   \n   \n   "
        let frames = CrashReport.parseCallStack(raw)
        #expect(frames.isEmpty)
    }
}

// MARK: - CrashReportStore Tests

struct CrashReportStoreTests {

    private func makeTempStore() -> CrashReportStore {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-CrashStore-\(UUID().uuidString)")
        return CrashReportStore(storageDirectory: tmpDir)
    }

    private func cleanup(_ store: CrashReportStore) {
        try? FileManager.default.removeItem(at: store.storageDirectory)
    }

    @Test func save_andLoadAll() {
        let store = makeTempStore()
        defer { cleanup(store) }

        let report = CrashReport(signal: "SIGABRT")
        store.save(report)

        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == report.id)
        #expect(loaded[0].signal == "SIGABRT")
    }

    @Test func count_returnsCorrectValue() {
        let store = makeTempStore()
        defer { cleanup(store) }

        #expect(store.loadAll().isEmpty)
        store.save(CrashReport(signal: "SIGSEGV"))
        #expect(store.count == 1)
        store.save(CrashReport(signal: "SIGBUS"))
        #expect(store.count == 2)
    }

    @Test func remove_byID() {
        let store = makeTempStore()
        defer { cleanup(store) }

        let report1 = CrashReport(signal: "A")
        let report2 = CrashReport(signal: "B")
        store.save(report1)
        store.save(report2)

        store.remove(id: report1.id)

        let remaining = store.loadAll()
        #expect(remaining.count == 1)
        #expect(remaining[0].id == report2.id)
    }

    @Test func removeAll_clearsStore() {
        let store = makeTempStore()
        defer { cleanup(store) }

        store.save(CrashReport(signal: "A"))
        store.save(CrashReport(signal: "B"))
        store.save(CrashReport(signal: "C"))

        store.removeAll()
        #expect(store.loadAll().isEmpty)
    }

    @Test func loadAll_sortedByTimestamp_newestFirst() {
        let store = makeTempStore()
        defer { cleanup(store) }

        let old = CrashReport(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 1_000_000),
            appVersion: "1", buildNumber: "1", osVersion: "26",
            signal: "old", exceptionType: nil, terminationReason: nil,
            callStackFrames: [], openTabCount: nil
        )
        let recent = CrashReport(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 2_000_000),
            appVersion: "1", buildNumber: "1", osVersion: "26",
            signal: "recent", exceptionType: nil, terminationReason: nil,
            callStackFrames: [], openTabCount: nil
        )
        store.save(old)
        store.save(recent)

        let loaded = store.loadAll()
        #expect(loaded.count == 2)
        #expect(loaded[0].signal == "recent")
        #expect(loaded[1].signal == "old")
    }

    @Test func emptyStore_loadsEmpty() {
        let store = makeTempStore()
        defer { cleanup(store) }

        #expect(store.loadAll().isEmpty)
    }

    @Test func maxReports_constant() {
        #expect(CrashReportStore.maxReports == 50)
    }

    @Test func fileExtension_constant() {
        #expect(CrashReportStore.fileExtension == "crashreport")
    }

    @Test func remove_nonexistentID_doesNotCrash() {
        let store = makeTempStore()
        defer { cleanup(store) }

        store.remove(id: UUID()) // Should not throw or crash
        #expect(store.loadAll().isEmpty)
    }

    @Test func pruning_removesOldReportsOverLimit() {
        let store = makeTempStore()
        defer { cleanup(store) }

        // Save more than maxReports
        for i in 0..<(CrashReportStore.maxReports + 5) {
            let report = CrashReport(
                id: UUID(),
                timestamp: Date(timeIntervalSinceNow: Double(i)),
                appVersion: "1", buildNumber: "1", osVersion: "26",
                signal: "SIG\(i)", exceptionType: nil, terminationReason: nil,
                callStackFrames: [], openTabCount: nil
            )
            store.save(report)
        }

        #expect(store.count <= CrashReportStore.maxReports)
    }
}

// MARK: - extractCallStackFrames Tests

struct ExtractCallStackFramesTests {

    @Test func emptyData_returnsEmpty() {
        let frames = CrashReportingManager.extractCallStackFrames(from: Data())
        #expect(frames.isEmpty)
    }

    @Test func invalidJSON_returnsEmpty() {
        let data = Data("not json".utf8)
        let frames = CrashReportingManager.extractCallStackFrames(from: data)
        #expect(frames.isEmpty)
    }

    @Test func missingCallStackTree_returnsEmpty() throws {
        let json: [String: Any] = ["other": "data"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let frames = CrashReportingManager.extractCallStackFrames(from: data)
        #expect(frames.isEmpty)
    }

    @Test func missingCallStacks_returnsEmpty() throws {
        let json: [String: Any] = ["callStackTree": ["other": "data"]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let frames = CrashReportingManager.extractCallStackFrames(from: data)
        #expect(frames.isEmpty)
    }

    @Test func singleFrame_parsesCorrectly() throws {
        let json: [String: Any] = [
            "callStackTree": [
                "callStacks": [
                    [
                        "callStackRootFrames": [
                            [
                                "binaryName": "Pine",
                                "address": 4_294_967_296,
                                "offsetIntoBinaryTextSegment": 1234
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let frames = CrashReportingManager.extractCallStackFrames(from: data)
        #expect(frames.count == 1)
        #expect(frames[0].contains("Pine"))
    }

    @Test func nestedSubFrames_flattensAll() throws {
        let json: [String: Any] = [
            "callStackTree": [
                "callStacks": [
                    [
                        "callStackRootFrames": [
                            [
                                "binaryName": "Pine",
                                "address": 100,
                                "offsetIntoBinaryTextSegment": 10,
                                "subFrames": [
                                    [
                                        "binaryName": "libsystem",
                                        "address": 200,
                                        "offsetIntoBinaryTextSegment": 20
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let frames = CrashReportingManager.extractCallStackFrames(from: data)
        #expect(frames.count == 2)
        #expect(frames[0].contains("Pine"))
        #expect(frames[1].contains("libsystem"))
    }

    @Test func multipleCallStacks_parsesAll() throws {
        let json: [String: Any] = [
            "callStackTree": [
                "callStacks": [
                    [
                        "callStackRootFrames": [
                            ["binaryName": "Pine", "address": 100, "offsetIntoBinaryTextSegment": 10]
                        ]
                    ],
                    [
                        "callStackRootFrames": [
                            ["binaryName": "AppKit", "address": 200, "offsetIntoBinaryTextSegment": 20]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let frames = CrashReportingManager.extractCallStackFrames(from: data)
        #expect(frames.count == 2)
        #expect(frames[0].contains("Pine"))
        #expect(frames[1].contains("AppKit"))
    }

    @Test func missingBinaryName_usesFallback() throws {
        let json: [String: Any] = [
            "callStackTree": [
                "callStacks": [
                    [
                        "callStackRootFrames": [
                            ["address": 100, "offsetIntoBinaryTextSegment": 10]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let frames = CrashReportingManager.extractCallStackFrames(from: data)
        #expect(frames.count == 1)
        #expect(frames[0].contains("?"))
    }

    @Test func emptyCallStacks_returnsEmpty() throws {
        let json: [String: Any] = [
            "callStackTree": [
                "callStacks": [] as [[String: Any]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let frames = CrashReportingManager.extractCallStackFrames(from: data)
        #expect(frames.isEmpty)
    }
}

// MARK: - MenuIcons Tests

struct CrashReportingMenuIconTests {
    @Test func crashReporting_iconExists() {
        #expect(
            NSImage(systemSymbolName: MenuIcons.crashReporting, accessibilityDescription: nil) != nil,
            "SF Symbol '\(MenuIcons.crashReporting)' does not exist"
        )
    }
}
