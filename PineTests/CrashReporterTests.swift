//
//  CrashReporterTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

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

    // MARK: - Opt-in default state

    @Test func crashReportingIsDisabledByDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = CrashReportSettings(defaults: defaults)
        #expect(settings.isEnabled == false)
    }

    // MARK: - Persistence

    @Test func enablingPersistsToUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = CrashReportSettings(defaults: defaults)
        settings.isEnabled = true

        #expect(defaults.bool(forKey: CrashReportSettings.enabledKey) == true)
    }

    @Test func disablingPersistsToUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = CrashReportSettings(defaults: defaults)
        settings.isEnabled = true
        settings.isEnabled = false

        #expect(defaults.bool(forKey: CrashReportSettings.enabledKey) == false)
    }

    @Test func settingLoadsFromUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(true, forKey: CrashReportSettings.enabledKey)

        let settings = CrashReportSettings(defaults: defaults)
        #expect(settings.isEnabled == true)
    }

    @Test func hasBeenAskedDefaultsToFalse() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = CrashReportSettings(defaults: defaults)
        #expect(settings.hasBeenAsked == false)
    }

    @Test func hasBeenAskedPersists() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = CrashReportSettings(defaults: defaults)
        settings.hasBeenAsked = true

        #expect(defaults.bool(forKey: CrashReportSettings.askedKey) == true)

        let settings2 = CrashReportSettings(defaults: defaults)
        #expect(settings2.hasBeenAsked == true)
    }

    // MARK: - CrashReport data model

    @Test func crashReportContainsRequiredFields() {
        let report = CrashReport(
            exceptionType: "NSInvalidArgumentException",
            exceptionReason: "Unrecognized selector",
            stackTrace: ["frame1", "frame2"],
            appVersion: "1.10.0",
            buildNumber: "42",
            osVersion: "macOS 26.0",
            openFileCount: 5,
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )

        #expect(report.exceptionType == "NSInvalidArgumentException")
        #expect(report.exceptionReason == "Unrecognized selector")
        #expect(report.stackTrace.count == 2)
        #expect(report.appVersion == "1.10.0")
        #expect(report.buildNumber == "42")
        #expect(report.osVersion == "macOS 26.0")
        #expect(report.openFileCount == 5)
        #expect(report.timestamp == Date(timeIntervalSince1970: 1_000_000))
    }

    @Test func crashReportEncodesAndDecodes() throws {
        let report = CrashReport(
            exceptionType: "EXC_BAD_ACCESS",
            exceptionReason: "Signal SIGSEGV",
            stackTrace: ["0x1234", "0x5678"],
            appVersion: "1.10.0",
            buildNumber: "1",
            osVersion: "macOS 26.0",
            openFileCount: 3,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(CrashReport.self, from: data)

        #expect(decoded.exceptionType == report.exceptionType)
        #expect(decoded.exceptionReason == report.exceptionReason)
        #expect(decoded.stackTrace == report.stackTrace)
        #expect(decoded.appVersion == report.appVersion)
        #expect(decoded.buildNumber == report.buildNumber)
        #expect(decoded.osVersion == report.osVersion)
        #expect(decoded.openFileCount == report.openFileCount)
        #expect(decoded.timestamp == report.timestamp)
    }

    // MARK: - CrashReportStore

    @Test func savesAndLoadsReport() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)
        let report = CrashReport(
            exceptionType: "NSException",
            exceptionReason: "test",
            stackTrace: ["frame"],
            appVersion: "1.0",
            buildNumber: "1",
            osVersion: "macOS 26.0",
            openFileCount: 0,
            timestamp: Date()
        )

        try store.save(report)
        let pending = try store.loadPending()

        #expect(pending.count == 1)
        #expect(pending[0].exceptionType == "NSException")
    }

    @Test func deletesPendingReports() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)
        let report = CrashReport(
            exceptionType: "Test",
            exceptionReason: "reason",
            stackTrace: [],
            appVersion: "1.0",
            buildNumber: "1",
            osVersion: "macOS 26.0",
            openFileCount: 0,
            timestamp: Date()
        )

        try store.save(report)
        #expect(try store.loadPending().count == 1)

        try store.deleteAll()
        #expect(try store.loadPending().isEmpty)
    }

    @Test func loadPendingReturnsEmptyWhenNoReports() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)
        let pending = try store.loadPending()
        #expect(pending.isEmpty)
    }

    @Test func multipleReportsAreSavedAndLoaded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CrashReportStore(directory: dir)

        for idx in 0..<3 {
            let report = CrashReport(
                exceptionType: "Type\(idx)",
                exceptionReason: "reason",
                stackTrace: [],
                appVersion: "1.0",
                buildNumber: "1",
                osVersion: "macOS 26.0",
                openFileCount: idx,
                timestamp: Date()
            )
            try store.save(report)
        }

        let pending = try store.loadPending()
        #expect(pending.count == 3)
    }

    // MARK: - CrashReport formatted output

    @Test func formattedReportContainsAllInfo() {
        let report = CrashReport(
            exceptionType: "NSInvalidArgumentException",
            exceptionReason: "Test reason",
            stackTrace: ["frame1", "frame2"],
            appVersion: "1.10.0",
            buildNumber: "42",
            osVersion: "macOS 26.0",
            openFileCount: 5,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let text = report.formattedText
        #expect(text.contains("NSInvalidArgumentException"))
        #expect(text.contains("Test reason"))
        #expect(text.contains("frame1"))
        #expect(text.contains("1.10.0"))
        #expect(text.contains("42"))
        #expect(text.contains("macOS 26.0"))
        #expect(text.contains("5"))
    }
}
