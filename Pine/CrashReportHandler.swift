//
//  CrashReportHandler.swift
//  Pine
//
//  Installs NSSetUncaughtExceptionHandler and POSIX signal handlers to capture
//  crash data. On crash, writes a CrashReport JSON to disk. On next launch,
//  the app checks for pending reports and optionally asks the user to send them.
//
//  Signal handlers use only async-signal-safe operations (write, open, close).
//  The detailed JSON report is written by the exception handler (ObjC exceptions
//  don't have the same restrictions as POSIX signals).
//

import Foundation
import os

// MARK: - Global C-compatible handler functions

/// Cached directory path for the signal handler (global for C function pointer compatibility).
private var crashReportDirectoryPath: [CChar] = []

/// Pre-built JSON template with placeholder for signal number.
/// Format: {"exceptionType":"Signal","exceptionReason":"Signal XX","stackTrace":[],...}
/// The "XX" at a known offset gets overwritten with the actual signal number.
private var signalJSONPrefix: [UInt8] = []
private var signalJSONSuffix: [UInt8] = []

/// Whether crash reporting is enabled (checked in handlers before writing).
private var crashReportingEnabled = false

/// Global exception handler — must be a plain function (no captures).
private func pineExceptionHandler(_ exception: NSException) {
    guard crashReportingEnabled else { return }

    let trace = exception.callStackSymbols
    let report = CrashReport(
        exceptionType: exception.name.rawValue,
        exceptionReason: exception.reason ?? "Unknown",
        stackTrace: trace,
        appVersion: AboutInfo.versionString,
        buildNumber: AboutInfo.buildString,
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        openFileCount: 0, // Can't safely access UI state during crash
        timestamp: Date()
    )

    do {
        try CrashReportStore.default.save(report)
    } catch {
        Logger.app.error("Failed to save crash report: \(error.localizedDescription)")
    }
}

/// Global signal handler — must be a plain function (no captures).
/// Uses only async-signal-safe operations: no String interpolation, no Date(),
/// no Array mutations, no memory allocations.
private func pineSignalHandler(_ sig: Int32) {
    guard crashReportingEnabled else {
        // Re-raise with default handler even if reporting is disabled
        signal(sig, SIG_DFL)
        raise(sig)
        return
    }
    guard !crashReportDirectoryPath.isEmpty else {
        signal(sig, SIG_DFL)
        raise(sig)
        return
    }

    // Build filename: "/signal-crash-NN.json"
    // Use fixed-size array to avoid heap allocations
    // "/signal-crash-" = 15 chars, up to 3 digits, ".json\0" = 6 chars = max 24
    var filenameBuf: [CChar] = [
        0x2F, // /
        0x73, 0x69, 0x67, 0x6E, 0x61, 0x6C, 0x2D, // signal-
        0x63, 0x72, 0x61, 0x73, 0x68, 0x2D, // crash-
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0 // digits + .json + null
    ]

    // Convert signal number to ASCII digits
    var num = sig < 0 ? -sig : sig
    var digitBuf: [CChar] = [0, 0, 0]
    var digitCount = 0

    if num == 0 {
        digitBuf[0] = 0x30 // '0'
        digitCount = 1
    } else {
        // Extract digits in reverse
        var tempCount = 0
        while num > 0 && tempCount < 3 {
            digitBuf[tempCount] = CChar(truncatingIfNeeded: (num % 10) + 0x30)
            tempCount += 1
            num /= 10
        }
        digitCount = tempCount
        // Reverse in-place
        if digitCount == 2 {
            let tmp = digitBuf[0]
            digitBuf[0] = digitBuf[1]
            digitBuf[1] = tmp
        } else if digitCount == 3 {
            let tmp = digitBuf[0]
            digitBuf[0] = digitBuf[2]
            digitBuf[2] = tmp
        }
    }

    // Place digits at offset 14, then ".json\0"
    var writeIdx = 14
    for dIdx in 0..<digitCount {
        filenameBuf[writeIdx] = digitBuf[dIdx]
        writeIdx += 1
    }
    filenameBuf[writeIdx] = 0x2E     // .
    filenameBuf[writeIdx + 1] = 0x6A // j
    filenameBuf[writeIdx + 2] = 0x73 // s
    filenameBuf[writeIdx + 3] = 0x6F // o
    filenameBuf[writeIdx + 4] = 0x6E // n
    filenameBuf[writeIdx + 5] = 0    // null

    // Build full path: dirPath + filename
    var pathBuf: [CChar] = Array(repeating: 0, count: 1024)
    var pathLen = 0

    // Copy directory path (without null terminator)
    for idx in 0..<crashReportDirectoryPath.count {
        let ch = crashReportDirectoryPath[idx]
        if ch == 0 { break }
        guard pathLen < 1023 else { break }
        pathBuf[pathLen] = ch
        pathLen += 1
    }

    // Copy filename
    var fnIdx = 0
    while filenameBuf[fnIdx] != 0 && pathLen < 1023 {
        pathBuf[pathLen] = filenameBuf[fnIdx]
        pathLen += 1
        fnIdx += 1
    }
    pathBuf[pathLen] = 0

    // Build minimal JSON: pre-built prefix + signal digits + pre-built suffix
    var jsonBuf: [UInt8] = Array(repeating: 0, count: 256)
    var jsonLen = 0

    for byte in signalJSONPrefix where jsonLen < 255 {
        jsonBuf[jsonLen] = byte
        jsonLen += 1
    }

    for dIdx in 0..<digitCount where jsonLen < 255 {
        jsonBuf[jsonLen] = UInt8(bitPattern: digitBuf[dIdx])
        jsonLen += 1
    }

    for byte in signalJSONSuffix where jsonLen < 255 {
        jsonBuf[jsonLen] = byte
        jsonLen += 1
    }

    // Ensure directory exists
    mkdir(&crashReportDirectoryPath, 0o755)

    // Write JSON to file using only POSIX calls
    let fd = open(&pathBuf, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 {
        _ = write(fd, &jsonBuf, jsonLen)
        close(fd)
    }

    // Re-raise signal with default handler so the OS generates a proper crash log
    signal(sig, SIG_DFL)
    raise(sig)
}

// MARK: - CrashReportHandler

/// Installs crash handlers and manages the crash-to-report pipeline.
enum CrashReportHandler {

    /// Tracked signals for crash detection.
    private static let crashSignals: [Int32] = [
        SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP
    ]

    /// Call once from applicationWillFinishLaunching to install handlers.
    /// Always installs handlers; the isEnabled flag is checked inside the handler
    /// before writing reports, so handlers work even if user opts in later.
    static func install(settings: CrashReportSettings) {
        // Sync the enabled flag for handlers to check
        crashReportingEnabled = settings.isEnabled

        // Cache the directory path as C string for the signal handler.
        let dirPath = CrashReportStore.default.directory.path(percentEncoded: false)
        crashReportDirectoryPath = Array(dirPath.utf8CString)

        // Pre-build JSON template parts (done once at startup, safe to allocate here)
        let prefix = #"{"exceptionType":"Signal","exceptionReason":"Signal "#
        let suffixPart1 = #"","stackTrace":[],"appVersion":"","#
        let suffixPart2 = #""buildNumber":"","osVersion":"","#
        let suffixPart3 = #""openFileCount":0,"timestamp":0}"#
        let suffix = suffixPart1 + suffixPart2 + suffixPart3
        signalJSONPrefix = Array(prefix.utf8)
        signalJSONSuffix = Array(suffix.utf8)

        // Exception handler for ObjC/Swift exceptions
        NSSetUncaughtExceptionHandler(pineExceptionHandler)

        // POSIX signal handlers for hard crashes
        for sig in crashSignals {
            signal(sig, pineSignalHandler)
        }
    }

    /// Updates the enabled flag (call after user changes opt-in preference).
    static func updateEnabled(_ enabled: Bool) {
        crashReportingEnabled = enabled
    }

    // MARK: - Next-launch check

    /// Checks for pending crash reports. Call from applicationDidFinishLaunching.
    /// Returns the reports if any exist, nil otherwise.
    static func checkForPendingReports() -> [CrashReport]? {
        let store = CrashReportStore.default
        do {
            let reports = try store.loadPending()
            return reports.isEmpty ? nil : reports
        } catch {
            Logger.app.error("Failed to load pending crash reports: \(error.localizedDescription)")
            return nil
        }
    }

    /// Deletes all pending crash reports (after user dismisses the dialog).
    static func clearPendingReports() {
        do {
            try CrashReportStore.default.deleteAll()
        } catch {
            Logger.app.error("Failed to clear crash reports: \(error.localizedDescription)")
        }
    }
}
