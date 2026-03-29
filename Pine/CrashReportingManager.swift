//
//  CrashReportingManager.swift
//  Pine
//
//  Central coordinator for crash reporting using MetricKit as primary
//  and POSIX signal handlers as a minimal fallback.
//

import Foundation
import MetricKit
import os

/// Coordinates crash reporting using MetricKit (MXCrashDiagnostic) as the
/// primary source and POSIX signal handlers as a minimal async-signal-safe fallback.
///
/// MetricKit delivers crash diagnostics on next launch via `MXMetricManagerSubscriber`.
/// The signal handler writes a minimal marker file using only POSIX APIs (no Swift/Foundation).
final class CrashReportingManager: NSObject, MXMetricManagerSubscriber {
    /// Shared singleton.
    static let shared = CrashReportingManager()

    private let logger = Logger(subsystem: "com.pine.editor", category: "CrashReporting")
    private let store: CrashReportStore

    /// Path to the signal handler's crash marker file.
    /// Written by the C-level signal handler using only async-signal-safe POSIX calls.
    static var crashMarkerPath: String {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            return NSTemporaryDirectory() + "Pine_crash_marker"
        }
        return appSupport.appendingPathComponent("Pine/crash_marker").path
    }

    init(store: CrashReportStore = .shared) {
        self.store = store
        super.init()
    }

    /// Starts crash reporting if the user has opted in.
    /// Call this from `applicationDidFinishLaunching`.
    func startIfEnabled() {
        guard CrashReportingSettings.isEnabled else {
            logger.info("Crash reporting is disabled by user preference")
            return
        }

        // Subscribe to MetricKit diagnostics
        MXMetricManager.shared.add(self)

        // Install signal handler fallback
        installSignalHandlers()

        // Check for crash marker from previous signal-based crash
        checkForCrashMarker()

        logger.info("Crash reporting started (MetricKit + signal handler fallback)")
    }

    /// Stops crash reporting (unsubscribes from MetricKit).
    func stop() {
        MXMetricManager.shared.remove(self)
        logger.info("Crash reporting stopped")
    }

    // MARK: - MXMetricManagerSubscriber

    /// Called by MetricKit when crash diagnostics are available (typically next launch).
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard CrashReportingSettings.isEnabled else { return }

        for payload in payloads {
            if let crashDiagnostics = payload.crashDiagnostics {
                for diagnostic in crashDiagnostics {
                    processCrashDiagnostic(diagnostic)
                }
            }
        }
    }

    /// Processes a single MetricKit crash diagnostic into a CrashReport.
    private func processCrashDiagnostic(_ diagnostic: MXCrashDiagnostic) {
        let callStack: [String]
        let jsonData = diagnostic.jsonRepresentation()
        if let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let stacks = json["callStackTree"] as? [String: Any],
           let callStackString = stacks.description.data(using: .utf8) {
            callStack = CrashReport.parseCallStack(String(data: callStackString, encoding: .utf8) ?? "")
        } else {
            callStack = []
        }

        let report = CrashReport(
            signal: diagnostic.signal?.description,
            exceptionType: diagnostic.exceptionType?.description,
            terminationReason: diagnostic.terminationReason,
            callStackFrames: callStack
        )

        store.save(report)
        logger.info("Saved MetricKit crash report: \(report.id)")
    }

    // MARK: - Signal Handler Fallback

    /// Installs POSIX signal handlers for common crash signals.
    /// The handler is strictly async-signal-safe: only POSIX write() and _exit().
    private func installSignalHandlers() {
        let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP]

        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = signalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(sig, &action, nil)
        }
    }

    /// Checks for a crash marker file left by the signal handler.
    /// If found, creates a minimal CrashReport from it.
    private func checkForCrashMarker() {
        let path = Self.crashMarkerPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else { return }

        // Read the signal number from the marker file
        let signalName: String?
        if let data = fm.contents(atPath: path),
           let content = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            signalName = content
        } else {
            signalName = "unknown"
        }

        let report = CrashReport(
            signal: signalName,
            exceptionType: "Signal crash (fallback handler)",
            callStackFrames: ["[Call stack not available — captured by signal handler fallback]"]
        )

        store.save(report)
        logger.info("Saved signal-handler crash report: \(report.id)")

        // Clean up the marker file
        try? fm.removeItem(atPath: path)
    }
}

// MARK: - Async-signal-safe crash handler (C-level, no Swift/Foundation)

/// Strictly async-signal-safe signal handler.
/// Uses ONLY POSIX APIs: open(), write(), close(), _exit().
/// No Swift runtime, no Foundation, no malloc, no ObjC messaging.
private func signalHandler(_ signal: Int32) {
    // Get the crash marker path — this is a compile-time known location
    // We cannot use Swift String here, so we use a pre-computed C string
    let path = CrashReportingManager.crashMarkerPath

    path.withCString { cPath in
        // Open file for writing (create if needed, truncate)
        let fd = open(cPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            _exit(signal)
        }

        // Write the signal number as ASCII digits
        var sigNum = signal
        var digits: [UInt8] = []

        if sigNum == 0 {
            digits.append(0x30) // '0'
        } else {
            while sigNum > 0 {
                digits.append(UInt8(0x30 + sigNum % 10))
                sigNum /= 10
            }
            digits.reverse()
        }

        digits.withUnsafeBufferPointer { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }

        // Write newline
        var newline: UInt8 = 0x0A
        _ = write(fd, &newline, 1)

        close(fd)
    }

    // Re-raise with default handler to get proper exit code
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}
