//
//  CrashReport.swift
//  Pine
//
//  Data model for a crash report. Contains only anonymous diagnostic info —
//  no file contents, no file paths, no personal data.
//

import Foundation

struct CrashReport: Codable, Sendable {
    /// Exception type (e.g. "NSInvalidArgumentException", "EXC_BAD_ACCESS").
    let exceptionType: String

    /// Exception reason / signal description.
    let exceptionReason: String

    /// Symbolicated stack trace frames.
    let stackTrace: [String]

    /// Pine version (CFBundleShortVersionString).
    let appVersion: String

    /// Pine build number (CFBundleVersion).
    let buildNumber: String

    /// macOS version string.
    let osVersion: String

    /// Number of open editor tabs at time of crash — helps gauge severity.
    let openFileCount: Int

    /// When the crash occurred.
    let timestamp: Date

    /// Human-readable text representation for display in the "send report?" dialog.
    var formattedText: String {
        var lines: [String] = []
        lines.append("Pine \(appVersion) (\(buildNumber)) on \(osVersion)")
        lines.append("Open files: \(openFileCount)")
        lines.append("Time: \(ISO8601DateFormatter().string(from: timestamp))")
        lines.append("")
        lines.append("Exception: \(exceptionType)")
        lines.append("Reason: \(exceptionReason)")
        lines.append("")
        lines.append("Stack Trace:")
        for frame in stackTrace {
            lines.append("  \(frame)")
        }
        return lines.joined(separator: "\n")
    }
}
