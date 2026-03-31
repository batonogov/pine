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

// MARK: - Global async-signal-safe storage for crash marker path

/// Pre-computed C string for the crash marker path.
/// Set once during `installSignalHandlers()`, read-only in the signal handler.
/// Using nonisolated(unsafe) because signal handlers are inherently unsafe
/// and this is written once before any signal can fire.
nonisolated(unsafe) private var crashMarkerCString: UnsafeMutablePointer<CChar>?

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

    /// Extracts call stack frame strings from MetricKit JSON representation.
    /// Parses the `callStackTree` → `callStacks` → `callStackRootFrames` hierarchy,
    /// flattening nested frames into human-readable strings.
    static func extractCallStackFrames(from jsonData: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let callStackTree = json["callStackTree"] as? [String: Any],
              let callStacks = callStackTree["callStacks"] as? [[String: Any]] else {
            return []
        }

        var frames: [String] = []
        for stack in callStacks {
            guard let rootFrames = stack["callStackRootFrames"] as? [[String: Any]] else { continue }
            Self.flattenFrames(rootFrames, into: &frames)
        }
        return frames
    }

    /// Recursively flattens nested call stack frames into a flat list of strings.
    private static func flattenFrames(_ frameList: [[String: Any]], into result: inout [String]) {
        for frame in frameList {
            let address = frame["address"] as? UInt64 ?? 0
            let binaryName = frame["binaryName"] as? String ?? "?"
            let offsetIntoBinaryTextSegment = frame["offsetIntoBinaryTextSegment"] as? UInt64 ?? 0
            result.append(String(
                format: "%@ 0x%llx +%llu",
                binaryName, address, offsetIntoBinaryTextSegment
            ))
            if let subFrames = frame["subFrames"] as? [[String: Any]] {
                flattenFrames(subFrames, into: &result)
            }
        }
    }

    /// Stops crash reporting: unsubscribes from MetricKit and restores default signal handlers.
    /// Frees the pre-computed crash marker C string to avoid memory leaks on toggle cycles.
    func stop() {
        MXMetricManager.shared.remove(self)

        // Restore default signal handlers
        let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP]
        for sig in signals {
            signal(sig, SIG_DFL)
        }

        // Free the strdup'd path to prevent memory leak on repeated start/stop cycles
        if let ptr = crashMarkerCString {
            free(ptr)
            crashMarkerCString = nil
        }

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
        let callStack: [String] = Self.extractCallStackFrames(from: diagnostic.jsonRepresentation())

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
    /// Pre-computes the crash marker path as a C string so the handler
    /// never touches Swift/Foundation/malloc.
    private func installSignalHandlers() {
        // Pre-compute the path as a C string BEFORE installing handlers.
        // This is the ONLY place we allocate — the handler only reads this pointer.
        // Free any previously allocated string to prevent leaks on repeated start() calls.
        if let previous = crashMarkerCString {
            free(previous)
            crashMarkerCString = nil
        }
        let path = Self.crashMarkerPath
        let cString = strdup(path)
        crashMarkerCString = cString

        let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP]

        for sig in signals {
            signal(sig, signalHandler)
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
///
/// The crash marker path is pre-computed in `installSignalHandlers()` and stored
/// in the global `crashMarkerCString`. This function only reads that pointer.
private func signalHandler(_ sig: Int32) {
    // Read pre-computed C string path — no allocation, no Swift runtime
    guard let cPath = crashMarkerCString else {
        _exit(sig)
    }

    // Open file for writing (create if needed, truncate)
    let fd = open(cPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else {
        _exit(sig)
    }

    // Write the signal number as ASCII digits using a stack buffer (no malloc).
    // Max digits for Int32: 10 digits + newline = 11 bytes. Using a 4-byte tuple
    // is sufficient since POSIX signals are small numbers (1-31).
    var buf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0))
    var sigNum = sig
    var len = 0

    if sigNum == 0 {
        buf.0 = 0x30 // '0'
        len = 1
    } else {
        // Signals are 1-31, so at most 2 digits — reverse into buf
        var tmp = (UInt8(0), UInt8(0))
        var tmpLen = 0
        while sigNum > 0, tmpLen < 2 {
            if tmpLen == 0 {
                tmp.0 = UInt8(0x30 + sigNum % 10)
            } else {
                tmp.1 = UInt8(0x30 + sigNum % 10)
            }
            tmpLen += 1
            sigNum /= 10
        }
        if tmpLen == 1 {
            buf.0 = tmp.0
        } else {
            buf.0 = tmp.1
            buf.1 = tmp.0
        }
        len = tmpLen
    }

    // Append newline
    if len == 0 {
        buf.0 = 0x0A
    } else if len == 1 {
        buf.1 = 0x0A
    } else {
        buf.2 = 0x0A
    }
    len += 1

    // Write using POSIX write() — async-signal-safe
    withUnsafePointer(to: &buf) { ptr in
        _ = write(fd, ptr, len)
    }

    close(fd)

    // Re-raise with default handler to get proper exit code
    Darwin.signal(sig, SIG_DFL)
    raise(sig)
}
