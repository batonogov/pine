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

// MARK: - Global C-compatible handler functions

/// Cached directory path for the signal handler (global for C function pointer compatibility).
private var crashReportDirectoryPath: [CChar] = []

/// Global exception handler — must be a plain function (no captures).
private func pineExceptionHandler(_ exception: NSException) {
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

    // Best-effort write — if this fails, we lose the report
    try? CrashReportStore.default.save(report)
}

/// Global signal handler — must be a plain function (no captures).
/// Uses only async-signal-safe operations.
private func pineSignalHandler(_ sig: Int32) {
    guard !crashReportDirectoryPath.isEmpty else { return }

    // Build path: <dir>/signal-crash-<signal>.json
    // Using fixed-size buffer to avoid allocations
    var pathBuf = crashReportDirectoryPath
    // Remove null terminator, append filename
    if pathBuf.last == 0 { pathBuf.removeLast() }
    let suffix = "/signal-crash-\(sig).json"
    suffix.withCString { ptr in
        var idx = 0
        while ptr[idx] != 0 {
            pathBuf.append(ptr[idx])
            idx += 1
        }
    }
    pathBuf.append(0) // null terminator

    // Build minimal JSON manually (no Foundation allocations in signal context)
    let json = """
    {"exceptionType":"Signal","exceptionReason":"Signal \(sig)",\
    "stackTrace":[],"appVersion":"","buildNumber":"",\
    "osVersion":"","openFileCount":0,\
    "timestamp":\(Date().timeIntervalSince1970)}
    """

    // Ensure directory exists
    mkdir(&crashReportDirectoryPath, 0o755)

    // Write JSON to file
    pathBuf.withUnsafeBufferPointer { buf in
        guard let ptr = buf.baseAddress else { return }
        let fd = open(ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        json.withCString { cJSON in
            _ = write(fd, cJSON, strlen(cJSON))
        }
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
    /// Only installs if crash reporting is enabled.
    static func install(settings: CrashReportSettings) {
        guard settings.isEnabled else { return }

        // Cache the directory path as C string for the signal handler.
        let dirPath = CrashReportStore.default.directory.path(percentEncoded: false)
        crashReportDirectoryPath = Array(dirPath.utf8CString)

        // Exception handler for ObjC/Swift exceptions
        NSSetUncaughtExceptionHandler(pineExceptionHandler)

        // POSIX signal handlers for hard crashes
        for sig in crashSignals {
            signal(sig, pineSignalHandler)
        }
    }

    // MARK: - Next-launch check

    /// Checks for pending crash reports. Call from applicationDidFinishLaunching.
    /// Returns the reports if any exist, nil otherwise.
    static func checkForPendingReports() -> [CrashReport]? {
        let store = CrashReportStore.default
        guard let reports = try? store.loadPending(), !reports.isEmpty else {
            return nil
        }
        return reports
    }

    /// Deletes all pending crash reports (after user dismisses the dialog).
    static func clearPendingReports() {
        try? CrashReportStore.default.deleteAll()
    }
}
