//
//  ProcessTreePollingHarnessTests.swift
//  PinePerformanceTests
//

import Darwin
import Foundation
import XCTest

@testable import Pine

/// Controlled measurement harness for issue #1718 (per-terminal process-tree
/// polling cost).
///
/// Spawns N synthetic terminals (POSIX group-leader shells running a
/// fixed churn workload), attaches a production
/// `TerminalProcessTreeController` to each, and reports debug-only
/// `UserTaskProcessTelemetry` counters over a fixed window:
///
/// - scheduled capture invocations per terminal per second
/// - capture pass duration (sum and mean)
/// - `proc_listchildpids` / `proc_listpgrppids` sizing and fill calls
/// - `proc_pidinfo` (BSD info) lookups
///
/// The workload script is fixed so the identical harness can be run against
/// the base implementation and the candidate and compared. Output is written
/// as JSON under the `PINE_1718_ARTIFACTS` environment variable when that
/// variable reaches the test host; otherwise under a unique per-run
/// `<temporaryDirectory>/pine-1718/run-<tag>` directory, which the local runner script
/// moves into the run directory afterwards. This is local measurement
/// evidence, not a CI benchmark gate.
final class ProcessTreePollingHarnessTests: XCTestCase {
    struct RunConfig {
        let terminals: Int
        let stableDescendants: Int
        let seconds: Int
        let sampleSeconds: Int

        var label: String {
            "n\(terminals)-k\(stableDescendants)"
        }
    }

    static var defaultArtifactRoot: String {
        let runTag = ProcessInfo.processInfo.globallyUniqueString.prefix(8)
        return FileManager.default.temporaryDirectory
            .appending(path: "pine-1718/run-\(runTag)").path
    }

    private static let workloadTemplate = """
    #!/bin/sh
    set -u
    i=0
    while [ "$i" -lt STABLE_COUNT ]; do
      /bin/sleep 300 &
      i=$((i + 1))
    done
    while :; do
      /bin/sleep 0.15 &
      churn_a=$!
      /bin/sleep 0.15 &
      churn_b=$!
      wait "$churn_a"
      wait "$churn_b"
    done
    """

    func testControlledPollingComparison() throws {
        #if DEBUG
        // Environment variables do not reach the xcodebuild test host, so the
        // default root is a unique per-run directory that the caller moves
        // into place afterwards (shared artifact roots are not stable on a
        // multi-worker machine).
        let artifactRoot = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["PINE_1718_ARTIFACTS"]
                ?? Self.defaultArtifactRoot
        )
        try FileManager.default.createDirectory(
            at: artifactRoot,
            withIntermediateDirectories: true
        )
        let configs: [RunConfig] = [
            RunConfig(terminals: 1, stableDescendants: 2, seconds: 20, sampleSeconds: 10),
            RunConfig(terminals: 4, stableDescendants: 2, seconds: 20, sampleSeconds: 10),
            RunConfig(terminals: 8, stableDescendants: 2, seconds: 25, sampleSeconds: 12),
            RunConfig(terminals: 8, stableDescendants: 8, seconds: 25, sampleSeconds: 12),
        ]
        var summary: [RunReport] = []
        for config in configs {
            let report = try runConfig(config, artifactRoot: artifactRoot)
            summary.append(report)
            print("1718-HARNESS \(report.jsonLine)")
        }
        try writeJSON(summary, to: artifactRoot.appending(path: "summary.json"))
        #else
        throw XCTSkip("Telemetry counters are debug-only.")
        #endif
    }

    #if DEBUG
    private struct RunReport: Codable, Sendable {
        let label: String
        let terminals: Int
        let stableDescendants: Int
        let durationSeconds: Int
        let context: SystemContext
        let snapshot: UserTaskProcessTelemetry.Snapshot

        var capturesPerSecondPerTerminal: Double {
            Double(snapshot.scheduledCaptures)
                / Double(terminals)
                / Double(durationSeconds)
        }

        var meanCaptureMicroseconds: Double {
            guard snapshot.scheduledCaptures > 0 else { return 0 }
            return Double(snapshot.captureDurationNanoseconds)
                / Double(snapshot.scheduledCaptures) / 1000
        }

        var listChildPidsCallsPerSecond: Double {
            Double(snapshot.listChildPidsFills + snapshot.listChildPidsSizings)
                / Double(durationSeconds)
        }

        var listPgrpPidsCallsPerSecond: Double {
            Double(snapshot.listPgrpPidsFills + snapshot.listPgrpPidsSizings)
                / Double(durationSeconds)
        }

        var bsdInfoLookupsPerSecond: Double {
            Double(snapshot.bsdInfoLookups) / Double(durationSeconds)
        }

        // This is accumulated elapsed time, including scheduling and syscall
        // waits, rather than CPU consumption.
        var captureWallSeconds: Double {
            Double(snapshot.captureDurationNanoseconds) / 1e9
        }

        var jsonLine: String {
            """
            capturesPerSecPerTerminal=\(String(format: "%.2f", capturesPerSecondPerTerminal)) \
            listChildPerSec=\(String(format: "%.1f", listChildPidsCallsPerSecond)) \
            listPgrpPerSec=\(String(format: "%.1f", listPgrpPidsCallsPerSecond)) \
            bsdInfoPerSec=\(String(format: "%.1f", bsdInfoLookupsPerSecond)) \
            meanCaptureUs=\(String(format: "%.1f", meanCaptureMicroseconds)) \
            captureWallSec=\(String(format: "%.3f", captureWallSeconds))
            """
        }
    }

    private struct SystemContext: Codable, Sendable {
        let osProductVersion: String
        let logicalCpus: Int
        let loadAverage: [Double]
        let sampleReport: String?
    }

    private struct Terminal {
        let pid: pid_t
        let retention: TerminalWorkingDirectoryRetention
        let controller: TerminalProcessTreeController
    }

    private func runConfig(
        _ config: RunConfig,
        artifactRoot: URL
    ) throws -> RunReport {
        let runDirectory = artifactRoot.appending(path: config.label)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true
        )
        let script = Self.workloadTemplate.replacingOccurrences(
            of: "STABLE_COUNT",
            with: String(config.stableDescendants)
        )
        let scriptURL = runDirectory.appending(path: "workload.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )

        var terminals: [Terminal] = []
        var spawnedPids: [pid_t] = []
        do {
            for _ in 0..<config.terminals {
                let pid = try Self.spawnWorkloadTerminal(at: scriptURL)
                spawnedPids.append(pid)
                let retention = TerminalWorkingDirectoryRetention(
                    canonicalDirectory: runDirectory
                )
                let controller = try Self.makeController(
                    rootProcessID: pid,
                    retention: retention
                )
                terminals.append(
                    Terminal(pid: pid, retention: retention, controller: controller)
                )
            }
        } catch {
            for terminal in terminals {
                terminal.controller.requestTermination()
            }
            for pid in spawnedPids
            where !terminals.contains(where: { $0.pid == pid }) {
                Self.killAndReap(pid)
            }
            throw error
        }

        defer { terminateAll(terminals) }

        UserTaskProcessTelemetry.reset()
        let sampleURL = runDirectory.appending(path: "sample.txt")
        let sampler = try? startSampler(
            target: getpid(),
            seconds: config.sampleSeconds,
            output: sampleURL
        )
        defer { sampler?.terminate() }

        Thread.sleep(forTimeInterval: Double(config.seconds))
        let snapshot = UserTaskProcessTelemetry.snapshot()

        let context = collectSystemContext(
            sampleReport: sampleURL,
            sampleAvailable: sampler != nil && FileManager.default.fileExists(atPath: sampleURL.path)
        )
        let report = RunReport(
            label: config.label,
            terminals: config.terminals,
            stableDescendants: config.stableDescendants,
            durationSeconds: config.seconds,
            context: context,
            snapshot: snapshot
        )
        try writeJSON(report, to: runDirectory.appending(path: "report.json"))

        return report
    }

    private static func makeController(
        rootProcessID: pid_t,
        retention: TerminalWorkingDirectoryRetention
    ) throws -> TerminalProcessTreeController {
        guard let controller = TerminalProcessTreeController(
            rootProcessID: rootProcessID,
            retention: retention
        ) else {
            throw HarnessError.controllerUnavailable
        }
        return controller
    }

    private enum HarnessError: Error {
        case spawnFailed(Int32)
        case controllerUnavailable
    }

    private static func killAndReap(_ pid: pid_t) {
        var status: Int32 = 0
        if Darwin.waitpid(pid, &status, WNOHANG) != pid {
            Darwin.kill(pid, SIGKILL)
            _ = Darwin.waitpid(pid, &status, 0)
        }
    }

    private static func spawnWorkloadTerminal(at scriptURL: URL) throws -> pid_t {
        let devnull = open("/dev/null", O_RDWR)
        guard devnull >= 0 else {
            throw HarnessError.spawnFailed(-1)
        }
        defer { close(devnull) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw HarnessError.spawnFailed(Int32(errno))
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // The controller requires its root to lead its own process group,
        // matching the `forkpty` session/group-leader invariant. On macOS the
        // SETPGROUP flag must be set explicitly; `setpgroup` alone leaves
        // the child in the parent's group.
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP)
        ) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw HarnessError.spawnFailed(Int32(errno))
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw HarnessError.spawnFailed(Int32(errno))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawn_file_actions_adddup2(&fileActions, devnull, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, devnull, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, devnull, STDERR_FILENO) == 0
        else {
            throw HarnessError.spawnFailed(Int32(errno))
        }

        let arguments = ["/bin/sh", scriptURL.path]
        var argumentPointers: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for pointer in argumentPointers {
                free(pointer)
            }
        }
        for argument in arguments {
            guard let pointer = argument.withCString({ strdup($0) }) else {
                throw HarnessError.spawnFailed(Int32(ENOMEM))
            }
            argumentPointers.append(pointer)
        }
        argumentPointers.append(nil)
        var pid: pid_t = 0
        let result = argumentPointers.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &pid,
                "/bin/sh",
                &fileActions,
                &attributes,
                buffer.baseAddress,
                nil
            )
        }
        guard result == 0 else {
            throw HarnessError.spawnFailed(Int32(result))
        }
        return pid
    }

    private func startSampler(
        target: pid_t,
        seconds: Int,
        output: URL
    ) throws -> Process {
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [
            String(target),
            String(seconds),
            "-f",
            output.path,
        ]
        try sampler.run()
        return sampler
    }

    private func collectSystemContext(
        sampleReport: URL,
        sampleAvailable: Bool
    ) -> SystemContext {
        var load = [Double](repeating: 0, count: 3)
        let loadCount = Int(load.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, 3)
        })
        if loadCount > 0 {
            load = Array(load.prefix(loadCount))
        }
        var productVersion = "unknown"
        let swVers = Process()
        swVers.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
        swVers.arguments = ["-productVersion"]
        swVers.standardOutput = Pipe()
        if (try? swVers.run()) != nil,
           let pipe = swVers.standardOutput as? Pipe {
            swVers.waitUntilExit()
            productVersion = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        }
        return SystemContext(
            osProductVersion: productVersion,
            logicalCpus: Int(sysconf(_SC_NPROCESSORS_ONLN)),
            loadAverage: load,
            sampleReport: sampleAvailable
                ? sampleReport.path
                : nil
        )
    }

    private func terminateAll(_ terminals: [Terminal]) {
        let deadline = Date().addingTimeInterval(10)
        for terminal in terminals {
            terminal.controller.requestTermination()
        }
        for terminal in terminals {
            _ = terminal.controller.waitForTermination(timeout: 5)
        }
        // Confirm every workload process is gone before releasing retention.
        var pending = terminals
        while !pending.isEmpty, Date() < deadline {
            pending = pending.filter { terminal in
                UserTaskProcessInspector.identity(
                    for: terminal.pid
                ) != nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        for terminal in terminals {
            terminal.retention.finishCleanup(succeeded: true)
        }
    }
    #endif

    private func writeJSON(_ value: Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
