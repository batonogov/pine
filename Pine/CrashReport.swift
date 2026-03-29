//
//  CrashReport.swift
//  Pine
//
//  Model for crash diagnostic data collected via MetricKit.
//

import Foundation

/// A structured crash report collected from MetricKit diagnostics.
struct CrashReport: Codable, Equatable, Sendable {
    /// Unique identifier for deduplication.
    let id: UUID

    /// Timestamp when the crash occurred.
    let timestamp: Date

    /// App version at the time of crash (CFBundleShortVersionString).
    let appVersion: String

    /// Build number at the time of crash (CFBundleVersion).
    let buildNumber: String

    /// macOS version string (e.g. "26.0").
    let osVersion: String

    /// Signal that caused the crash (e.g. SIGSEGV, SIGABRT).
    let signal: String?

    /// Exception type if available.
    let exceptionType: String?

    /// Termination reason if available.
    let terminationReason: String?

    /// Call stack frames as human-readable strings.
    let callStackFrames: [String]

    /// Number of open editor tabs at crash time (privacy-safe metric).
    let openTabCount: Int?

    /// Creates a CrashReport with current app/OS metadata.
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        signal: String? = nil,
        exceptionType: String? = nil,
        terminationReason: String? = nil,
        callStackFrames: [String] = [],
        openTabCount: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        self.buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        self.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        self.signal = signal
        self.exceptionType = exceptionType
        self.terminationReason = terminationReason
        self.callStackFrames = callStackFrames
        self.openTabCount = openTabCount
    }

    /// Internal initializer for testing with explicit app/OS values.
    init(
        id: UUID,
        timestamp: Date,
        appVersion: String,
        buildNumber: String,
        osVersion: String,
        signal: String?,
        exceptionType: String?,
        terminationReason: String?,
        callStackFrames: [String],
        openTabCount: Int?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.signal = signal
        self.exceptionType = exceptionType
        self.terminationReason = terminationReason
        self.callStackFrames = callStackFrames
        self.openTabCount = openTabCount
    }
}

// MARK: - Call Stack Parsing

extension CrashReport {
    /// Parses a raw call stack string into individual frame strings.
    /// Handles both MetricKit JSON format and standard crash log format.
    ///
    /// Each frame typically looks like:
    /// `0   Pine                        0x00000001000a1234 someFunction + 42`
    static func parseCallStack(_ rawCallStack: String) -> [String] {
        let lines = rawCallStack.components(separatedBy: .newlines)
        return lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
