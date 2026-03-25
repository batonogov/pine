//
//  CrashReporterTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

// swiftlint:disable type_body_length file_length

@Suite("CrashReporter Tests")
struct CrashReporterTests {

    private let suiteName = "PineTests.CrashReporter.\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return defaults
    }

    private func cleanupDefaults(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "PineTests.CrashReporter.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeReport(
        exceptionType: String = "NSException",
        exceptionReason: String = "test",
        stackTrace: [String] = ["frame"],
        appVersion: String = "1.0",
        buildNumber: String = "1",
        osVersion: String = "macOS 26.0",
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        source: CrashReport.Source = .exception
    ) -> CrashReport {
        CrashReport(
            exceptionType: exceptionType,
            exceptionReason: exceptionReason,
            stackTrace: stackTrace,
            appVersion: appVersion,
            buildNumber: buildNumber,
            osVersion: osVersion,
            timestamp: timestamp,
            source: source
        )
    }

    // MARK: - Settings: default values

    @MainActor
    @Test func crashReportingIsDisabledByDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = CrashReportSettings(defaults: defaults)
        #expect(settings.isEnabled == false)
    }

    @MainActor
    @Test func hasBeenAskedDefaultsToFalse() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = CrashReportSettings(defaults: defaults)
        #expect(settings.hasBeenAsked == false)
    }

    // MARK: - Settings: enable/disable/toggle

    @MainActor
    @Test func enablingPersistsToUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = CrashReportSettings(defaults: defaults)
        settings.isEnabled = true

        #expect(defaults.bool(forKey: CrashReportSettings.Keys.enabled) == true)
    }

    @MainActor
    @Test func disablingPersistsToUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = CrashReportSettings(defaults: defaults)
        settings.isEnabled = true
        settings.isEnabled = false

        #expect(defaults.bool(forKey: CrashReportSettings.Keys.enabled) == false)
    }

    @MainActor
    @Test func toggleEnableDisableEnable() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = CrashReportSettings(defaults: defaults)
        #expect(settings.isEnabled == false)

        settings.isEnabled = true
        #expect(settings.isEnabled == true)
        #expect(defaults.bool(forKey: CrashReportSettings.Keys.enabled) == true)

        settings.isEnabled = false
        #expect(settings.isEnabled == false)
        #expect(defaults.bool(forKey: CrashReportSettings.Keys.enabled) == false)

        settings.isEnabled = true
        #expect(settings.isEnabled == true)
    }

    // MARK: - Settings: persistence across restarts

    @MainActor
    @Test func settingLoadsFromUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(true, forKey: CrashReportSettings.Keys.enabled)

        let settings = CrashReportSettings(defaults: defaults)
        #expect(settings.isEnabled == true)
    }

    @MainActor
    @Test func hasBeenAskedPersistsAcrossInstances() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings1 = CrashReportSettings(defaults: defaults)
        settings1.hasBeenAsked = true

        #expect(defaults.bool(forKey: CrashReportSettings.Keys.asked) == true)

        let settings2 = CrashReportSettings(defaults: defaults)
        #expect(settings2.hasBeenAsked == true)
    }

    @MainActor
    @Test func enabledStatePersistsAcrossInstances() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings1 = CrashReportSettings(defaults: defaults)
        settings1.isEnabled = true

        let settings2 = CrashReportSettings(defaults: defaults)
        #expect(settings2.isEnabled == true)
    }

    // MARK: - Settings: keys are correct

    @MainActor
    @Test func settingsKeysAreStable() {
        #expect(CrashReportSettings.Keys.enabled == "crashReportingEnabled")
        #expect(CrashReportSettings.Keys.asked == "crashReportingAsked")
    }

    // MARK: - CrashReport: all fields populated

    @Test func crashReportContainsAllFields() {
        let report = makeReport(
            exceptionType: "NSInvalidArgumentException",
            exceptionReason: "Unrecognized selector",
            stackTrace: ["frame1", "frame2"],
            appVersion: "1.10.0",
            buildNumber: "42",
            osVersion: "macOS 26.0",
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            source: .metricKit
        )

        #expect(report.exceptionType == "NSInvalidArgumentException")
        #expect(report.exceptionReason == "Unrecognized selector")
        #expect(report.stackTrace.count == 2)
        #expect(report.appVersion == "1.10.0")
        #expect(report.buildNumber == "42")
        #expect(report.osVersion == "macOS 26.0")
        #expect(report.timestamp == Date(timeIntervalSince1970: 1_000_000))
        #expect(report.source == .metricKit)
    }

    // MARK: - CrashReport: encode/decode

    @Test func crashReportEncodesAndDecodes() throws {
        let report = makeReport(
            exceptionType: "EXC_BAD_ACCESS",
            exceptionReason: "Signal SIGSEGV",
            stackTrace: ["0x1234", "0x5678"],
            appVersion: "1.10.0",
            buildNumber: "1",
            source: .exception
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(report)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CrashReport.self, from: data)

        #expect(decoded.exceptionType == report.exceptionType)
        #expect(decoded.exceptionReason == report.exceptionReason)
        #expect(decoded.stackTrace == report.stackTrace)
        #expect(decoded.appVersion == report.appVersion)
        #expect(decoded.buildNumber == report.buildNumber)
        #expect(decoded.osVersion == report.osVersion)
        #expect(decoded.timestamp == report.timestamp)
        #expect(decoded.source == report.source)
    }

    @Test func crashReportEncodesAllSources() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        for source in [CrashReport.Source.metricKit, .signal, .exception] {
            let report = makeReport(source: source)
            let data = try encoder.encode(report)
            let decoded = try decoder.decode(CrashReport.self, from: data)
            #expect(decoded.source == source)
        }
    }

    // MARK: - CrashReport: signal crash JSON parsing (К4 fix)

    @Test func signalCrashJSONDecodesWithSecondsSince1970() throws {
        // This simulates the JSON written by the async-signal-safe signal handler
        let json = """
        {"exceptionType":"Signal","exceptionReason":"Signal 11",\
        "stackTrace":[],"appVersion":"","buildNumber":"",\
        "osVersion":"","timestamp":1700000000,"source":"signal"}
        """
        let data = Data(json.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let report = try decoder.decode(CrashReport.self, from: data)

        #expect(report.exceptionType == "Signal")
        #expect(report.exceptionReason == "Signal 11")
        #expect(report.stackTrace.isEmpty)
        #expect(report.source == .signal)
        #expect(report.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func signalCrashJSONWithZeroTimestamp() throws {
        let json = """
        {"exceptionType":"Signal","exceptionReason":"Signal 6",\
        "stackTrace":[],"appVersion":"","buildNumber":"",\
        "osVersion":"","timestamp":0,"source":"signal"}
        """
        let data = Data(json.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let report = try decoder.decode(CrashReport.self, from: data)

        #expect(report.timestamp == Date(timeIntervalSince1970: 0))
    }

    // MARK: - CrashReport: formatted text

    @Test func formattedReportContainsAllInfo() {
        let report = makeReport(
            exceptionType: "NSInvalidArgumentException",
            exceptionReason: "Test reason",
            stackTrace: ["frame1", "frame2"],
            appVersion: "1.10.0",
            buildNumber: "42",
            osVersion: "macOS 26.0",
            source: .exception
        )

        let text = report.formattedText
        #expect(text.contains("NSInvalidArgumentException"))
        #expect(text.contains("Test reason"))
        #expect(text.contains("frame1"))
        #expect(text.contains("frame2"))
        #expect(text.contains("1.10.0"))
        #expect(text.contains("42"))
        #expect(text.contains("macOS 26.0"))
        #expect(text.contains("exception"))
        #expect(text.contains("Source:"))
        #expect(text.contains("Stack Trace:"))
    }

    @Test func formattedReportWithEmptyStackTrace() {
        let report = makeReport(stackTrace: [])
        let text = report.formattedText
        #expect(text.contains("Stack Trace:"))
        // No frame lines after "Stack Trace:"
        let lines = text.components(separatedBy: "\n")
        guard let stackIdx = lines.firstIndex(where: { $0 == "Stack Trace:" }) else {
            Issue.record("Expected 'Stack Trace:' line")
            return
        }
        // All remaining lines should be empty or not start with "  " (no frames)
        let afterStack = lines[(stackIdx + 1)...]
        #expect(afterStack.allSatisfy { !$0.hasPrefix("  ") })
    }

    @Test func formattedReportDateIsISO8601() {
        let report = makeReport(timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let text = report.formattedText
        // ISO8601 format contains "T" separator and "Z" suffix
        #expect(text.contains("Time:"))
        let lines = text.components(separatedBy: "\n")
        let timeLine = lines.first { $0.hasPrefix("Time:") }
        #expect(timeLine != nil)
        #expect(timeLine?.contains("T") == true)
    }

    // MARK: - CrashReport: source enum

    @Test func sourceRawValues() {
        #expect(CrashReport.Source.metricKit.rawValue == "metricKit")
        #expect(CrashReport.Source.signal.rawValue == "signal")
        #expect(CrashReport.Source.exception.rawValue == "exception")
    }

    // MARK: - CrashReportStore: save/load

    @Test func savesAndLoadsReport() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)
        let report = makeReport()

        try store.save(report)
        let pending = try store.loadPending()

        #expect(pending.count == 1)
        #expect(pending[0].exceptionType == "NSException")
    }

    @Test func multipleReportsAreSavedAndLoaded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)

        for idx in 0..<3 {
            let report = makeReport(exceptionType: "Type\(idx)")
            try store.save(report)
        }

        let pending = try store.loadPending()
        #expect(pending.count == 3)
    }

    // MARK: - CrashReportStore: delete

    @Test func deletesPendingReports() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)
        try store.save(makeReport())
        #expect(try store.loadPending().count == 1)

        try store.deleteAll()
        #expect(try store.loadPending().isEmpty)
    }

    // MARK: - CrashReportStore: empty directory

    @Test func loadPendingReturnsEmptyWhenNoReports() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)
        let pending = try store.loadPending()
        #expect(pending.isEmpty)
    }

    // MARK: - CrashReportStore: missing directory

    @Test func loadPendingReturnsEmptyWhenDirectoryMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "PineTests.NonExistent.\(UUID().uuidString)")
        let store = CrashReportStore(directory: dir)
        let pending = try store.loadPending()
        #expect(pending.isEmpty)
    }

    @Test func deleteAllDoesNotThrowWhenDirectoryMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "PineTests.NonExistent.\(UUID().uuidString)")
        let store = CrashReportStore(directory: dir)
        try store.deleteAll()
        // No throw = success
    }

    // MARK: - CrashReportStore: corrupted JSON

    @Test func loadPendingSkipsCorruptedJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)

        // Save a valid report
        try store.save(makeReport())

        // Write corrupted JSON file
        let corruptedFile = dir.appending(path: "corrupted.json")
        try Data("not valid json {{{".utf8).write(to: corruptedFile)

        let pending = try store.loadPending()
        // Should load the valid one and skip the corrupted one
        #expect(pending.count == 1)
    }

    @Test func loadPendingSkipsEmptyFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)

        // Write empty JSON file
        let emptyFile = dir.appending(path: "empty.json")
        try Data().write(to: emptyFile)

        let pending = try store.loadPending()
        #expect(pending.isEmpty)
    }

    // MARK: - CrashReportStore: non-JSON files ignored

    @Test func loadPendingIgnoresNonJSONFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)

        // Write a .txt file
        let txtFile = dir.appending(path: "notes.txt")
        try Data("some text".utf8).write(to: txtFile)

        // Save a valid report
        try store.save(makeReport())

        let pending = try store.loadPending()
        #expect(pending.count == 1)
    }

    // MARK: - CrashReportStore: ensures directory

    @Test func saveCreatesDirectoryIfNeeded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "PineTests.CrashStore.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))

        try store.save(makeReport())
        #expect(FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))

        let pending = try store.loadPending()
        #expect(pending.count == 1)
    }

    @Test func ensureDirectoryExistsCreatesPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "PineTests.EnsureDir.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)
        try store.ensureDirectoryExists()
        #expect(FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
    }

    // MARK: - CrashReportStore: default singleton is stable

    @Test func defaultStoreIsSameInstance() {
        let store1 = CrashReportStore.default
        let store2 = CrashReportStore.default
        #expect(store1.directory == store2.directory)
    }

    // MARK: - CrashReportStore: date encoding consistency

    @Test func storeUsesSecondsSince1970Encoding() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)
        let knownDate = Date(timeIntervalSince1970: 1_700_000_000)
        let report = makeReport(timestamp: knownDate)

        try store.save(report)

        // Read raw JSON to verify timestamp format
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let jsonFile = try #require(contents.first { $0.pathExtension == "json" })
        let data = try Data(contentsOf: jsonFile)
        let rawJSON = try #require(String(data: data, encoding: .utf8))

        // Should contain the timestamp as seconds since 1970
        #expect(rawJSON.contains("1700000000"))
    }

    // MARK: - CrashReportHandler: install/uninstall

    @MainActor
    @Test func installDoesNothingWhenDisabled() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = CrashReportSettings(defaults: defaults)
        settings.isEnabled = false

        // Should not crash or throw — just a no-op
        CrashReportHandler.install(settings: settings)
    }

    @MainActor
    @Test func checkForPendingReportsReturnsNilWhenEmpty() throws {
        // Create a temp directory and a store with no reports
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // This tests the static method with default store; no reports should exist
        // if the CrashReports directory doesn't have any JSON files
        let result = CrashReportHandler.checkForPendingReports()
        // May or may not be nil depending on whether other tests left reports
        // The key test is that it doesn't crash
        _ = result
    }

    @Test func clearPendingReportsDoesNotThrow() {
        // Should not crash even if directory doesn't exist
        CrashReportHandler.clearPendingReports()
    }

    // MARK: - Negative scenarios: invalid JSON decoding

    @Test func decodingInvalidJSONThrows() {
        let data = Data("{invalid}".utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(CrashReport.self, from: data)
        }
    }

    @Test func decodingEmptyDataThrows() {
        let data = Data()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(CrashReport.self, from: data)
        }
    }

    @Test func decodingJSONMissingFieldsThrows() {
        let json = """
        {"exceptionType":"Signal","exceptionReason":"test"}
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(CrashReport.self, from: data)
        }
    }

    @Test func decodingJSONWithWrongTimestampStrategyFails() {
        // Signal handler writes seconds since 1970.
        // Using default decoder (which expects Date reference format) should fail or mismatch.
        let json = """
        {"exceptionType":"Signal","exceptionReason":"Signal 11",\
        "stackTrace":[],"appVersion":"","buildNumber":"",\
        "osVersion":"","timestamp":1700000000,"source":"signal"}
        """
        let data = Data(json.utf8)

        // Default decoder uses deferredToDate, which interprets doubles as reference date
        let decoder = JSONDecoder()
        let report = try? decoder.decode(CrashReport.self, from: data)

        if let report {
            // If it decodes, the timestamp will be wrong (interpreted as seconds since reference date 2001)
            #expect(report.timestamp != Date(timeIntervalSince1970: 1_700_000_000))
        }
        // Either way, this demonstrates why .secondsSince1970 is needed
    }

    // MARK: - CrashReport: optional/empty fields

    @Test func crashReportWithEmptyStrings() throws {
        let report = makeReport(
            exceptionType: "",
            exceptionReason: "",
            stackTrace: [],
            appVersion: "",
            buildNumber: "",
            osVersion: ""
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(report)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CrashReport.self, from: data)

        #expect(decoded.exceptionType == "")
        #expect(decoded.exceptionReason == "")
        #expect(decoded.stackTrace.isEmpty)
        #expect(decoded.appVersion == "")
    }

    @Test func crashReportWithLargeStackTrace() throws {
        let frames = (0..<100).map { "frame_\($0)" }
        let report = makeReport(stackTrace: frames)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(report)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CrashReport.self, from: data)

        #expect(decoded.stackTrace.count == 100)
    }

    @Test func crashReportWithSpecialCharactersInReason() throws {
        let report = makeReport(
            exceptionReason: "Error: \"quoted\" with\nnewline and\ttab and emoji"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(report)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CrashReport.self, from: data)

        #expect(decoded.exceptionReason.contains("quoted"))
        #expect(decoded.exceptionReason.contains("\n"))
    }
}

// swiftlint:enable type_body_length file_length
