//
//  LifecycleResourceSoakTests.swift
//  PinePerformanceTests
//

import AppKit
import Darwin
import Foundation
import XCTest

@testable import Pine

nonisolated private struct SoakProcessIdentity: Codable, Hashable, Sendable {
    let processID: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String
}

nonisolated private struct SoakResourceSnapshot: Codable, Sendable {
    let elapsedSeconds: Double
    let residentBytes: Int
    let peakResidentBytes: Int
    let cpuSeconds: Double
    let descriptorCount: Int
    let pseudoTerminalCount: Int
    let children: [SoakProcessIdentity]
}

nonisolated private enum SoakRendererMode: String, Codable, Sendable {
    case coreGraphics = "coregraphics"
    case automatic
}

nonisolated private enum SoakRendererBackend: String, Codable, Sendable {
    case coreGraphics = "coregraphics"
    case metal
    case unknown
}

nonisolated private struct SoakRendererObservation: Sendable {
    let requested: SoakRendererMode
    let effective: SoakRendererBackend
    let recreationAttempted: Bool
    let recreationSucceeded: Bool
}

nonisolated private struct SoakCycleSample: Codable, Sendable {
    let cycle: Int
    let selector: UInt64
    let wallSeconds: Double
    let cpuSeconds: Double
    let resources: SoakResourceSnapshot
    let descriptorDelta: Int
    let pseudoTerminalDelta: Int
    let childDelta: Int
    let rendererRequested: SoakRendererMode
    let rendererEffective: SoakRendererBackend
    let rendererRecreationAttempted: Bool
    let rendererRecreationSucceeded: Bool
}

nonisolated private struct LifecycleSoakReport: Codable, Sendable {
    let schemaVersion: Int
    let seed: UInt64
    let requestedCycles: Int
    let startedAtUnixSeconds: TimeInterval
    var completedCycles: Int
    var baseline: SoakResourceSnapshot?
    var final: SoakResourceSnapshot?
    var idleCPUSeconds: Double?
    var peakResidentBytes: Int
    var hardFailures: [String]
    var trendWarnings: [String]
    var samples: [SoakCycleSample]
}

nonisolated private struct LifecycleSoakConfiguration: Codable, Sendable {
    let enabled: Bool
    let cycles: Int
    let seed: UInt64
    let artifactsDirectory: String

    static func load() -> LifecycleSoakConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        if environment["PINE_LIFECYCLE_SOAK"] == "1" {
            return LifecycleSoakConfiguration(
                enabled: true,
                cycles: Int(environment["PINE_SOAK_CYCLES"] ?? "100") ?? 100,
                seed: UInt64(environment["PINE_SOAK_SEED"] ?? "1443") ?? 1_443,
                artifactsDirectory: environment["PINE_SOAK_ARTIFACTS_DIR"]
                    ?? FileManager.default.temporaryDirectory
                        .appending(path: "PineLifecycleSoakArtifacts")
                        .path
            )
        }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configURL = repositoryRoot
            .appending(path: "LifecycleSoakArtifacts/config.json")
        guard let data = try? Data(contentsOf: configURL),
              let configuration = try? JSONDecoder().decode(
                  LifecycleSoakConfiguration.self,
                  from: data
              ),
              configuration.enabled else {
            return nil
        }
        return configuration
    }
}

nonisolated private enum LifecycleSoakError: Error, CustomStringConvertible {
    case invariant(String)
    case timeout(String)

    var description: String {
        switch self {
        case .invariant(let detail):
            return detail
        case .timeout(let phase):
            return "Timed out while waiting for \(phase)"
        }
    }
}

nonisolated private struct SeededSoakGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

nonisolated private enum SoakResourceSampler {
    static func snapshot(
        startedAt: ContinuousClock.Instant
    ) -> SoakResourceSnapshot {
        let descriptors = descriptorInfo()
        let usage = processUsage()
        return SoakResourceSnapshot(
            elapsedSeconds: seconds(startedAt.duration(to: .now)),
            residentBytes: residentBytes(),
            peakResidentBytes: usage.peakResidentBytes,
            cpuSeconds: usage.cpuSeconds,
            descriptorCount: descriptors.count,
            pseudoTerminalCount: descriptors.pseudoTerminalCount,
            children: recursiveChildren(of: Darwin.getpid())
        )
    }

    static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
        ) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private static func processUsage() -> (
        cpuSeconds: Double,
        peakResidentBytes: Int
    ) {
        var usage = rusage()
        guard Darwin.getrusage(RUSAGE_SELF, &usage) == 0 else {
            return (0, 0)
        }
        let user = Double(usage.ru_utime.tv_sec)
            + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec)
            + Double(usage.ru_stime.tv_usec) / 1_000_000
        // Darwin reports ru_maxrss in bytes. Unlike periodic resident-size
        // samples, this retains a short-lived peak between lifecycle settles.
        return (user + system, max(0, Int(usage.ru_maxrss)))
    }

    private static func descriptorInfo() -> (
        count: Int,
        pseudoTerminalCount: Int
    ) {
        let processID = Darwin.getpid()
        let requestedBytes = Darwin.proc_pidinfo(
            processID,
            PROC_PIDLISTFDS,
            0,
            nil,
            0
        )
        guard requestedBytes > 0 else { return (0, 0) }

        let descriptorSize = MemoryLayout<proc_fdinfo>.size
        let capacity = Int(requestedBytes) / descriptorSize + 8
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: capacity
        )
        let bufferBytes = descriptors.count * descriptorSize
        guard bufferBytes <= Int(Int32.max) else { return (0, 0) }
        let receivedBytes = descriptors.withUnsafeMutableBytes { buffer in
            Darwin.proc_pidinfo(
                processID,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard receivedBytes > 0 else { return (0, 0) }

        let count = min(Int(receivedBytes) / descriptorSize, descriptors.count)
        var pseudoTerminalCount = 0
        for descriptor in descriptors.prefix(count) {
            guard let path = vnodePath(
                processID: processID,
                descriptor: descriptor.proc_fd
            ) else { continue }
            if path == "/dev/ptmx"
                || path.hasPrefix("/dev/pty")
                || path.hasPrefix("/dev/tty") {
                pseudoTerminalCount += 1
            }
        }
        return (count, pseudoTerminalCount)
    }

    private static func vnodePath(
        processID: pid_t,
        descriptor: Int32
    ) -> String? {
        var info = vnode_fdinfowithpath()
        let size = MemoryLayout<vnode_fdinfowithpath>.size
        guard size <= Int(Int32.max) else { return nil }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            Darwin.proc_pidfdinfo(
                processID,
                descriptor,
                PROC_PIDFDVNODEPATHINFO,
                pointer,
                Int32(size)
            )
        }
        guard result == Int32(size) else { return nil }
        return withUnsafeBytes(of: &info.pvip.vip_path) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            guard end != bytes.startIndex else { return nil }
            return String(bytes: bytes[..<end], encoding: .utf8)
        }
    }

    private static func recursiveChildren(
        of rootProcessID: pid_t
    ) -> [SoakProcessIdentity] {
        var pending = [rootProcessID]
        var visited = Set<pid_t>()
        var result: [SoakProcessIdentity] = []
        while let parent = pending.popLast() {
            for child in directChildren(of: parent) where visited.insert(child).inserted {
                pending.append(child)
                guard let identity = UserTaskProcessInspector.identity(
                    for: child,
                    includeZombie: true
                ) else { continue }
                result.append(SoakProcessIdentity(
                    processID: identity.processID,
                    startSeconds: identity.startSeconds,
                    startMicroseconds: identity.startMicroseconds,
                    executable: executableName(for: child)
                ))
            }
        }
        return result.sorted {
            if $0.processID != $1.processID {
                return $0.processID < $1.processID
            }
            if $0.startSeconds != $1.startSeconds {
                return $0.startSeconds < $1.startSeconds
            }
            return $0.startMicroseconds < $1.startMicroseconds
        }
    }

    private static func directChildren(of processID: pid_t) -> [pid_t] {
        let requestedBytes = Darwin.proc_listchildpids(processID, nil, 0)
        guard requestedBytes > 0 else { return [] }
        let capacity = Int(requestedBytes) / MemoryLayout<pid_t>.size + 8
        var processIDs = [pid_t](repeating: 0, count: capacity)
        let receivedBytes = processIDs.withUnsafeMutableBytes { buffer in
            Darwin.proc_listchildpids(
                processID,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard receivedBytes > 0 else { return [] }
        let count = min(
            Int(receivedBytes) / MemoryLayout<pid_t>.size,
            processIDs.count
        )
        return Array(processIDs.prefix(count)).filter { $0 > 1 }
    }

    private static func executableName(for processID: pid_t) -> String {
        // Swift's Clang importer does not expose the compound
        // PROC_PIDPATHINFO_MAXSIZE macro (4 * MAXPATHLEN).
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes { buffer in
            Darwin.proc_pidpath(
                processID,
                buffer.baseAddress,
                UInt32(buffer.count)
            )
        }
        guard length > 0 else { return "unknown" }
        guard let pathString = String(
            bytes: path.prefix(Int(length)),
            encoding: .utf8
        ) else { return "unknown" }
        return URL(
            fileURLWithPath: pathString
        ).lastPathComponent
    }
}

@MainActor
final class LifecycleResourceSoakTests: XCTestCase {
    private static let descriptorNoiseAllowance = 4
    private static let fixtureFileCount = 512
    private static let memoryTrendBytes = 64 * 1_048_576
    private static let minimumHardMemoryBytes = 512 * 1_048_576
    private static let idleDuration: Duration = .seconds(2)

    func testLifecycleResourceSoak() async throws {
        guard let configuration = LifecycleSoakConfiguration.load() else {
            throw XCTSkip(
                "Provide LifecycleSoakArtifacts/config.json to run the lifecycle soak"
            )
        }

        let cycles = min(max(1, configuration.cycles), 500)
        let seed = configuration.seed
        let artifactURL = try makeArtifactURL(
            directoryPath: configuration.artifactsDirectory
        )
        let fixtureRoot = try makeProjectFixture(seed: seed)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let defaultsName = "io.github.batonogov.pine.lifecycle-soak.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.set(false, forKey: LSPSettings.Keys.enabled)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let startedAt = ContinuousClock.now
        var generator = SeededSoakGenerator(seed: seed)
        var report = LifecycleSoakReport(
            schemaVersion: 1,
            seed: seed,
            requestedCycles: cycles,
            startedAtUnixSeconds: Date().timeIntervalSince1970,
            completedCycles: 0,
            baseline: nil,
            final: nil,
            idleCPUSeconds: nil,
            peakResidentBytes: 0,
            hardFailures: [],
            trendWarnings: [],
            samples: []
        )

        let overallSignpost = PerformanceSignposts.beginInterval(
            "lifecycle.soak"
        )
        defer {
            PerformanceSignposts.endInterval(
                "lifecycle.soak",
                overallSignpost
            )
        }

        let initial = SoakResourceSampler.snapshot(startedAt: startedAt)
        for rendererMode in [
            SoakRendererMode.coreGraphics,
            SoakRendererMode.automatic,
        ] {
            do {
                try await runCycle(
                    selector: generator.next(),
                    projectURL: fixtureRoot,
                    defaults: defaults,
                    rendererMode: rendererMode
                )
            } catch {
                report.hardFailures.append(
                    "warmup \(rendererMode.rawValue): \(error)"
                )
            }
        }
        let baseline = await settle(
            toward: initial,
            startedAt: startedAt,
            timeout: .seconds(5)
        )
        report.baseline = baseline
        report.peakResidentBytes = baseline.peakResidentBytes
        try write(report, to: artifactURL)

        for cycle in 0..<cycles {
            let selector = generator.next()
            let cycleStart = ContinuousClock.now
            let cycleStartResources = SoakResourceSampler.snapshot(
                startedAt: startedAt
            )
            let rendererMode: SoakRendererMode = cycle.isMultiple(of: 2)
                ? .coreGraphics
                : .automatic
            var renderer = SoakRendererObservation(
                requested: rendererMode,
                effective: .unknown,
                recreationAttempted: false,
                recreationSucceeded: false
            )
            let signpost = PerformanceSignposts.beginInterval(
                "lifecycle.soak.cycle"
            )
            do {
                renderer = try await runCycle(
                    selector: selector,
                    projectURL: fixtureRoot,
                    defaults: defaults,
                    rendererMode: rendererMode
                )
            } catch {
                report.hardFailures.append("cycle \(cycle): \(error)")
            }
            PerformanceSignposts.endInterval(
                "lifecycle.soak.cycle",
                signpost
            )

            let snapshot = await settle(
                toward: baseline,
                startedAt: startedAt,
                timeout: .seconds(5)
            )
            let descriptorDelta = snapshot.descriptorCount
                - baseline.descriptorCount
            let pseudoTerminalDelta = snapshot.pseudoTerminalCount
                - baseline.pseudoTerminalCount
            let childDelta = snapshot.children.count
                - baseline.children.count
            recordResourceFailures(
                cycle: cycle,
                baseline: baseline,
                snapshot: snapshot,
                report: &report
            )
            report.samples.append(SoakCycleSample(
                cycle: cycle,
                selector: selector,
                wallSeconds: SoakResourceSampler.seconds(
                    cycleStart.duration(to: .now)
                ),
                cpuSeconds: max(
                    0,
                    snapshot.cpuSeconds - cycleStartResources.cpuSeconds
                ),
                resources: snapshot,
                descriptorDelta: descriptorDelta,
                pseudoTerminalDelta: pseudoTerminalDelta,
                childDelta: childDelta,
                rendererRequested: renderer.requested,
                rendererEffective: renderer.effective,
                rendererRecreationAttempted: renderer.recreationAttempted,
                rendererRecreationSucceeded: renderer.recreationSucceeded
            ))
            report.completedCycles = cycle + 1
            report.peakResidentBytes = max(
                report.peakResidentBytes,
                snapshot.peakResidentBytes
            )
            try write(report, to: artifactURL)
        }

        let idleStart = SoakResourceSampler.snapshot(startedAt: startedAt)
        try await Task.sleep(for: Self.idleDuration)
        let final = SoakResourceSampler.snapshot(startedAt: startedAt)
        let idleCPUSeconds = max(0, final.cpuSeconds - idleStart.cpuSeconds)
        report.final = final
        report.idleCPUSeconds = idleCPUSeconds
        report.peakResidentBytes = max(
            report.peakResidentBytes,
            final.peakResidentBytes
        )
        recordSteadyStateThresholds(
            baseline: baseline,
            final: final,
            idleCPUSeconds: idleCPUSeconds,
            report: &report
        )
        try write(report, to: artifactURL)

        if !report.hardFailures.isEmpty {
            XCTFail(report.hardFailures.joined(separator: "\n"))
        }
    }

    private func runCycle(
        selector: UInt64,
        projectURL: URL,
        defaults: UserDefaults,
        rendererMode: SoakRendererMode = .coreGraphics
    ) async throws -> SoakRendererObservation {
        try await exerciseProjectLifecycle(
            selector: selector,
            projectURL: projectURL,
            defaults: defaults
        )
        let renderer = try await exerciseTerminalProcessTree(
            projectURL: projectURL,
            rendererMode: rendererMode
        )
        try await exerciseLSPCrashAndRestart(projectURL: projectURL)
        return renderer
    }

    private func exerciseProjectLifecycle(
        selector: UInt64,
        projectURL: URL,
        defaults: UserDefaults
    ) async throws {
        let signpost = PerformanceSignposts.beginInterval(
            "lifecycle.soak.project"
        )
        defer {
            PerformanceSignposts.endInterval(
                "lifecycle.soak.project",
                signpost
            )
        }

        let settings = LSPSettings(defaults: defaults)
        let manager = ProjectManager(lspSettings: settings)
        defer { manager.shutdownReclaimableProject() }
        manager.workspace.loadDirectory(url: projectURL)
        guard await waitUntil(timeout: .seconds(5), {
            !manager.workspace.isLoading
        }) else {
            throw LifecycleSoakError.timeout("project load")
        }
        guard manager.workspace.hasActiveFileWatcherForTesting else {
            throw LifecycleSoakError.invariant("workspace watcher did not start")
        }

        let files = (0..<3).map { index in
            let fixtureIndex = (
                Int(selector % UInt64(Self.fixtureFileCount)) + index
            ) % Self.fixtureFileCount
            return projectURL.appending(path: "Sources/File\(fixtureIndex).swift")
        }
        for file in files {
            manager.primaryTabManager.openTab(
                url: file,
                syntaxHighlightingDisabled: true
            )
        }
        guard let sourcePane = manager.paneManager.root.firstLeafID,
              let activeTabID = manager.primaryTabManager.activeTabID,
              let splitPane = manager.paneManager.splitPane(
                  sourcePane,
                  axis: selector.isMultiple(of: 2) ? .horizontal : .vertical,
                  tabID: activeTabID,
                  sourcePane: sourcePane
              ) else {
            throw LifecycleSoakError.invariant("tab/pane churn could not split")
        }

        let searchResults = await ProjectSearchProvider.performSearch(
            query: "pine-soak-token",
            isCaseSensitive: false,
            rootURL: projectURL
        )
        guard !searchResults.isEmpty else {
            throw LifecycleSoakError.invariant("large-project search returned no fixture result")
        }
        manager.paneManager.removePane(splitPane)

        manager.suspendEditorServices()
        guard manager.workspace.isSuspended,
              !manager.workspace.hasActiveFileWatcherForTesting,
              manager.lspManager.presentationLifecycle == .backgroundSuspended else {
            throw LifecycleSoakError.invariant("background services did not suspend")
        }
        manager.resumeEditorServices()
        guard await waitUntil(timeout: .seconds(5), {
            !manager.workspace.isLoading
        }) else {
            throw LifecycleSoakError.timeout("project resume")
        }
        guard !manager.workspace.isSuspended,
              manager.workspace.hasActiveFileWatcherForTesting,
              manager.lspManager.presentationLifecycle == .active else {
            throw LifecycleSoakError.invariant("background services did not resume")
        }

        manager.shutdownReclaimableProject()
        guard !manager.workspace.hasActiveFileWatcherForTesting,
              manager.lspManager.presentationLifecycle == .invalidated,
              manager.lspManager.servers.isEmpty else {
            throw LifecycleSoakError.invariant("project teardown retained editor services")
        }
    }

    private func exerciseTerminalProcessTree(
        projectURL: URL,
        rendererMode: SoakRendererMode
    ) async throws -> SoakRendererObservation {
        let signpost = PerformanceSignposts.beginInterval(
            "lifecycle.soak.terminal"
        )
        defer {
            PerformanceSignposts.endInterval(
                "lifecycle.soak.terminal",
                signpost
            )
        }

        let traceURL = projectURL.appending(path: "terminal.trace")
        try? FileManager.default.removeItem(at: traceURL)
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/codex")
        let tab = TerminalTab(name: "Lifecycle soak")
        tab.configure(
            workingDirectory: projectURL,
            initialProcess: TerminalInitialProcess(
                executablePath: "/usr/bin/python3",
                arguments: [fixtureURL.path, traceURL.path]
            )
        )
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        guard let terminalView = tab.terminalView as? PineTerminalView else {
            throw LifecycleSoakError.invariant("terminal renderer bridge unavailable")
        }
        terminalView.metalRendererDisabledForTesting = rendererMode == .coreGraphics
        let window = NSWindow(
            contentRect: tab.terminalView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = terminalView
        defer { window.contentView = nil }
        if rendererMode == .coreGraphics, terminalView.isUsingMetalRenderer {
            throw LifecycleSoakError.invariant("CoreGraphics cycle enabled Metal")
        }
        terminalView.bindPresentationHost(generation: UUID())
        tab.startIfNeeded()
        guard tab.isProcessRunning,
              let controller = tab.processTreeControllerForTesting else {
            tab.stop()
            throw LifecycleSoakError.invariant("terminal PTY did not start")
        }

        let processIdentity = controller.rootIdentity
        let detector = AgentDetector(maxSessionHistory: 4)
        let preciseStartedAt = Date(
            timeIntervalSince1970: TimeInterval(processIdentity.startSeconds)
                + TimeInterval(processIdentity.startMicroseconds) / 1_000_000
        )
        detector.processSnapshotDidUpdate([
            DetectedProcess(
                pid: processIdentity.processID,
                parentProcessID: Darwin.getpid(),
                processGroupID: Darwin.getpgid(processIdentity.processID),
                command: "/usr/bin/python3 \(fixtureURL.path)",
                cwd: projectURL,
                cpuTime: 0,
                startIdentifier: "\(processIdentity.startSeconds).\(processIdentity.startMicroseconds)",
                preciseStartedAt: preciseStartedAt
            ),
        ])
        guard detector.activeCount == 1,
              detector.activeSessions.first?.agentType == .codex else {
            tab.stop()
            throw LifecycleSoakError.invariant("controlled Codex agent was not detected")
        }

        guard await waitUntil(timeout: .seconds(3), {
            FileManager.default.fileExists(atPath: traceURL.path)
        }) else {
            tab.stop()
            throw LifecycleSoakError.timeout("controlled terminal child")
        }
        try await Task.sleep(for: .milliseconds(75))

        let wasUsingMetal = terminalView.isUsingMetalRenderer
        terminalView.bindPresentationHost(generation: UUID())
        let isUsingMetal = terminalView.isUsingMetalRenderer
        if wasUsingMetal, !isUsingMetal {
            tab.stop()
            throw LifecycleSoakError.invariant(
                "Metal renderer recreation fell back during an active PTY"
            )
        }
        guard tab.isProcessRunning else {
            tab.stop()
            throw LifecycleSoakError.invariant(
                "renderer replacement terminated the controlled agent"
            )
        }

        tab.stop()
        let terminated = await Task.detached(priority: .utility) {
            controller.waitForTermination(timeout: 3)
        }.value
        detector.processSnapshotDidUpdate([])
        guard terminated,
              !tab.hasAcknowledgedPTYLeaseForTesting,
              !tab.isProcessRunning,
              detector.activeCount == 0,
              detector.detectedSessions.last?.state == .done else {
            throw LifecycleSoakError.invariant("terminal process tree or PTY lease survived stop")
        }
        try? FileManager.default.removeItem(at: traceURL)
        return SoakRendererObservation(
            requested: rendererMode,
            effective: isUsingMetal ? .metal : .coreGraphics,
            recreationAttempted: wasUsingMetal,
            recreationSucceeded: wasUsingMetal && isUsingMetal
        )
    }

    private func exerciseLSPCrashAndRestart(
        projectURL: URL
    ) async throws {
        let signpost = PerformanceSignposts.beginInterval(
            "lifecycle.soak.lsp"
        )
        defer {
            PerformanceSignposts.endInterval(
                "lifecycle.soak.lsp",
                signpost
            )
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/fake-lsp.py")
        let crashClient = LSPClient(language: "soak")
        defer { crashClient.shutdown() }
        guard await crashClient.start(
            command: "/usr/bin/python3",
            arguments: [fixtureURL.path, "crash"],
            rootURI: projectURL.absoluteString,
            environment: ["PYTHONUNBUFFERED": "1"],
            currentDirectoryURL: projectURL,
            initializationTimeout: .seconds(2)
        ) else {
            crashClient.shutdown()
            throw LifecycleSoakError.invariant("crashing LSP did not initialize")
        }
        guard await waitUntil(timeout: .seconds(2), {
            !crashClient.transport.isRunning
        }) else {
            crashClient.shutdown()
            throw LifecycleSoakError.timeout("LSP crash cleanup")
        }
        guard crashClient.pendingRequestCount == 0 else {
            throw LifecycleSoakError.invariant("crashed LSP retained requests")
        }

        let restartedClient = LSPClient(language: "soak")
        defer { restartedClient.shutdown() }
        guard await restartedClient.start(
            command: "/usr/bin/python3",
            arguments: [fixtureURL.path, "graceful"],
            rootURI: projectURL.absoluteString,
            environment: ["PYTHONUNBUFFERED": "1"],
            currentDirectoryURL: projectURL,
            initializationTimeout: .seconds(2)
        ) else {
            restartedClient.shutdown()
            throw LifecycleSoakError.invariant("replacement LSP did not initialize")
        }
        guard await restartedClient.shutdownGracefully(timeout: .seconds(2)),
              !restartedClient.transport.isRunning,
              restartedClient.pendingRequestCount == 0 else {
            restartedClient.shutdown()
            throw LifecycleSoakError.invariant("replacement LSP did not shut down cleanly")
        }
    }

    private func waitUntil(
        timeout: Duration,
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        return condition()
    }

    private func settle(
        toward baseline: SoakResourceSnapshot,
        startedAt: ContinuousClock.Instant,
        timeout: Duration
    ) async -> SoakResourceSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var snapshot = SoakResourceSampler.snapshot(startedAt: startedAt)
        while clock.now < deadline {
            let childIdentity = Set(snapshot.children)
            let baselineIdentity = Set(baseline.children)
            if childIdentity == baselineIdentity,
               snapshot.pseudoTerminalCount <= baseline.pseudoTerminalCount,
               snapshot.descriptorCount
                    <= baseline.descriptorCount + Self.descriptorNoiseAllowance {
                return snapshot
            }
            try? await Task.sleep(for: .milliseconds(50))
            snapshot = SoakResourceSampler.snapshot(startedAt: startedAt)
        }
        return snapshot
    }

    private func recordResourceFailures(
        cycle: Int,
        baseline: SoakResourceSnapshot,
        snapshot: SoakResourceSnapshot,
        report: inout LifecycleSoakReport
    ) {
        let baselineChildren = Set(baseline.children)
        let currentChildren = Set(snapshot.children)
        if currentChildren != baselineChildren {
            let retained = currentChildren.subtracting(baselineChildren)
            report.hardFailures.append(
                "cycle \(cycle): retained child identities \(retained)"
            )
        }
        if snapshot.pseudoTerminalCount > baseline.pseudoTerminalCount {
            report.hardFailures.append(
                "cycle \(cycle): PTY descriptors \(snapshot.pseudoTerminalCount) "
                    + "did not return to \(baseline.pseudoTerminalCount)"
            )
        }

        let descriptorDelta = snapshot.descriptorCount - baseline.descriptorCount
        if descriptorDelta > Self.descriptorNoiseAllowance {
            report.hardFailures.append(
                "cycle \(cycle): descriptor delta \(descriptorDelta) exceeded "
                    + "noise allowance \(Self.descriptorNoiseAllowance)"
            )
        } else if descriptorDelta > 0 {
            report.trendWarnings.append(
                "cycle \(cycle): descriptor delta \(descriptorDelta) within shared-runner noise"
            )
        }
    }

    private func recordSteadyStateThresholds(
        baseline: SoakResourceSnapshot,
        final: SoakResourceSnapshot,
        idleCPUSeconds: Double,
        report: inout LifecycleSoakReport
    ) {
        let memoryGrowth = final.residentBytes - baseline.residentBytes
        let hardMemoryGrowth = max(
            Self.minimumHardMemoryBytes,
            baseline.residentBytes / 2
        )
        if memoryGrowth > hardMemoryGrowth {
            report.hardFailures.append(
                "steady-state memory grew by \(memoryGrowth) bytes; hard limit is \(hardMemoryGrowth)"
            )
        } else if memoryGrowth > Self.memoryTrendBytes {
            report.trendWarnings.append(
                "steady-state memory grew by \(memoryGrowth) bytes"
            )
        }

        let idleSeconds = SoakResourceSampler.seconds(Self.idleDuration)
        if idleCPUSeconds > idleSeconds * 0.75 {
            report.hardFailures.append(
                "idle CPU consumed \(idleCPUSeconds) seconds during \(idleSeconds)-second settle"
            )
        } else if idleCPUSeconds > idleSeconds * 0.15 {
            report.trendWarnings.append(
                "idle CPU consumed \(idleCPUSeconds) seconds during settle"
            )
        }
    }

    private func makeArtifactURL(
        directoryPath: String
    ) throws -> URL {
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appending(path: "lifecycle-soak-report.json")
    }

    private func write(
        _ report: LifecycleSoakReport,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private func makeProjectFixture(seed: UInt64) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pine-lifecycle-soak-\(seed)-\(UUID().uuidString)")
        let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )
        let padding = String(
            repeating: "// deterministic lifecycle soak padding\n",
            count: 128
        )
        for index in 0..<Self.fixtureFileCount {
            let content = """
            // pine-soak-token \(index)
            struct SoakFixture\(index) {
                let seed: UInt64 = \(seed)
                let value = \(index)
            }
            \(padding)
            """
            try content.write(
                to: sources.appending(path: "File\(index).swift"),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }
}
