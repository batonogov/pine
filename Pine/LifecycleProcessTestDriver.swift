//
//  LifecycleProcessTestDriver.swift
//  Pine
//
//  Debug-only process fixture for the full application lifecycle release gate.
//

#if DEBUG
import Foundation
import SwiftTerm

/// Installs deterministic dirty-editor and live-PTY state in the real Pine
/// process. The process test can request a second terminal generation with
/// a one-shot control file while AppKit's Quit sheet is visible, without
/// reaching through a
/// model-only test seam.
@MainActor
final class LifecycleProcessTestDriver {
    static let shared = LifecycleProcessTestDriver()

    private weak var projectManager: ProjectManager?
    private var terminalPaneID: PaneID?
    private var generationControl: DispatchSourceTimer?
    private var diagnosticsDirectory: URL?
    private var generation = 0

    private init() {}

    func startIfRequested(projectManager: ProjectManager) {
        guard CommandLine.arguments.contains(
            "--ui-test-lifecycle-process"
        ) else { return }
        guard generationControl == nil else { return }
        guard let diagnosticsDirectory = Self.diagnosticsDirectory() else {
            assertionFailure(
                "Lifecycle process fixture requires a diagnostics directory"
            )
            return
        }
        self.projectManager = projectManager
        self.diagnosticsDirectory = diagnosticsDirectory
        writeProcessIdentifier()

        if ProcessInfo.processInfo.environment[
            "PINE_LIFECYCLE_FIXTURE_DIRTY"
        ] != "0" {
            let dirtyFile = projectManager.rootURL?
                .appendingPathComponent("dirty.swift")
            if let dirtyFile,
               case .opened = projectManager.activeTabManager.openTab(
                   url: dirtyFile
               ) {
                projectManager.activeTabManager.updateContent(
                    "let lifecycleFixtureIsDirty = true\n"
                )
                record("dirty-buffer-ready")
            } else {
                record("dirty-buffer-failed")
            }
        }

        if ProcessInfo.processInfo.environment[
            "PINE_LIFECYCLE_FIXTURE_TERMINAL"
        ] != "0" {
            spawnTerminalGeneration()
            installGenerationControl()
        }
        record("fixture-ready")
    }

    private func installGenerationControl() {
        guard let diagnosticsDirectory else { return }
        let request = diagnosticsDirectory.appendingPathComponent(
            "request-next-generation"
        )
        generationControl = LifecycleProcessGenerationControl.make(
            request: request
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.spawnTerminalGeneration()
            }
        }
    }

    private func spawnTerminalGeneration() {
        guard let projectManager,
              let rootURL = projectManager.rootURL,
              let diagnosticsDirectory else { return }
        generation += 1
        let process = TerminalInitialProcess(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                "set -m; child=0; "
                    + "trap 'test \"$child\" -le 0 || kill \"$child\" "
                    + "2>/dev/null; exit 0' HUP INT TERM; "
                    + "while :; do /bin/sleep 60 & child=$!; "
                    + "echo $child > \"$1/owned-$2-child.pid\"; "
                    + "fg %1; done",
                "pine-lifecycle-fixture",
                diagnosticsDirectory.path,
                String(generation),
            ]
        )
        let tab: TerminalTab?
        if let terminalPaneID {
            tab = projectManager.paneManager.addTerminalTab(
                in: terminalPaneID,
                workingDirectory: rootURL,
                initialProcess: process
            )
        } else {
            terminalPaneID = projectManager.paneManager
                .createTerminalPaneAtBottom(
                    workingDirectory: rootURL,
                    initialProcess: process
                )
            tab = terminalPaneID.flatMap {
                projectManager.paneManager.terminalState(for: $0)?.activeTab
            }
        }
        record("terminal-generation-\(generation)-requested")
        guard let tab else {
            record("terminal-generation-\(generation)-missing-tab")
            return
        }
        // Production starts PTYs lazily from TerminalContainerView.layout().
        // The process-level gate must not depend on CI window-layout timing:
        // drive the same production start path once the real tab is owned.
        tab.startIfNeeded()
        recordStartedProcess(for: tab, generation: generation)
    }

    private func recordStartedProcess(
        for tab: TerminalTab,
        generation: Int
    ) {
        guard let diagnosticsDirectory else { return }
        Task { @MainActor [weak tab] in
            for _ in 0..<200 {
                guard let tab else { return }
                let processIdentifier = tab.terminalView.process.shellPid
                if tab.isProcessRunning, processIdentifier > 1 {
                    let url = diagnosticsDirectory.appendingPathComponent(
                        "owned-\(generation).pid"
                    )
                    try? Data("\(processIdentifier)\n".utf8).write(
                        to: url,
                        options: .atomic
                    )
                    LifecycleProcessDiagnostics.record(
                        "terminal-generation-\(generation)-started-"
                            + "pid-\(processIdentifier)",
                        in: diagnosticsDirectory
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            LifecycleProcessDiagnostics.record(
                "terminal-generation-\(generation)-start-timeout",
                in: diagnosticsDirectory
            )
        }
    }

    private func writeProcessIdentifier() {
        guard let diagnosticsDirectory else { return }
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let url = diagnosticsDirectory.appendingPathComponent("pine.pid")
        try? Data("\(processIdentifier)\n".utf8).write(
            to: url,
            options: .atomic
        )
    }

    private func record(_ phase: String) {
        guard let diagnosticsDirectory else { return }
        LifecycleProcessDiagnostics.record(
            phase,
            in: diagnosticsDirectory
        )
    }

    private static func diagnosticsDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment[
            "PINE_LIFECYCLE_DIAGNOSTICS_DIRECTORY"
        ], path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            return url
        } catch {
            return nil
        }
    }
}

nonisolated enum LifecycleProcessGenerationControl {
    static func make(
        request: URL,
        onRequest: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer {
        let source = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        source.schedule(
            deadline: .now(),
            repeating: .milliseconds(50)
        )
        source.setEventHandler {
            guard FileManager.default.fileExists(atPath: request.path),
                  (try? FileManager.default.removeItem(at: request)) != nil
            else { return }
            onRequest()
        }
        source.resume()
        return source
    }
}

nonisolated enum LifecycleProcessDiagnostics {
    private static let queue = DispatchQueue(
        label: "com.pine.lifecycle-process-diagnostics",
        qos: .utility
    )

    static func record(_ phase: String, in directory: URL) {
        queue.async {
            let url = directory.appendingPathComponent("phases.log")
            let line = Data("\(phase)\n".utf8)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil
                )
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                return
            }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.synchronize()
            } catch {
                return
            }
        }
    }
}
#endif
