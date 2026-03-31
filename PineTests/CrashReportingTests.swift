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

// MARK: - CrashReportStore Thread Safety Tests

struct CrashReportStoreThreadSafetyTests {

    private func makeTempStore() -> CrashReportStore {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-CrashStore-Thread-\(UUID().uuidString)")
        return CrashReportStore(storageDirectory: tmpDir)
    }

    private func cleanup(_ store: CrashReportStore) {
        try? FileManager.default.removeItem(at: store.storageDirectory)
    }

    @Test func concurrentSaves_doNotCrash() {
        let store = makeTempStore()
        defer { cleanup(store) }

        let group = DispatchGroup()
        let concurrentQueue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for i in 0..<20 {
            group.enter()
            concurrentQueue.async {
                let report = CrashReport(signal: "SIG\(i)")
                store.save(report)
                group.leave()
            }
        }

        group.wait()
        #expect(store.count == 20)
    }

    @Test func concurrentSaveAndLoad_doNotCrash() {
        let store = makeTempStore()
        defer { cleanup(store) }

        let group = DispatchGroup()
        let concurrentQueue = DispatchQueue(label: "test.concurrent.rw", attributes: .concurrent)

        // Pre-populate with some reports
        for i in 0..<5 {
            store.save(CrashReport(signal: "PRE\(i)"))
        }

        // Concurrent reads and writes
        for i in 0..<10 {
            group.enter()
            concurrentQueue.async {
                store.save(CrashReport(signal: "WRITE\(i)"))
                group.leave()
            }

            group.enter()
            concurrentQueue.async {
                _ = store.loadAll()
                group.leave()
            }

            group.enter()
            concurrentQueue.async {
                _ = store.count
                group.leave()
            }
        }

        group.wait()
        #expect(store.count == 15) // 5 pre + 10 writes
    }

    @Test func concurrentRemoveAll_doNotCrash() {
        let store = makeTempStore()
        defer { cleanup(store) }

        for i in 0..<10 {
            store.save(CrashReport(signal: "SIG\(i)"))
        }

        let group = DispatchGroup()
        let concurrentQueue = DispatchQueue(label: "test.concurrent.remove", attributes: .concurrent)

        // Concurrent removeAll and loadAll should not crash
        for _ in 0..<5 {
            group.enter()
            concurrentQueue.async {
                store.removeAll()
                group.leave()
            }

            group.enter()
            concurrentQueue.async {
                _ = store.loadAll()
                group.leave()
            }
        }

        group.wait()
        // After removeAll, store should be empty
        #expect(store.loadAll().isEmpty)
    }
}

// MARK: - CrashReportStore Export Tests

struct CrashReportStoreExportTests {

    private func makeTempStore() -> CrashReportStore {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-CrashStore-Export-\(UUID().uuidString)")
        return CrashReportStore(storageDirectory: tmpDir)
    }

    private func cleanup(_ store: CrashReportStore) {
        try? FileManager.default.removeItem(at: store.storageDirectory)
    }

    @Test func copyAllToClipboard_emptyStore_returnsZero() {
        let store = makeTempStore()
        defer { cleanup(store) }

        let copiedCount = store.copyAllToClipboard()
        #expect(copiedCount == 0)
    }

    @Test func copyAllToClipboard_withReports_returnsCopiedCount() {
        let store = makeTempStore()
        defer { cleanup(store) }

        store.save(CrashReport(signal: "SIGSEGV"))
        store.save(CrashReport(signal: "SIGABRT"))

        let copiedCount = store.copyAllToClipboard()
        #expect(copiedCount == 2)
    }

    @Test func copyAllToClipboard_writesValidJSON() {
        let store = makeTempStore()
        defer { cleanup(store) }

        let report = CrashReport(signal: "SIGSEGV", exceptionType: "EXC_BAD_ACCESS")
        store.save(report)

        store.copyAllToClipboard()

        let pasteboard = NSPasteboard.general
        guard let json = pasteboard.string(forType: .string) else {
            #expect(Bool(false), "Clipboard should contain a string")
            return
        }

        // Verify it's valid JSON (uses iso8601 date encoding)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8),
              let decoded = try? decoder.decode([CrashReport].self, from: data) else {
            #expect(Bool(false), "Clipboard content should be valid JSON decodable to [CrashReport]")
            return
        }

        #expect(decoded.count == 1)
        #expect(decoded[0].signal == "SIGSEGV")
        #expect(decoded[0].exceptionType == "EXC_BAD_ACCESS")
    }

    @Test func storageDirectory_isAccessible() {
        let store = makeTempStore()
        defer { cleanup(store) }

        // The storage directory should exist after init
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: store.storageDirectory.path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
    }
}

// MARK: - CrashReportingSettings Opt-In Race Tests

struct CrashReportingSettingsRaceTests {

    private func withCleanDefaults(_ body: () -> Void) {
        let enabledKey = CrashReportingSettings.enabledKey
        let promptKey = CrashReportingSettings.promptShownKey
        let savedEnabled = UserDefaults.standard.object(forKey: enabledKey)
        let savedPrompt = UserDefaults.standard.object(forKey: promptKey)

        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: promptKey)

        body()

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

    @Test func hasShownPrompt_setBeforeDisplay_preventsRace() {
        withCleanDefaults {
            // Simulate what showCrashReportingOptInIfNeeded now does:
            // set hasShownPrompt BEFORE the async delay
            #expect(CrashReportingSettings.needsPrompt)

            // First "window" marks prompt as shown
            CrashReportingSettings.hasShownPrompt = true

            // Second "window" should see prompt already shown
            #expect(!CrashReportingSettings.needsPrompt)
        }
    }

    @Test func recordChoice_afterHasShownPrompt_worksCorrectly() {
        withCleanDefaults {
            // Mark as shown (as the fix does)
            CrashReportingSettings.hasShownPrompt = true
            #expect(!CrashReportingSettings.needsPrompt)
            #expect(!CrashReportingSettings.isEnabled) // Not yet enabled

            // User clicks Enable
            CrashReportingSettings.recordChoice(enabled: true)
            #expect(CrashReportingSettings.isEnabled)
            #expect(CrashReportingSettings.hasShownPrompt) // Still true
        }
    }

    @Test func recordChoice_afterHasShownPrompt_disable() {
        withCleanDefaults {
            CrashReportingSettings.hasShownPrompt = true
            CrashReportingSettings.recordChoice(enabled: false)
            #expect(!CrashReportingSettings.isEnabled)
            #expect(CrashReportingSettings.hasShownPrompt)
        }
    }
}

// MARK: - CrashReportingManager Stop Tests

struct CrashReportingManagerStopTests {

    @Test func stop_canBeCalledMultipleTimes() {
        let store = CrashReportStore(
            storageDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("PineTests-Manager-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: store.storageDirectory) }

        let manager = CrashReportingManager(store: store)
        // Multiple stop() calls should not crash
        manager.stop()
        manager.stop()
        manager.stop()
    }

    @Test func crashMarkerPath_isNotEmpty() {
        let path = CrashReportingManager.crashMarkerPath
        #expect(!path.isEmpty)
        #expect(path.contains("Pine"))
    }
}

// MARK: - Strings Constants Tests

struct CrashReportingStringsTests {

    @Test func optInEnable_string_isNotEmpty() {
        let value = Strings.crashReportingOptInEnable
        #expect(!value.isEmpty)
    }

    @Test func optInDisable_string_isNotEmpty() {
        let value = Strings.crashReportingOptInDisable
        #expect(!value.isEmpty)
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

    @Test func crashReportsReveal_iconExists() {
        #expect(
            NSImage(systemSymbolName: MenuIcons.crashReportsReveal, accessibilityDescription: nil) != nil,
            "SF Symbol '\(MenuIcons.crashReportsReveal)' does not exist"
        )
    }

    @Test func crashReportsCopy_iconExists() {
        #expect(
            NSImage(systemSymbolName: MenuIcons.crashReportsCopy, accessibilityDescription: nil) != nil,
            "SF Symbol '\(MenuIcons.crashReportsCopy)' does not exist"
        )
    }
}
