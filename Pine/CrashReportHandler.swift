//
//  CrashReportHandler.swift
//  Pine
//
//  Uses Apple's MetricKit (MXMetricManager) as the primary crash reporting mechanism.
//  A minimal async-signal-safe POSIX signal handler is kept as a fallback for
//  hard crashes (SIGSEGV, etc.) that MetricKit may not capture immediately.
//
//  Signal handler constraints (async-signal-safe):
//  - No Swift String interpolation
//  - No Foundation (Date(), FileManager)
//  - Only POSIX: open(), write(), close(), _exit(), time(), mkdir()
//  - Path is a pre-computed C string buffer, filled BEFORE installing the handler
//  - Timestamp via time(nil), not Date()
//

import Foundation
import MetricKit

// MARK: - Pre-computed C buffers for signal handler

/// Pre-computed full path buffer: <dir>/signal-crash.json (filled once before handler install).
/// Must be global for C function pointer compatibility.
private var signalCrashFilePath: UnsafeMutablePointer<CChar>?
/// Pre-computed directory path for mkdir in signal handler.
private var signalCrashDirPath: UnsafeMutablePointer<CChar>?

// swiftlint:disable:next function_body_length
private func pineSignalHandler(_ sig: Int32) {
    guard let filePath = signalCrashFilePath else {
        // Cannot write without pre-computed path — re-raise and bail
        signal(sig, SIG_DFL)
        raise(sig)
        return
    }

    // Ensure directory exists (mkdir is async-signal-safe)
    if let dirPath = signalCrashDirPath {
        mkdir(dirPath, 0o755)
    }

    // Get current timestamp via POSIX time() — async-signal-safe
    let timestamp = time(nil)

    // Build minimal JSON as raw bytes — NO Swift String interpolation
    // Format: {"exceptionType":"Signal","exceptionReason":"Signal <N>",
    //          "stackTrace":[],"appVersion":"","buildNumber":"",
    //          "osVersion":"","timestamp":<seconds>,"source":"signal"}
    let jsonPrefix: StaticString =
        "{\"exceptionType\":\"Signal\",\"exceptionReason\":\"Signal "
    let jsonMiddle: StaticString =
        "\",\"stackTrace\":[],\"appVersion\":\"\",\"buildNumber\":\"\","
    let jsonSuffix: StaticString =
        "\"osVersion\":\"\",\"timestamp\":"
    let jsonEnd: StaticString =
        ",\"source\":\"signal\"}"

    let fd = open(filePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else {
        signal(sig, SIG_DFL)
        raise(sig)
        return
    }

    // Write JSON prefix
    jsonPrefix.withUTF8Buffer { buf in
        guard let ptr = buf.baseAddress else { return }
        _ = write(fd, ptr, buf.count)
    }

    // Write signal number as ASCII digits (stack-allocated buffer, no heap)
    var sigNum = sig
    if sigNum < 0 {
        let minus: UInt8 = 0x2D // '-'
        _ = withUnsafePointer(to: minus) { write(fd, $0, 1) }
        sigNum = -sigNum
    }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { digitsBuf in
        var count = 0
        if sigNum == 0 {
            digitsBuf[0] = 0x30 // '0'
            count = 1
        } else {
            var tmp = sigNum
            while tmp > 0 {
                digitsBuf[count] = UInt8(0x30 + tmp % 10)
                count += 1
                tmp /= 10
            }
            // Reverse in place
            var lo = 0
            var hi = count - 1
            while lo < hi {
                let swap = digitsBuf[lo]
                digitsBuf[lo] = digitsBuf[hi]
                digitsBuf[hi] = swap
                lo += 1
                hi -= 1
            }
        }
        // swiftlint:disable:next force_unwrapping
        _ = write(fd, digitsBuf.baseAddress!, count)
    }

    // Write middle
    jsonMiddle.withUTF8Buffer { buf in
        guard let ptr = buf.baseAddress else { return }
        _ = write(fd, ptr, buf.count)
    }

    // Write suffix
    jsonSuffix.withUTF8Buffer { buf in
        guard let ptr = buf.baseAddress else { return }
        _ = write(fd, ptr, buf.count)
    }

    // Write timestamp as ASCII digits (stack-allocated buffer, no heap)
    var ts = Int64(timestamp)
    if ts < 0 {
        let minus: UInt8 = 0x2D
        _ = withUnsafePointer(to: minus) { write(fd, $0, 1) }
        ts = -ts
    }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { tsBuf in
        var count = 0
        if ts == 0 {
            tsBuf[0] = 0x30
            count = 1
        } else {
            var tmp = ts
            while tmp > 0 {
                tsBuf[count] = UInt8(0x30 + tmp % 10)
                count += 1
                tmp /= 10
            }
            // Reverse in place
            var lo = 0
            var hi = count - 1
            while lo < hi {
                let swap = tsBuf[lo]
                tsBuf[lo] = tsBuf[hi]
                tsBuf[hi] = swap
                lo += 1
                hi -= 1
            }
        }
        // swiftlint:disable:next force_unwrapping
        _ = write(fd, tsBuf.baseAddress!, count)
    }

    // Write end
    jsonEnd.withUTF8Buffer { buf in
        guard let ptr = buf.baseAddress else { return }
        _ = write(fd, ptr, buf.count)
    }

    close(fd)

    // Re-raise signal with default handler so the OS generates a proper crash log
    signal(sig, SIG_DFL)
    raise(sig)
}

// MARK: - MetricKit Subscriber

/// Receives crash diagnostics from MetricKit on next app launch after a crash.
final class CrashDiagnosticSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    private let store: CrashReportStore

    init(store: CrashReportStore = .default) {
        self.store = store
        super.init()
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            guard let crashDiagnostics = payload.crashDiagnostics else { continue }
            for diagnostic in crashDiagnostics {
                let report = CrashReport(
                    exceptionType: diagnostic.exceptionType?.description
                        ?? String(diagnostic.signal?.intValue ?? 0),
                    exceptionReason: diagnostic.exceptionCode?.description ?? "Unknown",
                    stackTrace: parseCallStack(diagnostic.callStackTree),
                    appVersion: diagnostic.applicationVersion ?? AboutInfo.versionString,
                    buildNumber: AboutInfo.buildString,
                    osVersion: diagnostic.metaData.osVersion,
                    timestamp: payload.timeStampEnd,
                    source: .metricKit
                )
                try? store.save(report)
            }
        }
    }

    /// Extracts frame descriptions from the MXCallStackTree JSON representation.
    /// Uses `parseCallStackJSON(_:)` internally after getting JSON data from the tree.
    private func parseCallStack(_ callStackTree: MXCallStackTree) -> [String] {
        guard let data = try? callStackTree.jsonRepresentation() else {
            return []
        }
        return Self.parseCallStackJSON(data)
    }

    /// Parses call stack frames from raw JSON data (the format returned by MXCallStackTree).
    /// Extracted as a static method for testability.
    static func parseCallStackJSON(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let threads = json["callStacks"] as? [[String: Any]],
              let firstThread = threads.first,
              let frames = firstThread["callStackRootFrames"] as? [[String: Any]]
        else {
            return []
        }

        return frames.prefix(20).compactMap { frame in
            let address = frame["address"] as? UInt64 ?? 0
            let binaryName = frame["binaryName"] as? String ?? "?"
            let offset = frame["offsetIntoBinaryTextSegment"] as? UInt64 ?? 0
            return "\(binaryName) 0x\(String(address, radix: 16)) +\(offset)"
        }
    }
}

// MARK: - ObjC Exception Handler

/// Pre-computed store reference for exception handler (set before installing).
private var exceptionCrashStore: CrashReportStore?

/// ObjC uncaught exception handler — catches NSException in real time
/// (MetricKit only reports on next launch).
private func pineExceptionHandler(_ exception: NSException) {
    guard let store = exceptionCrashStore else { return }

    let report = CrashReport(
        exceptionType: exception.name.rawValue,
        exceptionReason: exception.reason ?? "Unknown",
        stackTrace: exception.callStackSymbols.prefix(20).map { String($0) },
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        timestamp: Date(),
        source: .exception
    )
    try? store.save(report)
}

// MARK: - CrashReportHandler

/// Installs crash handlers and manages the crash-to-report pipeline.
@MainActor
enum CrashReportHandler {

    /// Tracked signals for crash detection.
    private static let crashSignals: [Int32] = [
        SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP
    ]

    /// MetricKit subscriber — retained for the lifetime of the app.
    private static var metricKitSubscriber: CrashDiagnosticSubscriber?

    /// Whether handlers have already been installed (prevents double install).
    private static var isInstalled = false

    /// Call once from applicationDidFinishLaunching to install handlers.
    /// Only installs if crash reporting is enabled.
    static func install(settings: CrashReportSettings) {
        guard settings.isEnabled, !isInstalled else { return }
        isInstalled = true

        let store = CrashReportStore.default

        // Ensure directory exists before signal handler needs it
        try? store.ensureDirectoryExists()

        // Register MetricKit subscriber (primary mechanism)
        let subscriber = CrashDiagnosticSubscriber(store: store)
        MXMetricManager.shared.add(subscriber)
        metricKitSubscriber = subscriber

        // Install NSException handler (catches ObjC exceptions in real time)
        exceptionCrashStore = store
        NSSetUncaughtExceptionHandler(pineExceptionHandler)

        // Pre-compute C string paths for async-signal-safe handler
        let dirPath = store.directory.path(percentEncoded: false)
        let filePath = dirPath + "/signal-crash.json"

        let dirBuf = UnsafeMutablePointer<CChar>.allocate(capacity: dirPath.utf8.count + 1)
        dirPath.withCString { ptr in
            _ = strcpy(dirBuf, ptr)
        }
        signalCrashDirPath = dirBuf

        let pathBuf = UnsafeMutablePointer<CChar>.allocate(capacity: filePath.utf8.count + 1)
        filePath.withCString { ptr in
            _ = strcpy(pathBuf, ptr)
        }
        signalCrashFilePath = pathBuf

        // Install POSIX signal handlers (fallback for hard crashes)
        for sig in crashSignals {
            signal(sig, pineSignalHandler)
        }
    }

    /// Removes signal handlers and MetricKit subscriber. Called when user disables crash reporting.
    static func uninstall() {
        guard isInstalled else { return }
        isInstalled = false

        // Remove MetricKit subscriber
        if let subscriber = metricKitSubscriber {
            MXMetricManager.shared.remove(subscriber)
            metricKitSubscriber = nil
        }

        // Remove ObjC exception handler
        NSSetUncaughtExceptionHandler(nil)
        exceptionCrashStore = nil

        // Restore default signal handlers
        for sig in crashSignals {
            signal(sig, SIG_DFL)
        }

        // Free pre-computed buffers
        signalCrashFilePath?.deallocate()
        signalCrashFilePath = nil
        signalCrashDirPath?.deallocate()
        signalCrashDirPath = nil
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
